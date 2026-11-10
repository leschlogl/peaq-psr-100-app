import Foundation
import SwiftData

struct WeeklyReviewPeriod: Equatable, Sendable {
    let start: Date
    let end: Date
    let previousStart: Date

    init(weeksBack: Int = 0, now: Date = Date(), calendar: Calendar = .current) {
        let currentStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        end = calendar.date(byAdding: .weekOfYear, value: -max(0, weeksBack), to: currentStart)!
        start = calendar.date(byAdding: .weekOfYear, value: -1, to: end)!
        previousStart = calendar.date(byAdding: .weekOfYear, value: -1, to: start)!
    }
}

struct WeeklyReviewWeek: Sendable {
    let days: [Date]
    let sleep: [Date: TimeInterval]
    let readings: [RingMetric: [Date: Double]]
    let workoutCount: Int

    var hasData: Bool { !sleep.isEmpty || !readings.isEmpty || workoutCount > 0 }

    func goalDays(_ metric: RingMetric, target: Double) -> (met: Int, recorded: Int) {
        let values = readings[metric]?.values
        return (values?.filter { $0 >= target }.count ?? 0, values?.count ?? 0)
    }
}

struct WeeklyReviewSnapshot: Sendable {
    let current: WeeklyReviewWeek
    let previous: WeeklyReviewWeek
}

enum WeeklyReviewLoader {
    static func load(container: ModelContainer, ringID: String, period: WeeklyReviewPeriod,
                     calendar: Calendar = .current) async throws -> WeeklyReviewSnapshot {
        async let sleep = RingSnapshotLoader.sleepTotals(container: container, ringID: ringID,
            from: period.previousStart, through: calendar.date(byAdding: .day, value: -1, to: period.end)!,
            calendar: calendar)
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let from = period.previousStart, to = period.end
            var readings: [RingMetric: [Date: Double]] = [:]
            for metric in [RingMetric.steps, .calories, .distance, .heartRate, .hrv] {
                try Task.checkCancellation()
                let metricName = metric.rawValue
                let request = FetchDescriptor<StoredReading>(predicate: #Predicate {
                    $0.ringID == ringID && $0.metricName == metricName && $0.date >= from && $0.date < to
                }, sortBy: [SortDescriptor(\.date)])
                switch metric {
                case .steps, .calories, .distance:
                    // These are cumulative snapshots. Use the day's latest value,
                    // including an observed zero, rather than summing the snapshots.
                    var daily: [Date: Double] = [:]
                    try context.enumerate(request, batchSize: 500) { record in
                        try Task.checkCancellation()
                        guard metric.accepts(record.value) else { return }
                        daily[calendar.startOfDay(for: record.date)] = record.value
                    }
                    if !daily.isEmpty { readings[metric] = daily }
                default:
                    var averages = RingChartAverager(metric: metric, start: from, end: to, calendar: calendar)
                    try context.enumerate(request, batchSize: 500) { record in
                        try Task.checkCancellation()
                        guard metric.accepts(record.value) else { return }
                        averages.append(RingReading(metric: metric, value: record.value, date: record.date))
                    }
                    if averages.sourceCount > 0 {
                        readings[metric] = Dictionary(uniqueKeysWithValues: averages.readings.map { ($0.date, $0.value) })
                    }
                }
            }

            func workouts(from start: Date, to end: Date) throws -> Int {
                try context.fetchCount(FetchDescriptor<StoredWorkout>(predicate: #Predicate {
                    $0.ringID == ringID && $0.start >= start && $0.start < end
                }))
            }
            let currentWorkouts = try workouts(from: period.start, to: period.end)
            let previousWorkouts = try workouts(from: period.previousStart, to: period.start)
            return (readings, currentWorkouts, previousWorkouts)
        }
        let (readings, currentWorkouts, previousWorkouts) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        let sleepTotals = try await sleep

        func week(from start: Date, to end: Date, workoutCount: Int) -> WeeklyReviewWeek {
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            let dailyReadings = readings.compactMapValues { values -> [Date: Double]? in
                let matching = values.filter { $0.key >= start && $0.key < end }
                return matching.isEmpty ? nil : matching
            }
            return WeeklyReviewWeek(days: days, sleep: sleepTotals.filter { $0.key >= start && $0.key < end },
                                    readings: dailyReadings, workoutCount: workoutCount)
        }

        return WeeklyReviewSnapshot(current: week(from: period.start, to: period.end, workoutCount: currentWorkouts),
                                    previous: week(from: period.previousStart, to: period.start, workoutCount: previousWorkouts))
    }
}
