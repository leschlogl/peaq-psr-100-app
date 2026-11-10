import SwiftData
import XCTest
@testable import PeaqRing

final class PersonalBaselinesTests: XCTestCase {
    func testRespiratoryBaselineWeightsEachPriorDayEquallyAndLeavesChartGaps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))!
        let now = today.addingTimeInterval(3600)

        func sample(_ offset: Int, _ value: Double, seconds: TimeInterval = 600, observed: Bool = false) -> RingReading {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return RingReading(metric: .respiration, value: value, date: day.addingTimeInterval(seconds), isObservationTime: observed)
        }

        let samples = [sample(-28, 10), sample(-9, 12), sample(-8, 14), sample(-6, 16), sample(-4, 18),
                       sample(-3, 20), sample(-1, 22), sample(-29, 40), sample(-5, 100),
                       sample(-2, 60, observed: true), sample(0, 40), sample(0, 60, seconds: 7200)]
            + (0..<100).map { sample(-1, 22, seconds: TimeInterval(1200 + $0)) }
        let snapshot = PersonalBaselineSnapshot(metric: .respiration, readings: samples, now: now, calendar: calendar)

        XCTAssertEqual(snapshot.usual.dayCount, 7)
        XCTAssertEqual(snapshot.usual.median, 16)
        XCTAssertEqual(snapshot.usual.range, 13...19)
        XCTAssertEqual(snapshot.days.map(\.median), [16, nil, 18, 20, nil, 22, 40])
        XCTAssertEqual(snapshot.days[5].date.timeIntervalSince(snapshot.days[4].date), 25 * 3600)
    }

    func testBaselineRequiresSevenPriorDaysEvenWhenTodayHasData() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let now = today.addingTimeInterval(3600)
        let readings = (-6...0).map { offset in
            RingReading(metric: .hrv, value: 40, date: calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        let snapshot = PersonalBaselineSnapshot(metric: .hrv, readings: readings, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.usual.dayCount, 6)
        XCTAssertNil(snapshot.usual.range)
        XCTAssertEqual(snapshot.days.last?.median, 40)
    }

    @MainActor
    func testStoredBaselineUsesOnlySelectedRingAndMetric() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let now = today.addingTimeInterval(3600)
        func save(_ readings: [RingReading], ringID: String) throws {
            try RingHistoryPersistence.save(readings: readings, sleep: [], workouts: [],
                                            ringID: ringID, context: container.mainContext)
        }
        let readings = (-7...0).map { offset in
            RingReading(metric: .hrv, value: 45, date: calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        try save(readings + [RingReading(metric: .respiration, value: 15, date: today)], ringID: "A")
        try save([RingReading(metric: .hrv, value: 90, date: today)], ringID: "B")

        let snapshot = try await PersonalBaselineLoader.load(container: container, ringID: "A", metric: .hrv, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.usual.dayCount, 7)
        XCTAssertEqual(snapshot.usual.range, 45...45)
        XCTAssertEqual(snapshot.days.last?.median, 45)
        let respiration = try await PersonalBaselineLoader.load(container: container, ringID: "A", metric: .respiration, now: now, calendar: calendar)
        XCTAssertNil(respiration.usual.range)
        XCTAssertEqual(respiration.days.last?.median, 15)
    }
}
