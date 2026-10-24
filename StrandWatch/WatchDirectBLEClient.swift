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
    /// Standard HR sensors advertise 0x180D. A WHOOP strap may advertise only its own service, so
    /// scan for both families' primary services too; the HR characteristic is the same once connected.
    private static let scanServices: [CBUUID] = [heartRateService]
        + [DeviceFamily.whoop4, DeviceFamily.whoop5].map { CBUUID(string: $0.serviceUUIDString) }
    private static let lastDeviceKey = "noop.watch.lastDeviceId"

    /// Every plausible reading, with the time it arrived. The app buffers these for the phone.
    var onHeartRate: ((Int, [Int], Date) -> Void)?
    /// While a workout runs, an unexpected disconnect re-issues the connection instead of failing.
    var keepConnected = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// The strap we connected (or are connecting) to. Kept outside `peripherals` so a rescan, which
    /// clears the discovery list, can't make `stop()` forget to release a live link.
    private var activePeripheral: CBPeripheral?
    private var intentionalStop = false

    private var lastDeviceID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastDeviceKey) }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        intentionalStop = false
        if let active = activePeripheral, active.state == .connected || active.state == .connecting {
            central.cancelPeripheralConnection(active)
        }
        activePeripheral = nil
        peripherals.removeAll()
        state.startScan()

        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                state.fail(bluetoothUnavailableMessage)
            }
            return
        }

        central.scanForPeripherals(
            withServices: Self.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func connect(to device: WatchDirectDevice) {
        guard let peripheral = peripherals[device.id] else {
            state.fail("Device is no longer available.")
            return
        }

        central.stopScan()
        lastDeviceID = device.id
        activePeripheral = peripheral
        state.selectDevice(device)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func stop() {
        intentionalStop = true
        keepConnected = false
        central.stopScan()
        var toRelease = Set(peripherals.values.filter { $0.state == .connected || $0.state == .connecting })
        if let active = activePeripheral { toRelease.insert(active) }
        toRelease.forEach { central.cancelPeripheralConnection($0) }
        activePeripheral = nil
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
            // Bluetooth came back mid-workout: a connect issued while it was off was dropped.
            if central.state == .poweredOn, self.keepConnected, !self.state.scanning,
               let active = self.activePeripheral, active.state == .disconnected {
                self.state.markReconnecting("Reconnecting to your strap.")
                central.connect(active, options: nil)
                return
            }
            guard self.state.scanning else { return }
            if central.state == .poweredOn {
                self.central.scanForPeripherals(
                    withServices: Self.scanServices,
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
            let device = WatchDirectDevice(
                id: peripheral.identifier,
                displayName: self.displayName(for: peripheral, advertisementData: advertisementData),
                rssi: RSSI.intValue
            )
            self.state.upsertDiscoveredDevice(device)
            guard self.state.scanning else { return }
            // Reconnect to the strap used last time without making the user pick it again. On first
            // use, pick a WHOOP strap automatically when it is the only one in range.
            if peripheral.identifier == self.lastDeviceID {
                self.connect(to: device)
            } else if self.lastDeviceID == nil,
                      device.displayName.localizedCaseInsensitiveContains("WHOOP"),
                      self.state.discoveredDevices.filter({ $0.displayName.localizedCaseInsensitiveContains("WHOOP") }).count == 1 {
                self.connect(to: device)
            }
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
            // Ignore callbacks for a strap released by a rescan: chasing it would reconnect it behind
            // `activePeripheral`'s back, and failing on it would knock the new scan into the error view.
            guard !self.intentionalStop, peripheral === self.activePeripheral else { return }
            if self.keepConnected {
                self.state.markReconnecting("Couldn't reach your strap. Retrying.")
                central.connect(peripheral, options: nil)
                return
            }
            self.state.fail(error?.localizedDescription ?? "Could not connect.")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard !self.intentionalStop, peripheral === self.activePeripheral else { return }
            if self.keepConnected {
                // A pending connect never times out, so this resumes as soon as the strap is back.
                self.state.markReconnecting("Strap disconnected. Reconnecting.")
                central.connect(peripheral, options: nil)
                return
            }
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
        // Copy the value and arrival time now: a burst of notifications can overwrite
        // `characteristic.value` before the main-actor hop runs.
        let bytes = characteristic.value.map { [UInt8]($0) }
        let uuid = characteristic.uuid
        let arrivedAt = Date()
        Task { @MainActor in
            if let error {
                // A failed read (e.g. battery) shouldn't tear down a working heart-rate stream.
                if uuid == Self.heartRateCharacteristic { self.state.fail(error.localizedDescription) }
                return
            }
            guard let bytes else { return }

            switch uuid {
            case Self.heartRateCharacteristic:
                if let measurement = StandardHeartRateMeasurement.parse(bytes),
                   (30...220).contains(measurement.hr) {
                    self.state.receiveHeartRate(hr: measurement.hr, rr: measurement.rr)
                    self.onHeartRate?(measurement.hr, measurement.rr, arrivedAt)
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
