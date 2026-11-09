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
    init(_ segment: RingSleepSegment, ringID: String) {
        key = "\(ringID)|sleep|\(segment.start.timeIntervalSince1970)"
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

/// Bounded, indexed key lookups and one commit per batch. Unchanged history causes
/// no writes, avoiding repeated query invalidation on every automatic sync.
enum RingHistoryPersistence {
    @discardableResult
    static func save(readings: [RingReading], sleep: [RingSleepSegment], workouts: [RingWorkout], ringID: String, context: ModelContext) throws -> Bool {
        do {
            for offset in stride(from: 0, to: readings.count, by: 400) {
                let batch = readings[offset..<min(offset + 400, readings.count)]
                let keys = batch.map { $0.storageKey(ringID: ringID) }
                let records = try context.fetch(FetchDescriptor<StoredReading>(predicate: #Predicate { keys.contains($0.key) }))
                var existing = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                for reading in batch {
                    let key = reading.storageKey(ringID: ringID)
                    if let record = existing[key] {
                        if record.value != reading.value { record.value = reading.value }
                    } else {
                        let record = StoredReading(reading, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
                }
            }
            for offset in stride(from: 0, to: sleep.count, by: 400) {
                let batch = sleep[offset..<min(offset + 400, sleep.count)]
                let keys = batch.map { "\(ringID)|sleep|\($0.start.timeIntervalSince1970)" }
                let records = try context.fetch(FetchDescriptor<StoredSleepSegment>(predicate: #Predicate { keys.contains($0.key) }))
                var existing = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                for segment in batch {
                    let key = "\(ringID)|sleep|\(segment.start.timeIntervalSince1970)"
                    if let record = existing[key] {
                        if record.end != segment.end { record.end = segment.end }
                        if record.stageCode != segment.stage.rawValue { record.stageCode = segment.stage.rawValue }
                    } else {
                        let record = StoredSleepSegment(segment, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
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
                        if record.end != workout.end { record.end = workout.end }
                        if record.steps != workout.steps { record.steps = workout.steps }
                        if record.calories != workout.calories { record.calories = workout.calories }
                        if record.distanceMetres != workout.distanceMetres { record.distanceMetres = workout.distanceMetres }
                        if record.averageHeartRate != workout.averageHeartRate { record.averageHeartRate = workout.averageHeartRate }
                    } else {
                        let record = StoredWorkout(workout, ringID: ringID)
                        context.insert(record); existing[key] = record
                    }
                }
            }
            guard context.hasChanges else { return false }
            try context.save()
            return true
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
    static func insights(container: ModelContainer, ringID: String, calendar: Calendar = .current) async throws -> RingInsightsSnapshot {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var recentSleep = FetchDescriptor<StoredSleepSegment>(predicate: #Predicate { $0.ringID == ringID && $0.stageCode != 0 }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            recentSleep.fetchLimit = 1
            var sleepRecords: [StoredSleepSegment] = []
            if let last = try context.fetch(recentSleep).first {
                var day = calendar.startOfDay(for: last.end)
                if calendar.component(.hour, from: last.end) >= 19 { day = calendar.date(byAdding: .day, value: 1, to: day)! }
                let end = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day)!
                let start = calendar.date(byAdding: .day, value: -1, to: end)!
                sleepRecords = try context.fetch(FetchDescriptor<StoredSleepSegment>(predicate: #Predicate { $0.ringID == ringID && $0.start >= start && $0.start <= end && $0.end <= end }, sortBy: [SortDescriptor(\.start)]))
            }
            var recentWorkouts = FetchDescriptor<StoredWorkout>(predicate: #Predicate { $0.ringID == ringID }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            recentWorkouts.fetchLimit = 20
            let workouts = try context.fetch(recentWorkouts)
            var recentPAI = FetchDescriptor<StoredReading>(predicate: #Predicate { $0.ringID == ringID && $0.metricName == "pai" }, sortBy: [SortDescriptor(\.date, order: .reverse)])
            recentPAI.fetchLimit = 14
            let pai = try context.fetch(recentPAI)
            return RingInsightsSnapshot(
                sleep: sleepRecords.compactMap { record in
                    guard let stage = RingSleepStage(rawValue: record.stageCode) else { return nil }
                    return RingSleepSegment(start: record.start, end: record.end, stage: stage)
                },
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
            let sleep = blocks.flatMap { RingExtendedHistory.sleep($0) }
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
            result.changed = try RingHistoryPersistence.save(readings: readings, sleep: sleep, workouts: workouts, ringID: result.ringID, context: context)
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
