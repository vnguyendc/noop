import XCTest

final class AppleHealthConnectionTests: XCTestCase {
    func testNoHealthOnTheDevice() {
        XCTAssertEqual(AppleHealthConnection(healthAvailable: false, alreadyAsked: true, canSaveAny: true), .unavailable)
    }

    func testNeverAskedIsNotConnected() {
        let connection = AppleHealthConnection(healthAvailable: true, alreadyAsked: false, canSaveAny: false)
        XCTAssertEqual(connection, .notConnected)
        XCTAssertFalse(connection.isConnected)
    }

    /// After a relaunch the permission is read back from HealthKit, so syncing carries on.
    func testGrantedEarlierIsConnected() {
        let connection = AppleHealthConnection(healthAvailable: true, alreadyAsked: true, canSaveAny: true)
        XCTAssertEqual(connection, .connected(canSave: true))
        XCTAssertTrue(connection.isConnected)
    }

    func testAskedButSavingDeniedStillConnectedForReading() {
        XCTAssertEqual(AppleHealthConnection(healthAvailable: true, alreadyAsked: true, canSaveAny: false),
                       .connected(canSave: false))
    }

    /// An update that adds a type makes HealthKit want to ask again; the earlier grant still counts.
    func testNewTypeToAskForDoesNotDisconnect() {
        XCTAssertEqual(AppleHealthConnection(healthAvailable: true, alreadyAsked: false, canSaveAny: true),
                       .connected(canSave: true))
    }
}
