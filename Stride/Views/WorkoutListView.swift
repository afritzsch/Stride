import SwiftUI

struct WorkoutListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(Array((model.snapshot?.workouts ?? []).reversed())) { workout in
                NavigationLink(value: DashboardDestination.workout(workout)) {
                    WorkoutRow(workout: workout, load: model.metrics?.workoutLoad[workout.id], isReviewed: model.runAnalyses[workout.id] != nil)
                }
            }
        }
        .overlay {
            if model.snapshot?.workouts.isEmpty ?? true {
                ContentUnavailableView("No workouts", systemImage: "figure.run", description: Text("No workouts in Apple Health for the last 8 weeks."))
            }
        }
        .navigationTitle("Workouts")
    }
}

struct WorkoutRow: View {
    var workout: WorkoutSummary
    var load: Double?
    var isReviewed = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(workout.sport).font(.subheadline.bold())
                    if isReviewed {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.tint)
                    }
                }
                Text(workout.start.formatted(.dateTime.weekday().day().month()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryLine).font(.caption)
                Text("Load \(Format.number(load))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .contentShape(.rect)
    }

    private var primaryLine: String {
        var parts = ["\(Int(workout.durationMinutes)) min"]
        if let km = workout.distanceKm {
            parts.append("\(Format.number(km, digits: 1)) km")
            if workout.isFootSport { parts.append("\(WorkoutFormat.pace(workout.durationMinutes * 60 / km)) /km") }
        }
        if let hr = workout.averageHeartRate { parts.append("\(Int(hr)) bpm") }
        return parts.joined(separator: " · ")
    }
}
