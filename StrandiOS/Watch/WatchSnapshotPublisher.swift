#if os(iOS)
import Combine
import Foundation
import WatchConnectivity
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

        publish(from: model)
    }

    @MainActor
    func publish(from model: AppModel) {
        publish(WatchSnapshot.make(from: model))
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
        handleWatchDirectModeMessage(userInfo)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
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

    @discardableResult
    private func handleWatchDirectModeMessage(_ message: [String: Any]) -> Bool {
        guard let active = message[WatchSnapshotTransport.watchDirectModeActiveKey] as? Bool else { return false }

        Task { @MainActor in
            guard let model = self.model else { return }
            switch self.watchDirectHandoff.apply(
                watchDirectModeActive: active,
                phoneWasConnected: model.live.connected
            ) {
            case .none:
                break
            case .disconnectPhone:
                model.disconnect()
            case .reconnectPhone:
                model.scan()
            }
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
