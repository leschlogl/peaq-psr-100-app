import SwiftUI
import SwiftData
import Charts
import UIKit

enum RingPalette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.065)
    static let card = Color(red: 0.075, green: 0.10, blue: 0.115)
    static let mint = Color(red: 0.53, green: 0.94, blue: 0.76)
}

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Today", systemImage: "square.grid.2x2.fill") }
            InsightsView().tabItem { Label("Insights", systemImage: "moon.stars.fill") }
            RingDeviceView().tabItem { Label("My ring", systemImage: "circle.circle") }
            RingSettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}

struct DisplayReading: Identifiable {
    let id: String
    let metric: RingMetric
    let value: Double
    let date: Date
    let observed: Bool
    let series: Int
}

struct DashboardView: View {
    @EnvironmentObject private var references: ReferencePreferences
    @AppStorage(ActivityGoalDefaults.stepsKey) private var dailyStepGoal = ActivityGoalDefaults.steps
    @AppStorage(ActivityGoalDefaults.caloriesKey) private var dailyCalorieGoal = ActivityGoalDefaults.calories
    @AppStorage(ActivityGoalDefaults.distanceKey) private var dailyDistanceGoal = ActivityGoalDefaults.distance
    @State private var referenceMetric: RingMetric?
    @EnvironmentObject private var ring: RingBluetooth
    @State private var readings: [DisplayReading] = []
    @State private var latestReadings: [RingMetric: RingReading] = [:]
    @State private var trendSourceCount = 0
    @State private var hrvBaseline = HRVBaseline(readings: [], before: Date())
    @State private var selectedMetric: RingMetric = .heartRate
    @State private var rangeDays = 1
    @State private var selectedDay: Date?
    @State private var showingDatePicker = false
    @State private var isLoadingHistory = true
    private var displayDay: Date { selectedDay ?? Date() }
    private var isViewingToday: Bool { Calendar.current.isDateInToday(displayDay) }
    private var historyWindow: RingHistoryWindow { RingHistoryWindow(selectedDay: selectedDay, days: rangeDays) }
    private func latest(_ metric: RingMetric) -> RingReading? {
        guard let reading = latestReadings[metric], Calendar.current.isDate(reading.date, inSameDayAs: displayDay) else { return nil }
        return reading
    }
    private var referenceBand: ClosedRange<Double>? {
        selectedMetric == .hrv ? hrvBaseline.range : MetricReferences.range(for: selectedMetric, profile: references.profile)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(displayDay, format: .dateTime.weekday(.wide).month(.wide).day()).font(.subheadline).foregroundStyle(.secondary)
                            Text("Your daily rhythm").font(.largeTitle.bold()).tracking(-1)
                        }
                        Spacer()
                        Image(systemName: "circle.circle").font(.system(size: 34, weight: .light)).foregroundStyle(RingPalette.mint).accessibilityHidden(true)
                    }
                    if !isViewingToday {
                        if !isLoadingHistory && latestReadings.isEmpty {
                            Text("No readings recorded for this day.").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("history-empty-day")
                        }
                    }
                    activityCard
                    Text("HEALTH SNAPSHOT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach([RingMetric.heartRate, .oxygen, .hrv, .respiration]) { metric in
                            metricCard(metric)
                        }
                    }
                    Text("EMOTION HEALTH").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach([RingMetric.stress, .mood, .fatigue]) { metric in metricCard(metric) }
                    }
                    trendCard
                }.padding(20)
            }
            .background(RingPalette.background)
            .task(id: "\(ring.selectedID)|\(ring.historyRevision)|\(selectedMetric.rawValue)|\(rangeDays)|\(historyWindow.dayStart)") {
                let ringID = ring.selectedID
                let metric = selectedMetric, days = rangeDays
                let selection = selectedDay
                isLoadingHistory = true
                defer { if !Task.isCancelled { isLoadingHistory = false } }
                do {
                    let snapshot = try await RingSnapshotLoader.dashboard(container: RingStore.shared.get().container, ringID: ringID, metric: metric, days: days, selectedDay: selection)
                    guard !Task.isCancelled, ring.selectedID == ringID, selectedMetric == metric, rangeDays == days, selectedDay == selection else { return }
                    latestReadings = snapshot.latest
                    trendSourceCount = snapshot.sourceCount
                    var previousBucket: Date?, series = 0
                    readings = snapshot.readings.map {
                        if let previousBucket, Calendar.current.date(byAdding: days == 1 ? .hour : .day, value: 1, to: previousBucket)! < $0.date { series += 1 }
                        previousBucket = $0.date
                        return DisplayReading(id: $0.storageKey(ringID: ringID), metric: $0.metric, value: $0.value, date: $0.date, observed: $0.isObservationTime, series: series)
                    }
                    hrvBaseline = snapshot.hrvBaseline
                } catch {
                    guard !Task.isCancelled else { return }
                    ring.log("Dashboard history could not be loaded.")
                }
            }
            .onChange(of: ring.selectedID) { _, _ in
                readings = []; latestReadings = [:]; trendSourceCount = 0
                hrvBaseline = HRVBaseline(readings: [], before: Date())
            }
            .onChange(of: selectedMetric) { _, _ in readings = []; trendSourceCount = 0 }
            .onChange(of: rangeDays) { _, _ in readings = []; trendSourceCount = 0 }
            .onChange(of: selectedDay) { _, _ in
                readings = []; latestReadings = [:]; trendSourceCount = 0; isLoadingHistory = true
                hrvBaseline = HRVBaseline(readings: [], before: displayDay)
            }
            .sheet(isPresented: $showingDatePicker) {
                HistoryDayPicker(day: displayDay, onSelect: selectDay)
            }
            .sheet(item: $referenceMetric) { metric in
                MetricReferenceView(metric: metric, value: latest(metric)?.value, context: .resting, hrvBaseline: hrvBaseline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingDatePicker = true } label: {
                        Label("Choose date", systemImage: "calendar").labelStyle(.iconOnly)
                    }.accessibilityValue(displayDay.formatted(date: .complete, time: .omitted))
                        .accessibilityIdentifier("history-date-picker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { ring.readBattery(); ring.sync() } label: {
                        if ring.isSyncing { ProgressView() } else { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    }.disabled(!ring.historyReady || ring.isSyncing)
                }
            }
        }
    }
    private func selectDay(_ date: Date) {
        selectedDay = Calendar.current.isDateInToday(date) ? nil : Calendar.current.startOfDay(for: date)
    }
    private var activityCard: some View {
        HStack(spacing: 22) {
            let steps = latest(.steps)
            let stepGoal = max(1, dailyStepGoal)
            let progress = max(0, (steps?.value ?? 0) / Double(stepGoal))
            NavigationLink {
                StepHistoryView(selectedDay: selectedDay)
            } label: {
                stepRing(progress: progress, reading: steps, goal: stepGoal)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens step history.")
            .accessibilityIdentifier("step-history-link")
            VStack(alignment: .leading, spacing: 18) {
                activityLine(.calories, goal: Double(dailyCalorieGoal), tint: .orange)
                activityLine(.distance, goal: dailyDistanceGoal, tint: .cyan)
                if steps == nil {
                    Text(isViewingToday ? "Sync your ring to start today’s activity." : "No activity recorded for this day.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(22).frame(maxWidth: .infinity).background(RingPalette.card, in: RoundedRectangle(cornerRadius: 26))
    }
    private func stepRing(progress: Double, reading: RingReading?, goal: Int) -> some View {
        ZStack {
            Circle().stroke(RingPalette.mint.opacity(0.12), lineWidth: 13)
            Circle().trim(from: 0, to: min(progress, 1))
                .stroke(RingPalette.mint, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                Circle().trim(from: 0, to: min(progress - 1, 1))
                    .stroke(Color(red: 1, green: 0.82, blue: 0.49), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(13)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 4) {
                Image(systemName: "figure.walk").font(.title2).foregroundStyle(RingPalette.mint)
                Text(reading.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—").font(.title2.bold()).contentTransition(.numericText())
                Text("of \(goal.formatted()) steps")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 136, height: 136)
        .contentShape(Circle())
        .accessibilityElement(children: .combine)
    }
    private func activityLine(_ metric: RingMetric, goal: Double, tint: Color) -> some View {
        let reading = latest(metric)
        let hasGoal = goal.isFinite && goal > 0
        let current = reading.map { "\(format($0.value, metric: metric)) \(metric.unit)" } ?? "— \(metric.unit)"
        return VStack(alignment: .leading, spacing: 4) {
            Label(metric.title, systemImage: metric.symbol).font(.caption).foregroundStyle(tint)
            if hasGoal {
                let target = Text(" / \(goal.formatted())").font(.subheadline).foregroundStyle(.secondary)
                Text("\(Text(current))\(target)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text(current).font(.headline)
            }
            if hasGoal, let reading {
                ProgressView(value: min(max(0, reading.value), goal), total: goal)
                    .tint(tint)
                    .accessibilityLabel("\(metric.title) goal progress")
            }
        }
    }
    private func metricCard(_ metric: RingMetric) -> some View {
        let reading = latest(metric)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: metric.symbol).foregroundStyle(metric == .heartRate ? .pink : RingPalette.mint)
                    .accessibilityHidden(true)
                Spacer()
                Button { referenceMetric = metric } label: {
                    Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(metric.title) reference ranges")
            }
            Button { selectedMetric = metric } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(metric.title).font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(reading.map { format($0.value, metric: metric) } ?? "—")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text(metric.unit).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reading, let category = metric == .hrv ? hrvBaseline.category(value: reading.value) : MetricReferences.category(for: metric, value: reading.value, profile: references.profile, context: .resting) {
                        ReferenceCategoryBadge(category: category)
                    }
                    if let reading {
                        Text(reading.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(isViewingToday ? "Awaiting first reading" : "No readings on this day").font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(RingPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(selectedMetric == metric ? RingPalette.mint.opacity(0.5) : .clear).allowsHitTesting(false))
    }
    private var trendCard: some View {
        let start = historyWindow.trendStart, end = historyWindow.chartEnd
        let values = readings.filter { $0.metric == selectedMetric && $0.date >= start && $0.date <= end }
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(selectedMetric.title).font(.title3.bold())
                Spacer()
                Button { referenceMetric = selectedMetric } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reference ranges")
            }
            if let latest = values.last {
                HStack(spacing: 10) {
                    Text("\(latest.value.formatted(.number.precision(.fractionLength(0...1)))) \(selectedMetric.unit)")
                        .font(.title2.weight(.semibold))
                    if let category = selectedMetric == .hrv
                        ? hrvBaseline.category(value: latest.value)
                        : MetricReferences.category(for: selectedMetric, value: latest.value, profile: references.profile, context: .resting) {
                        ReferenceCategoryBadge(category: category, tint: TrendBands(metric: selectedMetric, reference: referenceBand)?.color(at: latest.value))
                    }
                }
            }
            Picker("Time range", selection: $rangeDays) {
                Text(isViewingToday ? "Today" : "Day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }.pickerStyle(.segmented)
            if values.isEmpty {
                ContentUnavailableView(isLoadingHistory ? "Loading readings…" : (isViewingToday ? "Your trends start here" : "No readings for this period"), systemImage: "chart.xyaxis.line", description: Text(isLoadingHistory ? "" : "Choose another date or sync to check for recorded history."))
                    .frame(height: 190)
            } else {
                RingTrendPlot(values: values, metric: selectedMetric, rangeDays: rangeDays, start: start, end: end, band: referenceBand, sourceCount: trendSourceCount)
            }
        }.padding(20).background(RingPalette.card, in: RoundedRectangle(cornerRadius: 24))
    }
    private func format(_ value: Double, metric: RingMetric) -> String {
        value.formatted(.number.precision(.fractionLength(metric == .distance ? 1 : 0)))
    }
}

struct HistoryDayPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ring: RingBluetooth
    @State private var day: Date
    @State private var visibleMonth: Date
    @State private var availableDays: Set<Date> = []
    @State private var loadingAvailability = true
    @State private var availabilityFailed = false
    @State private var availabilityContext = ""
    private let metric: RingMetric?
    let onSelect: (Date) -> Void
    init(day: Date, metric: RingMetric? = nil, onSelect: @escaping (Date) -> Void) {
        _day = State(initialValue: day)
        _visibleMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: day)!.start)
        self.metric = metric
        self.onSelect = onSelect
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HistoryAvailabilityCalendar(day: $day, visibleMonth: $visibleMonth, availableDays: availableDays)
                    .fixedSize(horizontal: false, vertical: true)
                Label(metric == .steps ? "Days with saved step readings" : "Days with saved dashboard readings", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.mint)
                if loadingAvailability {
                    ProgressView("Checking this month…").font(.caption)
                } else if availabilityFailed {
                    Text("Couldn’t load date markers. You can still choose a date.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(availableDays.contains(Calendar.current.startOfDay(for: day)) ? "Saved readings are available for this day." : (metric == nil ? "No dashboard readings saved for this day." : "No readings saved for this day."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("A dot means some readings were saved, not necessarily a complete day.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(20)
                .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show day") { onSelect(day); dismiss() }
                    }
                }
                .task(id: "\(visibleMonth)|\(ring.selectedID)|\(ring.historyRevision)|\(Calendar.current.timeZone.identifier)") {
                    let scope = "\(visibleMonth)|\(ring.selectedID)|\(Calendar.current.timeZone.identifier)"
                    if availabilityContext != scope { availableDays = []; availabilityContext = scope }
                    loadingAvailability = true; availabilityFailed = false
                    do {
                        let days = try await RingSnapshotLoader.availableDashboardDays(container: RingStore.shared.get().container, ringID: ring.selectedID, month: visibleMonth, metric: metric)
                        guard !Task.isCancelled else { return }
                        availableDays = days
                    } catch {
                        guard !Task.isCancelled else { return }
                        availabilityFailed = true
                    }
                    loadingAvailability = false
                }
        }.presentationDetents([.large])
    }
}

/// UICalendarView exposes native day decorations while retaining the system's
/// month/year navigation. Availability is provided by the visible-month query.
struct HistoryAvailabilityCalendar: UIViewRepresentable {
    @Binding var day: Date
    @Binding var visibleMonth: Date
    let availableDays: Set<Date>
    var calendar: Calendar = .current
    var onSelectRecordedDay: ((Date) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = calendar; view.timeZone = calendar.timeZone; view.locale = .current
        view.availableDateRange = DateInterval(start: .distantPast, end: Date())
        view.tintColor = .systemMint
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.accessibilityIdentifier = "history-date-input"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setVisibleDateComponents(calendar.dateComponents([.era, .year, .month], from: visibleMonth), animated: false)
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let size = uiView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: size.height)
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; coordinator.updating = true
        defer { coordinator.updating = false }
        let changed = coordinator.decoratedDays.symmetricDifference(availableDays)
        coordinator.decoratedDays = availableDays
        if onSelectRecordedDay == nil, let selection = view.selectionBehavior as? UICalendarSelectionSingleDate {
            let selected = selection.selectedDate.flatMap { calendar.date(from: $0) }
            if selected == nil || !calendar.isDate(selected!, inSameDayAs: day) {
                selection.setSelected(calendar.dateComponents([.era, .year, .month, .day], from: day), animated: false)
            }
        }
        if !changed.isEmpty {
            view.reloadDecorations(forDateComponents: changed.map { calendar.dateComponents([.era, .year, .month, .day], from: $0) }, animated: false)
        }
    }
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: HistoryAvailabilityCalendar
        var decoratedDays: Set<Date> = []
        var updating = false
        init(parent: HistoryAvailabilityCalendar) { self.parent = parent }
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = parent.calendar.date(from: dateComponents), decoratedDays.contains(parent.calendar.startOfDay(for: date)) else { return nil }
            return .default(color: .systemMint, size: .small)
        }
        func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previousDateComponents: DateComponents) {
            guard !updating, let date = parent.calendar.date(from: calendarView.visibleDateComponents), let month = parent.calendar.dateInterval(of: .month, for: date)?.start else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.visibleMonth != month else { return }
                self.parent.visibleMonth = month
            }
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard !updating, let dateComponents, let date = parent.calendar.date(from: dateComponents) else { return }
            if let onSelect = parent.onSelectRecordedDay {
                onSelect(parent.calendar.startOfDay(for: date))
            } else {
                parent.day = date
            }
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            guard let dateComponents, let date = parent.calendar.date(from: dateComponents) else { return false }
            let day = parent.calendar.startOfDay(for: date)
            if parent.onSelectRecordedDay != nil { return decoratedDays.contains(day) }
            return day <= parent.calendar.startOfDay(for: Date())
        }
    }
}

/// Presentation is independent of database loading so chart layouts can be
/// checked with synthetic data without injecting sample data into the live app.
struct RingTrendPlot: View {
    let values: [DisplayReading]
    let metric: RingMetric
    let rangeDays: Int
    let start: Date
    let end: Date
    let band: ClosedRange<Double>?
    let sourceCount: Int
    @State var selectedDate: Date? = nil
    var selectedReading: DisplayReading? {
        guard let selectedDate,
              let interval = Calendar.current.dateInterval(of: rangeDays == 1 ? .hour : .day, for: selectedDate) else { return nil }
        return values.first { $0.metric == metric && $0.date >= interval.start && $0.date < interval.end }
    }
    private var selectedPeriodStart: Date? {
        selectedDate.flatMap { Calendar.current.dateInterval(of: rangeDays == 1 ? .hour : .day, for: $0)?.start }
    }
    var body: some View {
        let bands = TrendBands(metric: metric, reference: band)
        let domain = bands?.domain(including: values.map(\.value))
        Chart {
            if let bands, let domain {
                bands.background(in: domain)
            }
            ForEach(values) { item in
                let isLatest = item.id == values.last?.id
                let pointColor = isLatest ? (bands?.color(at: item.value) ?? RingPalette.mint) : RingPalette.mint
                LineMark(x: .value("Time", item.date), y: .value(metric.title, item.value), series: .value("Recorded periods", item.series))
                    .foregroundStyle(RingPalette.mint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Time", item.date), y: .value(metric.title, item.value))
                    .foregroundStyle(pointColor)
                    .symbolSize(isLatest ? 55 : 24)
            }
            if let date = selectedPeriodStart {
                if let reading = selectedReading {
                    PointMark(x: .value("Selected time", reading.date), y: .value(metric.title, reading.value))
                        .foregroundStyle(RingPalette.mint).symbolSize(80)
                }
                RuleMark(x: .value("Selected period", date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartSelectionCallout(at: selectedPeriodStart) {
            if let date = selectedPeriodStart {
                VStack(alignment: .leading, spacing: 4) {
                    Text(date, format: rangeDays == 1 ? .dateTime.month(.abbreviated).day().hour() : .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                    if let reading = selectedReading {
                        Text("\(reading.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                            .font(.subheadline.bold()).foregroundStyle(RingPalette.mint)
                        Text(rangeDays == 1 ? "Hourly average" : "Daily average").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("No readings").font(.subheadline)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .sensoryFeedback(.selection, trigger: selectedPeriodStart) { _, period in
            period != nil
        }
        .trendYScale(domain)
        .chartXScale(domain: start...end, range: .plotDimension(padding: 6))
        .trendYAxis(bands)
        .chartXAxis {
            if rangeDays > 1 {
                AxisMarks(values: .stride(by: .day, count: rangeDays == 7 ? 1 : 7)) { value in
                    if let date = value.as(Date.self), date < end {
                        AxisGridLine()
                        AxisValueLabel(anchor: date <= start ? .topLeading : .top) {
                            Text(date, format: rangeDays == 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                                .font(.caption2).fixedSize()
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel(anchor: date <= start ? .topLeading : .top) {
                            Text(date, format: .dateTime.hour().minute()).font(.caption2).fixedSize()
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
        .frame(height: 190)
        .accessibilityLabel("\(metric.title), \(sourceCount) recorded readings, \(values.count) \(rangeDays > 1 ? "daily averages" : "hourly averages")")
        .accessibilityHint("Touch and slide across the chart to read an average.")
        .onChange(of: metric) { _, _ in selectedDate = nil }
        .onChange(of: rangeDays) { _, _ in selectedDate = nil }
        .onChange(of: start) { _, _ in selectedDate = nil }
    }
}

struct TrendBands {
    let thresholds: [Double]
    private let colors: [Color]
    private let inclusiveLowerBands: Set<Int>

    init?(metric: RingMetric, reference: ClosedRange<Double>? = nil) {
        let mint = RingPalette.mint
        let blue = Color(red: 0.54, green: 0.80, blue: 1)
        let amber = Color(red: 1, green: 0.82, blue: 0.49)
        let coral = Color(red: 1, green: 0.63, blue: 0.63)
        switch metric {
        case .heartRate, .respiration, .hrv:
            guard let reference else { return nil }
            thresholds = [reference.lowerBound, reference.upperBound]
            let outer = metric == .respiration ? amber : blue
            colors = [outer, mint, metric == .heartRate ? amber : outer]
            inclusiveLowerBands = [1]
        case .oxygen:
            thresholds = [88, 92, 95]
            colors = [coral, .orange, amber, mint]
            inclusiveLowerBands = [0, 1]
        case .stress, .fatigue:
            thresholds = [30, 60, 80]
            colors = [mint, blue, amber, coral]
            inclusiveLowerBands = []
        case .mood:
            thresholds = [34, 67]
            colors = [amber, blue, mint]
            inclusiveLowerBands = []
        case .pai:
            thresholds = [25, 50, 80]
            colors = [coral, amber, blue, mint]
            inclusiveLowerBands = []
        default:
            return nil
        }
    }

    func color(at value: Double) -> Color {
        let index = thresholds.enumerated().first { index, threshold in
            value < threshold || (value == threshold && inclusiveLowerBands.contains(index))
        }?.offset ?? thresholds.count
        return colors[index]
    }

    func domain(including values: [Double]) -> ClosedRange<Double> {
        let limits = values.filter(\.isFinite) + thresholds
        let lower = limits.min() ?? 0
        let upper = limits.max() ?? 1
        let padding = max(1, (upper - lower) * 0.08)
        return max(0, lower - padding)...(upper + padding)
    }

    @ChartContentBuilder
    func background(in domain: ClosedRange<Double>) -> some ChartContent {
        let edges = [domain.lowerBound] + thresholds + [domain.upperBound]
        ForEach(colors.indices, id: \.self) { index in
            RectangleMark(yStart: .value("Band lower edge", edges[index]),
                          yEnd: .value("Band upper edge", edges[index + 1]))
                .foregroundStyle(colors[index].opacity(0.10))
                .accessibilityHidden(true)
        }
    }
}

extension View {
    @ViewBuilder
    func trendYScale(_ domain: ClosedRange<Double>?) -> some View {
        if let domain {
            chartYScale(domain: domain)
        } else {
            chartYScale(domain: .automatic(includesZero: false))
        }
    }

    func trendYAxis(_ bands: TrendBands?) -> some View {
        chartYAxis {
            if let bands {
                AxisMarks(position: .trailing, values: Set(bands.thresholds).sorted()) { value in
                    trendAxisMark(value)
                }
            } else {
                AxisMarks(position: .trailing) { value in
                    trendAxisMark(value)
                }
            }
        }
    }

    @AxisMarkBuilder
    private func trendAxisMark(_ value: AxisValue) -> some AxisMark {
        AxisGridLine()
        AxisValueLabel(horizontalSpacing: 12) {
            if let number = value.as(Double.self) {
                Text(number, format: .number.precision(.fractionLength(0...1)))
                    .font(.caption2).fixedSize()
            }
        }
    }

    func chartSelectionCallout<Callout: View>(at date: Date?, @ViewBuilder content: () -> Callout) -> some View {
        let callout = content()
        return chartOverlay { proxy in
            GeometryReader { geometry in
                if let date, let frame = proxy.plotFrame, let x = proxy.position(forX: date) {
                    let plot = geometry[frame]
                    callout
                        .padding(10)
                        .background(RingPalette.card, in: RoundedRectangle(cornerRadius: 10))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trend-selected-value")
                        .frame(width: plot.width, height: plot.height, alignment: x > plot.width / 2 ? .topLeading : .topTrailing)
                        .position(x: plot.midX, y: plot.midY)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
