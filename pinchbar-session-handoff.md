# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 26.07.2026, ca. 20:15 CEST. Session pausiert mitten in Abschnitt 3.7 (Option C).

**Zweck:** Kontext der Recherche kompakt festhalten, damit eine neue Session ohne
Wiederholung der Recherche fortsetzen kann.

**Ziel:** Die Daumentasten (Back/Forward, HID++ CID 83/86) der Logitech MX Anywhere 3
(gekoppelt via macOS-Bluetooth) als echte Down/Up-Events für PinchBar (`~/Devel/PinchBar`,
`OtherMouseZoomMapping`) nutzbar machen – bisher geht das nur mit der mittleren Maustaste.

**Aktiver Stand:** Beide Geräte (MX Anywhere 3, MX Keys) sind testweise von Bluetooth auf einen
**Logitech-Unifying-USB-Dongle** umgepairt (nicht Bolt), um rohen HID++-Zugriff zu ermöglichen
(bei direktem BLE kernelseitig durch macOS blockiert). Der Dongle ist **nur Testaufbau** – das
eigentliche Ziel bleibt, die Events später über Bluetooth abzugreifen (siehe Abschnitt 3.7,
"Offene Frage"). Umgebung ist aufgesetzt (venv + hidapi, HID++-Rohkanal des Dongles
identifiziert), die eigentliche HID++-2.0-Implementierung (Root.GetFeature, setCidReporting)
ist der unmittelbar nächste Schritt (noch nicht geschrieben) – siehe Abschnitt 5.

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

**Nächster Schritt (noch NICHT begonnen):** Vollständige HID++-2.0-Implementierung in Python,
siehe Abschnitt 5 Priorität 1 für den konkreten Ablaufplan. Referenz-Vorlage im selben Repo:
`query_feature_index.py` (Windows/BLE-orientiert, zeigt aber das korrekte Root::GetFeature-
Byte-Framing, direkt übertragbar).

**Referenz für Byte-Formate:** https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html,
https://lekensteyn.nl/files/logitech/ (Short/Long-Report-Grundlagen).

**Offene Frage / Rückkopplung zu Bluetooth:** Sobald Option C über den Dongle funktioniert,
bleibt die Kernfrage, wie das auf BLE übertragen wird (`IOHIDDeviceOpen()` bleibt dort
blockiert). Zwei Ideen, beide ungeprüft:
- **CoreBluetooth-GATT direkt statt IOHIDManager:** Logitech-BLE-Mäuse exponieren HID++
  vermutlich über einen vendor-spezifischen GATT-Service. Die macOS-Sperre betrifft
  spezifisch `IOHIDManager`/Input-Device-Handling, nicht zwingend rohen `CoreBluetooth`-GATT-
  Zugriff (andere API-Ebene, für Nicht-Input-Peripherals normal nutzbar). Müsste mit einem
  kleinen Swift/CoreBluetooth-Testprogramm verifiziert werden.
- Falls das nicht klappt: zurück zu Priorität 2 (Options+-IPC-Schema finden), da Options+
  selbst nachweislich BLE-HID++-Zugriff hat.

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

**PRIORITÄT 1 – Option C weiterführen (Abschnitt 3.7):**

1. Skript schreiben (Vorlage: `query_feature_index.py`), das über `.venv` den HID++-Interface-
   Pfad (`usage_page 0xFF00`) öffnet und:
   - Short Reports (7 Byte: `0x10, deviceIndex, featureIndex, funcId<<4|swId, data0, data1, data2`)
     senden/empfangen kann.
   - `Root.GetFeature(0x1B04)` an Device-Indizes `0x01`–`0x06` durchprobiert, bis der Index der
     MX Anywhere 3 gefunden ist (nicht MX Keys o. ä. am selben Dongle).
   - Feature-Index cached, `getCidInfo`/`getCount` aufruft, CIDs 82/83/86/196 verifiziert.
   - `setCidReporting(83, divert=1)` und `(86, divert=1)` sendet.
   - Auf Long-Report-Notifications (`0x11`, `divertedButtonsEvent`) lauscht und dekodiert.
2. Nutzer bittet Back/Forward zu drücken, Down/Up-Sauberkeit prüfen (hier idealerweise ohne
   Re-Arm-Bedarf, da natives HID++-Notification-Modell).
3. **Danach sofort Bluetooth-Rückübertragung angehen** (nicht vergessen – eigentliches Ziel!):
   CoreBluetooth-Testprogramm (Swift), das GATT-Services der Maus auflistet und prüft, ob ein
   Logitech-vendor-spezifischer Service (nicht Standard-HID-over-GATT) sichtbar ist und sich
   darüber HID++-Frames senden/empfangen lassen.

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
