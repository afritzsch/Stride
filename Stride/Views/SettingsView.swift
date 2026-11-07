import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("On-device model", value: model.onDeviceBlocker == nil ? "Ready" : "Not ready")
                    if let blocker = model.onDeviceBlocker {
                        Text(blocker).font(.footnote).foregroundStyle(.secondary)
                    }
                    if AppleAnalyzer.isPrivateCloudInBuild {
                        Toggle("Use Private Cloud Compute", isOn: $model.allowPrivateCloud)
                        if model.allowPrivateCloud {
                            LabeledContent("Private Cloud Compute", value: AppleAnalyzer.privateCloudStatus)
                        }
                    } else {
                        LabeledContent("Private Cloud Compute", value: "Needs paid developer account")
                    }
                    Toggle("Review new workouts automatically", isOn: $model.autoReviewWorkouts)
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    if AppleAnalyzer.isPrivateCloudInBuild {
                        Text("Free and private. With Private Cloud Compute on, Apple's larger server model runs the analysis; Apple doesn't store your data. It has a usage limit, and when you reach it or are offline, the smaller on-device model takes over. Turn it off to keep everything on your iPhone.")
                    } else {
                        Text("Free and private: analyses, reviews and the coach chat run on your iPhone with Apple's on-device model. Apple's larger Private Cloud Compute model needs an entitlement that only paid Apple Developer accounts can get.")
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

                HeartRateZonesSection()

                Section("Availability") {
                    Stepper("Training days: \(model.profile.trainingDaysPerWeek)/week", value: $model.profile.trainingDaysPerWeek, in: 1...7)
                    Stepper("Time: \(Format.number(model.profile.weeklyHoursAvailable, digits: 1)) h/week", value: $model.profile.weeklyHoursAvailable, in: 1...25, step: 0.5)
                }

                ScheduleSettingsSection()

                NotificationSettingsSection()

                HevySettingsSection()

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

                DataSection()
            }
            .navigationTitle("Settings")
        }
    }
}

/// Demo data, Apple Health access and the debug export.
private struct DataSection: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var exportIncludesRoutes = false
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        @Bindable var model = model

        Section {
            Toggle("Use demo data", isOn: $model.useDemoData)
            if !model.useDemoData {
                Button("Connect Apple Health") {
                    Task { await model.connectHealth() }
                }
            }
            Toggle("Include GPS routes", isOn: $exportIncludesRoutes)
                .onChange(of: exportIncludesRoutes) { discardExport() }
            Button {
                Task {
                    isExporting = true
                    defer { isExporting = false }
                    do {
                        exportURL = try await model.exportHealthData(includeRoutes: exportIncludesRoutes)
                        exportError = nil
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    Text("Export data for debugging")
                    if isExporting { Spacer(); ProgressView() }
                }
            }
            .disabled(isExporting)
            if let exportURL, FileManager.default.fileExists(atPath: exportURL.path()) {
                ShareLink(item: exportURL) {
                    Label("Share export file", systemImage: "square.and.arrow.up")
                }
            }
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("The debug export contains your raw health data for the last \(HealthKitService.windowWeeks) weeks\(exportIncludesRoutes ? ", including GPS routes that show where you live and train" : "") and is deleted when you leave Settings. Only share it with someone you trust. Stride reads everything from Apple Health, so it works with any watch or app that syncs there (Apple Watch, Garmin, and others). Brand-specific scores such as Garmin Body Battery or Training Readiness aren't shared with Apple Health, so the coach estimates recovery from resting HR, HRV, and sleep instead.")
        }
        .onChange(of: model.selectedTab) { if model.selectedTab != .settings { discardExport() } }
    }

    private func discardExport() {
        AppModel.deleteHealthExport()
        exportURL = nil
    }
}

private struct HeartRateZonesSection: View {
    @Environment(AppModel.self) private var model
    @State private var justCopied = false

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Zones based on", selection: $model.profile.zoneMethod) {
                ForEach(HeartRateZoneMethod.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: model.profile.zoneMethod) { old, method in
                // Start custom zones from the ones shown before the switch, so only the differences need typing.
                guard method == .custom, model.profile.customZoneFloors.count != 4 else { return }
                var previous = model.profile
                previous.zoneMethod = old
                model.profile.customZoneFloors = previous.heartRateZones(restingHR: model.restingHRBaseline).floors.map { Int($0.rounded()) }
            }
            if model.profile.zoneMethod == .custom, model.profile.customZoneFloors.count == 4 {
                ForEach(0..<4, id: \.self) { index in
                    LabeledContent("Zone \(index + 2) starts at") {
                        TextField("bpm", value: $model.profile.customZoneFloors[index], format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            ForEach(Array(model.heartRateZones.ranges.enumerated()).reversed(), id: \.offset) { index, range in
                LabeledContent("Zone \(index + 1)", value: "\(range) bpm")
                    .foregroundStyle(.secondary)
            }
            Button {
                let zones = model.heartRateZones
                UIPasteboard.general.string = zones.garminText(maxHR: model.profile.effectiveMaxHeartRate)
                model.profile.garminZoneFloors = zones.roundedFloors
                justCopied = true
            } label: {
                Label(justCopied ? "Copied" : "Copy for Garmin", systemImage: justCopied ? "checkmark" : "doc.on.doc")
            }
            .onChange(of: model.heartRateZones) { justCopied = false }
            // Resting HR and max HR move the zones, but the bpm values typed into Garmin stay put.
            if let drift = model.heartRateZones.drift(from: model.profile.garminZoneFloors), drift >= 2 {
                Label("Your zones have moved by up to \(drift) bpm since you last copied them. Copy them again and update your watch.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Heart rate zones")
        } footer: {
            switch model.profile.zoneMethod {
            case .maxHeartRate:
                Text("Garmin's default: zones start at 60, 70, 80 and 90% of max HR. If your watch shows different zones, set your max HR above, or pick Custom and copy the zones from Garmin Connect.")
            case .heartRateReserve:
                Text("Percentages of the range between resting HR (your 28-day median, \(Int(model.restingHRBaseline)) bpm) and max HR. If your watch has no % of HR reserve option, copy the zones for Garmin and type the bpm values into Garmin Connect (heart rate zones in your user settings); the watch then uses the same zones.")
            case .custom:
                if !model.profile.hasValidCustomZones {
                    Text("Each zone has to start above the one before it. Until then, % of max HR zones are used.").foregroundStyle(.orange)
                } else {
                    Text("Copy the zones from Garmin Connect (heart rate zones in your user settings), entering where each zone starts.")
                }
            }
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
