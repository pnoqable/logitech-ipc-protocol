// Reiner GET-Check (schreibt NICHTS) fuer Feature 0x1B04 / getCidReporting: zeigt den
// aktuellen divert/persist/rawXY/remap-Zustand fuer die angegebenen CIDs (Default: 83=Back,
// 86=Forward) - fuer ALLE aktuell verbundenen Logitech-Geraete gleichzeitig (siehe
// `ble_hidpp_thumb_buttons.swift` fuer Details zur namenslosen Geraete-Erkennung ueber den
// Vendor-Service-UUID-Suffix "046D").
//
// Nuetzlich um vor/nach Experimenten mit `ble_hidpp_thumb_buttons.swift` oder
// `ble_hidpp_reset_divert.swift` zu pruefen, was auf den Maeusen tatsaechlich gerade
// konfiguriert ist, ohne selbst etwas zu veraendern.
//
// Wichtiger Befund (27.07.2026): Bei aktuellen Logi-Options+-Versionen bleibt Back/Forward
// IMMER divertiert (divert=1) - der Treiber setzt das offenbar dauerhaft durch/erzwingt es,
// auch nachdem man es per setCidReporting(divert=0) manuell zurueckgesetzt hat. Native
// Weiterleitung von Back/Forward an Apps (ohne Diversion) scheint es in aktuellen Options+-
// Versionen gar nicht mehr zu geben.
//
// Usage: swift ble_hidpp_check_divert_state.swift [cid1 cid2 ...]
// (ohne Argumente: prueft 83 und 86)

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
let LOGITECH_VENDOR_UUID_SUFFIX = "046D"
let OUR_SW_ID: UInt8 = 0x2
let ROOT_FEATURE_INDEX: UInt8 = 0x00
let FEATURE_ID_1B04: UInt16 = 0x1B04
let CID_NAMES: [UInt16: String] = [80: "Left", 81: "Right", 82: "Middle", 83: "Back", 86: "Forward", 196: "SmartShift"]

let cliArgs = CommandLine.arguments.dropFirst().compactMap { UInt16($0) }
let cidsToCheck: [UInt16] = cliArgs.isEmpty ? [83, 86] : Array(cliArgs)

func hidppFrame(featureIndex: UInt8, funcId: UInt8, swId: UInt8, params: [UInt8]) -> Data {
    var bytes: [UInt8] = [featureIndex, (funcId << 4) | (swId & 0x0F)]
    bytes.append(contentsOf: params)
    return Data(bytes)
}

func isLogitechVendorService(_ uuid: CBUUID) -> Bool {
    uuid.uuidString.uppercased().hasSuffix(LOGITECH_VENDOR_UUID_SUFFIX)
}

final class DeviceState {
    let peripheral: CBPeripheral
    var hidppChar: CBCharacteristic?
    var featureIndex: UInt8?
    var queue: [UInt16] = cidsToCheck
    var done = false

    init(peripheral: CBPeripheral) { self.peripheral = peripheral }
    var label: String { peripheral.name ?? peripheral.identifier.uuidString }
}

final class Checker: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var devices: [UUID: DeviceState] = [:]

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        var seen = Set<UUID>()
        for uuid in candidateServiceUUIDs {
            for p in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                if seen.contains(p.identifier) { continue }
                seen.insert(p.identifier)
                let state = DeviceState(peripheral: p)
                devices[p.identifier] = state
                p.delegate = self
                c.connect(p, options: nil)
            }
        }
        if devices.isEmpty {
            print("Keine verbundenen Bluetooth-Peripherals gefunden.")
            exit(1)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices(nil) }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard devices[peripheral.identifier] != nil else { return }
        var found = false
        for s in peripheral.services ?? [] where isLogitechVendorService(s.uuid) {
            found = true
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if !found {
            devices.removeValue(forKey: peripheral.identifier)
            exitIfAllDone()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        for c in service.characteristics ?? [] where c.properties.contains(.notify) && c.properties.contains(.write) {
            state.hidppChar = c
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier], let c = state.hidppChar else { return }
        let params: [UInt8] = [UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), UInt8(FEATURE_ID_1B04 & 0xFF)]
        let req = hidppFrame(featureIndex: ROOT_FEATURE_INDEX, funcId: 0x00, swId: OUR_SW_ID, params: params)
        peripheral.writeValue(req, for: c, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        guard let v = characteristic.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        let fIdx = bytes[0]
        let funcId = bytes[1] >> 4
        let swId = bytes[1] & 0x0F
        let params = Array(bytes.dropFirst(2))

        if state.featureIndex == nil {
            if fIdx == ROOT_FEATURE_INDEX && funcId == 0 && swId == OUR_SW_ID && params.count >= 1 {
                if params[0] != 0 {
                    state.featureIndex = params[0]
                    askNext(peripheral: peripheral, state: state)
                } else {
                    print("\(state.label): Feature 0x1B04 nicht unterstuetzt.")
                    state.done = true
                    exitIfAllDone()
                }
            }
            return
        }
        guard fIdx == state.featureIndex, funcId == 2, swId == OUR_SW_ID, params.count >= 5 else { return }
        let cid = (UInt16(params[0]) << 8) | UInt16(params[1])
        let flags = params[2]
        let remap = (UInt16(params[3]) << 8) | UInt16(params[4])
        print("\(state.label): cid=\(cid)(\(CID_NAMES[cid] ?? "?"))  divert=\(flags & 1)  "
              + "persist=\((flags >> 2) & 1)  rawXY=\((flags >> 4) & 1)  remap=\(remap)")
        askNext(peripheral: peripheral, state: state)
    }

    func askNext(peripheral: CBPeripheral, state: DeviceState) {
        guard let c = state.hidppChar, let fi = state.featureIndex else { return }
        if state.queue.isEmpty {
            state.done = true
            exitIfAllDone()
            return
        }
        let cid = state.queue.removeFirst()
        let params: [UInt8] = [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF)]
        let req = hidppFrame(featureIndex: fi, funcId: 0x02, swId: OUR_SW_ID, params: params)
        peripheral.writeValue(req, for: c, type: .withResponse)
    }

    func exitIfAllDone() {
        if !devices.isEmpty && devices.values.allSatisfy({ $0.done }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung zu \(peripheral.name ?? peripheral.identifier.uuidString) fehlgeschlagen: "
              + "\(error?.localizedDescription ?? "?")")
        devices.removeValue(forKey: peripheral.identifier)
    }
}

let checker = Checker()
checker.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
