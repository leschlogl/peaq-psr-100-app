import XCTest
@testable import RingProtocol

final class RingExtendedHistoryTests: XCTestCase {
    let zone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!
    func block(_ sub: UInt8, _ bytes: [UInt8]) -> RingHistoryBlock {
        RingHistoryBlock(command: 0x0a, subcommand: sub, payload: Data(bytes), receivedAt: now)
    }
    func testSleepTransitionsCrossMidnightAndOnlyClosedIntervalsCount() {
        let result = RingExtendedHistory.sleep(block(0xa2, [26,11,6, 1,23,0, 2,23,30, 1,6,0, 0,7,0]), now: now, timeZone: zone)
        XCTAssertEqual(result.map(\.stage), [.light, .deep, .light])
        XCTAssertEqual(result.map(\.duration), [1800, 23400, 3600])
        XCTAssertEqual(result.last?.end, ISO8601DateFormatter().date(from: "2026-11-07T07:00:00Z"))
        // The 07:00 awake transition has no next timestamp. Do not invent its duration.
        XCTAssertFalse(result.contains(where: { $0.stage == .awake }))
    }
    func testRecordedSleepUsesTheRingClockAcrossTimeZones() {
        let packet = block(0xa2, [26,11,6, 1,23,0, 2,23,30, 1,6,0, 0,7,0])
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let lisbon = TimeZone(identifier: "Europe/Lisbon")!
        let oldBerlin = RingExtendedHistory.sleep(packet, now: now, timeZone: berlin)
        let oldLisbon = RingExtendedHistory.sleep(packet, now: now, timeZone: lisbon)
        XCTAssertEqual(oldLisbon[0].start.timeIntervalSince(oldBerlin[0].start), 3600)

        let recorded = RingExtendedHistory.recordedSleep(packet, now: now)
        XCTAssertTrue(recorded.allSatisfy { $0.recordedClock == true })
        XCTAssertEqual(recorded[0].start, ISO8601DateFormatter().date(from: "2026-11-06T23:00:00Z"))
        XCTAssertEqual(recorded.map(\.duration), [1800, 23400, 3600])
        XCTAssertEqual(RingExtendedHistory.recordedSleep(packet, now: now.addingTimeInterval(3600)), recorded)
    }

    func testRecordedSleepPreservesClockTimesThroughDaylightSavingAndYearBoundaries() {
        let cases: [(date: [UInt8], start: String, end: String)] = [
            ([26, 3, 28], "2026-03-28T23:00:00Z", "2026-03-29T07:00:00Z"),
            ([26, 10, 24], "2026-10-24T23:00:00Z", "2026-10-25T07:00:00Z"),
            ([26, 12, 31], "2026-12-31T23:00:00Z", "2027-01-01T07:00:00Z")
        ]
        let iso = ISO8601DateFormatter()
        for example in cases {
            let end = iso.date(from: example.end)!
            // 02:30 is nonexistent on the spring transition and ambiguous
            // on the fall transition in Berlin. The ring only reports a clock.
            let packet = block(0xa2, example.date + [1, 23, 0, 2, 2, 30, 1, 3, 30, 0, 7, 0])
            let segments = RingExtendedHistory.recordedSleep(packet, now: end.addingTimeInterval(3600))
            XCTAssertEqual(segments.first?.start, iso.date(from: example.start), example.start)
            XCTAssertEqual(segments.last?.end, end, example.start)
            XCTAssertEqual(segments.map(\.duration), [12_600, 3_600, 12_600], example.start)
        }
    }

    func testRecordedSleepAllowsAnAheadOfUTCClockButRejectsImplausibleFutureData() {
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-11-07T12:00:00Z")!
        let plausible = block(0xa2, [26, 11, 7, 1, 23, 0, 0, 2, 0])
        let future = block(0xa2, [26, 11, 7, 1, 23, 0, 0, 2, 6])
        XCTAssertEqual(RingExtendedHistory.recordedSleep(plausible, now: now).map(\.duration), [10_800])
        XCTAssertTrue(RingExtendedHistory.recordedSleep(future, now: now).isEmpty)
    }

    func testInvalidTruncatedUnknownAndFutureSleepAreNotInvented() {
        for bytes: [UInt8] in [[], [26,11,6], [26,11,6,1,23], [26,2,30,1,23,0,0,7,0], [26,11,8,1,23,0,0,7,0], [26,11,6,9,23,0,0,7,0]] {
            XCTAssertTrue(RingExtendedHistory.sleep(block(0xa2, bytes), now: now, timeZone: zone).isEmpty)
        }
    }
    func testSleepSummaryTriplesAreNotMisreadAsSleepStages() {
        let values = RingExtendedHistory.sleep(block(0xa2, [26,11,6,255,0,88,254,0,12,1,23,0,0,7,0]), now: now, timeZone: zone)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.duration, 8 * 3600)
    }
    func testModernWorkoutSummaryAndPlausibility() {
        var bytes: [UInt8] = [3,26,11,7,9,0,0] + Array(repeating: 0, count: 42)
        func set(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset+i] = UInt8((value >> (8*(3-i))) & 255) }
        }
        set(3600, at: 7); set(6000, at: 11); set(300, at: 15); set(4200, at: 19); bytes[24] = 110
        let results = RingExtendedHistory.workouts(block(0xa5, bytes), now: now, timeZone: zone)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.steps, 6000)
        XCTAssertEqual(results.first?.calories, 300)
        XCTAssertEqual(results.first?.distanceMetres, 4200)
        XCTAssertEqual(results.first?.averageHeartRate, 110)
        XCTAssertEqual(results.first?.end.timeIntervalSince(results[0].start), 3600)
        bytes[24] = 255
        XCTAssertTrue(RingExtendedHistory.workouts(block(0xa5, bytes), now: now, timeZone: zone).isEmpty)
    }
    func testLegacyWorkoutLittleEndianCaloriesAndMidnight() {
        // Legacy record: date, start/end hour and minute, reserved byte,
        // big-endian steps, then little-endian float calories.
        var bytes: [UInt8] = [26,11,6,23,30,0,30,0, 0,0,3,232]
        let bits = Float(125.5).bitPattern
        bytes += (0..<4).map { UInt8((bits >> (8*$0)) & 255) }
        let values = RingExtendedHistory.workouts(block(0xa5, bytes), now: now, timeZone: zone)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.calories, 125.5)
        XCTAssertEqual(values.first?.steps, 1000)
        XCTAssertEqual(values.first?.end.timeIntervalSince(values[0].start), 3600)
        XCTAssertNil(values.first?.typeCode)
        XCTAssertNil(values.first?.distanceMetres)
    }
    func testUnsupportedWorkoutAndEmptyRecordsStayMissing() {
        XCTAssertTrue(RingExtendedHistory.workouts(block(0xa5, []), now: now, timeZone: zone).isEmpty)
        XCTAssertTrue(RingExtendedHistory.workouts(block(0xa5, [26,11,7,9,0]), now: now, timeZone: zone).isEmpty)
        XCTAssertTrue(RingExtendedHistory.workouts(block(0xc7, [UInt8](repeating: 0, count: 49)), now: now, timeZone: zone).isEmpty)
    }
    func testConfirmedPAIPreservesActivityDates() {
        var decoder = RingDecoder()
        let payload: [UInt8] = [0x0a,0,0xc8,0,8,26,11,5,10,26,11,6,95]
        let records = decoder.ingest(RingWire.frame(kind: 0x31, sequence: 2, payload: payload), now: now, timeZone: zone)
        XCTAssertEqual(records.map(\.metric), [.pai, .pai])
        XCTAssertEqual(records.map(\.value), [10,95])
        XCTAssertEqual(records.first?.date, ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        XCTAssertTrue(records.allSatisfy { $0.metric == .pai })
        let invalid: [UInt8] = [0x0a,0,0xc7,0,4,26,2,30,50]
        XCTAssertTrue(decoder.ingest(RingWire.frame(kind: 0x31, sequence: 3, payload: invalid), now: now, timeZone: zone).isEmpty)
    }
    func testValidatedEnvelopePreservesUnknownRecordForLaterDecoding() {
        var decoder = RingDecoder()
        let payload: [UInt8] = [0x0a,0,0xc7,0,3,26,11,6]
        let frame = RingWire.frame(kind: 0x31, sequence: 1, payload: payload)
        XCTAssertTrue(decoder.ingest(frame, now: now, timeZone: zone).isEmpty)
        XCTAssertEqual(decoder.receivedBlocks.map(\.subcommand), [0xc7])
        XCTAssertEqual(decoder.receivedBlocks.first?.payload, Data([26,11,6]))
        _ = decoder.ingest(Data(), now: now)
        XCTAssertTrue(decoder.receivedBlocks.isEmpty)
    }
}
