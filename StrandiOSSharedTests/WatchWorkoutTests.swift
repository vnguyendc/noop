import XCTest

final class WatchWorkoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_781_000_000)

    func testEveryKindHasAPhoneSportAndOtherMapsToWorkout() {
        for kind in WatchWorkoutKind.allCases {
            XCTAssertFalse(kind.sport.isEmpty, "\(kind) has no sport")
            XCTAssertFalse(kind.systemImage.isEmpty, "\(kind) has no symbol")
        }
        XCTAssertEqual(WatchWorkoutKind.other.sport, "Workout")
        XCTAssertEqual(WatchWorkoutKind.other.name, "Other")
        XCTAssertEqual(WatchWorkoutKind.strength.sport, "Strength Training")
        XCTAssertEqual(WatchWorkoutKind.allCases.count, 8)
    }

    func testOrderedPutsLastUsedFirstWithoutDuplicates() {
        let ordered = WatchWorkoutKind.ordered(lastUsed: .cycling)

        XCTAssertEqual(ordered.first, .cycling)
        XCTAssertEqual(ordered.count, WatchWorkoutKind.allCases.count)
        XCTAssertEqual(Set(ordered), Set(WatchWorkoutKind.allCases))
        XCTAssertEqual(WatchWorkoutKind.ordered(lastUsed: nil), WatchWorkoutKind.allCases)
    }

    func testLastUsedPersistsThroughDefaults() {
        let suite = "WatchWorkoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(WatchWorkoutKind.loadLastUsed(from: defaults))
        WatchWorkoutKind.rowing.saveAsLastUsed(to: defaults)
        XCTAssertEqual(WatchWorkoutKind.loadLastUsed(from: defaults), .rowing)
    }

    func testRecordRoundTripsThroughUserInfo() throws {
        let record = WatchWorkoutRecord(sport: "Cycling", start: start, end: start.addingTimeInterval(1800))

        let info = try XCTUnwrap(WatchWorkoutTransport.userInfo(for: record))
        let decoded = try XCTUnwrap(WatchWorkoutTransport.record(from: info))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.startTs, 1_781_000_000)
        XCTAssertEqual(decoded.endTs, 1_781_001_800)
        XCTAssertNil(WatchWorkoutTransport.record(from: ["other": Data()]))
    }

    func testRecordValidity() {
        XCTAssertTrue(WatchWorkoutRecord(sport: "Yoga", start: start, end: start.addingTimeInterval(1)).isValid)
        XCTAssertFalse(WatchWorkoutRecord(sport: " ", start: start, end: start.addingTimeInterval(1)).isValid)
        XCTAssertFalse(WatchWorkoutRecord(sport: "Yoga", start: start, end: start).isValid)
    }

    /// Work handed in first finishes first even when it is slower (R8: samples before the record).
    func testOrderedInboxRunsWorkInArrivalOrder() async {
        let inbox = OrderedInbox()
        let log = Log()

        inbox.enqueue {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await log.append("samples")
        }
        inbox.enqueue { await log.append("record") }
        inbox.enqueue { await log.append("more samples") }
        await inbox.drain()

        let entries = await log.entries
        XCTAssertEqual(entries, ["samples", "record", "more samples"])
    }

    private actor Log {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }
}
