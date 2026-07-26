#!/usr/bin/env python3
"""Ad-hoc test: try to enable HID++ CID divert reporting via the IPC socket,
using the SpecialKeysDivertRequest message found in the agent binary's
embedded protobuf descriptors, and see if /input/event (or similar) then
broadcasts button press/release for the diverted CIDs (Back=83, Forward=86)."""
import json
import socket
import sys
import time

sys.path.insert(0, '.')
from sniff_button_events import find_socket, make_frame, FrameStream, log  # noqa: E402

DEVICE_ID = 'dev00000041'  # MX Anywhere 3S, re-check with `devices` mode if changed

sock_path = find_socket()
if not sock_path:
    print('ERROR: agent socket not found')
    sys.exit(1)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(1.0)


def send(msg):
    log('divert', f'-> {json.dumps(msg)}')
    s.send(make_frame(msg))


def recv_for(seconds):
    stream = FrameStream('divert<-agent', grep=None)
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
            if not chunk:
                log('divert', 'agent closed connection')
                break
            stream.feed(chunk)
        except socket.timeout:
            continue


# --- Try several path/payload variants for enabling divert ---
variants = [
    ('/devices/special_keys_divert_state/configure',
     {'controlIdsList': [{'controlId': 83, 'divert': True}, {'controlId': 86, 'divert': True}]}),
    (f'/devices/{DEVICE_ID}/special_keys_divert_state/configure',
     {'controlIdsList': [{'controlId': 83, 'divert': True}, {'controlId': 86, 'divert': True}]}),
    ('/devices/special_keys_divert_state/configure',
     {'deviceId': DEVICE_ID, 'controlIdsList': [{'controlId': 83, 'divert': True}, {'controlId': 86, 'divert': True}]}),
]

for i, (path, payload) in enumerate(variants):
    msg = {'msg_id': f'divert_{i}', 'verb': 'SET', 'path': path, 'payload': payload}
    send(msg)
    recv_for(1.0)
    print('---')

# Also subscribe to a few candidate broadcast paths, just in case any of the
# above SET calls succeeded and start pushing events.
for p in ['/input/event', '/devices/special_keys_divert_state/configure',
          '/inputxy_event', '/lps/event/button', '/lps/input']:
    send({'msg_id': f'sub_{p}', 'verb': 'SUBSCRIBE', 'path': p})
recv_for(2.0)

log('divert', 'done with initial probing')
s.close()
