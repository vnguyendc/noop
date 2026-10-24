import Foundation

public struct WatchDirectDevice: Identifiable, Equatable {
    public let id: UUID
    public var displayName: String
    public var rssi: Int

    public init(id: UUID, displayName: String, rssi: Int) {
        self.id = id
        self.displayName = displayName
        self.rssi = rssi
    }
}

public struct WatchDirectLiveState: Equatable {
    public var scanning = false
    public var connecting = false
    public var connected = false
    public var discoveredDevices: [WatchDirectDevice] = []
    public var selectedDevice: WatchDirectDevice?
    public var bpm: Int?
    public var rr: [Int] = []
    public var batteryPct: Int?
    public var errorMessage: String?

    public init() {}

    public var isActive: Bool {
        scanning || connecting || connected
    }

    public mutating func startScan() {
        scanning = true
        connecting = false
        connected = false
        selectedDevice = nil
        errorMessage = nil
    }

    public mutating func upsertDiscoveredDevice(_ device: WatchDirectDevice) {
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        discoveredDevices.sort { lhs, rhs in
            if lhs.rssi == rhs.rssi { return lhs.displayName < rhs.displayName }
            return lhs.rssi > rhs.rssi
        }
    }

    public mutating func selectDevice(_ device: WatchDirectDevice) {
        scanning = false
        connecting = true
        connected = false
        selectedDevice = device
        errorMessage = nil
    }

    public mutating func markConnected() {
        scanning = false
        connecting = false
        connected = true
        errorMessage = nil
    }

    public mutating func receiveHeartRate(hr: Int, rr intervals: [Int]) {
        bpm = hr
        rr = intervals
        connected = true
        connecting = false
        scanning = false
        errorMessage = nil
    }

    public mutating func updateBattery(_ pct: Int) {
        batteryPct = pct
    }

    public mutating func fail(_ message: String) {
        scanning = false
        connecting = false
        connected = false
        errorMessage = message
    }

    public mutating func stop() {
        scanning = false
        connecting = false
        connected = false
        selectedDevice = nil
        discoveredDevices.removeAll()
        errorMessage = nil
    }
}

public enum WatchDirectHandoffAction: Equatable {
    case none
    case disconnectPhone
    case reconnectPhone
}

public struct WatchDirectHandoffCoordinator: Equatable {
    public private(set) var watchDirectModeActive = false
    public private(set) var reconnectAfterWatchDirect = false

    public init() {}

    public mutating func apply(watchDirectModeActive active: Bool, phoneWasConnected: Bool) -> WatchDirectHandoffAction {
        if active {
            guard !watchDirectModeActive else { return .none }
            watchDirectModeActive = true
            reconnectAfterWatchDirect = phoneWasConnected
            return phoneWasConnected ? .disconnectPhone : .none
        }

        guard watchDirectModeActive else { return .none }
        watchDirectModeActive = false
        let shouldReconnect = reconnectAfterWatchDirect
        reconnectAfterWatchDirect = false
        return shouldReconnect ? .reconnectPhone : .none
    }
}
