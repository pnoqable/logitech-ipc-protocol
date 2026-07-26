#!/usr/bin/env python3
"""
Parst eine Apple PacketLogger (.pklg) Datei komplett selbst (kein Wireshark/tshark
noetig), extrahiert alle ATT-Pakete (Write Command / Handle Value Notification) auf
dem BLE-Kanal und decodiert dabei HID++ 2.0 Feature 0x1B04 (SpecialKeysMseButtons)
Aufrufe, falls vorhanden.

Erkenntnisse (26.07.2026, Capture "MX Anywhere 3 Write.pklg"):
- .pklg-Recordformat: uint32 LE reclen, dann Body = uint32 LE ts_sec, uint32 LE
  ts_usec, 1 Byte type, dann payload. type 0x00=HCI Cmd,0x01=HCI Event,
  0x02=ACL TX (Host->Controller/"SEND"), 0x03=ACL RX ("RECV"), 0xFC/0xFD=Notiz-Text
  (z.B. "Product: ...", "Address: ...").
- ACL-Payload: HCI-ACL-Header (2 Byte handle+flags LE, 2 Byte L2CAP-Gesamtlaenge LE),
  dann L2CAP-Header (2 Byte Laenge LE, 2 Byte CID LE). ATT-Kanal = CID 0x0004.
- ATT-PDU: 1 Byte Opcode, dann bei Write Command (0x52) / Handle Value Notification
  (0x1B): 2 Byte Attribute-Handle (LE), dann die eigentlichen Nutzdaten.
- **BLE-HID++-Framing (bestaetigt, bit-genau gegen die offizielle x1b04-Spec
  https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html geprueft):**
  KEIN Report-ID-Marker (0x10/0x11) und KEIN devIndex-Byte wie bei USB! Format ist
  einfach:
      [featureIndex] [funcId<<4 | swId] [param0] [param1] ...
  Notifications werden vom Geraet immer auf 19 Byte nullgepolstert (=20-Byte-
  Long-Report minus Marker-Byte). Requests sind ungepolstert (nur so viele Bytes wie
  noetig).
- MX Anywhere 3: featureIndex 0x09 = Feature 0x1B04 (identisch mit dem per USB-Dongle
  ermittelten Wert, siehe Abschnitt 3.2 im Handoff-Dokument).
- Options+ nutzt swId=0xC (konstant) auf dem BLE-Kanal.
- Im Capture bestaetigt: getCidReporting(cid=80/81)+setCidReporting(cid=80/81,
  alle valid-Flags=0) fuer Left/Right - decodiert exakt passend zur Spec (divert=0,
  persist=0, rawXY=0, remap=0, wie erwartet fuer nicht-divertable CIDs).
- Noch nicht erfasst: CID 83 (Back) / 86 (Forward) getCidReporting/setCidReporting
  mit divert=1, sowie ein echtes divertedButtonsEvent (laut Spec: event0, kein
  regulaerer funcId/swId-Response, sondern Notification mit bis zu 4 CIDs).

Nutzung:
    python3 ble_pklg_decode.py "MX Anywhere 3 Write.pklg"
    python3 ble_pklg_decode.py "MX Anywhere 3 Write.pklg" --feature 0x09
    python3 ble_pklg_decode.py "MX Anywhere 3 Write.pklg" --raw   # nur rohe ATT-Zeilen
"""
import struct
import sys
import datetime
import argparse

CID_NAMES = {
    80: "Left", 81: "Right", 82: "Middle", 83: "Back", 86: "Forward",
    196: "SmartShift", 215: "virtual", 195: "AppSwitchGesture",
}

ATT_OPCODES = {
    0x01: "Error Response", 0x02: "Exchange MTU Request",
    0x03: "Exchange MTU Response", 0x04: "Find Information Request",
    0x05: "Find Information Response", 0x08: "Read By Type Request",
    0x09: "Read By Type Response", 0x0A: "Read Request",
    0x0B: "Read Response", 0x10: "Read By Group Type Request",
    0x11: "Read By Group Type Response", 0x12: "Write Request",
    0x13: "Write Response", 0x16: "Prepare Write Request",
    0x17: "Prepare Write Response", 0x18: "Execute Write Request",
    0x19: "Execute Write Response", 0x1B: "Handle Value Notification",
    0x1D: "Handle Value Indication", 0x1E: "Handle Value Confirmation",
    0x52: "Write Command",
}

# ATT opcodes, die ein 2-Byte Attribute-Handle vor den eigentlichen Nutzdaten haben
OPCODES_WITH_HANDLE = {0x12, 0x13, 0x1B, 0x1D, 0x52}


def parse_pklg(path):
    data = open(path, "rb").read()
    off = 0
    records = []
    while off < len(data):
        if off + 4 > len(data):
            break
        (reclen,) = struct.unpack("<I", data[off:off + 4])
        if reclen == 0:
            break
        body = data[off + 4:off + 4 + reclen]
        if len(body) >= 9:
            ts_sec, ts_usec = struct.unpack("<II", body[0:8])
            ptype = body[8]
            payload = body[9:]
            records.append((ts_sec, ts_usec, ptype, payload))
        off += 4 + reclen
    return records


def parse_acl(payload):
    if len(payload) < 4:
        return None
    handle_flags, acl_len = struct.unpack("<HH", payload[0:4])
    handle = handle_flags & 0x0FFF
    l2_payload = payload[4:4 + acl_len]
    if len(l2_payload) < 4:
        return None
    l2_len, cid = struct.unpack("<HH", l2_payload[0:4])
    att_payload = l2_payload[4:4 + l2_len]
    return handle, cid, att_payload


def decode_x1b04(funcswid, params, direction):
    """Decodiert Feature 0x1B04 Aufrufe bit-genau nach lekensteyn-Spec."""
    fid = funcswid >> 4
    swid = funcswid & 0xF
    if fid == 0 and direction == "RECV" and len(params) >= 2:
        # koennte divertedButtonsEvent sein (bis zu 4 CIDs, BE16 je Wert, swId=0)
        cids = []
        for i in range(0, min(len(params), 8), 2):
            if i + 1 >= len(params):
                break
            cid = (params[i] << 8) | params[i + 1]
            if cid == 0:
                break
            cids.append(f"{cid}({CID_NAMES.get(cid, '?')})")
        if cids:
            return f"divertedButtonsEvent -> pressed: {', '.join(cids)}"
        return "divertedButtonsEvent -> (keine Tasten gedrueckt / alle losgelassen)"
    if fid == 0 and direction == "SEND" and len(params) >= 1:
        return f"getCount() request"
    if fid == 1:
        if direction == "SEND":
            return f"getCidInfo(index={params[0]})"
        cid = (params[0] << 8) | params[1]
        tid = (params[2] << 8) | params[3]
        flags = params[4]
        pos = params[5]
        group = params[6]
        gmask = params[7] if len(params) > 7 else None
        return (f"-> cid={cid}({CID_NAMES.get(cid, '?')}) tid={tid} "
                f"mouse={flags & 1} fkey={(flags >> 1) & 1} hotkey={(flags >> 2) & 1} "
                f"fntog={(flags >> 3) & 1} reprog={(flags >> 4) & 1} "
                f"divert={(flags >> 5) & 1} persist={(flags >> 6) & 1} "
                f"virtual={(flags >> 7) & 1} pos={pos} group={group} gmask={gmask}")
    if fid == 2:
        cid = (params[0] << 8) | params[1]
        if direction == "SEND":
            return f"getCidReporting(cid={cid}={CID_NAMES.get(cid, '?')})"
        flags = params[2]
        remap = (params[3] << 8) | params[4]
        return (f"-> cid={cid}({CID_NAMES.get(cid, '?')}) divert={flags & 1} "
                f"persist={(flags >> 2) & 1} rawXY={(flags >> 4) & 1} remap={remap}")
    if fid == 3:
        cid = (params[0] << 8) | params[1]
        flags = params[2]
        remap = (params[3] << 8) | params[4]
        tag = "SET" if direction == "SEND" else "ACK"
        return (f"{tag} setCidReporting(cid={cid}({CID_NAMES.get(cid, '?')}) "
                f"divert={flags & 1}/valid={(flags >> 1) & 1} "
                f"persist={(flags >> 2) & 1}/valid={(flags >> 3) & 1} "
                f"rawXY={(flags >> 4) & 1}/valid={(flags >> 5) & 1} remap={remap})")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pklg_path")
    ap.add_argument("--feature", type=lambda x: int(x, 0), default=None,
                     help="Nur diesen featureIndex decodieren, z.B. 0x09 fuer 0x1B04")
    ap.add_argument("--raw", action="store_true", help="Nur rohe ATT-Zeilen ausgeben")
    args = ap.parse_args()

    records = parse_pklg(args.pklg_path)
    for ts_sec, ts_usec, ptype, payload in records:
        if ptype not in (2, 3):
            continue
        parsed = parse_acl(payload)
        if not parsed:
            continue
        handle, cid, att = parsed
        if cid != 0x0004 or len(att) == 0:
            continue
        opcode = att[0]
        opname = ATT_OPCODES.get(opcode, f"0x{opcode:02x}")
        direction = "SEND" if ptype == 2 else "RECV"
        t = datetime.datetime.fromtimestamp(ts_sec + ts_usec / 1e6)
        tstr = t.strftime("%H:%M:%S.%f")[:-3]
        rest = att[1:]

        if opcode in OPCODES_WITH_HANDLE and len(rest) >= 2:
            att_handle = rest[0] | (rest[1] << 8)
            value = rest[2:]
        else:
            att_handle = None
            value = rest

        if args.raw:
            print(f"{tstr} {direction} conn=0x{handle:04x} {opname:28s} "
                  f"att_handle={att_handle} value={value.hex()}")
            continue

        if value and len(value) >= 2:
            feat = value[0]
            funcswid = value[1]
            params = list(value[2:])
            if args.feature is not None and feat != args.feature:
                continue
            decoded = decode_x1b04(funcswid, params, direction) if feat == 0x09 else None
            extra = f"  => {decoded}" if decoded else ""
            print(f"{tstr} {direction} {opname:28s} feat=0x{feat:02x} "
                  f"funcId={funcswid >> 4} swId={funcswid & 0xF:x} "
                  f"raw={value.hex()}{extra}")


if __name__ == "__main__":
    main()
