// CoreBluetooth HID++ 2.0 client fuer die MX Anywhere 3, direkt ueber macOS-Bluetooth
// (kein Unifying-Dongle noetig). Nutzt den vendor-spezifischen GATT-Kanal (Service
// 00010000-0000-1000-8000-011F2000046D, Characteristic 00010001-...) und das am
// 26./27.07.2026 per Packet-Sniff bit-genau verifizierte BLE-HID++-Framing:
//
//     [featureIndex] [funcId<<4 | swId] [param0] [param1] ...
//
// (KEIN 0x10/0x11 Report-Marker, KEIN devIndex-Byte wie beim USB-Dongle - beides
// entfaellt bei BLE, da pro GATT-Verbindung nur ein logisches Geraet existiert.)
// Notifications sind immer auf 19 Byte nullgepolstert.
//
// Ablauf:
//   1) Root.getFeature(0x1B04) -> ermittelt dynamisch den featureIndex (bei der
//      getesteten MX Anywhere 3 bisher immer 0x09, aber nie hardcodieren - kann sich
//      laut Firmware-Version/Geraet unterscheiden, siehe hidpp_thumb_buttons.py).
//   2) setCidReporting(cid=83/Back, divert=1, dvalid=1) und dasselbe fuer 86/Forward,
//      mit einer EIGENEN swId (0x1) - Options+ nutzt 0xC, damit bleiben wir
//      unterscheidbar und stoeren uns nicht gegenseitig.
//   3) Auf Notifications lauschen, divertedButtonsEvent (funcId=0, swId=0) decodieren
//      und als DOWN/UP fuer Back/Forward ausgeben.
//   4) Bei Beendigung (Ctrl-C) divert wieder auf 0 zuruecksetzen.
//
// Usage: swift ble_hidpp_thumb_buttons.swift
// Voraussetzung: MX Anywhere 3 per direktem macOS-Bluetooth gekoppelt (nicht der Dongle).

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

let targetName = "MX Anywhere 3"
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
let runSeconds = 120.0

let ROOT_FEATURE_INDEX: UInt8 = 0x00
let FEATURE_ID_1B04: UInt16 = 0x1B04
let OUR_SW_ID: UInt8 = 0x1

let CID_BACK: UInt16 = 83
let CID_FORWARD: UInt16 = 86
let CID_NAMES: [UInt16: String] = [80: "Left", 81: "Right", 82: "Middle", 83: "Back", 86: "Forward", 196: "SmartShift"]

func hidppFrame(featureIndex: UInt8, funcId: UInt8, swId: UInt8, params: [UInt8]) -> Data {
    var bytes: [UInt8] = [featureIndex, (funcId << 4) | (swId & 0x0F)]
    bytes.append(contentsOf: params)
    return Data(bytes)
}

func setCidReportingFrame(featureIndex: UInt8, swId: UInt8, cid: UInt16, divert: Bool, dvalid: Bool) -> Data {
    let flags: UInt8 = (dvalid ? 0b0000_0010 : 0) | (divert ? 0b0000_0001 : 0)
    let params: [UInt8] = [
        UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF),
        flags,
        0x00, 0x00, // remap = 0 (unveraendert lassen)
    ]
    return hidppFrame(featureIndex: featureIndex, funcId: 0x03, swId: swId, params: params)
}

final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheralRef: CBPeripheral?
    var hidppChar: CBCharacteristic?
    var feature1B04Index: UInt8?
    var pressedCids: Set<UInt16> = []
    var resetSent = false

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
        signal(SIGINT, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler { [weak self] in
            print("\nCtrl-C erkannt, setze divert zurueck und beende ...")
            self?.resetAndExit()
        }
        sigintSrc.resume()
    }

    func resetAndExit() {
        guard !resetSent, let p = peripheralRef, let c = hidppChar, let fi = feature1B04Index else {
            exit(0)
        }
        resetSent = true
        p.writeValue(setCidReportingFrame(featureIndex: fi, swId: OUR_SW_ID, cid: CID_BACK, divert: false, dvalid: true),
                     for: c, type: .withoutResponse)
        p.writeValue(setCidReportingFrame(featureIndex: fi, swId: OUR_SW_ID, cid: CID_FORWARD, divert: false, dvalid: true),
                     for: c, type: .withoutResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("Bluetooth state: \(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        for uuid in candidateServiceUUIDs {
            for p in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                if p.name == targetName && peripheralRef == nil {
                    peripheralRef = p
                    p.delegate = self
                    print("Gefunden: \(p.name ?? "?") \(p.identifier) -> verbinde ...")
                    c.connect(p, options: nil)
                }
            }
        }
        if peripheralRef == nil {
            print("MX Anywhere 3 nicht unter verbundenen Peripherals gefunden. Ist sie per Bluetooth gekoppelt und aktiv?")
            exit(1)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Verbunden. Suche Services ...")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services where s.uuid.uuidString.count > 4 {
            print("Vendor-Service: \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars where c.properties.contains(.notify) && c.properties.contains(.write) {
            print("HID++-Kanal: \(c.uuid) properties=\(c.properties)")
            hidppChar = c
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error = error {
            print("Notify-Aktivierung fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        print("Notify aktiv. Sende Root.getFeature(0x1B04) ...")
        guard let c = hidppChar else { return }
        let params: [UInt8] = [UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), UInt8(FEATURE_ID_1B04 & 0xFF)]
        let req = hidppFrame(featureIndex: ROOT_FEATURE_INDEX, funcId: 0x00, swId: OUR_SW_ID, params: params)
        print("  write: \(req.map { String(format: "%02x", $0) }.joined())")
        peripheral.writeValue(req, for: c, type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("  Schreibfehler: \(error.localizedDescription)")
        }
    }

    func armDivert(peripheral: CBPeripheral, characteristic: CBCharacteristic, featureIndex: UInt8) {
        print("Feature 0x1B04 -> featureIndex=0x\(String(format: "%02x", featureIndex)). Aktiviere divert fuer Back(83)/Forward(86) ...")
        let backFrame = setCidReportingFrame(featureIndex: featureIndex, swId: OUR_SW_ID, cid: CID_BACK, divert: true, dvalid: true)
        let fwdFrame = setCidReportingFrame(featureIndex: featureIndex, swId: OUR_SW_ID, cid: CID_FORWARD, divert: true, dvalid: true)
        peripheral.writeValue(backFrame, for: characteristic, type: .withoutResponse)
        peripheral.writeValue(fwdFrame, for: characteristic, type: .withoutResponse)
        print("Divert aktiv. Druecke jetzt Back/Forward an der Maus (Ctrl-C zum Beenden, setzt Divert zurueck).")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Notify-Fehler: \(error.localizedDescription)")
            return
        }
        guard let v = characteristic.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        let featureIndex = bytes[0]
        let funcId = bytes[1] >> 4
        let swId = bytes[1] & 0x0F
        let params = Array(bytes.dropFirst(2))

        if feature1B04Index == nil {
            // Antwort auf Root.getFeature: featureIndex==ROOT, funcId==0, swId==unser eigener
            if featureIndex == ROOT_FEATURE_INDEX && funcId == 0 && swId == OUR_SW_ID && params.count >= 1 {
                let foundIndex = params[0]
                if foundIndex != 0 {
                    feature1B04Index = foundIndex
                    armDivert(peripheral: peripheral, characteristic: characteristic, featureIndex: foundIndex)
                } else {
                    print("Feature 0x1B04 nicht gefunden (featureIndex=0). Abbruch.")
                    exit(1)
                }
            }
            return
        }

        guard featureIndex == feature1B04Index else { return }

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
            let newlyDown = currentlyPressed.subtracting(pressedCids)
            let newlyUp = pressedCids.subtracting(currentlyPressed)
            for cid in newlyDown {
                print("DOWN  \(CID_NAMES[cid] ?? "cid\(cid)")")
            }
            for cid in newlyUp {
                print("UP    \(CID_NAMES[cid] ?? "cid\(cid)")")
            }
            pressedCids = currentlyPressed
        }
        // funcId==3 mit swId==unser eigener: ACK auf unser setCidReporting - ignorieren, ist erwartet.
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "?")")
        exit(1)
    }
}

let client = Client()
client.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: runSeconds))
print("\nTimeout erreicht, setze divert zurueck ...")
client.resetAndExit()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
