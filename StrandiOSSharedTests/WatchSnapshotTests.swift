import XCTest

final class WatchSnapshotTests: XCTestCase {
    private let updated = Date(timeIntervalSince1970: 1_781_000_000)

    func testEncodeDecodePreservesGlanceFields() throws {
        let snapshot = WatchSnapshot(
            recovery: 76,
            bpm: 61,
            batteryPct: 88,
            bonded: true,
            updated: updated
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    func testFreshnessUsesFifteenMinuteStaleThreshold() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertFalse(snapshot.isStale(now: updated.addingTimeInterval(14 * 60)))
        XCTAssertTrue(snapshot.isStale(now: updated.addingTimeInterval(16 * 60)))
    }

    func testUpdatedTextBucketsElapsedTime() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(30)), "updated just now")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(5 * 60)), "updated 5 min ago")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(2 * 3600)), "updated 2 h ago")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(3 * 86_400)), "updated 3 d ago")
    }

    func testUpdatedTextClampsFutureDates() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(-60)), "updated just now")
    }
}
