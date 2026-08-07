#!/usr/bin/env python3
"""Print the read-only Flow channel mapping for connected Flow-capable devices.

Usage: python3 logi_flow_snapshot.py
"""
import glob
import json
import socket
import struct
import sys

SOCKET_GLOB = "/tmp/logitech_kiros_agent-*"


def make_frame(message):
    payload = json.dumps(message).encode()
    protocol = b"json"
    inner = struct.pack(">I", len(protocol)) + protocol + struct.pack(">I", len(payload)) + payload
    return struct.pack("<I", len(inner)) + inner


def receive_json(sock):
    buffer = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) < 4:
            continue
        length = struct.unpack_from("<I", buffer)[0]
        if len(buffer) < length + 4:
            continue
        frame = buffer[4:length + 4]
        protocol_length = struct.unpack_from(">I", frame)[0]
        offset = 4 + protocol_length
        message_length = struct.unpack_from(">I", frame, offset)[0]
        if frame[4:4 + protocol_length] != b"json":
            return None
        return json.loads(frame[offset + 4:offset + 4 + message_length])


def request(sock, message):
    sock.sendall(make_frame(message))
    return receive_json(sock)


def main():
    paths = [path for path in glob.glob(SOCKET_GLOB) if not path.endswith(".real")]
    if not paths:
        print("ERROR: Logi Options+ agent socket not found. Is Options+ running?", file=sys.stderr)
        return 1

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(3)
        sock.connect(paths[0])
        devices_response = request(sock, {"msg_id": "devices", "verb": "GET", "path": "/devices/list"})
        devices = devices_response.get("payload", {}).get("deviceInfos", []) if devices_response else []
        flow_devices = [
            device for device in devices
            if device.get("connected") and device.get("capabilities", {}).get("flow")
        ]
        if not flow_devices:
            print("No connected Flow-capable device reported by the agent.", file=sys.stderr)
            return 1

        result = []
        for device in flow_devices:
            device_id = device["id"]
            item = {"id": device_id, "name": device.get("displayName")}
            for key, suffix in [
                ("config", "config"),
                ("location", "device_location"),
                ("peers", "device_peer_status"),
            ]:
                response = request(sock, {
                    "msg_id": f"{device_id}-{key}", "verb": "GET", "path": f"/flow/{device_id}/{suffix}",
                })
                item[key] = response.get("payload") if response and response.get("result", {}).get("code") == "SUCCESS" else response
            result.append(item)
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
