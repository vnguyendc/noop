import Foundation
import WatchConnectivity
import WidgetKit

final class WatchSnapshotStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WatchSnapshot?
    private var directModeActive = false

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

    func setDirectModeActive(_ active: Bool) {
        directModeActive = active
        activateSession()

        let message = [WatchSnapshotTransport.watchDirectModeActiveKey: active]
        let session = WCSession.default
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(message)
        }
    }

    func applyDirectState(_ state: WatchDirectLiveState) {
        guard directModeActive, state.isActive else { return }
        let snapshot = WatchSnapshot(
            recovery: snapshot?.recovery,
            bpm: state.bpm ?? snapshot?.bpm,
            batteryPct: state.batteryPct ?? snapshot?.batteryPct,
            bonded: state.connected,
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

    private func apply(_ message: [String: Any]) {
        guard !directModeActive else { return }
        guard let snapshot = WatchSnapshotTransport.snapshot(from: message) else { return }
        snapshot.saveForWatch()
        DispatchQueue.main.async {
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
