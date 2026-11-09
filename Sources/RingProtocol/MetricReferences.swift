import Foundation

public enum ReferenceSex: String, CaseIterable, Identifiable {
    case unspecified, male, female
    public var id: String { rawValue }
    public var title: String { switch self { case .unspecified: return "Not set"; case .male: return "Male"; case .female: return "Female" } }
}
public struct ReferenceProfile: Equatable {
    public let age: Int?
    public let sex: ReferenceSex
    public let maximumHeartRateOverride: Int?
    public init(age: Int? = nil, sex: ReferenceSex = .unspecified, maximumHeartRateOverride: Int? = nil) {
        self.age = age.flatMap { (18...120).contains($0) ? $0 : nil }
        self.sex = sex
        self.maximumHeartRateOverride = maximumHeartRateOverride.flatMap { (60...240).contains($0) ? $0 : nil }
    }
    public var maximumHeartRate: Int? { maximumHeartRateOverride ?? age.map { 220 - $0 } }
}
public enum ReadingContext: String, CaseIterable, Identifiable {
    case unspecified, resting, exercise
    public var id: String { rawValue }
    public var title: String { switch self { case .unspecified: return "Choose context"; case .resting: return "At rest"; case .exercise: return "Exercise" } }
}
public enum ReferenceTone: Equatable { case positive, neutral, attention, high, unavailable }
public struct MetricCategory {
    public let title: String
    public let detail: String
    public let tone: ReferenceTone
    public init(_ title: String, _ detail: String, _ tone: ReferenceTone) { self.title = title; self.detail = detail; self.tone = tone }
}
public struct ReferenceRow: Identifiable {
    public let title: String
    public let range: String
    public var id: String { title }
    public init(_ title: String, _ range: String) { self.title = title; self.range = range }
}

/// Original-app wellness categories, with AHA adult resting-heart-rate and
/// MedlinePlus SpO₂ references replacing the original fitness/oxygen labels.
public enum MetricReferences {
    private static let missingAge = MetricCategory("Set age", "Set your year of birth in Settings to estimate maximum heart rate.", .unavailable)
    private static let outside = MetricCategory("Outside reference", "This value is outside the supplied table’s scale and has not been assigned a category.", .unavailable)
    public static func range(for metric: RingMetric, profile: ReferenceProfile) -> ClosedRange<Double>? {
        if metric == .heartRate { return 60...100 }
        if metric == .respiration { return 12...20 }
        return nil
    }
    public static func category(for metric: RingMetric, value: Double, profile: ReferenceProfile,
                                context: ReadingContext = .unspecified) -> MetricCategory? {
        guard value.isFinite, value >= 0 else { return outside }
        switch metric {
        case .hrv:
            return HRVBaseline(readings: [], before: Date()).category(value: value)
        case .respiration:
            guard value > 0 else { return outside }
            let text = "12–20 breaths/min is a general adult resting reference from MedlinePlus. Activity and sleep can affect breathing; a ring estimate is not a diagnosis."
            if value < 12 { return MetricCategory("Below typical", text, .attention) }
            if value > 20 { return MetricCategory("Above typical", text, .attention) }
            return MetricCategory("Typical range", text, .neutral)
        case .mood:
            guard value <= 100 else { return outside }
            if value >= 67 { return MetricCategory("Joyful range", "The ring’s emotion index is in the original app’s 67–100 band. This does not establish your actual emotional state.", .positive) }
            if value >= 34 { return MetricCategory("Calm range", "The ring’s emotion index is in the original app’s 34–66 band.", .neutral) }
            return MetricCategory("Low mood index", "0–33. The original app calls this ‘Depressed’; a wearable index cannot diagnose depression or determine how you feel.", .attention)
        case .fatigue:
            guard value <= 100 else { return outside }
            if value < 30 { return MetricCategory("Normal", "0–29 in the original app’s fatigue scale. Consider how you feel alongside the score.", .positive) }
            if value < 60 { return MetricCategory("Mild", "30–59. Consider rest and adjusting your schedule if you feel tired.", .neutral) }
            if value < 80 { return MetricCategory("Moderate", "60–79. Consider reducing exertion and allowing time to recover.", .attention) }
            return MetricCategory("Severe", "80–100 in the ring’s fatigue index. Check how you feel and avoid pushing through significant fatigue; this score alone does not determine fitness to exercise.", .high)
        case .stress:
            guard value >= 1, value <= 99 else { return outside }
            if value < 30 { return MetricCategory("Relaxed", "1–29 in the original app’s stress-index scale.", .positive) }
            if value < 60 { return MetricCategory("Normal", "30–59 in the original app’s stress-index scale.", .neutral) }
            if value < 80 { return MetricCategory("Medium", "60–79 in the original app’s stress-index scale.", .attention) }
            return MetricCategory("High", "80–99 in the original app’s stress-index scale. It is a device estimate, not a psychological assessment.", .high)
        case .pai:
            guard value <= 1000 else { return outside }
            if value >= 80 { return MetricCategory("Great", "80 or more in the original app’s PAI scale.", .positive) }
            if value >= 50 { return MetricCategory("Acceptable", "50–79. The original app suggests improving sleep and activity.", .neutral) }
            if value >= 25 { return MetricCategory("Needs improvement", "25–49 in the original app’s PAI scale.", .attention) }
            return MetricCategory("Low score", "0–24. The original app calls this ‘Unhealthy lifestyle’; this score alone cannot assess your lifestyle, health, or life expectancy.", .attention)
        case .oxygen:
            guard value <= 100 else { return outside }
            if value >= 95 { return MetricCategory("Typical range", "95–100% is the usual pulse-oximetry reference. Ring measurements are estimates and can be inaccurate.", .neutral) }
            if value > 92 { return MetricCategory("Below typical", "Recheck the fit and reading. Confirm persistent low results with a medical pulse oximeter and discuss them with a clinician.", .attention) }
            if value > 88 { return MetricCategory("Low reading", "Confirm with a medical pulse oximeter. MedlinePlus advises contacting a healthcare provider for confirmed readings of 92% or below.", .high) }
            return MetricCategory("Very low reading", "Confirm with a medical pulse oximeter. Seek immediate medical attention for a confirmed reading of 88% or below, or for severe breathing difficulty, chest pain, or confusion regardless of the number.", .high)
        case .heartRate:
            if context == .unspecified { return MetricCategory("Choose context", "A pulse reading cannot automatically be treated as a resting measurement or an exercise session.", .unavailable) }
            if context == .exercise { return exerciseCategory(value: value, profile: profile) }
            guard value > 0 else { return outside }
            if value < 60 { return MetricCategory("Below typical", "Below 60 bpm. This can occur during sleep, with training, or with some medicines. A low reading alone does not indicate poor health; discuss persistent or unexpected changes with a healthcare professional.", .neutral) }
            if value <= 100 { return MetricCategory("Typical range", "60–100 bpm is the American Heart Association’s general adult resting reference. This comparison assumes you are calm and resting; it is not a fitness grade or a diagnosis.", .neutral) }
            return MetricCategory("Above typical", "Above 100 bpm compared with the adult resting reference. Activity, stress, illness, and other factors can raise pulse. Recheck while calm and resting; discuss persistent or unexpected changes with a healthcare professional.", .attention)
        default: return nil
        }
    }
    private static func exerciseCategory(value: Double, profile: ReferenceProfile) -> MetricCategory {
        guard let max = profile.maximumHeartRate else { return missingAge }
        let percent = value / Double(max) * 100
        let note = "\(Int(percent.rounded()))% of \(max) bpm \(profile.maximumHeartRateOverride == nil ? "estimated maximum (220 − age)" : "configured maximum"). These zones are references, not a prescribed target."
        if percent < 50 { return MetricCategory("Below warm-up zone", note, .neutral) }
        if percent <= 60 { return MetricCategory("Warm-up", note, .neutral) }
        if percent <= 70 { return MetricCategory("Fat-burning", note, .neutral) }
        if percent <= 80 { return MetricCategory("Aerobic", note, .neutral) }
        if percent <= 90 { return MetricCategory("Anaerobic", note, .attention) }
        if percent <= 100 { return MetricCategory("Extreme", note, .attention) }
        return MetricCategory("Above estimated maximum", note, .attention)
    }
    public static func rows(for metric: RingMetric, profile: ReferenceProfile, context: ReadingContext = .unspecified) -> [ReferenceRow] {
        switch metric {
        case .hrv: return []
        case .respiration: return [.init("Below typical", "<12 breaths/min"), .init("Typical range", "12–20 breaths/min"), .init("Above typical", ">20 breaths/min")]
        case .mood: return [.init("Joyful", "67–100"), .init("Calm", "34–66"), .init("Depressed (original label)", "0–33")]
        case .fatigue: return [.init("Normal", "0–29"), .init("Mild", "30–59"), .init("Moderate", "60–79"), .init("Severe", "80–100")]
        case .stress: return [.init("High", "80–99"), .init("Medium", "60–79"), .init("Normal", "30–59"), .init("Relaxed", "1–29")]
        case .pai: return [.init("Great", "≥80"), .init("Acceptable", "50–79"), .init("Needs improvement", "25–49"), .init("Unhealthy lifestyle (original label)", "0–24")]
        case .oxygen: return [.init("Normal (original label)", "90–100%"), .init("Low (original label)", "70–89%"), .init("Hypoxia (original label)", "<70%")]
        case .heartRate:
            if context == .exercise {
                return [.init("Warm-up", "50–60%"), .init("Fat-burning", ">60–70%"), .init("Aerobic", ">70–80%"), .init("Anaerobic", ">80–90%"), .init("Extreme", ">90–100%")]
            }
            return [.init("Below typical", "<60 bpm"), .init("Typical range", "60–100 bpm"), .init("Above typical", ">100 bpm")]
        default: return []
        }
    }
}

/// Descriptive, app-defined baseline, not a clinical reference interval.
/// Daily medians give each recorded day equal weight. Today's samples cannot
/// influence the comparison with today's latest reading.
public struct HRVBaseline: Sendable {
    public let dayCount: Int
    public let median: Double?
    public let range: ClosedRange<Double>?
    public init(readings: [RingReading], before date: Date, calendar: Calendar = .current) {
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -28, to: end)!
        let valid = readings.filter { $0.metric == .hrv && !$0.isObservationTime && RingMetric.hrv.accepts($0.value) && $0.date >= start && $0.date < end }
        // Repeated imports of the same timestamp must not change its weight.
        var unique: [Date: Double] = [:]
        for reading in valid { unique[reading.date] = reading.value }
        let days = Dictionary(grouping: unique.keys, by: { calendar.startOfDay(for: $0) })
        let medians = days.values.map { dates in Self.quantile(dates.map { unique[$0]! }.sorted(), 0.5) }.sorted()
        dayCount = medians.count
        if medians.count >= 7 {
            median = Self.quantile(medians, 0.5)
            range = Self.quantile(medians, 0.25)...Self.quantile(medians, 0.75)
        } else { median = nil; range = nil }
    }
    private static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
    public func category(value: Double) -> MetricCategory {
        guard RingMetric.hrv.accepts(value) else { return MetricCategory("Outside reference", "No personal comparison is available for this reading.", .unavailable) }
        guard let range else { return MetricCategory("Building baseline", "\(dayCount)/7 prior recorded days available in the last 28 days. Age tables are not used to grade HRV.", .unavailable) }
        let detail = "Compared with the middle 50% of your daily HRV medians from \(dayCount) prior days within 28 days. This is a personal trend comparison, not a health or recovery score."
        if value < range.lowerBound { return MetricCategory("Below your usual", detail, .neutral) }
        if value > range.upperBound { return MetricCategory("Above your usual", detail, .neutral) }
        return MetricCategory("Within your usual", detail, .neutral)
    }
}

public struct SleepDurationReference {
    public let minimumHours: Double
    public let maximumHours: Double?
    public let label: String
    public var durationLabel: String {
        if let maximumHours { return "\(Int(minimumHours))–\(Int(maximumHours)) hours" }
        return "At least \(Int(minimumHours)) hours"
    }
    public init?(profile: ReferenceProfile) {
        guard let age = profile.age else { return nil }
        minimumHours = 7
        switch age {
        case ...60: maximumHours = nil; label = "At least 7 hours · ages 18–60"
        case ...64: maximumHours = 9; label = "7–9 hours · ages 61–64"
        default: maximumHours = 8; label = "7–8 hours · ages 65+"
        }
    }
    public func category(recordedSeconds: TimeInterval) -> MetricCategory? {
        guard recordedSeconds.isFinite, recordedSeconds > 0 else { return nil }
        if recordedSeconds < minimumHours * 3600 {
            return MetricCategory("Below recommended duration", "Recorded sleep is below the daily duration guidance. The ring may have missed sleep or naps; this is not a sleep-quality assessment.", .attention)
        }
        if let maximumHours, recordedSeconds > maximumHours * 3600 {
            return MetricCategory("Above recommended duration", "Recorded sleep is above the daily duration guidance. Individual needs vary; duration alone does not establish a sleep problem.", .neutral)
        }
        return MetricCategory("Recommended duration met", "Recorded duration meets the daily age-based guidance. Duration alone does not measure sleep quality or confirm a complete night’s recording.", .neutral)
    }
}
