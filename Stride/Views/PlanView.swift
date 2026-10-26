import SwiftUI

struct PlanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let latest = model.latestAnalysis {
                        VStack(spacing: 24) {
                            WeekPlanList(analysis: latest)
                            if let adherence = model.planAdherence, !adherence.completed.isEmpty {
                                AdherenceList(days: adherence.completed).id("adherence")
                            }
                        }
                        .padding()
                    } else {
                        ContentUnavailableView(
                            "No plan yet",
                            systemImage: "calendar.badge.plus",
                            description: Text("Run an analysis on the AI Coach tab to get a 7-day plan built around your data.")
                        )
                        .padding(.top, 80)
                    }
                }
                .task {
                    #if DEBUG
                    // -scrollTo adherence (see AppModel+Debug).
                    if let target = UserDefaults.standard.string(forKey: "scrollTo") {
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo(target, anchor: .top)
                    }
                    #endif
                }
            }
            .navigationTitle("This Week")
        }
    }
}

struct WeekPlanList: View {
    var analysis: SavedAnalysis

    private var totalMinutes: Int { analysis.report.weekPlan.map(\.durationMinutes).reduce(0, +) }
    private var sessionCount: Int { analysis.report.weekPlan.filter { $0.intensity != .rest }.count }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("From \(analysis.planStartDate.formatted(date: .abbreviated, time: .omitted)): \(Format.hours(Double(totalMinutes) / 60)) over ^[\(sessionCount) session](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(Array(analysis.report.weekPlan.enumerated()), id: \.offset) { _, day in
                PlannedDayRow(day: day)
            }
        }
    }
}

private struct PlannedDayRow: View {
    var day: PlannedDay

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(day.intensity.color)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(day.day).font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(text: day.intensity.rawValue.capitalized, color: day.intensity.color)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(day.session).font(.headline)
                    if day.durationMinutes > 0 {
                        Text("\(day.durationMinutes) min").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if day.targetZone > 0 {
                        Text("Z\(day.targetZone)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.heartRateZone(day.targetZone - 1))
                    }
                }
                Text(day.details).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// How the days of earlier plans went, newest first.
private struct AdherenceList: View {
    var days: [PlanAdherence.Day]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How last week went").font(.headline)
                Spacer()
                Text(PlanAdherence.summary(of: days)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            ForEach(days.reversed()) { day in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: day.status.systemImage)
                        .foregroundStyle(day.status.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday().day().month())).font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text(day.status.title).font(.caption).foregroundStyle(day.status.color)
                        }
                        Text(day.planned.isRest ? "Rest" : "\(day.planned.session), \(day.planned.durationMinutes) min").font(.subheadline)
                        if !day.workouts.isEmpty {
                            Text("Did: " + day.workouts.map { "\($0.sport) \(Int($0.durationMinutes.rounded())) min" }.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(day.notes, id: \.self) { note in
                            Text(note.prefix(1).capitalized + note.dropFirst()).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if day.id != days.first?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension PlanAdherence.Status {
    var color: Color {
        switch self {
        case .done, .rested: .green
        case .modified: .orange
        case .missed: .red
        case .extra: .purple
        case .pending: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .rested: "moon.zzz.fill"
        case .modified: "arrow.triangle.swap"
        case .missed: "xmark.circle.fill"
        case .extra: "plus.circle.fill"
        case .pending: "clock"
        }
    }
}
