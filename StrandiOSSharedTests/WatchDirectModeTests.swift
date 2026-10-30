import XCTest

final class WatchDirectModeTests: XCTestCase {
    func testStateReducerHandlesScanConnectSampleAndStop() {
        let device = WatchDirectDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "WHOOP",
            rssi: -42
        )
        var state = WatchDirectLiveState()

        state.startScan()
        state.upsertDiscoveredDevice(device)
        state.selectDevice(device)
        state.markConnected()
        state.receiveHeartRate(hr: 64, rr: [938])
        state.updateBattery(81)

        XCTAssertFalse(state.scanning)
        XCTAssertFalse(state.connecting)
        XCTAssertTrue(state.connected)
        XCTAssertEqual(state.selectedDevice, device)
        XCTAssertEqual(state.bpm, 64)
        XCTAssertEqual(state.rr, [938])
        XCTAssertEqual(state.batteryPct, 81)

        state.stop()

        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.discoveredDevices.isEmpty)
        XCTAssertNil(state.selectedDevice)
    }

    func testHandoffDisconnectsOnlyOnce() {
        var coordinator = WatchDirectHandoffCoordinator()

        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true), .disconnectPhone)
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true), .none)
    }

    func testPhoneAlwaysLetsGoButReconnectsOnlyIfItWantedTheStrap() {
        var wanted = WatchDirectHandoffCoordinator()
        XCTAssertEqual(wanted.apply(watchDirectModeActive: true, phoneWantsStrap: true), .disconnectPhone)
        XCTAssertEqual(wanted.apply(watchDirectModeActive: false, phoneWantsStrap: false), .reconnectPhone)

        // A phone that was mid-scan (not connected, not paired) still stops so it can't race the watch.
        var unwanted = WatchDirectHandoffCoordinator()
        XCTAssertEqual(unwanted.apply(watchDirectModeActive: true, phoneWantsStrap: false), .disconnectPhone)
        XCTAssertEqual(unwanted.apply(watchDirectModeActive: false, phoneWantsStrap: false), .none)
    }
}

final class WatchDirectLivenessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// WHOOP 5.0: the phone stays connected and the watch connects alongside it. Before the fix the
    /// phone let go, re-armed its pending connect, got straight back in while the watch was still
    /// connected, and told the watch it had taken the strap back, which ended the workout.
    func testStrapThatTakesTwoConnectionsIsNeverHandedOver() {
        var coordinator = WatchDirectHandoffCoordinator()
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true,
                                         strapAcceptsSecondConnection: true, at: t0, now: t0), .none)
        XCTAssertFalse(coordinator.watchDirectModeActive)

        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0.addingTimeInterval(2)), .none)
        XCTAssertEqual(coordinator.armFallbackIfDue(now: t0.addingTimeInterval(30)), .none)
        XCTAssertFalse(coordinator.phoneReconnected(), "the phone's own connection is not the watch letting go")
        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(60 * 60)), .none)
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: false, phoneWantsStrap: true,
                                         strapAcceptsSecondConnection: true,
                                         at: t0.addingTimeInterval(30 * 60), now: t0.addingTimeInterval(30 * 60)), .none)
    }

    /// The one-connection hand-off still reports a reclaim, so the watch can end its workout.
    func testOneConnectionStrapStillReportsReclaim() {
        var coordinator = WatchDirectHandoffCoordinator()
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, at: t0, now: t0), .disconnectPhone)
        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0.addingTimeInterval(2)), .armPhoneFallback)
        XCTAssertTrue(coordinator.phoneReconnected())
        XCTAssertFalse(coordinator.watchDirectModeActive)
    }

    func testSilentWatchHandsStrapBackToPhone() {
        var coordinator = WatchDirectHandoffCoordinator()
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, now: t0), .disconnectPhone)

        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(9 * 60)), .none)
        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(11 * 60)), .reconnectPhone)
        XCTAssertFalse(coordinator.watchDirectModeActive)
        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(60 * 60)), .none)
    }

    func testHeartbeatsKeepTheWatchSessionAlive() {
        var coordinator = WatchDirectHandoffCoordinator()
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, now: t0)
        coordinator.noteWatchActivity(at: t0.addingTimeInterval(8 * 60))
        // An out-of-order (older) heartbeat must not move the activity clock backwards.
        coordinator.noteWatchActivity(at: t0.addingTimeInterval(60))

        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(15 * 60)), .none)
        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(19 * 60)), .reconnectPhone)
    }

    func testActivityIsIgnoredWhenWatchIsNotInControl() {
        var coordinator = WatchDirectHandoffCoordinator()
        coordinator.noteWatchActivity(at: t0)
        XCTAssertNil(coordinator.lastWatchActivity)
        XCTAssertEqual(coordinator.expireIfWatchSilent(now: t0.addingTimeInterval(3600)), .none)
    }

    func testFallbackArmsOnceWhenWatchHoldsStrap() {
        var coordinator = WatchDirectHandoffCoordinator()
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, now: t0)

        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0.addingTimeInterval(5)), .armPhoneFallback)
        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0.addingTimeInterval(65)), .none)
        XCTAssertEqual(coordinator.armFallbackIfDue(now: t0.addingTimeInterval(120)), .none)
        XCTAssertEqual(coordinator.lastWatchActivity, t0.addingTimeInterval(65))
    }

    func testQueuedNoticeFromEarlierSessionDoesNotArmFallback() {
        var coordinator = WatchDirectHandoffCoordinator()
        let start = t0.addingTimeInterval(600)
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, at: start, now: start)

        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0.addingTimeInterval(30)), .none)   // old session
        XCTAssertFalse(coordinator.fallbackArmed)
        XCTAssertEqual(coordinator.watchHoldsStrap(at: start.addingTimeInterval(4)), .armPhoneFallback)
    }

    func testFallbackArmsAfterGraceWhenWatchNeverReports() {
        var coordinator = WatchDirectHandoffCoordinator()
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, now: t0)

        XCTAssertEqual(coordinator.armFallbackIfDue(now: t0.addingTimeInterval(10)), .none)
        XCTAssertEqual(coordinator.armFallbackIfDue(now: t0.addingTimeInterval(30)), .armPhoneFallback)
        XCTAssertTrue(coordinator.fallbackArmed)
    }

    func testNoFallbackWhenPhoneDidNotWantTheStrap() {
        var coordinator = WatchDirectHandoffCoordinator()
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: false, now: t0)

        XCTAssertEqual(coordinator.watchHoldsStrap(at: t0), .none)
        XCTAssertEqual(coordinator.armFallbackIfDue(now: t0.addingTimeInterval(60)), .none)
    }

    func testPhoneReconnectEndsSessionOnlyAfterFallbackArmed() {
        var coordinator = WatchDirectHandoffCoordinator()
        _ = coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, now: t0)

        XCTAssertFalse(coordinator.phoneReconnected())   // not armed yet: a stray connect event is ignored
        XCTAssertTrue(coordinator.watchDirectModeActive)

        _ = coordinator.watchHoldsStrap(at: t0.addingTimeInterval(3))
        XCTAssertTrue(coordinator.phoneReconnected())
        XCTAssertFalse(coordinator.watchDirectModeActive)
        XCTAssertFalse(coordinator.phoneReconnected())
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: false, phoneWantsStrap: true,
                                         at: t0.addingTimeInterval(90)), .none)
    }

    func testOutOfOrderChangesAreIgnored() {
        var coordinator = WatchDirectHandoffCoordinator()
        let start = t0, stop = t0.addingTimeInterval(120)

        // Stop arrives first (nothing to stop), then the older queued start must not take effect.
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: false, phoneWantsStrap: true, at: stop, now: stop), .none)
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, at: start, now: stop), .none)
        XCTAssertFalse(coordinator.watchDirectModeActive)

        // Duplicate deliveries of the same change (context + message) apply once.
        let next = t0.addingTimeInterval(300)
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, at: next, now: next), .disconnectPhone)
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: true, phoneWantsStrap: true, at: next, now: next), .none)
        // A late stop from the earlier session can't end the newer one.
        XCTAssertEqual(coordinator.apply(watchDirectModeActive: false, phoneWantsStrap: true, at: stop, now: next), .none)
        XCTAssertTrue(coordinator.watchDirectModeActive)
    }

    func testStaleStartMessageIsDroppedButStopIsAlwaysHonoured() {
        let now = t0.addingTimeInterval(20 * 60)
        let staleStart = WatchSnapshotTransport.directModeMessage(active: true, at: t0)
        let freshStart = WatchSnapshotTransport.directModeMessage(active: true, at: now.addingTimeInterval(-5))
        let staleStop = WatchSnapshotTransport.directModeMessage(active: false, at: t0)

        XCTAssertNil(WatchSnapshotTransport.directModeChange(from: staleStart, now: now))
        XCTAssertEqual(WatchSnapshotTransport.directModeChange(from: freshStart, now: now)?.active, true)
        XCTAssertEqual(WatchSnapshotTransport.directModeChange(from: staleStop, now: now)?.active, false)
        XCTAssertEqual(WatchSnapshotTransport.directModeChange(
            from: [WatchSnapshotTransport.watchDirectModeActiveKey: true], now: now)?.at, nil)
        XCTAssertNil(WatchSnapshotTransport.directModeChange(from: ["x": 1], now: now))
    }

    func testReconnectingKeepsLastReading() {
        var state = WatchDirectLiveState()
        state.receiveHeartRate(hr: 120, rr: [500])
        state.markReconnecting("Strap out of range. Reconnecting.")

        XCTAssertTrue(state.connecting)
        XCTAssertFalse(state.connected)
        XCTAssertEqual(state.bpm, 120)
        XCTAssertTrue(state.isActive)
    }
}
