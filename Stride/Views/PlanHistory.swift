import SwiftUI

/// A saved analysis's plan, for past analyses.
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(day.day).font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(text: day.intensity.rawValue.capitalized, color: day.intensity.color)
                }
                PlannedDayContent(day: day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// How the days of earlier plans went, newest first.
struct AdherenceList: View {
    var days: [PlanAdherence.Day]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How last week went").font(.headline)
                Spacer()
                Text(PlanAdherence.summary(of: days)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            DividedForEach(data: days.reversed()) { day in
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
                            Text("Did: " + day.workouts.map(\.sportAndMinutes).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(day.notes, id: \.self) { note in
                            Text(note.prefix(1).capitalized + note.dropFirst()).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
