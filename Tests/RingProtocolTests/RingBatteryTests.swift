import XCTest
@testable import RingProtocol

final class RingBatteryTests: XCTestCase {
    func testRingStatusOverridesStaleStandardReading() {
        var tracker = RingBatteryTracker()
        tracker.receiveStandard(90)
        XCTAssertEqual(tracker.percent, 90)
        tracker.receiveRing(58)
        XCTAssertEqual(tracker.percent, 58)
        tracker.receiveStandard(90)
        XCTAssertEqual(tracker.standardPercent, 90)
        XCTAssertEqual(tracker.percent, 58)
        tracker.receiveRing(57)
        XCTAssertEqual(tracker.percent, 57)
        tracker = RingBatteryTracker()
        XCTAssertNil(tracker.percent)
    }
    func testVendorBatteryFrameIsCRCCheckedAndUsesItsPercentByte() {
        var decoder = RingDecoder()
        let frame = RingWire.frame(kind: 0x31, sequence: 0x70, payload: [4,0,0x41,0,2,58,0])
        XCTAssertTrue(decoder.ingest(frame.prefix(6)).isEmpty)
        XCTAssertNil(decoder.batteryStatus)
        XCTAssertTrue(decoder.ingest(frame.dropFirst(6)).isEmpty)
        XCTAssertEqual(decoder.batteryStatus, RingBatteryStatus(percent: 58, stateCode: 0))
        XCTAssertTrue(decoder.receivedBlocks.isEmpty) // No credential/device packets are archived as history.
        var bad = frame
        bad[bad.count-1] ^= 1
        _ = decoder.ingest(bad)
        XCTAssertNil(decoder.batteryStatus)
        XCTAssertGreaterThan(decoder.rejectedFrames, 0)
    }
    func testInvalidBatteryResponsesCannotReplaceValidValues() {
        var tracker = RingBatteryTracker()
        tracker.receiveRing(58)
        tracker.receiveRing(255)
        tracker.receiveStandard(-1)
        XCTAssertEqual(tracker.percent, 58)
        var decoder = RingDecoder()
        for payload: [UInt8] in [[4,0,0x41,0,2,101,0], [4,0,0x41,0,1,58], [2,0,0x41,0,2,58,0]] {
            _ = decoder.ingest(RingWire.frame(kind: 0x31, sequence: 1, payload: payload))
            XCTAssertNil(decoder.batteryStatus)
        }
    }
    func testQueriesIncludeActualBatteryRequestRatherThanOnlyDeviceCapabilities() {
        let query = RingWire.batteryQuery()
        XCTAssertEqual(Array(query.dropFirst(8)), [4,0,0x40,0,0])
        XCTAssertTrue(RingWire.historyQueries().contains(query))
    }
    func testConfirmedPAIUsesNinetyWithPreviousActivityDate() {
        var decoder = RingDecoder()
        let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        let frame = RingWire.frame(kind: 0x31, sequence: 1, payload: [0x0a,0,0xc8,0,4,26,11,7,90])
        let readings = decoder.ingest(frame, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(readings.first?.metric, .pai)
        XCTAssertEqual(readings.first?.value, 90)
        XCTAssertEqual(readings.first?.date, ISO8601DateFormatter().date(from: "2026-11-07T00:00:00Z"))
        let unknown = RingWire.frame(kind: 0x31, sequence: 2, payload: [0x0a,0,0xc7,0,4,26,11,8,62])
        XCTAssertEqual(decoder.ingest(unknown, now: now).first?.metric, .dailyIndexA)
    }
}
