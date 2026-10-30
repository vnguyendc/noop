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

    func testNewScoreFieldsRoundTrip() throws {
        let snapshot = WatchSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                                     effort: 48, rest: 85, hrvMs: 64, restingHr: 52, sleepMin: 432)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.sleepText, "7h 12m")
    }

    /// A snapshot written by a phone build that predates the score fields (R4).
    func testOldPhoneSnapshotDecodesWithNewFieldsNil() throws {
        let old = """
        {"recovery":76,"bpm":61,"batteryPct":88,"bonded":true,"updated":1781000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(WatchSnapshot.self, from: Data(old.utf8))

        XCTAssertEqual(decoded.recovery, 76)
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.rest)
        XCTAssertNil(decoded.hrvMs)
        XCTAssertNil(decoded.restingHr)
        XCTAssertNil(decoded.sleepMin)
        XCTAssertNil(decoded.sleepText)
    }

    /// A new snapshot still carries everything an old watch build reads (R4).
    func testNewSnapshotKeepsOldKeys() throws {
        let snapshot = WatchSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                                     effort: 48, rest: 85, hrvMs: 64, restingHr: 52, sleepMin: 432)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])

        XCTAssertEqual(json["recovery"] as? Int, 72)
        XCTAssertEqual(json["bpm"] as? Int, 58)
        XCTAssertEqual(json["batteryPct"] as? Int, 84)
        XCTAssertEqual(json["bonded"] as? Bool, true)
        XCTAssertNotNil(json["updated"])
    }

    func testFreshnessUsesFifteenMinuteStaleThreshold() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertFalse(snapshot.isStale(now: updated.addingTimeInterval(14 * 60)))
        XCTAssertTrue(snapshot.isStale(now: updated.addingTimeInterval(16 * 60)))
    }

    func testUpdatedTextBucketsElapsedTime() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(30)), "Synced just now")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(5 * 60)), "Synced 5 min ago")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(2 * 3600)), "Synced 2 h ago")
        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(3 * 86_400)), "Synced 3 d ago")
    }

    func testUpdatedTextClampsFutureDates() {
        let snapshot = WatchSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: updated)

        XCTAssertEqual(snapshot.updatedText(now: updated.addingTimeInterval(-60)), "Synced just now")
    }
}
