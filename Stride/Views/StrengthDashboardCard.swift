import SwiftUI

/// The dashboard's way into the strength screen, shown when there is strength training.
struct StrengthDashboardCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let report = model.strength.report, model.strength.hasStrengthTraining {
            NavigationLink(value: DashboardDestination.strength) {
                Card(title: "Strength", isLink: true) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Format.number(report.sessionsPerWeek, digits: 1))")
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text("sessions a week").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let volume = report.volumeLast28Days, volume > 0 {
                            Text("\(StrengthFormat.tonnes(volume)) in 4 wk").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let last = report.entries.first {
                        Text(lastLine(last))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let record = report.records.first {
                        Label("PB: \(record.title) \(record.set.workText())", systemImage: "trophy.fill")
                            .font(.footnote)
                            .foregroundStyle(.primary, .yellow)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func lastLine(_ entry: StrengthReport.Entry) -> String {
        let date = entry.date.formatted(.dateTime.weekday(.wide))
        guard let session = entry.session else { return "Last: \(entry.title), \(date), \(Int(entry.minutes.rounded())) min" }
        let main = session.exercises.prefix(2).compactMap { exercise in exercise.topSet.map { "\(exercise.title) \($0.workText())" } }
        return "Last: \(entry.title), \(date)" + (main.isEmpty ? "" : " · " + main.joined(separator: ", "))
    }
}

enum StrengthFormat {
    /// "6.2 t" from kg, "850 kg" below a tonne.
    static func tonnes(_ kg: Double) -> String {
        kg >= 1000 ? "\(Format.number(kg / 1000, digits: 1)) t" : "\(Int(kg.rounded())) kg"
    }
}
