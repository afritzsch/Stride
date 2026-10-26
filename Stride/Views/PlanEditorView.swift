import SwiftUI

/// The fields of one planned day.
struct PlanDayForm: View {
    @Binding var day: PlannedDay
    /// Sport to use when a rest day becomes a training day.
    var defaultSport: String

    private static let trainingSports = PlannedDay.sports.filter { $0 != PlannedDay.rest }

    var body: some View {
        Section {
            Toggle("Rest day", isOn: Binding(
                get: { day.isRest },
                set: { rest in
                    if rest {
                        day = PlannedDay(day: day.day, sport: PlannedDay.rest, intensity: .rest, session: PlannedDay.rest, durationMinutes: 0, targetZone: 0, details: day.details)
                    } else {
                        day = PlannedDay(day: day.day, sport: defaultSport, intensity: .easy, session: "", durationMinutes: 45, targetZone: 2, details: day.details)
                    }
                }
            ))
        }
        if !day.isRest {
            Section("Session") {
                Picker("Sport", selection: titleKeeping(\.sport)) {
                    // Plans saved before sports existed have none; keep that selectable until it's changed.
                    if !Self.trainingSports.contains(day.sport) { Text(day.sport.isEmpty ? "Not set" : day.sport).tag(day.sport) }
                    ForEach(Self.trainingSports, id: \.self) { Text($0).tag($0) }
                }
                Picker("Intensity", selection: titleKeeping(\.intensity)) {
                    ForEach([SessionIntensity.easy, .moderate, .hard], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Title", text: $day.session, prompt: Text(day.defaultTitle))
                Stepper("Duration: \(day.durationMinutes) min", value: $day.durationMinutes, in: 5...360, step: 5)
                Picker("Heart-rate zone", selection: $day.targetZone) {
                    Text("No target").tag(0)
                    ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
                }
            }
        }
        Section("Details") {
            TextField("Structure, pace, notes…", text: $day.details, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    /// Changing sport or intensity clears a title that was just the default for the old values, so the new
    /// default shows instead of e.g. "Easy run" on a ride.
    private func titleKeeping<Value>(_ keyPath: WritableKeyPath<PlannedDay, Value>) -> Binding<Value> {
        Binding(
            get: { day[keyPath: keyPath] },
            set: { value in
                let wasDefault = day.session.isEmpty || day.session == day.defaultTitle
                day[keyPath: keyPath] = value
                if wasDefault { day.session = "" }
            }
        )
    }
}

/// Edits one day. Saving makes it the athlete's own day, which the coach's plans don't override.
struct PlanDayEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var date: Date
    @State private var draft: PlannedDay

    init(date: Date, initial: PlannedDay?) {
        self.date = date
        _draft = State(initialValue: initial ?? PlannedDay(
            day: PromptBuilder.dayLabel(date, calendar: .current), sport: "Running", intensity: .easy, session: "",
            durationMinutes: 45, targetZone: 2, details: ""
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                PlanDayForm(day: $draft, defaultSport: model.defaultPlanSport)
                if model.isAthletePlanned(on: date), let coach = model.coachSession(on: date) {
                    Section {
                        Button("Use the coach's plan", systemImage: "arrow.uturn.backward") {
                            model.removeAthleteDay(on: date)
                            dismiss()
                        }
                    } header: {
                        Text("Coach's plan")
                    } footer: {
                        Text(coach.briefDescription)
                    }
                }
                let problems = problemsWithDraft
                if !problems.isEmpty {
                    Section("The next 7 days would break these rules") {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
            }
            .navigationTitle(Format.day(date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setAthleteDay(draft, on: date)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Rule problems in today and the next 6 days with this day changed, if it's one of them.
    private var problemsWithDraft: [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard dates.contains(where: { calendar.isDate($0, inSameDayAs: date) }) else { return [] }
        let days = dates.map { calendar.isDate($0, inSameDayAs: date) ? draft : model.plannedSession(on: $0) }
        return WeekPlanEditor.problems(days: days, dates: dates, profile: model.profile)
    }
}

/// Plans today and the next 6 days at once. Only days that change become the athlete's own.
struct WeekPlanEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var dates: [Date]
    private var original: [PlannedDay]
    @State private var drafts: [PlannedDay]

    init(dates: [Date], initial: [PlannedDay?]) {
        self.dates = dates
        let days = zip(dates, initial).map { date, day in day ?? Self.restDay(on: date) }
        original = days
        _drafts = State(initialValue: days)
    }

    var body: some View {
        NavigationStack {
            List {
                let problems = Self.problems(days: drafts, dates: dates, profile: model.profile)
                if !problems.isEmpty {
                    Section("Check") {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
                Section {
                    ForEach(dates.indices, id: \.self) { index in
                        NavigationLink {
                            Form { PlanDayForm(day: $drafts[index], defaultSport: model.defaultPlanSport) }
                                .navigationTitle(Format.day(dates[index]))
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            row(index)
                        }
                    }
                } header: {
                    Text("\(Format.hours(Double(drafts.map(\.durationMinutes).reduce(0, +)) / 60)) over ^[\(drafts.filter { !$0.isRest }.count) session](inflect: true)")
                } footer: {
                    Text("Days you change stay as you planned them. The next weekly analysis keeps them and plans the other days around them. Available: \(model.profile.trainingDaysPerWeek) days, \(Format.number(model.profile.weeklyHoursAvailable, digits: 1)) h a week.")
                }
            }
            .navigationTitle("Plan your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for index in dates.indices where drafts[index] != original[index] {
                            model.setAthleteDay(drafts[index], on: dates[index])
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let day = drafts[index]
        return HStack(spacing: 12) {
            Circle().fill(day.intensity.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(dates[index].formatted(.dateTime.weekday(.abbreviated).day())).font(.caption.bold()).foregroundStyle(.secondary)
                Text(day.isRest ? "Rest" : (day.session.isEmpty ? day.defaultTitle : day.session))
            }
            Spacer()
            if day.durationMinutes > 0 {
                Text(day.durationAndZone).foregroundStyle(.secondary)
            }
            if day != original[index] {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.blue).accessibilityLabel("Changed")
            }
        }
    }

    static func restDay(on date: Date) -> PlannedDay {
        PlannedDay(
            day: PromptBuilder.dayLabel(date, calendar: .current), sport: PlannedDay.rest, intensity: .rest,
            session: PlannedDay.rest, durationMinutes: 0, targetZone: 0, details: ""
        )
    }

    /// `PlanCheck` rules for seven days; days without a plan count as rest. The rules are phrased for the model,
    /// so "the athlete" becomes "you".
    static func problems(days: [PlannedDay?], dates: [Date], profile: UserProfile) -> [String] {
        let calendar = Calendar.current
        let labels = dates.map { PromptBuilder.dayLabel($0, calendar: calendar) }
        let plan = PlanCheck.normalized(zip(dates, days).map { date, day in day ?? restDay(on: date) }, labels: labels)
        return PlanCheck.problems(plan, labels: labels, profile: profile).map {
            $0.replacingOccurrences(of: "the athlete trains", with: "you train")
                .replacingOccurrences(of: "the athlete has", with: "you have")
        }
    }
}

extension AppModel {
    /// The athlete's primary sport when it's one the plan knows, otherwise running.
    var defaultPlanSport: String {
        PlannedDay.sports.first { $0.caseInsensitiveCompare(profile.primarySport) == .orderedSame && $0 != PlannedDay.rest } ?? "Running"
    }
}
