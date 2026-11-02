import SwiftUI

/// Which issue a sheet edits: a new one or an existing one.
struct HealthIssueSheet: Identifiable {
    var issue: HealthIssue?
    var id: UUID { issue?.id ?? Self.newID }
    private static let newID = UUID()
}

extension HealthIssue {
    var systemImage: String { kind == .pain ? "bandage" : "thermometer.medium" }

    /// "Moderate · day 3", "Gone since 2 Nov".
    var statusLine: String {
        if let resolvedOn { return "Gone since \(resolvedOn.formatted(.dateTime.day().month()))" }
        let day = (Calendar.current.dateComponents([.day], from: started, to: Calendar.current.startOfDay(for: .now)).day ?? 0) + 1
        return "\(severity.title) · day \(max(day, 1))" + (trend.map { " · \($0)" } ?? "")
    }
}

extension HealthIssue.Severity {
    var color: Color {
        switch self {
        case .mild: .yellow
        case .moderate: .orange
        case .severe: .red
        }
    }

    func explanation(for kind: HealthIssue.Kind) -> String {
        switch (kind, self) {
        case (.pain, .mild): "Noticeable, but it doesn't change how you move."
        case (.pain, .moderate): "It changes how you move, or gets worse while training."
        case (.pain, .severe): "It hurts at rest or when walking."
        case (.illness, .mild): "A few symptoms; you feel mostly fine."
        case (.illness, .moderate): "You're clearly unwell."
        case (.illness, .severe): "You're in bed."
        }
    }
}

/// The Today card's part for the health log: ongoing issues with a quick check-in, planned days that don't fit, and
/// a way to log something new.
struct HealthTodaySection: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: HealthIssueSheet?

    var body: some View {
        let ongoing = model.healthLog.ongoing
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ongoing) { issue in
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.subheadline.bold())
                            Text(issue.statusLine).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: issue.systemImage).foregroundStyle(issue.severity.color)
                    }
                    Spacer()
                    Menu("How is it today?") {
                        ForEach(HealthIssue.Severity.allCases) { severity in
                            Button {
                                model.checkIn(issue.id, severity: severity)
                            } label: {
                                if severity == issue.severity { Label(severity.title, systemImage: "checkmark") } else { Text(severity.title) }
                            }
                        }
                        Button("It's gone", systemImage: "checkmark.circle") { model.resolveHealthIssue(issue.id) }
                        Button("Edit…", systemImage: "pencil") { sheet = HealthIssueSheet(issue: issue) }
                    }
                    .font(.caption)
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            let conflicts = model.healthConflicts
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflicts.count == 1 ? "This planned day doesn't fit what you logged:" : "These \(conflicts.count) planned days don't fit what you logged:")
                        .font(.footnote)
                    ForEach(conflicts, id: \.date) { conflict in
                        Text("\(DayTitle.text(for: conflict.date)): \(conflict.planned.session) → \(conflict.fixed.isRest ? "rest" : conflict.fixed.session)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Change these days", systemImage: "wand.and.stars") { model.resolveHealthConflicts() }
                        .buttonStyle(.borderedProminent)
                        .font(.subheadline)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            }

            HStack {
                Button("Log pain or illness", systemImage: "cross.case") { sheet = HealthIssueSheet(issue: nil) }
                    .font(.footnote)
                Spacer()
                if !model.healthIssues.isEmpty {
                    NavigationLink("Health log", value: DashboardDestination.healthLog).font(.footnote)
                }
            }
        }
    }
}

/// "Today", "Tomorrow" or "Thursday 30 Oct".
enum DayTitle {
    static func text(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return Format.day(date)
    }
}

/// Logs a new issue or edits one: what and where, how bad today, since when, and a note. Shows what it means for
/// the plan before saving.
struct HealthIssueEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: HealthIssue?
    @State private var issue: HealthIssue
    @State private var severity: HealthIssue.Severity
    @State private var started: Date
    @State private var confirmsDelete = false

    init(issue: HealthIssue?) {
        original = issue
        let draft = issue ?? HealthIssue(kind: .pain, bodyPart: .calf, side: .left, severity: .mild, started: .now)
        _issue = State(initialValue: draft)
        _severity = State(initialValue: draft.severity)
        _started = State(initialValue: draft.started)
    }

    private var isNew: Bool { original == nil }

    /// The issue as it would be saved.
    private var result: HealthIssue {
        var result = issue
        if isNew {
            result.checkIns = [HealthIssue.CheckIn(date: Calendar.current.startOfDay(for: started), severity: severity)]
        } else if severity != issue.severity {
            result.checkIn(severity, on: .now)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        Picker("Kind", selection: $issue.kind) {
                            ForEach(HealthIssue.Kind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if issue.kind == .pain {
                        Picker("Where", selection: $issue.bodyPart) {
                            ForEach(HealthIssue.BodyPart.allCases) { Text($0.title).tag($0) }
                        }
                        if issue.bodyPart.hasSide {
                            Picker("Side", selection: $issue.side) {
                                ForEach(HealthIssue.Side.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    } else {
                        Picker("What", selection: $issue.illness) {
                            ForEach(HealthIssue.Illness.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }

                Section {
                    Picker(isNew ? "How bad" : "How bad today", selection: $severity) {
                        ForEach(HealthIssue.Severity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if isNew {
                        DatePicker("Since", selection: $started, in: ...Date.now, displayedComponents: .date)
                    }
                } footer: {
                    Text(severity.explanation(for: issue.kind) + " " + planEffect)
                }

                Section("Note") {
                    TextField("e.g. tight after the long run, worse on stairs", text: $issue.note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let original {
                    if original.checkIns.count > 1 {
                        Section("Check-ins") {
                            ForEach(original.checkIns.reversed(), id: \.date) { checkIn in
                                LabeledContent(checkIn.date.formatted(.dateTime.weekday().day().month()), value: checkIn.severity.title)
                            }
                        }
                    }
                    Section {
                        if original.isOngoing {
                            Button("It's gone", systemImage: "checkmark.circle") {
                                model.resolveHealthIssue(original.id)
                                dismiss()
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "Log pain or illness" : issue.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveHealthIssue(result)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let original { model.deleteHealthIssue(original.id) }
                    dismiss()
                }
            }
        }
    }

    /// What the plan does with it, in the same words the plan check uses.
    private var planEffect: String {
        let saved = result
        guard saved.isOngoing, let limit = saved.limit(on: .now) else {
            return "Your coach knows about it but your plan stays as it is."
        }
        let what = limit.maxIntensity == .rest ? "Your plan: rest" : "Your plan: \(limit.summary)"
        return "\(what) for the next \(HealthIssue.horizonDays) days. Check in when it changes."
    }
}

/// Every logged issue, ongoing first.
struct HealthLogView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: HealthIssueSheet?

    var body: some View {
        let issues = model.healthIssues
        List {
            let ongoing = issues.filter(\.isOngoing)
            let past = issues.filter { !$0.isOngoing }.reversed()
            if !ongoing.isEmpty {
                Section("Ongoing") { ForEach(ongoing) { row($0) } }
            }
            if !past.isEmpty {
                Section("Past") { ForEach(Array(past)) { row($0) } }
            }
            if issues.isEmpty {
                Text("Nothing logged. When something hurts or you're ill, log it here: your plan adjusts and your coach takes it into account.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Health log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Log pain or illness", systemImage: "plus") { sheet = HealthIssueSheet(issue: nil) }
            }
        }
        .sheet(item: $sheet) { HealthIssueEditor(issue: $0.issue) }
    }

    private func row(_ issue: HealthIssue) -> some View {
        Button {
            sheet = HealthIssueSheet(issue: issue)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).foregroundStyle(.primary)
                    Text("Since \(issue.started.formatted(.dateTime.day().month())) · \(issue.statusLine)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !issue.note.isEmpty {
                        Text(issue.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: issue.systemImage).foregroundStyle(issue.isOngoing ? issue.severity.color : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
