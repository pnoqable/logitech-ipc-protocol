// CoreBluetooth HID++ probe, phase 2: talk to the vendor-specific GATT characteristic
// discovered on the MX Anywhere 3 / MX Keys (service 00010000-0000-1000-8000-011F2000046D,
// characteristic 00010001-... with properties read/write/writeNoResp/notify).
//
// Hypothesis: this characteristic carries raw HID++ 2.0 frames using the same on-wire byte
// format as the USB/Unifying short/long reports (0x10/0x11 + deviceIndex + featureIndex +
// funcId<<4|swId + params), just tunneled over GATT read/write/notify instead of USB HID
// reports. This script writes a Root.GetFeature(0x1B04) request and listens for a matching
// notification to test that hypothesis - if it works, this is the way to bypass macOS's
// IOHIDManager block on Bluetooth input devices (see pinchbar-session-handoff.md, Abschnitt
// 3.7 "Offene Frage").
//
// Usage: swift ble_hidpp_probe.swift
// Requires the MX Anywhere 3 to be connected via direct macOS Bluetooth (not the dongle).

import Foundation
import CoreBluetooth

let targetName = "MX Anywhere 3"
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
let runSeconds = 30.0

// Same constants/framing as hidpp_thumb_buttons.py, ported to Swift.
let ROOT_FEATURE_INDEX: UInt8 = 0x00
let FEATURE_ID_1B04: UInt16 = 0x1B04
let SW_ID: UInt8 = 0x05

// Two framing hypotheses to test against the real device:
//   A) same as USB: leading 0x10/0x11 report-id byte, then devIdx, featIdx, funcId/swId, params
//   B) no report-id byte (GATT already frames the message): devIdx, featIdx, funcId/swId, params
func shortReportWithMarker(devidx: UInt8, featidx: UInt8, funcid: UInt8, swid: UInt8,
                            d0: UInt8 = 0, d1: UInt8 = 0, d2: UInt8 = 0) -> Data {
    let fsw = (funcid << 4) | (swid & 0x0F)
    return Data([0x10, devidx, featidx, fsw, d0, d1, d2])
}

func shortReportNoMarker(devidx: UInt8, featidx: UInt8, funcid: UInt8, swid: UInt8,
                          d0: UInt8 = 0, d1: UInt8 = 0, d2: UInt8 = 0) -> Data {
    let fsw = (funcid << 4) | (swid & 0x0F)
    return Data([devidx, featidx, fsw, d0, d1, d2])
}

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var hidppChar: CBCharacteristic?
    var vendorServiceUUID: CBUUID?

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("state: \(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        for uuid in candidateServiceUUIDs {
            for p in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                if p.name == targetName && target == nil {
                    target = p
                    p.delegate = self
                    print("gefunden: \(p.name ?? "?") \(p.identifier) -> verbinde ...")
                    c.connect(p, options: nil)
                }
            }
        }
        if target == nil {
            print("MX Anywhere 3 nicht unter verbundenen Peripherals gefunden.")
            exit(1)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Verbunden. Suche Services ...")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services {
            let isStandard = s.uuid.uuidString.count <= 4
            if !isStandard {
                vendorServiceUUID = s.uuid
                print("Vendor-Service: \(s.uuid)")
            }
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.properties.contains(.notify) && c.properties.contains(.write) {
                print("HID++-Kandidat: \(c.uuid) properties=\(c.properties)")
                hidppChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error = error {
            print("Notify-Aktivierung fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        print("Notify aktiv fuer \(characteristic.uuid). Sende Root.GetFeature(0x1B04) Testanfragen ...")
        guard let c = hidppChar else { return }

        // Try both framing hypotheses (with/without leading 0x10 marker) across a few
        // plausible device index conventions for BLE (single logical device per connection,
        // unlike the multi-device Unifying receiver).
        struct Attempt { let label: String; let frame: Data }
        var attempts: [Attempt] = []
        for devidx: UInt8 in [0x00, 0xFF, 0x01] {
            let a = shortReportWithMarker(devidx: devidx, featidx: ROOT_FEATURE_INDEX, funcid: 0x00, swid: SW_ID,
                                           d0: UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), d1: UInt8(FEATURE_ID_1B04 & 0xFF))
            attempts.append(Attempt(label: "withMarker devIdx=0x\(String(format: "%02X", devidx))", frame: a))
            let b = shortReportNoMarker(devidx: devidx, featidx: ROOT_FEATURE_INDEX, funcid: 0x00, swid: SW_ID,
                                        d0: UInt8((FEATURE_ID_1B04 >> 8) & 0xFF), d1: UInt8(FEATURE_ID_1B04 & 0xFF))
            attempts.append(Attempt(label: "noMarker   devIdx=0x\(String(format: "%02X", devidx))", frame: b))
        }
        var i = 0
        func sendNext() {
            guard i < attempts.count else { return }
            let a = attempts[i]
            i += 1
            print("  write [\(a.label)]: \(a.frame.map { String(format: "%02x", $0) }.joined())")
            let writeType: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(a.frame, for: c, type: writeType)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { sendNext() }
        }
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("  Schreibfehler: \(error.localizedDescription)")
        } else {
            print("  Schreiben OK (with-response bestaetigt)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Notify-Fehler: \(error.localizedDescription)")
            return
        }
        if let v = characteristic.value {
            print(">>> Notification \(characteristic.uuid): \(v.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "?")")
        exit(1)
    }
}

let prober = Prober()
prober.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: runSeconds))
print("\nFertig (Timeout erreicht).")
