#!/usr/bin/env python3
"""Print a compact, read-only Logi Options+ device/host snapshot on macOS.

The agent's /devices/list response is large. This script preserves the fields
needed to compare Flow hosts and re-pairing states without sending any SET
request or accessing HID++ directly.

Usage: python3 logi_device_snapshot.py
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


def read_frames(sock):
    buffer = b""
    while True:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            return
        if not chunk:
            return
        buffer += chunk
        while len(buffer) >= 4:
            length = struct.unpack_from("<I", buffer)[0]
            if length <= 0 or len(buffer) < length + 4:
                break
            frame, buffer = buffer[4:length + 4], buffer[length + 4:]
            protocol_length = struct.unpack_from(">I", frame)[0]
            offset = 4 + protocol_length
            message_length = struct.unpack_from(">I", frame, offset)[0]
            message = frame[offset + 4:offset + 4 + message_length]
            if frame[4:4 + protocol_length] == b"json":
                yield json.loads(message)


def snapshot(device):
    interface = (device.get("activeInterfaces") or [{}])[0]
    capabilities = device.get("capabilities", {})
    return {
        "id": device.get("id"),
        "name": device.get("displayName"),
        "type": device.get("deviceType"),
        "model": device.get("modelId"),
        "firmware": device.get("firmwareVersion"),
        "connected": device.get("connected"),
        "connection": interface.get("connectionType", device.get("connectionType")),
        "hostChannel": interface.get("hostChannel"),
        "udid": device.get("udid") or interface.get("udid"),
        "hashedSerialNumber": device.get("hashedSerialNumber") or interface.get("hashedSerialNumber"),
        "flow": capabilities.get("flow"),
        "hostInfos": capabilities.get("hostInfos"),
        "hostRemovalSupport": capabilities.get("hostRemovalSupport"),
    }


def main():
    paths = [path for path in glob.glob(SOCKET_GLOB) if not path.endswith(".real")]
    if not paths:
        print("ERROR: Logi Options+ agent socket not found. Is Options+ running?", file=sys.stderr)
        return 1

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(3)
        sock.connect(paths[0])
        sock.sendall(make_frame({"msg_id": "snapshot", "verb": "GET", "path": "/devices/list"}))
        for response in read_frames(sock):
            devices = response.get("payload", {}).get("deviceInfos")
            if devices is None:
                continue
            physical_devices = [device for device in devices if device.get("connectionType") != "VIRTUAL"]
            print(json.dumps([snapshot(device) for device in physical_devices], indent=2))
            return 0

    print("ERROR: /devices/list returned no device list.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
