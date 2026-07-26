// Reiner GET-Check (schreibt NICHTS) fuer Feature 0x1B04 / getCidReporting: zeigt den
// aktuellen divert/persist/rawXY/remap-Zustand fuer die angegebenen CIDs (Default: 83=Back,
// 86=Forward). Nuetzlich um vor/nach Experimenten mit `ble_hidpp_thumb_buttons.swift` oder
// `ble_hidpp_reset_divert.swift` zu pruefen, was auf der Maus tatsaechlich gerade konfiguriert
// ist, ohne selbst etwas zu veraendern.
//
// Wichtiger Befund (27.07.2026): Bei aktuellen Logi-Options+-Versionen bleibt Back/Forward
// IMMER divertiert (divert=1) - der Treiber setzt das offenbar dauerhaft durch/erzwingt es,
// auch nachdem man es per setCidReporting(divert=0) manuell zurueckgesetzt hat (nach kurzer
// Zeit sprang es von selbst wieder auf divert=1, ohne dass wir etwas geschrieben haben). Native
// Weiterleitung von Back/Forward an Apps (ohne Diversion) scheint es in aktuellen Options+-
// Versionen gar nicht mehr zu geben. Das ist praktisch fuer uns: unsere eigenen Tools muessen
// divert vermutlich gar nicht mehr selbst setzen, siehe `ble_hidpp_thumb_buttons.swift`.
//
// Usage: swift ble_hidpp_check_divert_state.swift [cid1 cid2 ...]
// (ohne Argumente: prueft 83 und 86)

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

let targetName = "MX Anywhere 3"
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
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

final class Checker: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var p: CBPeripheral?
    var ch: CBCharacteristic?
    var featureIndex: UInt8?
    var queue: [UInt16] = cidsToCheck

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        for uuid in candidateServiceUUIDs {
            for per in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                if per.name == targetName && p == nil { p = per; per.delegate = self; c.connect(per, options: nil) }
            }
        }
        if p == nil { print("Maus '\(targetName)' nicht unter verbundenen Peripherals gefunden."); exit(1) }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices(nil) }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid.uuidString.count > 4 { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.properties.contains(.notify) && c.properties.contains(.write) {
            ch = c
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = ch else { return }
        let params: [UInt8] = [UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), UInt8(FEATURE_ID_1B04 & 0xFF)]
        let req = hidppFrame(featureIndex: ROOT_FEATURE_INDEX, funcId: 0x00, swId: OUR_SW_ID, params: params)
        peripheral.writeValue(req, for: c, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let v = characteristic.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        let fIdx = bytes[0]
        let funcId = bytes[1] >> 4
        let swId = bytes[1] & 0x0F
        let params = Array(bytes.dropFirst(2))

        if featureIndex == nil {
            if fIdx == ROOT_FEATURE_INDEX && funcId == 0 && swId == OUR_SW_ID && params.count >= 1 && params[0] != 0 {
                featureIndex = params[0]
                askNext(peripheral: peripheral)
            }
            return
        }
        guard fIdx == featureIndex, funcId == 2, swId == OUR_SW_ID, params.count >= 5 else { return }
        let cid = (UInt16(params[0]) << 8) | UInt16(params[1])
        let flags = params[2]
        let remap = (UInt16(params[3]) << 8) | UInt16(params[4])
        print("cid=\(cid)(\(CID_NAMES[cid] ?? "?"))  divert=\(flags & 1)  persist=\((flags >> 2) & 1)  rawXY=\((flags >> 4) & 1)  remap=\(remap)")
        askNext(peripheral: peripheral)
    }

    func askNext(peripheral: CBPeripheral) {
        guard let c = ch, let fi = featureIndex else { return }
        if queue.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }; return }
        let cid = queue.removeFirst()
        let params: [UInt8] = [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF)]
        let req = hidppFrame(featureIndex: fi, funcId: 0x02, swId: OUR_SW_ID, params: params)
        peripheral.writeValue(req, for: c, type: .withResponse)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "?")")
        exit(1)
    }
}

let checker = Checker()
checker.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
