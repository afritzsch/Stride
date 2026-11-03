import Charts
import SwiftUI

/// Strength training over the last 8 weeks. With Hevy connected: volume, main lifts and personal bests;
/// otherwise what the watch records (sessions, time, heart rate).
struct StrengthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let strength = model.strength
        ScrollView {
            VStack(spacing: 16) {
                if let report = strength.report {
                    SourceCard()
                    SummaryGrid(report: report)
                    WeeklyChart(report: report)
                    if report.hasLog {
                        if !report.lifts.isEmpty { LiftsCard(lifts: report.lifts) }
                        if !report.records.isEmpty { RecordsCard(records: report.records) }
                    } else {
                        HeartRateTrendCard(entries: report.entries)
                    }
                    SessionsCard(entries: Array(report.entries.prefix(12)))
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding()
        }
        .navigationTitle("Strength")
        .refreshable { await strength.sync(force: true) }
        .task { await strength.sync() }
    }
}

/// Where the data comes from, and how to get more.
private struct SourceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let strength = model.strength
        switch strength.source {
        case .hevy:
            Card {
                HStack {
                    Label("Hevy\(strength.accountName.map { " · \($0)" } ?? "")", systemImage: "dumbbell.fill")
                        .font(.subheadline.bold())
                    Spacer()
                    if strength.isSyncing {
                        ProgressView()
                    } else if let lastSync = strength.lastSync {
                        Text("Synced \(lastSync, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = strength.syncError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
        case .demo:
            Label("Demo Hevy log. Connect Hevy in Settings to see your own lifts.", systemImage: "wand.and.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .none:
            ConnectHevyCard()
        }
    }
}

/// Shown where a lifting log would add something, with a way to Settings.
struct ConnectHevyCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            Label("From your watch", systemImage: "applewatch")
                .font(.subheadline.bold())
            Text("Apple Health only gets time and heart rate for strength sessions. Connect Hevy to see exercises, sets, weights and personal bests here and in coach reviews.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Connect Hevy in Settings", systemImage: "link") {
                model.selectedTab = .settings
            }
            .font(.subheadline)
        }
    }
}

private struct SummaryGrid: View {
    var report: StrengthReport

    private var stats: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = [
            ("Per week", "\(Format.number(report.sessionsPerWeek, digits: 1)) sessions"),
            ("Time per week", "\(Int(report.minutesPerWeek.rounded())) min"),
        ]
        if let last = report.lastSession {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last), to: Calendar.current.startOfDay(for: .now)).day ?? 0
            items.append(("Last session", days == 0 ? "Today" : days == 1 ? "Yesterday" : "\(days) days ago"))
        }
        if let volume = report.volumeLast28Days {
            items.append(("Volume, 4 wk", StrengthFormat.tonnes(volume)))
            let sets = report.last28Days.compactMap(\.session).map(\.workingSets.count).reduce(0, +)
            items.append(("Sets per week", Format.number(Double(sets) / 4, digits: 0)))
        }
        return items
    }

    var body: some View {
        StatGrid(stats: stats)
    }
}

private struct WeeklyChart: View {
    var report: StrengthReport

    var body: some View {
        let usesVolume = report.hasLog && report.weeks.contains { ($0.volumeKg ?? 0) > 0 }
        Card(title: usesVolume ? "Weekly volume" : "Weekly strength time") {
            Chart(report.weeks) { week in
                BarMark(
                    x: .value("Week", week.start, unit: .weekOfYear),
                    y: .value(usesVolume ? "Tonnes" : "Minutes", usesVolume ? (week.volumeKg ?? 0) / 1000 : week.minutes)
                )
                .foregroundStyle(Color.purple)
                .cornerRadius(4)
                .annotation(position: .top) {
                    if week.sessions > 0 {
                        Text("\(week.sessions)×").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .biweeklyDateAxis()
            .chartYAxisLabel(usesVolume ? "t" : "min")
            .frame(height: 160)
            Text(usesVolume ? "Weight × reps of working sets per week; the number on top is sessions." : "Minutes of strength, core, climbing, yoga and mobility per week; the number on top is sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LiftsCard: View {
    var lifts: [StrengthReport.Lift]

    var body: some View {
        Card(title: "Main lifts") {
            DividedForEach(data: lifts) { lift in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lift.title).font(.subheadline.bold()).lineLimit(1)
                        Text("\(lift.latestTopSet.map { "Top set \($0.workText())" } ?? "") · \(lift.timesDone)×")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if lift.history.count > 1 {
                        Chart(lift.history, id: \.date) { point in
                            LineMark(x: .value("Date", point.date), y: .value("1RM", point.oneRepMax))
                                .foregroundStyle(.purple)
                                .interpolationMethod(.monotone)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(width: 64, height: 28)
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(StrengthSet.kg((lift.latest ?? 0).rounded())).font(.subheadline.bold()).monospacedDigit()
                        if let change = lift.change, abs(change) >= 0.5 {
                            Text("\(change > 0 ? "+" : "−")\(StrengthSet.kg(abs(change).rounded()))")
                                .font(.caption)
                                .foregroundStyle(change > 0 ? .green : .orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Estimated one-rep max of the best working set (Epley, sets up to 12 reps), change over 8 weeks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecordsCard: View {
    var records: [StrengthReport.Record]

    var body: some View {
        Card(title: "Personal bests") {
            ForEach(records.prefix(6)) { record in
                HStack {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.subheadline)
                        Text(record.date, format: .dateTime.weekday().day().month())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(record.set.workText()).font(.subheadline).monospacedDigit()
                        Text("est. \(StrengthSet.kg(record.oneRepMax.rounded()))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Without a lifting log, heart rate is the only thing the watch adds: how hard sessions ran over time.
private struct HeartRateTrendCard: View {
    var entries: [StrengthReport.Entry]

    var body: some View {
        let points = entries.compactMap { entry in entry.workout?.averageHeartRate.map { (date: entry.date, bpm: $0) } }.reversed()
        if points.count > 1 {
            Card(title: "Average heart rate per session") {
                Chart(Array(points), id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("BPM", point.bpm))
                        .foregroundStyle(.red)
                    PointMark(x: .value("Date", point.date), y: .value("BPM", point.bpm))
                        .foregroundStyle(.red)
                        .symbolSize(20)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
                Text("Heart rate rises with shorter rests and bigger muscle groups, not with heavier weights, so it describes the session's density rather than how hard you lifted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SessionsCard: View {
    var entries: [StrengthReport.Entry]

    var body: some View {
        Card(title: "Sessions") {
            if entries.isEmpty {
                Text("No strength sessions in the last 8 weeks.").font(.footnote).foregroundStyle(.secondary)
            }
            DividedForEach(data: entries) { entry in
                Group {
                    if let workout = entry.workout {
                        NavigationLink(value: DashboardDestination.workout(workout)) { row(entry) }
                    } else if let session = entry.session {
                        NavigationLink(value: DashboardDestination.strengthSession(session)) { row(entry) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ entry: StrengthReport.Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.subheadline.bold())
                Text(entry.date, format: .dateTime.weekday().day().month())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryLine(entry)).font(.caption)
                if let session = entry.session, session.volumeKg > 0 {
                    Text(StrengthFormat.tonnes(session.volumeKg)).font(.caption2).foregroundStyle(.secondary)
                } else if let hr = entry.workout?.averageHeartRate {
                    Text("\(Int(hr)) bpm").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            LinkChevron()
        }
        .contentShape(.rect)
    }

    private func primaryLine(_ entry: StrengthReport.Entry) -> String {
        var parts = ["\(Int(entry.minutes.rounded())) min"]
        if let session = entry.session {
            parts.append("\(session.exercises.count) exercises")
            parts.append("\(session.workingSets.count) sets")
        }
        return parts.joined(separator: " · ")
    }
}
