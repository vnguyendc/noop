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
    public static let watchSuiteName = "group.com.noopapp.noop.watch"
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

    public static func message(for snapshot: WatchSnapshot) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return [snapshotDataKey: data]
    }

    public static func snapshot(from message: [String: Any]) -> WatchSnapshot? {
        guard let data = message[snapshotDataKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
