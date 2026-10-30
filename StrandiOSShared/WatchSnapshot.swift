import Foundation

/// Tiny glance snapshot synchronized from iPhone to Apple Watch. The watch app and its complication
/// read only this value; BLE, SQLite, HealthKit, and scoring stay on iPhone.
public struct WatchSnapshot: Codable, Equatable {
    public var recovery: Int?
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
    }

    public static let staleAfter: TimeInterval = 15 * 60
    public static let watchSuiteName = AppGroupID.watch
    public static let storageKey = "noop.watch.snapshot"

    public static var placeholder: WatchSnapshot {
        WatchSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date())
    }

    public func isStale(now: Date = Date(), staleAfter: TimeInterval = WatchSnapshot.staleAfter) -> Bool {
        now.timeIntervalSince(updated) > staleAfter
    }

    public func updatedText(now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        if seconds < 60 { return "updated just now" }
        if seconds < 3600 { return "updated \(seconds / 60) min ago" }
        if seconds < 86_400 { return "updated \(seconds / 3600) h ago" }
        return "updated \(seconds / 86_400) d ago"
    }

    public static func loadForWatch() -> WatchSnapshot? {
        guard let data = watchDefaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return nil }
        return snapshot
    }

    public func saveForWatch() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        WatchSnapshot.watchDefaults.set(data, forKey: WatchSnapshot.storageKey)
    }

    private static var watchDefaults: UserDefaults {
        UserDefaults(suiteName: watchSuiteName) ?? .standard
    }
}

public enum WatchSnapshotTransport {
    public static let snapshotDataKey = "watchSnapshotData"
    public static let requestSnapshotKey = "requestSnapshot"
    public static let watchDirectModeActiveKey = "watchDirectModeActive"
    public static let watchDirectModeAtKey = "watchDirectModeAt"

    public struct DirectModeChange: Equatable {
        public let active: Bool
        /// When the watch made the change. Older messages without a timestamp decode as nil.
        public let at: Date?
    }

    /// Sent by the phone when its pending connect took the strap back during a watch session.
    public static let phoneReclaimedStrapAtKey = "phoneReclaimedStrapAt"

    /// Sent by the watch when it has connected to the strap.
    public static let watchHoldsStrapAtKey = "watchHoldsStrapAt"

    public static func holdsStrapMessage(at date: Date = Date()) -> [String: Any] {
        [watchHoldsStrapAtKey: date]
    }

    public static func directModeMessage(active: Bool, at date: Date = Date()) -> [String: Any] {
        [watchDirectModeActiveKey: active, watchDirectModeAtKey: date]
    }

    /// Decodes a direct-mode change. A stale "start" (queued delivery arriving after the liveness
    /// window) is dropped, so a late message can't knock the phone off the strap again.
    public static func directModeChange(from message: [String: Any],
                                        now: Date = Date(),
                                        staleAfter: TimeInterval = WatchDirectHandoffCoordinator.livenessTimeout) -> DirectModeChange? {
        guard let active = message[watchDirectModeActiveKey] as? Bool else { return nil }
        let at = message[watchDirectModeAtKey] as? Date
        if active, let at, now.timeIntervalSince(at) > staleAfter { return nil }
        return DirectModeChange(active: active, at: at)
    }

    public static func message(for snapshot: WatchSnapshot) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return [snapshotDataKey: data]
    }

    public static func snapshot(from message: [String: Any]) -> WatchSnapshot? {
        guard let data = message[snapshotDataKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
