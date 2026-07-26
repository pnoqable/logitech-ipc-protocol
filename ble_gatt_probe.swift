// CoreBluetooth GATT probe for the Logitech MX Anywhere 3.
//
// Purpose: verify whether raw HID++ frames can be sent/received via CoreBluetooth GATT
// (a different API layer than IOHIDManager, which macOS blocks for Bluetooth *input*
// devices). If the mouse exposes either:
//   (a) a Logitech vendor-specific GATT service, or
//   (b) the standard HID-over-GATT service (0x1812) with readable/writable Report
//       characteristics
// then it may be possible to read/write HID++ short/long reports through CoreBluetooth
// even though IOHIDDeviceOpen() is blocked for this device.
//
// This is read-only reconnaissance: it lists all services/characteristics/properties. It
// does NOT yet attempt to write HID++ frames - that's the next step once we know which
// characteristic (if any) looks like the right one.
//
// Requires the MX Anywhere 3 to be actively paired via direct macOS Bluetooth (not via the
// Unifying dongle) so a BLE connection can be established.
//
// Usage:
//   swift ble_gatt_probe.swift
//
// The first run will likely trigger a macOS Bluetooth permission prompt for the terminal
// app being used to run this (Terminal/iTerm) - grant it under System Settings > Privacy &
// Security > Bluetooth if not prompted automatically.

import Foundation
import CoreBluetooth

let targetNameSubstrings = ["MX Anywhere", "Anywhere 3"]
let scanTimeoutSeconds = 20.0
let hidServiceUUID = CBUUID(string: "1812") // standard HID-over-GATT
// Additional standard services the OS may have already cached for this peripheral
// (populated when macOS itself did a GATT read for e.g. battery level).
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), // Human Interface Device
    CBUUID(string: "180F"), // Battery Service
    CBUUID(string: "180A"), // Device Information
    CBUUID(string: "1800"), // Generic Access
]
let logitechCompanyID: UInt16 = 0x0060 // Bluetooth SIG assigned company identifier for Logitech

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var startTime = Date()

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("CBCentralManager state: \(c.state.rawValue) (\(describeState(c.state)))")
        guard c.state == .poweredOn else {
            if c.state == .unauthorized {
                print("-> Bluetooth-Zugriff nicht autorisiert. Bitte in Systemeinstellungen > " +
                      "Datenschutz & Sicherheit > Bluetooth der Terminal-App Zugriff erlauben, " +
                      "dann Skript erneut starten.")
            }
            return
        }

        // Check already-connected/known peripherals first. A peripheral already connected
        // via the system Bluetooth HID stack won't be advertising anymore, so scanning alone
        // won't find it - we must ask CoreBluetooth for peripherals it already knows about
        // that expose any of these cached standard services.
        for uuid in candidateServiceUUIDs {
            let known = c.retrieveConnectedPeripherals(withServices: [uuid])
            for p in known {
                print("Bereits verbundenes Peripheral (via Service \(uuid)): \(p.name ?? "?") \(p.identifier)")
                if target == nil {
                    target = p
                    p.delegate = self
                    print("-> verbinde ...")
                    c.connect(p, options: nil)
                }
            }
        }

        print("Scanne nach BLE-Peripherals (\(Int(scanTimeoutSeconds))s Timeout, Ziel-Name enthaelt " +
              "\(targetNameSubstrings))) ...")
        startTime = Date()
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds) {
            if self.target == nil {
                print("\nTimeout: kein passendes Geraet gefunden. Ist die Maus per Bluetooth " +
                      "gekoppelt (nicht ueber den Dongle) und in Reichweite?")
                exit(1)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(unbekannt)"
        let svcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        var extra = ""
        if !svcUUIDs.isEmpty {
            extra += " services=\(svcUUIDs.map { $0.uuidString })"
        }
        var isLogitech = false
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            let companyID = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
            extra += " mfgCompanyID=0x\(String(format: "%04X", companyID))"
            if companyID == logitechCompanyID {
                isLogitech = true
                extra += " <<< LOGITECH"
            }
        }
        print("gefunden: \(name)  id=\(peripheral.identifier)  rssi=\(RSSI)\(extra)")

        let isTarget = targetNameSubstrings.contains { name.range(of: $0, options: .caseInsensitive) != nil } || isLogitech
        if isTarget && target == nil {
            target = peripheral
            print("-> Ziel gefunden, verbinde ...")
            c.stopScan()
            peripheral.delegate = self
            c.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Verbunden mit \(peripheral.name ?? "?"). Suche Services ...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "unbekannt")")
        exit(1)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Fehler beim Service-Discovery: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        print("\n\(services.count) Service(s) gefunden:")
        for service in services {
            print("  Service \(service.uuid) \(isStandard(service.uuid) ? "(standard)" : "(VENDOR-SPEZIFISCH)")")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("  Fehler beim Characteristic-Discovery fuer \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            print("    Characteristic \(c.uuid)  properties=\(describeProps(c.properties))")
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value {
            print("      Wert von \(characteristic.uuid): \(value.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func isStandard(_ uuid: CBUUID) -> Bool {
        // Standard 16-bit Bluetooth SIG UUIDs are shorter in string form (4 hex chars).
        return uuid.uuidString.count <= 4
    }

    func describeState(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    func describeProps(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}

let prober = Prober()
prober.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: scanTimeoutSeconds + 5))
