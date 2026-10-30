import Combine
import HealthKit
import SwiftUI
import WatchKit

@main
struct NOOPWatchApp: App {
    @WKApplicationDelegateAdaptor(NOOPWatchAppDelegate.self) private var appDelegate
    @StateObject private var live = WatchLiveModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchGlanceView(live: live, store: live.store, directClient: live.client, workout: live.workout)
                .tint(.noopAccent)
                .onChange(of: scenePhase) { _, phase in
                    // Without a workout session watchOS suspends the app once it leaves the screen,
                    // which drops the strap anyway, so hand it back to the phone. With a workout
                    // running, keep reading in the background.
                    guard phase == .background, live.isLive, !live.workout.isActive else { return }
                    live.stop()
                }
        }
    }
}

/// Owns the watch's live pieces and the order they start and stop in.
@MainActor
final class WatchLiveModel: ObservableObject {
    let store = WatchSnapshotStore()
    let client = WatchDirectBLEClient()
    let workout = WatchWorkoutController()

    /// True from "Start workout" until "End workout". The screen follows this, not the Bluetooth
    /// state, so a failed scan or a dropped strap still shows the live screen and its End button
    /// (otherwise the phone would stay disconnected with no way to hand the strap back).
    @Published private(set) var isLive = false
    /// Why the last workout ended when the user didn't end it, shown on the glance.
    @Published private(set) var endReason: String?

    /// Give the strap back to the phone if the watch hasn't held it for this long (still searching,
    /// Bluetooth off, strap out of range), so neither device sits idle for a whole workout.
    static let noStrapTimeout: TimeInterval = 3 * 60

    private var lastHeldStrapAt = Date()
    private var liveStartedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Timer?

    init() {
        client.onHeartRate = { [weak store] hr, rr, at in
            store?.recordSample(hr: hr, rr: rr, at: at)
        }
        store.isHoldingStrap = { [weak client] in client?.state.connected ?? false }
        workout.onEndedBySystem = { [weak self] in
            self?.stop(reason: "watchOS ended the workout. Your iPhone has the strap again.")
        }
        store.onPhoneReclaimedStrap = { [weak self] at in
            guard let self, self.isLive, at > self.liveStartedAt else { return }   // ignore older sessions
            // Still connected: the strap took the phone as a second connection without dropping the
            // watch, so the phone didn't take anything back.
            guard !self.client.state.connected else { return }
            self.stop(reason: "Your iPhone took the strap back after the watch lost it.")
        }
        client.$state
            .map(\.connected)
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self, self.isLive, connected else { return }
                self.lastHeldStrapAt = Date()
                self.store.notifyHoldingStrap()
            }
            .store(in: &cancellables)
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStrapHeld() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkStrapHeld() {
        guard isLive else { return }
        if client.state.connected {
            lastHeldStrapAt = Date()
        } else if Date().timeIntervalSince(lastHeldStrapAt) > Self.noStrapTimeout {
            stop(reason: "The watch couldn't reach your strap for 3 minutes, so your iPhone has it again.")
        }
    }

    /// Take the strap from the phone and keep reading it inside a workout session.
    /// `useWorkoutSession: false` exists only for simulator screenshots (no Health prompt).
    func start(useWorkoutSession: Bool = true) {
        guard !isLive else { return }
        isLive = true
        endReason = nil
        liveStartedAt = Date()
        lastHeldStrapAt = Date()
        startWatchdog()
        store.setDirectModeActive(true)   // phone lets go of the strap
        store.startSampleFlushing()
        client.startScan()
        client.keepConnected = true
        if useWorkoutSession { Task { await workout.start() } }
    }

    /// Retry finding the strap after a failed scan or connection, without ending the workout.
    func rescan() {
        guard isLive else { return }
        client.startScan()
        client.keepConnected = true
    }

    /// End the workout, send the remaining samples, then give the strap back to the phone.
    /// `reason` is shown on the glance when the user didn't end it themselves.
    func stop(reason: String? = nil) {
        guard isLive else { return }
        isLive = false
        endReason = reason
        watchdog?.invalidate()
        watchdog = nil
        workout.end()
        client.stop()
        store.stopSampleFlushing()
        store.setDirectModeActive(false)
        store.requestRefresh()
    }
}

/// If watchOS relaunches the app while a workout session it started is still running (crash, memory
/// pressure), the new process has no strap connection to go with it. End the orphaned session so it
/// doesn't block the next one; the phone's pending connect has already taken the strap back.
final class NOOPWatchAppDelegate: NSObject, WKApplicationDelegate {
    private let healthStore = HKHealthStore()

    func handleActiveWorkoutRecovery() {
        healthStore.recoverActiveWorkoutSession { session, _ in
            session?.end()
        }
    }
}

extension Color {
    /// NOOP's brand green (#18C98B), the app's single accent.
    static let noopAccent = Color(red: 24 / 255, green: 201 / 255, blue: 139 / 255)
}
