import SwiftUI

/// A Hevy session the watch didn't record.
struct StrengthSessionView: View {
    @Environment(AppModel.self) private var model
    var session: StrengthSession

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.start.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.title2.bold())
                    Text("\(session.start.formatted(date: .omitted, time: .shortened)) · Hevy · no watch workout at this time")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LoggedSessionContent(session: session, history: model.strength.sessions ?? [])
            }
            .padding()
        }
        .navigationTitle(session.title.isEmpty ? "Strength" : session.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The strength part of a watch workout's detail: the matching Hevy session, or what the watch says about it
/// next to the athlete's routine.
struct StrengthWorkoutSection: View {
    @Environment(AppModel.self) private var model
    var workout: WorkoutSummary

    var body: some View {
        let strength = model.strength
        if let session = strength.session(for: workout) {
            LoggedSessionContent(session: session, history: strength.sessions ?? [])
                .id("exercises")
        } else {
            if strength.source == .hevy {
                Card {
                    Label("No Hevy workout was logged at this time.", systemImage: "dumbbell")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = strength.syncError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            RoutineCard(workout: workout)
            if strength.source == .none { ConnectHevyCard() }
        }
        NavigationLink(value: DashboardDestination.strength) {
            HStack {
                Label("Strength overview", systemImage: "chart.bar.fill")
                Spacer()
                LinkChevron()
            }
            .font(.subheadline)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }
}

/// From the watch only: where this session sits in the athlete's strength routine.
private struct RoutineCard: View {
    @Environment(AppModel.self) private var model
    var workout: WorkoutSummary

    var body: some View {
        let calendar = Calendar.current
        let all = (model.snapshot?.workouts ?? []).filter { $0.kind == .strength }
        let monthStart = calendar.date(byAdding: .day, value: -27, to: calendar.startOfDay(for: workout.start)) ?? workout.start
        let month = all.filter { $0.start >= monthStart && $0.start <= workout.start }
        let previous = all.last { $0.start < workout.start }
        let same = all.filter { $0.sport == workout.sport && $0.start < workout.start }.suffix(6)
        let usualHR = MetricsReport.median(same.compactMap(\.averageHeartRate))
        let usualMinutes = MetricsReport.median(same.map(\.durationMinutes))
        Card(title: "Your routine") {
            VStack(alignment: .leading, spacing: 6) {
                fact("calendar", "\(month.count) strength session\(month.count == 1 ? "" : "s") in the 4 weeks up to this one (\(Format.number(Double(month.count) / 4, digits: 1)) a week)")
                if let previous {
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous.start), to: calendar.startOfDay(for: workout.start)).day ?? 0
                    fact("clock.arrow.circlepath", days == 0 ? "Second session that day" : "\(days) day\(days == 1 ? "" : "s") since the last one" + (previous.sport == workout.sport ? "" : " (\(previous.sport.lowercased()))"))
                }
                if let usualMinutes, same.count >= 2 {
                    fact("timer", "\(Int(workout.durationMinutes.rounded())) min against your usual \(Int(usualMinutes.rounded())) min")
                }
                if let usualHR, let hr = workout.averageHeartRate, same.count >= 2 {
                    let delta = hr - usualHR
                    let comparison = abs(delta) < 3 ? "about your usual" : "\(Int(abs(delta).rounded())) bpm \(delta > 0 ? "above" : "below") your usual"
                    fact("heart", "Average heart rate \(Int(hr)) bpm, \(comparison) (\(Int(usualHR)) bpm)")
                }
            }
            .font(.subheadline)
        }
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }
}

/// Totals and every exercise of a logged session, with personal bests marked.
struct LoggedSessionContent: View {
    var session: StrengthSession
    var history: [StrengthSession]

    var body: some View {
        let records = StrengthLog.records(in: session, history: history)
        VStack(spacing: 16) {
            Card {
                HStack {
                    Label(session.title.isEmpty ? "Hevy workout" : session.title, systemImage: "dumbbell.fill")
                        .font(.headline)
                    Spacer()
                    Text("Hevy").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    total("Exercises", "\(session.exercises.count)")
                    total("Sets", "\(session.workingSets.count)")
                    total("Reps", "\(session.totalReps)")
                    if session.volumeKg > 0 { total("Volume", StrengthFormat.tonnes(session.volumeKg)) }
                }
                if !records.isEmpty {
                    Label("\(records.count) personal best\(records.count == 1 ? "" : "s")", systemImage: "trophy.fill")
                        .font(.subheadline)
                        .foregroundStyle(.primary, .yellow)
                }
                if let notes = session.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Card(title: "Exercises") {
                DividedForEach(data: session.exercises) { exercise in
                    ExerciseRows(
                        exercise: exercise,
                        isRecord: records.contains(exercise.templateID),
                        previous: StrengthLog.previous(exercise, before: session.start, in: history)?.exercise
                    )
                }
            }
        }
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ExerciseRows: View {
    var exercise: StrengthExercise
    var isRecord: Bool
    var previous: StrengthExercise?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.title).font(.subheadline.bold())
                if exercise.supersetID != nil {
                    Text("Superset").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.purple.opacity(0.15), in: .capsule)
                }
                Spacer()
                if isRecord {
                    Label("PB", systemImage: "trophy.fill").font(.caption.bold()).foregroundStyle(.yellow)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(exercise.sets.enumerated()), id: \.offset) { position, set in
                    GridRow {
                        Text(label(for: set, position: position))
                            .font(.caption.bold())
                            .foregroundStyle(set.kind == .warmup ? .secondary : set.kind == .normal ? .primary : Color.orange)
                            .gridColumnAlignment(.center)
                        Text(set.workText()).monospacedDigit()
                        Text(set.rpe.map { "RPE \(Format.number($0, digits: $0.rounded() == $0 ? 0 : 1))" } ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .opacity(set.kind == .warmup ? 0.6 : 1)
                }
            }
            if let previous, !previous.workingSets.isEmpty {
                Text("Last time: \(previous.setsSummary())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).italic()
            }
        }
        .padding(.vertical, 2)
    }

    /// Working sets are numbered; others show their type like in Hevy (W, D, F).
    private func label(for set: StrengthSet, position: Int) -> String {
        switch set.kind {
        case .warmup: return "W"
        case .dropset: return "D"
        case .failure: return "F"
        case .normal:
            return "\(exercise.sets.prefix(position + 1).filter { $0.kind == .normal }.count)"
        }
    }
}
