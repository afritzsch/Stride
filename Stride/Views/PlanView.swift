import SwiftUI

struct PlanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                if let latest = model.latestAnalysis {
                    WeekPlanList(analysis: latest).padding()
                } else {
                    ContentUnavailableView(
                        "No plan yet",
                        systemImage: "calendar.badge.plus",
                        description: Text("Run an analysis on the AI Coach tab to get a 7-day plan built around your data.")
                    )
                    .padding(.top, 80)
                }
            }
            .navigationTitle("This Week")
        }
    }
}

struct WeekPlanList: View {
    var analysis: SavedAnalysis

    private var totalMinutes: Int { analysis.report.weekPlan.map(\.durationMinutes).reduce(0, +) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Planned: \(Format.hours(Double(totalMinutes) / 60)) over \(analysis.report.weekPlan.filter { $0.intensity != .rest }.count) sessions")
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
                }
                Text(day.details).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}
