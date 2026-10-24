import Foundation
import WatchConnectivity
import WidgetKit

final class WatchSnapshotStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WatchSnapshot?
    private var directModeActive = false

    /// Readings taken while the watch holds the strap, waiting to be sent to the phone.
    /// Main-thread only (fed by the main-actor BLE client and flushed by a main-run-loop timer).
    private var sampleBuffer = WatchSampleBuffer()
    private var flushTimer: Timer?
    static let flushInterval: TimeInterval = 60
    /// Whether the watch is connected to the strap right now. Heartbeats are sent only then, so a
    /// watch stuck searching doesn't keep telling the phone everything is fine.
    var isHoldingStrap: () -> Bool = { false }
    /// Called on the main thread when the phone reports it took the strap back, with its timestamp.
    var onPhoneReclaimedStrap: ((Date) -> Void)?

    override init() {
        self.snapshot = WatchSnapshot.loadForWatch()
        super.init()
        activateSession()
    }

    func requestRefresh() {
        activateSession()
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            [WatchSnapshotTransport.requestSnapshotKey: true],
            replyHandler: { [weak self] reply in self?.apply(reply) },
            errorHandler: nil
        )
    }

    /// Tell the phone the watch has the strap, so it can arm its fallback reconnect right away.
    func notifyHoldingStrap() {
        activateSession()
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message = WatchSnapshotTransport.holdsStrapMessage()
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    func setDirectModeActive(_ active: Bool) {
        directModeActive = active
        activateSession()

        let message = WatchSnapshotTransport.directModeMessage(active: active)
        let session = WCSession.default
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(message)
        }
    }

    // MARK: - Samples for the phone

    func recordSample(hr: Int, rr: [Int], at date: Date) {
        sampleBuffer.append(hr: hr, rr: rr, at: date)
        if sampleBuffer.pending.count >= WatchSampleBuffer.defaultBatchSize {
            flushSamples(heartbeat: false)
        }
    }

    /// Start the once-a-minute flush. Each flush doubles as a heartbeat so the phone can tell the
    /// watch still holds the strap (see `WatchDirectHandoffCoordinator.livenessTimeout`).
    func startSampleFlushing() {
        flushTimer?.invalidate()
        let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flushSamples(heartbeat: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    /// Stop flushing and send whatever is left. Call before handing the strap back to the phone, so
    /// the samples are queued ahead of the "stopped" message.
    func stopSampleFlushing() {
        flushTimer?.invalidate()
        flushTimer = nil
        flushSamples(heartbeat: false)
    }

    private func flushSamples(heartbeat: Bool) {
        activateSession()
        let session = WCSession.default
        // transferUserInfo needs an activated session; keep the samples until it is.
        guard session.activationState == .activated else { return }
        let batches = sampleBuffer.drain(sentAt: Date(),
                                         directModeActive: directModeActive,
                                         heartbeatWhenEmpty: heartbeat && directModeActive && isHoldingStrap())
        for (index, batch) in batches.enumerated() {
            guard let info = WatchSampleTransport.userInfo(for: batch) else {
                sampleBuffer.restore(batches[index...].flatMap(\.samples))
                return
            }
            // Queued and delivered by the system even if the phone app isn't running right now.
            session.transferUserInfo(info)
        }
    }

    func applyDirectState(_ state: WatchDirectLiveState) {
        guard directModeActive, state.isActive else { return }
        let snapshot = WatchSnapshot(
            recovery: snapshot?.recovery,
            bpm: state.bpm ?? snapshot?.bpm,
            batteryPct: state.batteryPct ?? snapshot?.batteryPct,
            // `bonded` means "strap connected to the iPhone", which is false while the watch has it.
            bonded: false,
            updated: Date()
        )
        snapshot.saveForWatch()
        self.snapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
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

    /// WCSession delegate callbacks arrive on a background queue; `directModeActive` and the
    /// published snapshot are main-thread state.
    private func apply(_ message: [String: Any]) {
        if let at = message[WatchSnapshotTransport.phoneReclaimedStrapAtKey] as? Date {
            DispatchQueue.main.async { self.onPhoneReclaimedStrap?(at) }
            return
        }
        guard let snapshot = WatchSnapshotTransport.snapshot(from: message) else { return }
        DispatchQueue.main.async {
            guard !self.directModeActive else { return }
            snapshot.saveForWatch()
            self.snapshot = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        apply(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        apply(userInfo)
    }
}
