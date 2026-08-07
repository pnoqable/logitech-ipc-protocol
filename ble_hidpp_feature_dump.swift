// Read-only HID++ 2.0 feature enumeration for directly Bluetooth-connected
// Logitech devices on macOS.
//
// It resolves FEATURE_SET (0x0001) through ROOT, reads its count, and then
// enumerates every feature with FEATURE_SET.getFeatureId. No host switching,
// pairing, provisioning, reset, or other state-changing HID++ command is sent.
// In particular, HOSTS_INFO (0x1815) is only reported when present; it is not
// queried because its read-function payload is not verified for this device.
//
// BLE HID++ framing: [featureIndex] [funcId << 4 | swId] [parameters...]
// Usage: swift ble_hidpp_feature_dump.swift

import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)

let candidateServiceUUIDs = [
    CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
]
let logitechVendorUUIDSuffix = "046D"
let rootFeatureIndex: UInt8 = 0x00
let featureSetID: UInt16 = 0x0001
let changeHostID: UInt16 = 0x1814
let hostsInfoID: UInt16 = 0x1815
let ourSoftwareID: UInt8 = 0x02
let timeoutSeconds = 45.0

struct PendingRequest {
    let featureIndex: UInt8
    let functionID: UInt8
    let description: String
}

final class DeviceState {
    let peripheral: CBPeripheral
    var hidppCharacteristic: CBCharacteristic?
    var featureSetIndex: UInt8?
    var featureCount: Int?
    var nextFeatureIndex = 0
    var pending: PendingRequest?
    var completed = false

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    var label: String {
        peripheral.name ?? peripheral.identifier.uuidString
    }
}

func hidppFrame(featureIndex: UInt8, functionID: UInt8, parameters: [UInt8] = []) -> Data {
    Data([featureIndex, (functionID << 4) | ourSoftwareID] + parameters)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func isLogitechVendorService(_ uuid: CBUUID) -> Bool {
    uuid.uuidString.uppercased().hasSuffix(logitechVendorUUIDSuffix)
}

func featureFlags(_ flags: UInt8) -> String {
    var names: [String] = []
    if flags & 0x20 != 0 { names.append("internal") }
    if flags & 0x40 != 0 { names.append("hidden") }
    if flags & 0x80 != 0 { names.append("obsolete") }
    return names.isEmpty ? "-" : names.joined(separator: ",")
}

final class FeatureDumper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var devices: [UUID: DeviceState] = [:]
    var foundHIDPPDevice = false

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }

        var seen = Set<UUID>()
        for serviceUUID in candidateServiceUUIDs {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
                guard seen.insert(peripheral.identifier).inserted else { continue }
                let state = DeviceState(peripheral: peripheral)
                devices[peripheral.identifier] = state
                peripheral.delegate = self
                print("\(state.label): pruefe Logitech-HID++-Service ...")
                central.connect(peripheral, options: nil)
            }
        }

        if devices.isEmpty {
            print("Keine verbundenen Bluetooth-Peripherals mit Standard-Services gefunden.")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("\(peripheral.name ?? peripheral.identifier.uuidString): Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "?")")
        devices.removeValue(forKey: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        if let error = error {
            print("\(state.label): Service-Discovery fehlgeschlagen: \(error.localizedDescription)")
            devices.removeValue(forKey: peripheral.identifier)
            return
        }

        let vendorServices = (peripheral.services ?? []).filter { isLogitechVendorService($0.uuid) }
        guard !vendorServices.isEmpty else {
            print("\(state.label): kein Logitech-HID++-Service, ignoriere.")
            devices.removeValue(forKey: peripheral.identifier)
            return
        }
        for service in vendorServices {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        if let error = error {
            print("\(state.label): Characteristic-Discovery fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        guard let characteristic = (service.characteristics ?? []).first(where: {
            $0.properties.contains(.notify) && $0.properties.contains(.write)
        }) else {
            print("\(state.label): kein beschreibbarer/benachrichtigbarer HID++-Kanal.")
            return
        }
        state.hidppCharacteristic = characteristic
        foundHIDPPDevice = true
        print("\(state.label): HID++-Kanal \(characteristic.uuid), aktiviere Notify.")
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier] else { return }
        if let error = error {
            print("\(state.label): Notify-Aktivierung fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        send(state, featureIndex: rootFeatureIndex, functionID: 0,
             parameters: [UInt8(featureSetID >> 8), UInt8(featureSetID & 0xFF)],
             description: "ROOT.getFeature(0x0001 FEATURE_SET)")
    }

    func send(_ state: DeviceState, featureIndex: UInt8, functionID: UInt8,
              parameters: [UInt8] = [], description: String) {
        guard let characteristic = state.hidppCharacteristic else { return }
        let frame = hidppFrame(featureIndex: featureIndex, functionID: functionID, parameters: parameters)
        state.pending = PendingRequest(featureIndex: featureIndex, functionID: functionID, description: description)
        print("[\(state.label)] TX \(description): \(hex([UInt8](frame)))")
        state.peripheral.writeValue(frame, for: characteristic,
                                    type: characteristic.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error, let state = devices[peripheral.identifier] {
            print("\(state.label): Schreibfehler: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = devices[peripheral.identifier], let value = characteristic.value else { return }
        if let error = error {
            print("\(state.label): Notify-Fehler: \(error.localizedDescription)")
            return
        }
        let bytes = [UInt8](value)
        guard bytes.count >= 2, let pending = state.pending else { return }

        let expectedHeader = (pending.functionID << 4) | ourSoftwareID
        if bytes[0] == 0xFF, bytes.count >= 4,
           bytes[1] == pending.featureIndex, bytes[2] == expectedHeader {
            print("[\(state.label)] RX \(pending.description): \(hex(bytes)) (HID++ error 0x\(String(format: "%02x", bytes[3])))")
            state.pending = nil
            state.completed = true
            finishIfPossible()
            return
        }
        guard bytes[0] == pending.featureIndex, bytes[1] == expectedHeader else { return }

        let parameters = Array(bytes.dropFirst(2))
        print("[\(state.label)] RX \(pending.description): \(hex(bytes))")
        state.pending = nil
        handleResponse(state, request: pending, parameters: parameters)
    }

    func handleResponse(_ state: DeviceState, request: PendingRequest, parameters: [UInt8]) {
        if request.featureIndex == rootFeatureIndex {
            guard let index = parameters.first, index != 0 else {
                print("\(state.label): FEATURE_SET nicht unterstuetzt.")
                state.completed = true
                finishIfPossible()
                return
            }
            state.featureSetIndex = index
            send(state, featureIndex: index, functionID: 0, description: "FEATURE_SET.getCount")
            return
        }

        if request.functionID == 0 {
            guard let count = parameters.first else {
                print("\(state.label): FEATURE_SET.getCount ohne Nutzdaten.")
                state.completed = true
                finishIfPossible()
                return
            }
            // GetCount excludes ROOT, while feature indices include ROOT at index 0.
            state.featureCount = Int(count) + 1
            state.nextFeatureIndex = 0
            print("\n\(state.label): FEATURE_SET meldet \(count) Feature(s), zusaetzlich zu ROOT.\n")
            sendNextFeature(state)
            return
        }

        guard parameters.count >= 4 else {
            print("\(state.label): getFeatureId ohne vollstaendige Nutzdaten.")
            state.completed = true
            finishIfPossible()
            return
        }
        let featureID = (UInt16(parameters[0]) << 8) | UInt16(parameters[1])
        let flags = parameters[2]
        let version = parameters[3]
        let index = state.nextFeatureIndex - 1
        let marker: String
        switch featureID {
        case changeHostID: marker = "  <== CHANGE_HOST"
        case hostsInfoID: marker = "  <== HOSTS_INFO (nur erkannt, nicht abgefragt)"
        default: marker = ""
        }
        print("[\(state.label)] index=0x\(String(format: "%02x", index)) id=0x\(String(format: "%04x", featureID)) version=\(version) flags=0x\(String(format: "%02x", flags)) [\(featureFlags(flags))]\(marker)")
        sendNextFeature(state)
    }

    func sendNextFeature(_ state: DeviceState) {
        guard let featureSetIndex = state.featureSetIndex, let count = state.featureCount else { return }
        guard state.nextFeatureIndex < count else {
            print("\n\(state.label): Feature-Dump abgeschlossen. Es wurden keine Host- oder Pairing-Aktionen ausgefuehrt.\n")
            state.completed = true
            finishIfPossible()
            return
        }
        let index = state.nextFeatureIndex
        state.nextFeatureIndex += 1
        send(state, featureIndex: featureSetIndex, functionID: 1, parameters: [UInt8(index)],
             description: "FEATURE_SET.getFeatureId(index=0x\(String(format: "%02x", index)))")
    }

    func finishIfPossible() {
        let activeStates = Array(devices.values)
        guard foundHIDPPDevice, !activeStates.isEmpty, activeStates.allSatisfy({ $0.completed }) else { return }
        exit(0)
    }
}

let dumper = FeatureDumper()
dumper.start()
DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
    if !dumper.foundHIDPPDevice {
        print("Timeout: kein Logitech-HID++-Geraet gefunden.")
    } else {
        print("Timeout: mindestens eine Anfrage blieb ohne passende Antwort. Die bisher geloggten Frames sind vollstaendig erhalten.")
    }
    exit(1)
}
RunLoop.main.run()
