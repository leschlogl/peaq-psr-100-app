import Foundation
import SwiftData

enum PersonalBaselineMetric: String, CaseIterable, Identifiable, Sendable {
    case hrv, respiration

    var id: Self { self }
    var metric: RingMetric { self == .hrv ? .hrv : .respiration }
    var title: String { self == .hrv ? "HRV" : "Respiratory rate" }
}

struct PersonalBaselineSnapshot: Sendable {
    struct Day: Identifiable, Sendable {
        let date: Date
        let median: Double?
        var id: Date { date }
    }

    let days: [Day]
    let usual: DailyReadingBaseline

    init(metric: PersonalBaselineMetric, readings: [RingReading], now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let medians = DailyReadingBaseline.dailyMedians(for: metric.metric,
            readings: readings.filter { $0.date <= now }, calendar: calendar)
        usual = DailyReadingBaseline(dailyMedians: medians, before: today, calendar: calendar)
        days = (-6...0).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return Day(date: day, median: medians[day])
        }
    }
}

enum PersonalBaselineLoader {
    static func load(container: ModelContainer, ringID: String, metric: PersonalBaselineMetric,
                     now: Date = Date(), calendar: Calendar = .current) async throws -> PersonalBaselineSnapshot {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let start = calendar.date(byAdding: .day, value: -DailyReadingBaseline.windowDays, to: calendar.startOfDay(for: now))!
            let name = metric.metric.rawValue
            let request = FetchDescriptor<StoredReading>(predicate: #Predicate {
                $0.ringID == ringID && $0.metricName == name && !$0.isObservationTime && $0.date >= start && $0.date <= now
            })
            var readings: [RingReading] = []
            try context.enumerate(request, batchSize: 500) { record in
                try Task.checkCancellation()
                readings.append(RingReading(metric: metric.metric, value: record.value, date: record.date))
            }
            return PersonalBaselineSnapshot(metric: metric, readings: readings, now: now, calendar: calendar)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
