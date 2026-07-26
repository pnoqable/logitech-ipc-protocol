"""
Raw HID++ 2.0 access to the Logitech Unifying dongle: find the MX Anywhere 3's
thumb buttons (CID 83 = Back, CID 86 = Forward), divert them to software, and
decode incoming divertedButtonsEvent notifications as clean Down/Up events.

Byte-format reference (feature 0x1B04, "Special Keys and Mouse Buttons"):
    https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
General HID++ 2.0 short/long report framing verified against the Solaar
project's base.py (https://github.com/pwr-Solaar/Solaar).

Usage:
    DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 hidpp_thumb_buttons.py

Requires: brew install hidapi; .venv/bin/pip install hid
"""
import hid
import sys
import time
import signal

VENDOR_ID = 0x046D
PRODUCT_ID = 0xC52B
USAGE_PAGE = 0xFF00  # vendor-specific HID++ raw channel

ROOT_FEATURE_INDEX = 0x00
FEATURE_ID_1B04 = 0x1B04

# HID++ software ID for our own requests (nonzero, low nibble only).
# Known IDs in use by other tools: 0x07 OpenRGB, 0x0A LGSTrayEx, 0x0B Solaar,
# 0x0D Logitech G HUB, 0x0F Logitech firmware. Pick something unused.
SW_ID = 0x05

CID_NAMES = {
    80: "Left",
    81: "Right",
    82: "Middle",
    83: "Back",
    86: "Forward",
    196: "SmartShift",
}

# CIDs we want to divert to software (Back, Forward).
DIVERT_CIDS = (83, 86)

READ_TIMEOUT_MS = 1000


def find_hidpp_path():
    """Locate the HID++ raw channel (usage_page 0xFF00) of the Unifying dongle.

    The path changes every session (it's an IOKit session id), so this must
    be re-discovered on every run, never hardcoded.
    """
    for d in hid.enumerate(VENDOR_ID, PRODUCT_ID):
        if d.get("usage_page") == USAGE_PAGE:
            return d["path"]
    return None


def drain(h):
    """Discard any stale/queued input reports sitting in the buffer."""
    while True:
        stale = h.read(32, timeout=0)
        if not stale:
            return


def short_report(devidx, featidx, funcid, swid, d0=0, d1=0, d2=0):
    """Build a 7-byte short HID++ report: 0x10, devIdx, featIdx, funcId<<4|swId, d0, d1, d2."""
    fsw = ((funcid & 0x0F) << 4) | (swid & 0x0F)
    return bytes([0x10, devidx, featidx, fsw, d0 & 0xFF, d1 & 0xFF, d2 & 0xFF])


def long_report(devidx, featidx, funcid, swid, params=b""):
    """Build a 20-byte long HID++ report: 0x11, devIdx, featIdx, funcId<<4|swId, up to 16 param bytes."""
    fsw = ((funcid & 0x0F) << 4) | (swid & 0x0F)
    params = params + bytes(16 - len(params))
    return bytes([0x11, devidx, featidx, fsw]) + params


def call(h, devidx, featidx, funcid, swid, d0=0, d1=0, d2=0, timeout_ms=READ_TIMEOUT_MS,
         long_params=None):
    """Send a request and wait for the matching reply, ignoring unrelated notifications.

    Returns (status, frame) where status is one of:
      'ok'      - success reply,        frame[4:] holds the return params
      'err2.0'  - HID++ 2.0 error,      frame[5] holds the error code
      'err1.0'  - HID++ 1.0 error       (e.g. device index not connected), frame[5] holds the error code
      'timeout' - no matching reply within timeout_ms
    """
    fsw = ((funcid & 0x0F) << 4) | (swid & 0x0F)
    if long_params is not None:
        frame = long_report(devidx, featidx, funcid, swid, long_params)
    else:
        frame = short_report(devidx, featidx, funcid, swid, d0, d1, d2)

    drain(h)
    h.write(frame)

    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        remaining_ms = max(1, int((deadline - time.time()) * 1000))
        resp = h.read(32, timeout=remaining_ms)
        if not resp:
            continue
        if resp[1] != devidx:
            continue  # reply/notification for a different device index
        if resp[2] == featidx and resp[3] == fsw:
            return "ok", resp
        if resp[2] == 0xFF and resp[3] == featidx and resp[4] == fsw:
            return "err2.0", resp
        if resp[2] == 0x8F and resp[3] == featidx and resp[4] == fsw:
            return "err1.0", resp
        # else: unrelated notification/reply, keep waiting
    return "timeout", None


def get_feature_index(h, devidx, feature_id):
    """Root.GetFeature(feature_id) on the given device index.

    Returns the feature index, or None if the device doesn't exist / doesn't
    support the feature.
    """
    status, resp = call(
        h, devidx, ROOT_FEATURE_INDEX, funcid=0x00, swid=SW_ID,
        d0=(feature_id >> 8) & 0xFF, d1=feature_id & 0xFF, d2=0x00,
    )
    if status == "ok":
        featidx = resp[4]
        return featidx if featidx != 0 else None
    return None


def get_cid_table(h, devidx, featidx):
    """getCount() + getCidInfo(i) for i in range(count). Returns list of (cid, flags)."""
    status, resp = call(h, devidx, featidx, funcid=0x00, swid=SW_ID)  # getCount
    if status != "ok":
        return []
    count = resp[4]

    entries = []
    for i in range(count):
        status, resp = call(h, devidx, featidx, funcid=0x01, swid=SW_ID, d0=i)  # getCidInfo
        if status != "ok":
            continue
        p = resp[4:13]
        cid = (p[0] << 8) | p[1]
        flags = p[4]
        entries.append((cid, flags))
    return entries


def find_mx_anywhere_3(h):
    """Try device indices 0x01-0x06, return (devidx, featidx) of the device whose
    x1b04 CID table contains Back/Forward/Middle (i.e. the mouse, not the keyboard
    also hanging off the same dongle).
    """
    for devidx in range(1, 7):
        featidx = get_feature_index(h, devidx, FEATURE_ID_1B04)
        if featidx is None:
            continue
        cids = {cid for cid, _flags in get_cid_table(h, devidx, featidx)}
        print(f"  device index 0x{devidx:02X}: feature 0x1B04 @ index 0x{featidx:02X}, "
              f"CIDs = {sorted(cids)}")
        if {82, 83, 86}.issubset(cids):
            return devidx, featidx
    return None, None


def set_cid_reporting(h, devidx, featidx, cid, divert):
    """setCidReporting(cid, divert=divert, dvalid=1). Uses a long report since the
    request needs 5 param bytes (cid msb/lsb, flags, remap msb/lsb), more than the
    3 bytes a short report can carry.
    """
    flags = (1 if divert else 0) | 0x02  # bit0=divert, bit1=dvalid
    params = bytes([(cid >> 8) & 0xFF, cid & 0xFF, flags, 0x00, 0x00])
    status, resp = call(h, devidx, featidx, funcid=0x03, swid=SW_ID, long_params=params)
    return status, resp


def decode_diverted_buttons_event(resp):
    """Decode a divertedButtonsEvent frame into the list of currently pressed CIDs."""
    cids = []
    payload = resp[4:12]  # 4 x 2-byte CIDs
    for i in range(4):
        cid = (payload[2 * i] << 8) | payload[2 * i + 1]
        if cid != 0:
            cids.append(cid)
    return cids


def cid_name(cid):
    return CID_NAMES.get(cid, f"CID {cid}")


def main():
    print("Suche HID++-Rohkanal des Unifying-Dongles ...")
    path = find_hidpp_path()
    if not path:
        print("Kein HID++-Interface (usage_page 0xFF00) gefunden. Ist der Dongle eingesteckt?")
        sys.exit(1)
    print(f"  gefunden: path={path}")

    h = hid.Device(path=path)
    print(f"  geoeffnet: {h.manufacturer} / {h.product}")

    print("\nSuche MX Anywhere 3 unter Device-Indizes 0x01-0x06 ...")
    devidx, featidx = find_mx_anywhere_3(h)
    if devidx is None:
        print("MX Anywhere 3 nicht gefunden (kein Device-Index mit CIDs 82/83/86).")
        h.close()
        sys.exit(1)
    print(f"-> MX Anywhere 3 = Device-Index 0x{devidx:02X}, Feature 0x1B04 @ Index 0x{featidx:02X}")

    print("\nVolle CID-Tabelle:")
    for cid, flags in get_cid_table(h, devidx, featidx):
        mouse = flags & 0x01
        divert = (flags >> 5) & 0x01
        persist = (flags >> 6) & 0x01
        print(f"  {cid_name(cid):12s} cid={cid:3d} (0x{cid:02X})  flags=0x{flags:02X}  "
              f"mouse={mouse} divertable={divert} persist={persist}")

    print(f"\nDivertiere CIDs {DIVERT_CIDS} (Back/Forward) ...")
    for cid in DIVERT_CIDS:
        status, resp = set_cid_reporting(h, devidx, featidx, cid, divert=True)
        ok = "OK" if status == "ok" else status
        print(f"  setCidReporting({cid_name(cid)}={cid}, divert=1): {ok}")

    def restore(*_args):
        print("\nSetze Divert zurueck (divert=0) ...")
        for cid in DIVERT_CIDS:
            set_cid_reporting(h, devidx, featidx, cid, divert=False)
        h.close()
        print("Beendet.")
        sys.exit(0)

    signal.signal(signal.SIGINT, restore)

    print("\nBereit. Bitte jetzt Back/Forward an der MX Anywhere 3 druecken "
          "(Ctrl-C zum Beenden) ...\n")

    pressed = set()
    while True:
        resp = h.read(32, timeout=500)
        if not resp:
            continue
        if resp[1] != devidx or resp[2] != featidx:
            continue
        fsw = resp[3]
        swid = fsw & 0x0F
        funcid = fsw >> 4
        if swid != 0x00:
            continue  # not a notification (swId 0 marks spontaneous events)
        if funcid != 0x00:
            continue  # not divertedButtonsEvent (event index 0)

        now_pressed = set(decode_diverted_buttons_event(resp))
        for cid in now_pressed - pressed:
            print(f"DOWN  {cid_name(cid)} (cid={cid})")
        for cid in pressed - now_pressed:
            print(f"UP    {cid_name(cid)} (cid={cid})")
        pressed = now_pressed


if __name__ == "__main__":
    main()
