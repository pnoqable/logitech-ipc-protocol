// CoreBluetooth GATT probe fuer ALLE aktuell verbundenen Logitech-Geraete.
//
// Purpose: verify whether raw HID++ frames can be sent/received via CoreBluetooth GATT
// (a different API layer than IOHIDManager, which macOS blocks for Bluetooth *input*
// devices). Dumpt Services/Characteristics/Properties fuer jedes gefundene Geraet.
//
// GERAETE-ERKENNUNG (28.07.2026): KEINE Namenspruefung mehr! Es werden (a) alle bereits
// verbundenen Peripherals ueber die Standard-Services 1812/180F/180A/1800 gefunden, und
// (b) zusaetzlich per Scan alle advertisenden Peripherals deren BLE-Manufacturer-Company-ID
// 0x0060 (Bluetooth SIG Company Identifier fuer Logitech) ist. Beide Wege liefern
// Kandidaten, die dann per GATT-Service-Discovery weiter gefiltert werden (Vendor-Service
// mit UUID-Suffix "046D" = Logitechs USB-Vendor-ID).
//
// Requires: mindestens eine Logitech-Maus/-Tastatur aktiv per direktem macOS-Bluetooth
// gekoppelt (nicht ueber den Unifying-Dongle) damit eine BLE-Verbindung moeglich ist.
//
// Usage:
//   swift ble_gatt_probe.swift
//
// Der erste Lauf kann einen macOS-Bluetooth-Berechtigungsdialog fuer die Terminal-App
// ausloesen - unter Systemeinstellungen > Datenschutz & Sicherheit > Bluetooth erlauben,
// falls nicht automatisch gefragt wird.

import Foundation
import CoreBluetooth

let scanTimeoutSeconds = 20.0
// Standard-Services, ueber die macOS bereits verbundene (nicht mehr advertisende)
// Peripherals findet - unabhaengig vom Hersteller.
let candidateServiceUUIDs = [
    CBUUID(string: "1812"), // Human Interface Device
    CBUUID(string: "180F"), // Battery Service
    CBUUID(string: "180A"), // Device Information
    CBUUID(string: "1800"), // Generic Access
]
let logitechCompanyID: UInt16 = 0x0060 // Bluetooth SIG assigned company identifier fuer Logitech
let LOGITECH_VENDOR_UUID_SUFFIX = "046D" // Logitechs USB-Vendor-ID als Suffix in vendor-spez. UUIDs

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var targets: [UUID: CBPeripheral] = [:]

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

        // Bereits verbundene Peripherals (advertisen nicht mehr, muessen ueber ihre
        // gecachten Standard-Services gefunden werden).
        for uuid in candidateServiceUUIDs {
            for p in c.retrieveConnectedPeripherals(withServices: [uuid]) {
                connectIfNew(p, via: "bereits verbunden (Service \(uuid))")
            }
        }

        print("Scanne zusaetzlich nach advertisenden Logitech-Peripherals "
              + "(\(Int(scanTimeoutSeconds))s Timeout, Manufacturer-Company-ID 0x0060) ...")
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds) {
            c.stopScan()
            if self.targets.isEmpty {
                print("\nTimeout: keine Geraete gefunden. Ist mindestens eine Logitech-Maus/-Tastatur " +
                      "per Bluetooth gekoppelt (nicht ueber den Dongle) und in Reichweite?")
                exit(1)
            }
        }
    }

    func connectIfNew(_ p: CBPeripheral, via reason: String) {
        guard targets[p.identifier] == nil else { return }
        targets[p.identifier] = p
        p.delegate = self
        print("Kandidat gefunden: \(p.name ?? "?")  id=\(p.identifier)  [\(reason)] -> verbinde ...")
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        var isLogitech = false
        var extra = ""
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            let companyID = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
            extra += " mfgCompanyID=0x\(String(format: "%04X", companyID))"
            if companyID == logitechCompanyID {
                isLogitech = true
                extra += " <<< LOGITECH"
            }
        }
        if isLogitech {
            print("advertisement: \(peripheral.name ?? "(unbekannt)")  rssi=\(RSSI)\(extra)")
            connectIfNew(peripheral, via: "Scan, mfgCompanyID=Logitech")
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Verbunden mit \(peripheral.name ?? "?"). Suche Services ...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung zu \(peripheral.name ?? "?") fehlgeschlagen: \(error?.localizedDescription ?? "unbekannt")")
        targets.removeValue(forKey: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[\(peripheral.name ?? "?")] Fehler beim Service-Discovery: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        print("\n[\(peripheral.name ?? "?")] \(services.count) Service(s) gefunden:")
        var hasVendorService = false
        for service in services {
            let isVendor = isLogitechVendorService(service.uuid)
            if isVendor { hasVendorService = true }
            print("  Service \(service.uuid) \(isStandard(service.uuid) ? "(standard)" : isVendor ? "(LOGITECH VENDOR)" : "(vendor, unbekannt)")")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if !hasVendorService {
            print("  -> kein Logitech-Vendor-Service (Suffix \(LOGITECH_VENDOR_UUID_SUFFIX)) gefunden.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("  [\(peripheral.name ?? "?")] Fehler beim Characteristic-Discovery fuer \(service.uuid): "
                  + "\(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            print("    [\(peripheral.name ?? "?")] Characteristic \(c.uuid)  properties=\(describeProps(c.properties))")
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value {
            print("      [\(peripheral.name ?? "?")] Wert von \(characteristic.uuid): "
                  + "\(value.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func isLogitechVendorService(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.uppercased().hasSuffix(LOGITECH_VENDOR_UUID_SUFFIX)
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
