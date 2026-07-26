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

**🟢 Aktiver Zwischenstand (Abschnitt 4):** CoreBluetooth-GATT-Zugriff auf die Maus
funktioniert grundsätzlich und umgeht die `IOHIDManager`-Sperre für Bluetooth-Input-Geräte –
der richtige vendor-spezifische GATT-Kanal wurde gefunden, Options+ nutzt nachweislich genau
diesen Kanal. **Das Byte-Format ist jetzt entschlüsselt** (Packet-Sniff mit PacketLogger,
`.pklg` selbst geparst mit neuem Tool `ble_pklg_decode.py`) – bit-genau gegen die offizielle
0x1B04-Spec verifiziert an `getCidReporting`/`setCidReporting` für Left/Right. Fehlt noch:
dieselben Aufrufe für Back/Forward (CID 83/86) und ein echtes `divertedButtonsEvent` live
sehen – dann direkt Implementierung in `ble_hidpp_probe.swift`. Siehe Abschnitt 4 für Details.

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
| **Option C, Bluetooth-Variante: CoreBluetooth-GATT** | 🟢 Kanal gefunden, Byte-Format entschlüsselt, Back/Forward-CID + Event noch zu bestätigen (Abschnitt 4) |

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

**✅ Byte-Format ENTSCHLÜSSELT (26.07.2026, ~22:44–22:46):** Packet-Sniff mit Apple
PacketLogger (App aus "Additional Tools for Xcode", nicht im Standard-Xcode enthalten)
während SmartShift-Regler-Bewegung in Options+ durchgeführt, Capture in
`MX Anywhere 3 Write.pklg` gesichert. **Die `.pklg`-Datei wurde direkt selbst geparst**
(kein Wireshark/tshark nötig – Format ist einfach genug für einen ~150-Zeilen-Python-Parser,
siehe `ble_pklg_decode.py`), dadurch auch die Notify-Antworten erfasst (nicht nur die
Writes wie im ersten Text-Export aus PacketLogger).

**Bestätigtes BLE-HID++-Framing** (bit-genau gegen die offizielle x1b04-Spec geprüft,
https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html):
```
[featureIndex] [funcId<<4 | swId] [param0] [param1] ...
```
- **Kein Report-ID-Marker (`0x10`/`0x11`) und kein `devIndex`-Byte** wie beim USB-Dongle –
  beides entfällt bei BLE, da pro GATT-Verbindung nur ein Gerät existiert (kein
  Multi-Device-Empfänger wie der Unifying-Dongle). Das erklärt auch, warum alle Versuche
  in der Vorsession mit `devIdx`-Präfix scheiterten (Byte-Offset war dadurch um 1 verschoben).
- **`featureIndex 0x09` = Feature `0x1B04`** – identisch mit dem per USB-Dongle ermittelten
  Wert (Abschnitt 3.2)! Feature-Indizes scheinen zwischen USB- und BLE-Transport identisch
  zu sein (gleiche Firmware-Feature-Tabelle).
- **Options+ nutzt `swId = 0xC`** (konstant) auf dem BLE-Kanal – eigene Tools sollten einen
  anderen swId wählen (z. B. `0x1`), um eigene Requests von Options+-Traffic unterscheidbar
  zu halten (analog zum USB-Dongle-Vorgehen).
- **Notifications werden immer auf 19 Byte nullgepolstert** (= 20-Byte-Long-Report minus
  Marker-Byte). Requests sind ungepolstert (nur so viele Bytes wie nötig – GATT
  `writeWithoutResponse` erlaubt kurze Writes, Rest wird geräteseitig implizit als 0
  behandelt).
- **Live verifiziert (bit-genau passend zur Spec):** `getCidReporting(cid=80/81)` +
  `setCidReporting(cid=80/81, ...)` für Left/Right-Maustaste (Options+ fragt diese beim
  Öffnen der Geräteseite automatisch ab, unabhängig vom SmartShift-Regler). Decodierte
  Flags: `divert=0, persist=0, rawXY=0, remap=0` – exakt passend zu "Left/Right nicht
  divertable" aus unserer CID-Tabelle (Abschnitt 2.1).
- Nebenbefund: `featureIndex 0x0D`/`0x0E` sind vermutlich die SmartShift-Feature (0x2130)
  selbst bzw. eine Wheel-Ratchet-Konfiguration (Payload-Struktur passt zu
  Threshold-Werten/Modus-Auswahl 1 vs. 3) – nicht weiter verfolgt, da nicht das Ziel.

**🟡 Noch offen:** CID 83 (Back) / 86 (Forward) wurden in diesem Capture nicht abgefragt
(nur Left/Right) – vermutlich weil das Capture erst nach dem initialen Seiten-Load der
Button-Seite startete, oder weil Back/Forward nur bei expliziter Interaktion
(Neu-Zuweisung) abgefragt werden. Auch das eigentliche `divertedButtonsEvent`
(Notification mit `swId=0`, bis zu 4 CIDs, siehe Spec) wurde noch nicht gesehen.

**Nächste Schritte:**
1. **Empfohlen:** Neuen Sniff durchführen, diesmal gezielt auf Back/Forward: in Options+
   der MX Anywhere 3 eine **Custom-Aktion auf Back oder Forward zuweisen** (das triggert
   garantiert `setCidReporting(cid=83/86, divert=1, dvalid=1, ...)`), danach die Taste
   **physisch drücken/halten** (sollte ein `divertedButtonsEvent` mit `cid=83` bzw. `86`
   auslösen). Auswertung direkt mit `ble_pklg_decode.py <neue-datei>.pklg --feature 0x09`.
2. Mit den jetzt bekannten Byte-Formaten (`getCidInfo`, `getCidReporting`,
   `setCidReporting`) kann `ble_hidpp_probe.swift` jetzt korrekt implementiert werden
   (eigenes `setCidReporting(83, divert=1)` + `divertedButtonsEvent`-Listener), OHNE
   weiteren Sniff – das eigentliche Ziel (Back/Forward Down/Up über BLE) ist damit
   vermutlich direkt erreichbar.
3. Falls das Schreiben eigener Requests wider Erwarten nicht funktioniert: zurück zu
   Priorität 2 (Abschnitt 2.3) – Ghidra/objdump, jetzt mit konkreter Suchspur (Service
   `00010000-...`/Characteristic `00010001-...`, swId `0xC`).

---

## 5. Tooling

**Ort:** `~/Devel/logitech-ipc-protocol/`

| Tool | Zweck | Status |
|---|---|---|
| `hidpp_thumb_buttons.py` | Rohes HID++ 2.0 über Unifying-Dongle, Back/Forward Down/Up-Events | ✅ fertig |
| `ble_gatt_probe.swift` | CoreBluetooth Service/Characteristic-Discovery | ✅ funktioniert |
| `ble_hidpp_probe.swift` | Gezielter GATT-Schreib/Notify-Test (HID++-Framing-Hypothesen) | 🟢 Byte-Format jetzt bekannt, Skript noch nicht mit korrektem Framing aktualisiert |
| `ble_pklg_decode.py` | Parst `.pklg`-Packet-Sniffs selbst (kein Wireshark nötig), decodiert Feature 0x1B04 | ✅ neu, funktioniert |
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

1. **Back/Forward-CID-Traffic + `divertedButtonsEvent` sniffen** (Abschnitt 4): Custom-Aktion
   auf Back/Forward in Options+ zuweisen (triggert `setCidReporting(divert=1)`), Taste
   drücken/halten, mit PacketLogger mitschneiden, mit `ble_pklg_decode.py --feature 0x09`
   auswerten.
2. **`ble_hidpp_probe.swift` mit jetzt bekanntem Framing neu implementieren:**
   `setCidReporting(cid=83/86, divert=1, dvalid=1)` schreiben + auf
   `divertedButtonsEvent`-Notifications lauschen (swId=0). Eigenen swId (z. B. `0x1`,
   nicht `0xC`) verwenden, um Options+-eigenen Traffic unterscheiden zu können.
3. **Falls das scheitert:** Priorität 2, Options+-IPC-Weg (Abschnitt 2.3) – Ghidra/objdump auf
   `logioptionsplus_agent`, jetzt mit konkreter Suchspur (GATT-UUIDs, swId `0xC`).
4. **Sobald ein Weg (Dongle UND Bluetooth) CID-Events liefert:** PinchBar-Integration
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
