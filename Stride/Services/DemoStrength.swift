import Foundation

/// A Hevy log for the demo data's gym sessions: two alternating routines whose weights go up slowly, so the
/// strength screen has lifts, records and volume to show.
nonisolated enum DemoStrength {
    private struct Template {
        var id: String
        var title: String
        /// Working sets × reps; reps nil for timed sets.
        var sets: Int
        var reps: Int?
        var seconds: Double?
        /// Starting weight and kg added per session; nil weight is bodyweight.
        var weight: Double?
        var step: Double = 0
        var warmup = false
    }

    private static let routines: [(title: String, exercises: [Template])] = [
        ("Lower body", [
            Template(id: "D04AC939", title: "Squat (Barbell)", sets: 3, reps: 5, weight: 72.5, step: 1.25, warmup: true),
            Template(id: "2B4B7310", title: "Romanian Deadlift (Barbell)", sets: 3, reps: 8, weight: 60, step: 1.25),
            Template(id: "B5D3A742", title: "Bulgarian Split Squat", sets: 3, reps: 8, weight: 14, step: 0.5),
            Template(id: "C2C6D7F0", title: "Calf Raise (Machine)", sets: 3, reps: 12, weight: 50, step: 0.5),
            Template(id: "C6C9B8A0", title: "Plank", sets: 3, seconds: 45),
        ]),
        ("Upper body", [
            Template(id: "79D0BB3A", title: "Bench Press (Barbell)", sets: 3, reps: 5, weight: 60, step: 1.25, warmup: true),
            Template(id: "1B2B1E7C", title: "Pull Up", sets: 3, reps: 6),
            Template(id: "7B8D84E8", title: "Overhead Press (Barbell)", sets: 3, reps: 6, weight: 35, step: 0.5),
            Template(id: "F1E57334", title: "Bent Over Row (Barbell)", sets: 3, reps: 8, weight: 50, step: 1),
            Template(id: "6E6EE645", title: "Hanging Leg Raise", sets: 3, reps: 10),
        ]),
    ]

    /// One logged session per strength workout, recorded a few minutes inside the watch workout like a real log.
    static func sessions(for workouts: [WorkoutSummary]) -> [StrengthSession] {
        let gym = workouts.filter { $0.kind == .strength }.sorted { $0.start < $1.start }
        return gym.enumerated().map { number, workout in
            var rng = SeededGenerator(seed: UInt64(abs(workout.start.timeIntervalSince1970.rounded())))
            let routine = routines[number % routines.count]
            // How often this routine was done before: weights go up with it.
            let done = Double(number / routines.count)
            let start = workout.start.addingTimeInterval(4 * 60)
            let exercises = routine.exercises.enumerated().map { index, template in
                exercise(template, index: index, done: done, rng: &rng)
            }
            return StrengthSession(
                id: "demo-\(Int(workout.start.timeIntervalSince1970))",
                title: routine.title,
                notes: nil,
                start: start,
                end: start.addingTimeInterval(max(workout.durationMinutes - 6, 10) * 60),
                exercises: exercises
            )
        }
    }

    private static func exercise(_ template: Template, index: Int, done: Double, rng: inout SeededGenerator) -> StrengthExercise {
        // Round to what plates and dumbbells allow; a bad day every so often keeps the trend honest.
        let weight = template.weight.map { base in
            let raw = base + template.step * done
            return raw >= 20 ? (raw / 2.5).rounded() * 2.5 : raw.rounded()
        }
        var sets: [StrengthSet] = []
        if template.warmup, let weight {
            sets.append(StrengthSet(index: 0, kind: .warmup, weightKg: (weight * 0.6 / 2.5).rounded() * 2.5, reps: 8))
        }
        for set in 0..<template.sets {
            let isLast = set == template.sets - 1
            var reps = template.reps
            if let planned = reps, isLast, Double.random(in: 0...1, using: &rng) < 0.25 { reps = planned - 1 }
            if template.weight == nil, let planned = reps { reps = planned + Int(done / 3) }
            sets.append(StrengthSet(
                index: sets.count,
                kind: .normal,
                weightKg: weight,
                reps: reps,
                durationSeconds: template.seconds.map { $0 + 5 * (done / 2).rounded(.down) },
                rpe: isLast && weight != nil ? [7.5, 8, 8.5, 9].randomElement(using: &rng) : nil
            ))
        }
        return StrengthExercise(index: index, title: template.title, templateID: template.id, notes: nil, supersetID: nil, sets: sets)
    }
}
