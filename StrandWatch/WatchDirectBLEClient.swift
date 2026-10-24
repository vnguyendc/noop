import CoreBluetooth
import Foundation
import WhoopProtocol

@MainActor
final class WatchDirectBLEClient: NSObject, ObservableObject {
    @Published private(set) var state = WatchDirectLiveState()

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateCharacteristic = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryCharacteristic = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var intentionalStop = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        intentionalStop = false
        peripherals.removeAll()
        state.startScan()

        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                state.fail(bluetoothUnavailableMessage)
            }
            return
        }

        central.scanForPeripherals(
            withServices: [Self.heartRateService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func connect(to device: WatchDirectDevice) {
        guard let peripheral = peripherals[device.id] else {
            state.fail("Device is no longer available.")
            return
        }

        central.stopScan()
        state.selectDevice(device)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func stop() {
        intentionalStop = true
        central.stopScan()
        if let peripheral = peripherals.values.first(where: { $0.state == .connected || $0.state == .connecting }) {
            central.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
        state.stop()
    }

    private var bluetoothUnavailableMessage: String {
        switch central.state {
        case .unsupported:
            return "Bluetooth is not supported on this watch."
        case .unauthorized:
            return "Bluetooth permission is required."
        case .poweredOff:
            return "Bluetooth is off."
        default:
            return "Bluetooth is unavailable."
        }
    }

    private func displayName(for peripheral: CBPeripheral, advertisementData: [String: Any] = [:]) -> String {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        return localName ?? peripheral.name ?? "Heart rate sensor"
    }
}

extension WatchDirectBLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.state.scanning else { return }
            if central.state == .poweredOn {
                self.central.scanForPeripherals(
                    withServices: [Self.heartRateService],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            } else if central.state != .unknown && central.state != .resetting {
                self.state.fail(self.bluetoothUnavailableMessage)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            self.peripherals[peripheral.identifier] = peripheral
            self.state.upsertDiscoveredDevice(WatchDirectDevice(
                id: peripheral.identifier,
                displayName: self.displayName(for: peripheral, advertisementData: advertisementData),
                rssi: RSSI.intValue
            ))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.delegate = self
            self.state.markConnected()
            peripheral.discoverServices([Self.heartRateService, Self.batteryService])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.state.fail(error?.localizedDescription ?? "Could not connect.")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard !self.intentionalStop else { return }
            self.state.fail(error?.localizedDescription ?? "Disconnected.")
        }
    }
}

extension WatchDirectBLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.state.fail(error.localizedDescription)
                return
            }

            peripheral.services?.forEach { service in
                switch service.uuid {
                case Self.heartRateService:
                    peripheral.discoverCharacteristics([Self.heartRateCharacteristic], for: service)
                case Self.batteryService:
                    peripheral.discoverCharacteristics([Self.batteryCharacteristic], for: service)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.state.fail(error.localizedDescription)
                return
            }

            service.characteristics?.forEach { characteristic in
                switch characteristic.uuid {
                case Self.heartRateCharacteristic:
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.batteryCharacteristic:
                    peripheral.readValue(for: characteristic)
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.state.fail(error.localizedDescription)
                return
            }
            guard let value = characteristic.value else { return }
            let bytes = [UInt8](value)

            switch characteristic.uuid {
            case Self.heartRateCharacteristic:
                if let measurement = StandardHeartRateMeasurement.parse(bytes),
                   (30...220).contains(measurement.hr) {
                    self.state.receiveHeartRate(hr: measurement.hr, rr: measurement.rr)
                }
            case Self.batteryCharacteristic:
                if let pct = bytes.first {
                    self.state.updateBattery(Int(pct))
                }
            default:
                break
            }
        }
    }
}
