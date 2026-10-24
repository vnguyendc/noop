#if os(iOS)
import Combine
import Foundation
import UIKit
import WatchConnectivity
import WhoopProtocol
import WhoopStore
import WidgetKit

final class WatchSnapshotPublisher: NSObject, WCSessionDelegate {
    static let shared = WatchSnapshotPublisher()

    private weak var model: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var watchDirectHandoff = WatchDirectHandoffCoordinator()

    @MainActor
    func start(model: AppModel) {
        self.model = model
        activateSession()

        Publishers.MergeMany([
            model.$bpm.map { _ in () }.eraseToAnyPublisher(),
            model.live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
            model.live.$batteryPct.map { _ in () }.eraseToAnyPublisher(),
            model.live.$bonded.map { _ in () }.eraseToAnyPublisher(),
            model.repo.$days.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
        .sink { [weak self, weak model] in
            guard let self, let model else { return }
            self.publish(from: model)
        }
        .store(in: &cancellables)

        // The phone's pending connect completed while the watch had the strap: the watch let go.
        model.live.$connected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.watchDirectHandoff.phoneReconnected() else { return }
                    self.notifyWatchPhoneReclaimedStrap()
                }
            }
            .store(in: &cancellables)

        // Backstop for when the app is awake. The armed pending connect is what recovers the strap
        // while the app is suspended.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.checkWatchLiveness() }
            }
            .store(in: &cancellables)

        publish(from: model)
    }

    @MainActor
    func publish(from model: AppModel) {
        checkWatchLiveness()
        publish(WatchSnapshot.make(from: model))
    }

    /// If the watch took the strap and then went quiet (app killed, battery dead), take it back.
    @MainActor
    private func checkWatchLiveness() {
        perform(watchDirectHandoff.expireIfWatchSilent(now: Date()))
    }

    @MainActor
    private func perform(_ action: WatchDirectHandoffAction) {
        guard let model else { return }
        switch action {
        case .none:
            break
        case .disconnectPhone:
            model.disconnect()
            scheduleFallbackGraceCheck()
        case .armPhoneFallback, .reconnectPhone:
            // Pending connect to the known strap: immediate if it's free, otherwise completes the
            // moment the watch lets go, even with the app suspended.
            model.awaitStrapReturn()
        }
    }

    /// If the watch never reports holding the strap, arm the phone's fallback after the grace period.
    /// A background task keeps the app awake that long after the watch's message woke it; if iOS
    /// grants less time, the check runs early (shorter grace) rather than never.
    @MainActor
    private func scheduleFallbackGraceCheck() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "NOOP watch handoff") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining   // huge while in the foreground
        let grace = max(1, min(WatchDirectHandoffCoordinator.fallbackGrace, remaining - 4))
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                if let self { self.perform(self.watchDirectHandoff.armFallbackIfDue(now: Date(), grace: grace)) }
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// The phone's pending connect won the strap back mid-session (the watch dropped it briefly, or
    /// went away). Tell the watch so it ends its workout with a reason instead of retrying for minutes.
    @MainActor
    private func notifyWatchPhoneReclaimedStrap() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message: [String: Any] = [WatchSnapshotTransport.phoneReclaimedStrapAtKey: Date()]
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }

    private func publish(_ snapshot: WatchSnapshot) {
        guard WCSession.isSupported(),
              let message = WatchSnapshotTransport.message(for: snapshot) else { return }

        let session = WCSession.default
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleWatchDirectModeMessage(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let batch = WatchSampleTransport.batch(from: userInfo) {
            handleSampleBatch(batch)
            return
        }
        handleWatchDirectModeMessage(userInfo)
    }

    /// Store readings the watch took while it held the strap, under the strap's own device id so
    /// they merge into the same history. Inserts are idempotent (one row per second), so a batch
    /// delivered twice changes nothing.
    private func handleSampleBatch(_ batch: WatchSampleBatch) {
        Task { @MainActor in
            // The watch only sends while it is connected to the strap, so a batch is proof it holds it.
            if batch.directModeActive {
                self.perform(self.watchDirectHandoff.watchHoldsStrap(at: batch.sentAt))
            }
            let rows = batch.storableRows()
            guard !rows.hr.isEmpty || !rows.rr.isEmpty, let model = self.model else { return }
            guard let store = await model.repo.storeHandle() else {
                NSLog("NOOP: store not ready; dropped %d watch samples", batch.samples.count)
                return
            }
            let streams = Streams(hr: rows.hr.map { HRSample(ts: $0.ts, bpm: $0.value) },
                                  rr: rows.rr.map { RRInterval(ts: $0.ts, rrMs: $0.value) })
            do {
                try await store.insert(streams, deviceId: model.deviceId)
            } catch {
                // The batch is gone from the watch; the phone log is the only trace of the loss.
                NSLog("NOOP: failed to store %d watch samples: %@", batch.samples.count, error.localizedDescription)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Messages the watch sends without a reply handler (direct-mode changes, "holds strap"). This
    /// is the path that wakes the phone app immediately; without it only the slower application
    /// context / queued userInfo copies would arrive.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchDirectModeMessage(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if handleWatchDirectModeMessage(message) {
            replyHandler([:])
            return
        }

        guard message[WatchSnapshotTransport.requestSnapshotKey] as? Bool == true else {
            replyHandler([:])
            return
        }

        Task { @MainActor in
            guard let model = self.model,
                  let reply = WatchSnapshotTransport.message(for: WatchSnapshot.make(from: model)) else {
                replyHandler([:])
                return
            }
            replyHandler(reply)
        }
    }

    /// Returns true when the message was a direct-mode change or a "holds strap" notice (even a
    /// stale change that is ignored).
    @discardableResult
    private func handleWatchDirectModeMessage(_ message: [String: Any]) -> Bool {
        if let heldAt = message[WatchSnapshotTransport.watchHoldsStrapAtKey] as? Date {
            Task { @MainActor in self.perform(self.watchDirectHandoff.watchHoldsStrap(at: heldAt)) }
            return true
        }
        guard message[WatchSnapshotTransport.watchDirectModeActiveKey] is Bool else { return false }
        guard let change = WatchSnapshotTransport.directModeChange(from: message) else { return true }

        Task { @MainActor in
            // Before start(model:) there is nothing to hand over; don't record a change we can't act on.
            guard self.model != nil else { return }
            self.perform(self.watchDirectHandoff.apply(
                watchDirectModeActive: change.active,
                // The phone is NOOP's 24/7 collector, so it always takes the strap back afterwards.
                // (Connection state can't decide this: a freshly relaunched phone reads as
                // not-connected and not-bonded even when it normally holds the strap.)
                phoneWantsStrap: true,
                at: change.at,
                now: Date()
            ))
        }
        return true
    }
}

extension WatchSnapshot {
    @MainActor
    static func make(from model: AppModel) -> WatchSnapshot {
        let recovery = model.repo.days.last(where: { $0.recovery != nil })?.recovery
        return WatchSnapshot(
            recovery: recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date()
        )
    }
}
#endif
