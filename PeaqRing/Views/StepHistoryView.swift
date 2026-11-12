import Charts
import SwiftUI

struct StepHistoryView: View {
    @EnvironmentObject private var ring: RingBluetooth
    @AppStorage(ActivityGoalDefaults.stepsKey) private var dailyStepGoal = ActivityGoalDefaults.steps
    @State var selectedDay: Date?
    @State private var days = 1
    @State private var showingCalendar = false
    @State private var history: RingStepHistory?
    @State private var loadedRequest: String?

    private var window: RingHistoryWindow { RingHistoryWindow(selectedDay: selectedDay, days: days) }
    private var request: String {
        "\(ring.selectedID)|\(ring.historyRevision)|\(days)|\(window.dayStart)|\(Calendar.current.timeZone.identifier)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Time range", selection: $days) {
                    Text(window.isToday ? "Today" : "Day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("step-history-range")

                VStack(alignment: .leading, spacing: 12) {
                    Text(window.dayStart, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.subheadline).foregroundStyle(.secondary)
                    if loadedRequest != request {
                        ProgressView("Loading steps…").frame(maxWidth: .infinity, minHeight: 180)
                    } else if let history {
                        stepSummary(history.selectedDayTotal)
                        let buckets = history.buckets
                        if buckets.contains(where: { $0.steps != nil }) {
                            StepHistoryChart(buckets: buckets, hourly: days == 1, goal: max(1, dailyStepGoal))
                                .id(request)
                            Text(days == 1
                                 ? "Bars show changes between readings within an hour. Steps across hour boundaries are left out."
                                 : "Each bar shows the last total received for that day. The dashed line marks your daily goal.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            let hasTotal = history.selectedDayTotal != nil
                            ContentUnavailableView(
                                hasTotal ? "Hourly steps unavailable" : "No saved steps",
                                systemImage: "chart.bar",
                                description: Text(hasTotal
                                    ? "Hourly steps need at least two readings within the same hour."
                                    : "Choose another date or sync your ring for a new reading.")
                            )
                        }
                    } else {
                        ContentUnavailableView("Couldn’t load steps", systemImage: "exclamationmark.circle",
                                               description: Text("Try another date or reopen step history."))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RingPalette.card, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(20)
        }
        .background(RingPalette.background)
        .navigationTitle("Step history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCalendar = true } label: {
                    Label("Choose date", systemImage: "calendar").labelStyle(.iconOnly)
                }
                .accessibilityValue(window.dayStart.formatted(date: .complete, time: .omitted))
                .accessibilityIdentifier("step-history-calendar")
            }
        }
        .sheet(isPresented: $showingCalendar) {
            HistoryDayPicker(day: window.dayStart, metric: .steps) { day in
                selectedDay = Calendar.current.isDateInToday(day) ? nil : Calendar.current.startOfDay(for: day)
            }
        }
        .task(id: request) {
            let key = request
            do {
                let result = try await RingSnapshotLoader.stepHistory(
                    container: RingStore.shared.get().container, ringID: ring.selectedID,
                    days: days, selectedDay: selectedDay)
                guard !Task.isCancelled, key == request else { return }
                history = result
            } catch {
                guard !Task.isCancelled, key == request else { return }
                history = nil
                ring.log("Step history could not be loaded.")
            }
            loadedRequest = key
        }
    }

    @ViewBuilder
    private func stepSummary(_ total: Int?) -> some View {
        if let total {
            Text("\(total.formatted()) steps").font(.title.bold()).foregroundStyle(RingPalette.mint)
            Text("Daily goal \(max(1, dailyStepGoal).formatted()) steps")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct StepHistoryChart: View {
    let buckets: [RingStepHistory.Bucket]
    let hourly: Bool
    let goal: Int
    @State private var selection: Int?

    private var maximum: Double {
        Double(max(1, hourly ? 0 : goal, buckets.compactMap(\.steps).max() ?? 0)) * 1.08
    }

    private var tickPositions: [Double] {
        let stride = hourly ? 4 : (buckets.count == 7 ? 1 : 7)
        return buckets.indices.filter { $0.isMultiple(of: stride) }.map { Double($0) + 0.5 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selection.map { bucketLabel(buckets[$0]) } ?? (hourly ? "Steps by hour" : "Daily steps"))
                    .font(.headline)
                Spacer()
                if let selection {
                    Text(buckets[selection].steps.map { "\($0.formatted()) steps" } ?? "No reading")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(RingPalette.mint)
                }
            }
            .accessibilityElement(children: .combine)
            Chart {
                if !hourly {
                    RuleMark(y: .value("Daily goal", goal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Daily goal")
                        .accessibilityValue("\(goal.formatted()) steps")
                }
                if let selection {
                    RuleMark(x: .value("Selected time", Double(selection) + 0.5))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .accessibilityHidden(true)
                }
                ForEach(buckets.indices, id: \.self) { index in
                    let bucket = buckets[index]
                    if let steps = bucket.steps {
                        let tint = RingPalette.mint.opacity(selection == nil || selection == index ? 1 : 0.5)
                        if steps == 0 {
                            PointMark(x: .value("Time", Double(index) + 0.5), y: .value("Steps", 0))
                                .symbolSize(16)
                                .foregroundStyle(tint)
                                .accessibilityLabel(bucketLabel(bucket))
                                .accessibilityValue("0 steps")
                        } else {
                            RectangleMark(xStart: .value("Start", Double(index) + 0.17),
                                          xEnd: .value("End", Double(index) + 0.83),
                                          yStart: .value("Minimum", 0), yEnd: .value("Steps", steps))
                                .foregroundStyle(tint)
                                .accessibilityLabel(bucketLabel(bucket))
                                .accessibilityValue("\(steps.formatted()) steps")
                        }
                    }
                }
            }
            .chartXScale(domain: 0...Double(buckets.count))
            .chartYScale(domain: 0...maximum)
            .chartXAxis {
                AxisMarks(values: tickPositions) { value in
                    AxisValueLabel {
                        if let position = value.as(Double.self) {
                            let start = buckets[Int(position)].start
                            if hourly {
                                Text(start, format: .dateTime.hour()).font(.caption2)
                            } else {
                                Text(start, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel(horizontalSpacing: 8) {
                        if let amount = value.as(Double.self), amount.rounded() == amount {
                            Text(amount, format: .number.notation(.compactName)).font(.caption2).fixedSize()
                        }
                    }
                }
            }
            .chartGesture { proxy in
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    if let position = proxy.value(atX: gesture.location.x, as: Double.self), position.isFinite {
                        selection = Int(min(max(position, 0), Double(buckets.count - 1)))
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selection) { _, next in next != nil }
            .accessibilityHint("Touch and slide to select a bar.")
            .accessibilityIdentifier("step-history-chart")
            .frame(height: 190)
        }
    }

    private func bucketLabel(_ bucket: RingStepHistory.Bucket) -> String {
        if hourly {
            return bucket.start.formatted(.dateTime.hour().minute())
        }
        return bucket.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
