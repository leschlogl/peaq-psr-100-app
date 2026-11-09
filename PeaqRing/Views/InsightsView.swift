import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @EnvironmentObject private var references: ReferencePreferences
    @State private var showingPAIReference = false
    @State private var showingSleepInfo = false
    @EnvironmentObject private var ring: RingBluetooth
    @State private var allSleep: [RingSleepSegment] = []
    @State private var workouts: [RingWorkout] = []
    @State private var readings: [RingReading] = []
    @State private var selectedSleepTime: Date?
    @State private var selectedPAITime: Date?
    private var sleep: [RingSleepSegment] {
        let records = allSleep
        guard let last = records.last(where: { $0.stage.rawValue != RingSleepStage.awake.rawValue }) else { return [] }
        let cal = Calendar.current
        var day = cal.startOfDay(for: last.end)
        if cal.component(.hour, from: last.end) >= 19 { day = cal.date(byAdding: .day, value: 1, to: day)! }
        let end = cal.date(bySettingHour: 19, minute: 0, second: 0, of: day)!
        let start = cal.date(byAdding: .day, value: -1, to: end)!
        return records.filter { $0.start >= start && $0.end <= end }
    }
    private var pai: RingReading? { readings.first }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Beyond the daily numbers").font(.subheadline).foregroundStyle(.secondary)
                    sleepCard
                    paiCard
                    exerciseCard
                }.padding(20)
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.065))
            .navigationTitle("Insights")
            .task(id: "\(ring.selectedID)|\(ring.historyRevision)") {
                let ringID = ring.selectedID
                do {
                    let snapshot = try await RingSnapshotLoader.insights(container: RingStore.shared.get().container, ringID: ringID)
                    guard !Task.isCancelled, ring.selectedID == ringID else { return }
                    allSleep = snapshot.sleep; workouts = snapshot.workouts; readings = snapshot.pai
                } catch {
                    guard !Task.isCancelled else { return }
                    ring.log("Insights history could not be loaded.")
                }
            }
            .onChange(of: ring.selectedID) { _, _ in
                allSleep = []; workouts = []; readings = []
                selectedSleepTime = nil; selectedPAITime = nil
            }
            .sheet(isPresented: $showingPAIReference) { MetricReferenceView(metric: .pai, value: pai?.value) }
            .sheet(isPresented: $showingSleepInfo) {
                SleepBadgeInfo()
            }
        }
    }
    private var sleepCard: some View {
        let sleep = sleep
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Sleep", systemImage: "bed.double.fill").font(.title2.bold()).foregroundStyle(.indigo)
                Spacer()
                infoButton("About sleep duration") { showingSleepInfo = true }
            }
            if sleep.isEmpty {
                Text("Your next night starts here").font(.headline)
                Text("Wear your ring while you sleep. Recorded sleep will sync automatically when available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let asleep = sleep.filter { $0.stage.rawValue != RingSleepStage.awake.rawValue }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
                HStack(spacing: 12) {
                    Text(duration(asleep)).font(.system(size: 34, weight: .semibold, design: .rounded))
                    if asleep > 0 {
                        let badge = sleepBadge(hours: asleep / 3600)
                        insightBadge(badge.title, color: badge.color)
                            .accessibilityLabel("Sleep duration: \(badge.title)")
                    }
                }
                if let end = sleep.last?.end { Text(end, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary) }
                let segment = selectedSleepTime.flatMap { time in
                    sleep.last { $0.start <= time && time < $0.end }
                }
                Chart {
                    ForEach(sleep, id: \.start) { record in
                        RectangleMark(xStart: .value("Start", record.start), xEnd: .value("End", record.end), y: .value("Stage", record.stage.rawValue), height: 18)
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
                            Text("\(segment.start.formatted(date: .omitted, time: .shortened)) – \(segment.end.formatted(date: .omitted, time: .shortened))")
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
                .chartYScale(domain: -0.5...2.5)
                .chartYAxis {
                    AxisMarks(values: [0, 1, 2]) { value in
                        AxisValueLabel { if let code = value.as(Int.self) { Text(RingSleepStage(rawValue: code)?.title ?? "") } }
                    }
                }
                .frame(height: 140)
                HStack(spacing: 16) {
                    ForEach(RingSleepStage.allCases, id: \.rawValue) { stage in
                        let total = sleep.filter { $0.stage.rawValue == stage.rawValue }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
                        VStack(alignment: .leading) {
                            Text(stage.title).font(.caption).foregroundStyle(stageColor(stage.rawValue))
                            Text(duration(total)).font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
        }.insightCard()
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
    private func insightBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
    }
    private func sleepBadge(hours: Double) -> (title: String, color: Color) {
        switch hours {
        case ..<4: return ("Very short", .red)
        case ..<7: return ("Short", .yellow)
        case ...9: return ("Good", .green)
        default: return ("Above target", .blue)
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
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
