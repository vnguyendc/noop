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

        XCTAssertEqual(
            coordinator.apply(watchDirectModeActive: true, phoneWasConnected: true),
            .disconnectPhone
        )
        XCTAssertEqual(
            coordinator.apply(watchDirectModeActive: true, phoneWasConnected: true),
            .none
        )
    }

    func testHandoffReconnectsOnlyWhenPhoneWasConnectedBeforeTakeover() {
        var connectedCoordinator = WatchDirectHandoffCoordinator()
        _ = connectedCoordinator.apply(watchDirectModeActive: true, phoneWasConnected: true)
        XCTAssertEqual(
            connectedCoordinator.apply(watchDirectModeActive: false, phoneWasConnected: false),
            .reconnectPhone
        )

        var disconnectedCoordinator = WatchDirectHandoffCoordinator()
        _ = disconnectedCoordinator.apply(watchDirectModeActive: true, phoneWasConnected: false)
        XCTAssertEqual(
            disconnectedCoordinator.apply(watchDirectModeActive: false, phoneWasConnected: false),
            .none
        )
    }
}
