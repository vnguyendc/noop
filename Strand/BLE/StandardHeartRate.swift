import Foundation
import WhoopProtocol

/// Pure parser for the standard BLE Heart Rate Measurement characteristic (0x2A37).
/// Returns the heart rate (bpm) and any R-R intervals (ms). Pure → unit-testable.
public enum StandardHeartRate {
    public static func parse(_ data: [UInt8]) -> (hr: Int, rr: [Int])? {
        StandardHeartRateMeasurement.parse(data)
    }
}
