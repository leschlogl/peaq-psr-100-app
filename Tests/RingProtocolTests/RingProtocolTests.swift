import XCTest
@testable import RingProtocol

final class RingProtocolTests: XCTestCase {
    let utc = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-11-06T22:00:00Z")!
    func packet(_ body: [UInt8], sub: UInt8 = 0xa4, kind: UInt8 = 0x31, sequence: UInt16 = 1) -> Data {
        RingWire.frame(kind: kind, sequence: sequence,
                       payload: [0x0a, 0, sub, UInt8(body.count >> 8), UInt8(body.count & 255)] + body)
    }
    func testStandardCRCAndCapturedQuery() {
        XCTAssertEqual(RingWire.crc(Array("123456789".utf8)), 0x29b1)
        let actual = RingWire.frame(sequence: 5, payload: [2, 0, 0x40, 0, 0])
        XCTAssertEqual(actual.map { String(format: "%02x", $0) }.joined(), "ba210005482200050200400000")
    }
    func testHeartRateAcrossSplitNotificationsAndCoalescedFrames() {
        var decoder = RingDecoder()
        let frame = packet([26, 11, 6, 9, 45, 0, 72])
        XCTAssertTrue(decoder.ingest(frame.prefix(4), now: now, timeZone: utc).isEmpty)
        let received = decoder.ingest(frame.dropFirst(4) + packet([26, 11, 6, 10, 0, 0, 81]), now: now, timeZone: utc)
        XCTAssertEqual(received.map(\.value), [72, 81])
        XCTAssertEqual(received.first?.metric, .heartRate)
        XCTAssertEqual(received.first?.date, ISO8601DateFormatter().date(from: "2026-11-06T09:45:00Z"))
    }
    func testProtocolFragmentReassembly() {
        var decoder = RingDecoder()
        XCTAssertTrue(decoder.ingest(packet([26, 11, 6], kind: 0x71), now: now, timeZone: utc).isEmpty)
        let values = decoder.ingest(packet([9, 45, 0, 72]), now: now, timeZone: utc)
        XCTAssertEqual(values.map(\.value), [72])
    }
    func testCorruptedCRCIsRejectedThenStreamRecovers() {
        var decoder = RingDecoder()
        var bad = packet([26, 11, 6, 9, 45, 0, 72])
        bad[bad.count-1] ^= 1
        let result = decoder.ingest(bad + packet([26, 11, 6, 9, 46, 0, 80]), now: now, timeZone: utc)
        XCTAssertEqual(result.map(\.value), [80])
        XCTAssertGreaterThan(decoder.rejectedFrames, 0)
    }
    func testInvalidDateFutureAndImplausibleValuesAreRejected() {
        for body: [UInt8] in [
            [26, 2, 30, 9, 0, 0, 72], [26, 11, 7, 9, 0, 0, 72],
            [26, 11, 6, 24, 0, 0, 72], [26, 11, 6, 9, 0, 0, 0]
        ] {
            var decoder = RingDecoder()
            XCTAssertTrue(decoder.ingest(packet(body), now: now, timeZone: utc).isEmpty)
        }
    }
    func testInnerLengthMismatchIsRejected() {
        var decoder = RingDecoder()
        let bad = RingWire.frame(kind: 0x31, sequence: 1, payload: [0x0a, 0, 0xa4, 0, 99, 26, 11, 6, 9, 0, 0, 72])
        XCTAssertTrue(decoder.ingest(bad, now: now, timeZone: utc).isEmpty)
        XCTAssertEqual(decoder.rejectedFrames, 1)
    }
    func testMoodAndRespirationAndCompactActivity() {
        var decoder = RingDecoder()
        let result = decoder.ingest(packet([26, 11, 6, 9, 0, 0, 42, 14], sub: 0xc5), now: now, timeZone: utc)
        XCTAssertEqual(result.map(\.metric), [.mood, .respiration])
        XCTAssertEqual(result.map(\.value), [42, 14])
        func floatBytes(_ value: Float) -> [UInt8] {
            let bits = value.bitPattern
            return [UInt8((bits >> 24) & 255), UInt8((bits >> 16) & 255), UInt8((bits >> 8) & 255), UInt8(bits & 255)]
        }
        let compact = packet([0, 0, 3, 0x7f] + floatBytes(57) + floatBytes(0.714), sub: 0xac)
        let activity = decoder.ingest(compact, now: now, timeZone: utc)
        XCTAssertEqual(activity.map(\.metric), [.steps, .calories, .distance])
        XCTAssertEqual(activity[0].value, 895)
        XCTAssertEqual(activity[1].value, 57)
        XCTAssertEqual(activity[2].value, 0.714, accuracy: 0.0001)
        XCTAssertTrue(activity.allSatisfy(\.isObservationTime))
    }
    func testTokenIsUserSuppliedAndCommandsDoNotWriteClockOrProfile() throws {
        let commands = try RingWire.historyCommands(token: "MYRINGTOKEN", now: now, timeZone: utc)
        XCTAssertEqual(commands.count, 31)
        XCTAssertTrue(commands[0].contains(Data("MYRINGTOKEN".utf8)))
        for command in commands {
            let p = Array(command.dropFirst(8))
            XCTAssertNotEqual(Array(p.prefix(4)), [2, 0, 0x20, 0])
            XCTAssertEqual(RingWire.crc(p), UInt16(command[4]) << 8 | UInt16(command[5]))
        }
        for token in ["", "a b", "ä", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try RingWire.historyCommands(token: token))
        }
    }
    func testHistoryKeysDeduplicateAndSeparateRingsAndSnapshots() {
        let first = RingReading(metric: .heartRate, value: 72, date: now)
        let correction = RingReading(metric: .heartRate, value: 73, date: now)
        XCTAssertEqual(first.storageKey(ringID: "one"), correction.storageKey(ringID: "one"))
        XCTAssertNotEqual(first.storageKey(ringID: "one"), first.storageKey(ringID: "two"))
        let snap = RingReading(metric: .steps, value: 123, date: now, isObservationTime: true)
        let repeatSnap = RingReading(metric: .steps, value: 124, date: now.addingTimeInterval(10), isObservationTime: true)
        XCTAssertEqual(snap.storageKey(ringID: "one"), repeatSnap.storageKey(ringID: "one"))
    }
    func testExpiredFragmentCannotJoinLaterSession() {
        var decoder = RingDecoder()
        _ = decoder.ingest(packet([26, 11, 6], kind: 0x71), now: now, timeZone: utc)
        XCTAssertTrue(decoder.ingest(packet([9, 45, 0, 72]), now: now.addingTimeInterval(31), timeZone: utc).isEmpty)
        _ = decoder.ingest(packet([26, 11, 6], kind: 0x71), now: now, timeZone: utc)
        decoder.reset()
        XCTAssertTrue(decoder.ingest(packet([9, 45, 0, 72]), now: now, timeZone: utc).isEmpty)
    }
    func testRandomAndTruncatedInputDoesNotProduceReadings() {
        var decoder = RingDecoder()
        for length in 0...300 {
            let input = Data((0..<length).map { UInt8(($0 * 37 + length) % 256) })
            XCTAssertTrue(decoder.ingest(input, now: now, timeZone: utc).isEmpty)
            decoder.reset()
        }
        let frame = packet([26, 11, 6, 9, 0, 0, 72])
        for length in 0..<frame.count {
            decoder.reset()
            XCTAssertTrue(decoder.ingest(frame.prefix(length), now: now, timeZone: utc).isEmpty)
        }
    }
}
