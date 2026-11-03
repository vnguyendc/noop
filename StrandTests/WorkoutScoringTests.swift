import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

final class WorkoutScoringTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_781_000_000)
    private let profile = ScoringProfile(hrMax: 185, sex: "male", weightKg: 75, heightCm: 178, age: 35)

    private func samples(_ bpms: [Int]) -> [HRSample] {
        bpms.enumerated().map { HRSample(ts: Int(start.timeIntervalSince1970) + $0.offset, bpm: $0.element) }
    }

    func testScoresAvgMaxStrainAndCaloriesUnderTheGivenSport() throws {
        let end = start.addingTimeInterval(600)
        let hr = samples(Array(repeating: 140, count: 300) + Array(repeating: 160, count: 300))

        let row = try XCTUnwrap(WorkoutScoring.row(samples: hr, start: start, end: end, sport: "Cycling",
                                                   profile: profile))

        XCTAssertEqual(row.sport, "Cycling")
        XCTAssertEqual(row.source, "manual")
        XCTAssertEqual(row.startTs, 1_781_000_000)
        XCTAssertEqual(row.endTs, 1_781_000_600)
        XCTAssertEqual(row.durationS, 600)
        XCTAssertEqual(row.avgHr, 150)
        XCTAssertEqual(row.maxHr, 160)
        XCTAssertNotNil(row.strain)
        XCTAssertGreaterThan(row.energyKcal ?? 0, 0)
    }

    func testFewerThanTwoSamplesSavesNothing() {
        XCTAssertNil(WorkoutScoring.row(samples: [], start: start, end: start.addingTimeInterval(60),
                                        sport: "Yoga", profile: profile))
        XCTAssertNil(WorkoutScoring.row(samples: samples([120]), start: start, end: start.addingTimeInterval(60),
                                        sport: "Yoga", profile: profile))
    }

    func testWatchValuesTakeTheLatestDayThatHasEachValue() {
        let days = [
            day("2026-10-27", sleep: 400, eff: 0.9, deep: 80, rem: 90, rhr: 55, hrv: 60, recovery: 61.4, strain: 10.2),
            day("2026-10-28", sleep: 432, eff: 0.92, deep: 90, rem: 100, rhr: 52, hrv: 64.4, recovery: 72.5, strain: nil),
            day("2026-10-29", sleep: nil, eff: nil, deep: nil, rem: nil, rhr: nil, hrv: nil, recovery: nil, strain: 47.6)
        ]

        let values = WatchScoreValues(days: days)

        XCTAssertEqual(values.charge, 73)
        XCTAssertEqual(values.effort, 48)
        XCTAssertEqual(values.hrvMs, 64)
        XCTAssertEqual(values.restingHr, 52)
        XCTAssertEqual(values.sleepMin, 432)
        // Rest comes from the last day with sleep data (the 28th), through the app's Rest composite.
        XCTAssertEqual(values.rest, WatchScoreValues(days: [days[1]]).rest)
        XCTAssertTrue((1...100).contains(values.rest ?? -1))
    }

    func testWatchValuesAreNilWithoutData() {
        XCTAssertEqual(WatchScoreValues(days: []), WatchScoreValues())
        let noSleep = [day("2026-10-29", sleep: nil, eff: nil, deep: nil, rem: nil, rhr: nil, hrv: nil,
                           recovery: nil, strain: nil)]
        XCTAssertEqual(WatchScoreValues(days: noSleep), WatchScoreValues())
    }

    private func day(_ day: String, sleep: Double?, eff: Double?, deep: Double?, rem: Double?, rhr: Int?,
                     hrv: Double?, recovery: Double?, strain: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: eff, deepMin: deep, remMin: rem, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
                    exerciseCount: nil)
    }
}
