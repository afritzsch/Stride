import Foundation

/// One lifting session from a workout log (Hevy): what Apple Health never gets, the exercises, sets, reps and weights.
nonisolated struct StrengthSession: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var notes: String?
    var start: Date
    var end: Date
    var exercises: [StrengthExercise]

    var durationMinutes: Double { max(end.timeIntervalSince(start) / 60, 0) }
    var workingSets: [StrengthSet] { exercises.flatMap(\.workingSets) }
    /// Weight × reps over working sets, in kg. Bodyweight and timed sets add nothing.
    var volumeKg: Double { exercises.map(\.volumeKg).reduce(0, +) }
    var totalReps: Int { workingSets.compactMap(\.reps).reduce(0, +) }
}

nonisolated struct StrengthExercise: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var title: String
    /// Hevy's exercise template; the same exercise across sessions shares it.
    var templateID: String
    var notes: String?
    var supersetID: Int?
    var sets: [StrengthSet]

    var id: Int { index }
    var workingSets: [StrengthSet] { sets.filter { $0.kind != .warmup } }
    var volumeKg: Double { workingSets.compactMap(\.volumeKg).reduce(0, +) }
    /// Best estimated one-rep max of the working sets, for weighted sets of 12 reps or fewer.
    var bestOneRepMax: Double? { workingSets.compactMap(\.estimatedOneRepMax).max() }

    /// The set that stands for the exercise: the heaviest by estimated 1RM, else most reps, else longest.
    var topSet: StrengthSet? {
        let sets = workingSets
        if let weighted = sets.compactMap({ set in set.estimatedOneRepMax.map { (set: set, oneRepMax: $0) } }).max(by: { $0.oneRepMax < $1.oneRepMax })?.set {
            return weighted
        }
        if let reps = sets.filter({ ($0.reps ?? 0) > 0 }).max(by: { ($0.reps ?? 0) < ($1.reps ?? 0) }) { return reps }
        return sets.max { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
    }

    /// Working sets with identical sets merged: "3×5 @ 80 kg, 1×4 @ 80 kg (RPE 9)".
    func setsSummary(locale: Locale = .current) -> String {
        var groups: [(set: StrengthSet, count: Int)] = []
        for set in workingSets {
            if let last = groups.last, last.set.sameWork(as: set) {
                groups[groups.count - 1].count += 1
                // Keep the last RPE of a group: the hardest one.
                if set.rpe != nil { groups[groups.count - 1].set.rpe = set.rpe }
            } else {
                groups.append((set, 1))
            }
        }
        return groups.map { group in
            let prefix = group.count > 1 ? "\(group.count)×" : ""
            let rpe = group.set.rpe.map { " (RPE \($0.formatted(.number.precision(.fractionLength(0...1)).locale(locale))))" } ?? ""
            let kind = group.set.kind == .warmup || group.set.kind == .normal ? "" : " \(group.set.kind.rawValue)"
            return prefix + group.set.workText(compactWeight: group.count > 1, locale: locale) + kind + rpe
        }.joined(separator: ", ")
    }
}

nonisolated struct StrengthSet: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case normal, warmup, dropset, failure
    }

    var index: Int
    var kind: Kind
    var weightKg: Double?
    var reps: Int?
    var distanceMeters: Double?
    var durationSeconds: Double?
    var rpe: Double?

    var id: Int { index }

    var volumeKg: Double? {
        guard let weightKg, let reps, weightKg > 0, reps > 0 else { return nil }
        return weightKg * Double(reps)
    }

    /// Past this many reps a set says more about endurance than strength, so it gets no 1RM estimate.
    static let maxRepsForOneRepMax = 12

    /// Epley's estimate.
    var estimatedOneRepMax: Double? {
        guard let weightKg, let reps, weightKg > 0, (1...Self.maxRepsForOneRepMax).contains(reps) else { return nil }
        return reps == 1 ? weightKg : weightKg * (1 + Double(reps) / 30)
    }

    func sameWork(as other: StrengthSet) -> Bool {
        weightKg == other.weightKg && reps == other.reps && distanceMeters == other.distanceMeters
            && durationSeconds == other.durationSeconds && kind == other.kind
    }

    /// "80 kg × 5", "12 reps", "45 s", "500 m". With `compactWeight`, "5 @ 80 kg" so a count can go in front.
    func workText(compactWeight: Bool = false, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let reps, reps > 0 {
            if let weightKg, weightKg > 0 {
                parts.append(compactWeight ? "\(reps) @ \(Self.kg(weightKg, locale: locale))" : "\(Self.kg(weightKg, locale: locale)) × \(reps)")
            } else {
                parts.append("\(reps) reps")
            }
        } else if let weightKg, weightKg > 0 {
            parts.append(Self.kg(weightKg, locale: locale))
        }
        if let durationSeconds, durationSeconds > 0 { parts.append(Self.duration(durationSeconds)) }
        if let distanceMeters, distanceMeters > 0 {
            parts.append(distanceMeters >= 1000 ? "\(PromptBuilder.num(distanceMeters / 1000, 2)) km" : "\(Int(distanceMeters)) m")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: ", ")
    }

    /// "80 kg", "76.25 kg". Prompts pass the POSIX locale so the model always sees a decimal point.
    static func kg(_ value: Double, locale: Locale = .current) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))) kg"
    }

    static func duration(_ seconds: Double) -> String {
        seconds >= 60 ? WorkoutFormat.duration(seconds) : "\(Int(seconds)) s"
    }
}
