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

    /// The strap dropped mid-session and the client is re-issuing the connection. Keeps the last
    /// reading on screen so a brief drop doesn't blank the workout view.
    public mutating func markReconnecting(_ message: String) {
        scanning = false
        connecting = true
        connected = false
        errorMessage = message
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
    /// Let go of the strap so the watch can connect.
    case disconnectPhone
    /// Queue a pending connect so the phone re-takes the strap the moment it is free again.
    case armPhoneFallback
    /// The watch is done (or gone): reconnect now.
    case reconnectPhone
}

/// Phone-side bookkeeping for the watch borrowing the strap (a WHOOP 4.0 holds one connection).
///
/// Sequence: the watch says "start" → the phone disconnects. Once the watch holds the strap (or a
/// short grace period passes), the phone arms a pending connect, which the system completes even
/// while the phone app is suspended, as soon as the watch lets go for any reason. "Stop" reconnects
/// immediately. If the watch goes silent while the phone app is awake, `expireIfWatchSilent` also
/// hands the strap back. Changes carry the watch's timestamp so a late or duplicate message from an
/// older change is ignored.
///
/// A strap that accepts a second connection (WHOOP 5.0) is never handed over: the watch connects
/// alongside the phone. Handing it over anyway would let the phone's pending connect complete while
/// the watch still holds the strap, which `phoneReconnected` would read as the watch letting go.
public struct WatchDirectHandoffCoordinator: Equatable {
    /// The watch sends a heartbeat every minute while it holds the strap.
    public static let livenessTimeout: TimeInterval = 10 * 60
    /// How long the phone waits for the watch to grab the strap before arming its own fallback.
    public static let fallbackGrace: TimeInterval = 25

    public private(set) var watchDirectModeActive = false
    public private(set) var reconnectAfterWatchDirect = false
    public private(set) var fallbackArmed = false
    public private(set) var activatedAt: Date?
    public private(set) var lastWatchActivity: Date?
    public private(set) var lastChangeAt: Date?

    public init() {}

    /// - Parameters:
    ///   - phoneWantsStrap: whether the phone should take the strap back afterwards (it was
    ///     connected or paired). The phone always lets go on "start", connected or not, so a scan or
    ///     reconnect in flight can't grab the strap from the watch.
    ///   - strapAcceptsSecondConnection: the watch can connect without the phone letting go, so
    ///     "start" changes nothing on the phone.
    ///   - at: when the watch made the change, if the message carried it.
    public mutating func apply(watchDirectModeActive active: Bool,
                               phoneWantsStrap: Bool,
                               strapAcceptsSecondConnection: Bool = false,
                               at: Date? = nil,
                               now: Date = Date()) -> WatchDirectHandoffAction {
        if let at {
            if let last = lastChangeAt, at <= last { return .none }   // older or duplicate change
            lastChangeAt = at
        }
        if active {
            guard !strapAcceptsSecondConnection else { return .none }
            guard !watchDirectModeActive else {
                noteWatchActivity(at: at ?? now)
                return .none
            }
            watchDirectModeActive = true
            reconnectAfterWatchDirect = phoneWantsStrap
            fallbackArmed = false
            activatedAt = now
            lastWatchActivity = at ?? now
            return .disconnectPhone
        }
        guard watchDirectModeActive else { return .none }
        return end(reconnect: reconnectAfterWatchDirect)
    }

    /// Any sign of life from the watch while it holds the strap (heartbeat or "holding" message).
    /// The first one arms the phone's fallback.
    public mutating func watchHoldsStrap(at date: Date) -> WatchDirectHandoffAction {
        guard watchDirectModeActive else { return .none }
        // A queued notice or heartbeat from an earlier session must not arm this session's fallback
        // before the watch has actually connected.
        if let start = lastChangeAt, date <= start { return .none }
        noteWatchActivity(at: date)
        return armFallbackIfNeeded()
    }

    /// Arms the fallback once the grace period has passed even if the watch never reported holding
    /// the strap (first-time pairing, Bluetooth off on the watch, message lost).
    public mutating func armFallbackIfDue(now: Date = Date(),
                                          grace: TimeInterval = fallbackGrace) -> WatchDirectHandoffAction {
        guard watchDirectModeActive, let activatedAt, now.timeIntervalSince(activatedAt) >= grace else { return .none }
        return armFallbackIfNeeded()
    }

    /// The phone's pending connect completed: the watch let go, so its session is over. Returns true
    /// when this ended an active session, so the phone can tell the watch.
    @discardableResult
    public mutating func phoneReconnected() -> Bool {
        guard watchDirectModeActive, fallbackArmed else { return false }
        _ = end(reconnect: false)
        return true
    }

    public mutating func noteWatchActivity(at date: Date) {
        guard watchDirectModeActive else { return }
        lastWatchActivity = max(lastWatchActivity ?? date, date)
    }

    public mutating func expireIfWatchSilent(now: Date = Date(),
                                             timeout: TimeInterval = livenessTimeout) -> WatchDirectHandoffAction {
        guard watchDirectModeActive,
              let last = lastWatchActivity,
              now.timeIntervalSince(last) > timeout else { return .none }
        return end(reconnect: reconnectAfterWatchDirect)
    }

    private mutating func armFallbackIfNeeded() -> WatchDirectHandoffAction {
        guard reconnectAfterWatchDirect, !fallbackArmed else { return .none }
        fallbackArmed = true
        return .armPhoneFallback
    }

    private mutating func end(reconnect: Bool) -> WatchDirectHandoffAction {
        watchDirectModeActive = false
        reconnectAfterWatchDirect = false
        fallbackArmed = false
        activatedAt = nil
        lastWatchActivity = nil
        return reconnect ? .reconnectPhone : .none
    }
}
