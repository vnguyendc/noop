import Foundation
import HealthKit

/// Runs an `HKWorkoutSession` while the watch holds the strap.
///
/// watchOS suspends a third-party app soon after the wrist goes down, which also stops its Core
/// Bluetooth callbacks. A running workout session is the supported way to keep the app (and its
/// Bluetooth link) alive in the background. NOOP uses the session only for that: it attaches no
/// workout builder and saves nothing to Apple Health.
@MainActor
final class WatchWorkoutController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running(since: Date)
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Called when watchOS ends the session without the user asking (for example after an error),
    /// so the app can release the strap back to the phone.
    var onEndedBySystem: (() -> Void)?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var userRequestedEnd = false

    var isActive: Bool {
        switch phase {
        case .starting, .running: return true
        case .idle, .unavailable: return false
        }
    }

    var startedAt: Date? {
        if case .running(let since) = phase { return since }
        return nil
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = phase { return reason }
        return nil
    }

    /// Start a session of the chosen kind. The kind only sets the session's activity type (what
    /// watchOS shows while it runs); NOOP's own record of the workout is kept on the phone.
    func start(kind: WatchWorkoutKind = .other) async {
        guard session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .unavailable("Apple Health isn't available on this watch.")
            return
        }
        phase = .starting
        userRequestedEnd = false
        do {
            try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
            // The user may have ended live mode while the permission sheet was up.
            guard !userRequestedEnd else {
                phase = .idle
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = kind.activityType
            configuration.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            self.session = session
            session.startActivity(with: Date())
        } catch {
            session = nil
            phase = .unavailable(Self.message(for: error))
        }
    }

    func end() {
        userRequestedEnd = true
        guard let session else {
            // Nothing running. Keep an .unavailable reason visible; only clear a pending start.
            if phase == .starting { phase = .idle }
            return
        }
        // Detach now so an immediate restart isn't blocked waiting for the .ended callback (which
        // is ignored once the session is detached).
        self.session = nil
        phase = .idle
        session.end()
    }

    private func finish(endedBySystem: Bool) {
        session = nil
        if case .unavailable = phase {} else { phase = .idle }
        if endedBySystem { onEndedBySystem?() }
    }

    private static func message(for error: Error) -> String {
        if let hkError = error as? HKError, hkError.code == .errorAuthorizationDenied {
            return "Allow NOOP to use workouts in the Health settings on your iPhone."
        }
        return "Workout mode needs a build signed with HealthKit. \(error.localizedDescription)"
    }
}

extension WatchWorkoutController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            switch toState {
            case .running:
                self.phase = .running(since: self.startedAt ?? date)
            case .ended, .stopped:
                guard workoutSession === self.session else { return }
                if toState == .stopped { workoutSession.end() }
                if toState == .ended { self.finish(endedBySystem: !self.userRequestedEnd) }
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard workoutSession === self.session else { return }
            self.phase = .unavailable(Self.message(for: error))
            self.finish(endedBySystem: true)
        }
    }
}

extension WatchWorkoutKind {
    var activityType: HKWorkoutActivityType {
        switch self {
        case .strength: return .traditionalStrengthTraining
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .hiit: return .highIntensityIntervalTraining
        case .rowing: return .rowing
        case .yoga: return .yoga
        case .other: return .other
        }
    }
}
