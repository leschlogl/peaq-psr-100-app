import Foundation

public enum RingMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate, oxygen, hrv, steps, calories, distance, respiration, stress, mood, fatigue, pai, dailyIndexA, dailyIndexB
    public static let dashboardMetrics: [RingMetric] = [.heartRate, .oxygen, .hrv, .respiration, .stress, .mood, .fatigue, .steps, .calories, .distance]
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .oxygen: return "Blood oxygen"
        case .hrv: return "HRV"
        case .steps: return "Steps"
        case .calories: return "Energy"
        case .distance: return "Distance"
        case .respiration: return "Respiration"
        case .stress: return "Stress"
        case .mood: return "Mood"
        case .fatigue: return "Fatigue"
        case .pai: return "PAI Vitality Index"
        case .dailyIndexA: return "Daily index A"
        case .dailyIndexB: return "Daily index B"
        }
    }
    public var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .oxygen: return "%"
        case .hrv: return "ms"
        case .steps: return "steps"
        case .calories: return "kcal"
        case .distance: return "km"
        case .respiration: return "breaths/min"
        case .pai: return "points"
        default: return "index"
        }
    }
    public var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .oxygen: return "drop.fill"
        case .hrv: return "waveform.path.ecg"
        case .steps: return "figure.walk"
        case .calories: return "flame.fill"
        case .distance: return "location.fill"
        case .respiration: return "lungs.fill"
        case .stress: return "brain.head.profile"
        case .mood: return "face.smiling"
        case .fatigue: return "moon.fill"
        case .pai: return "sparkles"
        case .dailyIndexA, .dailyIndexB: return "chart.bar.fill"
        }
    }
    public func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .heartRate: return (25...240).contains(value)
        case .oxygen: return (50...100).contains(value)
        case .hrv: return (1...255).contains(value)
        case .steps: return (0...100_000).contains(value)
        case .calories: return (0...20_000).contains(value)
        case .distance: return (0...200).contains(value)
        case .respiration: return (4...60).contains(value)
        case .pai: return (0...1000).contains(value)
        default: return (0...255).contains(value)
        }
    }
}

public struct RingReading: Equatable, Sendable {
    public let metric: RingMetric
    public let value: Double
    public let date: Date
    public let isObservationTime: Bool
    public init(metric: RingMetric, value: Double, date: Date, isObservationTime: Bool = false) {
        self.metric = metric
        self.value = value
        self.date = date
        self.isObservationTime = isObservationTime
    }
    public func storageKey(ringID: String) -> String {
        // Compact activity packets have no sample timestamp. Store one snapshot per minute.
        let stamp = isObservationTime ? floor(date.timeIntervalSince1970 / 60) * 60 : date.timeIntervalSince1970
        return "\(ringID)|\(metric.rawValue)|\(stamp)|\(isObservationTime)"
    }
}

/// Streaming chart reduction: retain each time bucket's minimum and maximum,
/// plus the window's first/last samples. Raw database records are untouched.
public struct RingTrendSampler {
    private let start: Date
    private let end: Date
    private let bucketCount: Int
    private var lows: [RingReading?]
    private var highs: [RingReading?]
    private var first: RingReading?
    private var last: RingReading?
    public private(set) var sourceCount = 0
    public init(start: Date, end: Date, bucketCount: Int = 600) {
        self.start = start; self.end = end
        self.bucketCount = max(1, min(600, bucketCount))
        lows = Array(repeating: nil, count: self.bucketCount)
        highs = Array(repeating: nil, count: self.bucketCount)
    }
    public mutating func append(_ reading: RingReading) {
        guard reading.value.isFinite, reading.date >= start, reading.date <= end else { return }
        sourceCount += 1
        let fraction = reading.date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
        let index = min(bucketCount - 1, max(0, Int(fraction * Double(bucketCount))))
        if lows[index] == nil || reading.value < lows[index]!.value { lows[index] = reading }
        if highs[index] == nil || reading.value > highs[index]!.value { highs[index] = reading }
        if first == nil || reading.date < first!.date { first = reading }
        if last == nil || reading.date > last!.date { last = reading }
    }
    public var readings: [RingReading] {
        var unique: [String: RingReading] = [:]
        for reading in (lows + highs + [first, last]).compactMap({ $0 }) {
            unique[reading.storageKey(ringID: "chart")] = reading
        }
        return unique.values.sorted { $0.date < $1.date }
    }
}

/// Sample-weighted chart means. Keep only a count and running mean per local
/// calendar interval. Absolute interval starts distinguish repeated DST hours.
public struct RingChartAverager {
    public enum Interval { case hour, day }
    private struct Summary { var count: Int; var mean: Double }
    private let metric: RingMetric
    private let start: Date
    private let end: Date
    private let calendar: Calendar
    private let interval: Interval
    private var days: [Date: Summary] = [:]
    public private(set) var sourceCount = 0
    public init(metric: RingMetric, start: Date, end: Date, calendar: Calendar = .current, interval: Interval = .day) {
        self.metric = metric; self.start = start; self.end = end; self.calendar = calendar; self.interval = interval
    }
    public mutating func append(_ reading: RingReading) {
        guard reading.metric == metric, reading.value.isFinite, reading.date >= start, reading.date <= end else { return }
        guard let day = calendar.dateInterval(of: interval == .hour ? .hour : .day, for: reading.date)?.start else { return }
        var summary = days[day] ?? Summary(count: 0, mean: 0)
        summary.count += 1
        summary.mean += (reading.value - summary.mean) / Double(summary.count)
        days[day] = summary; sourceCount += 1
    }
    public var readings: [RingReading] {
        days.keys.sorted().map { RingReading(metric: metric, value: days[$0]!.mean, date: $0) }
    }
}

/// Calendar-based, half-open day bounds work across 23/25-hour days. Historical
/// windows end at the following midnight; today's reads are capped at `now`.
public struct RingHistoryWindow: Sendable {
    public let dayStart: Date
    public let nextDay: Date
    public let trendStart: Date
    public let chartEnd: Date
    public let days: Int
    public let isToday: Bool
    public init(selectedDay: Date? = nil, days: Int = 1, now: Date = Date(), calendar: Calendar = .current) {
        self.days = [1,7,30].contains(days) ? days : 1
        dayStart = calendar.startOfDay(for: min(selectedDay ?? now, now))
        nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        trendStart = calendar.date(byAdding: .day, value: -(self.days - 1), to: dayStart)!
        isToday = calendar.isDate(dayStart, inSameDayAs: now)
        chartEnd = isToday ? now : nextDay
    }
}
