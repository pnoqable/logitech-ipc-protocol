# PinchBar × Logitech HID++ – Session-Handoff

**Stand:** 24.07.2026, 16:32 CEST (verifiziert funktionsfähig zu diesem Zeitpunkt)
**Zweck dieses Dokuments:** Kompletten Kontext der bisherigen Recherche festhalten, damit die
Session in einer neuen Umgebung/einem neuen Chat nahtlos fortgesetzt werden kann, ohne die
gesamte Recherche zu wiederholen.

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
| Options+ IPC-Unix-Socket – **`/input_tracker/*` API** | 🟢 **DURCHBRUCH, aber noch nicht zu Ende getestet.** Per MITM-Proxy entdeckt: liefert echte `isDown`-Events für Tastatur. Ob `filter: ["MOUSE"]` auch Maustasten-Events liefert, ist der **nächste zu testende Schritt**. |

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

1. ~~`--filter MOUSE` testen~~ **bereits getestet, schlägt sofort mit `INVALID_ARG` fehl**
   (siehe Zwischenstand in Abschnitt 3.6). `"MOUSE"` ist also der falsche Enum-Literal.

2. **Günstige Sofort-Versuche** (jeweils nur der `start`-Call, kein Tastendruck nötig, um
   schnell weitere Kandidaten durchzuprobieren – erst wenn einer OHNE Fehler durchgeht, lohnt
   sich das Warten+Tastendruck):
   ```bash
   cd ~/Devel/logitech-ipc-protocol
   python3 sniff_button_events.py input_tracker --filter MOUSE_BUTTON --duration 3
   python3 sniff_button_events.py input_tracker --filter POINTER --duration 3
   python3 sniff_button_events.py input_tracker --filter HID_MOUSE --duration 3
   python3 sniff_button_events.py input_tracker --filter BUTTON --duration 3
   python3 sniff_button_events.py input_tracker --filter ALL --duration 3
   # Filter ganz weglassen (evtl. anderes Payload-Schema als "filter"-Liste?)
   ```
   Sobald einer davon **ohne** `INVALID_ARG`/`INVALID_MESSAGE_RECEIVED` durchgeht: mit
   `--duration 30` wiederholen und **währenddessen die Daumentaste drücken**.

3. **Falls alle Rate-Versuche fehlschlagen (wahrscheinlich): Ghidra-Ansatz** (jetzt priorisiert,
   da reines Raten sich schon einmal als Sackgasse erwiesen hat) (Nutzer hat Ghidra bereits installiert – siehe Abschnitt 6): Die
   `logioptionsplus_agent`-Binary (`/Library/Application Support/Logitech.localized/
   LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent`) ist
   vermutlich in C++ mit Protobuf gebaut. Protobuf-C++-Binaries betten bei nicht vollständig
   gestripptem Reflection-Support oft die **komplette serialisierte
   `FileDescriptorProto`-Descriptor-Pool** ein – das würde uns direkt und ohne weiteres Raten:
   - alle gültigen Enum-Werte für `input_tracker`-`filter` (z. B. `MOUSE`, `GAMEPAD`, ...)
   - alle Feldnamen der `Event`-Message-Variante für Maus (analog zu `keyboard.hidUsage`,
     `keyboard.isDown`, `keyboard.virtualKeyId` – vermutlich sowas wie `mouse.controlId`,
     `mouse.isDown`, `mouse.cid` o. ä.)
   liefern. Vorgehen: In Ghidra nach Strings suchen, die nach Protobuf-Feldnamen aussehen
   (`input_tracker`, `MouseEvent`, `controlId` etc.), von dort zu den referenzierenden
   Funktionen/Datenstrukturen zurückverfolgen, ggf. mit einem Ghidra-Script nach
   `FileDescriptorProto`-typischen Byte-Mustern (Feld-Tags `0x0a` für `name`, geschachtelte
   Messages) suchen. Alternativ (schneller, ohne Ghidra): einfaches Python-Script, das die
   Binary linear nach Blöcken durchsucht, die sich als `google.protobuf.FileDescriptorProto`
   parsen lassen (`from google.protobuf import descriptor_pb2`).

4. **Sobald Maus-Events bestätigt sind:** Feldnamen/Struktur dokumentieren (Analog zu Abschnitt
   3.6), dann grober Architektur-Entwurf für eine echte PinchBar-Integration:
   - Vermutlich als separater kleiner Helper-Prozess (Python-Prototyp zuerst, ggf. später
     Swift-Rewrite mit `Network.framework`/`POSIX`-Unix-Socket-API) der sich mit dem
     Options+-Agent-Socket verbindet, `input_tracker` für die relevante(n) CID(s) startet, und
     Down/Up-Zustände über IPC (z. B. Distributed Notifications, ein eigener kleiner
     Named-Pipe/Socket, oder direkt eingebettet in PinchBar als Swift-Code) an PinchBar
     weiterreicht, wo `OtherMouseZoomMapping`/`PinchMapping` sie wie ein synthetisches
     `otherMouseDown`/`otherMouseUp`-Event behandeln.
   - **Offene Frage, die vor der Integration zu klären ist:** Blockiert `keyboardExclusive`
     (bzw. ein analoges `mouseExclusive`?) während der Tracker aktiv ist die normale
     Funktion der Maustaste für den Rest des Systems? Das müsste dauerhaft im Hintergrund
     laufen (nicht nur kurz wie im UI-Dialog) – falls exklusiv, wäre das ein Problem.
   - Lizenz-/Robustheits-Hinweis: Dies bleibt ein **undokumentiertes, jederzeit von Logitech
     änderbares Protokoll** – für eine produktive PinchBar-Funktion müsste ein Fallback/Opt-in
     mit klarer Fehlerbehandlung existieren, falls der Agent nicht läuft oder sich das Protokoll
     ändert.

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

# NÄCHSTER SCHRITT: Maus-Events testen ("MOUSE" ist NICHT der richtige Filter-Wert, siehe oben --
# erst einen gültigen Enum-Wert finden/raten, dann mit Daumentaste-Druck während der 30s testen)
python3 sniff_button_events.py input_tracker --filter MOUSE_BUTTON --duration 30

# Falls nötig: MITM-Proxy für weitere UI-Flow-Exploration
# (Options+-UI vorher beenden, Agent-Hintergrundprozess läuft weiter lassen)
python3 sniff_button_events.py proxy > out.txt 2>&1
# ... Options+ UI neu öffnen, gewünschten Flow durchspielen, Ctrl-C ...
grep -n '"verb": "SET"\|SUBSCRIBE\|input_tracker' out.txt | cut -c1-300
```
