import Charts
import SwiftUI

struct WeeklyReviewView: View {
    @EnvironmentObject private var ring: RingBluetooth
    @Environment(\.calendar) private var localCalendar
    @Environment(\.timeZone) private var timeZone
    @AppStorage(ActivityGoalDefaults.stepsKey) private var stepGoal = ActivityGoalDefaults.steps
    @AppStorage(ActivityGoalDefaults.caloriesKey) private var energyGoal = ActivityGoalDefaults.calories
    @AppStorage(ActivityGoalDefaults.distanceKey) private var distanceGoal = ActivityGoalDefaults.distance

    @State private var weeksBack = 0
    @State private var metric = ReviewMetric.sleep
    @State private var selectedDay: Int?
    @State private var snapshot: WeeklyReviewSnapshot?
    @State private var loadFailed = false

    private var calendar: Calendar {
        var calendar = localCalendar
        calendar.timeZone = timeZone
        return calendar
    }

    var body: some View {
        let calendar = calendar
        let period = WeeklyReviewPeriod(weeksBack: weeksBack, calendar: calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                weekNavigation(period, calendar: calendar)
                Picker("Review section", selection: $metric) {
                    ForEach(ReviewMetric.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: metric) { _, _ in selectedDay = nil }

                if let snapshot {
                    let target = Double(max(1, stepGoal))
                    ReviewChartCard(metric: metric, snapshot: snapshot, stepGoal: target, selectedDay: $selectedDay)
                    additionalMetrics(snapshot)
                } else if loadFailed {
                    ContentUnavailableView("Couldn’t load weekly review", systemImage: "chart.bar.xaxis")
                } else {
                    ProgressView("Loading weekly review…").frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .navigationTitle("Weekly review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: ring.selectedID) { _, _ in
            weeksBack = 0
            selectedDay = nil
        }
        .task(id: "\(period.start)|\(calendar)|\(ring.selectedID)|\(ring.historyRevision)") {
            let ringID = ring.selectedID
            snapshot = nil
            loadFailed = false
            do {
                let result = try await WeeklyReviewLoader.load(container: RingStore.shared.get().container,
                    ringID: ringID, period: period, calendar: calendar)
                guard !Task.isCancelled, ring.selectedID == ringID else { return }
                snapshot = result
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }

    private func weekNavigation(_ period: WeeklyReviewPeriod, calendar: Calendar) -> some View {
        HStack {
            Button {
                weeksBack += 1
                selectedDay = nil
            } label: {
                Image(systemName: "chevron.left").foregroundStyle(.mint).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous week")
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(weekLabel(from: period.start, until: period.end, calendar: calendar))
                    .font(.headline)
                    .accessibilityIdentifier("weekly-review-dates")
                Text("Compared with \(weekLabel(from: period.previousStart, until: period.start, calendar: calendar))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button {
                weeksBack -= 1
                selectedDay = nil
            } label: {
                Image(systemName: "chevron.right").foregroundStyle(.mint).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Next week")
            .disabled(weeksBack == 0)
        }
        .buttonStyle(.plain)
    }

    private func weekLabel(from start: Date, until end: Date, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: end)!
        return (start..<last).formatted(.interval.month(.abbreviated).day())
    }

    @ViewBuilder
    private func additionalMetrics(_ snapshot: WeeklyReviewSnapshot) -> some View {
        switch metric {
        case .sleep:
            EmptyView()
        case .activity:
            VStack(spacing: 8) {
                if energyGoal > 0 {
                    goalRow("Energy goal", metric: .calories, target: Double(energyGoal), snapshot: snapshot)
                    Divider()
                }
                if distanceGoal.isFinite && distanceGoal > 0 {
                    goalRow("Distance goal", metric: .distance, target: distanceGoal, snapshot: snapshot)
                    Divider()
                }
                summaryRow("Workouts", value: snapshot.current.workoutCount.formatted(), coverage: "Recorded sessions",
                           prior: snapshot.previous.hasData ? snapshot.previous.workoutCount.formatted() : nil)
            }
        case .heart:
            let values = snapshot.current.readings[.hrv]
            let priorValues = snapshot.previous.readings[.hrv]
            let current = values.flatMap { average(Array($0.values)) }
            let previous = priorValues.flatMap { average(Array($0.values)) }
            summaryRow("Average HRV", value: current.map { reviewNumber($0, unit: "ms") } ?? "—",
                       coverage: reviewCoverage(values?.count ?? 0, unit: "days"),
                       prior: previous.map { "\(reviewNumber($0, unit: "ms")) · \(priorValues?.count ?? 0) of 7 days" })
        }
    }

    private func goalRow(_ title: String, metric: RingMetric, target: Double, snapshot: WeeklyReviewSnapshot) -> some View {
        let current = snapshot.current.goalDays(metric, target: target)
        let previous = snapshot.previous.goalDays(metric, target: target)
        return summaryRow(title, value: goalSummary(current),
                          coverage: "\(reviewCoverage(current.recorded, unit: "days")) · \(target.formatted()) \(metric.unit)/day",
                          prior: previous.recorded > 0 ? goalSummary(previous) : nil)
    }

    private func summaryRow(_ title: String, value: String, coverage: String, prior: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(coverage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let prior { Text("Prior: \(prior)").font(.caption).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum ReviewMetric: String, CaseIterable, Identifiable {
    case sleep = "Sleep", activity = "Activity", heart = "Heart"

    var id: Self { self }
    var title: String {
        switch self {
        case .sleep: return "Average sleep"
        case .activity: return "Steps goal"
        case .heart: return "Average heart rate"
        }
    }
    var tint: Color {
        switch self {
        case .sleep: return .indigo
        case .activity: return .mint
        case .heart: return .cyan
        }
    }
    var axisMaximum: Double {
        switch self {
        case .sleep: return 10
        case .activity: return 12_000
        case .heart: return 80
        }
    }
    var coverageUnit: String { self == .sleep ? "nights" : "days" }

    func readings(for week: WeeklyReviewWeek) -> [Double?] {
        switch self {
        case .sleep: return week.days.map { week.sleep[$0].map { $0 / 3600 } }
        case .activity: return week.days.map { week.readings[.steps]?[$0] }
        case .heart: return week.days.map { week.readings[.heartRate]?[$0] }
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .sleep:
            let minutes = Int((value * 60).rounded())
            return "\(minutes / 60)h \(minutes % 60)m"
        case .activity: return reviewNumber(value, unit: "steps")
        case .heart: return reviewNumber(value, unit: "bpm")
        }
    }

    func axisLabel(_ value: Double) -> String {
        switch self {
        case .sleep: return reviewNumber(value, unit: "h")
        case .activity: return value == 0 ? "0" : reviewNumber(value / 1000, unit: "k")
        case .heart: return value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    func change(current: Double, previous: Double) -> String {
        let scale: Double = self == .sleep ? 60 : 1
        let delta = Int((current * scale).rounded()) - Int((previous * scale).rounded())
        if delta == 0 { return "Same as prior week" }
        let units = self == .sleep ? "min" : "bpm"
        return "\(delta > 0 ? "+" : "−")\(abs(delta)) \(units) vs prior week"
    }
}

private struct ReviewChartCard: View {
    let metric: ReviewMetric
    let snapshot: WeeklyReviewSnapshot
    let stepGoal: Double
    @Binding var selectedDay: Int?

    var body: some View {
        let values = metric.readings(for: snapshot.current)
        let priorValues = metric.readings(for: snapshot.previous)
        let recorded = values.compactMap { $0 }
        let priorRecorded = priorValues.compactMap { $0 }
        let mean = average(recorded)
        let priorMean = average(priorRecorded)
        let goal = snapshot.current.goalDays(.steps, target: stepGoal)
        let priorGoal = snapshot.previous.goalDays(.steps, target: stepGoal)
        let reference: Double? = metric == .activity ? stepGoal : priorMean

        VStack(alignment: .leading, spacing: 10) {
            Text(metric == .activity ? "\(metric.title) · \(stepGoal.formatted())/day" : metric.title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(metric.tint)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    headline(mean, goal: goal)
                    comparison(mean: mean, priorMean: priorMean, priorGoal: priorGoal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    headline(mean, goal: goal)
                    comparison(mean: mean, priorMean: priorMean, priorGoal: priorGoal)
                }
            }
            Text("\(reviewCoverage(recorded.count, unit: metric.coverageUnit)) · Prior: \(priorRecorded.count) of 7")
                .font(.caption).foregroundStyle(.secondary)
            chart(values, reference: reference)
            if let reference {
                HStack(spacing: 6) {
                    Image(systemName: "line.horizontal.3").font(.caption2).accessibilityHidden(true)
                    Text(metric == .activity ? "Daily goal · \(metric.format(reference))" : "Prior-week average · \(metric.format(reference))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Divider()
            dayReadout(values)
        }
        .padding(14)
        .background(Color(red: 0.075, green: 0.10, blue: 0.115), in: RoundedRectangle(cornerRadius: 20))
    }

    private func headline(_ mean: Double?, goal: (met: Int, recorded: Int)) -> some View {
        Text(metric == .activity ? goalSummary(goal) : (mean.map(metric.format) ?? "—"))
            .font(.largeTitle.weight(.semibold)).monospacedDigit()
            .accessibilityIdentifier("weekly-review-value")
    }

    @ViewBuilder
    private func comparison(mean: Double?, priorMean: Double?, priorGoal: (met: Int, recorded: Int)) -> some View {
        if metric == .activity {
            if priorGoal.recorded > 0 {
                Text("Prior week: \(goalSummary(priorGoal))").font(.caption)
            }
        } else if let mean, let priorMean {
            Text(metric.change(current: mean, previous: priorMean)).font(.caption)
        }
    }

    private func chart(_ values: [Double?], reference: Double?) -> some View {
        let days = snapshot.current.days
        let maximum = max(metric.axisMaximum, max(values.compactMap { $0 }.max() ?? 0, reference ?? 0))
        return Chart {
            if let reference {
                RuleMark(y: .value("Comparison", reference))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityHidden(true)
            }
            ForEach(days.indices, id: \.self) { index in
                if let value = values[index] {
                    RectangleMark(xStart: .value("Day start", Double(index) + 0.22),
                                  xEnd: .value("Day end", Double(index) + 0.78),
                                  yStart: .value("Minimum", 0.0), yEnd: .value("Reading", value))
                        .foregroundStyle(metric.tint.opacity(index == selectedDay || selectedDay == nil ? 1 : 0.55))
                        .accessibilityLabel(Text(days[index], format: .dateTime.weekday(.wide).month().day()))
                        .accessibilityValue(metric.format(value))
                }
            }
        }
        .chartXScale(domain: 0...Double(days.count))
        .chartYScale(domain: 0...maximum)
        .chartXAxis {
            AxisMarks(values: days.indices.map { Double($0) + 0.5 }) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self), days.indices.contains(Int(position)) {
                        Text(days[Int(position)], format: .dateTime.weekday(.abbreviated))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(metric.axisLabel(amount)) }
                }
            }
        }
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0).onChanged { gesture in
                if let value = proxy.value(atX: gesture.location.x, as: Double.self), value.isFinite {
                    selectedDay = Int(min(max(value, 0), Double(days.count - 1)))
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay) { _, next in next != nil }
        .accessibilityIdentifier("weekly-review-chart")
        .accessibilityHint("Touch and slide to select a day.")
        .frame(height: 150)
    }

    private func dayReadout(_ values: [Double?]) -> some View {
        HStack {
            if let selectedDay, snapshot.current.days.indices.contains(selectedDay) {
                Text(snapshot.current.days[selectedDay], format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(values[selectedDay].map(metric.format) ?? "No reading recorded")
                    .fontWeight(.semibold)
            } else {
                Text("Daily readings").foregroundStyle(.secondary)
                Spacer()
                if values.contains(where: { $0 == nil }) {
                    Text("Gaps show missing readings").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("weekly-review-day")
    }
}

private func average(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

private func goalSummary(_ goal: (met: Int, recorded: Int)) -> String {
    goal.recorded == 0 ? "—" : "\(goal.met) / \(goal.recorded) days"
}

private func reviewCoverage(_ count: Int, unit: String) -> String {
    "\(count) of 7 \(unit) recorded"
}

private func reviewNumber(_ value: Double, unit: String) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) \(unit)"
}
