import Foundation

/// One standard-profile (0x2A37) heart-rate reading the watch took directly from the strap.
public struct WatchHRSample: Codable, Equatable {
    /// Unix seconds.
    public let ts: Int
    public let bpm: Int
    /// R-R intervals in milliseconds.
    public let rr: [Int]

    public init(ts: Int, bpm: Int, rr: [Int]) {
        self.ts = ts
        self.bpm = bpm
        self.rr = rr
    }
}

/// Samples the watch collected while it held the strap, sent to the iPhone so they land in the
/// phone's history. A batch with no samples still counts as a liveness heartbeat for the phone.
public struct WatchSampleBatch: Codable, Equatable {
    public let id: UUID
    public let sentAt: Date
    public let directModeActive: Bool
    public let samples: [WatchHRSample]

    public init(id: UUID = UUID(), sentAt: Date, directModeActive: Bool, samples: [WatchHRSample]) {
        self.id = id
        self.sentAt = sentAt
        self.directModeActive = directModeActive
        self.samples = samples
    }

    public struct Row: Equatable {
        public let ts: Int
        public let value: Int
        public init(ts: Int, value: Int) { self.ts = ts; self.value = value }
    }

    /// Rows to persist, filtered with the same plausibility limits the phone's own collector uses
    /// for the standard HR profile (HR 30–220 bpm, R-R 250–3000 ms).
    public func storableRows() -> (hr: [Row], rr: [Row]) {
        var hr: [Row] = []
        var rr: [Row] = []
        for sample in samples {
            if (30...220).contains(sample.bpm) { hr.append(Row(ts: sample.ts, value: sample.bpm)) }
            for interval in sample.rr where (250...3000).contains(interval) {
                rr.append(Row(ts: sample.ts, value: interval))
            }
        }
        return (hr, rr)
    }
}

/// In-memory buffer of watch samples between flushes. Readings within the same second are merged
/// (the phone stores one HR row per second), and the buffer is capped so a long phone outage can't
/// grow it without bound; the oldest samples are dropped first.
public struct WatchSampleBuffer: Equatable {
    public static let defaultCapacity = 4 * 60 * 60   // 4 h at ~1 Hz
    public static let defaultBatchSize = 600

    public private(set) var pending: [WatchHRSample] = []
    public private(set) var droppedCount = 0
    public let capacity: Int

    public init(capacity: Int = WatchSampleBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func append(hr: Int, rr: [Int], at date: Date) {
        let ts = Int(date.timeIntervalSince1970)
        if let last = pending.last, last.ts == ts {
            pending[pending.count - 1] = WatchHRSample(ts: ts, bpm: hr, rr: last.rr + rr)
            return
        }
        pending.append(WatchHRSample(ts: ts, bpm: hr, rr: rr))
        if pending.count > capacity {
            let overflow = pending.count - capacity
            pending.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// Put samples back at the front, for a flush that couldn't be handed to WatchConnectivity.
    public mutating func restore(_ samples: [WatchHRSample]) {
        pending.insert(contentsOf: samples, at: 0)
        if pending.count > capacity {
            let overflow = pending.count - capacity
            pending.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// Remove everything pending and split it into batches. With `heartbeatWhenEmpty`, an empty
    /// buffer still yields one empty batch so the phone knows the watch is alive.
    public mutating func drain(sentAt: Date,
                               directModeActive: Bool,
                               heartbeatWhenEmpty: Bool,
                               batchSize: Int = WatchSampleBuffer.defaultBatchSize) -> [WatchSampleBatch] {
        guard !pending.isEmpty else {
            return heartbeatWhenEmpty
                ? [WatchSampleBatch(sentAt: sentAt, directModeActive: directModeActive, samples: [])]
                : []
        }
        let size = max(1, batchSize)
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        return stride(from: 0, to: samples.count, by: size).map { start in
            WatchSampleBatch(sentAt: sentAt,
                             directModeActive: directModeActive,
                             samples: Array(samples[start..<min(start + size, samples.count)]))
        }
    }
}

public enum WatchSampleTransport {
    public static let batchKey = "watchSampleBatch"

    public static func userInfo(for batch: WatchSampleBatch) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(batch) else { return nil }
        return [batchKey: data]
    }

    public static func batch(from userInfo: [String: Any]) -> WatchSampleBatch? {
        guard let data = userInfo[batchKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSampleBatch.self, from: data)
    }
}
