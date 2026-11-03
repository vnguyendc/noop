import Foundation

/// A workout type the user can pick on the watch. The phone stores the `sport` string, so adding
/// a kind here never needs a phone change; an old phone just sees a new sport name.
public enum WatchWorkoutKind: String, CaseIterable, Codable, Equatable {
    case strength
    case running
    case walking
    case cycling
    case hiit
    case rowing
    case yoga
    case other

    /// Name shown on the watch and stored on the phone (matches the phone's Workouts list labels).
    /// "Other" becomes "Workout", the sport the phone's own untyped workouts use.
    public var sport: String {
        switch self {
        case .strength: return "Strength Training"
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiit: return "HIIT"
        case .rowing: return "Rowing"
        case .yoga: return "Yoga"
        case .other: return "Workout"
        }
    }

    public var name: String {
        self == .other ? "Other" : sport
    }

    public var systemImage: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .hiit: return "figure.highintensity.intervaltraining"
        case .rowing: return "figure.rower"
        case .yoga: return "figure.yoga"
        case .other: return "figure.mixed.cardio"
        }
    }

    public static let lastUsedKey = "noop.watch.lastWorkoutKind"

    /// The pick list: the last-used kind first, then the default order.
    public static func ordered(lastUsed: WatchWorkoutKind?) -> [WatchWorkoutKind] {
        guard let lastUsed else { return allCases }
        return [lastUsed] + allCases.filter { $0 != lastUsed }
    }

    public static func loadLastUsed(from defaults: UserDefaults = .standard) -> WatchWorkoutKind? {
        defaults.string(forKey: lastUsedKey).flatMap(WatchWorkoutKind.init(rawValue:))
    }

    public func saveAsLastUsed(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.lastUsedKey)
    }
}

/// What the watch tells the phone when a workout ends. The phone already has the heart-rate samples
/// (sent in batches during the workout); this adds the type and the span so the phone can score and
/// save a typed entry. `id` lets the phone tell a re-delivered record from a new one.
public struct WatchWorkoutRecord: Codable, Equatable {
    public let id: UUID
    public let sport: String
    public let start: Date
    public let end: Date

    public init(id: UUID = UUID(), sport: String, start: Date, end: Date) {
        self.id = id
        self.sport = sport
        self.start = start
        self.end = end
    }

    public var startTs: Int { Int(start.timeIntervalSince1970) }
    public var endTs: Int { Int(end.timeIntervalSince1970) }

    /// False for a record that could never describe a workout (empty sport, end before start).
    public var isValid: Bool {
        !sport.trimmingCharacters(in: .whitespaces).isEmpty && end > start
    }
}

public enum WatchWorkoutTransport {
    public static let recordKey = "watchWorkoutRecord"

    public static func userInfo(for record: WatchWorkoutRecord) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return [recordKey: data]
    }

    public static func record(from userInfo: [String: Any]) -> WatchWorkoutRecord? {
        guard let data = userInfo[recordKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchWorkoutRecord.self, from: data)
    }
}

/// Runs pieces of work one after another in the order they were handed in, even when each piece
/// awaits. The phone feeds every watch message through one of these so a workout record is never
/// scored before the sample batches sent ahead of it are stored.
public final class OrderedInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    public init() {}

    public func enqueue(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for everything enqueued so far. For tests.
    public func drain() async {
        await currentTail()?.value
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}
