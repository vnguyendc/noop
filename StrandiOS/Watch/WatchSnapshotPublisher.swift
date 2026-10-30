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
    /// Sample batches and workout records in the order the watch queued them, so a record is scored
    /// only after the samples sent ahead of it are stored.
    private let inbox = OrderedInbox()

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

        #if DEBUG
        // Simulators don't deliver `transferUserInfo` between a paired phone and watch, so
        // `-NOOPSimulateWatchWorkout YES` feeds a two-minute Rowing workout (samples first, then the
        // record, as the watch queues them) through the same receive path a real transfer takes.
        if UserDefaults.standard.bool(forKey: "NOOPSimulateWatchWorkout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.simulateWatchWorkout()
            }
        }
        #endif
    }

    #if DEBUG
    private func simulateWatchWorkout() {
        let end = Date()
        let start = end.addingTimeInterval(-120)
        let samples = (0..<120).map { i in
            WatchHRSample(ts: Int(start.timeIntervalSince1970) + i, bpm: 120 + (i * 7) % 31, rr: [])
        }
        let batch = WatchSampleBatch(sentAt: end, directModeActive: false, samples: samples)
        let record = WatchWorkoutRecord(sport: WatchWorkoutKind.rowing.sport, start: start, end: end)
        guard let batchInfo = WatchSampleTransport.userInfo(for: batch),
              let recordInfo = WatchWorkoutTransport.userInfo(for: record) else { return }
        session(WCSession.default, didReceiveUserInfo: batchInfo)
        session(WCSession.default, didReceiveUserInfo: recordInfo)
        // Delivered twice: must update the same entry, not add a second one.
        session(WCSession.default, didReceiveUserInfo: recordInfo)
    }
    #endif

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
            NSLog("NOOP: watch sent %d samples", batch.samples.count)
            handleSampleBatch(batch)
            return
        }
        if let record = WatchWorkoutTransport.record(from: userInfo) {
            NSLog("NOOP: watch sent workout record %@ %@", record.sport, record.id.uuidString)
            inbox.enqueue { await self.saveWatchWorkout(record) }
            return
        }
        handleWatchDirectModeMessage(userInfo)
    }

    /// Score a workout the watch tracked from the samples it already sent, and save it under the
    /// chosen sport like a workout started on the phone. The row's key is (device, start, sport), so
    /// a record delivered twice updates the same entry; too few samples saves nothing, as on the phone.
    @MainActor
    private func saveWatchWorkout(_ record: WatchWorkoutRecord) async {
        guard record.isValid else {
            NSLog("NOOP: ignored invalid watch workout record %@", record.id.uuidString)
            return
        }
        guard let model else { return }
        guard let store = await model.repo.storeHandle() else {
            NSLog("NOOP: store not ready; dropped watch workout %@", record.sport)
            return
        }
        let samples: [HRSample]
        do {
            samples = try await store.hrSamples(deviceId: model.deviceId, from: record.startTs, to: record.endTs,
                                                limit: Self.maxWorkoutSamples)
        } catch {
            NSLog("NOOP: couldn't read samples for watch workout %@: %@", record.sport, error.localizedDescription)
            return
        }
        guard let row = WorkoutScoring.row(samples: samples, start: record.start, end: record.end,
                                           sport: record.sport, profile: ScoringProfile(model.profile)) else {
            NSLog("NOOP: watch workout %@ had %d samples; not saved", record.sport, samples.count)
            return
        }
        do {
            _ = try await store.upsertWorkouts([row], deviceId: model.deviceId)
            NSLog("NOOP: saved watch workout %@ from %d samples", record.sport, samples.count)
            await model.repo.refresh()
        } catch {
            NSLog("NOOP: failed to save watch workout %@: %@", record.sport, error.localizedDescription)
        }
    }

    /// One sample per second for 12 hours; longer spans are truncated rather than unbounded.
    private static let maxWorkoutSamples = 12 * 3600

    /// Store readings the watch took while it held the strap, under the strap's own device id so
    /// they merge into the same history. Inserts are idempotent (one row per second), so a batch
    /// delivered twice changes nothing.
    private func handleSampleBatch(_ batch: WatchSampleBatch) {
        inbox.enqueue { @MainActor in
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
                strapAcceptsSecondConnection: WhoopModel.persisted.acceptsSecondConnection,
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
        let values = WatchScoreValues(days: model.repo.days)
        return WatchSnapshot(
            recovery: values.charge,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            effort: values.effort,
            rest: values.rest,
            hrvMs: values.hrvMs,
            restingHr: values.restingHr,
            sleepMin: values.sleepMin
        )
    }
}
#endif
