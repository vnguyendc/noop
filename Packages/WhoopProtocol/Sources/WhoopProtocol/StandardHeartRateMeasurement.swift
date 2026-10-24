import Foundation

/// Parser for the standard BLE Heart Rate Measurement characteristic (0x2A37).
public enum StandardHeartRateMeasurement {
    public static func parse(_ data: [UInt8]) -> (hr: Int, rr: [Int])? {
        guard !data.isEmpty else { return nil }

        let flags = data[0]
        var idx = 1
        let hr: Int

        if flags & 0x01 != 0 {
            guard idx + 1 < data.count else { return nil }
            hr = Int(data[idx]) | (Int(data[idx + 1]) << 8)
            idx += 2
        } else {
            guard idx < data.count else { return nil }
            hr = Int(data[idx])
            idx += 1
        }

        if flags & 0x08 != 0 {
            guard idx + 1 < data.count else { return nil }
            idx += 2
        }

        var rr: [Int] = []
        if flags & 0x10 != 0 {
            while idx + 1 < data.count {
                let raw = Int(data[idx]) | (Int(data[idx + 1]) << 8)
                rr.append(Int((Double(raw) / 1024.0 * 1000.0).rounded()))
                idx += 2
            }
        }

        return (hr, rr)
    }
}
