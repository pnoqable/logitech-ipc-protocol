# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 26.07.2026, ca. 20:15 CEST (verifiziert funktionsfähig zu diesem Zeitpunkt, Session
pausiert auf Nutzerwunsch mitten in Abschnitt 3.7 / Option C)
**Zweck dieses Dokuments:** Kompletten Kontext der bisherigen Recherche festhalten, damit die
Session in einer neuen Umgebung/einem neuen Chat nahtlos fortgesetzt werden kann, ohne die
gesamte Recherche zu wiederholen.

> **WICHTIGSTER HINWEIS FÜR DEN NÄCHSTEN START:** Beide Logitech-Geräte (MX Anywhere 3 **und**
> MX Keys) sind aktuell **nicht mehr per Bluetooth gekoppelt**, sondern über einen **Logitech
> Unifying-USB-Empfänger** (nicht Bolt – der Nutzer hat die MX Anywhere 3, nicht 3S). Das war
> eine bewusste Testumgebungs-Änderung (siehe 3.7), um rohen HID-Zugriff zu ermöglichen (der bei
> direktem Bluetooth kernelseitig blockiert ist). **Das eigentliche Ziel bleibt aber
> ausdrücklich, die Events später auch über Bluetooth abzugreifen** – der Dongle ist nur zum
> Validieren/Verstehen des Protokolls gedacht. Siehe Abschnitt 3.7 für den genauen Stand und
> Abschnitt 5 für die als Nächstes geplanten Schritte (HID++-2.0-Root/Feature-0x1B04-Implementierung,
> noch nicht abgeschlossen).

> **Update 26.07.:** Abschnitt 3.6 (`/input_tracker/*`) wurde zu Ende getestet – siehe
> **3.6a (Re-Arm-Mechanismus)** und **3.6b (Daumentasten-Negativbefund)** unten. Kurzfassung:
> Der Pfad funktioniert einwandfrei für Standard-Maustasten (links/rechts/mitte), aber **nicht**
> für die HID++-CID-Daumentasten (Back/Forward) – das ist vermutlich eine Sackgasse für diese
> spezielle API in Bezug auf unser eigentliches Ziel.
>
> **Update 26.07., später:** Auf Nutzerfrage hin ("könnten noch andere Enums existieren?") wurde
> die Agent-Binary direkt nach dem eingebetteten Protobuf-Schema durchsucht (`strings`, kein
> Ghidra nötig – Reflection ist nicht gestrippt). Ergebnis: **Abschnitt 3.6c** – der
> `input_tracker`-`Filter`-Enum hat autoritativ nur 5 Werte, keiner davon deckt CID-Buttons ab.
> ABER: Es wurde eine **komplett andere, vielversprechende Message-Familie** gefunden
> (`SpecialKeysDivertRequest`, `TestKeyState` mit `is_diverted`-Flags, Feature-Name
> `feature_x1b04_special_keys` – exakte Übereinstimmung mit der HID++-0x1B04-Doku aus
> Abschnitt 3.3!). Der zugehörige IPC-Pfad `/devices/special_keys_divert_state/configure`
> existiert nachweislich (kommt durch den JSON-Parser durch), aber das **exakte Feld-Schema
> des Requests wurde trotz vieler Versuche noch nicht gefunden** – siehe Abschnitt 3.6c für
> Details und Abschnitt 5 für den Vorschlag, wie das sauber (ohne weiteres Raten) zu Ende
> gebracht werden könnte.
>
> **Update 26.07., noch später (aktuellster Stand):** Nutzer hat als Reaktion auf die
> `/configure`-Sackgasse beide Geräte auf einen Logitech-Unifying-Dongle umgepairt, mit dem
> expliziten Ziel, den rohen HID++-Weg (Abschnitt 3.3) direkt selbst zu implementieren, **als
> Blaupause für eine spätere Bluetooth-Lösung**. Raw-HID-Zugriff aus Python wurde erfolgreich
> aufgesetzt (`hidapi` via Homebrew + eigenes venv, da System-Python SIP-geschützt ist). Der
> HID++-Rohkanal des Dongles wurde identifiziert. Die eigentliche HID++-2.0-Implementierung
> (Feature-Discovery, `setCidReporting`) war **in Arbeit, aber noch nicht fertig/getestet**, als
> die Session pausiert wurde. Siehe **Abschnitt 3.7** für den vollständigen Stand.

---

## 1. Ausgangsproblem

PinchBar (macOS-Menüleisten-App, `~/Devel/PinchBar`) transformiert Multitouch-Gesten in
Scroll-/Tasten-Events, u. a. für Pinch-to-Zoom in Cubase. `OtherMouseZoomMapping` bildet
Taste-halten + Scrollen auf ein Magnify-Event ab – funktioniert bisher nur mit der **mittleren
Maustaste**, was wegen gleichzeitigen Scrollens eine schlechte UX ergibt.

**Ziel:** Die Daumentaste(n) der Logitech **MX Anywhere 3S** (Nutzer-Maus; im IPC-Test tauchte
das Vorgängermodell "MX Anywhere 3" auf – vermutlich Tippfehler/Verwechslung des Nutzers, technisch
identische Mechanismen) nutzbar machen, **ohne** dass Logi Options+ die Tasten abfängt/umbelegt.
Wir brauchen echte **Down- und Up-Events** (kein einmaliger Trigger), da PinchBar eine
"gehaltene Taste + Scrollen"-Geste braucht.

**Kopplung der Maus:** Direktes macOS-Bluetooth (kein Logi-Bolt-USB-Empfänger).
Das ist technisch relevant (siehe unten).

---

## 2. TL;DR – aktueller Erkenntnisstand

| Ansatz | Status |
|---|---|
| Logi Actions SDK (offiziell) | ❌ Nicht anwendbar (nur Creative Console/Loupedeck/Actions Ring; zudem nur Einzel-Trigger, kein Down/Up) |
| Options+ Keystroke-/Gesture-Button-Zuweisung | ❌ Nur Einzel-Trigger, kein "Hold"-Zustand exportierbar |
| Roher HID/HID++-Zugriff (IOHIDManager) | ⚠️ Technisch exakt das, was wir brauchen (Feature `0x1B04`, siehe unten) – aber **kernelseitig blockiert**, weil die Maus per **direktem Bluetooth** gekoppelt ist (nicht über Logi-Bolt-Dongle). Kein Workaround/Entitlement hilft hier für Drittanbieter-Apps. |
| Options+ IPC-Unix-Socket – geratene `SUBSCRIBE`-Pfade | ❌ Bestätigt wirkungslos (leerer Test über 30s, alle Maustasten mehrfach gedrückt – nichts kam an). Deckt sich mit dokumentiertem Negativ-Befund für den Easy-Switch-Knopf im Referenz-Repo. |
| Options+ IPC-Unix-Socket – **`/input_tracker/*` API** | 🟡 **Zu Ende getestet, gemischtes Ergebnis.** `filter: ["MOUSE_BUTTON"]` liefert echte `isDown`-Events für **Standard**-Maustasten (links/rechts/mitte) – funktioniert einwandfrei mit Re-Arm-Pattern (Abschnitt 3.6a). Aber: Für die **Daumentasten (Back/Forward, CID 83/86)**, die wir eigentlich brauchen, kommen **null Events** – vermutlich weil HID++-CID-Buttons intern nicht an den IPC-Broadcast weitergereicht werden (Abschnitt 3.6b). **Sehr wahrscheinlich eine Sackgasse für unser eigentliches Ziel.** |

---

## 3. Technischer Hintergrund (Details, mit Quellen)

### 3.1 Logi Actions SDK
- https://logitech.github.io/actions-sdk-docs/ , https://github.com/Logitech/actions-sdk
- Nur für MX Creative Console / Loupedeck / virtuellen "Actions Ring" (Supported-Devices-Seite
  bestätigt das explizit). Normale Mäuse werden nicht als Action-auslösendes Gerät unterstützt.
- Selbst wenn: `PluginDynamicCommand.RunCommand()` feuert nur einmal pro Tastendruck – keine
  Down/Up-Semantik im Plugin-Modell.

### 3.2 Options+ Keystroke-/Gesture-Zuweisung
- Community-Berichte (z. B. Reddit r/logitech, Thread zu "Switch Applications"/Gesture Button)
  bestätigen: Zugewiesene Aktionen/Shortcuts feuern nur als einmaliger Trigger, nicht als
  gehaltene Taste. "Gesture Button"-Modus erkennt Hold+Swipe, aber nur für 4 feste
  Richtungs-Aktionen, kein roher Zustand exportierbar.

### 3.3 Roher HID/HID++-Zugriff
- **HID++ 2.0 Feature `0x1B04`** ("Special Keys and Mouse Buttons") ist offiziell dokumentiert:
  https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
  - `setCidReporting(cid, divert=1)` lenkt eine Taste um: Firmware sendet dann bei
    Zustandsänderung ein `divertedButtonsEvent` mit einer Liste der aktuell gedrückten
    Control-IDs (CID erscheint = Down, verschwindet = Up – **genau das, was wir brauchen**).
  - MX Anywhere 3 CIDs (aus `/devices/list`, `specialKeys.programmable`): **82 = Middle,
    83 = Back, 86 = Forward, 196 = SmartShift**.
- **Warum roher Zugriff nicht geht:** macOS blockiert `IOHIDDeviceOpen()` für Bluetooth-
  Input-Geräte **kernelseitig, ohne Bypass** (bestätigt durch unabhängige Reverse-Engineering-
  Quelle: https://github.com/saimanish1/logitech-ipc-protocol). Das gilt für **jede** App,
  nicht nur Drittanbieter.
- **Wichtige Korrektur/Erkenntnis:** Die Behauptung jener Quelle, Options+ würde dies über das
  Sandbox-Entitlement `com.apple.security.device.bluetooth` umgehen, ist **falsch/ungenau** –
  das ist ein ganz normales, öffentlich verfügbares Entitlement (jeder Entwickler kann es in
  Xcode aktivieren), kein Apple-exklusives Privileg. Wie Options+ tatsächlich Bluetooth-HID++-
  Zugriff bekommt, ist nicht abschließend geklärt (vermutlich ein privates, nur an
  Hardware-Partner vergebenes Bluetooth-Entitlement für tiefere `IOBluetooth`-APIs – für ein
  Community-Projekt realistisch nicht zu bekommen).
- **Praktischer Ausweg wäre:** Maus über **Logi-Bolt-USB-Empfänger** statt direktem Bluetooth
  koppeln – dann ist die HID++-Kommunikation ein normaler USB-HID-Transport, der **nicht**
  unter die Bluetooth-Sperre fällt, und `IOHIDManager` könnte (mit Input-Monitoring-Berechtigung)
  theoretisch mitlesen. **Bisher nicht verfolgt**, da Nutzer direktes Bluetooth nutzt.

### 3.4 Options+ IPC-Unix-Socket – Protokoll-Basics
- Referenz-Repo (bereits lokal ausgecheckt): `~/Devel/logitech-ipc-protocol`
  (Fork-Hinweis: `git remote -v` zeigt **Origin = Original von saimanish1**, nicht der eigene
  Fork! Vor Commits/Push ggf. erst auf GitHub forken und Remote umbiegen.)
- Socket: `/tmp/logitech_kiros_agent-<hash>` (aktuell: `21232f297a57a5a743894a0e4a801fc3`,
  kann sich bei Options+-Neustart ändern – nie hardcoden, immer per Glob suchen).
- Wire-Format: `LE32(total_len) + BE32(proto_name_len) + "json" + BE32(msg_len) + JSON`
- Verbs: `GET`, `SET`, `SUBSCRIBE`, `UNSUBSCRIBE`, `BROADCAST`
- Requests: `msg_id` (snake_case). Responses: `msgId` (camelCase).
- MX Anywhere 3 Device-ID (für diese Session): `dev00000015` (Achtung: kann sich bei
  Re-Pairing ändern – neu per `devices`-Modus abfragen falls nötig).

### 3.5 Negativ-Ergebnis: geratene SUBSCRIBE-Pfade
- Referenz-Repo `TODO.md` dokumentiert für den **Easy-Switch-Knopf** (ebenfalls reiner
  HID++-Button): passiver Listener am Agent-Pipe empfängt **keine** Events beim Tastendruck.
  Der Agent broadcastet Button-Events nicht automatisch an IPC-Clients.
- **Selbst verifiziert** (siehe `sniff_button_events.py subscribe`-Modus): 11 geratene Pfade
  (`/devices/{id}/button_event`, `.../cid_reporting`, `.../divertedButtonsEvent`, etc.) per
  `SUBSCRIBE` angefragt, 30s gewartet, **alle Maustasten der MX Anywhere 3 mehrfach gedrückt**
  → absolut keine Antwort/kein Event. Bestätigt den Negativ-Befund.

### 3.6 DURCHBRUCH: `/input_tracker/*` API
Entdeckt durch **MITM-Proxy** (`sniff_button_events.py proxy`) während in der Options+-UI ein
Maustasten-Slot auf "Tastenkombination zuweisen" gestellt und dabei eine Taste (sichtbar: "+")
gedrückt wurde:

```
[UI->agent] SET       /input_tracker/start   {"filter": ["KEYBOARD"], "keyboardExclusive": true}
[UI->agent] SUBSCRIBE /input_tracker/events
[agent->UI] BROADCAST /input_tracker/events  {"keyboard": {"hidUsage": 48, "isDown": true, "displayName": "+", "virtualKeyId": "VK_RIGHT_BRACKET"}}
[UI->agent] SET       /input_tracker/stop
[UI->agent] UNSUBSCRIBE /input_tracker/events
```

**Das ist der erste bestätigt funktionierende `SUBSCRIBE`-Pfad überhaupt**, und das Event trägt
ein echtes `isDown`-Flag (true/false-Semantik erwartbar). Response auf `start` enthielt zudem
ein nicht mitgesendetes Zusatzfeld `"captureMode": "MODIFIERS_BASED"` (Default-Wert des Agents).

**Offene Kernfrage:** Liefert `filter: ["MOUSE"]` (oder ein anderer Enum-Wert) analog
`{"mouse": {...}}`-Events mit Button-/CID-Info? **Das ist der wichtigste nächste Test.**

> **Zwischenstand (24.07., 16:34):** `--filter MOUSE` wurde bereits getestet (nur der
> `start`-Aufruf, noch ohne Tastendruck nötig) und schlägt **sofort** fehl:
> ```
> {"msgId": "", "verb": "OPTIONS", "path": "INVALID_MESSAGE_RECEIVED", "origin": "",
>  "result": {"code": "INVALID_ARG", "what": "{...\"filter\": [\"MOUSE\"]...}"}}
> ```
> Das passiert schon beim Parsen des Requests (nicht erst bei der Auswertung) – typisches
> Symptom einer strikten Protobuf-JSON-Validierung, wenn ein Enum-Feld einen **nicht
> existierenden Literal-Namen** bekommt. `"MOUSE"` ist also vermutlich schlicht der falsche
> String. Der korrekte Wert muss aus dem Agent-Binary extrahiert werden (Enum-Definition von
> `logi.protocol.input_tracker.*`, vermutlich `Options.filter` o.ä.) – **reines Raten weiterer
> Strings (`MOUSE_BUTTON`, `POINTER`, `HID_MOUSE`, `BUTTON`, ...) ist möglich, aber ineffizient
> – hier ist der Ghidra-Ansatz aus Abschnitt 5.3 der richtige Hebel.**

Kontext dazu: Diese `input_tracker`-API wird von der UI offenbar nur für den
"Tastenkombination zuweisen"-Dialog benutzt (um zu erkennen, welche Taste der Nutzer als
Ziel-Shortcut drückt) – nicht direkt zur Button-Zuweisung selbst (das läuft separat über
`SET /v2/assignment` mit `slotId` wie `mx-anywhere-3-6b025_c86` – die Zahl nach `c` ist die
**Control-ID (CID)**, hier 86 = Forward-Taste, `cardId` z. B. `card_global_presets_keyboard_shortcut`
oder `card_global_presets_osx_back`). Ob es einen analogen Dialog/Mechanismus für "Maustaste als
Trigger erkennen" gibt (z. B. in Makro-Editor oder Smart Actions), wurde noch nicht erkundet.

### 3.6a ZU ENDE GETESTET: `filter` = `MOUSE_BUTTON` ist der korrekte Enum-Wert

`"MOUSE"` (Abschnitt 3.6, alter Zwischenstand) war falsch. Durchprobiert am 26.07. (nur
`start`-Call, ohne Tastendruck nötig für den reinen Enum-Test):

| Kandidat | Ergebnis |
|---|---|
| `MOUSE` | ❌ `INVALID_ARG` |
| **`MOUSE_BUTTON`** | ✅ **`SUCCESS`** |
| `SPECIAL_BUTTON`, `HIDPP_BUTTON`, `GESTURE_BUTTON`, `PROGRAMMABLE_BUTTON`, `VENDOR_BUTTON`, `DIVERTED_BUTTON`, `SMART_BUTTON`, `CID_BUTTON` | ❌ alle `INVALID_ARG` |

`KEYBOARD` (aus dem ursprünglichen MITM-Fund) und `MOUSE_BUTTON` sind also vermutlich die
einzigen zwei gültigen Filter-Werte (weiteres Raten wäre jetzt Zeitverschwendung – falls doch
mehr gebraucht wird, siehe Ghidra-Ansatz in Abschnitt 5).

**Event-Format bei Klicks der Standard-Maustaste (links, CID/hidUsage 1):**
```json
{"mouse": {"button": {"hidUsage": 1, "isDown": true}}}
{"mouse": {"button": {"hidUsage": 1, "isDown": false}}}
```
Sauber alternierend bei jedem Klick/Loslassen – **echte Down/Up-Semantik bestätigt**, genau
das, was PinchBar braucht (zumindest für Buttons, die dieses hidUsage-Schema nutzen).

**WICHTIGER MECHANISMUS-FUND – Re-Arm-Pattern:** `/input_tracker/start` liefert **immer nur
genau ein** nachfolgendes Event über den `SUBSCRIBE`d-Kanal, danach verstummt der Broadcast
wieder (das erklärt die scheinbar "toten" Tests vom 24.07. – kein Bug, sondern Design, passend
zum "Single-Capture"-UI-Flow). Um kontinuierlich Events zu bekommen, muss nach **jedem**
empfangenen `/input_tracker/events`-Broadcast sofort ein neuer `SET /input_tracker/start`
gesendet werden (re-arm). Mit diesem Pattern (Testskript `sniff_repeat.py`, `--restart`-Flag)
kamen in einem 40s-Test 19 sauber alternierende Events für die linke Maustaste an. Für eine
produktive Integration ist das der Kern-Loop: `on_event -> handle -> resend(start)`.

### 3.6b NEGATIV-BEFUND: Daumentasten (Back/Forward, CID 83/86) liefern KEINE `input_tracker`-Events

Mit demselben Re-Arm-Loop (`sniff_repeat.py --restart`), sowohl mit `--filter MOUSE_BUTTON`
als auch mit `--filter KEYBOARD` (Theorie: evtl. HID-Consumer-Control-Codes wie "AC
Back"/"AC Forward", die über den Tastatur-Pfad laufen könnten) getestet: **null Events**, egal
wie oft/lang die Daumentasten gedrückt wurden, während die linke Maustaste im selben Testlauf
zuverlässig weiter Events lieferte (Sanity-Check bestanden – der Mechanismus läuft, nur für
diese Tasten kommt schlicht nichts).

**Interpretation:** `/input_tracker/*` scheint nur generische OS-Level-Input-Events zu sehen
(Standard-USB/BLE-HID-Tastatur-Scancodes, Standard-Maustasten-`hidUsage`). Die HID++-CID-Buttons
(Back/Forward/SmartShift, siehe Abschnitt 3.3, Feature `0x1B04`) werden vom Agent intern
vermutlich direkt an die Assignment/Action-Dispatch-Logik weitergereicht (z. B. um daraus eine
Tastenkombination oder OS-Navigation zu feuern) – **ohne** jemals über den IPC-Socket an
Drittanbieter-Listener gebroadcastet zu werden. Damit ist der `/input_tracker/*`-Pfad für unser
eigentliches Ziel (Daumentasten-Hold-Erkennung) **sehr wahrscheinlich eine Sackgasse**, auch wenn
er als generischer Maustasten/Tastatur-Sniffer (linke/rechte/mittlere Taste, normale Tastatur)
technisch einwandfrei funktioniert.

**Device-Detail-Korrektur (26.07.):** Aktuelle Device-ID der MX Anywhere 3S ist `dev00000041`
(hat sich seit dem 24.07. durch Re-Pairing geändert, siehe Warnung in Abschnitt 3.4).
`connectionType` im `/devices/list`-Payload zeigt exakt `"BLE"` (Bluetooth Low Energy) –
technisch präziser als die bisherige Doku-Formulierung "direktes Bluetooth", ändert aber nichts
an der grundsätzlichen Einschätzung aus Abschnitt 3.3. `specialKeys.programmable` bestätigt
`[82, 83, 86, 196]` (Middle/Back/Forward/SmartShift) wie erwartet.

**Test-Tool:** `~/Devel/logitech-ipc-protocol/sniff_repeat.py` (neu, 26.07., Ad-hoc-Skript,
noch nicht committed) – Re-Arm-Loop um `input_tracker`, Parameter: `<duration> [--restart]
[--filter WERT]`.

### 3.6c NEUER ANSATZ: Protobuf-Reflection direkt aus der Binary auslesen (ohne Ghidra!)

**Auslöser:** Nutzerfrage, ob es außer `KEYBOARD`/`MOUSE_BUTTON` noch weitere `input_tracker`-
Filter-Werte geben könnte (z. B. für Zusatztasten). Antwort ließ sich **autoritativ** klären,
ohne Ghidra zu öffnen:

```bash
strings -a "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent" > agent_strings.txt
```

Der Agent ist mit **nicht gestripptem Protobuf-Reflection-Support** gebaut – der komplette
`FileDescriptorProto`-Pool liegt als lesbarer Text im Binary (kurze Tag/Length-Bytes werden von
`strings` einfach übersprungen, die Feld-/Message-/Enum-Namen bleiben aber in der korrekten
Deklarationsreihenfolge erhalten). Das ist erheblich schneller als Ghidra und liefert 1:1 exakte
Ergebnisse statt Vermutungen.

**Ergebnis 1 – `input_tracker.Filter`-Enum ist jetzt vollständig und autoritativ bekannt:**
```
enum Filter { NONE, MOUSE_MOVE, MOUSE_BUTTON, MOUSE_WHEEL, KEYBOARD }
```
**Es gibt garantiert keinen weiteren Wert** (kein `GAMEPAD`, kein CID-/Spezialtasten-Wert). Damit
ist zweifelsfrei (nicht nur empirisch wie in 3.6b) belegt: `/input_tracker/*` kann die
HID++-CID-Buttons (Back/Forward/SmartShift) architektonisch **nicht** sehen – das Enum hat
schlicht keinen Wert dafür.

**Ergebnis 2 – Eine völlig andere, sehr vielversprechende Message-Familie existiert:**
Direkt im selben Descriptor-Pool gefunden, unter `logi.protocol.devices`:
```
message DivertStateRequest { int32 control_id; bool divert; bool raw_xy; bool raw_wheel; }
message SpecialKeysDivertRequest { repeated DivertStateRequest control_ids_list; }
message DivertState { int32 control_id; bool divert; }
message SpecialKeysDivertState { repeated DivertState control_ids_list; }

message TestKeyState {
  int32 ctrl_id;
  bool is_diverted, is_diverted_valid;
  bool is_persistently_diverted, is_persistently_diverted_valid;
  bool is_raw_xy_reporting, is_raw_xy_reporting_valid;
  bool is_force_raw_xy_reporting, is_force_raw_xy_reporting_valid;
  int32 remapped_id;
  bool is_reporting_analytics, is_reporting_analytics_valid;
  bool is_raw_wheel_reporting, is_raw_wheel_reporting_valid;
}
message TestDeviceKeysState { repeated TestKeyState states; }
message TestCidList { string device_id; }

message TriggerEvent {
  string device_id; Device.Type device_type; string slot_id;
  TriggerEvent.State state;  // enum State { INACTIVE, START, ONE_SHOT }
  ...
}
```
Zusätzlich: ein Symbol `feature_x1b04_special_keys` (`_process_key_gesture_event`) – **exakte
Übereinstimmung mit HID++ Feature `0x1B04`** aus Abschnitt 3.3! Das beweist: Der von uns
gesuchte Mechanismus (`setCidReporting`/`divertedButtonsEvent`) ist **intern im Agent
tatsächlich implementiert und adressierbar**, nur eben nicht über `/input_tracker/*`.

**Gefundener, aber noch nicht funktionsfähiger Pfad:** `SET /devices/special_keys_divert_state/configure`
- Existiert nachweislich: `GET` auf den Pfad → `"no handler for 'GET ...'"` (Pfad ist bekannt,
  nur `GET` nicht unterstützt). `SET` mit **leerem Payload `{}`** kommt durch den JSON-Parser
  durch (kein `INVALID_MESSAGE_RECEIVED` mehr!) und liefert einen Applikationsfehler:
  `"Invalid special_keys_divert_state settings"` mit Response-Typ
  `logi.protocol.card_register.TaskExecute`.
- **Aber:** Jeder Versuch mit tatsächlichen Feldern (`controlId`/`divert`, `controlIdsList`,
  `ctrlId`/`isDiverted`, `states`, mit/ohne `deviceId`, in allen denkbaren camelCase-Varianten
  der oben gefundenen Feldnamen) schlägt wieder mit `INVALID_MESSAGE_RECEIVED` fehl. Das
  bedeutet: **keiner der bisher aus dem String-Dump abgeleiteten Feldnamen ist exakt richtig**
  (oder das Feld gehört zu einer anderen Message als vermutet – die Zuordnung "welche Message
  gehört zu welchem IPC-Pfad" ist aus reinen Strings nicht ableitbar, nur aus dem tatsächlichen
  Registrierungscode).
- Auch blindes `SUBSCRIBE` auf naheliegende Pfade (`/devices/trigger_event`, `/trigger_event`,
  `/devices/test_keys`, `/devices/test_device_keys`, `/devices/special_keys_divert_state`,
  `/software_events/lps/trigger/event`) brachte **keine** Events beim Drücken von Back/Forward –
  konsistent mit dem bereits dokumentierten Negativbefund für geratene `SUBSCRIBE`-Pfade
  (Abschnitt 3.5).

**Bewertung:** Wir sind jetzt sehr nah dran – der Mechanismus existiert nachweislich im Agent
(nicht nur in der Maus-Firmware), und wir kennen die ungefähre Message-Familie. Was fehlt, ist
die **exakte Zuordnung Pfad → Message-Typ → Feldnamen**, die sich nicht mehr durch Raten lösen
lässt (mehrfach mit plausiblen Kandidaten probiert, alle gescheitert). Der nächste sinnvolle
Schritt ist **keine weitere Raterei**, sondern entweder (a) die echte serialisierte
`FileDescriptorProto`-Bytefolge sauber extrahieren und mit `google.protobuf.descriptor_pb2`
parsen (liefert Feldnummern/-typen exakt, aber nicht zwingend die Pfad-Zuordnung), oder (b) in
Ghidra/objdump den Registrierungscode für den String `"special_keys_divert_state/configure"`
finden und zurückverfolgen, welcher Message-Typ dort tatsächlich `::ParseFromString`/
`JsonStringToMessage` aufruft. Siehe Abschnitt 5 für die konkrete Empfehlung.

**Neues Test-Tool:** `~/Devel/logitech-ipc-protocol/test_divert.py` (26.07., Ad-hoc, noch nicht
committed) – probiert mehrere Payload-Varianten für `/devices/special_keys_divert_state/configure`
durch. String-Dump der Binary liegt (aktuell nur temporär) unter
`/var/folders/.../T/opencode/agent_strings.txt` – bei Bedarf einfach neu erzeugen (Befehl s.o.).

### 3.7 IN ARBEIT (pausiert): Rohes HID++ 2.0 direkt über Logitech-Unifying-Dongle (Option C)

**Kontext/Entscheidung:** Nachdem das Erraten des `/configure`-JSON-Schemas (3.6c) an seine
Grenze kam, hat der Nutzer als pragmatischen nächsten Schritt entschieden: Statt weiter im
Options+-IPC-Protokoll zu raten, **direkt den offiziell dokumentierten HID++-2.0-Weg
(Abschnitt 3.3) selbst implementieren** – mit der Maus über einen physischen Dongle gekoppelt,
damit die macOS-Bluetooth-Kernel-Sperre für `IOHIDManager`/rohen HID-Zugriff nicht greift.

**WICHTIG – Ziel-Klarstellung vom Nutzer (explizit, nicht vergessen):** Der Dongle-Umweg ist
**nur ein Testaufbau, um das Protokoll zu verstehen/validieren**. Das eigentliche Endziel bleibt,
die Events **über Bluetooth** (die vom Nutzer bevorzugte, tatsächlich genutzte Kopplungsart)
abzugreifen. Jeder hier gefundene Baustein muss also am Ende daraufhin bewertet werden, ob/wie
er sich auf den BLE-Fall übertragen lässt (siehe "Offene Frage" ganz unten in diesem Abschnitt).

**Hardware-Detail-Korrektur:** Der Nutzer hat einen **Logitech Unifying**-Empfänger (nicht Bolt –
Bolt ist nur für die 3S-Variante bzw. neuere Geräte relevant; die vorhandene Maus ist die reguläre
**MX Anywhere 3**, kein 3S). Für unsere Zwecke (roher USB-HID-Transport, keine BT-Kernel-Sperre)
ist das gleichwertig zu Bolt – der in Abschnitt 3.3/5 erwähnte "Bolt-Workaround" gilt technisch
genauso für Unifying.

**Was bereits gemacht wurde:**

1. **Umpairing:** Nutzer hat MX Anywhere 3 und MX Keys von Bluetooth getrennt und neu über den
   Unifying-Dongle gekoppelt. Verifiziert per `sniff_button_events.py devices`:
   ```
   dev00000040 | MX Keys           | WIRELESS | 6b35b   (via USB Receiver)
   dev00000041 | MX Anywhere 3     | WIRELESS | 6b025   (via USB Receiver)
   dev00000042 | Logi Unifying receiver | USB | c52b
   ```
   `activeInterfaces[].path` zeigt jetzt `...USB Receiver@.../IOUSBHostInterface@2/
   AppleUserUSBHostHIDDevice:N` statt eines BLE-Pfads – Device-IDs (`dev00000041` etc.) sind
   unverändert geblieben (kein Re-Pairing-bedingter ID-Wechsel diesmal).

2. **Raw-HID-Python-Zugriff aufgesetzt** (das System-Python `/usr/bin/python3` ist SIP-geschützt,
   `DYLD_LIBRARY_PATH` wird dafür von macOS entfernt – deshalb Umweg über Homebrew-Python nötig):
   ```bash
   brew install hidapi                       # native libhidapi.dylib
   brew install python@3.12                  # nicht-SIP-geschütztes Python
   cd ~/Devel/logitech-ipc-protocol
   /opt/homebrew/bin/python3.12 -m venv .venv
   .venv/bin/pip install hid                 # Python-Bindings (ctypes-Wrapper um libhidapi)
   ```
   Funktionierender Testaufruf (liefert alle Logitech-HID-Interfaces):
   ```bash
   DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 -c "
   import hid
   for d in hid.enumerate():
       if d.get('vendor_id') == 0x046d: print(d)
   "
   ```

3. **HID-Interfaces des Unifying-Empfängers identifiziert** (vendor_id `0x046d` = 1133,
   product_id `50475` = `0xC52B`, `product_string: 'USB Receiver'`), drei separate
   `interface_number`/Pfad-Gruppen (jede Gruppe = eigener `path`, mehrere `usage_page`/`usage`-
   Einträge pro Pfad):
   | interface_number | path (Beispiel-Session) | usage_page(s) | Bedeutung |
   |---|---|---|---|
   | 0 | `DevSrvsID:4295060437` | `1` (usage 6 = Keyboard) | Tastatur-Reports |
   | 1 | `DevSrvsID:4295060438` | `1` (usage 1/2), `12` (Consumer), `65468` (vendor) | Standard-Maus/Consumer-Reports |
   | **2** | `DevSrvsID:4295060436` | **`65280` (= 0xFF00, vendor-spezifisch)**, usages 1/2/4 | **HID++-Rohkanal** (Short/Long/Very-Long-Reports) |

   **Interface 2 (usage_page 0xFF00) ist der für uns relevante Kanal** – das entspricht exakt dem
   aus der öffentlichen HID++-Doku (Abschnitt 3.3/3.7-Referenzen) bekannten Aufbau: Logitech-
   Empfänger exponieren HID++ als vendor-defined Usage Page, mit Short Reports (7 Byte, Report-ID
   `0x10`) und Long Reports (20 Byte, Report-ID `0x11`).

   ⚠️ **Achtung, Pfad-Bytes sind nicht stabil:** Die `path`-Werte (`DevSrvsID:...`) sind
   IOKit-Session-IDs, die sich bei jedem Neustart/Neuverbinden ändern können – vor jedem neuen
   Testlauf per `hid.enumerate()` neu ermitteln, nie hardcoden.

**Was als Nächstes geplant war (noch NICHT begonnen/getestet):**

Vollständige HID++-2.0-Implementierung in Python (`hid.device().open_path(...)`, dann rohe
7-/20-Byte-Reports schreiben/lesen), Ablauf laut öffentlicher Spezifikation:

1. **Device-Index herausfinden:** Der Unifying-Dongle multiplext mehrere gepairte Geräte über
   Device-Indizes (typischerweise `0x01`–`0x06`; `0xFF` = Empfänger selbst). Muss experimentell
   ermittelt werden, welcher Index zur MX Anywhere 3 gehört (z. B. durchprobieren, welcher Index
   auf eine `Root.GetFeature`-Anfrage sinnvoll antwortet statt eines HID++-Fehlercodes).
2. **`Root.GetFeature(0x1B04)`** (Feature-Index `0x00` ist immer `IRoot`, Funktion 0 = `getFeature`)
   aufrufen, um den Feature-Index für "Special Keys and Mouse Buttons" (`0x1B04`) auf diesem
   Gerät zu bekommen (variiert pro Firmware).
3. Mit diesem Feature-Index: `getCount()` (Funktion 0) und `getCidInfo(index)` (Funktion 1)
   aufrufen, um zu verifizieren, dass CIDs `82/83/86/196` (Middle/Back/Forward/SmartShift, siehe
   Abschnitt 3.3) tatsächlich in der Liste auftauchen.
4. **`setCidReporting(cid, divert=1)`** (Funktion 3) für CID `83` und `86` aufrufen.
5. Auf eingehende **Long Reports** (Report-ID `0x11`) mit passendem Feature-Index lauschen –
   Funktion/Event `divertedButtonsEvent` (Funktion 0 als Notification, `swId`-Bit gesetzt)
   enthält die Liste der aktuell gedrückten CIDs (CID erscheint = Down, verschwindet = Up).
6. Bei Erfolg: Timing/Zuverlässigkeit prüfen (kommt das genauso sauber Down/Up wie beim
   `input_tracker`-Re-Arm-Test in 3.6a, oder gibt es hier von Haus aus einen kontinuierlichen
   Stream ohne Re-Arm-Bedarf – vermutlich Letzteres, da HID++-Notifications nicht das
   "Single-Capture"-Verhalten von `input_tracker` haben sollten).

**Referenz für exakte Byte-Formate:** https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
(bereits in Abschnitt 3.3/7 verlinkt) sowie allgemeine HID++-1.0/2.0-Rahmenformat-Doku unter
https://lekensteyn.nl/files/logitech/ (Index-Seite, Short/Long-Report-Grundlagen).

**Offene Frage / Rückkopplung zum eigentlichen Ziel (Bluetooth):** Sobald dieser Weg über den
Dongle funktioniert, bleibt die Kernfrage: Wie übertragen wir das auf den BLE-Fall, wo
`IOHIDDeviceOpen()` für Drittanbieter-Apps kernelseitig blockiert ist (Abschnitt 3.3)? Zwei
Ideen, die noch nicht untersucht wurden:
   - **Direkter CoreBluetooth-GATT-Zugriff statt IOHIDManager:** Logitech-BLE-Mäuse exponieren
     HID++ vermutlich über einen eigenen, vendor-spezifischen GATT-Service (nicht nur das
     Standard-HID-over-GATT-Profil). Die macOS-Kernel-Sperre betrifft nach bisherigem
     Kenntnisstand (Abschnitt 3.3) spezifisch `IOHIDManager`/Input-Device-Handling – **nicht**
     zwingend rohen GATT-Zugriff über `CoreBluetooth` (eine komplett andere API-Ebene, die für
     Nicht-Input-Peripheriegeräte normal von Drittanbieter-Apps genutzt wird). **Das ist eine
     bisher rein hypothetische, ungeprüfte Idee** – müsste mit einem kleinen Swift/CoreBluetooth-
     Testprogramm verifiziert werden (GATT-Services der Maus auflisten, schauen ob ein
     Logitech-spezifischer Service/Characteristic sichtbar ist, versuchen zu subscriben).
   - Alternativ: Falls CoreBluetooth nicht klappt, bleibt nur Option A (Options+-IPC-Schema
     doch noch finden, Abschnitt 3.6c/5) als Weg, der mit BLE-gekoppelten Geräten funktioniert,
     da Options+ selbst nachweislich BLE-HID++-Zugriff hat (sonst würden Back/Forward-Tasten
     ja gar keine Aktion auslösen können).

**Tools/Umgebung für Fortsetzung:**
- Venv: `~/Devel/logitech-ipc-protocol/.venv` (Python 3.12, Paket `hid` installiert)
- Aufruf-Pattern: `DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3 <script>.py`
- Noch kein Skript für die eigentliche HID++-Kommunikation geschrieben (nur Enumeration
  getestet) – das ist der konkrete nächste Schritt.

---

## 4. Tooling: `sniff_button_events.py`

**Ort:** `~/Devel/logitech-ipc-protocol/sniff_button_events.py` (steht NICHT in PinchBar selbst –
bewusst getrennt, da eigenständiges Python-Reverse-Engineering-Tool ohne Code-Bezug zu
PinchBars Swift/ObjC++-Stack).

**Modi** (`python3 sniff_button_events.py <modus> --help` für Details):

| Modus | Zweck | Status |
|---|---|---|
| `devices` | `/devices/list` abfragen, Device-IDs finden | ✅ funktioniert |
| `subscribe` | Rät `SUBSCRIBE`-Pfade, hört passiv zu | ✅ funktioniert (liefert bestätigt **keine** Events) |
| `input_tracker` | Nutzt `/input_tracker/start`+`SUBSCRIBE /input_tracker/events` | ✅ Code fertig, **noch nicht live mit Maustaste getestet** |
| `proxy` | MITM zwischen Options+-UI und Agent-Socket | ✅ funktioniert (nach 2 Bugfixes, siehe unten) |
| `ws` | Sondiert WebSocket-Port 59869 | Implementiert, nie getestet (braucht `pip install websocket-client`) |

### Bekannte, bereits gefixte Bugs im Tool
1. **Frame-Parser-Hang bei großen Nachrichten:** `FrameStream` hatte eine zu niedrige
   Plausibilitätsgrenze (5 MB) für Frame-Längen und einen ineffizienten Byte-für-Byte-Resync
   (O(n²)), der bei echten Multi-MB-Payloads (Ressourcen/Icons) den Relay-Thread blockierte und
   von außen wie eine kaputte Verbindung aussah. **Fix:** Grenze auf 64 MB angehoben, Resync
   scannt jetzt ein begrenztes Fenster (4096 Bytes) statt endlos einzelne Bytes zu droppen;
   Relay leitet Rohdaten jetzt **immer zuerst weiter**, bevor geloggt/geparst wird (Parsing-Bugs
   können die eigentliche Proxy-Funktion nicht mehr beeinträchtigen).
2. **Race Condition beim Cleanup:** Ein SIGINT-Handler und der `finally`-Block in `cmd_proxy`
   riefen beide unabhängig Cleanup-Logik auf; der `finally`-Block hat dabei unconditional
   `os.remove(sock_path)` aufgerufen und damit den gerade vom Signal-Handler wiederhergestellten
   **echten Agent-Socket erneut gelöscht** → Options+ konnte sich nach Ctrl-C nicht mehr neu
   verbinden (Socket-Datei fehlte, obwohl der Agent-Prozess seinen File-Descriptor noch offen
   hatte). **Fix:** Custom-Signal-Handler entfernt (natürliches `KeyboardInterrupt` reicht,
   analog zu den anderen Modi), Cleanup läuft jetzt nur noch genau einmal über
   `_restore_real_socket()` (idempotent).
3. **Nach Bug 2 musste der Options+-Agent-Prozess neu gestartet werden**, da ein Unix-Socket
   nach `unlink()` nicht unter seinem alten Pfad "wiederauftauchen" kann, solange der Prozess
   weiterläuft. Befehl dafür (funktioniert ohne sudo, User-LaunchAgent):
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.logi.cp-dev-mgr
   ```
   Danach ein paar Sekunden warten, bis der Socket unter `/tmp/logitech_kiros_agent-*` wieder
   auftaucht (per `ls -la /tmp | grep logitech_kiros` prüfen).

**Verifiziert funktionsfähig zum Zeitpunkt dieses Dokuments** (24.07.2026, 16:32 CEST):
`python3 sniff_button_events.py devices` liefert erfolgreich die Geräteliste inkl. MX Anywhere 3
(`dev00000015`).

---

## 5. Nächste Schritte (priorisiert)

**Zusammenfassung des Stands:** `/input_tracker/*` ist zu Ende getestet (Abschnitt 3.6a/3.6b) und
**autoritativ als Sackgasse für Daumentasten bestätigt** (3.6c – vollständiger Filter-Enum
ausgelesen, kein CID-Wert vorhanden). Der Options+-IPC-Weg über `/devices/special_keys_divert_state/configure`
(3.6c) existiert nachweislich, aber das exakte JSON-Feldschema wurde trotz vieler Versuche nicht
gefunden – reines Raten ist ausgereizt. **Aktiver, in Arbeit befindlicher Pfad ist jetzt Option C
(Abschnitt 3.7): rohes HID++ 2.0 direkt über einen Logitech-Unifying-Dongle**, unabhängig von
Options+. Die Umgebung dafür ist bereits aufgesetzt (Geräte umgepairt, Python-Venv mit
`hid`/`hidapi`, HID++-Rohkanal des Dongles identifiziert), die eigentliche Protokoll-
Implementierung ist der unmittelbar nächste Schritt.

**PRIORITÄT 1 – direkt weitermachen mit Option C (Abschnitt 3.7):**

1. Skript schreiben, das über `.venv` (`DYLD_LIBRARY_PATH=/opt/homebrew/lib .venv/bin/python3`)
   den HID++-Interface-Pfad (usage_page `0xFF00`/`65280`) öffnet und:
   - Kurze Reports (7 Byte: `0x10, deviceIndex, featureIndex, funcId<<4|swId, data0, data1, data2`)
     senden/empfangen kann (Basis-Framing für HID++ 1.0/2.0).
   - `Root.GetFeature(0x1B04)` an mehreren Device-Indizes (`0x01`.."0x06`) durchprobiert, bis der
     Index gefunden ist, der zur MX Anywhere 3 gehört (nicht MX Keys/Performance MX/MX Master 3,
     die auch am selben Dongle hängen).
   - Feature-Index für `0x1B04` cached, dann `getCidInfo`/`getCount` aufruft, um CIDs 82/83/86/196
     zu verifizieren.
   - `setCidReporting(83, divert=1)` und `setCidReporting(86, divert=1)` sendet.
   - Auf Long-Report-Notifications lauscht und rohe Bytes dekodiert (Doku:
     https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html).
2. Nutzer bittet, Back/Forward zu drücken, prüfen ob Down/Up sauber ankommt (analog zum
   Re-Arm-Test in 3.6a, aber hier idealerweise OHNE Re-Arm-Bedarf, da es sich um ein natives
   HID++-Notification-Modell handelt, nicht um das "Single-Capture"-Verhalten von
   `input_tracker`).
3. **Danach sofort die Bluetooth-Rückübertragung angehen** (nicht vergessen – das ist das
   eigentliche Ziel!): Kleines CoreBluetooth-Testprogramm (Swift, z. B. als Kommandozeilen-Tool
   oder Xcode-Playground), das nach der MX Anywhere 3/MX Keys als BLE-Peripheral sucht (auch
   wenn sie gerade über den Dongle gekoppelt sind, sollte das Gerät weiterhin per BLE
   advertisen/verbindbar sein, ggf. dafür kurz wieder auf direktes Bluetooth zurückpairen) und
   deren GATT-Services auflistet. Prüfen, ob ein Logitech-vendor-spezifischer Service (nicht das
   Standard-HID-over-GATT-Profil) sichtbar ist und ob sich darüber ähnliche HID++-Frames
   senden/empfangen lassen wie über den Dongle. **Das ist reine Hypothese (Abschnitt 3.7,
   letzter Absatz) – noch nicht mal ansatzweise verifiziert**, aber der aktuell einzige konkrete
   Ansatz für einen dritten, von Options+ unabhängigen BLE-Weg.

**PRIORITÄT 2 – falls Option C nicht funktioniert oder das BLE-Problem sich als unlösbar
herausstellt, zurück zum Options+-IPC-Weg:**

   **Option A1: Registrierungscode für `special_keys_divert_state/configure` in Ghidra/objdump
   lokalisieren.** Nach dem String `"special_keys_divert_state/configure"` im Disassembler
   suchen, referenzierende Funktion finden, zurückverfolgen welcher Protobuf-Message-Typ per
   `JsonStringToMessage`/`ParseFromString` auf das Payload angewendet wird. Das gibt die exakten
   Feldnamen ohne weiteres Raten.
   - `logioptionsplus_agent`-Binary: `/Library/Application Support/Logitech.localized/
     LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent`
   - String-Dump liegt bereits vor (siehe 3.6c), kann bei Bedarf neu erzeugt werden.

   **Option A2: MITM-Proxy während einer versteckten Test-/Debug-Ansicht der UI**, falls
   auffindbar (die `Test*`-Messages aus 3.6c deuten auf eine interne QA-Oberfläche hin, die
   `/configure` evtl. tatsächlich benutzt).

   Vorteil dieser Optionen gegenüber Option C: Funktioniert nachweislich auch mit BLE-gekoppelten
   Geräten (da Options+ selbst nachweislich BLE-HID++-Zugriff hat), löst also das
   Bluetooth-Ziel direkt mit, ohne Umweg über CoreBluetooth-Spekulation.

3. **Sobald irgendein Weg (C oder A) tatsächlich CID-Button-Events liefert – über USB-Dongle
   UND (wichtig!) über Bluetooth:** Feldnamen/Struktur dokumentieren, dann grober
   Architektur-Entwurf für eine echte PinchBar-Integration:
   - Vermutlich als separater kleiner Helper-Prozess (Python-Prototyp zuerst, ggf. später
     Swift-Rewrite mit `Network.framework`/`POSIX`-Unix-Socket-API bzw. direkt `IOHIDManager`/
     `CoreBluetooth` bei Option C) der die Down/Up-Zustände über IPC (z. B. Distributed
     Notifications, ein eigener kleiner Named-Pipe/Socket, oder direkt eingebettet in PinchBar
     als Swift-Code) an PinchBar weiterreicht, wo `OtherMouseZoomMapping`/`PinchMapping` sie wie
     ein synthetisches `otherMouseDown`/`otherMouseUp`-Event behandeln.
   - Bei Option A zusätzlich offene Frage: Muss dort auch ein Re-Arm-Pattern implementiert werden
     (siehe 3.6a), oder verhält sich ein neu gefundener Pfad anders (kontinuierlicher Stream)?
   - Lizenz-/Robustheits-Hinweis: Bei Option A bleibt es ein **undokumentiertes, jederzeit von
     Logitech änderbares Protokoll**. Option C basiert auf offiziell dokumentiertem HID++
     (Abschnitt 3.3), ist also robuster – **falls** sich der BLE-Teil davon lösen lässt.

---

## 6. Empfehlung zur Arbeitsumgebung

**Kurz gesagt: In der aktuellen Umgebung (echter Mac mit echter Maus + echtem Options+) weiter
arbeiten – nicht in eine Cloud-/Remote-Sandbox wechseln.**

Begründung: Diese Recherche ist zu 100 % hardware-/GUI-gebunden (physische Tastendrücke, echte
Bluetooth-Kopplung, laufender Options+-Prozess). Eine Cloud-IDE oder ein isolierter Container
hat keinen Zugriff auf Bluetooth-Hardware oder eine echte macOS-GUI-Session – das würde die
gesamte weitere Untersuchung unmöglich machen. Die bisherige Kombination (KI-Agent mit
Shell-Zugriff auf dem echten Dev-Mac + Nutzer führt physische Aktionen aus und teilt
Terminal-Output) ist genau richtig und sollte fortgesetzt werden.

**Zusätzlich sinnvoll, jetzt wo Ghidra zur Verfügung steht:**
- Ghidra für die native Agent-Binary (`logioptionsplus_agent`) nutzen, um die Protobuf-
  Descriptor-Pool-Extraktion aus Schritt 5.3 durchzuführen – das könnte uns Stunden an
  Trial-and-Error bei Filter-Enum-Werten und Feldnamen ersparen.
- Für die Electron-UI-Seite (JS) reicht weiterhin `npx asar extract` (kein Ghidra nötig) –
  das wurde im Referenz-Repo bereits erfolgreich genutzt, um das Wire-Format zu finden.
- Falls Ghidra für die Analyse der `.node`/Electron-nativen Teile gebraucht wird: eher
  nachrangig, die interessante Logik (Protobuf-Schema, Feature-Handling) dürfte primär im
  `logioptionsplus_agent`-Backend-Prozess stecken, nicht im Renderer.

**Fork-Erinnerung:** Vor dem ersten Commit im Ordner `~/Devel/logitech-ipc-protocol` bitte
erst `saimanish1/logitech-ipc-protocol` auf GitHub forken und den `origin`-Remote umbiegen,
falls die Ergebnisse remote gesichert werden sollen (aktuell zeigt `origin` auf das fremde
Original-Repo, nicht auf einen eigenen Fork).

---

## 7. Referenzen

- PinchBar-Code: `~/Devel/PinchBar` (`OtherMouseZoomMapping.swift`, `OtherMouseScrollMapping.swift`,
  `Utilities/CGEventExtensions.swift`, `MultitouchSupport.mm` als Vorbild für native Bridges)
- Referenz-Repo (IPC-Protokoll): https://github.com/saimanish1/logitech-ipc-protocol
  (lokal unter `~/Devel/logitech-ipc-protocol`, insbesondere `logi-options-ipc-reverse-engineering.md`,
  `api-reference.md`, `TODO.md`)
- HID++ 2.0 Feature 0x1B04 Spezifikation: https://lekensteyn.nl/files/logitech/x1b04_specialkeysmsebuttons.html
- Weitere HID++-Dokus/Tools: https://lekensteyn.nl/files/logitech/ (Index), https://github.com/cvuchener/hidpp,
  https://github.com/pwr-Solaar/Solaar (beide nur Linux/Windows, keine macOS-Unterstützung)
- Logi Actions SDK (nicht anwendbar, aber zur Vollständigkeit): https://logitech.github.io/actions-sdk-docs/
- Unser Sniffer-Tool: `~/Devel/logitech-ipc-protocol/sniff_button_events.py`
- Re-Arm-Test-Tool (26.07., ad-hoc, noch nicht committed): `~/Devel/logitech-ipc-protocol/sniff_repeat.py`
  (`python3 sniff_repeat.py <duration> --restart --filter MOUSE_BUTTON|KEYBOARD`)
- Divert-Konfigurations-Testtool (26.07., ad-hoc, noch nicht committed):
  `~/Devel/logitech-ipc-protocol/test_divert.py` (probiert Payload-Varianten für
  `/devices/special_keys_divert_state/configure` – bisher erfolglos, siehe 3.6c)
- Raw-HID++-Testumgebung (26.07., Abschnitt 3.7): venv unter
  `~/Devel/logitech-ipc-protocol/.venv` (Python 3.12 via Homebrew, Paket `hid`), benötigt
  `brew install hidapi` + `DYLD_LIBRARY_PATH=/opt/homebrew/lib` beim Aufruf. Noch kein
  eigenes HID++-Protokoll-Skript geschrieben (nur Geräte-Enumeration getestet).
- HID++ Short/Long-Report-Rahmenformat (Grundlage für 3.7): https://lekensteyn.nl/files/logitech/
  (Index-Seite verlinkt die einzelnen Feature-Specs, inkl. 0x1B04)

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
# siehe 3.6a/3.6b; Re-Arm-Pattern in sniff_repeat.py --restart)
python3 sniff_button_events.py input_tracker --filter MOUSE_BUTTON --duration 30

# Falls nötig: MITM-Proxy für weitere UI-Flow-Exploration
# (Options+-UI vorher beenden, Agent-Hintergrundprozess läuft weiter lassen)
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
# siehe Abschnitt 3.7 für den vollständigen Ablaufplan.
```
