import Foundation

struct RingStepHistory: Sendable {
    struct Bucket: Identifiable, Sendable {
        let start: Date
        let steps: Int?
        var id: Date { start }
    }

    private let window: RingHistoryWindow
    private let calendar: Calendar
    private var previous: (date: Date, steps: Int)?
    private var totals: [Date: Int] = [:]
    private var changes: [Date: Int] = [:]

    init(window: RingHistoryWindow, calendar: Calendar) {
        self.window = window
        self.calendar = calendar
    }

    // Readings arrive in chronological order. The first snapshot establishes
    // a baseline. An increase belongs to an hour only if both endpoints fit.
    mutating func append(_ reading: RingReading) {
        guard reading.metric == .steps, RingMetric.steps.accepts(reading.value),
              reading.date >= window.trendStart, reading.date < window.nextDay,
              reading.date <= window.chartEnd else { return }
        let steps = Int(reading.value.rounded())
        let day = calendar.startOfDay(for: reading.date)
        totals[day] = steps
        guard window.days == 1 else { return }

        defer { previous = (reading.date, steps) }
        guard let previous, previous.date < reading.date, steps >= previous.steps,
              let hour = calendar.dateInterval(of: .hour, for: previous.date),
              reading.date <= hour.end else { return }
        changes[hour.start, default: 0] += steps - previous.steps
    }

    var selectedDayTotal: Int? { totals[window.dayStart] }

    var buckets: [Bucket] {
        if window.days > 1 {
            return (0..<window.days).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: window.trendStart)!
                return Bucket(start: day, steps: totals[day])
            }
        }
        var hours: [Bucket] = []
        var start = window.dayStart
        while start < window.nextDay, let hour = calendar.dateInterval(of: .hour, for: start) {
            hours.append(Bucket(start: start, steps: changes[hour.start]))
            start = hour.end
        }
        return hours
    }
}
