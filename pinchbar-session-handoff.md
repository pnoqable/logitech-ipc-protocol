# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 27.07.2026, ca. 00:20 CEST. **Kernziel technisch erreicht** – Back/Forward liefern
jetzt live verifiziert echte Down/Up-Events über direktes Bluetooth (kein Dongle nötig). Fokus
verschiebt sich auf PinchBar-Integration (Abschnitt 6).

**Ziel:** Die Daumentasten (Back/Forward, HID++ CID 83/86) der Logitech MX Anywhere 3
(gekoppelt via macOS-Bluetooth) als echte Down/Up-Events für PinchBar (`~/Devel/PinchBar`,
`OtherMouseZoomMapping`) nutzbar machen – bisher geht das nur mit der mittleren Maustaste.
Gebraucht werden echte Down/Up-Events (kein Einzel-Trigger), da PinchBar "gehaltene Taste +
Scrollen" braucht, ohne dass Logi Options+ die Taste abfängt.

**✅ Priorität 1 (Option C, USB-Dongle) – abgeschlossen und funktioniert:**
`hidpp_thumb_buttons.py` implementiert die volle HID++-2.0-Kette (Root.GetFeature,
getCount/getCidInfo, setCidReporting, divertedButtonsEvent-Decoding) über den
Logitech-Unifying-USB-Dongle. Live verifiziert: Back/Forward liefern saubere, wiederholbare
DOWN/UP-Events, auch bei gehaltener Taste. Details siehe Abschnitt 3.5.

**✅ Priorität 1, Bluetooth-Variante (Abschnitt 4) – JETZT AUCH abgeschlossen und live
verifiziert:** CoreBluetooth-GATT-Zugriff funktioniert komplett, ohne Dongle, direkt über
macOS-Bluetooth. Das komplette BLE-HID++-Byteformat wurde per Packet-Sniff entschlüsselt
(bit-genau gegen die offizielle 0x1B04-Spec verifiziert) und in `ble_hidpp_thumb_buttons.swift`
implementiert. **Live-Test in dieser Session:** Skript lief parallel zu Options+, Back/Forward
wurden mehrfach gedrückt → saubere `DOWN Forward` / `UP Forward` / `DOWN Back` / `UP Back`
Ausgabe, exakt wie beim USB-Dongle. Damit ist **das eigentliche technische Kernproblem des
gesamten Projekts gelöst** – beide Transportwege (USB-Dongle und direktes Bluetooth) liefern
jetzt echte CID-Down/Up-Events. Details und bekannter kleiner Bug (SIGINT-Handler) siehe
Abschnitt 4.

**Beide Geräte (MX Anywhere 3, MX Keys) sind aktuell sowohl über den Unifying-Dongle als auch
über direktes macOS-Bluetooth gekoppelt.** Der Dongle bleibt reiner Testaufbau – Endziel ist
der Bluetooth-Pfad, der jetzt funktioniert. Der Logi-Options+-Agent (`com.logi.cp-dev-mgr`)
lief während der gesamten Bluetooth-Tests normal weiter (kein Stoppen mehr nötig, da unser
eigener `swId=0x1` von Options+' `swId=0xC` unterscheidbar ist) – bei Sessionstart trotzdem
kurz prüfen (`launchctl list | grep cp-dev-mgr`, Maus/Tastatur normal?). **Wichtig:** Nach dem
letzten Testlauf wurde der temporäre Divert auf Back/Forward per Reset-Skript wieder auf 0
gesetzt – bei Sessionstart trotzdem prüfen, ob Back/Forward noch normal als Browser-Navigation
funktionieren (falls nicht: `ble_hidpp_thumb_buttons.swift` kurz laufen lassen und per Ctrl-C
sauber beenden, oder direkt divert=0 setzen, siehe Abschnitt 4).

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
| **Option C, Bluetooth-Variante: CoreBluetooth-GATT** | **✅ Funktioniert, live verifiziert** (Abschnitt 4) |

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

## 4. CoreBluetooth-Experiment (Option C, Bluetooth-Variante) – ✅ ABGESCHLOSSEN

**Frage:** Lässt sich HID++ direkt über Bluetooth abgreifen (ohne Dongle-Umweg), obwohl
`IOHIDDeviceOpen()` für BT-Input-Geräte blockiert ist? **Antwort: Ja.** Tools:
`ble_gatt_probe.swift` (Service/Characteristic-Dump), `ble_hidpp_probe.swift` (ältere
Framing-Hypothesen-Experimente, historisch, durch untenstehendes Tool ersetzt),
`ble_hidpp_thumb_buttons.swift` (**finales, funktionierendes Tool**) – alle per
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

**✅ Zweiter Sniff (`MX Anywhere 3 komplett.pklg`, 27.07.2026 ~01:12–01:13) – Back/Forward
+ echtes `divertedButtonsEvent` bestätigt:** Nutzer hat Back/Forward-Taste physisch gedrückt
(Divert war bereits von einer früheren Custom-Zuweisung aktiv, kein `setCidReporting`-Write
in diesem Capture sichtbar). `ble_pklg_decode.py --feature 0x09` zeigte saubere
`divertedButtonsEvent`-Pakete:
```
feat=0x09 funcId=0 swId=0 raw=090000560000...  => divertedButtonsEvent -> pressed: 86(Forward)
feat=0x09 funcId=0 swId=0 raw=090000000000...  => divertedButtonsEvent -> (keine Tasten gedrueckt)
feat=0x09 funcId=0 swId=0 raw=090000530000...  => divertedButtonsEvent -> pressed: 83(Back)
```
Exakt passend zur Spec (Table 8: bis zu 4 CIDs als BE16, Liste endet bei `cid==0`).
Nebenbefund: eine weitere Notification `funcId=2 swId=0` (z. B. `092000500100...`) tauchte
periodisch für CID 80 (Left) auf, vermutlich Klick-Feedback des normalen Mausgebrauchs
während der Aufnahme – nicht weiter relevant für unser Ziel, absichtlich ignoriert.

**✅ `ble_hidpp_thumb_buttons.swift` implementiert und LIVE GETESTET (27.07.2026 ~23:18
CEST, direkt in dieser Session):**
- Ablauf: `Root.getFeature(0x1B04)` dynamisch (kein Hardcoding) → liefert `featureIndex=0x09`
  (live bestätigt) → `setCidReporting(cid=83/86, divert=1, dvalid=1)` mit eigenem `swId=0x1`
  → Lauschen auf `divertedButtonsEvent` (`funcId=0, swId=0`) → DOWN/UP-Ausgabe.
- **Live-Ergebnis (im Hintergrund laufen lassen, User hat mehrfach Back/Forward gedrückt):**
  ```
  DOWN  Forward
  UP    Forward
  ... (mehrfach wiederholt)
  DOWN  Back
  UP    Back
  ... (mehrfach wiederholt)
  ```
  Sauber, wiederholbar, kein Rauschen – **identisch zuverlässig wie beim USB-Dongle**, aber
  ohne Dongle, direkt über die bestehende Bluetooth-Kopplung. Lief parallel zum laufenden
  Options+-Agent, ohne dass dieser gestoppt werden musste (unterschiedliche `swId` reicht
  zur Trennung).
- **⚠️ Bekannter Bug:** Der `SIGINT`-Handler (Ctrl-C setzt Divert zurück) hat im Test nicht
  zuverlässig ausgelöst, als das Skript per `nohup ... &` im Hintergrund lief (kein
  kontrollierendes Terminal). Bei normalem interaktivem `swift ble_hidpp_thumb_buttons.swift`
  im Vordergrund (echtes Terminal, Ctrl-C per Tastatur) sollte das funktionieren – **in einer
  Folgesession zuerst so verifizieren**, bevor man sich darauf verlässt. Als Fallback:
  manuelles Reset-Skript (Struktur siehe unten) oder Divert bleibt bestehen, bis
  `setCidReporting(divert=0)` erneut gesendet wird oder ein HID++-Konfigurationsreset
  passiert (Feature 0x0020, laut Spec) – **kein bekannter automatischer Reset beim reinen
  Verbindungsabbau**, also nach jedem Testlauf sicherheitshalber sauber zurücksetzen.
- Nach dem Test wurde der Divert-Zustand mit einem Reset-Aufruf
  (`setCidReporting(cid=83/86, divert=0, dvalid=1, swId=0x1)`) wieder auf 0 gesetzt.

**Damit ist Abschnitt 4 vollständig abgeschlossen.** Nächste Schritte siehe Abschnitt 6
(PinchBar-Integration).

---

## 5. Tooling

**Ort:** `~/Devel/logitech-ipc-protocol/`

| Tool | Zweck | Status |
|---|---|---|
| `hidpp_thumb_buttons.py` | Rohes HID++ 2.0 über Unifying-Dongle, Back/Forward Down/Up-Events | ✅ fertig |
| `ble_gatt_probe.swift` | CoreBluetooth Service/Characteristic-Discovery | ✅ funktioniert |
| `ble_hidpp_probe.swift` | Alte Framing-Hypothesen-Experimente (historisch) | 🗄️ obsolet, durch `ble_hidpp_thumb_buttons.swift` ersetzt |
| **`ble_hidpp_thumb_buttons.swift`** | **Back/Forward Down/Up-Events über direktes Bluetooth (kein Dongle)** | **✅ fertig, live verifiziert** |
| `ble_pklg_decode.py` | Parst `.pklg`-Packet-Sniffs selbst (kein Wireshark nötig), decodiert Feature 0x1B04 | ✅ fertig, funktioniert |
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

**Beide Transportwege (USB-Dongle und direktes Bluetooth) liefern jetzt echte CID-Down/Up-
Events.** Der Fokus verschiebt sich komplett auf die PinchBar-Integration:

1. **`SIGINT`-Reset-Bug in `ble_hidpp_thumb_buttons.swift` fixen/verifizieren** (Abschnitt 4)
   – wichtig für einen sauberen Dauerbetrieb, damit Back/Forward beim Beenden zuverlässig
   wieder normal funktionieren.
2. **PinchBar-Integration entwerfen:** `ble_hidpp_thumb_buttons.swift`-Logik in einen
   dauerhaften Helper-Prozess überführen (Swift-Package oder eingebetteter Code in PinchBar
   selbst?), der Back/Forward Down/Up in synthetische `otherMouseDown/Up`-CGEvents übersetzt
   (siehe `~/Devel/PinchBar/Utilities/CGEventExtensions.swift` für das bestehende Muster bei
   der mittleren Maustaste). Offene Fragen dafür:
   - Soll der Helper ein eigener LaunchAgent sein (robust gegen App-Neustarts) oder Teil von
     PinchBar selbst (einfacher, aber CoreBluetooth-Reconnect-Logik muss dann in PinchBar
     laufen)?
   - Reconnect-Handling: Was passiert bei Bluetooth-Disconnect/Schlafmodus/Maus-Neustart?
     `centralManager(_:didDisconnectPeripheral:error:)` müsste implementiert werden (bisher
     nicht im Probe-Skript vorhanden, da nur für kurze Tests gedacht).
   - Divert-Zustand dauerhaft aktiv lassen (persist=1 statt divert=1?) vs. nur während
     PinchBar läuft temporär divertieren, siehe `persist`-Flag in der Spec (Abschnitt 2.1).
   - Verhalten falls Options+ gleichzeitig läuft und ebenfalls Custom-Aktionen auf
     Back/Forward gelegt hat (Konflikt um "wer divertiert zuerst"?) – noch nicht getestet.
3. **Testen, ob das auch mit MX Keys oder anderen HID++-2.0-Mäusen funktioniert** (CID-Tabelle
   und Feature-Index können abweichen, aber Root.GetFeature-Ansatz ist bereits generisch).
4. **Falls die BLE-Variante doch instabil ist:** Fallback auf USB-Dongle-Weg
   (`hidpp_thumb_buttons.py`, Abschnitt 3.2) oder Priorität 2, Options+-IPC-Weg
   (Abschnitt 2.3) – Ghidra/objdump auf `logioptionsplus_agent`.

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

# CoreBluetooth: GATT-Services dumpen
swift ble_gatt_probe.swift

# CoreBluetooth: Back/Forward Down/Up-Events ueber direktes Bluetooth (fertig, funktioniert!)
swift ble_hidpp_thumb_buttons.swift
# Ctrl-C beendet (Reset-Bug siehe Abschnitt 4 - im Vordergrund/echtem Terminal testen)

# .pklg-Packet-Sniff (PacketLogger) selbst auswerten, kein Wireshark noetig
python3 ble_pklg_decode.py "<datei>.pklg" --feature 0x09

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
