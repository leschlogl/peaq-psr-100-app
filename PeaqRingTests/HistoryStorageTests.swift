import XCTest
import SwiftData
import SQLite3
import SwiftUI
@testable import PeaqRing

final class HistoryStorageTests: XCTestCase {
    @MainActor
    func testSyncSummaryCountsOnlyCommittedChangesAndFreshnessIsRingScoped() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date())
        let start = day.addingTimeInterval(-3600)
        let sleep = [
            RingSleepSegment(start: start, end: day, stage: .light, recordedClock: true),
            RingSleepSegment(start: day, end: day.addingTimeInterval(3600), stage: .deep, recordedClock: true)
        ]
        let heartDate = day.addingTimeInterval(4000)
        let activityDate = day.addingTimeInterval(5000)
        let readings = [
            RingReading(metric: .heartRate, value: 63, date: heartDate),
            RingReading(metric: .steps, value: 4200, date: activityDate, isObservationTime: true)
        ]
        let batch = try RingHistoryPersistence.saveBatch(readings: readings + readings, sleep: sleep + sleep, workouts: [],
                                                         ringID: "A", context: context)
        XCTAssertTrue(batch.changed)
        XCTAssertEqual(batch.imports.readings.count, 2)
        XCTAssertEqual(batch.imports.sleepDays.count, 1)
        let repeated = try RingHistoryPersistence.saveBatch(readings: readings, sleep: sleep, workouts: [], ringID: "A", context: context)
        XCTAssertFalse(repeated.changed)
        XCTAssertTrue(repeated.imports.isEmpty)

        let correction = RingReading(metric: .heartRate, value: 65, date: heartDate)
        let corrected = try RingHistoryPersistence.saveBatch(readings: [correction], sleep: [], workouts: [], ringID: "A", context: context)
        var totals = batch.imports
        totals.merge(corrected.imports)
        XCTAssertEqual(totals.readings.count, 2)

        try RingHistoryPersistence.save(readings: [RingReading(metric: .heartRate, value: 68, date: day.addingTimeInterval(6000))],
                                        sleep: [], workouts: [], ringID: "B", context: context)
        let freshness = try await RingSnapshotLoader.freshness(container: container, ringID: "A", calendar: calendar)
        XCTAssertEqual(freshness.sleepDay, day)
        XCTAssertEqual(freshness.heart, heartDate)
        XCTAssertEqual(freshness.activity, activityDate)
        let other = try await RingSnapshotLoader.freshness(container: container, ringID: "B", calendar: calendar)
        XCTAssertNil(other.sleepDay)
        XCTAssertNil(other.activity)
    }

    func testSyncHistoryKeepsLatestThirtyEntriesPerRing() throws {
        let name = "RingSyncHistoryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for index in 0..<35 {
            _ = RingSyncEntry.record(RingSyncEntry(outcome: index == 34 ? .noResponse : .noChanges,
                date: Date(timeIntervalSince1970: TimeInterval(index))), ringID: "A", defaults: defaults)
        }
        let entries = RingSyncEntry.load(ringID: "A", defaults: defaults)
        XCTAssertEqual(entries.count, 30)
        XCTAssertEqual(entries.first?.outcome, .noResponse)
        XCTAssertEqual(entries.first(where: { $0.outcome.successful })?.date, Date(timeIntervalSince1970: 33))
        XCTAssertEqual(entries.last?.date, Date(timeIntervalSince1970: 5))
        XCTAssertTrue(RingSyncEntry.load(ringID: "B", defaults: defaults).isEmpty)
    }

    @MainActor
    func testRecordedSleepHistoryKeepsItsWakeDatesAcrossTheDateLineAndDST() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let now = ISO8601DateFormatter().date(from: "2027-01-02T12:00:00Z")!
        // Each packet begins exactly at 19:00. The daytime nap at 18:00
        // still belongs to the earlier day, even near a month or year change.
        let fixtures: [(wireDate: [UInt8], wake: DateComponents)] = [
            ([26, 3, 28], DateComponents(year: 2026, month: 3, day: 29)),
            ([26, 10, 24], DateComponents(year: 2026, month: 10, day: 25)),
            ([26, 12, 31], DateComponents(year: 2027, month: 1, day: 1))
        ]
        let zones = ["Pacific/Kiritimati", "America/Adak", "Asia/Kathmandu", "Australia/Adelaide",
                     "Pacific/Chatham", "Europe/Berlin", "Europe/Lisbon", "America/St_Johns"]
        let context = container.mainContext
        for (index, fixture) in fixtures.enumerated() {
            let ring = "Travel-\(index)"
            let nightPacket = RingHistoryBlock(command: 10, subcommand: 162,
                payload: Data(fixture.wireDate + [1, 19, 0, 0, 21, 0, 2, 22, 0, 1, 2, 30, 0, 6, 0]), receivedAt: now)
            let night = RingExtendedHistory.recordedSleep(nightPacket, now: now)
            XCTAssertEqual(night.count, 4)
            let napStart = night[0].start.addingTimeInterval(-3600)
            let nap = RingSleepSegment(start: napStart, end: napStart.addingTimeInterval(1800), stage: .light, recordedClock: true)
            XCTAssertTrue(try RingHistoryPersistence.save(readings: [], sleep: [nap] + night, workouts: [], ringID: ring, context: context))

            for (trip, zone) in zones.enumerated() {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                let wake = try XCTUnwrap(calendar.date(from: fixture.wake))
                let previous = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: wake))
                let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: wake))
                let reimported = RingExtendedHistory.recordedSleep(nightPacket, now: now.addingTimeInterval(Double(trip) * 3600))
                XCTAssertFalse(try RingHistoryPersistence.save(readings: [], sleep: reimported, workouts: [], ringID: ring, context: context), zone)

                let history = try await RingSnapshotLoader.sleepTotals(container: container, ringID: ring,
                    from: previous, through: next, calendar: calendar)
                XCTAssertEqual(history, [previous: 1800, wake: 36_000], zone)
                let summaries = try await RingSnapshotLoader.sleepNightSummaries(container: container, ringID: ring,
                    from: previous, through: next, calendar: calendar)
                let timing = try XCTUnwrap(summaries[wake], zone)
                XCTAssertEqual(timing.startOffset, -5 * 3600, zone)
                XCTAssertEqual(timing.endOffset, 6 * 3600, zone)
                XCTAssertEqual(timing.asleepDuration, 10 * 3600, zone)
                XCTAssertFalse(timing.usesLocalClock, zone)
                XCTAssertEqual(summaries[previous]?.startOffset, 18 * 3600, zone)
                XCTAssertNil(summaries[next], zone)
                let detail = try await RingSnapshotLoader.sleepNight(container: container, ringID: ring, day: wake, calendar: calendar)
                XCTAssertEqual(detail, night, zone)
                let latest = try await RingSnapshotLoader.insights(container: container, ringID: ring, calendar: calendar)
                XCTAssertEqual(latest.sleep, night, zone)
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSleepSegment>()), 15)
    }

    @MainActor
    func testLegacyRepairCountsFractionalShiftOnceButKeepsDistinctAndAmbiguousSessions() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let first = day.addingTimeInterval(3600)
        let original = [
            RingSleepSegment(start: first, end: first.addingTimeInterval(1200), stage: .light),
            RingSleepSegment(start: first.addingTimeInterval(1200), end: first.addingTimeInterval(4800), stage: .deep),
            RingSleepSegment(start: first.addingTimeInterval(4800), end: first.addingTimeInterval(7200), stage: .light)
        ]
        func shifted(by offset: TimeInterval) -> [RingSleepSegment] {
            original.map { RingSleepSegment(start: $0.start.addingTimeInterval(offset), end: $0.end.addingTimeInterval(offset), stage: $0.stage) }
        }
        let laterNap = shifted(by: 10 * 3600)
        let shiftedCopy = shifted(by: 45 * 60)
        let last = shiftedCopy[2]
        let different = Array(shiftedCopy.prefix(2)) + [RingSleepSegment(start: last.start, end: last.end, stage: .deep)]
        let fixtures = [
            (stored: original + shiftedCopy + laterNap, expected: original + laterNap),
            (stored: original + different, expected: (original + different).sorted { $0.start < $1.start })
        ]
        for (index, fixture) in fixtures.enumerated() {
            let ring = "Legacy-\(index)"
            try RingHistoryPersistence.save(readings: [], sleep: fixture.stored, workouts: [], ringID: ring, context: container.mainContext)
            let loaded = try await RingSnapshotLoader.sleepNight(container: container, ringID: ring, day: day, calendar: calendar)
            XCTAssertEqual(loaded, fixture.expected)
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredSleepSegment>()), 15)
    }

    @MainActor
    func testTravelSleepRepairsShiftedCopiesAndPrefersRecordedClock() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var lisbon = Calendar(identifier: .gregorian)
        lisbon.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        var berlin = lisbon
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = DateComponents(year: 2026, month: 11, day: 8)
        let now = lisbon.date(from: day)!.addingTimeInterval(18 * 3600)
        let packet = RingHistoryBlock(command: 10, subcommand: 162,
            payload: Data([26,11,7, 1,23,0, 2,23,43, 1,0,58, 0,8,40]), receivedAt: now)
        let legacyBerlin = RingExtendedHistory.sleep(packet, now: now, timeZone: berlin.timeZone)
        let legacyLisbon = RingExtendedHistory.sleep(packet, now: now, timeZone: lisbon.timeZone)
        let nap = RingSleepSegment(start: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(-3 * 3600), stage: .light)
        let context = container.mainContext
        try RingHistoryPersistence.save(readings: [], sleep: legacyBerlin + legacyLisbon + [nap], workouts: [], ringID: "A", context: context)
        try RingHistoryPersistence.save(readings: [], sleep: legacyLisbon, workouts: [], ringID: "B", context: context)

        let lisbonDay = lisbon.date(from: day)!
        let repaired = try await RingSnapshotLoader.sleepNight(container: container, ringID: "A", day: lisbonDay, calendar: lisbon)
        XCTAssertEqual(repaired, legacyBerlin + [nap])

        let recorded = RingExtendedHistory.recordedSleep(packet, now: now)
        XCTAssertTrue(try RingHistoryPersistence.save(readings: [], sleep: recorded, workouts: [], ringID: "A", context: context))
        XCTAssertFalse(try RingHistoryPersistence.save(readings: [], sleep: RingExtendedHistory.recordedSleep(packet, now: now.addingTimeInterval(3600)),
                                                       workouts: [], ringID: "A", context: context))
        for calendar in [lisbon, berlin] {
            let localDay = calendar.date(from: day)!
            let totals = try await RingSnapshotLoader.sleepTotals(container: container, ringID: "A",
                                                                  from: localDay, through: localDay, calendar: calendar)
            XCTAssertEqual(totals, [localDay: 640 * 60])
            let detail = try await RingSnapshotLoader.sleepNight(container: container, ringID: "A", day: localDay, calendar: calendar)
            XCTAssertEqual(detail, recorded + [nap])
            let summaries = try await RingSnapshotLoader.sleepNightSummaries(container: container, ringID: "A",
                from: localDay, through: localDay, calendar: calendar)
            let timing = try XCTUnwrap(summaries[localDay])
            XCTAssertEqual(timing.startOffset, -3600)
            XCTAssertEqual(timing.asleepDuration, 640 * 60)
            XCTAssertTrue(timing.usesLocalClock)
            let latest = try await RingSnapshotLoader.insights(container: container, ringID: "A", calendar: calendar)
            XCTAssertEqual(latest.sleep, detail)
        }
        let otherRing = try await RingSnapshotLoader.sleepNight(container: container, ringID: "B", day: lisbonDay, calendar: lisbon)
        XCTAssertEqual(otherRing, legacyLisbon)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSleepSegment>()), 13)
    }

    @MainActor
    func testSleepHistoryUsesWakeDateAndExcludesAwakeTimeAndOtherRings() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        func date(_ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let overnight = RingSleepSegment(start: date(24, 23), end: date(25, 6), stage: .light)
        let awake = RingSleepSegment(start: date(25, 6), end: date(25, 7), stage: .awake)
        let awakeOnly = RingSleepSegment(start: date(26, 4), end: date(26, 5), stage: .awake)
        let cutoff = RingSleepSegment(start: date(27, 18), end: date(27, 19), stage: .deep)
        try RingHistoryPersistence.save(readings: [], sleep: [overnight, awake, awakeOnly, cutoff], workouts: [],
                                        ringID: "A", context: container.mainContext)
        try RingHistoryPersistence.save(readings: [], sleep: [cutoff], workouts: [], ringID: "B", context: container.mainContext)

        let totals = try await RingSnapshotLoader.sleepTotals(container: container, ringID: "A",
                                                              from: date(24), through: date(26), calendar: calendar)
        XCTAssertEqual(totals, [date(25): 8 * 3600])
        let detail = try await RingSnapshotLoader.sleepNight(container: container, ringID: "A", day: date(25), calendar: calendar)
        XCTAssertEqual(detail, [overnight, awake])
        let otherRing = try await RingSnapshotLoader.sleepTotals(container: container, ringID: "B",
                                                                  from: date(24), through: date(27), calendar: calendar)
        XCTAssertEqual(otherRing, [date(27): 3600])
        let latest = try await RingSnapshotLoader.insights(container: container, ringID: "A", calendar: calendar)
        XCTAssertEqual(latest.sleep, [cutoff])
    }

    @MainActor
    func testCalendarAvailabilityIsScopedToMonthRingAndVisibleDashboardMetrics() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        let now = date(10,29)
        let data = [RingReading(metric: .steps, value: 300, date: date(10,23), isObservationTime: true),
                    RingReading(metric: .heartRate, value: 72, date: date(10,25)),
                    RingReading(metric: .heartRate, value: 80, date: date(10,26)),
                    RingReading(metric: .pai, value: 90, date: date(10,27)),
                    RingReading(metric: .dailyIndexA, value: 90, date: date(10,28)),
                    RingReading(metric: .heartRate, value: 72, date: date(10,30)),
                    RingReading(metric: .heartRate, value: 72, date: date(9,30))]
        try RingHistoryPersistence.save(readings: data, sleep: [], workouts: [], ringID: "A", context: container.mainContext)
        try RingHistoryPersistence.save(readings: [RingReading(metric: .heartRate, value: 72, date: date(10,24))], sleep: [], workouts: [], ringID: "B", context: container.mainContext)
        let days = try await RingSnapshotLoader.availableDashboardDays(container: container, ringID: "A", month: now, now: now, calendar: calendar)
        XCTAssertEqual(days, Set([date(10,23),date(10,25),date(10,26)]))
        let empty = try await RingSnapshotLoader.availableDashboardDays(container: container, ringID: "A", month: date(8,1), now: now, calendar: calendar)
        XCTAssertTrue(empty.isEmpty)
    }
    @MainActor
    func testCalendarDecorationsMarkOnlyAvailableDays() async throws {
        let calendar = Calendar.current
        let date = calendar.startOfDay(for: Date())
        let parent = HistoryAvailabilityCalendar(day: .constant(date), visibleMonth: .constant(date), availableDays: [date])
        let coordinator = parent.makeCoordinator()
        coordinator.decoratedDays = [date]
        let view = UICalendarView()
        XCTAssertNotNil(coordinator.calendarView(view, decorationFor: calendar.dateComponents([.year,.month,.day], from: date)))
        let absent = calendar.date(byAdding: .day, value: -1, to: date)!
        XCTAssertNil(coordinator.calendarView(view, decorationFor: calendar.dateComponents([.year,.month,.day], from: absent)))
        let marked = [date, absent, calendar.date(byAdding: .day, value: -3, to: date)!]
        coordinator.decoratedDays = Set(marked)
        view.calendar = calendar; view.timeZone = calendar.timeZone
        view.delegate = coordinator; view.tintColor = .systemMint
        view.availableDateRange = DateInterval(start: .distantPast, end: Date())
        let selection = UICalendarSelectionSingleDate(delegate: coordinator)
        view.selectionBehavior = selection
        selection.setSelected(calendar.dateComponents([.year,.month,.day], from: date), animated: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.overrideUserInterfaceStyle = .dark
        let controller = UIViewController()
        controller.view.backgroundColor = .secondarySystemBackground
        window.rootViewController = controller
        view.frame = CGRect(x: 20, y: 20, width: 350, height: 550)
        controller.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Calendar with saved-data dots"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    func testHistoricalCardsChartsAndHRVExcludeFollowingDays() async throws {
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: selected)!
        let now = calendar.date(byAdding: .day, value: 10, to: selected)!
        var data = [RingReading(metric: .heartRate, value: 72, date: selected),
                    RingReading(metric: .heartRate, value: 88, date: selected.addingTimeInterval(1800)),
                    RingReading(metric: .heartRate, value: 80, date: tomorrow.addingTimeInterval(-1)),
                    RingReading(metric: .heartRate, value: 120, date: tomorrow),
                    RingReading(metric: .oxygen, value: 99, date: selected.addingTimeInterval(-1)),
                    RingReading(metric: .steps, value: 4200, date: tomorrow.addingTimeInterval(-60), isObservationTime: true),
                    RingReading(metric: .hrv, value: 45, date: selected.addingTimeInterval(3600)),
                    RingReading(metric: .hrv, value: 200, date: tomorrow)]
        for offset in 1...7 {
            data.append(RingReading(metric: .hrv, value: 40, date: calendar.date(byAdding: .day, value: -offset, to: selected)!))
        }
        try RingHistoryPersistence.save(readings: data, sleep: [], workouts: [], ringID: "A", context: container.mainContext)
        let day = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", selectedDay: selected, now: now, calendar: calendar)
        XCTAssertEqual(day.latest[.heartRate]?.value, 80)
        XCTAssertEqual(day.latest[.steps]?.value, 4200)
        XCTAssertNil(day.latest[.oxygen]) // No fallback to the previous day.
        XCTAssertEqual(day.sourceCount, 3); XCTAssertEqual(day.readings.map(\.value), [80,80])
        XCTAssertEqual(day.readings.first?.date, selected)
        XCTAssertEqual(day.hrvBaseline.dayCount, 7); XCTAssertEqual(day.hrvBaseline.median, 40)
        let week = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", days: 7, selectedDay: selected, now: now, calendar: calendar)
        XCTAssertEqual(week.readings.map(\.value), [80])
        let empty = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", selectedDay: now.addingTimeInterval(-86400), now: now, calendar: calendar)
        XCTAssertTrue(empty.latest.isEmpty); XCTAssertEqual(empty.sourceCount, 0)
    }
    @MainActor
    func testDailyTrendChartsRenderAtPhoneWidth() throws {
        let calendar = Calendar.current
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        for days in [1,7,30] {
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: end))!
            let pointCount = days == 1 ? 13 : days
            let values: [DisplayReading] = (0..<pointCount).compactMap { index in
                // A missing day must remain a visible break in the line.
                if index == 3 { return nil }
                let date = calendar.date(byAdding: days == 1 ? .hour : .day, value: index, to: start)!
                // The selected point overlaps the callout near the top of the plot.
                let value = index == pointCount - 1 ? 99 : 68 + sin(Double(index) * 0.7) * 8
                return DisplayReading(id: String(index), metric: .heartRate, value: value, date: date, observed: false, series: index < 3 ? 0 : 1)
            }
            let view = RingTrendPlot(values: values, metric: .heartRate, rangeDays: days, start: start, end: end, band: 60...100, sourceCount: values.count * 80, selectedDate: values.last?.date)
                .frame(width: 330, height: 190).padding(20)
                .background(Color(red: 0.075, green: 0.10, blue: 0.115))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "\(days)-day averages with a missing period"; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    @MainActor
    func testChartSelectionUsesItsHourOrDayWithoutFillingGaps() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        for days in [1,7,30] {
            let component: Calendar.Component = days == 1 ? .hour : .day
            let second = calendar.date(byAdding: component, value: 2, to: start)!
            let end = calendar.date(byAdding: component, value: 3, to: start)!
            let readings = [DisplayReading(id: "first", metric: .heartRate, value: 72.5, date: start, observed: false, series: 0),
                            DisplayReading(id: "last", metric: .heartRate, value: 85, date: second, observed: false, series: 1)]
            for (offset, expected): (Int, Double?) in [(0,72.5),(1,nil),(2,85)] {
                let selected = calendar.date(byAdding: component, value: offset, to: start)!.addingTimeInterval(60)
                let view = RingTrendPlot(values: readings, metric: .heartRate, rangeDays: days, start: start, end: end, band: nil, sourceCount: 20, selectedDate: selected)
                XCTAssertEqual(view.selectedReading?.value, expected)
            }
        }
    }
    @MainActor
    func testExistingDiskStoreUpgradesIndexesWithoutLosingReadingsSleepOrWorkouts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.store")
        let date = Date(timeIntervalSince1970: 1_783_000_020)
        let sample = RingReading(metric: .steps, value: 4200, date: date, isObservationTime: true)
        let sleep = RingSleepSegment(start: date, end: date.addingTimeInterval(600), stage: .deep)
        let workout = RingWorkout(start: date, end: date.addingTimeInterval(900), typeCode: 3, steps: 1000, calories: 80, distanceMetres: nil, averageHeartRate: 110)
        try autoreleasepool {
            let legacy = Schema([StoredReading.self, StoredSleepSegment.self, StoredWorkout.self])
            let container = try ModelContainer(for: legacy, configurations: ModelConfiguration(schema: legacy, url: url))
            try RingHistoryPersistence.save(readings: [sample], sleep: [sleep], workouts: [workout], ringID: "A", context: container.mainContext)
        }
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let records = try context.fetch(FetchDescriptor<StoredReading>())
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.key, sample.storageKey(ringID: "A"))
        XCTAssertEqual(records.first?.value, 4200); XCTAssertEqual(records.first?.isObservationTime, true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSleepSegment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredWorkout>()), 1)
        if #available(iOS 18, *) {
            XCTAssertEqual(schema.entitiesByName["StoredReading"]?.indices, [["binary", "ringID", "metricName", "date"]])
            let columns = try indexColumns(at: url)
            XCTAssertTrue(columns.contains(["ZRINGID", "ZMETRICNAME", "ZDATE"]), "Expected persisted compound reading index, got \(columns)")
            XCTAssertTrue(columns.contains(["ZRINGID", "ZSTART"]))
        }
        let snapshot = try await RingSnapshotLoader.insights(container: container, ringID: "A")
        XCTAssertEqual(snapshot.sleep, [sleep]); XCTAssertEqual(snapshot.workouts, [workout])
    }

    @MainActor
    func testHundredThousandReadingDiskStoreUsesBoundedQueriesAndKeepsOldCorrections() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let schema = RingDatabaseSchema.make()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: folder.appendingPathComponent("scale.store")))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        let seedStart = Date()
        let seedTask: Task<Void, Error> = Task.detached(priority: .utility) {
            for offset in stride(from: 0, to: 100_000, by: 500) {
                let context = ModelContext(container); context.autosaveEnabled = false
                var readings: [RingReading] = []
                for index in offset..<min(offset + 500, 100_000) {
                    let value: Double = index == 400 ? 220 : Double(60 + index % 60)
                    let stamp = now.addingTimeInterval(-Double(index) * 300)
                    readings.append(RingReading(metric: .heartRate, value: value, date: stamp))
                }
                try RingHistoryPersistence.save(readings: readings, sleep: [], workouts: [], ringID: "A", context: context)
            }
            let context = ModelContext(container)
            var hrv: [RingReading] = []
            for day in 1...35 {
                let stamp = now.addingTimeInterval(-Double(day) * 86400)
                hrv.append(RingReading(metric: .hrv, value: Double(40 + day % 5), date: stamp))
            }
            hrv.append(RingReading(metric: .hrv, value: 45, date: now))
            var pai: [RingReading] = []
            for day in 0..<40 {
                let stamp = now.addingTimeInterval(-Double(day) * 86400)
                pai.append(RingReading(metric: .pai, value: 90, date: stamp))
            }
            var sleep: [RingSleepSegment] = [], workouts: [RingWorkout] = []
            for day in 0..<40 {
                let start = calendar.startOfDay(for: now).addingTimeInterval(Double(-day * 86400))
                sleep.append(RingSleepSegment(start: start, end: start.addingTimeInterval(4 * 3600), stage: .light))
                sleep.append(RingSleepSegment(start: start.addingTimeInterval(4 * 3600), end: start.addingTimeInterval(8 * 3600), stage: .deep))
                workouts.append(RingWorkout(start: start, end: start.addingTimeInterval(900), typeCode: nil, steps: 1000, calories: 80, distanceMetres: nil, averageHeartRate: 110))
            }
            try RingHistoryPersistence.save(readings: hrv + pai, sleep: sleep, workouts: workouts, ringID: "A", context: context)
            try RingHistoryPersistence.save(readings: [RingReading(metric: .heartRate, value: 99, date: now)], sleep: [], workouts: [], ringID: "B", context: context)
        }
        try await seedTask.value
        let seededSeconds = Date().timeIntervalSince(seedStart)
        let loadStart = Date()
        for days in [1, 7, 30] {
            let snapshot = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", days: days, now: now, calendar: calendar)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
            XCTAssertEqual(snapshot.sourceCount, Int(now.timeIntervalSince(start) / 300) + 1)
            XCTAssertLessThanOrEqual(snapshot.readings.count, days > 1 ? days : 25)
            XCTAssertEqual(snapshot.latest[.heartRate]?.value, 60)
            XCTAssertEqual(snapshot.hrvBaseline.dayCount, 28)
            if days > 1 {
                let todaySampleCount = Int(now.timeIntervalSince(calendar.startOfDay(for: now)) / 300) + 1
                let todaySum = (0..<todaySampleCount).reduce(0.0) { $0 + Double(60 + $1 % 60) }
                XCTAssertEqual(snapshot.readings.count, days)
                XCTAssertEqual(snapshot.readings.last!.value, todaySum / Double(todaySampleCount), accuracy: 0.000001)
                XCTAssertEqual(snapshot.readings.last?.date, calendar.startOfDay(for: now))
            }
        }
        let insights = try await RingSnapshotLoader.insights(container: container, ringID: "A", calendar: calendar)
        XCTAssertEqual(insights.sleep.count, 2); XCTAssertEqual(insights.workouts.count, 20); XCTAssertEqual(insights.pai.count, 14)
        let availableDays = try await RingSnapshotLoader.availableDashboardDays(container: container, ringID: "A", month: now, now: now, calendar: calendar)
        XCTAssertEqual(availableDays.count, 9)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let oldest = now.addingTimeInterval(Double(-99_999 * 300))
        let corrections = [RingReading(metric: .heartRate, value: 80, date: oldest), RingReading(metric: .heartRate, value: 74, date: now)]
        XCTAssertTrue(try RingHistoryPersistence.save(readings: corrections, sleep: [], workouts: [], ringID: "A", context: container.mainContext))
        XCTAssertFalse(try RingHistoryPersistence.save(readings: corrections, sleep: [], workouts: [], ringID: "A", context: container.mainContext))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredReading>()), 100_077)
        let corrected = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", now: now, calendar: calendar)
        XCTAssertEqual(corrected.latest[.heartRate]?.value, 74)
        print("Synthetic disk benchmark: 100,077 readings seeded in \(seededSeconds)s; three chart windows plus Insights loaded in \(loadSeconds)s; multi-day charts use one mean per recorded day.")
    }

    private func indexColumns(at url: URL) throws -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticSQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        func strings(_ sql: String, column: Int32) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SyntheticSQLite", code: 2) }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, column) { values.append(String(cString: value)) }
            }
            return values
        }
        return try strings("SELECT name FROM sqlite_master WHERE type='index'", column: 0).map { name in
            try strings("PRAGMA index_info('\(name.replacingOccurrences(of: "'", with: "''"))')", column: 2)
        }
    }
    @MainActor
    func testUnchangedBatchDoesNotCommitAndCorrectionsStillMerge() throws {
        let container = try ModelContainer(for: StoredReading.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_783_000_000)
        let first = RingReading(metric: .heartRate, value: 72, date: date)
        XCTAssertTrue(try RingHistoryPersistence.save(readings: Array(repeating: first, count: 801), sleep: [], workouts: [], ringID: "A", context: context))
        XCTAssertFalse(try RingHistoryPersistence.save(readings: [first], sleep: [], workouts: [], ringID: "A", context: context))
        XCTAssertTrue(try RingHistoryPersistence.save(readings: [RingReading(metric: .heartRate, value: 73, date: date)], sleep: [], workouts: [], ringID: "A", context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredReading>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredReading>()).first?.value, 73)
    }

    @MainActor
    func testBackgroundHistoryBurstKeepsMainActorAvailableAndFlushWaitsForPublication() async throws {
        let container = try ModelContainer(for: StoredReading.self, StoredSleepSegment.self, StoredWorkout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var published = 0, batches = 0, failures = 0, ticks = 0
        let worker = RingHistoryWorker(container: container) { update in
            XCTAssertTrue(Thread.isMainThread)
            published += update.saved; batches += 1
            if update.storageFailed { failures += 1 }
        }
        let session = UUID(); worker.beginSession(session, ringID: "A")
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        // Two thousand distinct samples arriving in a notification burst.
        // The UI actor must be able to run while decoding and saving them.
        for block in 0..<20 {
            var body: [UInt8] = []
            for row in 0..<100 {
                let minute = block * 100 + row
                body += [26, 1, UInt8(1 + minute / 1440), UInt8(minute % 1440 / 60), UInt8(minute % 60), 0, 72]
            }
            let packet = RingWire.frame(kind: 0x31, sequence: UInt16(block), payload: [0x0a, 0, 0xa4, UInt8(body.count >> 8), UInt8(body.count & 255)] + body)
            // Exercise transport reassembly across queue submissions too.
            worker.enqueue(packet.prefix(4), sessionID: session)
            worker.enqueue(packet.dropFirst(4), sessionID: session)
        }
        await worker.flush()
        heartbeat.cancel()
        XCTAssertGreaterThan(ticks, 0)
        XCTAssertEqual(published, 2000)
        XCTAssertEqual(failures, 0)
        XCTAssertLessThan(batches, 40)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12))!
        let snapshot = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", days: 7, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.sourceCount, 2000)
        XCTAssertEqual(snapshot.readings.count, 2)
        XCTAssertTrue(snapshot.readings.allSatisfy { $0.value == 72 })
    }

    @MainActor
    func testSessionChangeDrainsOldHistoryAndRejectsStalePackets() async throws {
        let container = try ModelContainer(for: StoredReading.self, StoredSleepSegment.self, StoredWorkout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var updates: [RingHistoryUpdate] = []
        let worker = RingHistoryWorker(container: container) { updates.append($0) }
        func packet(_ value: UInt8) -> Data {
            RingWire.frame(kind: 0x31, sequence: 1, payload: [0x0a, 0, 0xa4, 0, 7, 26, 1, 1, 9, 0, 0, value])
        }
        let first = UUID(), second = UUID()
        worker.beginSession(first, ringID: "A")
        worker.enqueue(packet(72), sessionID: first)
        worker.beginSession(second, ringID: "B")
        worker.enqueue(packet(99), sessionID: first)
        worker.enqueue(packet(81), sessionID: second)
        await worker.flush()
        XCTAssertEqual(updates.map(\.ringID), ["A", "B"])
        XCTAssertEqual(updates.map(\.sessionID), [first, second])
        let selected = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let a = try await RingSnapshotLoader.dashboard(container: container, ringID: "A", selectedDay: selected)
        let b = try await RingSnapshotLoader.dashboard(container: container, ringID: "B", selectedDay: selected)
        XCTAssertEqual(a.latest[.heartRate]?.value, 72); XCTAssertEqual(b.latest[.heartRate]?.value, 81)
        // A repeated import is acknowledged but doesn't invalidate the views.
        worker.enqueue(packet(81), sessionID: second)
        await worker.flush()
        XCTAssertEqual(updates.last?.saved, 1)
        XCTAssertEqual(updates.last?.changed, false)
    }

    @MainActor
    func testBackgroundInsightsSnapshotContainsOnlyItsRingAndPAI() async throws {
        let container = try ModelContainer(for: StoredReading.self, StoredSleepSegment.self, StoredWorkout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let date = Date(timeIntervalSince1970: 1_783_000_020)
        let sleep = RingSleepSegment(start: date, end: date.addingTimeInterval(600), stage: .deep)
        let workout = RingWorkout(start: date, end: date.addingTimeInterval(900), typeCode: 3, steps: 1000, calories: 80, distanceMetres: nil, averageHeartRate: 110)
        for id in ["A", "B"] {
            try RingHistoryPersistence.save(readings: [RingReading(metric: .pai, value: 90, date: date), RingReading(metric: .heartRate, value: 72, date: date)], sleep: [sleep], workouts: [workout], ringID: id, context: container.mainContext)
        }
        let snapshot = try await RingSnapshotLoader.insights(container: container, ringID: "A")
        XCTAssertEqual(snapshot.sleep, [sleep]); XCTAssertEqual(snapshot.workouts, [workout])
        XCTAssertEqual(snapshot.pai.map(\.metric), [.pai]); XCTAssertEqual(snapshot.pai.map(\.value), [90])
    }
    @MainActor
    func testPAIMigrationRekeysHistoryWithoutDuplicatingScores() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredReading.self, configurations: config)
        let store = RingStore(container: container)
        let date = Date(timeIntervalSince1970: 1_794_009_600)
        try store.save([RingReading(metric: .dailyIndexB, value: 90, date: date)], ringID: "A")
        try store.save([RingReading(metric: .dailyIndexB, value: 40, date: date)], ringID: "B")
        try store.migrateConfirmedPAI()
        try store.migrateConfirmedPAI()
        try store.save([RingReading(metric: .pai, value: 90, date: date)], ringID: "A")
        let records = try container.mainContext.fetch(FetchDescriptor<StoredReading>())
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.metricName == RingMetric.pai.rawValue })
        XCTAssertEqual(records.first(where: { $0.ringID == "A" })?.value, 90)
        // An already imported ring score wins over a duplicate legacy record.
        try store.save([RingReading(metric: .dailyIndexB, value: 89, date: date)], ringID: "A")
        try store.migrateConfirmedPAI()
        let merged = try container.mainContext.fetch(FetchDescriptor<StoredReading>())
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first(where: { $0.ringID == "A" })?.value, 90)
    }
    @MainActor
    func testSleepAndExerciseMergeAndRemainSeparateByRing() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredReading.self, StoredSleepSegment.self, StoredWorkout.self, configurations: config)
        let store = RingStore(container: container)
        let date = Date(timeIntervalSince1970: 1_783_000_020)
        let first = RingSleepSegment(start: date, end: date.addingTimeInterval(600), stage: .light)
        let corrected = RingSleepSegment(start: date, end: date.addingTimeInterval(900), stage: .deep)
        let workout = RingWorkout(start: date, end: date.addingTimeInterval(3600), typeCode: 3, steps: 6000, calories: 300, distanceMetres: 4000, averageHeartRate: 100)
        try store.saveExtended(sleep: [first], workouts: [workout], ringID: "A")
        try store.saveExtended(sleep: [corrected], workouts: [workout], ringID: "A")
        try store.saveExtended(sleep: [first], workouts: [workout], ringID: "B")
        let sleep = try container.mainContext.fetch(FetchDescriptor<StoredSleepSegment>())
        let workouts = try container.mainContext.fetch(FetchDescriptor<StoredWorkout>())
        XCTAssertEqual(sleep.count, 2)
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(sleep.first(where: { $0.ringID == "A" })?.end, corrected.end)
        XCTAssertEqual(sleep.first(where: { $0.ringID == "A" })?.stageCode, RingSleepStage.deep.rawValue)
    }
    @MainActor
    func testRepeatedHistoryMergesCorrectionsAndKeepsRingsSeparate() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredReading.self, configurations: configuration)
        let store = RingStore(container: container)
        let date = Date(timeIntervalSince1970: 1_783_000_000)
        let first = RingReading(metric: .heartRate, value: 72, date: date)
        let corrected = RingReading(metric: .heartRate, value: 73, date: date)
        try store.save([first, first], ringID: "A")
        try store.save([corrected], ringID: "A")
        try store.save([first], ringID: "B")
        let readings = try container.mainContext.fetch(FetchDescriptor<StoredReading>())
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings.first(where: { $0.ringID == "A" })?.value, 73)
        XCTAssertEqual(readings.first(where: { $0.ringID == "B" })?.value, 72)
    }
    @MainActor
    func testActivitySnapshotsMergeWithinMinuteAndKeepTimestampMeaning() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredReading.self, configurations: configuration)
        let store = RingStore(container: container)
        let date = Date(timeIntervalSince1970: 1_783_000_020)
        try store.save([
            RingReading(metric: .steps, value: 100, date: date, isObservationTime: true),
            RingReading(metric: .steps, value: 110, date: date.addingTimeInterval(10), isObservationTime: true),
            RingReading(metric: .steps, value: 120, date: date.addingTimeInterval(60), isObservationTime: true)
        ], ringID: "A")
        let readings = try container.mainContext.fetch(FetchDescriptor<StoredReading>())
        XCTAssertEqual(readings.count, 2)
        XCTAssertTrue(readings.allSatisfy(\.isObservationTime))
        XCTAssertEqual(Set(readings.map(\.value)), [110, 120])
    }
}
