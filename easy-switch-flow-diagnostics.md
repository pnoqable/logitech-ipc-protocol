# Easy-Switch and Flow Diagnostics

## Verified device state

Feature enumeration was captured through the Logitech BLE HID++ GATT channel on the affected
hardware:

| Device | `CHANGE_HOST` (`0x1814`) | `HOSTS_INFO` (`0x1815`) |
| --- | --- | --- |
| MX Anywhere 3 | present at feature index `0x0A` | not present |
| MX Keys | present at feature index `0x09` | present at feature index `0x0A`, version 1 |

The MX Anywhere 3 also reports `hostInfos: false` in the Logi Options+ agent's `/devices/list`
response. It therefore has no confirmed standard HID++ read path for its stored Easy-Switch host
metadata. Do not send guessed `HOSTS_INFO` requests to the keyboard or state-changing commands to
either device.

Both devices were connected by BLE when observed. The agent reported `hostChannel: 0` for both;
this is an agent-side connection field, not yet a proven physical Easy-Switch slot number.

## Safe comparison procedure

On each Flow host while the devices are actively connected, capture both read-only snapshots:

```bash
swift ble_hidpp_feature_dump.swift > "feature-dump-$(hostname).log"
python3 logi_device_snapshot.py > "agent-snapshot-$(hostname).json"
```

Compare `udid`, `hashedSerialNumber`, `hostChannel`, `flow`, and `hostInfos` in the agent
snapshots. The hardware feature lists should remain stable across hosts. A differing device
identity, host channel, or Flow configuration is evidence for host-side Options+/Flow state rather
than a change made by this diagnostic tooling.

`hostChannel` is only available when the agent lists an active interface. If the snapshot reports
`connected: false` or `hostChannel: null`, reconnect or activate the device on that host before
capturing the comparison.

## Current conclusion

The initial hypothesis that the mouse may expose old slot metadata through `HOSTS_INFO` is not
supported for this MX Anywhere 3. A Flow reset was captured on macOS and directly confirms the
stale host mapping: the physical Windows peer is connected to Easy-Switch slot 2, but the resulting
Flow config stores it as `channel: 3`. Flow then emits `deviceChannel: 3` when crossing the edge.

The stale state is therefore in the Flow channel mapping, not an unverified mouse `HOSTS_INFO`
response. Capture the peer's state before changing anything else:

```bash
# macOS
python3 logi_flow_snapshot.py

# Windows
python query_agent_windows.py
```

The Windows output must show its Flow `Config`, `Location`, and `Peers` for the connected mouse.
In particular, compare the Windows peer's self channel with the physical Easy-Switch slot 2.
Do not send a guessed HID++ host command.

## Confirmed Windows channel source

The Windows capture reports the MX Anywhere 3 as `deviceChannel: 3` and `selfChannel: 3`.
Resetting Flow cleared the discovered peer metadata, but did not change either value. Therefore
the channel is not stale Flow configuration; it comes from the currently active mouse/connection
state as seen by Options+. The same config reports `keyboardChannel: 2`, so the keyboard is on
slot 2 while the mouse is currently identified as channel 3.

`CHANGE_HOST` itself has a read-only `GetHostInfo` operation, exposed by the Options+ agent as
`GET /change_host/<device-id>/host`. `query_agent_windows.py` includes this response as
`HID++ ChangeHost`; use it to distinguish the firmware's current host index from Flow's channel
number before any further correction attempt.

## Persisted Flow Channel Repair

Flow keeps a per-device XML record under `LogiOptionsPlus/flow/devices`. Its zero-based `channel`
attribute is exposed by the agent as one-based `selfChannel`, and is not cleared by Flow reset.
Use the repair tool in inspection mode first:

```powershell
python repair_flow_channel_windows.py --list
```

For the MX Anywhere 3 record only, after confirming its serial and that the desired channel is 2,
quit Logi Options+ and stop its agent. Then run the generated dry run before opting in to a change:

```powershell
python repair_flow_channel_windows.py --serial <serial> --set-channel 2
python repair_flow_channel_windows.py --serial <serial> --set-channel 2 --apply
```

The tool creates a timestamped backup next to the XML before changing the value. Restart Logi
Options+, verify `selfChannel: 2` with `query_agent_windows.py`, then set up Flow again.

### Validated result

For MX Anywhere 3 serial `1599074031`, changing stored `channel` from `2` to `1` and restarting
Options+ produced `HID++ ChangeHost: {"host": 1}`, `deviceChannel: 2`, and `selfChannel: 2` on
Windows. The Flow config then placed `WIN-2QMI19B5V24` on channel 2 with `keyboardChannel: 2`.
This is the required state for an Easy-Switch slot-2 Windows connection.

The Flow reset remains useful for clearing peer metadata:

```powershell
python query_agent_windows.py --reset-flow
```

This sends the verified `SET /flow/<device-id>/reset` request. It resets only Flow configuration;
it does not alter Bluetooth/Unifying pairings or send a `CHANGE_HOST` command. Before another
Flow setup, verify the mouse's physical Easy-Switch position separately from the keyboard. The
Windows agent must report `selfChannel: 2` for Flow to target slot 2.

The existing observational proxy can capture that UI-to-agent traffic:

```bash
python3 sniff_button_events.py proxy > flow-agent-traffic.log 2>&1
```

It temporarily relocates the agent socket while active; follow the script's established procedure
to quit and relaunch the Options+ UI, perform only the normal Flow configuration/reset steps, then
stop the proxy and inspect the log. Do not use this together with a guessed HID++ host command.
