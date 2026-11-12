import XCTest
@testable import RingProtocol

final class RingStepHistoryTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func history(_ samples: [(String, Double)], days: Int = 1, now: String,
                         zone: String = "UTC") -> RingStepHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let window = RingHistoryWindow(days: days, now: date(now), calendar: calendar)
        var history = RingStepHistory(window: window, calendar: calendar)
        for (time, steps) in samples {
            history.append(RingReading(metric: .steps, value: steps, date: date(time), isObservationTime: true))
        }
        return history
    }

    func testHourlyDeltasExcludeBaselineGapsAndCounterDrops() {
        let result = history([
            ("2026-11-12T07:10:00Z", 100),
            ("2026-11-12T07:30:00Z", 180),
            ("2026-11-12T08:00:00Z", 200),
            ("2026-11-12T08:15:00Z", 200),
            ("2026-11-12T12:00:00Z", 900),
            ("2026-11-12T12:10:00Z", 10),
            ("2026-11-12T12:40:00Z", 60),
            ("2026-11-12T15:30:00Z", 300)
        ], now: "2026-11-12T15:00:00Z")

        XCTAssertEqual(result.buckets.count, 24)
        XCTAssertNil(result.buckets[6].steps)
        XCTAssertEqual(result.buckets[7].steps, 100)
        XCTAssertEqual(result.buckets[8].steps, 0)
        XCTAssertNil(result.buckets[9].steps)
        XCTAssertEqual(result.buckets[12].steps, 50)
        XCTAssertEqual(result.selectedDayTotal, 60)
    }

    func testMultiDayUsesLatestSnapshotAndDistinguishesMissingDaysFromZero() {
        let result = history([
            ("2026-11-05T23:59:00Z", 500),
            ("2026-11-06T23:59:00Z", 0),
            ("2026-11-08T10:00:00Z", 200),
            ("2026-11-08T16:00:00Z", 700),
            ("2026-11-12T14:00:00Z", 150)
        ], days: 7, now: "2026-11-12T15:00:00Z")

        XCTAssertEqual(result.buckets.map(\.steps), [0, nil, 700, nil, nil, nil, 150])
        XCTAssertEqual(result.selectedDayTotal, 150)
    }

    func testRepeatedHourHasTwoIndependentBuckets() {
        let result = history([
            ("2026-10-25T00:10:00Z", 100),
            ("2026-10-25T00:35:00Z", 200),
            ("2026-10-25T01:10:00Z", 300),
            ("2026-10-25T01:30:00Z", 400)
        ], now: "2026-10-25T20:00:00Z", zone: "Europe/Lisbon")

        XCTAssertEqual(result.buckets.count, 25)
        XCTAssertEqual(result.buckets[1].start, date("2026-10-25T00:00:00Z"))
        XCTAssertEqual(result.buckets[2].start, date("2026-10-25T01:00:00Z"))
        XCTAssertEqual(result.buckets[1].steps, 100)
        XCTAssertEqual(result.buckets[2].steps, 100)
    }

    func testSpringForwardDayHasNoBucketForSkippedHour() {
        let result = history([], now: "2026-03-29T20:00:00Z", zone: "Europe/Lisbon")
        XCTAssertEqual(result.buckets.count, 23)
        XCTAssertTrue(result.buckets.allSatisfy { $0.steps == nil })
    }
}
