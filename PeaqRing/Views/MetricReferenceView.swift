import SwiftUI

extension ReferenceTone {
    var color: Color {
        switch self { case .positive: return .mint; case .neutral: return .cyan; case .attention: return .orange; case .high: return .red; case .unavailable: return .secondary }
    }
    var symbol: String {
        switch self { case .positive, .neutral: return "circle.fill"; case .attention, .high: return "exclamationmark.circle.fill"; case .unavailable: return "info.circle" }
    }
}
struct ReferenceCategoryBadge: View {
    let category: MetricCategory
    var tint: Color? = nil
    var body: some View {
        let color = tint ?? category.tone.color
        Label(category.title, systemImage: category.tone.symbol)
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .fixedSize(horizontal: false, vertical: true)
    }
}
struct ReferenceProfileFields: View {
    @EnvironmentObject private var references: ReferencePreferences
    @State private var editingBirthYear = false
    var body: some View {
        Section {
            Button { editingBirthYear = true } label: {
                LabeledContent("Year of birth", value: references.birthYear > 0 ? String(references.birthYear) : "Not set")
            }.foregroundStyle(.primary).accessibilityIdentifier("reference-age")
                .sheet(isPresented: $editingBirthYear) { BirthYearEditor() }
            if references.profile.age != nil {
                LabeledContent(references.birthYear > 0 ? "Reference age this year" : "Previously saved age", value: "\(references.age) years")
            }
            Picker("Sex (optional)", selection: $references.sex) {
                ForEach(ReferenceSex.allCases) { sex in Text(sex.title).tag(sex) }
            }.pickerStyle(.navigationLink).accessibilityIdentifier("reference-sex")
        } header: { Text("Personal details") } footer: {
            Text("Age selects your sleep recommendation and helps estimate maximum heart rate. These optional details stay on this iPhone. Sex is currently saved for your profile.")
        }
        Section {
            TextField("Optional maximum bpm", text: Binding(
                get: { references.maximumHeartRate > 0 ? String(references.maximumHeartRate) : "" },
                set: { references.maximumHeartRate = Int($0) ?? 0 }))
                .keyboardType(.numberPad).accessibilityIdentifier("reference-maximum-heart-rate")
            if let max = references.profile.maximumHeartRate {
                LabeledContent(references.profile.maximumHeartRateOverride == nil ? "Estimated maximum" : "Configured maximum", value: "\(max) bpm")
            } else {
                Text("Set age to estimate maximum heart rate.").foregroundStyle(.secondary)
            }
            if references.maximumHeartRate != 0 && references.profile.maximumHeartRateOverride == nil {
                Text("Enter 60–240 bpm, or leave blank to use the age estimate.").font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("Exercise heart-rate zones") } footer: {
            Text("The age estimate uses 220 − age. A measured maximum can be entered instead. Estimates vary between people and do not set a safe exercise limit.")
        }
    }
}
private struct BirthYearEditor: View {
    @EnvironmentObject private var references: ReferencePreferences
    @Environment(\.dismiss) private var dismiss
    @State private var year = ""
    @FocusState private var focused: Bool
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var valid: Bool {
        year.isEmpty || (year.count == 4 && Int(year).map { (18...120).contains(currentYear - $0) } == true)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Year of birth", text: $year)
                        .keyboardType(.numberPad).focused($focused)
                        .accessibilityIdentifier("birth-year-input")
                    if !valid { Text("Enter a year from \(String(currentYear - 120)) to \(String(currentYear - 18)).").foregroundStyle(.orange) }
                } footer: {
                    Text("Only the year is saved on this iPhone. References use the age you turn this calendar year and update automatically each year. Leave blank to remove your age setting.")
                }
            }.navigationTitle("Year of birth").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { if references.saveBirthYear(Int(year)) { dismiss() } }.disabled(!valid)
                    }
                }
                .onAppear { year = references.birthYear > 0 ? String(references.birthYear) : ""; focused = true }
        }.presentationDetents([.medium, .large])
    }
}
struct ReferenceProfileView: View {
    var body: some View {
        Form { ReferenceProfileFields() }
            .navigationTitle("Reference profile")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct MetricReferenceView: View {
    let metric: RingMetric
    let value: Double?
    @EnvironmentObject private var references: ReferencePreferences
    @Environment(\.dismiss) private var dismiss
    let context: ReadingContext
    let hrvBaseline: HRVBaseline?
    init(metric: RingMetric, value: Double?, context: ReadingContext = .unspecified, hrvBaseline: HRVBaseline? = nil) {
        self.metric = metric; self.value = value; self.context = context; self.hrvBaseline = hrvBaseline
    }
    private var sectionTitle: String {
        if metric == .hrv { return "Your personal baseline" }
        if metric == .respiration { return "Adult resting reference · MedlinePlus" }
        if metric == .oxygen { return "Original app ranges — not clinical cutoffs" }
        if metric == .heartRate && context != .exercise { return "Adult resting reference · AHA" }
        return "Original app references"
    }
    private var profile: ReferenceProfile { references.profile }
    var body: some View {
        NavigationStack {
            Form {
                if metric == .heartRate {
                    Section {
                        LabeledContent("Reading context", value: context.title)
                        Text("The home page uses the resting-heart-rate reference table. Ring history can also include activity; this comparison does not confirm that the reading was recorded at rest.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let value {
                    Section("Reading") {
                        LabeledContent(metric.title, value: "\(value.formatted(.number.precision(.fractionLength(0)))) \(metric.unit)")
                        if let category = metric == .hrv ? hrvBaseline?.category(value: value) : MetricReferences.category(for: metric, value: value, profile: profile, context: context) {
                            ReferenceCategoryBadge(category: category)
                            Text(category.detail).font(.subheadline)
                        }
                    }
                }
                if metric == .heartRate && context == .exercise {
                    Section {
                        NavigationLink("Reference profile") { ReferenceProfileView() }
                        LabeledContent("Age", value: profile.age.map { "\($0) years" } ?? "Not set")
                    }
                }
                Section(sectionTitle) {
                    if metric == .hrv {
                        if let baseline = hrvBaseline, let range = baseline.range, let median = baseline.median {
                            LabeledContent("Personal median", value: "\(median.formatted(.number.precision(.fractionLength(1)))) ms")
                            LabeledContent("Usual band", value: "\(range.lowerBound.formatted(.number.precision(.fractionLength(1))))–\(range.upperBound.formatted(.number.precision(.fractionLength(1)))) ms")
                            LabeledContent("Prior recorded days", value: "\(baseline.dayCount) of 28")
                        } else {
                            Text("Building baseline: \(hrvBaseline?.dayCount ?? 0)/7 prior recorded days within 28 days.")
                        }
                    }
                    ForEach(MetricReferences.rows(for: metric, profile: profile, context: context)) { row in
                        LabeledContent(row.title, value: row.range).font(.subheadline)
                    }
                    referenceNotes
                }
                sources
            }
            .navigationTitle(metric.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    @ViewBuilder private var referenceNotes: some View {
        switch metric {
        case .hrv:
            Text("Your baseline uses the median HRV for each of up to 28 prior calendar days, excluding the displayed day. At least 7 recorded days are needed. The usual band is the middle 50% of those daily medians; days with more samples do not get extra weight. These window and band choices are descriptive app settings, not medically validated cutoffs. A single reading can naturally fall outside the band. Timing and recording conditions may differ, and the ring’s HRV calculation method is not verified.")
        case .respiration:
            Text("MedlinePlus gives 12–20 breaths per minute as a general adult resting reference. This replaces the original age tables and does not require age or sex. Sleep and activity can affect breathing; ring estimates are not diagnostic. Seek urgent medical help for rapid breathing with difficulty breathing, chest pain, or blue/gray lips.")
        case .mood:
            Text("These categories describe the ring’s index. Physiological signals cannot establish a person’s emotional state or diagnose depression. The dashboard uses ‘Low mood index’ for the original app’s lowest band.")
        case .fatigue, .stress:
            Text("Categories reproduce the supplied original-app index bands. They are device estimates, not a medical assessment. Values outside the table are left unclassified.")
        case .pai:
            Text("PAI stands for Personal Activity Intelligence. This app displays the ring’s daily score and uses the supplied category bands. The vendor’s formula is not known here; we do not infer medical history, diet, environment, or life expectancy from it, and age/sex settings do not recalculate PAI.")
        case .oxygen:
            Text("The original app’s 90–100% ‘Normal’ band is not used as a reassuring dashboard category. The primary indicator uses a typical 95–100% reference and flags lower values. A ring estimate cannot diagnose hypoxia. Confirm low results with a medical pulse oximeter; MedlinePlus advises contacting a provider at 92% or below and immediate medical attention at 88% or below.")
        case .heartRate:
            if context == .exercise {
                Text("Zones use the supplied percentage bands with continuous boundaries: 60.5%, for example, falls in the >60–70% zone. ‘Fat-burning’ is the original zone name, not a promise of weight loss. These are exercise references, not intensity recommendations.")
            } else {
                Text("These general adult bands follow the American Heart Association and replace the original app’s age/sex fitness ratings. Rates below 60 can occur during sleep, with training, or with some medicines. Persistent or unexpected changes deserve discussion with a healthcare professional. Seek urgent medical help for a suddenly unusual pulse with chest pain, shortness of breath, dizziness, or fainting. A ring reading alone cannot diagnose a heart condition.")
            }
        default: EmptyView()
        }
    }
    @ViewBuilder private var sources: some View {
        Section("Source and context") {
            if metric == .heartRate && context != .exercise {
                Text("General adult resting reference from the American Heart Association. The ring’s latest pulse is compared with this range; it is not a validated resting-heart-rate summary.").font(.caption).foregroundStyle(.secondary)
            } else if metric == .hrv {
                Text("Personal trend comparison calculated locally from this ring’s recorded HRV. No universal healthy HRV threshold is applied.").font(.caption).foregroundStyle(.secondary)
            } else if metric == .respiration {
                Text("General adult resting reference from MedlinePlus, not a validated sleep-specific range for this ring.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Wellness bands supplied from the original app by you. They have not been independently validated for this ring.").font(.caption).foregroundStyle(.secondary)
            }
            if metric == .respiration { Link("MedlinePlus: Breathing rate", destination: URL(string: "https://medlineplus.gov/ency/article/007198.htm")!) }
            if metric == .oxygen { Link("MedlinePlus: Pulse oximetry", destination: URL(string: "https://medlineplus.gov/lab-tests/pulse-oximetry/")!) }
            if metric == .heartRate {
                Link("American Heart Association: Resting heart rate", destination: URL(string: "https://www.heart.org/en/health-topics/high-blood-pressure/the-facts-about-high-blood-pressure/all-about-heart-rate-pulse")!)
                if context == .exercise { Link("American Heart Association: Exercise heart rates", destination: URL(string: "https://www.heart.org/en/healthy-living/exercise-and-physical-activity/fitness-basics/target-heart-rates")!) }
            }
            if metric == .hrv { Link("Cleveland Clinic: Understanding HRV", destination: URL(string: "https://my.clevelandclinic.org/health/diagnostics/21773-heart-rate-variability-hrv")!) }
        }
    }
}
