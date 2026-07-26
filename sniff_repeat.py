#!/usr/bin/env python3
"""Ad-hoc test: does /input_tracker/start need to be re-sent after every event
to get further mouse button events, or does it keep streaming on its own?"""
import json
import socket
import sys
import time

sys.path.insert(0, '.')
from sniff_button_events import find_socket, make_frame, FrameStream, log  # noqa: E402

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 60
RESTART_AFTER_EVENT = '--restart' in sys.argv
FILTER = 'MOUSE_BUTTON'
for i, a in enumerate(sys.argv):
    if a == '--filter' and i + 1 < len(sys.argv):
        FILTER = sys.argv[i + 1]

sock_path = find_socket()
if not sock_path:
    print('ERROR: agent socket not found')
    sys.exit(1)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(0.5)


def send_start():
    msg = {'msg_id': f'it_start_{int(time.time()*1000)}', 'verb': 'SET',
           'path': '/input_tracker/start', 'payload': {'filter': [FILTER]}}
    log('repeat', f'-> {json.dumps(msg)}')
    s.send(make_frame(msg))


send_start()
sub_msg = {'msg_id': 'it_sub', 'verb': 'SUBSCRIBE', 'path': '/input_tracker/events'}
log('repeat', f'-> {json.dumps(sub_msg)}')
s.send(make_frame(sub_msg))

log('repeat', f'Listening for {DURATION}s (restart_after_event={RESTART_AFTER_EVENT}). Click the left mouse button repeatedly...')

seen_events = []


def on_frame(obj):
    if obj.get('verb') == 'BROADCAST' and obj.get('path') == '/input_tracker/events':
        seen_events.append(obj)
        if RESTART_AFTER_EVENT:
            time.sleep(0.05)
            send_start()


stream = FrameStream('repeat<-agent', grep=None)
# monkey-patch: after each feed, inspect stream's internal parsed objects
orig_feed = stream.feed


def feed_and_hook(data):
    orig_feed(data)


stream.feed = feed_and_hook

deadline = time.time() + DURATION
try:
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
            if not chunk:
                log('repeat', 'agent closed connection')
                break
            stream.feed(chunk)
            # crude: re-parse chunk ourselves to detect broadcast events for the restart logic
            try:
                text = chunk.decode('utf-8', errors='ignore')
            except Exception:
                text = ''
            if '"verb": "BROADCAST"' in text and '/input_tracker/events' in text:
                seen_events.append(text)
                if RESTART_AFTER_EVENT:
                    time.sleep(0.05)
                    send_start()
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

log('repeat', f'done. total broadcast events seen: {len(seen_events)}')
