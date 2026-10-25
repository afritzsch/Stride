import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKeyDraft = ""

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $model.engine) {
                        ForEach(AIEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch model.engine {
                    case .claude:
                        SecureField("Anthropic API key", text: $apiKeyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button(model.apiKey.isEmpty ? "Save key" : "Update key") {
                            model.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            apiKeyDraft = ""
                        }
                        .disabled(apiKeyDraft.isEmpty)
                        if !model.apiKey.isEmpty {
                            LabeledContent("Saved key", value: "••••" + model.apiKey.suffix(4))
                            Button("Remove key", role: .destructive) { model.apiKey = "" }
                        }
                    case .onDevice:
                        LabeledContent("Status", value: OnDeviceAnalyzer.unavailableReason ?? "Ready")
                    }
                } header: {
                    Text("AI engine")
                } footer: {
                    switch model.engine {
                    case .claude:
                        Text("Uses Claude Opus 5.5 with your own key from [platform.claude.com](https://platform.claude.com). A summary of your health data is sent to Anthropic for each analysis. The key is stored in the Keychain.")
                    case .onDevice:
                        Text("Runs privately on your iPhone with Apple Intelligence. Free and offline, but the analysis is shorter and looks at less history.")
                    }
                }

                Section("About you") {
                    TextField("Primary sport", text: $model.profile.primarySport)
                    Picker("Experience", selection: $model.profile.experience) {
                        ForEach(ExperienceLevel.allCases) { Text($0.title).tag($0) }
                    }
                    OptionalNumberField(title: "Age", value: $model.profile.age, range: 10...100)
                    OptionalNumberField(title: "Max heart rate", value: $model.profile.maxHeartRate, range: 120...230)
                    if model.profile.isMaxHeartRateEstimated {
                        LabeledContent("Estimated max HR", value: "\(Int(model.profile.effectiveMaxHeartRate)) bpm")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Availability") {
                    Stepper("Training days: \(model.profile.trainingDaysPerWeek)/week", value: $model.profile.trainingDaysPerWeek, in: 1...7)
                    Stepper("Time: \(Format.number(model.profile.weeklyHoursAvailable, digits: 1)) h/week", value: $model.profile.weeklyHoursAvailable, in: 1...25, step: 0.5)
                }

                Section("Goal") {
                    Toggle("Training for an event", isOn: $model.profile.hasGoal)
                    if model.profile.hasGoal {
                        TextField("Event, e.g. Berlin Half Marathon", text: $model.profile.goalName)
                        DatePicker("Date", selection: $model.profile.goalDate, in: Date.now..., displayedComponents: .date)
                        TextField("Target, e.g. sub 1:45", text: $model.profile.goalTarget)
                    }
                }

                Section("Daily targets") {
                    Stepper("Sleep: \(Format.number(model.profile.sleepTargetHours, digits: 1)) h", value: $model.profile.sleepTargetHours, in: 5...10, step: 0.25)
                    Stepper("Steps: \(model.profile.dailyStepTarget.formatted())", value: $model.profile.dailyStepTarget, in: 2000...25000, step: 500)
                }

                Section {
                    ForEach(FocusArea.allCases) { area in
                        Toggle(isOn: Binding(
                            get: { model.profile.focusAreas.contains(area) },
                            set: { isOn in
                                if isOn { model.profile.focusAreas.insert(area) } else { model.profile.focusAreas.remove(area) }
                            }
                        )) {
                            Label(area.title, systemImage: area.systemImage)
                        }
                    }
                } header: {
                    Text("What should the coach focus on?")
                }

                Section {
                    TextField("Injuries, schedule constraints, preferences…", text: $model.profile.notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes for the coach")
                }

                Section {
                    Toggle("Use demo data", isOn: $model.useDemoData)
                    if !model.useDemoData {
                        Button("Connect Apple Health") {
                            Task { await model.connectHealth() }
                        }
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Stride reads everything from Apple Health, so it works with any watch or app that syncs there (Apple Watch, Garmin, and others). Brand-specific scores such as Garmin Body Battery or Training Readiness aren't shared with Apple Health, so the coach estimates recovery from resting HR, HRV, and sleep instead.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct OptionalNumberField: View {
    var title: String
    @Binding var value: Int?
    var range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            TextField("Not set", value: Binding(
                get: { value },
                set: { value = $0.map { min(max($0, range.lowerBound), range.upperBound) } }
            ), format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }
    }
}
