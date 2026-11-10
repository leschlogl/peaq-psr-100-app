import Charts
import SwiftUI

struct PersonalBaselinesView: View {
    @EnvironmentObject private var ring: RingBluetooth
    @Environment(\.calendar) private var calendar
    @State private var metric = PersonalBaselineMetric.hrv
    @State private var result: PersonalBaselineSnapshot?
    @State private var loadedScope: LoadScope?
    @State private var loadFailed = false

    private struct LoadScope: Equatable {
        let ringID: String
        let metric: PersonalBaselineMetric
        let revision: Int
        let day: Date
        let calendar: Calendar
    }

    var body: some View {
        let now = Date()
        let scope = LoadScope(ringID: ring.selectedID, metric: metric, revision: ring.historyRevision,
                              day: calendar.startOfDay(for: now), calendar: calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Baseline metric", selection: $metric) {
                    ForEach(PersonalBaselineMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if scope.ringID.isEmpty {
                    ContentUnavailableView("No ring selected", systemImage: "waveform.path.ecg",
                                           description: Text("Connect your ring to build a personal baseline."))
                } else if let result, loadedScope == scope {
                    BaselineCard(metric: metric, snapshot: result, calendar: calendar)
                        .id(metric)
                } else if loadFailed, loadedScope == scope {
                    ContentUnavailableView("Couldn’t load your baseline", systemImage: "chart.xyaxis.line")
                } else {
                    ProgressView("Loading baseline…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .navigationTitle("Personal baselines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: scope) {
            guard !scope.ringID.isEmpty else { return }
            do {
                let snapshot = try await PersonalBaselineLoader.load(container: RingStore.shared.get().container,
                    ringID: scope.ringID, metric: scope.metric, now: now, calendar: scope.calendar)
                guard !Task.isCancelled else { return }
                result = snapshot
                loadFailed = false
                loadedScope = scope
            } catch {
                guard !Task.isCancelled else { return }
                result = nil
                loadFailed = true
                loadedScope = scope
            }
        }
    }
}

private struct BaselineCard: View {
    let metric: PersonalBaselineMetric
    let snapshot: PersonalBaselineSnapshot
    let calendar: Calendar
    @State private var selectedDay: Int?

    private var activeIndex: Int { selectedDay ?? snapshot.days.count - 1 }
    private var valueStyle: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...1)) }
    private var tint: Color { metric == .hrv ? .indigo : .cyan }

    var body: some View {
        let range = snapshot.usual.range
        let today = snapshot.days.last?.median

        VStack(alignment: .leading, spacing: 12) {
            Text("Today’s daily median").font(.subheadline).foregroundStyle(.secondary)
            Text(today.map(formatted) ?? "No reading today")
                .font(today == nil ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                .monospacedDigit()
                .accessibilityIdentifier("personal-baseline-headline")

            if let range {
                if let today {
                    Text(comparison(today, range: range))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                }
                Text("Usual range · \(range.lowerBound.formatted(valueStyle))–\(range.upperBound.formatted(valueStyle)) \(metric.metric.unit)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("personal-baseline-range")
            } else {
                Text("Building your baseline")
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("personal-baseline-range")
            }

            if range != nil || snapshot.days.contains(where: { $0.median != nil }) {
                chart(range: range)
                dayReadout
            } else {
                Text("No readings in the last 7 days.").font(.subheadline).foregroundStyle(.secondary)
            }

            Divider()
            Text("Usual range based on \(snapshot.usual.dayCount) of the prior \(DailyReadingBaseline.windowDays) days.")
                .font(.caption).foregroundStyle(.secondary)
            if range == nil {
                Text("At least \(DailyReadingBaseline.minimumDays) recorded days are needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(red: 0.075, green: 0.10, blue: 0.115), in: RoundedRectangle(cornerRadius: 20))
    }

    private func comparison(_ value: Double, range: ClosedRange<Double>) -> String {
        if value < range.lowerBound { return "Below your usual range" }
        if value > range.upperBound { return "Above your usual range" }
        return "Within your usual range"
    }

    private func formatted(_ value: Double) -> String {
        "\(value.formatted(valueStyle)) \(metric.metric.unit)"
    }

    private func chart(range: ClosedRange<Double>?) -> some View {
        let days = snapshot.days
        let limits = days.compactMap(\.median) + (range.map { [$0.lowerBound, $0.upperBound] } ?? [])
        let low = limits.min() ?? 0
        let high = limits.max() ?? low
        let padding = max((high - low) * 0.15, 1)
        return Chart {
            if let range {
                if range.lowerBound == range.upperBound {
                    RuleMark(y: .value("Usual range", range.lowerBound))
                        .foregroundStyle(.mint.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .accessibilityHidden(true)
                } else {
                    RectangleMark(xStart: .value("First day", 0.0), xEnd: .value("Last day", Double(days.count)),
                                  yStart: .value("Usual low", range.lowerBound), yEnd: .value("Usual high", range.upperBound))
                        .foregroundStyle(.mint.opacity(0.16))
                        .accessibilityHidden(true)
                }
            }
            ForEach(days.indices, id: \.self) { index in
                if let value = days[index].median {
                    PointMark(x: .value("Day", Double(index) + 0.5), y: .value(metric.title, value))
                        .foregroundStyle(index == activeIndex ? Color.mint : tint)
                        .symbolSize(index == activeIndex ? 75 : 36)
                        .accessibilityLabel(Text(days[index].date, format: .dateTime.weekday(.wide).month().day()))
                        .accessibilityValue(formatted(value))
                }
            }
            if let selectedDay {
                RuleMark(x: .value("Selected day", Double(selectedDay) + 0.5))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: 0...Double(days.count))
        .chartYScale(domain: max(0, low - padding)...(high + padding))
        .chartXAxis {
            AxisMarks(values: days.indices.map { Double($0) + 0.5 }) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self), days.indices.contains(Int(position)) {
                        Text(days[Int(position)].date, format: .dateTime.day())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(amount.formatted(valueStyle)) }
                }
            }
        }
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0).onChanged { gesture in
                if let position = proxy.value(atX: gesture.location.x, as: Double.self), position.isFinite {
                    selectedDay = Int(min(max(position, 0), Double(days.count - 1)))
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay) { _, next in next != nil }
        .accessibilityIdentifier("personal-baseline-chart")
        .accessibilityHint("Touch and slide to select a day.")
        .frame(height: 148)
    }

    private var dayReadout: some View {
        let day = snapshot.days[activeIndex]
        return HStack {
            Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .foregroundStyle(.secondary)
            Spacer()
            Text(day.median.map(formatted) ?? "No reading")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("personal-baseline-day")
    }
}
