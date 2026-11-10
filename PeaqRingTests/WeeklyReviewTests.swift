import SwiftData
import XCTest
@testable import PeaqRing

final class WeeklyReviewTests: XCTestCase {
    @MainActor
    func testCompletedWeeksUseDailySnapshotsAndKeepMissingDaysSeparateFromZero() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        calendar.firstWeekday = 2
        func date(_ day: Int, hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let period = WeeklyReviewPeriod(now: date(28), calendar: calendar)
        XCTAssertEqual(period.previousStart, date(12))
        XCTAssertEqual(period.start, date(19))
        XCTAssertEqual(period.end, date(26))
        XCTAssertEqual(period.end.timeIntervalSince(period.start), 169 * 3600)

        let previousMonday = date(12), monday = date(19), tuesday = date(20), sunday = date(25)
        let readings = [
            RingReading(metric: .steps, value: 8500, date: previousMonday, isObservationTime: true),
            RingReading(metric: .steps, value: 2000, date: monday, isObservationTime: true),
            RingReading(metric: .steps, value: 9000, date: date(19, hour: 18), isObservationTime: true),
            RingReading(metric: .steps, value: 0, date: tuesday, isObservationTime: true),
            RingReading(metric: .calories, value: 45, date: monday, isObservationTime: true),
            RingReading(metric: .calories, value: 155, date: date(19, hour: 20), isObservationTime: true),
            RingReading(metric: .distance, value: 4.2, date: monday, isObservationTime: true),
            RingReading(metric: .heartRate, value: 60, date: sunday.addingTimeInterval(1.5 * 3600)),
            RingReading(metric: .heartRate, value: 70, date: sunday.addingTimeInterval(2.5 * 3600)),
            RingReading(metric: .hrv, value: 45, date: date(25, hour: 8)),
            RingReading(metric: .steps, value: 9999, date: date(11), isObservationTime: true),
            RingReading(metric: .steps, value: 9999, date: period.end, isObservationTime: true)
        ]
        let sleepStart = date(18, hour: 23)
        let sleep = RingSleepSegment(start: sleepStart, end: sleepStart.addingTimeInterval(8 * 3600), stage: .light)
        func workout(at date: Date) -> RingWorkout {
            RingWorkout(start: date, end: date.addingTimeInterval(1800), typeCode: nil,
                        steps: 1500, calories: 60, distanceMetres: 900, averageHeartRate: nil)
        }
        try RingHistoryPersistence.save(readings: readings, sleep: [sleep],
            workouts: [previousMonday, monday, sunday, period.end].map { workout(at: $0) },
            ringID: "A", context: container.mainContext)
        try RingHistoryPersistence.save(readings: [RingReading(metric: .steps, value: 10_000, date: date(21), isObservationTime: true)],
            sleep: [sleep], workouts: [workout(at: monday)], ringID: "B", context: container.mainContext)

        let result = try await WeeklyReviewLoader.load(container: container, ringID: "A", period: period, calendar: calendar)
        XCTAssertEqual(result.current.days, (19...25).map { date($0) })
        XCTAssertEqual(result.previous.days, (12...18).map { date($0) })
        XCTAssertEqual(result.current.readings[.steps], [monday: 9000, tuesday: 0])
        XCTAssertEqual(result.previous.readings[.steps], [previousMonday: 8500])
        XCTAssertEqual(result.current.readings[.heartRate], [sunday: 65])
        XCTAssertEqual(result.current.readings[.hrv], [sunday: 45])
        XCTAssertEqual(result.current.sleep, [monday: 8 * 3600])
        XCTAssertTrue(result.previous.sleep.isEmpty)
        XCTAssertEqual(result.current.workoutCount, 2)
        XCTAssertEqual(result.previous.workoutCount, 1)
        let steps = result.current.goalDays(.steps, target: 8000)
        XCTAssertEqual(steps.met, 1)
        XCTAssertEqual(steps.recorded, 2)
        let energy = result.current.goalDays(.calories, target: 150)
        XCTAssertEqual(energy.met, 1)
        XCTAssertEqual(energy.recorded, 1)
        let distance = result.current.goalDays(.distance, target: 5)
        XCTAssertEqual(distance.met, 0)
        XCTAssertEqual(distance.recorded, 1)
    }

    func testWeekNavigationHonorsCalendarFirstWeekdayAcrossTheNewYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        calendar.firstWeekday = 1
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 12))!
        let latest = WeeklyReviewPeriod(now: now, calendar: calendar)
        let earlier = WeeklyReviewPeriod(weeksBack: 1, now: now, calendar: calendar)
        XCTAssertEqual(latest.start, calendar.date(from: DateComponents(year: 2026, month: 12, day: 27)))
        XCTAssertEqual(latest.end, calendar.date(from: DateComponents(year: 2027, month: 1, day: 3)))
        XCTAssertEqual(earlier.end, latest.start)
        XCTAssertEqual(earlier.start, latest.previousStart)
    }
}
