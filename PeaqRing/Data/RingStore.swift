import Foundation
import SwiftData
import Security

@Model
final class StoredReading {
    @Attribute(.unique) var key: String
    var ringID: String
    var metricName: String
    var value: Double
    var date: Date
    var isObservationTime: Bool
    init(_ reading: RingReading, ringID: String) {
        key = reading.storageKey(ringID: ringID)
        self.ringID = ringID
        metricName = reading.metric.rawValue
        value = reading.value
        date = reading.date
        isObservationTime = reading.isObservationTime
    }
}

@Model
final class StoredSleepSegment {
    @Attribute(.unique) var key: String
    var ringID: String
    var start: Date
    var end: Date
    var stageCode: Int
    static let recordedClockMarker = "|sleep-clock|"

    static func key(for segment: RingSleepSegment, ringID: String) -> String {
        let marker = segment.recordedClock == true ? recordedClockMarker : "|sleep|"
        return "\(ringID)\(marker)\(segment.start.timeIntervalSince1970)"
    }

    init(_ segment: RingSleepSegment, ringID: String) {
        key = Self.key(for: segment, ringID: ringID)
        self.ringID = ringID; start = segment.start; end = segment.end; stageCode = segment.stage.rawValue
    }
}

@Model
final class StoredWorkout {
    @Attribute(.unique) var key: String
    var ringID: String
    var start: Date
    var end: Date
    var typeCode: Int?
    var steps: Int
    var calories: Double
    var distanceMetres: Double?
    var averageHeartRate: Int?
    init(_ workout: RingWorkout, ringID: String) {
        key = "\(ringID)|workout|\(workout.start.timeIntervalSince1970)|\(workout.typeCode ?? -1)"
        self.ringID = ringID; start = workout.start; end = workout.end
        typeCode = workout.typeCode; steps = workout.steps; calories = workout.calories
        distanceMetres = workout.distanceMetres; averageHeartRate = workout.averageHeartRate
    }
}

@MainActor
final class RingStore {
    static private(set) var shared = Result { try RingStore() }

    static func retryOpening() -> Result<RingStore, Error> {
        if case .failure = shared { shared = Result { try RingStore() } }
        return shared
    }
    let container: ModelContainer
    private init() throws {
        container = try ModelContainer(for: RingDatabaseSchema.make())
        try? migrateConfirmedPAI()
    }
    init(container: ModelContainer) { self.container = container }
    /// Reclassify the preserved C8 records after the original-app comparison.
    /// Updating the stored metric also changes its deduplication key; existing
    /// PAI records take precedence, so repeat launches cannot create duplicates.
    func migrateConfirmedPAI() throws {
        let context = container.mainContext
        let oldName = RingMetric.dailyIndexB.rawValue
        let oldRecords = try context.fetch(FetchDescriptor<StoredReading>(predicate: #Predicate { $0.metricName == oldName }))
        for record in oldRecords {
            let reading = RingReading(metric: .pai, value: record.value, date: record.date, isObservationTime: record.isObservationTime)
            let key = reading.storageKey(ringID: record.ringID)
            let existing = try context.fetch(FetchDescriptor<StoredReading>(predicate: #Predicate { $0.key == key })).first
            if existing != nil { context.delete(record) }
            else { record.key = key; record.metricName = RingMetric.pai.rawValue }
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }
    func saveExtended(sleep: [RingSleepSegment], workouts: [RingWorkout], ringID: String) throws {
        try RingHistoryPersistence.save(readings: [], sleep: sleep, workouts: workouts, ringID: ringID, context: container.mainContext)
    }
    func save(_ readings: [RingReading], ringID: String) throws {
        try RingHistoryPersistence.save(readings: readings, sleep: [], workouts: [], ringID: ringID, context: container.mainContext)
    }

}

enum RingDatabaseSchema {
    static func make() -> Schema {
        let schema = Schema([StoredReading.self, StoredSleepSegment.self, StoredWorkout.self])
        // Use the supported schema API at runtime so iOS 17 remains supported.
        // Attributes and unique keys stay identical; adding indexes permits
        // SwiftData's automatic lightweight migration of the existing store.
        if #available(iOS 18, *) {
            // Entity.indices uses the same kind-prefixed representation emitted
            // by #Index and Schema.Index's Codable metadata.
            schema.entitiesByName["StoredReading"]?.indices = [["binary", "ringID", "metricName", "date"]]
            schema.entitiesByName["StoredSleepSegment"]?.indices = [["binary", "ringID", "start"]]
            schema.entitiesByName["StoredWorkout"]?.indices = [["binary", "ringID", "start"]]
        }
        return schema
    }
}

struct RingImportChanges: Sendable {
    var readings: Set<String> = []
    var sleepDays: Set<Date> = []
    var workouts: Set<String> = []

    var isEmpty: Bool { readings.isEmpty && sleepDays.isEmpty && workouts.isEmpty }

    mutating func merge(_ batch: Self) {
        readings.formUnion(batch.readings)
        sleepDays.formUnion(batch.sleepDays)
        workouts.formUnion(batch.workouts)
    }
}

struct RingSyncEntry: Codable, Identifiable {
    enum Outcome: String, Codable {
        case imported, noChanges, noResponse, storageFailure, connectionFailure, interrupted, credentials

        var successful: Bool { self == .imported || self == .noChanges }
        var title: String {
            switch self {
            case .imported: return "Sync complete"
            case .noChanges: return "No new readings"
            case .interrupted: return "Sync interrupted"
            default: return "Couldn’t sync"
            }
        }
    }

    let id: UUID
    let date: Date
    let outcome: Outcome
    let readings: Int
    let sleepDays: Int
    let workouts: Int

    init(outcome: Outcome, changes: RingImportChanges = RingImportChanges(), date: Date = Date()) {
        id = UUID()
        self.date = date
        self.outcome = outcome
        readings = changes.readings.count
        sleepDays = changes.sleepDays.count
        workouts = changes.workouts.count
    }

    var detail: String {
        switch outcome {
        case .imported:
            var saved: [String] = []
            if sleepDays > 0 { saved.append(sleepDays == 1 ? "1 sleep day" : "\(sleepDays) sleep days") }
            if readings > 0 { saved.append(readings == 1 ? "1 reading" : "\(readings) readings") }
            if workouts > 0 { saved.append(workouts == 1 ? "1 workout" : "\(workouts) workouts") }
            return "\(saved.formatted(.list(type: .and))) saved"
        case .noChanges: return "The ring returned readings already saved on your iPhone."
        case .noResponse: return "No usable history came back from the ring. Try syncing again."
        case .storageFailure: return "Some readings couldn’t be saved. Check available iPhone storage and try again."
        case .connectionFailure: return "Check the connection in My Ring and try again."
        case .interrupted: return "Readings already saved are kept."
        case .credentials: return "The saved connection credentials couldn’t be used."
        }
    }

    static func load(ringID: String, defaults: UserDefaults = .standard) -> [Self] {
        guard !ringID.isEmpty, let data = defaults.data(forKey: "syncHistory.\(ringID)") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    static func record(_ entry: Self, ringID: String, defaults: UserDefaults = .standard) -> [Self] {
        guard !ringID.isEmpty else { return [] }
        let entries = [entry] + load(ringID: ringID, defaults: defaults).prefix(29)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: "syncHistory.\(ringID)")
        }
        return entries
    }
}

struct RingDataFreshness: Sendable {
    let sleepDay: Date?
    let activity: Date?
    let heart: Date?
}

/// Bounded, indexed key lookups and one commit per batch. Unchanged history causes
/// no writes, avoiding repeated query invalidation on every automatic sync.
enum RingHistoryPersistence {
    @discardableResult
    static func save(readings: [RingReading], sleep: [RingSleepSegment], workouts: [RingWorkout], ringID: String, context: ModelContext) throws -> Bool {
        try saveBatch(readings: readings, sleep: sleep, workouts: workouts, ringID: ringID, context: context).changed
    }

    static func saveBatch(readings: [RingReading], sleep: [RingSleepSegment], workouts: [RingWorkout], ringID: String,
                          context: ModelContext) throws -> (changed: Bool, imports: RingImportChanges) {
        var imports = RingImportChanges()
        do {
            for offset in stride(from: 0, to: readings.count, by: 400) {
                let batch = readings[offset..<min(offset + 400, readings.count)]
                let keys = batch.map { $0.storageKey(ringID: ringID) }
                let records = try context.fetch(FetchDescriptor<StoredReading>(predicate: #Predicate { keys.contains($0.key) }))
                var existing = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                for reading in batch {
                    let key = reading.storageKey(ringID: ringID)
                    if let record = existing[key] {
                        guard record.value != reading.value else { continue }
                        record.value = reading.value
                    } else {
                        let record = StoredReading(reading, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
                    imports.readings.insert(key)
                }
            }
            for offset in stride(from: 0, to: sleep.count, by: 400) {
                let batch = sleep[offset..<min(offset + 400, sleep.count)]
                let keys = batch.map { StoredSleepSegment.key(for: $0, ringID: ringID) }
                let records = try context.fetch(FetchDescriptor<StoredSleepSegment>(predicate: #Predicate { keys.contains($0.key) }))
                var existing = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                for segment in batch {
                    let key = StoredSleepSegment.key(for: segment, ringID: ringID)
                    if let record = existing[key] {
                        guard record.end != segment.end || record.stageCode != segment.stage.rawValue else { continue }
                        record.end = segment.end
                        record.stageCode = segment.stage.rawValue
                    } else {
                        let record = StoredSleepSegment(segment, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
                    imports.sleepDays.insert(RingSnapshotLoader.sleepDay(for: segment))
                }
            }
            for offset in stride(from: 0, to: workouts.count, by: 400) {
                let batch = workouts[offset..<min(offset + 400, workouts.count)]
                let keys = batch.map { "\(ringID)|workout|\($0.start.timeIntervalSince1970)|\($0.typeCode ?? -1)" }
                let records = try context.fetch(FetchDescriptor<StoredWorkout>(predicate: #Predicate { keys.contains($0.key) }))
                var existing = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                for workout in batch {
                    let key = "\(ringID)|workout|\(workout.start.timeIntervalSince1970)|\(workout.typeCode ?? -1)"
                    if let record = existing[key] {
                        guard record.end != workout.end || record.steps != workout.steps || record.calories != workout.calories ||
                              record.distanceMetres != workout.distanceMetres || record.averageHeartRate != workout.averageHeartRate else { continue }
                        record.end = workout.end
                        record.steps = workout.steps
                        record.calories = workout.calories
                        record.distanceMetres = workout.distanceMetres
                        record.averageHeartRate = workout.averageHeartRate
                    } else {
                        let record = StoredWorkout(workout, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
                    imports.workouts.insert(key)
                }
            }
            guard context.hasChanges else { return (false, RingImportChanges()) }
            try context.save()
            return (true, imports)
        } catch { context.rollback(); throw error }
    }
}

struct RingDashboardSnapshot: Sendable {
    let latest: [RingMetric: RingReading]
    let readings: [RingReading]
    let sourceCount: Int
    let hrvBaseline: HRVBaseline
}
struct RingInsightsSnapshot: Sendable {
    let sleep: [RingSleepSegment]
    let workouts: [RingWorkout]
    let pai: [RingReading]
}

struct RingSleepNightSummary: Sendable {
    let asleepDuration: TimeInterval
    // Ring clock offsets from midnight on the wake-up date. The previous
    // evening is negative, so the chart can use a continuous overnight axis.
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let usesLocalClock: Bool
}

enum RingSnapshotLoader {
    /// At most one indexed existence lookup per past/current day in the visible
    /// month. No full-history scan and no health values cross into the picker.
    static func availableDashboardDays(container: ModelContainer, ringID: String, month: Date, now: Date = Date(), calendar: Calendar = .current) async throws -> Set<Date> {
        let task = Task.detached(priority: .utility) {
            guard !ringID.isEmpty, let interval = calendar.dateInterval(of: .month, for: month) else { return Set<Date>() }
            let context = ModelContext(container)
            let names = RingMetric.dashboardMetrics.map(\.rawValue)
            var day = interval.start, available: Set<Date> = []
            while day < interval.end && day <= now {
                try Task.checkCancellation()
                let start = day, end = calendar.date(byAdding: .day, value: 1, to: day)!
                var request = FetchDescriptor<StoredReading>(predicate: #Predicate {
                    $0.ringID == ringID && names.contains($0.metricName) && $0.date >= start && $0.date < end && $0.date <= now
                })
                request.fetchLimit = 1
                request.propertiesToFetch = [\.date]
                if try !context.fetch(request).isEmpty { available.insert(start) }
                day = end
            }
            return available
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func recordedClockCalendar(_ calendar: Calendar = .current) -> Calendar {
        var clock = calendar
        clock.timeZone = TimeZone(secondsFromGMT: 0)!
        return clock
    }

    static func recordedClockDate(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        return recordedClockCalendar(calendar).date(from: parts)!
    }

    // The ring groups sleep from 19:00 to 19:00, labeled by the second date.
    static func sleepDay(for segment: RingSleepSegment, calendar: Calendar = .current) -> Date {
        sleepDay(forStart: segment.start, recordedClock: segment.recordedClock == true, calendar: calendar)
    }

    private static func sleepDay(forStart start: Date, recordedClock: Bool, calendar: Calendar) -> Date {
        let clock = recordedClock ? recordedClockCalendar(calendar) : calendar
        var day = clock.startOfDay(for: start)
        if clock.component(.hour, from: start) >= 19 { day = clock.date(byAdding: .day, value: 1, to: day)! }
        if !recordedClock { return day }
        let parts = clock.dateComponents([.era, .year, .month, .day], from: day)
        return calendar.startOfDay(for: calendar.date(from: parts)!)
    }

    private static func sleepRecordsByDay(context: ModelContext, ringID: String, from firstDay: Date, through lastDay: Date,
                                          calendar: Calendar) throws -> [Date: [RingSleepSegment]] {
        let previousDay = calendar.date(byAdding: .day, value: -1, to: firstDay)!
        let localStart = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: previousDay)!
        let localEnd = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: lastDay)!
        let start = min(localStart, recordedClockDate(localStart, calendar: calendar))
        let end = max(localEnd, recordedClockDate(localEnd, calendar: calendar))
        let request = FetchDescriptor<StoredSleepSegment>(predicate: #Predicate {
            $0.ringID == ringID && $0.start >= start && $0.start < end && $0.end <= end
        }, sortBy: [SortDescriptor(\.start)])
        var days: [Date: [RingSleepSegment]] = [:]
        for record in try context.fetch(request) {
            try Task.checkCancellation()
            guard record.end > record.start, let stage = RingSleepStage(rawValue: record.stageCode) else { continue }
            let recordedClock = record.key.contains(StoredSleepSegment.recordedClockMarker)
            let segment = RingSleepSegment(start: record.start, end: record.end, stage: stage, recordedClock: recordedClock ? true : nil)
            let day = sleepDay(for: segment, calendar: calendar)
            guard day >= firstDay && day <= lastDay else { continue }
            let localCutoff = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day)!
            let cutoff = recordedClock ? recordedClockDate(localCutoff, calendar: calendar) : localCutoff
            if record.end <= cutoff { days[day, default: []].append(segment) }
        }
        return days.mapValues { reconcileSleep($0, calendar: calendar) }
    }

    private static func reconcileSleep(_ segments: [RingSleepSegment], calendar: Calendar) -> [RingSleepSegment] {
        let recorded = segments.filter { $0.recordedClock == true }
        let legacy = sleepRuns(segments.filter { $0.recordedClock != true }).flatMap(removeShiftedSleepCopy)
        guard !recorded.isEmpty else { return legacy }
        guard !legacy.isEmpty else { return recorded }
        var result = recorded
        let recordedByStart = Dictionary(uniqueKeysWithValues: recorded.map { ($0.start, $0) })
        for run in sleepRuns(legacy) {
            let clockStart = recordedClockDate(run[0].start, calendar: calendar)
            let clockEnd = recordedClockDate(run.last!.end, calendar: calendar)
            let hasDistinctStages = run.count >= 3 && Set(run.map(\.stage)).count > 1
            let matchesRecorded = recorded.contains { candidate in
                let offset = candidate.start.timeIntervalSince(clockStart)
                guard candidate.stage == run[0].stage, candidate.duration == run[0].duration,
                      offset == 0 || hasDistinctStages,
                      candidate.start < clockEnd,
                      candidate.start.addingTimeInterval(run.last!.end.timeIntervalSince(run[0].start)) > clockStart else { return false }
                return run.allSatisfy { segment in
                    let start = recordedClockDate(segment.start, calendar: calendar).addingTimeInterval(offset)
                    guard let match = recordedByStart[start] else { return false }
                    return match.stage == segment.stage && match.duration == segment.duration
                }
            }
            if !matchesRecorded {
                result.append(contentsOf: run.filter { segment in
                    let clockStart = recordedClockDate(segment.start, calendar: calendar)
                    guard let match = recordedByStart[clockStart] else { return true }
                    return match.stage != segment.stage || match.duration != segment.duration
                })
            }
        }
        return result.sorted {
            let first = $0.recordedClock == true ? $0.start : recordedClockDate($0.start, calendar: calendar)
            let second = $1.recordedClock == true ? $1.start : recordedClockDate($1.start, calendar: calendar)
            return first < second
        }
    }

    private static func sleepRuns(_ segments: [RingSleepSegment]) -> [[RingSleepSegment]] {
        var groups: [[RingSleepSegment]] = []
        var end = Date.distantPast
        for segment in segments {
            if segment.start > end || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(segment)
            end = max(end, segment.end)
        }
        return groups
    }

    // Old imports have no source time zone. Suppress only a complete second
    // copy of a stage sequence, leaving uncertain overlaps and naps intact.
    private static func removeShiftedSleepCopy(_ group: [RingSleepSegment]) -> [RingSleepSegment] {
        guard group.count >= 6, group.count.isMultiple(of: 2) else { return group }
        let first = group[0]
        let byStart = Dictionary(uniqueKeysWithValues: group.map { ($0.start, $0) })
        for candidate in group.dropFirst() where candidate.stage == first.stage && candidate.duration == first.duration {
            let offset = candidate.start.timeIntervalSince(first.start)
            guard offset >= 60, offset.truncatingRemainder(dividingBy: 60) == 0 else { continue }
            var remaining = byStart
            var original: [RingSleepSegment] = []
            for segment in group where remaining[segment.start] != nil {
                let shifted = segment.start.addingTimeInterval(offset)
                guard let match = remaining[shifted], match.stage == segment.stage, match.duration == segment.duration,
                      original.last.map({ $0.end <= segment.start }) ?? true else { break }
                remaining.removeValue(forKey: segment.start)
                remaining.removeValue(forKey: shifted)
                original.append(segment)
            }
            if remaining.isEmpty, let last = original.last, last.end > candidate.start,
               Set(original.map(\.stage)).count > 1 {
                return original
            }
        }
        return group
    }

    static func sleepNight(container: ModelContainer, ringID: String, day: Date, calendar: Calendar = .current) async throws -> [RingSleepSegment] {
        let task = Task.detached(priority: .utility) {
            try sleepRecordsByDay(context: ModelContext(container), ringID: ringID, from: day, through: day, calendar: calendar)[day] ?? []
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func sleepTotals(container: ModelContainer, ringID: String, from firstDay: Date, through lastDay: Date,
                            calendar: Calendar = .current) async throws -> [Date: TimeInterval] {
        let task = Task.detached(priority: .utility) {
            let records = try sleepRecordsByDay(context: ModelContext(container), ringID: ringID, from: firstDay,
                                                through: lastDay, calendar: calendar)
            var totals: [Date: TimeInterval] = [:]
            for (day, segments) in records {
                try Task.checkCancellation()
                let asleep = segments.filter { $0.stage != .awake }.reduce(0) { $0 + $1.duration }
                if asleep > 0 { totals[day] = asleep }
            }
            return totals
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func sleepNightSummaries(container: ModelContainer, ringID: String, from firstDay: Date, through lastDay: Date,
                                     calendar: Calendar = .current) async throws -> [Date: RingSleepNightSummary] {
        let task = Task.detached(priority: .utility) {
            let records = try sleepRecordsByDay(context: ModelContext(container), ringID: ringID, from: firstDay,
                                                through: lastDay, calendar: calendar)
            let clock = recordedClockCalendar(calendar)
            var summaries: [Date: RingSleepNightSummary] = [:]
            for (day, segments) in records {
                try Task.checkCancellation()
                let midnight = clock.startOfDay(for: recordedClockDate(day, calendar: calendar))
                var start = Date.distantFuture
                var end = Date.distantPast
                var duration: TimeInterval = 0
                var usesLocalClock = false
                for segment in segments where segment.stage != .awake {
                    duration += segment.duration
                    if segment.recordedClock == true {
                        start = min(start, segment.start)
                        end = max(end, segment.end)
                    } else {
                        usesLocalClock = true
                        let localStart = recordedClockDate(segment.start, calendar: calendar)
                        let localEnd = recordedClockDate(segment.end, calendar: calendar)
                        start = min(start, localStart, localEnd)
                        end = max(end, localStart, localEnd)
                    }
                }
                if duration > 0 {
                    summaries[day] = RingSleepNightSummary(asleepDuration: duration, startOffset: start.timeIntervalSince(midnight),
                        endOffset: end.timeIntervalSince(midnight), usesLocalClock: usesLocalClock)
                }
            }
            return summaries
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func latestSleepDay(context: ModelContext, ringID: String, calendar: Calendar) throws -> Date? {
        let clockMarker = StoredSleepSegment.recordedClockMarker
        var latestDays: [Date] = []
        // Absolute legacy dates and encoded clock dates cannot be ordered
        // together until each is assigned to its recorded day.
        for recordedClock in [false, true] {
            var recent = FetchDescriptor<StoredSleepSegment>(predicate: #Predicate {
                $0.ringID == ringID && $0.stageCode != 0 && $0.key.contains(clockMarker) == recordedClock
            }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            recent.fetchLimit = 1
            if let last = try context.fetch(recent).first {
                latestDays.append(sleepDay(forStart: last.start, recordedClock: recordedClock, calendar: calendar))
            }
        }
        return latestDays.max()
    }

    static func freshness(container: ModelContainer, ringID: String, calendar: Calendar = .current) async throws -> RingDataFreshness {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            func latest(_ metrics: [RingMetric]) throws -> Date? {
                var dates: [Date] = []
                for metric in metrics {
                    try Task.checkCancellation()
                    let name = metric.rawValue
                    var request = FetchDescriptor<StoredReading>(predicate: #Predicate {
                        $0.ringID == ringID && $0.metricName == name
                    }, sortBy: [SortDescriptor(\.date, order: .reverse)])
                    request.fetchLimit = 1
                    if let date = try context.fetch(request).first?.date { dates.append(date) }
                }
                return dates.max()
            }

            return RingDataFreshness(sleepDay: try latestSleepDay(context: context, ringID: ringID, calendar: calendar),
                activity: try latest([.steps, .calories, .distance]), heart: try latest([.heartRate, .hrv]))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func insights(container: ModelContainer, ringID: String, calendar: Calendar = .current) async throws -> RingInsightsSnapshot {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var sleep: [RingSleepSegment] = []
            if let day = try latestSleepDay(context: context, ringID: ringID, calendar: calendar) {
                sleep = try sleepRecordsByDay(context: context, ringID: ringID, from: day, through: day, calendar: calendar)[day] ?? []
            }
            var recentWorkouts = FetchDescriptor<StoredWorkout>(predicate: #Predicate { $0.ringID == ringID }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            recentWorkouts.fetchLimit = 20
            let workouts = try context.fetch(recentWorkouts)
            var recentPAI = FetchDescriptor<StoredReading>(predicate: #Predicate { $0.ringID == ringID && $0.metricName == "pai" }, sortBy: [SortDescriptor(\.date, order: .reverse)])
            recentPAI.fetchLimit = 14
            let pai = try context.fetch(recentPAI)
            return RingInsightsSnapshot(
                sleep: sleep,
                workouts: workouts.map { RingWorkout(start: $0.start, end: $0.end, typeCode: $0.typeCode, steps: $0.steps, calories: $0.calories, distanceMetres: $0.distanceMetres, averageHeartRate: $0.averageHeartRate) },
                pai: pai.map { RingReading(metric: .pai, value: $0.value, date: $0.date) })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    static func dashboard(container: ModelContainer, ringID: String, metric: RingMetric = .heartRate, days: Int = 1, selectedDay: Date? = nil, now: Date = Date(), calendar: Calendar = .current) async throws -> RingDashboardSnapshot {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let window = RingHistoryWindow(selectedDay: selectedDay, days: days, now: now, calendar: calendar)
            let dayStart = window.dayStart, nextDay = window.nextDay
            var latest: [RingMetric: RingReading] = [:]
            for metric in RingMetric.dashboardMetrics {
                try Task.checkCancellation()
                let name = metric.rawValue
                var request = FetchDescriptor<StoredReading>(predicate: #Predicate { $0.ringID == ringID && $0.metricName == name && $0.date >= dayStart && $0.date < nextDay && $0.date <= now }, sortBy: [SortDescriptor(\.date, order: .reverse)])
                request.fetchLimit = 1
                if let record = try context.fetch(request).first {
                    latest[metric] = RingReading(metric: metric, value: record.value, date: record.date, isObservationTime: record.isObservationTime)
                }
            }
            let windowDays = window.days
            let start = window.trendStart, end = window.chartEnd
            let name = metric.rawValue
            let request = FetchDescriptor<StoredReading>(predicate: #Predicate { $0.ringID == ringID && $0.metricName == name && $0.date >= start && $0.date < nextDay && $0.date <= now }, sortBy: [SortDescriptor(\.date)])
            var averages = RingChartAverager(metric: metric, start: start, end: end, calendar: calendar, interval: windowDays == 1 ? .hour : .day)
            try context.enumerate(request, batchSize: 500) { record in
                try Task.checkCancellation()
                let reading = RingReading(metric: metric, value: record.value, date: record.date, isObservationTime: record.isObservationTime)
                averages.append(reading)
            }
            let baselineEnd = dayStart
            let baselineStart = calendar.date(byAdding: .day, value: -28, to: baselineEnd)!
            let hrvRequest = FetchDescriptor<StoredReading>(predicate: #Predicate { $0.ringID == ringID && $0.metricName == "hrv" && !$0.isObservationTime && $0.date >= baselineStart && $0.date < baselineEnd })
            var hrv: [RingReading] = []
            try context.enumerate(hrvRequest, batchSize: 500) { record in
                try Task.checkCancellation()
                hrv.append(RingReading(metric: .hrv, value: record.value, date: record.date))
            }
            return RingDashboardSnapshot(latest: latest, readings: averages.readings, sourceCount: averages.sourceCount,
                hrvBaseline: HRVBaseline(readings: hrv, before: dayStart, calendar: calendar))
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}

struct RingHistoryUpdate: Sendable {
    let sessionID: UUID
    let ringID: String
    var notifications = 0
    var decoded = 0
    var saved = 0
    var imports = RingImportChanges()
    var metricCounts: [String: Int] = [:]
    var rejectedFrames = 0
    var battery: Int?
    var firmwareVersion: String?
    var bluetoothAddress: String?
    var changed = false
    var storageFailed = false
    var blockMessages: [String] = []
}

/// The decoder and SwiftData context are confined to this serial
/// utility queue. Bluetooth objects and SwiftUI state never cross onto it.
final class RingHistoryWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.peaqring.history", qos: .utility)
    private let container: ModelContainer
    private let onUpdate: @MainActor (RingHistoryUpdate) -> Void
    private var decoder = RingDecoder()
    private var update: RingHistoryUpdate?
    private var readings: [RingReading] = []
    private var sleep: [RingSleepSegment] = []
    private var workouts: [RingWorkout] = []
    private var drainID: UUID?
    init(container: ModelContainer, onUpdate: @escaping @MainActor (RingHistoryUpdate) -> Void) {
        self.container = container; self.onUpdate = onUpdate
    }
    func beginSession(_ id: UUID, ringID: String) {
        queue.async {
            self.flushPending()
            self.decoder.reset()
            self.update = RingHistoryUpdate(sessionID: id, ringID: ringID)
        }
    }
    func enqueue(_ data: Data, sessionID: UUID) {
        queue.async {
            guard self.update?.sessionID == sessionID else { return }
            let decoded = self.decoder.ingest(data)
            let blocks = self.decoder.receivedBlocks
            let sleep = blocks.flatMap { RingExtendedHistory.recordedSleep($0) }
            let workouts = blocks.flatMap { RingExtendedHistory.workouts($0) }
            self.readings += decoded
            self.sleep += sleep; self.workouts += workouts
            self.update!.notifications += 1
            self.update!.decoded += decoded.count + sleep.count + workouts.count
            self.update!.rejectedFrames = self.decoder.rejectedFrames
            if let status = self.decoder.batteryStatus { self.update!.battery = status.percent }
            if let version = self.decoder.firmwareVersion { self.update!.firmwareVersion = version }
            if let address = self.decoder.bluetoothAddress { self.update!.bluetoothAddress = address }
            if let message = self.decoder.identityResponseDescription { self.update!.blockMessages.append(message) }
            for reading in decoded { self.update!.metricCounts[reading.metric.rawValue, default: 0] += 1 }
            for block in blocks {
                self.update!.blockMessages.append(String(format: "History block sub=0x%02X payload=%d bytes", block.subcommand, block.payload.count))
            }
            if self.readings.count + self.sleep.count + self.workouts.count >= 500 {
                self.flushPending()
                return
            }
            if self.drainID == nil {
                let id = UUID(); self.drainID = id
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    guard self.drainID == id else { return }
                    self.flushPending()
                }
            }
        }
    }
    /// Barrier: progress is published before the sync task can report success.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.flushPending()
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    private func flushPending() {
        dispatchPrecondition(condition: .onQueue(queue))
        drainID = nil
        guard var result = update, result.notifications > 0 else { return }
        do {
            // Release registered objects after each transaction rather than
            // keeping a long-lived context as the history grows.
            let context = ModelContext(container); context.autosaveEnabled = false
            let batch = try RingHistoryPersistence.saveBatch(readings: readings, sleep: sleep, workouts: workouts,
                ringID: result.ringID, context: context)
            result.changed = batch.changed
            result.imports = batch.imports
            result.saved = readings.count + sleep.count + workouts.count
        } catch { result.storageFailed = true }
        readings.removeAll(keepingCapacity: true)
        sleep.removeAll(keepingCapacity: true); workouts.removeAll(keepingCapacity: true)
        update = RingHistoryUpdate(sessionID: result.sessionID, ringID: result.ringID)
        DispatchQueue.main.async { self.onUpdate(result) }
    }
}

enum TokenVault {
    private static let service = "com.peaqring.session"
    static func read(ringID: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: ringID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, ringID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: ringID]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.failed(status) }
            return
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw VaultError.failed(added) }
        } else if status != errSecSuccess { throw VaultError.failed(status) }
    }
    enum VaultError: LocalizedError {
        case failed(OSStatus)
        var errorDescription: String? { "The session token could not be saved securely. Try again while the phone is unlocked." }
    }
}
