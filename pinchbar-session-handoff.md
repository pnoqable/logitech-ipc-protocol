# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 26.07.2026, ca. 21:35 CEST. Session pausiert mitten im CoreBluetooth-Experiment
(Abschnitt 3.6, "Offene Frage").

**Ziel:** Die Daumentasten (Back/Forward, HID++ CID 83/86) der Logitech MX Anywhere 3
(gekoppelt via macOS-Bluetooth) als echte Down/Up-Events für PinchBar (`~/Devel/PinchBar`,
`OtherMouseZoomMapping`) nutzbar machen – bisher geht das nur mit der mittleren Maustaste.
Gebraucht werden echte Down/Up-Events (kein Einzel-Trigger), da PinchBar "gehaltene Taste +
Scrollen" braucht, ohne dass Logi Options+ die Taste abfängt.

**✅ Priorität 1 (Option C) – abgeschlossen und funktioniert:** `hidpp_thumb_buttons.py`
implementiert die volle HID++-2.0-Kette (Root.GetFeature, getCount/getCidInfo,
setCidReporting, divertedButtonsEvent-Decoding) über den Logitech-Unifying-USB-Dongle. Live
verifiziert: Back/Forward liefern saubere, wiederholbare DOWN/UP-Events, auch bei gehaltener
Taste. Details siehe Abschnitt 3.5.

**🟡 Aktiver Zwischenstand (Abschnitt 3.6):** CoreBluetooth-GATT-Zugriff auf die Maus
funktioniert grundsätzlich und umgeht die `IOHIDManager`-Sperre für Bluetooth-Input-Geräte –
der richtige vendor-spezifische GATT-Kanal wurde gefunden und es ist bestätigt, dass Options+
selbst genau diesen Kanal nutzt. Das genaue Byte-Format der Antworten ist aber noch nicht
entschlüsselt. Empfohlener nächster Schritt: Bluetooth-Packet-Sniff von echtem Options+-Traffic
als Referenz (siehe Abschnitt 3.6 für Details).

**Beide Geräte (MX Anywhere 3, MX Keys) sind aktuell sowohl über den Unifying-Dongle als auch
über direktes macOS-Bluetooth gekoppelt** (Bluetooth wurde in dieser Session für den
CoreBluetooth-Test zusätzlich eingerichtet). Der Dongle bleibt reiner Testaufbau – Endziel ist
der Bluetooth-Pfad. Der Logi-Options+-Agent (`com.logi.cp-dev-mgr`) wurde während der Session
kurz gestoppt (sauberer GATT-Test ohne Störtraffic) und wieder gestartet – bei Sessionstart kurz
prüfen (`launchctl list | grep cp-dev-mgr`, Maus/Tastatur normal?).

---

## 1. Erkenntnisstand – Übersicht

| Ansatz | Status |
|---|---|
| Logi Actions SDK | ❌ Nicht anwendbar (nur Creative Console/Loupedeck/Actions Ring), zudem nur Einzel-Trigger |
| Options+ Keystroke-/Gesture-Zuweisung | ❌ Nur Einzel-Trigger, kein Hold-Zustand exportierbar |
| Options+ IPC – geratene `SUBSCRIBE`-Pfade | ❌ Bestätigt wirkungslos, Agent broadcastet Button-Events nicht automatisch |
| Options+ IPC – `/input_tracker/*` | 🟡 Funktioniert für Standard-Maustasten, **beweisbar Sackgasse für CID-Daumentasten** (Details Abschnitt 3.3) |
| Options+ IPC – `/devices/special_keys_divert_state/configure` | 🟡 Pfad existiert nachweislich, JSON-Feldschema nicht gefunden – Fallback als Priorität 2 (Abschnitt 5) |
| **Option C: Rohes HID++ über USB-Dongle** | **✅ Funktioniert, live verifiziert** (Abschnitt 3.5) |
| **Option C, Bluetooth-Variante: CoreBluetooth-GATT** | 🟡 Kanal gefunden, Byte-Format offen (Abschnitt 3.6) |

---

## 2. Technischer Hintergrund

### 2.1 HID++ 2.0 Grundlagen (Feature 0x1B04)
- Referenz: https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
- `setCidReporting(cid, divert=1)` lenkt eine Taste um; Firmware sendet dann bei
  Zustandsänderung ein `divertedButtonsEvent` mit Liste aktuell gedrückter CIDs
  (erscheint=Down, verschwindet=Up).
- **MX Anywhere 3 CIDs:** 80=Left, 81=Right (nicht divertable), 82=Middle, 83=Back,
  86=Forward, 196=SmartShift (alle divertable), 215=virtueller Eintrag.
- **Warum roher Zugriff bei direktem BLE nicht geht:** macOS blockiert `IOHIDDeviceOpen()`
  für Bluetooth-Input-Geräte kernelseitig, für jede App. Wie Options+ dennoch BLE-HID++-Zugriff
  bekommt war lange ungeklärt – siehe Abschnitt 3.6 für den (teilweise gelösten) Grund:
  vermutlich CoreBluetooth-GATT statt IOHIDManager.
- **Praktischer Ausweg (Option C):** Maus über Logitech-Unifying/Bolt-USB-Dongle statt
  direktem Bluetooth koppeln → HID++ läuft dann als normaler USB-HID-Transport, nicht unter
  die BT-Sperre. → Umgesetzt in Abschnitt 3.5.

### 2.2 Options+ IPC-Unix-Socket – Basics
- Referenz-Repo (dieses Repo): `~/Devel/logitech-ipc-protocol`. **Achtung:** `origin` zeigt auf
  das fremde Original (`saimanish1`) – vor Commits/Push erst forken und Remote umbiegen.
- Socket: `/tmp/logitech_kiros_agent-<hash>` (Hash ändert sich bei Agent-Neustart, nie
  hardcoden, per Glob suchen).
- Wire-Format: `LE32(total_len) + BE32(proto_name_len) + "json" + BE32(msg_len) + JSON`.
- Verbs: `GET`, `SET`, `SUBSCRIBE`, `UNSUBSCRIBE`, `BROADCAST`. Requests: `msg_id`
  (snake_case), Responses: `msgId` (camelCase).
- Device-IDs (ändern sich bei Re-Pairing, per `devices`-Modus neu ermitteln).

### 2.3 `/input_tracker/*` API – Sackgasse für CID-Tasten (Fallback-Referenz für Priorität 2)
- `SET /input_tracker/start {"filter": [...]}` + `SUBSCRIBE /input_tracker/events` liefert
  `BROADCAST`-Events mit `isDown`-Flag für `KEYBOARD` und `MOUSE_BUTTON` (Standardtasten).
  Re-Arm-Pattern nötig: nach jedem Event sofort neu `start` senden (`sniff_repeat.py --restart`).
- **CID 83/86 (Back/Forward) liefern über diesen Pfad null Events** – autoritativ bestätigt per
  Protobuf-Reflection aus der Binary (`enum Filter { NONE, MOUSE_MOVE, MOUSE_BUTTON,
  MOUSE_WHEEL, KEYBOARD }`, kein CID-Wert vorhanden). Architektonische Sackgasse.
- **Fund für Priorität 2** (Protobuf-Descriptor-Pool, `logi.protocol.devices`):
  ```protobuf
  message DivertStateRequest { int32 control_id; bool divert; bool raw_xy; bool raw_wheel; }
  message SpecialKeysDivertRequest { repeated DivertStateRequest control_ids_list; }
  message DivertState { int32 control_id; bool divert; }
  message SpecialKeysDivertState { repeated DivertState control_ids_list; }
  message TestKeyState { int32 ctrl_id; bool is_diverted, is_diverted_valid; ... }
  message TestDeviceKeysState { repeated TestKeyState states; }
  message TriggerEvent { string device_id; Device.Type device_type; string slot_id;
    TriggerEvent.State state; /* enum State { INACTIVE, START, ONE_SHOT } */ ... }
  ```
  Symbol `feature_x1b04_special_keys` (`_process_key_gesture_event`) bestätigt: Feature `0x1B04`
  ist intern im Agent implementiert. Pfad `SET /devices/special_keys_divert_state/configure`
  existiert nachweislich (liefert Applikationsfehler statt "no handler"), aber jeder Versuch mit
  aus obigen Messages abgeleiteten Feldnamen scheitert an `INVALID_MESSAGE_RECEIVED` – Pfad→
  Message-Zuordnung aus Strings nicht ableitbar. Nächster Schritt wäre Ghidra/objdump (Priorität 2).
- Ad-hoc-Tools (nicht committed): `sniff_repeat.py`, `test_divert.py`.

### 2.4 Sonstige negativ getestete Wege
- Geratene `SUBSCRIBE`-Pfade (11 Stück, alle Maustasten getestet): keine Events.
- Referenz-Repo-Hinweise (`TODO.md`, Easy-Switch-Knopf): ebenfalls kein Treffer.

---

## 3. Option C: Rohes HID++ 2.0 (Hauptansatz)

### 3.1 Setup (USB-Dongle)
- Hardware: Logitech **Unifying**-Empfänger (nicht Bolt), Maus = reguläre **MX Anywhere 3**.
- Python-Umgebung (System-Python ist SIP-geschützt):
  ```bash
  brew install hidapi python@3.12
  cd ~/Devel/logitech-ipc-protocol
  /opt/homebrew/bin/python3.12 -m venv .venv
  .venv/bin/pip install hid
  ```
  Aufruf-Pattern: `DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 <script>.py`
- Dongle-Interfaces (vendor_id `0x046d`, product_id `0xC52B`): Interface 2, usage_page
  `0xFF00` (vendor-spezifisch) ist der HID++-Rohkanal (Short Reports 7 Byte/`0x10`, Long
  Reports 20 Byte/`0x11`). ⚠️ `path` (`DevSrvsID:...`) ändert sich pro Session – immer per
  `hid.enumerate()` neu ermitteln, nie hardcoden.

### 3.2 ✅ `hidpp_thumb_buttons.py` – fertig, live verifiziert
Wichtige Erkenntnisse für Folgesessions:
- **Device-Index MX Anywhere 3 = 0x04** (0x01 = MX Keys am selben Dongle, erkennbar an CIDs
  ohne `mouse`-Flag/mit `fkey`-Flag statt 82/83/86). Index kann sich bei Re-Pairing ändern –
  im Skript daher dynamisch über CID-Table ermittelt, nie hardcodiert.
- **Feature-Index von 0x1B04:** MX Anywhere 3 = 0x09, MX Keys = 0x08 – wird per
  `Root.GetFeature` ermittelt, nicht hardcodiert.
- **CID-Tabelle MX Anywhere 3** (7 Einträge): 80=Left, 81=Right (nicht divertable), 82=Middle,
  83=Back, 86=Forward, 196=SmartShift (alle divertable), 215=virtuell.
- **Response-Framing-Überraschung:** Anfragen als 7-Byte-Short-Report (`0x10`) gesendet, Dongle
  antwortet auf `Root.GetFeature`/`getCidInfo` aber mit **Long-Report** (`0x11`, 21 Byte). Parser
  muss beide Report-IDs akzeptieren (Header-Layout ab Byte 2 identisch, Long-Report nur weiter
  mit Nullen aufgefüllt).
- **Multiplexing:** Auf dem Rohkanal treffen laufend fremde Antworten/Notifications ein – jede
  Anfrage muss per `devIndex`+`featureIndex`+`funcId/swId`-Echo gefiltert werden.
- **`setCidReporting` braucht Long-Report**, da 5 Parameterbytes nötig sind (mehr als die 3
  Bytes eines Short-Reports).
- **Notification-Erkennung:** `divertedButtonsEvent` hat `swId==0` und `funcId==0` (Byte 3) –
  unterscheidet sich zuverlässig von Funktions-Antworten (immer `swId`≠0).
- **Ergebnis:** Back/Forward liefern über `setCidReporting(divert=1)` +
  `divertedButtonsEvent`-Decoding saubere, wiederholbare DOWN/UP-Events.

Aufruf: `DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 hidpp_thumb_buttons.py`
(Ctrl-C beendet, setzt Divert automatisch zurück).

---

## 4. CoreBluetooth-Experiment (Option C, Bluetooth-Variante) – 🟡 IN ARBEIT

**Frage:** Lässt sich HID++ direkt über Bluetooth abgreifen (ohne Dongle-Umweg), obwohl
`IOHIDDeviceOpen()` für BT-Input-Geräte blockiert ist? Tools: `ble_gatt_probe.swift`
(Service/Characteristic-Dump), `ble_hidpp_probe.swift` (Schreib/Notify-Test) – beide per
`swift <script>.swift` ausführbar, kein Xcode-Projekt nötig.

**✅ Bestätigt:**
- CoreBluetooth-GATT-Zugriff funktioniert und umgeht die IOHIDManager-Sperre.
- `CBCentralManager.scanForPeripherals()` findet die Maus NICHT (sie advertised nicht mehr,
  da bereits verbunden). Stattdessen funktioniert `retrieveConnectedPeripherals(withServices:)`
  mit Standard-UUIDs `180F` (Battery) oder `180A` (Device Information) als Filter.
- Service-Struktur: neben Standard-Services (`180A`, `180F`) existiert ein
  **vendor-spezifischer Service `00010000-0000-1000-8000-011F2000046D`** mit einer
  Characteristic **`00010001-0000-1000-8000-011F2000046D`**
  (Properties: `read, write, writeWithoutResponse, notify`) – mit hoher Wahrscheinlichkeit der
  HID++-Tunnel über GATT.
- **Options+ nutzt nachweislich genau diesen Kanal:** Writes lösten bei laufendem
  `com.logi.cp-dev-mgr` eine Flut fremder Notifications aus (Options+' eigener
  Hintergrund-Traffic, macOS multiplext mehrere Apps auf dieselbe BLE-Verbindung). Nach
  `launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr` verschwand das Rauschen – jeder eigene
  Write erzeugte danach genau eine Antwort. **Agent danach wieder gestartet** via
  `open "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app"`
  (⚠️ nach vollem `bootout` greift `kickstart -k` nicht mehr, da der Job komplett entladen
  wurde – dann muss die App neu geöffnet werden statt `kickstart`).

**🔴 Byte-Format noch NICHT entschlüsselt:**
- `Root.GetFeature(0x1B04)`-Requests im USB-Short-Report-Format
  (`0x10, devIdx, featIdx, funcId<<4|swId, d0,d1,d2`) mit devIdx `0x00`/`0x01`/`0xFF`, mit/ohne
  führendes `0x10`-Marker-Byte getestet. Alle Varianten lieferten *eine* konsistente Antwort
  (echter Kanal, kein Rauschen), aber:
  - devIdx `0x00`/`0x01` (mit Marker): Marker+devIdx+featIdx korrekt echot, aber erwartetes
    `funcId<<4|swId` (`0x05`) kam als `0x00` zurück – entweder andere Response-Struktur
    (schon Nutzdaten = "Feature nicht gefunden") oder anderes Request-Encoding.
  - devIdx `0xFF`: strukturell andere Antwort (`ff 10 ff 07 00...`), sieht nach Fehlerantwort
    aus (`0x07`=`INVALID_FUNCTION`) – `0xFF` vermutlich ungültig bei Direkt-BLE (kein
    Multi-Device-Empfänger wie beim Dongle).

**Nächste Schritte (nicht versucht):**
1. **Empfohlen:** Bei laufendem Options+ eine echte 0x1B04-Aktion in der UI auslösen (z. B.
   SmartShift-Regler bewegen) und mit PacketLogger/Bluetooth-Diagnose (`Xcode > Open Developer
   Tool > Bluetooth`) den echten Request/Response-Bytestream mitschneiden – liefert
   garantiert korrekte Referenz statt weiterem Raten.
2. Systematisch `swId`-Werte 0x1–0xF und vertauschte Nibble-Reihenfolge (`swId<<4|funcId`)
   durchprobieren, bei gestopptem Options+-Agent.
3. Prüfen ob es eine zweite, noch unentdeckte Characteristic für Short- vs. Long-Reports gibt.
4. Falls Byte-Format nicht zeitnah geknackt wird: zurück zu Priorität 2 (Abschnitt 2.3) – aber
   jetzt mit konkreter Suchspur für Ghidra (Code, der Service `00010000-...`/Characteristic
   `00010001-...` referenziert).

---

## 5. Tooling

**Ort:** `~/Devel/logitech-ipc-protocol/`

| Tool | Zweck | Status |
|---|---|---|
| `hidpp_thumb_buttons.py` | Rohes HID++ 2.0 über Unifying-Dongle, Back/Forward Down/Up-Events | ✅ fertig |
| `ble_gatt_probe.swift` | CoreBluetooth Service/Characteristic-Discovery | ✅ funktioniert |
| `ble_hidpp_probe.swift` | Gezielter GATT-Schreib/Notify-Test (HID++-Framing-Hypothesen) | 🟡 Byte-Format offen |
| `sniff_button_events.py` | Options+-IPC: `devices`, `subscribe`, `input_tracker`, `proxy`, `ws` | ✅ (siehe unten) |
| `sniff_repeat.py` | Re-Arm-Loop für `input_tracker` | ✅ (nicht committed) |
| `test_divert.py` | Payload-Varianten für `/configure` | 🟡 (nicht committed) |
| `query_feature_index.py` | Windows/BLE-Referenz für Root::GetFeature-Framing | Referenz |

**Gefixte Bugs in `sniff_button_events.py`** (falls Tool wieder komisch reagiert):
1. Frame-Parser hing bei großen Nachrichten → Limit 64 MB, Resync mit 4096-Byte-Fenster.
2. Race Condition beim Cleanup löschte Agent-Socket erneut → Custom-SIGINT-Handler entfernt.
3. Nach Bug 2 Agent neu starten: `launchctl kickstart -k gui/$(id -u)/com.logi.cp-dev-mgr`,
   dann Socket unter `/tmp/logitech_kiros_agent-*` prüfen.

---

## 6. Nächste Schritte (priorisiert)

1. **CoreBluetooth-Byte-Format knacken** (Abschnitt 4) – Packet-Sniff von echtem
   Options+-Traffic empfohlen.
2. **Falls das scheitert:** Priorität 2, Options+-IPC-Weg (Abschnitt 2.3) – Ghidra/objdump auf
   `logioptionsplus_agent`, jetzt mit konkreter Suchspur (GATT-UUIDs).
3. **Sobald ein Weg (Dongle UND Bluetooth) CID-Events liefert:** PinchBar-Integration
   entwerfen – vermutlich separater Helper-Prozess, der Down/Up über IPC an PinchBar
   weiterreicht (behandelt wie synthetisches `otherMouseDown/Up`). Options+-IPC-Weg bliebe
   undokumentiertes, änderbares Protokoll; HID++-Weg ist robuster (offiziell dokumentiert).

---

## 7. Arbeitsumgebung & Referenzen

- Auf dem echten Mac mit echter Maus + laufendem Options+ weiterarbeiten (Recherche ist 100%
  hardware-/GUI-gebunden). Ghidra für Priorität-2-Protobuf-Analyse nutzen, `npx asar extract`
  für die Electron-UI.
- **Fork-Erinnerung:** Vor dem ersten Commit `saimanish1/logitech-ipc-protocol` forken und
  `origin` umbiegen (zeigt aktuell auf das fremde Original).
- PinchBar-Code: `~/Devel/PinchBar` (`OtherMouseZoomMapping.swift`,
  `OtherMouseScrollMapping.swift`, `Utilities/CGEventExtensions.swift`, `MultitouchSupport.mm`)
- Referenz-Repo: https://github.com/saimanish1/logitech-ipc-protocol (lokal hier, v. a.
  `logi-options-ipc-reverse-engineering.md`, `api-reference.md`, `TODO.md`)
- HID++ 2.0 Feature 0x1B04: https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
- Weitere HID++-Dokus: https://lekensteyn.nl/files/logitech/, https://github.com/cvuchener/hidpp,
  https://github.com/pwr-Solaar/Solaar (Quelle für Short/Long-Report-Framing-Details, Linux/Windows)
- Logi Actions SDK (nicht anwendbar): https://logitech.github.io/actions-sdk-docs/

---

## 8. Kurzreferenz: Wichtige Befehle

```bash
# Agent-Socket-Status prüfen / Agent neu starten
ls -la /tmp/ | grep -i logitech_kiros
launchctl kickstart -k gui/$(id -u)/com.logi.cp-dev-mgr
# falls das nicht greift (z.B. nach `bootout`): App neu oeffnen
open "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app"

# Bluetooth-Verbindungsstatus der Geraete pruefen
system_profiler SPBluetoothDataType | grep -A6 "MX Anywhere\|MX Keys"

# Option C: Back/Forward Down/Up-Events ueber den Dongle (fertig, funktioniert)
cd ~/Devel/logitech-ipc-protocol
DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 hidpp_thumb_buttons.py

# CoreBluetooth-Experiment: GATT-Services dumpen bzw. HID++-Framing testen
swift ble_gatt_probe.swift
swift ble_hidpp_probe.swift

# Options+-IPC: Geraete + Device-IDs auflisten
python3 sniff_button_events.py devices

# Options+-IPC: Maus-Events testen (nur Standardtasten, NICHT Daumentasten, siehe 2.3)
python3 sniff_button_events.py input_tracker --filter MOUSE_BUTTON --duration 30

# Falls noetig: MITM-Proxy fuer weitere UI-Flow-Exploration
python3 sniff_button_events.py proxy > out.txt 2>&1
# ... Options+ UI neu oeffnen, gewuenschten Flow durchspielen, Ctrl-C ...
grep -n '"verb": "SET"\|SUBSCRIBE\|input_tracker' out.txt | cut -c1-300
```
</content>
