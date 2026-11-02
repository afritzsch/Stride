import SwiftUI

/// Today's planned session next to this morning's recovery signals, with a lighter version when they're off.
struct TodayCard: View {
    @Environment(AppModel.self) private var model
    @State private var picksTime = false
    @State private var healthSheet: HealthIssueSheet?

    var body: some View {
        let readiness = model.readiness
        Card(title: "Today") {
            if let readiness, readiness.level != .unknown {
                StatusBadge(text: readiness.level.title, color: readiness.level.color)
            }
        } content: {
            // Logged pain and illness are listed below, with their check-in.
            if let signals = readiness?.signals.filter({ !$0.isLogged }), !signals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(signals, id: \.self) { signal in
                        Label(signal.text, systemImage: signal.isStrong ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                            .foregroundStyle(signal.isStrong ? .orange : .secondary)
                    }
                }
                .font(.footnote)
            }

            if !model.todaysWorkouts.isEmpty {
                Label("Done: " + model.todaysWorkouts.map(\.sportAndMinutes).joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                ForEach(model.todaysWorkouts) { workout in
                    if let review = model.runAnalyses[workout.id] {
                        NavigationLink(value: DashboardDestination.workout(workout)) {
                            Label(review.analysis.headline, systemImage: "sparkles").font(.footnote)
                        }
                    } else if model.analyzingWorkoutIDs.contains(workout.id) {
                        Label("Reviewing your \(workout.sport.lowercased())…", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let planned = model.todaysPlan {
                PlannedLine(day: planned, prefix: "Planned")
                adjustment(for: planned, readiness: readiness)
                if let schedule = model.schedule.schedule(on: .now) {
                    SessionTimeLine(schedule: schedule) { picksTime = true }
                }
            } else {
                Text("No session planned for today. Run an analysis on the AI Coach tab to get a plan, or plan the day yourself on the Plan tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HealthTodaySection(sheet: $healthSheet)
        }
        .sheet(isPresented: $picksTime) { SlotPickerView(date: .now) }
        .sheet(item: $healthSheet) { HealthIssueEditor(issue: $0.issue) }
    }

    @ViewBuilder
    private func adjustment(for planned: PlannedDay, readiness: Readiness?) -> some View {
        if let saved = model.todayAdjustment, Calendar.current.isDateInToday(saved.date) {
            switch saved.state {
            case .suggested:
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    PlannedLine(day: saved.adjustment.session, prefix: "Suggested")
                    Text(saved.adjustment.reason).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Use this") { model.resolveTodayAdjustment(accept: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Keep plan") { model.resolveTodayAdjustment(accept: false) }
                            .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                }
            case .accepted:
                Label("Adjusted for how you recovered", systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
            case .declined:
                EmptyView()
            }
        } else if model.isAdjustingToday {
            HStack(spacing: 8) {
                ProgressView()
                Text("Adjusting today's session…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if !planned.isRest, readiness?.suggestsAdjusting == true {
            Button("Adjust for today", systemImage: "wand.and.stars") {
                Task { await model.adjustTodayIfNeeded(automatically: false) }
            }
            .font(.subheadline)
            .disabled(model.aiBlocker != nil)
            if let error = model.adjustmentError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

private struct PlannedLine: View {
    var day: PlannedDay
    var prefix: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(day.intensity.color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text("\(Text("\(prefix):").foregroundStyle(.secondary)) \(Text(day.isRest ? "Rest" : day.session).bold())")
            Spacer()
            if day.durationMinutes > 0 {
                Text(day.durationAndZone)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }
}
