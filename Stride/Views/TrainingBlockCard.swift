import SwiftUI

extension TrainingPhase {
    var color: Color {
        switch self {
        case .base: .teal
        case .build: .blue
        case .peak: .orange
        case .taper: .purple
        case .race: .red
        case .general: .gray
        }
    }
}

/// Where the next week sits in the training block toward the goal: the phase, its focus, and the weeks to come.
struct TrainingBlockCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let week = model.trainingBlockWeek
        let outline = model.trainingBlockOutline
        Card(title: "Training block") {
            StatusBadge(text: week.isRecovery ? "Recovery week" : week.phase.title, color: week.phase.color)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(week)).font(.subheadline.bold())
                Text(week.phase.focus.prefix(1).uppercased() + week.phase.focus.dropFirst() + ".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(limits(week))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if outline.count > 1 {
                PhaseStrip(weeks: outline)
            } else if outline.isEmpty {
                Text("Set a goal event in Settings to plan base, build, peak and taper weeks toward it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func headline(_ week: BlockWeek) -> String {
        guard let weeks = week.weeksToGoal else {
            return week.isRecovery ? "Time for an easier week" : "Building fitness, no goal set"
        }
        let goal = PromptBuilder.goalTitle(model.profile)
        let title = week.phaseWeek.map { week.phase == .race ? week.phase.title : "\(week.phase.title), week \($0.index) of \($0.count)" } ?? week.phase.title
        return weeks == 0 ? "\(title): \(goal) this week" : "\(title) · \(weeks) week\(weeks == 1 ? "" : "s") to \(goal)"
    }

    private func limits(_ week: BlockWeek) -> String {
        var text = "Next 7 days: at most \(week.maxHardSessions) hard session\(week.maxHardSessions == 1 ? "" : "s")"
        if week.isRecovery {
            text += ", about \(Int(TrainingBlock.recoveryShare * 100))% of your usual volume, after three loading weeks"
        }
        return text + "."
    }
}

/// One bar per week to the goal, colored by phase; recovery weeks are lighter and the next week is outlined.
private struct PhaseStrip: View {
    var weeks: [BlockWeek]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(week.phase.color.opacity(week.isRecovery ? 0.35 : 0.85))
                        .frame(height: 14)
                        .overlay {
                            if index == 0 {
                                RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1.5)
                            }
                        }
                }
            }
            HStack(spacing: 10) {
                ForEach(phases, id: \.self) { phase in
                    HStack(spacing: 4) {
                        Circle().fill(phase.color).frame(width: 7, height: 7)
                        Text(phase.title)
                    }
                }
                if weeks.contains(where: \.isRecovery) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                        Text("Recovery")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var phases: [TrainingPhase] {
        var seen: [TrainingPhase] = []
        for week in weeks where !seen.contains(week.phase) { seen.append(week.phase) }
        return seen
    }

    private var accessibilitySummary: String {
        phases.map { phase in
            let count = weeks.filter { $0.phase == phase }.count
            return "\(phase.title) \(count) week\(count == 1 ? "" : "s")"
        }.joined(separator: ", ")
    }
}
