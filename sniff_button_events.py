#!/usr/bin/env python3
"""
Sniff the Logi Options+ agent IPC socket on macOS, looking for events that
might be sent when a HID++-only control (e.g. a diverted mouse/gesture
button) is pressed or released.

Background: Easy-Switch button presses are known to NOT be broadcast to
IPC clients (see TODO.md in this repo). This script exists to check
whether that also holds for other HID++-only controls (e.g. the MX
Anywhere 3S / MX Master gesture button), and to leave the door open for
whatever channel the Options+ UI itself uses to highlight a physical
button press while you are reassigning it in the Buttons configuration
screen.

Modes:

  devices        Connect to the agent and dump `/devices/list` (use this
                 first to find device IDs for the `subscribe` mode).

  subscribe      Connect directly to the agent (no UI involved), send
                 SUBSCRIBE requests for a list of candidate paths, then
                 keep the connection open and print anything the agent
                 sends unprompted. Press/release the physical button
                 while this is running. (Confirmed dead end for plain
                 device-scoped paths -- see TODO.md's Easy-Switch
                 findings -- kept for completeness/regression checks.)

  input_tracker  Use the agent's `/input_tracker/*` API, discovered via
                 `proxy` mode while assigning a keyboard-shortcut card
                 to a button slot in the UI:
                     SET       /input_tracker/start {"filter": [...]}
                     SUBSCRIBE /input_tracker/events
                     BROADCAST /input_tracker/events {"keyboard": {"isDown": true, ...}}
                 This is the first *confirmed working* SUBSCRIBE path
                 found so far, and it reports proper isDown state. This
                 mode lets you try other filter values (e.g. MOUSE) to
                 see whether mouse button state is reported the same way.

  proxy          Man-in-the-middle the UI <-> agent Unix socket. Renames
                 the real socket, binds a proxy at the original path,
                 and relays + logs every parsed frame in both
                 directions. You must fully quit Logi Options+ first,
                 start this, then relaunch Options+ so its UI reconnects
                 through the proxy. Open the Buttons configuration
                 screen for your device and press the physical button
                 while watching the log.

  ws             Connect to the WebSocket server reportedly listening on
                 127.0.0.1:59869 and log whatever frames arrive. Requires
                 `pip install websocket-client`.

Usage:
    python3 sniff_button_events.py devices
    python3 sniff_button_events.py subscribe --device dev00000000
    python3 sniff_button_events.py subscribe --path /devices/dev00000000/custom_path
    python3 sniff_button_events.py input_tracker --filter MOUSE
    python3 sniff_button_events.py proxy
    python3 sniff_button_events.py ws

All modes are read-only / observational with the exception of `proxy`,
which briefly relocates the agent's socket file for the duration of the
run (restored automatically on exit, including Ctrl-C).
"""
import argparse
import glob
import json
import os
import socket
import struct
import sys
import threading
import time
from datetime import datetime

SOCK_GLOB = '/tmp/logitech_kiros_agent-*'

# Candidate paths that might report button/control state changes.
# Educated guesses based on HID++ feature 0x1B04 (Special Keys and Mouse
# Buttons) terminology: getCidReporting / setCidReporting /
# divertedButtonsEvent / divertedRawMouseXYEvent. None of these are
# confirmed to exist -- that's what we're testing.
DEFAULT_SUBSCRIBE_PATHS = [
    '/devices/list',
    '/devices/{device}/button_event',
    '/devices/{device}/buttons',
    '/devices/{device}/cid_reporting',
    '/devices/{device}/diverted_buttons',
    '/devices/{device}/divertedButtonsEvent',
    '/devices/{device}/hidpp_event',
    '/devices/{device}/reprogrammable_keys',
    '/devices/{device}/special_keys',
    '/lps/emulate/trigger_easy_switch',
    '/v2/assignment',
]


def log(label, msg):
    ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
    print(f'[{ts}] [{label}] {msg}', flush=True)


def find_socket():
    socks = [s for s in glob.glob(SOCK_GLOB) if not s.endswith('.real')]
    return socks[0] if socks else None


def make_frame(obj):
    data = json.dumps(obj).encode()
    proto = b'json'
    inner = struct.pack('>I', len(proto)) + proto + struct.pack('>I', len(data)) + data
    return struct.pack('<I', len(inner)) + inner


# Some responses (e.g. depot/resource listings with embedded icons) can be
# several MB. Anything beyond this is assumed to be a genuine desync rather
# than a real frame.
MAX_FRAME_LEN = 64 * 1024 * 1024
# When desynced, only scan a bounded window for a plausible re-sync point
# instead of dropping one byte at a time across a multi-MB buffer (which is
# O(n^2) and can stall the relay thread for a long time).
MAX_RESYNC_WINDOW = 4096


class FrameStream:
    """Incrementally parses the agent's wire format from a byte stream
    that may arrive in arbitrarily chunked pieces, logging each complete
    frame as it becomes available. Used by both `subscribe` and `proxy`
    modes so partial reads/writes never get misparsed.

    This is purely for observation/logging: callers must forward the raw
    bytes to their destination themselves *before* calling feed(), so that
    a parsing bug or desync here can never delay or break the actual
    proxied connection.
    """

    def __init__(self, label, grep=None):
        self.label = label
        self.buf = b''
        self.grep = grep

    def feed(self, data):
        try:
            self._feed(data)
        except Exception as e:
            log(self.label, f'WARN parser crashed ({e!r}), dropping buffered data and continuing')
            self.buf = b''

    def _feed(self, data):
        self.buf += data
        while True:
            if len(self.buf) < 4:
                return
            total = struct.unpack_from('<I', self.buf, 0)[0]
            if total <= 0 or total > MAX_FRAME_LEN:
                if not self._resync():
                    return
                continue
            if len(self.buf) < 4 + total:
                return  # wait for more bytes
            inner = self.buf[4:4 + total]
            self.buf = self.buf[4 + total:]
            self._log_inner(inner)

    def _resync(self):
        """Look for a plausible frame-length prefix within a small window
        instead of shifting the whole buffer one byte at a time. Returns
        True if it found one and trimmed the buffer accordingly, False if
        it gave up (buffer cleared, caller should wait for more data)."""
        window = self.buf[:MAX_RESYNC_WINDOW]
        for offset in range(1, max(1, len(window) - 3)):
            total = struct.unpack_from('<I', window, offset)[0]
            if 0 < total <= MAX_FRAME_LEN:
                log(self.label, f'WARN desynced, resynced by dropping {offset} byte(s)')
                self.buf = self.buf[offset:]
                return True
        log(self.label, f'WARN desynced, no plausible frame found in next {len(window)} bytes; dropping buffer')
        self.buf = self.buf[len(window):]
        return False

    def _log_inner(self, inner):
        pos = 0
        if pos + 4 > len(inner):
            self._print(f'RAW (too short to contain proto len): {inner!r}')
            return
        plen = struct.unpack_from('>I', inner, pos)[0]
        pos += 4
        proto = inner[pos:pos + plen]
        pos += plen
        if pos + 4 > len(inner):
            self._print(f'RAW (truncated after proto {proto!r}): {inner!r}')
            return
        mlen = struct.unpack_from('>I', inner, pos)[0]
        pos += 4
        msg = inner[pos:pos + mlen]
        if proto == b'json':
            try:
                obj = json.loads(msg)
                self._print(json.dumps(obj, ensure_ascii=False))
                return
            except Exception:
                pass
        self._print(f'proto={proto!r} raw={msg!r}')

    def _print(self, text):
        if self.grep and self.grep.lower() not in text.lower():
            return
        log(self.label, text)


# --- devices mode -----------------------------------------------------

def cmd_devices(args):
    sock_path = find_socket()
    if not sock_path:
        print('ERROR: Logi Options+ agent socket not found. Is Options+ running?')
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(3)
    s.send(make_frame({'msg_id': '1', 'verb': 'GET', 'path': '/devices/list'}))

    stream = FrameStream('devices')
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            stream.feed(chunk)
    except socket.timeout:
        pass
    s.close()
    return 0


# --- subscribe mode -----------------------------------------------------

def cmd_subscribe(args):
    sock_path = find_socket()
    if not sock_path:
        print('ERROR: Logi Options+ agent socket not found. Is Options+ running?')
        return 1

    paths = args.path if args.path else DEFAULT_SUBSCRIBE_PATHS
    resolved = []
    for p in paths:
        if '{device}' in p:
            if not args.device:
                log('subscribe', f'skipping {p!r} (needs --device, run `devices` mode first)')
                continue
            p = p.replace('{device}', args.device)
        resolved.append(p)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(0.5)

    for i, path in enumerate(resolved):
        msg = {'msg_id': f'sub{i}', 'verb': 'SUBSCRIBE', 'path': path}
        log('subscribe', f'-> {json.dumps(msg)}')
        s.send(make_frame(msg))

    log('subscribe', f'Listening for {args.duration}s. Press/release the physical button now...')
    stream = FrameStream('subscribe<-agent', grep=args.grep)
    deadline = time.time() + args.duration
    try:
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
                if not chunk:
                    log('subscribe', 'agent closed the connection')
                    break
                stream.feed(chunk)
            except socket.timeout:
                continue
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    log('subscribe', 'done')
    return 0


# --- input_tracker mode -----------------------------------------------
#
# Discovered by proxying the UI <-> agent traffic while assigning a
# keyboard-shortcut card to a button slot in the Options+ UI:
#
#   SET       /input_tracker/start   {"filter": ["KEYBOARD"], "keyboardExclusive": true}
#   SUBSCRIBE /input_tracker/events
#   BROADCAST /input_tracker/events  {"keyboard": {"hidUsage": 48, "isDown": true, ...}}
#   SET       /input_tracker/stop
#   UNSUBSCRIBE /input_tracker/events
#
# This is the first confirmed-working SUBSCRIBE path in this whole
# exploration, and the event carries a proper `isDown` flag. It's unknown
# whether `filter: ["MOUSE"]` (or some other value) reports mouse button
# state -- that's what this mode is for.

def cmd_input_tracker(args):
    sock_path = find_socket()
    if not sock_path:
        print('ERROR: Logi Options+ agent socket not found. Is Options+ running?')
        return 1

    filters = args.filter or ['MOUSE']

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(0.5)

    start_payload = {'filter': filters}
    if args.keyboard_exclusive:
        start_payload['keyboardExclusive'] = True

    start_msg = {'msg_id': 'it_start', 'verb': 'SET', 'path': '/input_tracker/start', 'payload': start_payload}
    log('input_tracker', f'-> {json.dumps(start_msg)}')
    s.send(make_frame(start_msg))

    sub_msg = {'msg_id': 'it_sub', 'verb': 'SUBSCRIBE', 'path': '/input_tracker/events'}
    log('input_tracker', f'-> {json.dumps(sub_msg)}')
    s.send(make_frame(sub_msg))

    log('input_tracker', f'Listening for {args.duration}s. Press/release the physical button now...')
    stream = FrameStream('input_tracker<-agent', grep=args.grep)
    deadline = time.time() + args.duration
    try:
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
                if not chunk:
                    log('input_tracker', 'agent closed the connection')
                    break
                stream.feed(chunk)
            except socket.timeout:
                continue
    except KeyboardInterrupt:
        pass
    finally:
        try:
            s.send(make_frame({'msg_id': 'it_stop', 'verb': 'SET', 'path': '/input_tracker/stop'}))
            s.send(make_frame({'msg_id': 'it_unsub', 'verb': 'UNSUBSCRIBE', 'path': '/input_tracker/events'}))
            time.sleep(0.2)
        except OSError:
            pass
        s.close()
    log('input_tracker', 'done')
    return 0


# --- proxy (MITM) mode --------------------------------------------------

_restore_path = None


def _restore_real_socket():
    global _restore_path
    if _restore_path and os.path.exists(_restore_path):
        proxy_path = _restore_path[: -len('.real')]
        try:
            if os.path.exists(proxy_path):
                os.remove(proxy_path)
        except OSError:
            pass
        try:
            os.rename(_restore_path, proxy_path)
            log('proxy', f'restored real socket to {proxy_path}')
        except OSError as e:
            log('proxy', f'ERROR restoring real socket: {e}')
        _restore_path = None


def _relay(src, dst, stream, stop_event):
    try:
        while not stop_event.is_set():
            try:
                src.settimeout(0.5)
                data = src.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            # Forward the raw, untouched bytes *first* and immediately --
            # the proxied connection must never be delayed by (or broken
            # by a bug in) our own logging/parsing below.
            try:
                dst.sendall(data)
            except OSError:
                break
            # Now log/parse a copy, best-effort. FrameStream.feed() catches
            # its own exceptions, so this can never break the relay above.
            stream.feed(data)
    finally:
        stop_event.set()
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _handle_client(client_sock, real_sock_path, grep):
    try:
        agent_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        agent_sock.connect(real_sock_path)
    except OSError as e:
        log('proxy', f'ERROR connecting to real agent socket: {e}')
        client_sock.close()
        return

    log('proxy', 'client connected (UI <-> agent bridge established)')
    stop_event = threading.Event()
    ui_to_agent = FrameStream('UI->agent', grep=grep)
    agent_to_ui = FrameStream('agent->UI', grep=grep)

    t1 = threading.Thread(target=_relay, args=(client_sock, agent_sock, ui_to_agent, stop_event), daemon=True)
    t2 = threading.Thread(target=_relay, args=(agent_sock, client_sock, agent_to_ui, stop_event), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client_sock.close()
    agent_sock.close()
    log('proxy', 'client disconnected')


def cmd_proxy(args):
    global _restore_path

    sock_path = find_socket()
    if not sock_path:
        print('ERROR: Logi Options+ agent socket not found.')
        print('Make sure Logi Options+ (agent + UI) is running, then quit only the UI')
        print('(keep the background agent alive) before starting proxy mode -- or quit')
        print('both, start this script, and relaunch Options+ afterwards.')
        return 1

    real_path = sock_path + '.real'
    if os.path.exists(real_path):
        print(f'ERROR: {real_path} already exists -- a previous proxy run may not have')
        print('cleaned up correctly, or the agent itself created it. Investigate manually')
        print(f'(compare {sock_path} and {real_path}) before proceeding.')
        return 1

    os.rename(sock_path, real_path)
    _restore_path = real_path

    # Deliberately no custom SIGINT/SIGTERM handler here: Python's default
    # SIGINT handler already raises KeyboardInterrupt out of the blocking
    # accept() call below, which we catch. A previous version additionally
    # installed a signal handler that called _restore_real_socket() itself
    # -- that ran *concurrently* with the identical cleanup in the finally
    # block below, and the finally block's unconditional `os.remove(sock_path)`
    # ended up deleting the just-restored *real* agent socket after the
    # signal handler had already renamed it back. _restore_real_socket() is
    # idempotent (safe to call more than once), so we now only ever call it
    # from the single finally block.

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(10)
    log('proxy', f'listening at {sock_path} (real agent socket moved to {real_path})')
    log('proxy', 'now (re)launch Logi Options+ so its UI reconnects through this proxy.')
    log('proxy', 'open the Buttons configuration screen and press the physical button.')
    log('proxy', 'press Ctrl-C here when done.')

    try:
        while True:
            client_sock, _ = server.accept()
            threading.Thread(
                target=_handle_client, args=(client_sock, real_path, args.grep), daemon=True
            ).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        # _restore_real_socket() removes our proxy socket file itself (if
        # still present) before renaming the real agent socket back into
        # place -- do not also os.remove(sock_path) here, that would race
        # with (and could delete) the just-restored real socket.
        _restore_real_socket()
    return 0


# --- websocket probe -----------------------------------------------------

def cmd_ws(args):
    try:
        import websocket  # from `websocket-client`
    except ImportError:
        print('ERROR: this mode needs the `websocket-client` package.')
        print('Install with: pip install websocket-client')
        return 1

    url = f'ws://127.0.0.1:{args.port}'
    log('ws', f'connecting to {url} ...')

    def on_message(ws, message):
        log('ws<-', message)

    def on_error(ws, error):
        log('ws', f'ERROR {error}')

    def on_open(ws):
        log('ws', f'connected. Listening for {args.duration}s -- press the physical button now.')

        def _closer():
            time.sleep(args.duration)
            ws.close()

        threading.Thread(target=_closer, daemon=True).start()

    ws = websocket.WebSocketApp(url, on_message=on_message, on_error=on_error, on_open=on_open)
    ws.run_forever()
    log('ws', 'done')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='mode', required=True)

    p_devices = sub.add_parser('devices', help='dump /devices/list to find device IDs')
    p_devices.set_defaults(func=cmd_devices)

    p_sub = sub.add_parser('subscribe', help='SUBSCRIBE to candidate paths and listen passively')
    p_sub.add_argument('--device', help='device id (from `devices` mode) to substitute into {device} paths')
    p_sub.add_argument('--path', action='append', help='override candidate path(s) (repeatable)')
    p_sub.add_argument('--duration', type=int, default=60, help='seconds to listen (default: 60)')
    p_sub.add_argument('--grep', help='only print lines containing this substring (case-insensitive)')
    p_sub.set_defaults(func=cmd_subscribe)

    p_it = sub.add_parser('input_tracker', help="use the agent's live input tracker (as used by the UI's shortcut-capture dialog) and listen for events")
    p_it.add_argument('--filter', action='append', help='filter value(s) for /input_tracker/start (repeatable, e.g. --filter MOUSE). Default: MOUSE')
    p_it.add_argument('--keyboard-exclusive', action='store_true', help='set keyboardExclusive:true like the UI does for keyboard shortcuts')
    p_it.add_argument('--duration', type=int, default=30, help='seconds to listen (default: 30)')
    p_it.add_argument('--grep', help='only print lines containing this substring (case-insensitive)')
    p_it.set_defaults(func=cmd_input_tracker)

    p_proxy = sub.add_parser('proxy', help='MITM proxy between the Options+ UI and the agent socket')
    p_proxy.add_argument('--grep', help='only print lines containing this substring (case-insensitive)')
    p_proxy.set_defaults(func=cmd_proxy)

    p_ws = sub.add_parser('ws', help='probe the reported WebSocket server')
    p_ws.add_argument('--port', type=int, default=59869)
    p_ws.add_argument('--duration', type=int, default=60)
    p_ws.set_defaults(func=cmd_ws)

    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
