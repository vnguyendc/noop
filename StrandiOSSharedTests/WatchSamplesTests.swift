import XCTest

final class WatchSamplesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSameSecondReadingsMergeIntoOneSample() {
        var buffer = WatchSampleBuffer()
        buffer.append(hr: 60, rr: [1000], at: t0)
        buffer.append(hr: 62, rr: [968], at: t0.addingTimeInterval(0.4))
        buffer.append(hr: 63, rr: [], at: t0.addingTimeInterval(1))

        XCTAssertEqual(buffer.pending, [
            WatchHRSample(ts: 1_800_000_000, bpm: 62, rr: [1000, 968]),
            WatchHRSample(ts: 1_800_000_001, bpm: 63, rr: [])
        ])
    }

    func testCapacityDropsOldestFirst() {
        var buffer = WatchSampleBuffer(capacity: 2)
        for i in 0..<4 { buffer.append(hr: 60 + i, rr: [], at: t0.addingTimeInterval(TimeInterval(i))) }

        XCTAssertEqual(buffer.pending.map(\.bpm), [62, 63])
        XCTAssertEqual(buffer.droppedCount, 2)
    }

    func testDrainSplitsIntoBatchesAndEmptiesBuffer() {
        var buffer = WatchSampleBuffer()
        for i in 0..<5 { buffer.append(hr: 70, rr: [], at: t0.addingTimeInterval(TimeInterval(i))) }

        let batches = buffer.drain(sentAt: t0, directModeActive: true, heartbeatWhenEmpty: false, batchSize: 2)

        XCTAssertEqual(batches.map { $0.samples.count }, [2, 2, 1])
        XCTAssertTrue(batches.allSatisfy { $0.directModeActive && $0.sentAt == self.t0 })
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEmptyDrainEmitsHeartbeatOnlyWhenAsked() {
        var buffer = WatchSampleBuffer()
        XCTAssertTrue(buffer.drain(sentAt: t0, directModeActive: true, heartbeatWhenEmpty: false).isEmpty)

        let heartbeat = buffer.drain(sentAt: t0, directModeActive: true, heartbeatWhenEmpty: true)
        XCTAssertEqual(heartbeat.count, 1)
        XCTAssertTrue(heartbeat[0].samples.isEmpty)
    }

    func testRestorePutsUnsentSamplesBackInOrder() {
        var buffer = WatchSampleBuffer()
        buffer.append(hr: 61, rr: [], at: t0)
        let unsent = buffer.drain(sentAt: t0, directModeActive: true, heartbeatWhenEmpty: false)[0].samples
        buffer.append(hr: 64, rr: [], at: t0.addingTimeInterval(5))

        buffer.restore(unsent)

        XCTAssertEqual(buffer.pending.map(\.bpm), [61, 64])
    }

    func testStorableRowsApplyPhonePlausibilityLimits() {
        let batch = WatchSampleBatch(sentAt: t0, directModeActive: true, samples: [
            WatchHRSample(ts: 1, bpm: 25, rr: [200, 900]),
            WatchHRSample(ts: 2, bpm: 72, rr: [833, 3100])
        ])

        let rows = batch.storableRows()

        XCTAssertEqual(rows.hr, [WatchSampleBatch.Row(ts: 2, value: 72)])
        XCTAssertEqual(rows.rr, [WatchSampleBatch.Row(ts: 1, value: 900), WatchSampleBatch.Row(ts: 2, value: 833)])
    }

    func testTransportRoundTrip() {
        let batch = WatchSampleBatch(sentAt: t0, directModeActive: false,
                                     samples: [WatchHRSample(ts: 9, bpm: 88, rr: [682])])
        let info = WatchSampleTransport.userInfo(for: batch)

        XCTAssertNotNil(info)
        XCTAssertEqual(info.flatMap(WatchSampleTransport.batch(from:)), batch)
        XCTAssertNil(WatchSampleTransport.batch(from: ["other": 1]))
    }
}
