import Foundation

/// Whether NOOP is connected to Apple Health, from the two things HealthKit will say: whether NOOP
/// has already asked for access, and whether it may save each type. HealthKit never reveals whether
/// read access was granted. It does remember the answer across launches, so this is recomputed at
/// launch instead of being stored.
public enum AppleHealthConnection: Equatable {
    /// No Apple Health on this device.
    case unavailable
    /// NOOP hasn't asked yet.
    case notConnected
    /// NOOP has asked. `canSave` is false when every write type is denied, so nothing reaches Health.
    case connected(canSave: Bool)

    public init(healthAvailable: Bool, alreadyAsked: Bool, canSaveAny: Bool) {
        if !healthAvailable {
            self = .unavailable
        } else if canSaveAny {
            // Also covers an update that added a type: HealthKit wants to ask again, but the types
            // granted earlier still save.
            self = .connected(canSave: true)
        } else if alreadyAsked {
            self = .connected(canSave: false)
        } else {
            self = .notConnected
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
