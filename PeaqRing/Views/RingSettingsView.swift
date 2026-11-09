import SwiftUI

enum ActivityGoalDefaults {
    static let stepsKey = "dailyStepGoal"
    static let caloriesKey = "dailyCalorieGoal"
    static let distanceKey = "dailyDistanceGoal"
    static let steps = 8_000
    static let calories = 150
    static let distance = 3.0
}

struct RingSettingsView: View {
    @EnvironmentObject private var ring: RingBluetooth
    var body: some View {
        NavigationStack {
            Form {
                Section("Health") {
                    NavigationLink {
                        ReferenceProfileView()
                    } label: {
                        Label("Reference profile", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        ActivityGoalsEditor()
                    } label: {
                        Label("Daily activity goals", systemImage: "target")
                    }
                }
                Section("Ring") {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        LabeledContent {
                            Text("\(ring.intervalMinutes) min")
                        } label: {
                            Label("Automatic sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                Section {
                    LabeledContent("Reading storage", value: "On this iPhone")
                    LabeledContent("Version", value: "0.1.0")
                } header: {
                    Text("App")
                } footer: {
                    Text("Readings are saved automatically on this iPhone. My PEAQ is an independent app and requires no account or subscription.")
                }
            }.navigationTitle("Settings")
        }
    }
}

private struct SyncSettingsView: View {
    @EnvironmentObject private var ring: RingBluetooth

    var body: some View {
        Form {
            Section {
                Picker("Sync interval", selection: $ring.intervalMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { minutes in
                        Text("Every \(minutes) minutes").tag(minutes)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Sync interval")
            } footer: {
                Text("Your ring syncs automatically when connected. This interval applies while the app is open. iOS controls background updates.")
            }
        }
        .navigationTitle("Automatic sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ActivityGoalsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ActivityGoalDefaults.stepsKey) private var stepGoal = ActivityGoalDefaults.steps
    @AppStorage(ActivityGoalDefaults.caloriesKey) private var calorieGoal = ActivityGoalDefaults.calories
    @AppStorage(ActivityGoalDefaults.distanceKey) private var distanceGoal = ActivityGoalDefaults.distance
    @State private var steps = ""
    @State private var calories = ""
    @State private var distance = ""

    private var enteredSteps: Int? { try? Int(steps, format: .number) }
    private var enteredCalories: Int? { calories.isEmpty ? 0 : try? Int(calories, format: .number) }
    private var enteredDistance: Double? { distance.isEmpty ? 0 : try? Double(distance, format: .number) }
    private var canSave: Bool {
        guard let steps = enteredSteps, let calories = enteredCalories, let distance = enteredDistance else { return false }
        return steps > 0 && calories >= 0 && distance.isFinite && distance >= 0
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Steps") {
                    TextField("Steps", text: $steps).keyboardType(.numberPad)
                }
                LabeledContent("Calories (kcal)") {
                    TextField("Optional", text: $calories).keyboardType(.numberPad)
                        .accessibilityLabel("Calorie goal in kilocalories")
                }
                LabeledContent("Distance (km)") {
                    TextField("Optional", text: $distance).keyboardType(.decimalPad)
                        .accessibilityLabel("Distance goal in kilometers")
                }
            } header: {
                Text("Daily targets")
            } footer: {
                Text("Starter goals are \(ActivityGoalDefaults.steps.formatted()) steps, \(ActivityGoalDefaults.calories.formatted()) kcal, and \(ActivityGoalDefaults.distance.formatted()) km. Leave calories or distance blank to turn off that goal.")
            }
            .multilineTextAlignment(.trailing)
        }
        .navigationTitle("Daily activity goals")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            steps = String(stepGoal)
            calories = calorieGoal > 0 ? String(calorieGoal) : ""
            distance = distanceGoal > 0 ? distanceGoal.formatted(.number.grouping(.never)) : ""
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard canSave, let steps = enteredSteps, let calories = enteredCalories, let distance = enteredDistance else { return }
                    stepGoal = steps
                    calorieGoal = calories
                    distanceGoal = distance
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
