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
