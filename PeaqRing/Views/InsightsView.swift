import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @EnvironmentObject private var references: ReferencePreferences
    @State private var showingPAIReference = false
    @EnvironmentObject private var ring: RingBluetooth
    @State private var allSleep: [RingSleepSegment] = []
    @State private var includedSleep: [RingSleepSegment] = []
    @AppStorage(SleepCorrectionStore.revisionKey) private var sleepCorrectionRevision = 0
    @State private var workouts: [RingWorkout] = []
    @State private var readings: [RingReading] = []
    @State private var selectedPAITime: Date?
    @State private var selectedSleepDay: Date?
    private var pai: RingReading? { readings.first }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Beyond the daily numbers").font(.subheadline).foregroundStyle(.secondary)
                    weeklyReviewLink
                    SleepInsightsCard(sleep: allSleep, includedSleep: includedSleep) { selectedSleepDay = $0 }.id(ring.selectedID)
                    paiCard
                    exerciseCard
                }.padding(20)
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.065))
            .navigationTitle("Insights")
            .navigationDestination(item: $selectedSleepDay) { day in
                SleepNightDetail(day: day)
            }
            .task(id: "\(ring.selectedID)|\(ring.historyRevision)|\(sleepCorrectionRevision)") {
                let ringID = ring.selectedID
                do {
                    let snapshot = try await RingSnapshotLoader.insights(container: RingStore.shared.get().container, ringID: ringID)
                    guard !Task.isCancelled, ring.selectedID == ringID else { return }
                    allSleep = snapshot.sleep; includedSleep = snapshot.includedSleep; workouts = snapshot.workouts; readings = snapshot.pai
                } catch {
                    guard !Task.isCancelled else { return }
                    ring.log("Insights history could not be loaded.")
                }
            }
            .onChange(of: ring.selectedID) { _, _ in
                allSleep = []; includedSleep = []; workouts = []; readings = []
                selectedPAITime = nil; selectedSleepDay = nil
            }
            .sheet(isPresented: $showingPAIReference) { MetricReferenceView(metric: .pai, value: pai?.value) }
        }
    }
    private var weeklyReviewLink: some View {
        let period = WeeklyReviewPeriod()
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: period.end) ?? period.start
        let dates = (period.start..<lastDay).formatted(.interval.month(.abbreviated).day())
        return NavigationLink {
            WeeklyReviewView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(.mint)
                    .frame(width: 36, height: 36)
                    .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly review").font(.headline)
                    Text("\(dates) · Compare with the prior week").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .insightCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("weekly-review-link")
    }

    private var paiCard: some View {
        let bands = TrendBands(metric: .pai)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("PAI Vitality Index", systemImage: "sparkles").font(.title2.bold()).foregroundStyle(.mint)
                Spacer()
                infoButton("About PAI and ranges") { showingPAIReference = true }
            }
            HStack(spacing: 12) {
                Text(pai.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                if let pai, let category = MetricReferences.category(for: .pai, value: pai.value, profile: references.profile) {
                    insightBadge(category.title, color: bands?.color(at: pai.value) ?? category.tone.color)
                }
            }
            if let pai {
                Text("Ring-reported PAI").font(.caption.weight(.semibold)).foregroundStyle(.mint)
                Text("Activity date: \(pai.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Based on the previous day’s activity. Matched against the original app.")
                    .font(.subheadline).foregroundStyle(.secondary)
                let history = readings.prefix(14).reversed().map { $0 }
                if let first = history.first, let last = history.last, first.date < last.date {
                    let domain = bands?.domain(including: history.map(\.value))
                    let day = selectedPAITime.map { Calendar.current.startOfDay(for: $0) }
                    let selected = day.flatMap { day in history.first { Calendar.current.isDate($0.date, inSameDayAs: day) } }
                    Chart {
                        if let bands, let domain {
                            bands.background(in: domain)
                        }
                        ForEach(history, id: \.date) { item in
                            LineMark(x: .value("Activity date", item.date), y: .value("PAI", item.value)).foregroundStyle(.mint)
                            PointMark(x: .value("Activity date", item.date), y: .value("PAI", item.value))
                                .foregroundStyle(item.date == last.date ? bands?.color(at: item.value) ?? .mint : .mint)
                                .symbolSize(item.date == selected?.date ? 80 : (item.date == last.date ? 55 : 24))
                        }
                        if let date = selected?.date ?? day {
                            RuleMark(x: .value("Selected day", date))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(dash: [3, 3]))
                        }
                    }
                    .trendYScale(domain)
                    .trendYAxis(bands)
                    .chartXScale(domain: first.date...last.date, range: .plotDimension(padding: 6))
                    .chartSelectionCallout(at: selected?.date ?? day) {
                        if let day {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(.caption).foregroundStyle(.secondary)
                                if let selected {
                                    Text("\(selected.value.formatted(.number.precision(.fractionLength(0)))) PAI")
                                        .font(.subheadline.bold()).foregroundStyle(.mint)
                                } else {
                                    Text("No score recorded").font(.subheadline)
                                }
                            }
                        }
                    }
                    .chartXSelection(value: $selectedPAITime)
                    .sensoryFeedback(.selection, trigger: day) { _, day in day != nil }
                    .accessibilityHint("Touch and slide to read a daily PAI score.")
                    .frame(height: 130)
                }
            } else {
                Text("Awaiting first PAI score").font(.headline)
                Text("Your ring’s daily score will appear after syncing.").font(.subheadline).foregroundStyle(.secondary)
            }
        }.insightCard().accessibilityIdentifier("pai-panel")
    }
    private var exerciseCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Exercise records", systemImage: "figure.run").font(.title2.bold()).foregroundStyle(.orange)
            if workouts.isEmpty {
                Text("No exercise records received").font(.headline)
                Text("Completed sessions stored by the ring will appear here after syncing. Sessions kept only in the original app cannot be imported through the ring.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(workouts.prefix(20)), id: \.displayKey) { workout in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Exercise session").font(.headline)
                            Spacer()
                            Text(duration(workout.end.timeIntervalSince(workout.start))).font(.subheadline.weight(.medium))
                        }
                        Text(workout.start, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        Text("\(workout.steps.formatted()) steps · \(workout.calories.formatted(.number.precision(.fractionLength(0)))) kcal")
                            .font(.subheadline)
                        if let heartRate = workout.averageHeartRate {
                            Text("\(heartRate) bpm average").font(.caption)
                            if let zone = MetricReferences.category(for: .heartRate, value: Double(heartRate), profile: references.profile, context: .exercise) {
                                ReferenceCategoryBadge(category: zone)
                            }
                        }
                        if let distance = workout.distanceMetres {
                            Text("\((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
            }
            Text("Session details await comparison with the original app.").font(.caption).foregroundStyle(.secondary)
        }.insightCard()
    }
    private func infoButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private func insightBadge(_ title: String, color: Color) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
}

private func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

private enum SleepTrendMode: Hashable {
    case duration
    case timing
}

private struct SleepInsightsCard: View {
    let sleep: [RingSleepSegment]
    let includedSleep: [RingSleepSegment]
    let onSelectNight: (Date) -> Void
    @EnvironmentObject private var ring: RingBluetooth
    @AppStorage(SleepCorrectionStore.revisionKey) private var sleepCorrectionRevision = 0
    @State private var range = 1
    @State private var mode = SleepTrendMode.duration
    @State private var showingInfo = false
    @State private var showingCalendar = false
    @State private var calendarSelection: Date?
    @State private var summaries: [Date: RingSleepNightSummary]?
    @State private var loadedFirstDay: Date?
    @State private var trendFailed = false

    private var latestDay: Date? {
        sleep.last { $0.stage != .awake }.map { RingSnapshotLoader.sleepDay(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Sleep", systemImage: "bed.double.fill").font(.title2.bold()).foregroundStyle(.indigo)
                Spacer()
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About sleep duration")
            }
            if let latestDay {
                Picker("Sleep range", selection: $range) {
                    Text("Latest night").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                if range > 1 {
                    Picker("Sleep chart mode", selection: $mode) {
                        Text("Duration").tag(SleepTrendMode.duration)
                        Text("Timing").tag(SleepTrendMode.timing)
                    }
                    .pickerStyle(.segmented)
                }
                let calendar = Calendar.current
                let firstDay = calendar.date(byAdding: .day, value: 1 - range, to: latestDay)!
                HStack {
                    Group {
                        if range == 1 {
                            Text("Woke \(latestDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                        } else {
                            Text(firstDay..<latestDay, format: .interval.month(.abbreviated).day())
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingCalendar = true
                    } label: {
                        Label("Calendar", systemImage: "calendar").font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.indigo)
                    .accessibilityLabel("Open sleep calendar")
                }
                if range == 1 {
                    if includedSleep.isEmpty {
                        Text("No overnight sleep included").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        SleepNightTimeline(sleep: includedSleep)
                    }
                    Button { onSelectNight(latestDay) } label: {
                        Label("View night", systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.indigo)
                } else if loadedFirstDay == firstDay, let summaries {
                    let days = (0..<range).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
                    SleepTrend(days: days, summaries: summaries, mode: mode, onSelect: onSelectNight)
                        .id(firstDay)
                } else if trendFailed {
                    Text("Couldn’t load sleep history.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading sleep history…")
                }
            } else {
                Text("Your next night starts here").font(.headline)
                Text("Wear your ring while you sleep. Recorded sleep will sync automatically when available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .insightCard()
        .sheet(isPresented: $showingInfo) { SleepBadgeInfo() }
        .sheet(isPresented: $showingCalendar, onDismiss: {
            guard let day = calendarSelection else { return }
            calendarSelection = nil
            onSelectNight(day)
        }) {
            NavigationStack {
                SleepHistoryCalendar(initialMonth: min(latestDay ?? Date(), Date())) { day in
                    calendarSelection = day
                    showingCalendar = false
                }
                .navigationTitle("Sleep calendar")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCalendar = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .task(id: "\(range)|\(latestDay?.timeIntervalSince1970 ?? 0)|\(ring.historyRevision)|\(sleepCorrectionRevision)") {
            trendFailed = false
            guard range > 1, let latestDay else { return }
            let calendar = Calendar.current
            let first = calendar.date(byAdding: .day, value: 1 - range, to: latestDay)!
            do {
                let result = try await RingSnapshotLoader.sleepNightSummaries(container: RingStore.shared.get().container,
                    ringID: ring.selectedID, from: first, through: latestDay, calendar: calendar)
                guard !Task.isCancelled else { return }
                loadedFirstDay = first
                summaries = result
            } catch {
                guard !Task.isCancelled else { return }
                trendFailed = true
            }
        }
    }
}

private struct SleepTrend: View {
    let days: [Date]
    let summaries: [Date: RingSleepNightSummary]
    let mode: SleepTrendMode
    let onSelect: (Date) -> Void
    @State private var selection: Int?

    private var selectedIndex: Int { selection ?? days.count - 1 }
    private var included: [RingSleepNightSummary] { summaries.values.filter { $0.asleepDuration > 0 } }
    private var axisRange: ClosedRange<Double> {
        if mode == .duration {
            return 0...max(10, (included.map(\.asleepDuration).max() ?? 0) / 3600)
        }
        let first = (included.map(\.startOffset).min() ?? 0) / 3600
        let last = (included.map(\.endOffset).max() ?? 0) / 3600
        // Negative values put early clock times at the top of the chart.
        return -max(9, (last / 3).rounded(.up) * 3)...(-min(-3, (first / 3).rounded(.down) * 3))
    }

    private func clock(_ offset: TimeInterval) -> String {
        Date(timeIntervalSinceReferenceDate: offset).formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .timing {
                Text("Ring clock time").font(.headline)
                Text("\(included.count) of \(days.count) nights included")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let average = included.isEmpty ? nil : included.reduce(0) { $0 + $1.asleepDuration } / Double(included.count)
                Text(average.map(duration) ?? "—").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Average asleep · \(included.count) of \(days.count) nights included")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Chart {
                ForEach(days.indices, id: \.self) { index in
                    if let summary = summaries[days[index]], summary.asleepDuration > 0 {
                        let lower = mode == .timing ? -summary.endOffset / 3600 : 0
                        let upper = mode == .timing ? -summary.startOffset / 3600 : summary.asleepDuration / 3600
                        RectangleMark(xStart: .value("Day start", Double(index) + 0.16),
                                      xEnd: .value("Day end", Double(index) + 0.84),
                                      yStart: .value("Hours", lower), yEnd: .value("Hours", upper))
                            .foregroundStyle(index == selectedIndex ? Color.cyan : Color.indigo)
                            .accessibilityLabel(Text(days[index], format: .dateTime.month().day()))
                            .accessibilityValue(mode == .timing
                                ? "\(clock(summary.startOffset)) to \(clock(summary.endOffset))"
                                : duration(summary.asleepDuration))
                    }
                }
            }
            .chartXScale(domain: 0...Double(days.count))
            .chartYScale(domain: axisRange)
            .chartXAxis {
                let ticks = days.count == 7 ? Array(days.indices) : [0, 7, 14, 21, days.count - 1]
                AxisMarks(values: ticks.map { Double($0) + 0.5 }) { value in
                    AxisValueLabel {
                        if let position = value.as(Double.self), days.indices.contains(Int(position)) {
                            Text(days[Int(position)], format: .dateTime.day())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: mode == .timing ? 3.0 : 5.0)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(mode == .timing ? clock(-hours * 3600) : "\(Int(hours))h")
                        }
                    }
                }
            }
            .chartGesture { proxy in
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    if let value = proxy.value(atX: gesture.location.x, as: Double.self), value.isFinite {
                        selection = Int(min(max(value, 0), Double(days.count - 1)))
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedIndex)
            .accessibilityIdentifier(mode == .timing ? "sleep-timing-trend" : "sleep-duration-trend")
            .accessibilityHint("Touch and slide to select a night.")
            .frame(height: 145)

            let day = days[selectedIndex]
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("sleep-trend-selected-date")
                    if let summary = summaries[day], summary.asleepDuration > 0 {
                        if mode == .timing {
                            Text("\(clock(summary.startOffset)) – \(clock(summary.endOffset))")
                                .font(.subheadline.weight(.medium))
                                .accessibilityIdentifier("sleep-trend-selected-timing")
                            Text("\(duration(summary.asleepDuration)) asleep").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(duration(summary.asleepDuration)) asleep").font(.subheadline.weight(.medium))
                        }
                    } else {
                        Text(summaries[day] == nil ? "No sleep recorded" : "No overnight sleep included")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if summaries[day] != nil {
                    Button { onSelect(day) } label: {
                        Label("View night", systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.indigo)
                }
            }
            if mode == .timing, summaries.values.contains(where: \.usesLocalClock) {
                Text("Older recordings use your current time zone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SleepHistoryCalendar: View {
    @EnvironmentObject private var ring: RingBluetooth
    @State private var visibleMonth: Date
    @State private var availableDays: Set<Date> = []
    @State private var loading = true
    @State private var failed = false
    let onSelect: (Date) -> Void

    init(initialMonth: Date, onSelect: @escaping (Date) -> Void) {
        _visibleMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: initialMonth)!.start)
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HistoryAvailabilityCalendar(day: .constant(visibleMonth), visibleMonth: $visibleMonth,
                                            availableDays: availableDays, onSelectRecordedDay: onSelect)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Sleep recorded", systemImage: "circle.fill").font(.caption).foregroundStyle(.mint)
                if loading {
                    ProgressView("Checking this month…").font(.caption)
                } else if failed {
                    Text("Couldn’t load this month.").font(.subheadline).foregroundStyle(.secondary)
                } else if availableDays.isEmpty {
                    Text("No sleep recorded this month.").font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .task(id: "\(visibleMonth)|\(ring.selectedID)|\(ring.historyRevision)") {
            loading = true
            failed = false
            availableDays = []
            let calendar = Calendar.current
            let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: visibleMonth)!
            do {
                let totals = try await RingSnapshotLoader.sleepTotals(container: RingStore.shared.get().container,
                    ringID: ring.selectedID, from: visibleMonth, through: end, calendar: calendar, includeExcluded: true)
                guard !Task.isCancelled else { return }
                availableDays = Set(totals.keys)
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loading = false
        }
    }
}

private struct SleepNightDetail: View {
    let day: Date
    @EnvironmentObject private var ring: RingBluetooth
    @AppStorage(SleepCorrectionStore.revisionKey) private var sleepCorrectionRevision = 0
    @State private var sessions: [RingSleepSession]?
    @State private var selectedSessionID: String?
    @State private var failed = false

    private var selectedSession: RingSleepSession? {
        sessions?.first { $0.id == selectedSessionID } ?? sessions?.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sleep · Wake-up date")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .textCase(.uppercase)
                    Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("sleep-night-date")
                }
                if let sessions {
                    if sessions.count > 1 {
                        Picker("Sleep session", selection: Binding(
                            get: { selectedSession?.id ?? "" },
                            set: { selectedSessionID = $0 }
                        )) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                Text(sessionLabel(session, index: index)).tag(session.id)
                            }
                        }
                        .accessibilityIdentifier("sleep-session-picker")
                    }
                    if let session = selectedSession {
                        SleepNightTimeline(sleep: session.segments, expanded: true, correction: session.correction)
                            .id(session.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.correction.title).font(.headline)
                                .accessibilityIdentifier("sleep-session-status")
                            Text(session.correction.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .insightCard()
                    } else {
                        Text("No sleep recorded").foregroundStyle(.secondary)
                    }
                } else if failed {
                    Text("Couldn’t load this night.").foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading sleep details…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let session = selectedSession {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if session.correction != .nap {
                            Button("Mark as nap", systemImage: "moon.zzz") {
                                SleepCorrectionStore.set(.nap, for: session, ringID: ring.selectedID)
                            }
                        }
                        if session.correction != .excluded {
                            Button("Exclude from summaries", systemImage: "eye.slash") {
                                SleepCorrectionStore.set(.excluded, for: session, ringID: ring.selectedID)
                            }
                        }
                        if session.correction != .original {
                            Button("Restore original", systemImage: "arrow.uturn.backward") {
                                SleepCorrectionStore.set(.original, for: session, ringID: ring.selectedID)
                            }
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Edit sleep session")
                    .accessibilityIdentifier("sleep-session-edit")
                }
            }
        }
        .task(id: "\(day)|\(ring.selectedID)|\(ring.historyRevision)|\(sleepCorrectionRevision)") {
            failed = false
            let ringID = ring.selectedID
            do {
                let result = try await RingSnapshotLoader.sleepSessions(container: RingStore.shared.get().container,
                    ringID: ringID, day: day)
                guard !Task.isCancelled, ring.selectedID == ringID else { return }
                sessions = result
            } catch {
                guard !Task.isCancelled, ring.selectedID == ringID else { return }
                sessions = nil
                failed = true
            }
        }
    }

    private func sessionLabel(_ session: RingSleepSession, index: Int) -> String {
        let label = session.correction == .nap ? "Nap" : "Session \(index + 1)"
        let first = session.segments.first { $0.stage != .awake }!
        let zone = first.recordedClock == true ? TimeZone(secondsFromGMT: 0)! : .current
        let start = first.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        return "\(label) · \(start)"
    }
}

private struct SleepNightTimeline: View {
    let sleep: [RingSleepSegment]
    var expanded = false
    var correction = SleepCorrection.original
    @State private var selectedSleepTime: Date?

    private var usesRecordedClock: Bool { sleep.contains { $0.recordedClock == true } }
    private var timeFormat: Date.FormatStyle {
        .init(date: .omitted, time: .shortened,
              timeZone: usesRecordedClock ? TimeZone(secondsFromGMT: 0)! : .current)
    }

    private func plotDate(_ date: Date, segment: RingSleepSegment) -> Date {
        usesRecordedClock && segment.recordedClock != true ? RingSnapshotLoader.recordedClockDate(date) : date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let asleep = sleep.filter { $0.stage != .awake }.reduce(0.0) { $0 + $1.duration }
            HStack(spacing: 12) {
                Text(duration(asleep)).font(.system(size: expanded ? 42 : 34, weight: .semibold, design: .rounded))
                if correction == .nap {
                    insightBadge("Nap", color: .indigo)
                } else if correction == .excluded {
                    insightBadge("Excluded", color: .secondary)
                } else if asleep > 0 {
                    let badge = sleepBadge(hours: asleep / 3600)
                    insightBadge(badge.title, color: badge.color)
                        .accessibilityLabel("Sleep duration: \(badge.title)")
                }
            }
            Text("Total asleep").font(.caption).foregroundStyle(.secondary)
            if expanded {
                Divider().padding(.top, 8)
                Text("Sleep stages").font(.headline).accessibilityAddTraits(.isHeader)
            }
            let segment = selectedSleepTime.flatMap { time in
                sleep.last { plotDate($0.start, segment: $0) <= time && time < plotDate($0.end, segment: $0) }
            }
            Chart {
                ForEach(sleep, id: \.start) { record in
                    RectangleMark(xStart: .value("Start", plotDate(record.start, segment: record)),
                                  xEnd: .value("End", plotDate(record.end, segment: record)), y: .value("Stage", axisStage(record.stage.rawValue)), height: 18)
                        .foregroundStyle(stageColor(record.stage.rawValue))
                }
                if let time = selectedSleepTime {
                    RuleMark(x: .value("Selected time", time))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                }
            }
            .chartSelectionCallout(at: selectedSleepTime) {
                VStack(alignment: .leading, spacing: 4) {
                    if let segment {
                        Text(segment.stage.title).font(.subheadline.bold())
                            .foregroundStyle(stageColor(segment.stage.rawValue))
                        Text("\(plotDate(segment.start, segment: segment).formatted(timeFormat)) – \(plotDate(segment.end, segment: segment).formatted(timeFormat))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(duration(segment.end.timeIntervalSince(segment.start))).font(.caption2)
                    } else {
                        Text("No sleep recorded").font(.subheadline)
                    }
                }
            }
            .chartXSelection(value: $selectedSleepTime)
            .sensoryFeedback(.selection, trigger: segment?.start) { _, start in start != nil }
            .onChange(of: sleep.first?.start) { _, _ in selectedSleepTime = nil }
            .accessibilityHint("Touch and slide to read a sleep stage.")
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(date, format: timeFormat) }
                    }
                }
            }
            .chartYScale(domain: -0.5...2.5)
            .chartYAxis {
                AxisMarks(position: expanded ? .leading : .automatic, values: [0, 1, 2]) { value in
                    if expanded { AxisGridLine() }
                    AxisValueLabel {
                        if let code = value.as(Int.self) { Text(RingSleepStage(rawValue: axisStage(code))?.title ?? "") }
                    }
                }
            }
            .frame(height: expanded ? 175 : 140)
            if expanded { Divider() }
            HStack(spacing: 16) {
                ForEach(RingSleepStage.allCases, id: \.rawValue) { stage in
                    let total = sleep.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
                    VStack(alignment: .leading) {
                        Text(stage.title).font(.caption).foregroundStyle(stageColor(stage.rawValue))
                        Text(duration(total)).font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
                }
            }
        }
    }

    private func axisStage(_ code: Int) -> Int {
        expanded ? RingSleepStage.deep.rawValue - code : code
    }

    private func sleepBadge(hours: Double) -> (title: String, color: Color) {
        switch hours {
        case ..<4: return ("Very short", .red)
        case ..<7: return ("Short", .yellow)
        case ...9: return ("Good", .green)
        default: return ("Above target", .blue)
        }
    }

    private func stageColor(_ code: Int) -> Color {
        switch RingSleepStage(rawValue: code) { case .awake: return .orange; case .light: return .cyan; case .deep: return .indigo; case nil: return .gray }
    }
}

private struct SleepBadgeInfo: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var references: ReferencePreferences

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Very short", value: "Under 4h")
                    LabeledContent("Short", value: "4h to under 7h")
                    LabeledContent("Good", value: "7h through 9h")
                    LabeledContent("Above target", value: "Over 9h")
                } header: {
                    Text("App duration badges")
                } footer: {
                    Text("These badges describe the duration recorded by your ring. The recording may miss sleep or naps.")
                }
                Section("Age-based recommendation") {
                    if let guidance = SleepDurationReference(profile: references.profile) {
                        Text(guidance.durationLabel)
                    } else {
                        NavigationLink("Set birth year for sleep guidance") { ReferenceProfileView() }
                    }
                }
            }
            .navigationTitle("Sleep duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    func insightCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(red: 0.075, green: 0.10, blue: 0.115), in: RoundedRectangle(cornerRadius: 24))
    }
}

private extension RingWorkout {
    var displayKey: String { "\(start.timeIntervalSince1970)|\(typeCode ?? -1)" }
}
