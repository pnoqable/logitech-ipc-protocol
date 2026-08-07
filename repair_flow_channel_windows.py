#!/usr/bin/env python3
"""Inspect or repair a persisted Logi Options+ Flow device channel on Windows.

Flow stores a zero-based channel in flow/devices/*.xml. The agent exposes the
same value as one-based selfChannel. This tool defaults to inspection only.

Examples:
    python repair_flow_channel_windows.py --list
    python repair_flow_channel_windows.py --serial 1599074031 --set-channel 2
    python repair_flow_channel_windows.py --serial 1599074031 --set-channel 2 --apply
"""
import argparse
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path
from xml.etree import ElementTree


def flow_directories():
    roots = [os.environ.get("APPDATA"), os.environ.get("LOCALAPPDATA"), os.environ.get("PROGRAMDATA")]
    return [Path(root) / "LogiOptionsPlus" / "flow" / "devices" for root in roots if root]


def device_files():
    files = []
    for directory in flow_directories():
        if directory.is_dir():
            files.extend(directory.glob("*.xml"))
    return sorted(files)


def read_device(path):
    root = ElementTree.parse(path).getroot()
    if root.tag != "device" or "channel" not in root.attrib:
        return None
    return root


def describe(path, root):
    serial = root.get("serialNumber", "")
    channel = int(root.get("channel"))
    return f"{path}  serial={serial}  storedChannel={channel}  selfChannel={channel + 1}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list detected Flow device files")
    parser.add_argument("--serial", help="device serialNumber from --list or query_agent_windows.py")
    parser.add_argument("--set-channel", type=int, choices=(1, 2, 3), help="target one-based Flow channel")
    parser.add_argument("--apply", action="store_true", help="write the requested change and create a backup")
    args = parser.parse_args()

    devices = [(path, root) for path in device_files() if (root := read_device(path)) is not None]
    if args.list or not args.serial:
        if not devices:
            print("No Flow device XML files found under AppData.", file=sys.stderr)
            return 1
        for path, root in devices:
            print(describe(path, root))
        if not args.serial:
            return 0

    matches = [(path, root) for path, root in devices if root.get("serialNumber") == args.serial]
    if len(matches) != 1:
        print(f"Expected exactly one Flow XML file for serial {args.serial!r}; found {len(matches)}.", file=sys.stderr)
        return 1
    if args.set_channel is None:
        print("--set-channel is required when --serial is supplied.", file=sys.stderr)
        return 1

    path, root = matches[0]
    current = int(root.get("channel"))
    target = args.set_channel - 1
    print(describe(path, root))
    print(f"Requested selfChannel={args.set_channel} (storedChannel={target}).")
    if current == target:
        print("No change needed.")
        return 0
    if not args.apply:
        print("Dry run only. Stop the Logi Options+ agent, then repeat with --apply.")
        return 0

    backup = path.with_suffix(path.suffix + ".bak-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    root.set("channel", str(target))
    ElementTree.ElementTree(root).write(path, encoding="utf-8", xml_declaration=False)
    print(f"Updated {path}; backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
