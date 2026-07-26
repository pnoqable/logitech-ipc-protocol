# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 26.07.2026, ca. 21:35 CEST. Session **pausiert auf Nutzerwunsch** mitten im
CoreBluetooth-Experiment (Abschnitt 3.7, "Offene Frage"). Priorität 1 (Option C) ist
**vollständig abgeschlossen und funktioniert** (Back/Forward liefern saubere Down/Up-Events
über den Unifying-Dongle). Das CoreBluetooth-GATT-Experiment hat den richtigen Kanal
gefunden, aber das Byte-Format ist noch nicht entschlüsselt – siehe Abschnitt 3.7 für den
exakten Stand und die empfohlenen nächsten Schritte (Packet-Sniff von echtem Options+-Traffic).

**Zweck:** Kontext der Recherche kompakt festhalten, damit eine neue Session ohne
Wiederholung der Recherche fortsetzen kann.

**Ziel:** Die Daumentasten (Back/Forward, HID++ CID 83/86) der Logitech MX Anywhere 3
(gekoppelt via macOS-Bluetooth) als echte Down/Up-Events für PinchBar (`~/Devel/PinchBar`,
`OtherMouseZoomMapping`) nutzbar machen – bisher geht das nur mit der mittleren Maustaste.

**Aktiver Stand:** MX Anywhere 3 und MX Keys sind aktuell **sowohl** über den
Logitech-Unifying-USB-Dongle **als auch** über direktes macOS-Bluetooth gekoppelt (Letzteres
wurde in dieser Session für den CoreBluetooth-Test neu eingerichtet, siehe Abschnitt 3.7).
Der Dongle bleibt **nur Testaufbau** – das eigentliche Ziel ist der Bluetooth-Pfad. Der
Logi-Options+-Agent (`com.logi.cp-dev-mgr`) wurde während der Session kurzzeitig gestoppt
(um GATT-Traffic ohne Störgeräusch zu beobachten) und am Ende wieder gestartet – Status vor
Fortsetzung kurz prüfen (`launchctl list | grep cp-dev-mgr`, sowie ob Maus/Tastatur normal
funktionieren).

**✅ Priorität 1 erledigt:** `hidpp_thumb_buttons.py` implementiert die volle HID++-2.0-Kette
(Root.GetFeature, getCount/getCidInfo, setCidReporting, divertedButtonsEvent-Decoding) und wurde
live gegen die echte Hardware verifiziert – siehe Abschnitt 3.7 für Details und exakte
Byte-Layouts. Back/Forward liefern zuverlässig getrennte DOWN/UP-Events, auch bei gehaltener
Taste (kein Einzel-Trigger-Problem). Nächster Schritt: CoreBluetooth-GATT-Test (Abschnitt 3.7,
"Offene Frage"), danach PinchBar-Integration (Abschnitt 5, letzter Absatz).

---

## 1. Ausgangsproblem

PinchBar (macOS-Menüleisten-App) transformiert Multitouch-Gesten in Scroll-/Tasten-Events.
`OtherMouseZoomMapping` bildet Taste-halten + Scrollen auf ein Magnify-Event ab – funktioniert
bisher nur mit der mittleren Maustaste (schlechte UX wegen gleichzeitigem Scrollen). Ziel: die
Daumentasten der MX Anywhere 3 nutzbar machen, ohne dass Logi Options+ sie abfängt. Gebraucht
werden echte Down/Up-Events (kein Einzel-Trigger), da PinchBar "gehaltene Taste + Scrollen"
braucht. Maus-Kopplung ursprünglich: direktes macOS-Bluetooth (BLE).

---

## 2. Erkenntnisstand – Übersicht

| Ansatz | Status |
|---|---|
| Logi Actions SDK | ❌ Nicht anwendbar (nur Creative Console/Loupedeck/Actions Ring), zudem nur Einzel-Trigger |
| Options+ Keystroke-/Gesture-Zuweisung | ❌ Nur Einzel-Trigger, kein Hold-Zustand exportierbar |
| Roher HID/HID++ direkt (IOHIDManager) | ⚠️ Technisch exakt richtig (Feature `0x1B04`), aber kernelseitig blockiert bei direktem Bluetooth. Kein Bypass für Drittanbieter-Apps. Workaround: über USB-Dongle koppeln → **Option C, aktiv in Arbeit** |
| Options+ IPC – geratene `SUBSCRIBE`-Pfade | ❌ Bestätigt wirkungslos |
| Options+ IPC – `/input_tracker/*` | 🟡 Funktioniert für Standard-Maustasten, **beweisbar Sackgasse für CID-Daumentasten** (vollständiger Filter-Enum ausgelesen, kein CID-Wert vorhanden) |
| Options+ IPC – `/devices/special_keys_divert_state/configure` | 🟡 Pfad existiert nachweislich, exaktes JSON-Feldschema trotz vieler Versuche nicht gefunden – Raten ausgereizt, siehe Abschnitt 5 Priorität 2 |

---

## 3. Technischer Hintergrund

### 3.1–3.2 Offizielle SDK/UI-Wege – nicht anwendbar
- Logi Actions SDK: nur für MX Creative Console/Loupedeck/Actions Ring, kein Down/Up-Modell.
- Options+ Gesture-/Keystroke-Zuweisung: feuert nur als Einzel-Trigger, kein roher Hold-Zustand.

### 3.3 Roher HID/HID++-Zugriff – Kernfakten
- **HID++ 2.0 Feature `0x1B04`** ("Special Keys and Mouse Buttons"), dokumentiert unter
  https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html.
  `setCidReporting(cid, divert=1)` lenkt eine Taste um; Firmware sendet dann bei
  Zustandsänderung ein `divertedButtonsEvent` mit Liste aktuell gedrückter CIDs (erscheint=Down,
  verschwindet=Up).
- **MX Anywhere 3 CIDs:** 82=Middle, 83=Back, 86=Forward, 196=SmartShift
  (`specialKeys.programmable`, bestätigt via `/devices/list`).
- **Warum roher Zugriff bei BLE nicht geht:** macOS blockiert `IOHIDDeviceOpen()` für
  Bluetooth-Input-Geräte kernelseitig, für jede App (nicht nur Drittanbieter). Die Behauptung,
  Options+ würde dies über das öffentliche Entitlement `com.apple.security.device.bluetooth`
  umgehen, ist falsch – wie Options+ tatsächlich BLE-HID++-Zugriff bekommt, ist ungeklärt
  (vermutlich privates Hardware-Partner-Entitlement).
- **Praktischer Ausweg:** Maus über Logitech-Bolt/Unifying-USB-Dongle statt direktem Bluetooth
  koppeln → HID++ läuft dann als normaler USB-HID-Transport, nicht unter die BT-Sperre. →
  Umgesetzt in Abschnitt 3.7.

### 3.4 Options+ IPC-Unix-Socket – Protokoll-Basics
- Referenz-Repo (dieses Repo): `~/Devel/logitech-ipc-protocol`. **Achtung:** `origin` zeigt auf
  das fremde Original (`saimanish1`), nicht auf einen eigenen Fork – vor Commits/Push ggf. erst
  forken und Remote umbiegen.
- Socket: `/tmp/logitech_kiros_agent-<hash>` (Hash ändert sich bei Agent-Neustart, nie hardcoden,
  per Glob suchen).
- Wire-Format: `LE32(total_len) + BE32(proto_name_len) + "json" + BE32(msg_len) + JSON`.
- Verbs: `GET`, `SET`, `SUBSCRIBE`, `UNSUBSCRIBE`, `BROADCAST`. Requests: `msg_id` (snake_case),
  Responses: `msgId` (camelCase).
- Aktuelle Device-IDs (Stand 26.07., ändern sich bei Re-Pairing): MX Anywhere 3S = `dev00000041`,
  MX Keys = `dev00000040`, Unifying-Empfänger = `dev00000042`. `connectionType` zeigte vor dem
  Umpairing `"BLE"`.

### 3.5 Negativ-Ergebnis: geratene SUBSCRIBE-Pfade
- Weder eigene Tests (11 geratene Pfade, 30s, alle Maustasten gedrückt) noch das Referenz-Repo
  (`TODO.md`, Easy-Switch-Knopf) konnten je ein Event über geratene `SUBSCRIBE`-Pfade empfangen.
  Der Agent broadcastet Button-Events nicht automatisch.

### 3.6 `/input_tracker/*` API – funktioniert, aber Sackgasse für CID-Tasten
- Entdeckt via MITM-Proxy (`sniff_button_events.py proxy`): `SET /input_tracker/start
  {"filter": [...]}` + `SUBSCRIBE /input_tracker/events` liefert `BROADCAST`-Events mit
  `isDown`-Flag für Tastatur (`filter: ["KEYBOARD"]`) und Standard-Maustasten
  (`filter: ["MOUSE_BUTTON"]`, Event z. B. `{"mouse": {"button": {"hidUsage": 1, "isDown": true}}}`).
  `"MOUSE"` ist **kein** gültiger Wert (`INVALID_ARG`).
- **Re-Arm-Pattern nötig:** `start` liefert immer nur genau ein Folge-Event, danach verstummt der
  Broadcast – für kontinuierliche Events muss nach jedem empfangenen Event sofort neu
  `SET /input_tracker/start` gesendet werden (Tool: `sniff_repeat.py --restart`).
- **Negativ-Befund Daumentasten:** CID 83/86 (Back/Forward) liefern über diesen Pfad **null
  Events**, egal mit welchem Filter, während linke Maustaste im selben Test zuverlässig
  weiterläuft (Sanity-Check bestanden). Interpretation: `/input_tracker/*` sieht nur generische
  OS-Level-HID-Events, CID-Buttons werden vom Agent intern direkt an die Assignment-Logik
  weitergereicht, nie an den IPC-Broadcast.
- **Autoritativ bestätigt per Protobuf-Reflection aus der Binary** (`strings -a` auf
  `logioptionsplus_agent`, nicht gestrippt): `enum Filter { NONE, MOUSE_MOVE, MOUSE_BUTTON,
  MOUSE_WHEEL, KEYBOARD }` – **kein weiterer Wert existiert**, also architektonisch keine
  Möglichkeit für CID-Events über diesen Pfad.
- **Zusätzlicher Fund im selben Descriptor-Pool** (`logi.protocol.devices`), relevant für
  Priorität 2 (Abschnitt 5):
  ```protobuf
  message DivertStateRequest { int32 control_id; bool divert; bool raw_xy; bool raw_wheel; }
  message SpecialKeysDivertRequest { repeated DivertStateRequest control_ids_list; }
  message DivertState { int32 control_id; bool divert; }
  message SpecialKeysDivertState { repeated DivertState control_ids_list; }
  message TestKeyState { int32 ctrl_id; bool is_diverted, is_diverted_valid;
    bool is_persistently_diverted, is_persistently_diverted_valid;
    bool is_raw_xy_reporting, is_raw_xy_reporting_valid;
    bool is_force_raw_xy_reporting, is_force_raw_xy_reporting_valid;
    int32 remapped_id; bool is_reporting_analytics, is_reporting_analytics_valid;
    bool is_raw_wheel_reporting, is_raw_wheel_reporting_valid; }
  message TestDeviceKeysState { repeated TestKeyState states; }
  message TestCidList { string device_id; }
  message TriggerEvent { string device_id; Device.Type device_type; string slot_id;
    TriggerEvent.State state; /* enum State { INACTIVE, START, ONE_SHOT } */ ... }
  ```
  Symbol `feature_x1b04_special_keys` (`_process_key_gesture_event`) bestätigt: Feature `0x1B04`
  ist intern im Agent tatsächlich implementiert.
- **Pfad `SET /devices/special_keys_divert_state/configure`:** existiert nachweislich (`GET` →
  "no handler", `SET {}` → kommt durch JSON-Parser, liefert Applikationsfehler "Invalid
  special_keys_divert_state settings"). Aber: Jeder Versuch mit echten Feldnamen (aus obigen
  Message-Definitionen abgeleitet, alle plausiblen camelCase-Varianten) schlägt mit
  `INVALID_MESSAGE_RECEIVED` fehl – die Pfad→Message-Zuordnung ist aus reinen Strings nicht
  ableitbar. Nächster sinnvoller Schritt wäre Ghidra/objdump statt weiterem Raten (siehe
  Abschnitt 5, Priorität 2).
- Ad-hoc-Test-Tools (noch nicht committed): `sniff_repeat.py` (Re-Arm-Loop), `test_divert.py`
  (Payload-Varianten für `/configure`).

### 3.7 IN ARBEIT (pausiert): Rohes HID++ 2.0 über Logitech-Unifying-Dongle (Option C)

**Entscheidung:** Statt weiter im Options+-IPC-Schema zu raten, den offiziell dokumentierten
HID++-2.0-Weg (Abschnitt 3.3) selbst implementieren, mit der Maus über einen physischen Dongle
gekoppelt (umgeht die macOS-BLE-Kernel-Sperre für rohen HID-Zugriff).

**Ziel-Klarstellung (nicht vergessen):** Der Dongle ist nur Testaufbau zum
Verstehen/Validieren des Protokolls. Endziel bleibt Bluetooth-Zugriff – jeder hier gefundene
Baustein muss am Ende auf BLE-Übertragbarkeit geprüft werden (siehe "Offene Frage" unten).

**Hardware:** Logitech **Unifying**-Empfänger (nicht Bolt), Maus ist reguläre **MX Anywhere 3**
(kein 3S). Für rohen USB-HID-Transport gleichwertig zu Bolt.

**Bereits erledigt:**
1. Umpairing verifiziert (`sniff_button_events.py devices`):
   `dev00000040` MX Keys, `dev00000041` MX Anywhere 3 (beide "via USB Receiver"),
   `dev00000042` Logi Unifying receiver (USB). Device-IDs unverändert gegenüber BLE-Zeit.
2. Raw-HID-Python-Zugriff aufgesetzt (System-Python ist SIP-geschützt, daher Homebrew-Python):
   ```bash
   brew install hidapi
   brew install python@3.12
   cd ~/Devel/logitech-ipc-protocol
   /opt/homebrew/bin/python3.12 -m venv .venv
   .venv/bin/pip install hid
   ```
   Aufruf-Pattern: `DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 <script>.py`
3. HID-Interfaces des Dongles identifiziert (vendor_id `0x046d`, product_id `0xC52B`,
   `product_string: 'USB Receiver'`), drei Interface-Gruppen:
   | interface_number | usage_page(s) | Bedeutung |
   |---|---|---|
   | 0 | 1 (usage 6 = Keyboard) | Tastatur-Reports |
   | 1 | 1 (usage 1/2), 12 (Consumer), 65468 (vendor) | Standard-Maus/Consumer |
   | **2** | **65280 (0xFF00, vendor-spezifisch)**, usages 1/2/4 | **HID++-Rohkanal** (Short/Long/Very-Long-Reports) |

   Interface 2 ist der relevante Kanal (Short Reports 7 Byte, Report-ID `0x10`; Long Reports
   20 Byte, Report-ID `0x11`). ⚠️ `path`-Werte (`DevSrvsID:...`) sind IOKit-Session-IDs, ändern
   sich pro Neuverbindung – vor jedem Testlauf per `hid.enumerate()` neu ermitteln.

**✅ Erledigt (neu):** Vollständige HID++-2.0-Implementierung in Python:
`hidpp_thumb_buttons.py`. Live gegen echte Hardware verifiziert. Wichtige Erkenntnisse für
Folgesessions:

- **Device-Index MX Anywhere 3 = 0x04** (nicht 0x01 – das ist die MX Keys am selben Dongle,
  erkennbar an CIDs ohne `mouse`-Flag/mit `fkey`-Flag statt Maustasten-CIDs 82/83/86). Index
  kann sich aber bei Re-Pairing ändern, daher im Skript weiterhin dynamisch über CID-Table
  ermittelt, nicht hardcodiert.
- **Feature-Index von 0x1B04 auf der MX Anywhere 3 = 0x09** (auf MX Keys: 0x08) – ändert sich
  potenziell pro Firmware/Gerät, wird von `Root.GetFeature` ermittelt.
- **CID-Tabelle MX Anywhere 3** (7 Einträge): 80=Left, 81=Right (beide nicht divertable),
  82=Middle, 83=Back, 86=Forward, 196=SmartShift (alle divertable), 215=virtueller Eintrag
  (mouse-Flag=0, divertable=1, vermutlich Gesture-Button-Ziel).
- **Überraschung beim Response-Framing:** Anfragen wurden als 7-Byte-Short-Report (`0x10`)
  gesendet, aber der Dongle antwortet auf `Root.GetFeature`/`getCidInfo` mit einem **Long-Report
  (`0x11`, 21 Byte inkl. Report-ID)**, obwohl die Anfrage kurz war. Der Parser muss daher beide
  Report-IDs als gültige Antwortformate akzeptieren (Header-Layout ab Byte 2 ist identisch,
  Long-Report ist nur weiter mit Nullen aufgefüllt).
- **Multiplexing/Nebenläufigkeit:** Auf dem HID++-Rohkanal treffen laufend Antworten *und*
  Benachrichtigungen anderer Geräte/Features ein. Jede Anfrage muss die Antwort anhand
  `devIndex` + `featureIndex` + `funcId/swId`-Echo filtern und alles andere ignorieren
  (sonst werden stale/fremde Frames fälschlich als Antwort interpretiert – trat in einem
  Zwischentest tatsächlich auf).
- **`setCidReporting` braucht den Long-Report**, da die Anfrage 5 Parameterbytes benötigt
  (cid msb/lsb, flags, remap msb/lsb) – mehr als die 3 Datenbytes eines Short-Reports.
- **Notification-Erkennung:** `divertedButtonsEvent` hat `swId == 0` (Bit 0-3 von Byte 3) und
  `funcId == 0` (Bit 4-7); das unterscheidet es zuverlässig von einer Funktions-Antwort
  (die immer die von uns gewählte, von 0 verschiedene `swId` echot).
- **Ergebnis:** Back/Forward liefern über `setCidReporting(divert=1)` + Decodierung von
  `divertedButtonsEvent` saubere, wiederholbare DOWN/UP-Events, auch bei gehaltener Taste.

**Referenz für Byte-Formate:** https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html,
https://lekensteyn.nl/files/logitech/ (Short/Long-Report-Grundlagen).

**🟡 Offene Frage / Rückkopplung zu Bluetooth – IN ARBEIT, wichtiger Zwischenstand:**

**✅ Bestätigt: CoreBluetooth-GATT-Zugriff funktioniert und umgeht die IOHIDManager-Sperre.**
Getestet mit `ble_gatt_probe.swift` (Discovery/Service-Dump) und `ble_hidpp_probe.swift`
(Schreib/Notify-Test), beide im Repo-Root, ausführbar via `swift <script>.swift` (kein
Xcode-Projekt nötig, Swift-Interpreter-Modus reicht).

- Maus wurde testweise zusätzlich/wieder per direktem macOS-Bluetooth gekoppelt (Kanal-Switch
  an der Mausunterseite + Bluetooth-Pairing-Dialog). `system_profiler SPBluetoothDataType`
  zeigt sie danach unter "Connected" mit eigener Product-ID (**0xB025** für BLE, anders als
  0xC52B für den Dongle – erwartbar, unterschiedliche Transportarten).
- **Wichtig:** Ein `CBCentralManager.scanForPeripherals()` findet die Maus NICHT (sie
  advertised nicht mehr, da bereits verbunden). Stattdessen funktioniert
  `retrieveConnectedPeripherals(withServices:)` mit den Standard-Service-UUIDs `180F`
  (Battery) oder `180A` (Device Information) als Filter – das liefert die bereits verbundene
  MX Anywhere 3 *und* MX Keys zuverlässig, auch ohne vorheriges Scannen.
- **Service-Struktur pro Gerät** (per `discoverServices`/`discoverCharacteristics`): neben den
  Standard-Services (Device Information `180A`, Battery `180F`) existiert ein
  **vendor-spezifischer Service `00010000-0000-1000-8000-011F2000046D`** mit genau einer
  nicht-standard Characteristic **`00010001-0000-1000-8000-011F2000046D`**
  (Properties: `read, write, writeWithoutResponse, notify`). Das ist mit hoher
  Wahrscheinlichkeit der gesuchte HID++-Tunnel über GATT.
- **Bestätigung, dass Options+ genau diesen Kanal nutzt:** Direkt nach dem ersten Schreibversuch
  auf diese Characteristic (bei laufendem `com.logi.cp-dev-mgr`-Agenten) kam eine Flut von
  Notifications rein, obwohl die Maus unbewegt auf dem Tisch lag – das ist mit hoher
  Wahrscheinlichkeit Options+' eigener Hintergrund-Traffic auf derselben Characteristic (macOS
  erlaubt mehreren Apps/Prozessen parallelen GATT-Zugriff auf dieselbe physische BLE-Verbindung
  via `bluetoothd`-Multiplexing). Nach `launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr`
  (Options+-Agent temporär gestoppt) verschwand das Rauschen komplett – jeder eigene Write
  erzeugte danach genau eine Antwort. **Agent wurde am Ende wieder gestartet** via
  `open "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app"`
  (⚠️ `launchctl kickstart -k` griff nach `bootout` nicht mehr, da der Job dadurch komplett
  entladen war, nicht nur gestoppt – für einen reinen Neustart ohne `bootout` reicht
  `kickstart -k` wie in Abschnitt 8 dokumentiert; nach vollem `bootout` muss die App stattdessen
  neu geöffnet werden).
- **🔴 Byte-Format noch NICHT entschlüsselt:** Ein `Root.GetFeature(0x1B04)`-Request im exakt
  gleichen Kurz-Report-Format wie über USB (`0x10, devIdx, featIdx, funcId<<4|swId, d0,d1,d2`)
  wurde testweise mit devIdx `0x00`/`0x01`/`0xFF` und mit/ohne führendes `0x10`-Marker-Byte
  gesendet. Alle Varianten lieferten *eine* saubere, in sich konsistente Antwort (Beweis: es ist
  ein echter Request/Response-Kanal, kein Zufalls-Rauschen), aber:
  - Für devIdx `0x00`/`0x01` (mit Marker-Byte) wurden Marker, devIdx und featIdx exakt
    korrekt echot (`10 00 00 00...` bzw. `10 01 00 00...`), aber das erwartete `funcId<<4|swId`
    (`0x05`) kam als `0x00` zurück – d.h. entweder ist die Response-Struktur ab dieser Stelle
    keine reine Echo-Struktur mehr (sondern schon Nutzdaten, was auf "Feature nicht gefunden"
    hindeuten würde), oder das Request-Encoding (z. B. `swId`-Wert, Function-Nibble-Reihenfolge)
    unterscheidet sich vom USB-Schema.
  - Für devIdx `0xFF` sah die Antwort strukturell anders aus (`ff 10 ff 07 00...`), was nach
    einer Fehlerantwort aussieht (`0x07` = `INVALID_FUNCTION` im HID++-2.0-Fehlerschema) –
    spricht dafür, dass `0xFF` als Geräteindex hier ungültig ist (plausibel: bei einer direkten
    BLE-Verbindung gibt es nur ein Gerät, keinen Multi-Device-Empfänger wie beim Dongle).
  - **Nächste sinnvolle Schritte zum Knacken des Byte-Formats** (noch nicht versucht):
    1. Bei laufendem Options+ eine echte Feature-0x1B04-Aktion in der UI auslösen (z. B.
       SmartShift-Regler bewegen) und dabei mit Apple's PacketLogger/Bluetooth-Diagnose
       (`Xcode > Open Developer Tool > Bluetooth`, oder `/usr/local/bin/PacketLogger` falls
       Additional Tools installiert) den echten Request/Response-Bytestream mitschneiden –
       liefert eine garantiert korrekte Referenz zum Abgleich, statt weiter zu raten.
    2. Systematisch `swId`-Werte 0x1–0xF und ggf. vertauschte Nibble-Reihenfolge
       (`swId<<4|funcId` statt `funcId<<4|swId`) durchprobieren, jeweils bei gestopptem
       Options+-Agent (sonst Störgeräusch).
    3. Prüfen, ob die Characteristic-Länge (19 Byte Antwort beobachtet) eine feste
       Long-Report-Größe ist und ob es eine zweite, noch nicht entdeckte Characteristic für
       kurze vs. lange Reports gibt (bei den bisherigen Scans wurde nur eine gefunden – ggf.
       lohnt ein Blick mit `discoverDescriptors`/CCCD oder erneuter Service-Dump mit mehr
       Geduld).
  - Tools: `ble_gatt_probe.swift` (allgemeiner Service/Characteristic-Dump, per Name oder
    Logitech-Manufacturer-ID `0x0060` erkennbar), `ble_hidpp_probe.swift` (gezielter
    Schreib/Notify-Test gegen die Vendor-Characteristic mit den Framing-Hypothesen).

- Falls das Byte-Format sich nicht zeitnah knacken lässt: zurück zu Priorität 2 (Options+-IPC-
  Schema finden), da Options+ selbst nachweislich BLE-HID++-Zugriff hat – aber jetzt mit dem
  Wissen, DASS und WORÜBER es das tut (GATT-Characteristic `00010001-...`), was auch der
  Ghidra-Analyse aus Priorität 2 eine sehr konkrete Suchspur gibt (nach Code suchen, der diese
  Characteristic-UUID oder den Service `00010000-...` referenziert).

---

## 4. Tooling

**Ort:** `~/Devel/logitech-ipc-protocol/sniff_button_events.py` (bewusst getrennt von PinchBar).

| Modus | Zweck | Status |
|---|---|---|
| `devices` | `/devices/list` abfragen, Device-IDs finden | ✅ |
| `subscribe` | Rät `SUBSCRIBE`-Pfade | ✅ bestätigt keine Events |
| `input_tracker` | `/input_tracker/start` + `SUBSCRIBE` | ✅ funktioniert (Standardtasten) |
| `proxy` | MITM Options+-UI ↔ Agent-Socket | ✅ |
| `ws` | WebSocket-Port 59869 | Implementiert, nie getestet |

**Neu (Option C, Abschnitt 3.7):** `hidpp_thumb_buttons.py` – rohes HID++ 2.0 über den
Unifying-Dongle, findet MX Anywhere 3 dynamisch, divertiert Back/Forward, gibt DOWN/UP-Events
aus. ✅ Live verifiziert. Aufruf: `DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3
hidpp_thumb_buttons.py` (Ctrl-C zum Beenden, setzt Divert automatisch zurück).

**Gefixte Bugs (falls Tool wieder komisch reagiert):**
1. Frame-Parser hing bei großen Nachrichten (Limit war 5 MB, Byte-für-Byte-Resync) → Limit auf
   64 MB, Resync mit 4096-Byte-Fenster, Rohdaten werden immer zuerst weitergeleitet.
2. Race Condition beim Cleanup löschte versehentlich den echten Agent-Socket erneut → Custom-
   SIGINT-Handler entfernt, Cleanup läuft nur noch einmal (idempotent).
3. Nach Bug 2 muss der Agent neu gestartet werden: `launchctl kickstart -k gui/$(id -u)/com.logi.cp-dev-mgr`,
   dann prüfen ob Socket unter `/tmp/logitech_kiros_agent-*` wieder auftaucht.

Weitere Ad-hoc-Skripte (noch nicht committed): `sniff_repeat.py` (Re-Arm-Loop für
`input_tracker`), `test_divert.py` (Payload-Varianten für `/configure`).

---

## 5. Nächste Schritte (priorisiert)

**✅ PRIORITÄT 1 – Option C – ERLEDIGT (Abschnitt 3.7):**

1. ~~Skript schreiben~~ → `hidpp_thumb_buttons.py`, vollständig implementiert und live
   verifiziert (Root.GetFeature-Discovery über Device-Indizes, getCount/getCidInfo,
   setCidReporting, divertedButtonsEvent-Decoding). Details siehe Abschnitt 3.7.
2. ~~Nutzer bittet Back/Forward zu drücken~~ → getestet, saubere DOWN/UP-Events für beide
   Tasten, mehrfach wiederholt, auch bei gehaltener Taste. Kein Re-Arm-Bedarf nötig (natives
   HID++-Notification-Modell wie erwartet).
3. **NÄCHSTER SCHRITT – Bluetooth-Rückübertragung (nicht vergessen – eigentliches Ziel!):**
   CoreBluetooth-Testprogramm (Swift), das GATT-Services der Maus auflistet und prüft, ob ein
   Logitech-vendor-spezifischer Service (nicht Standard-HID-over-GATT) sichtbar ist und sich
   darüber HID++-Frames senden/empfangen lassen. **Voraussetzung:** MX Anywhere 3 muss dafür
   (zumindest testweise) wieder über direktes macOS-Bluetooth gekoppelt sein statt über den
   Unifying-Dongle – aktuell offen, ob die alte BT-Kopplung noch besteht oder neu eingerichtet
   werden muss (Kanal-Umschaltung am Geräte-Schalter + macOS-Bluetooth-Pairing-Dialog).

**PRIORITÄT 2 – falls Option C oder der BLE-Teil scheitert, zurück zum Options+-IPC-Weg:**

1. **Registrierungscode für `special_keys_divert_state/configure` in Ghidra/objdump
   lokalisieren** (`logioptionsplus_agent`-Binary), um zu sehen welcher Protobuf-Message-Typ
   per `JsonStringToMessage`/`ParseFromString` auf das Payload angewendet wird – liefert exakte
   Feldnamen ohne Raten.
2. Alternativ: MITM-Proxy während einer versteckten Test-/Debug-Ansicht der UI (die
   `Test*`-Messages aus 3.6 deuten auf eine interne QA-Oberfläche hin).
3. Vorteil gegenüber Option C: funktioniert nachweislich auch mit BLE-gekoppelten Geräten.

**Sobald ein Weg (C oder A) tatsächlich CID-Events liefert – über Dongle UND über Bluetooth:**
Architektur-Entwurf für PinchBar-Integration (vermutlich separater Helper-Prozess, der Down/Up
über IPC an PinchBar weiterreicht, dort behandelt wie synthetisches `otherMouseDown/Up`).
Bei Option A ggf. weiteres Re-Arm-Pattern nötig; Lizenz-Hinweis: Option A bleibt undokumentiertes,
jederzeit änderbares Protokoll, Option C ist robuster (offiziell dokumentiertes HID++).

---

## 6. Empfehlung zur Arbeitsumgebung

Auf dem echten Mac mit echter Maus + laufendem Options+ weiterarbeiten, nicht in eine Cloud-/
Remote-Sandbox wechseln – die Recherche ist zu 100 % hardware-/GUI-gebunden (Bluetooth,
physische Tastendrücke, Options+-Prozess).

Jetzt wo Ghidra zur Verfügung steht: für die native Agent-Binary nutzen, um die Protobuf-
Descriptor-Pool-Extraktion (Priorität 2) zu Ende zu bringen. Für die Electron-UI reicht
weiterhin `npx asar extract`.

**Fork-Erinnerung:** Vor dem ersten Commit `saimanish1/logitech-ipc-protocol` forken und
`origin` umbiegen (zeigt aktuell auf das fremde Original).

---

## 7. Referenzen

- PinchBar-Code: `~/Devel/PinchBar` (`OtherMouseZoomMapping.swift`, `OtherMouseScrollMapping.swift`,
  `Utilities/CGEventExtensions.swift`, `MultitouchSupport.mm`)
- Referenz-Repo: https://github.com/saimanish1/logitech-ipc-protocol (lokal hier, insbesondere
  `logi-options-ipc-reverse-engineering.md`, `api-reference.md`, `TODO.md`)
- HID++ 2.0 Feature 0x1B04: https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
- Weitere HID++-Dokus: https://lekensteyn.nl/files/logitech/, https://github.com/cvuchener/hidpp,
  https://github.com/pwr-Solaar/Solaar (beide nur Linux/Windows)
- Logi Actions SDK (nicht anwendbar): https://logitech.github.io/actions-sdk-docs/
- Sniffer-Tool: `sniff_button_events.py`; Re-Arm-Test: `sniff_repeat.py`; Divert-Test:
  `test_divert.py`; Windows-Referenz für Root::GetFeature-Framing: `query_feature_index.py`
- Raw-HID++-Testumgebung: `.venv` (Python 3.12 via Homebrew, Paket `hid`), benötigt
  `brew install hidapi` + `DYLD_LIBRARY_PATH=/opt/homebrew/lib`. Noch kein eigenes
  HID++-Protokoll-Skript geschrieben (nur Enumeration getestet).

---

## 8. Kurzreferenz: Wichtige Befehle

```bash
# Agent-Socket-Status prüfen
ls -la /tmp/ | grep -i logitech_kiros

# Agent-LaunchAgent neu starten (falls Socket kaputt/verschwunden)
launchctl kickstart -k gui/$(id -u)/com.logi.cp-dev-mgr

# Geräte + Device-IDs auflisten
cd ~/Devel/logitech-ipc-protocol
python3 sniff_button_events.py devices

# Options+-IPC: Maus-Events testen (funktioniert für Standard-Tasten, NICHT für Daumentasten,
# siehe 3.6; Re-Arm-Pattern in sniff_repeat.py --restart)
python3 sniff_button_events.py input_tracker --filter MOUSE_BUTTON --duration 30

# Falls nötig: MITM-Proxy für weitere UI-Flow-Exploration
python3 sniff_button_events.py proxy > out.txt 2>&1
# ... Options+ UI neu öffnen, gewünschten Flow durchspielen, Ctrl-C ...
grep -n '"verb": "SET"\|SUBSCRIBE\|input_tracker' out.txt | cut -c1-300

# NÄCHSTER SCHRITT (Option C, Abschnitt 3.7): Raw-HID-Zugriff auf den Unifying-Dongle testen
cd ~/Devel/logitech-ipc-protocol
DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 -c "
import hid
for d in hid.enumerate():
    if d.get('vendor_id') == 0x046d:
        print(d)
"
# -> Interface mit usage_page 65280 (0xFF00) ist der HID++-Rohkanal (path ändert sich pro Session!)
# Als Nächstes: HID++-2.0-Framing (Root.GetFeature, setCidReporting) darüber implementieren,
# siehe Abschnitt 3.7/5 für den vollständigen Ablaufplan; query_feature_index.py als Vorlage.
```
</content>
