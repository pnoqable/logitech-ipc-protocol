"""
Query the Logi Options+ agent on Windows via named pipe.

Shows connected devices with HID paths, connection types, and host channels.
Same wire protocol as the Unix socket on macOS.

Usage:
    python query_agent_windows.py
    python query_agent_windows.py --reset-flow

Requires:
    - Logi Options+ installed and running
    - pywin32: pip install pywin32
"""
import struct, json, os, sys, time

try:
    import win32file, win32pipe, pywintypes
except ModuleNotFoundError:
    print("ERROR: pywin32 is required. Install it with: python -m pip install pywin32")
    raise SystemExit(1)

def find_pipe():
    pipes = [p for p in os.listdir(r'\\.\pipe') if p.startswith('logitech_kiros_agent')]
    return rf'\\.\pipe\{pipes[0]}' if pipes else None

def make_frame(obj):
    data = json.dumps(obj).encode()
    proto = b'json'
    inner = struct.pack('>I', len(proto)) + proto + struct.pack('>I', len(data)) + data
    return struct.pack('<I', len(inner)) + inner

def parse_responses(data):
    results = []
    pos = 0
    while pos + 4 <= len(data):
        total = struct.unpack_from('<I', data, pos)[0]
        if total > 1000000 or pos + 4 + total > len(data): break
        inner = data[pos+4:pos+4+total]
        pos += 4 + total
        ipos = 0
        if ipos + 4 > len(inner): continue
        plen = struct.unpack_from('>I', inner, ipos)[0]
        ipos += 4
        proto = inner[ipos:ipos+plen]
        ipos += plen
        if ipos + 4 > len(inner): continue
        mlen = struct.unpack_from('>I', inner, ipos)[0]
        ipos += 4
        msg = inner[ipos:ipos+mlen]
        if proto == b'json':
            try: results.append(json.loads(msg))
            except: pass
    return results

def query(handle, msg):
    win32file.WriteFile(handle, make_frame(msg))
    time.sleep(0.2)
    hr, data = win32file.ReadFile(handle, 65536)
    return parse_responses(data)

if __name__ == '__main__':
    reset_flow = sys.argv[1:] == ['--reset-flow']
    if sys.argv[1:] and not reset_flow:
        print("Usage: python query_agent_windows.py [--reset-flow]")
        exit(1)

    pipe_path = find_pipe()
    if not pipe_path:
        print("ERROR: Logi Options+ agent pipe not found")
        exit(1)

    handle = win32file.CreateFile(
        pipe_path,
        win32file.GENERIC_READ | win32file.GENERIC_WRITE,
        0, None, win32file.OPEN_EXISTING, 0, None
    )
    win32pipe.SetNamedPipeHandleState(handle, win32pipe.PIPE_READMODE_BYTE, None, None)

    # Handshake
    win32file.WriteFile(handle, make_frame({'msg_id': '1', 'verb': 'GET', 'path': '/permissions'}))
    time.sleep(0.5)
    try:
        win32file.ReadFile(handle, 65536)
    except pywintypes.error:
        pass

    # Query devices
    responses = query(handle, {'msg_id': '2', 'verb': 'GET', 'path': '/devices/list'})

    for r in responses:
        if 'payload' not in r:
            continue
        devices = r['payload'].get('deviceInfos', [])
        for d in devices:
            if d.get('connectionType') == 'VIRTUAL':
                continue
            ifaces = d.get('activeInterfaces', [])
            path = ifaces[0]['path'] if ifaces else d.get('path', '')
            conn = ifaces[0].get('connectionType', d.get('connectionType', '')) if ifaces else d.get('connectionType', '')
            host = ifaces[0].get('hostChannel', '') if ifaces else ''
            print(f"{d['displayName']}")
            print(f"  ID:         {d['id']}")
            print(f"  PID:        {d.get('pid', ''):#06x}")
            print(f"  Serial:     {d.get('unitId') or d.get('deviceSerialNumber', '')}")
            print(f"  Type:       {d.get('deviceType', '')}")
            print(f"  Connection: {conn}")
            print(f"  Connected:  {d.get('connected', '')}")
            print(f"  Host:       {host}")
            print(f"  Path:       {path}")

            if d.get('connected') and d.get('deviceType') in ('MOUSE', 'KEYBOARD'):
                host_responses = query(handle, {
                    'msg_id': f"host-{d['id']}",
                    'verb': 'GET',
                    'path': f"/change_host/{d['id']}/host",
                })
                for host_response in host_responses:
                    if host_response.get('result', {}).get('code') == 'SUCCESS':
                        print(f"  HID++ ChangeHost: {json.dumps(host_response.get('payload', {}))}")
                    else:
                        print(f"  HID++ ChangeHost: {host_response.get('result', {}).get('code', 'NO_RESPONSE')}")
            print()

            if not d.get('connected') or not d.get('capabilities', {}).get('flow'):
                continue
            if reset_flow:
                print("  Resetting Flow configuration only (no pairing or host switch) ...")
                reset_responses = query(handle, {
                    'msg_id': f"flow-{d['id']}-reset",
                    'verb': 'SET',
                    'path': f"/flow/{d['id']}/reset",
                })
                for reset_response in reset_responses:
                    print(f"    Reset: {reset_response.get('result', {}).get('code', 'NO_RESPONSE')}")
            print("  Flow:")
            for label, suffix in [
                ('Config', 'config'),
                ('Location', 'device_location'),
                ('Peers', 'device_peer_status'),
            ]:
                flow_responses = query(handle, {
                    'msg_id': f"flow-{d['id']}-{suffix}",
                    'verb': 'GET',
                    'path': f"/flow/{d['id']}/{suffix}",
                })
                for flow_response in flow_responses:
                    if flow_response.get('result', {}).get('code') == 'SUCCESS':
                        print(f"    {label}: {json.dumps(flow_response.get('payload', {}))}")
                    else:
                        print(f"    {label}: {flow_response.get('result', {}).get('code', 'NO_RESPONSE')}")
            print()

    handle.Close()
