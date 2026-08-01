// Setzt setCidReporting(cid, divert=0, dvalid=1) fuer die angegebenen CIDs (Default: 83=Back,
// 86=Forward) ueber direktes Bluetooth-GATT - fuer ALLE aktuell verbundenen Logitech-Geraete
// gleichzeitig (siehe `ble_hidpp_thumb_buttons.swift` fuer Details zur namenslosen
// Geraete-Erkennung ueber den Vendor-Service-UUID-Suffix "046D").
//
// Nuetzlich zum manuellen Aufraeumen nach abgebrochenen Testlaeufen.
//
// Wichtiger Befund (27.07.2026): Auf aktuellen Logi-Options+-Versionen springt divert fuer
// Back/Forward offenbar von selbst wieder auf 1 zurueck (vermutlich durch den laufenden
// `com.logi.cp-dev-mgr`-Agenten durchgesetzt) - native, nicht-diverted Weiterleitung an Apps
// scheint es fuer diese Tasten praktisch nicht mehr zu geben. Dieses Skript ist trotzdem
// nuetzlich fuer gezielte Experimente/Verifikation, aber verlasst euch nicht darauf, dass der
// Reset dauerhaft haelt.
//
// Usage: swift ble_hidpp_reset_divert.swift [cid1 cid2 ...]
// (ohne Argumente: setzt 83 und 86 auf divert=0)

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
let LOGITECH_VENDOR_UUID_SUFFIX = "046D"
let OUR_SW_ID: UInt8 = 0x1
let ROOT_FEATURE_INDEX: UInt8 = 0x00
let FEATURE_ID_1B04: UInt16 = 0x1B04
let CID_NAMES: [UInt16: String] = [80: "Left", 81: "Right", 82: "Middle", 83: "Back", 86: "Forward", 196: "SmartShift"]

let cliArgs = CommandLine.arguments.dropFirst().compactMap { UInt16($0) }
let cidsToReset: [UInt16] = cliArgs.isEmpty ? [83, 86] : Array(cliArgs)

func hidppFrame(featureIndex: UInt8, funcId: UInt8, swId: UInt8, params: [UInt8]) -> Data {
    var bytes: [UInt8] = [featureIndex, (funcId << 4) | (swId & 0x0F)]
    bytes.append(contentsOf: params)
    return Data(bytes)
}

func setCidReportingFrame(featureIndex: UInt8, cid: UInt16, divert: Bool) -> Data {
    let flags: UInt8 = 0b0000_0010 | (divert ? 0b0000_0001 : 0) // dvalid=1, persist unangetastet
    return hidppFrame(featureIndex: featureIndex, funcId: 0x03, swId: OUR_SW_ID,
                       params: [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF), flags, 0, 0])
}

func isLogitechVendorService(_ uuid: CBUUID) -> Bool {
    uuid.uuidString.uppercased().hasSuffix(LOGITECH_VENDOR_UUID_SUFFIX)
}

final class DeviceState {
    let peripheral: CBPeripheral
    var hidppChar: CBCharacteristic?
    var featureIndex: UInt8?
    var done = false

    init(peripheral: CBPeripheral) { self.peripheral = peripheral }
    var label: String { peripheral.name ?? peripheral.identifier.uuidString }
}

final class Resetter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier], state.featureIndex == nil else { return }
        guard let v = characteristic.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        let fIdx = bytes[0]
        let funcId = bytes[1] >> 4
        let swId = bytes[1] & 0x0F
        let params = Array(bytes.dropFirst(2))
        guard fIdx == ROOT_FEATURE_INDEX, funcId == 0, swId == OUR_SW_ID, params.count >= 1 else { return }

        if params[0] == 0 {
            print("\(state.label): Feature 0x1B04 nicht unterstuetzt, ueberspringe.")
            state.done = true
            exitIfAllDone()
            return
        }
        state.featureIndex = params[0]
        guard let c = state.hidppChar else { return }
        for cid in cidsToReset {
            print("\(state.label): setze divert=0 fuer cid=\(cid)(\(CID_NAMES[cid] ?? "?")) ...")
            peripheral.writeValue(setCidReportingFrame(featureIndex: params[0], cid: cid, divert: false),
                                   for: c, type: .withoutResponse)
        }
        state.done = true
        exitIfAllDone()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}

    func exitIfAllDone() {
        if !devices.isEmpty && devices.values.allSatisfy({ $0.done }) {
            print("Reset-Frames an alle erkannten Geraete gesendet.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung zu \(peripheral.name ?? peripheral.identifier.uuidString) fehlgeschlagen: "
              + "\(error?.localizedDescription ?? "?")")
        devices.removeValue(forKey: peripheral.identifier)
    }
}

let resetter = Resetter()
resetter.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
