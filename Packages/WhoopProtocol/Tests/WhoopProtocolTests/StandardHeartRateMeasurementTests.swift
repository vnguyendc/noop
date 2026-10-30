import XCTest
@testable import WhoopProtocol

final class StandardHeartRateMeasurementTests: XCTestCase {
    func testParsesEightBitHeartRate() {
        let parsed = StandardHeartRateMeasurement.parse([0x00, 72])

        XCTAssertEqual(parsed?.hr, 72)
        XCTAssertEqual(parsed?.rr, [])
    }

    func testParsesSixteenBitHeartRate() {
        let parsed = StandardHeartRateMeasurement.parse([0x01, 0x2C, 0x01])

        XCTAssertEqual(parsed?.hr, 300)
        XCTAssertEqual(parsed?.rr, [])
    }

    func testParsesRRIntervals() {
        let parsed = StandardHeartRateMeasurement.parse([0x10, 65, 0x00, 0x04, 0x00, 0x03])

        XCTAssertEqual(parsed?.hr, 65)
        XCTAssertEqual(parsed?.rr, [1000, 750])
    }

    func testSkipsEnergyExpendedBeforeRRIntervals() {
        let parsed = StandardHeartRateMeasurement.parse([0x18, 80, 0x34, 0x12, 0x00, 0x04])

        XCTAssertEqual(parsed?.hr, 80)
        XCTAssertEqual(parsed?.rr, [1000])
    }

    func testRejectsMalformedPackets() {
        XCTAssertNil(StandardHeartRateMeasurement.parse([]))
        XCTAssertNil(StandardHeartRateMeasurement.parse([0x00]))
        XCTAssertNil(StandardHeartRateMeasurement.parse([0x01, 0x2C]))
        XCTAssertNil(StandardHeartRateMeasurement.parse([0x18, 80, 0x34]))
    }
}
