// CoreBluetooth HID++ 2.0 client fuer ALLE aktuell verbundenen Logitech-Maeuse, direkt
// ueber macOS-Bluetooth (kein Unifying-Dongle noetig). Nutzt den vendor-spezifischen
// GATT-Kanal (Service 00010000-0000-1000-8000-011F2000046D, Characteristic
// 00010001-0000-1000-8000-011F2000046D) und das am 26./27.07.2026 per Packet-Sniff
// bit-genau verifizierte BLE-HID++-Framing:
//
//     [featureIndex] [funcId<<4 | swId] [param0] [param1] ...
//
// (KEIN 0x10/0x11 Report-Marker, KEIN devIndex-Byte wie beim USB-Dongle - beides
// entfaellt bei BLE, da pro GATT-Verbindung nur ein logisches Geraet existiert.)
// Notifications sind immer auf 19 Byte nullgepolstert.
//
// GERAETE-ERKENNUNG (28.07.2026): KEINE Namenspruefung mehr! Stattdessen werden ALLE
// aktuell mit macOS verbundenen Bluetooth-Peripherals durchsucht (ueber die Standard-
// Services 1812/180F/180A/1800, die macOS fuer bereits verbundene Geraete kennt), und
// jedes Peripheral wird als "Logitech HID++ faehig" erkannt, wenn es einen GATT-Service
// hat dessen UUID auf die Logitech-USB-Vendor-ID "046D" endet (z.B.
// 00010000-0000-1000-8000-011F2000046D). Live verifiziert an MX Anywhere 3 UND M720
// Triathlon - beide exponieren exakt denselben Vendor-Service-UUID-Suffix. Dadurch
// werden automatisch ALLE angeschlossenen Logitech-HID++-Maeuse gleichzeitig bedient,
// nicht nur eine.
//
// Ablauf pro erkanntem Geraet (unabhaengig voneinander):
//   1) Root.getFeature(0x1B04) -> ermittelt dynamisch den featureIndex (kann sich je
//      Geraet/Firmware unterscheiden, siehe hidpp_thumb_buttons.py - z.B. MX Anywhere 3
//      hatte 0x09).
//   2) Nur noch auf Notifications lauschen, divertedButtonsEvent (funcId=0, swId=0)
//      decodieren und als DOWN/UP fuer Back/Forward ausgeben (mit Geraetename als Praefix).
//
// WICHTIGER BEFUND (27.07.2026): Auf dieser Hardware/mit dieser Logi-Options+-Version ist
// Back/Forward (CID 83/86) OFFENBAR DAUERHAFT divertiert (divert=1) - vermutlich vom
// laufenden `com.logi.cp-dev-mgr`-Agenten durchgesetzt/erzwungen, unabhaengig davon ob
// unser eigenes Tool laeuft. Live verifiziert:
//   - `setCidReporting(divert=0)` manuell gesetzt -> nach kurzer Zeit sprang der Wert von
//     selbst wieder auf divert=1, OHNE dass wir etwas geschrieben haben.
//   - Ein rein lauschendes Test-Skript OHNE jeglichen eigenen `setCidReporting`-Call hat
//     trotzdem saubere `divertedButtonsEvent`-Notifications fuer Back/Forward empfangen.
// Deshalb sendet dieses Skript bewusst KEIN setCidReporting mehr und muss beim Beenden
// auch nichts zuruecksetzen. Falls sich das bei einer anderen Maus/Firmware/Options+-
// Version anders verhaelt (Back/Forward liefern gar keine Events), zuerst mit
// `ble_hidpp_check_divert_state.swift 83 86` pruefen und ggf. `ble_hidpp_reset_divert.swift`
// -Logik umgekehrt nutzen um divert=1 selbst zu setzen.
//
// Usage: swift ble_hidpp_thumb_buttons.swift
// Voraussetzung: mindestens eine Logitech-Maus per direktem macOS-Bluetooth gekoppelt
// (nicht der Dongle).
// Ctrl-C beendet ueber das normale SIGINT-Default-Verhalten (Prozess terminiert sofort) -
// bewusst KEIN eigener Signal-Handler, da kein Cleanup noetig ist (siehe oben).

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

// Standard-Services, ueber die macOS bereits verbundene (nicht mehr advertisende)
// Peripherals findet - unabhaengig vom Hersteller. Die eigentliche Logitech-Erkennung
// passiert danach ueber den Vendor-Service-UUID-Suffix.
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
// Logitechs USB-Vendor-ID 0x046D taucht als Suffix in Logitechs 128-bit vendor-spezifischen
// GATT-Service-UUIDs auf (z.B. 00010000-0000-1000-8000-011F2000046D). Live verifiziert an
// MX Anywhere 3 UND M720 Triathlon.
let LOGITECH_VENDOR_UUID_SUFFIX = "046D"

let runSeconds = 120.0

let ROOT_FEATURE_INDEX: UInt8 = 0x00
let FEATURE_ID_1B04: UInt16 = 0x1B04
let OUR_SW_ID: UInt8 = 0x1

let CID_NAMES: [UInt16: String] = [80: "Left", 81: "Right", 82: "Middle", 83: "Back", 86: "Forward", 196: "SmartShift"]

func hidppFrame(featureIndex: UInt8, funcId: UInt8, swId: UInt8, params: [UInt8]) -> Data {
    var bytes: [UInt8] = [featureIndex, (funcId << 4) | (swId & 0x0F)]
    bytes.append(contentsOf: params)
    return Data(bytes)
}

func isLogitechVendorService(_ uuid: CBUUID) -> Bool {
    uuid.uuidString.uppercased().hasSuffix(LOGITECH_VENDOR_UUID_SUFFIX)
}

/// Pro Geraet gehaltener Zustand - jede Maus wird unabhaengig von den anderen behandelt.
final class DeviceState {
    let peripheral: CBPeripheral
    var hidppChar: CBCharacteristic?
    var featureIndex: UInt8?
    var pressedCids: Set<UInt16> = []

    init(peripheral: CBPeripheral) { self.peripheral = peripheral }
    var label: String { peripheral.name ?? peripheral.identifier.uuidString }
}

final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var devices: [UUID: DeviceState] = [:]

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("Bluetooth state: \(c.state.rawValue)")
        guard c.state == .poweredOn else { return }

        var seen = Set<UUID>()
        for uuid in candidateServiceUUIDs {
            for p in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                if seen.contains(p.identifier) { continue }
                seen.insert(p.identifier)
                let state = DeviceState(peripheral: p)
                devices[p.identifier] = state
                p.delegate = self
                print("Verbundenes Peripheral gefunden: \(state.label) (\(p.identifier)) -> pruefe auf Logitech-Vendor-Service ...")
                c.connect(p, options: nil)
            }
        }
        if devices.isEmpty {
            print("Keine verbundenen Bluetooth-Peripherals mit Standard-Services gefunden. "
                  + "Ist mindestens eine Maus per Bluetooth gekoppelt und aktiv?")
            exit(1)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        var foundVendorService = false
        for s in peripheral.services ?? [] where isLogitechVendorService(s.uuid) {
            foundVendorService = true
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if !foundVendorService {
            print("\(state.label): kein Logitech-Vendor-Service (Suffix \(LOGITECH_VENDOR_UUID_SUFFIX)) "
                  + "gefunden - ignoriere dieses Geraet.")
            devices.removeValue(forKey: peripheral.identifier)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        for c in service.characteristics ?? [] where c.properties.contains(.notify) && c.properties.contains(.write) {
            print("\(state.label): HID++-Kanal gefunden (\(c.uuid)).")
            state.hidppChar = c
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        if let error = error {
            print("\(state.label): Notify-Aktivierung fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        guard let c = state.hidppChar else { return }
        print("\(state.label): Notify aktiv, sende Root.getFeature(0x1B04) ...")
        let params: [UInt8] = [UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), UInt8(FEATURE_ID_1B04 & 0xFF)]
        let req = hidppFrame(featureIndex: ROOT_FEATURE_INDEX, funcId: 0x00, swId: OUR_SW_ID, params: params)
        peripheral.writeValue(req, for: c, type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error, let state = devices[peripheral.identifier] {
            print("\(state.label): Schreibfehler: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        if let error = error {
            print("\(state.label): Notify-Fehler: \(error.localizedDescription)")
            return
        }
        guard let v = characteristic.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        let featureIndex = bytes[0]
        let funcId = bytes[1] >> 4
        let swId = bytes[1] & 0x0F
        let params = Array(bytes.dropFirst(2))

        if state.featureIndex == nil {
            // Antwort auf Root.getFeature: featureIndex==ROOT, funcId==0, swId==unser eigener
            if featureIndex == ROOT_FEATURE_INDEX && funcId == 0 && swId == OUR_SW_ID && params.count >= 1 {
                let foundIndex = params[0]
                if foundIndex != 0 {
                    state.featureIndex = foundIndex
                    print("\(state.label): Feature 0x1B04 -> featureIndex=0x\(String(format: "%02x", foundIndex)). "
                          + "Lausche auf divertedButtonsEvent. Druecke jetzt Back/Forward (Ctrl-C beendet alles).")
                } else {
                    print("\(state.label): Feature 0x1B04 (Special Keys/Mouse Buttons) nicht unterstuetzt - "
                          + "ignoriere dieses Geraet fuer Button-Events.")
                }
            }
            return
        }

        guard featureIndex == state.featureIndex else { return }

        if funcId == 0 && swId == 0 {
            // divertedButtonsEvent: bis zu 4 CIDs (BE16), Liste endet bei cid==0
            var currentlyPressed: Set<UInt16> = []
            var i = 0
            while i + 1 < params.count {
                let cid = (UInt16(params[i]) << 8) | UInt16(params[i + 1])
                if cid == 0 { break }
                currentlyPressed.insert(cid)
                i += 2
            }
            let newlyDown = currentlyPressed.subtracting(state.pressedCids)
            let newlyUp = state.pressedCids.subtracting(currentlyPressed)
            for cid in newlyDown {
                print("[\(state.label)] DOWN  \(CID_NAMES[cid] ?? "cid\(cid)")")
            }
            for cid in newlyUp {
                print("[\(state.label)] UP    \(CID_NAMES[cid] ?? "cid\(cid)")")
            }
            state.pressedCids = currentlyPressed
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung zu \(peripheral.name ?? peripheral.identifier.uuidString) fehlgeschlagen: "
              + "\(error?.localizedDescription ?? "?")")
        devices.removeValue(forKey: peripheral.identifier)
    }
}

let client = Client()
client.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: runSeconds))
print("\nTimeout erreicht, beende.")
