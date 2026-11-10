import SwiftData
import XCTest
@testable import PeaqRing

final class SleepCorrectionTests: XCTestCase {
    @MainActor
    func testSleepCorrectionsKeepTheCalendarAndSeparateSessionsFromSummaries() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let ringID = "sleep-corrections-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: "sleepCorrections.\(ringID)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let night = RingSleepSegment(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(6 * 3600),
                                     stage: .deep, recordedClock: true)
        let nap = RingSleepSegment(start: day.addingTimeInterval(13 * 3600), end: day.addingTimeInterval(14 * 3600),
                                   stage: .light, recordedClock: true)
        try RingHistoryPersistence.save(readings: [], sleep: [night, nap], workouts: [], ringID: ringID, context: container.mainContext)
        let sessions = try await RingSnapshotLoader.sleepSessions(container: container, ringID: ringID, day: day, calendar: calendar)
        XCTAssertEqual(sessions.count, 2)
        let overnight = try XCTUnwrap(sessions.first)
        let daytime = try XCTUnwrap(sessions.last)
        XCTAssertNotEqual(overnight.id, daytime.id)
        SleepCorrectionStore.set(.nap, for: daytime, ringID: ringID)
        let revised = try await RingSnapshotLoader.sleepTotals(container: container, ringID: ringID, from: day, through: day, calendar: calendar)
        XCTAssertEqual(revised[day], night.duration)

        SleepCorrectionStore.set(.excluded, for: overnight, ringID: ringID)
        let excluded = try await RingSnapshotLoader.sleepTotals(container: container, ringID: ringID, from: day, through: day, calendar: calendar)
        XCTAssertNil(excluded[day])
        let trend = try await RingSnapshotLoader.sleepNightSummaries(container: container, ringID: ringID, from: day, through: day, calendar: calendar)
        XCTAssertEqual(trend[day]?.asleepDuration, 0)
        let calendarDays = try await RingSnapshotLoader.sleepTotals(container: container, ringID: ringID, from: day, through: day,
                                                                   calendar: calendar, includeExcluded: true)
        XCTAssertEqual(calendarDays[day], night.duration + nap.duration)
        let visible = try await RingSnapshotLoader.sleepSessions(container: container, ringID: ringID, day: day, calendar: calendar)
        XCTAssertEqual(visible.map(\.correction), [.excluded, .nap])
        XCTAssertEqual(visible.flatMap(\.segments), [night, nap])
        XCTAssertTrue(SleepCorrectionStore.load(ringID: "another-ring").isEmpty)

        SleepCorrectionStore.set(.original, for: overnight, ringID: ringID)
        let restored = try await RingSnapshotLoader.sleepTotals(container: container, ringID: ringID, from: day, through: day, calendar: calendar)
        XCTAssertEqual(restored[day], night.duration)
    }

    @MainActor
    func testLegacyCorrectionSurvivesMatchingRecordedClockImport() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let ringID = "sleep-correction-migration-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: "sleepCorrections.\(ringID)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let start = day.addingTimeInterval(60 * 60)
        let legacy = [
            RingSleepSegment(start: start, end: start.addingTimeInterval(3600), stage: .light),
            RingSleepSegment(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(3 * 3600), stage: .deep),
            RingSleepSegment(start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(4 * 3600), stage: .light),
            RingSleepSegment(start: start.addingTimeInterval(4 * 3600), end: start.addingTimeInterval(5 * 3600), stage: .awake)
        ]
        let recorded = legacy.map {
            RingSleepSegment(start: $0.start.addingTimeInterval(-3600), end: $0.end.addingTimeInterval(-3600),
                             stage: $0.stage, recordedClock: true)
        }
        try RingHistoryPersistence.save(readings: [], sleep: legacy, workouts: [], ringID: ringID, context: container.mainContext)
        let before = try await RingSnapshotLoader.sleepSessions(container: container, ringID: ringID, day: day, calendar: calendar)
        let original = try XCTUnwrap(before.first)
        XCTAssertEqual(original.segments, legacy)
        SleepCorrectionStore.set(.excluded, for: original, ringID: ringID)
        try RingHistoryPersistence.save(readings: [], sleep: recorded, workouts: [], ringID: ringID, context: container.mainContext)
        let updated = try await RingSnapshotLoader.sleepSessions(container: container, ringID: ringID, day: day, calendar: calendar)
        let replacement = try XCTUnwrap(updated.first)
        XCTAssertEqual(replacement.segments, recorded)
        XCTAssertEqual(replacement.correction, .excluded)
        SleepCorrectionStore.set(.original, for: replacement, ringID: ringID)
        XCTAssertTrue(SleepCorrectionStore.load(ringID: ringID).isEmpty)
    }
}
