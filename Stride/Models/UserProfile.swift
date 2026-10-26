import Foundation

nonisolated enum FocusArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case training, sleep, activity, goal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .training: "Training plan"
        case .sleep: "Sleep & recovery"
        case .activity: "Daily activity"
        case .goal: "Race / goal prep"
        }
    }

    var systemImage: String {
        switch self {
        case .training: "figure.run"
        case .sleep: "bed.double.fill"
        case .activity: "shoeprints.fill"
        case .goal: "flag.checkered"
        }
    }
}

nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner, intermediate, advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Context the AI needs that the watch can't know: goals, availability, constraints.
nonisolated struct UserProfile: Codable, Equatable, Sendable {
    var primarySport = "Running"
    var experience = ExperienceLevel.intermediate
    var age: Int?
    /// Leave nil to estimate from age.
    var maxHeartRate: Int?
    var zoneMethod = HeartRateZoneMethod.maxHeartRate
    /// Lower bounds of zones 2–5 in bpm, used when `zoneMethod` is `.custom`.
    var customZoneFloors: [Int] = []
    /// Lower bounds of zones 2–5 as last copied for Garmin Connect, to notice when the watch falls out of date.
    var garminZoneFloors: [Int] = []
    var trainingDaysPerWeek = 4
    var weeklyHoursAvailable = 5.0

    var hasGoal = false
    var goalName = ""
    var goalDate = Calendar.current.date(byAdding: .day, value: 84, to: .now) ?? .now
    var goalTarget = ""

    var sleepTargetHours = 8.0
    var dailyStepTarget = 8000
    var notes = ""
    var focusAreas = Set(FocusArea.allCases)

    /// Tanaka formula when age is known, otherwise a conservative default.
    var effectiveMaxHeartRate: Double {
        if let maxHeartRate { return Double(maxHeartRate) }
        if let age { return 208 - 0.7 * Double(age) }
        return 190
    }

    var isMaxHeartRateEstimated: Bool { maxHeartRate == nil }

    /// Four floors, each above the one before, so every zone has a range.
    var hasValidCustomZones: Bool {
        customZoneFloors.count == 4 && zip(customZoneFloors, customZoneFloors.dropFirst()).allSatisfy(<)
    }

    func heartRateZones(restingHR: Double) -> HeartRateZones {
        let maxHR = effectiveMaxHeartRate
        let shares = [0.6, 0.7, 0.8, 0.9]
        switch zoneMethod {
        case .custom where hasValidCustomZones:
            return HeartRateZones(floors: customZoneFloors.map(Double.init), method: zoneMethod)
        case .heartRateReserve where maxHR > restingHR:
            let bpm = { restingHR + $0 * (maxHR - restingHR) }
            return HeartRateZones(floors: shares.map(bpm), method: zoneMethod, zone1Floor: bpm(0.5))
        default:
            return HeartRateZones(floors: shares.map { $0 * maxHR }, method: .maxHeartRate, zone1Floor: 0.5 * maxHR)
        }
    }
}

nonisolated extension UserProfile {
    /// Decodes field by field so a profile saved by an older version keeps its values when fields are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = UserProfile()
        primarySport = try value(.primarySport, defaults.primarySport)
        experience = try value(.experience, defaults.experience)
        age = try container.decodeIfPresent(Int.self, forKey: .age)
        maxHeartRate = try container.decodeIfPresent(Int.self, forKey: .maxHeartRate)
        zoneMethod = try value(.zoneMethod, defaults.zoneMethod)
        customZoneFloors = try value(.customZoneFloors, defaults.customZoneFloors)
        garminZoneFloors = try value(.garminZoneFloors, defaults.garminZoneFloors)
        trainingDaysPerWeek = try value(.trainingDaysPerWeek, defaults.trainingDaysPerWeek)
        weeklyHoursAvailable = try value(.weeklyHoursAvailable, defaults.weeklyHoursAvailable)
        hasGoal = try value(.hasGoal, defaults.hasGoal)
        goalName = try value(.goalName, defaults.goalName)
        goalDate = try value(.goalDate, defaults.goalDate)
        goalTarget = try value(.goalTarget, defaults.goalTarget)
        sleepTargetHours = try value(.sleepTargetHours, defaults.sleepTargetHours)
        dailyStepTarget = try value(.dailyStepTarget, defaults.dailyStepTarget)
        notes = try value(.notes, defaults.notes)
        focusAreas = try value(.focusAreas, defaults.focusAreas)
    }
}

/// How heart-rate zones are set. Garmin offers the same choices, so the app can match the watch.
nonisolated enum HeartRateZoneMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case maxHeartRate, heartRateReserve, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maxHeartRate: "% of max HR"
        case .heartRateReserve: "% of HR reserve"
        case .custom: "Custom (bpm)"
        }
    }
}

/// Five heart-rate zones, given as the bpm where zones 2–5 start. Zone 1 is everything below zone 2.
nonisolated struct HeartRateZones: Equatable, Sendable {
    var floors: [Double]
    var method: HeartRateZoneMethod
    /// Where zone 1 starts (50%), which Garmin asks for. Unknown for custom zones.
    var zone1Floor: Double? = nil

    var roundedFloors: [Int] { floors.map { Int($0.rounded()) } }

    /// 0-based zone index (0 = Z1 … 4 = Z5).
    func index(for bpm: Double) -> Int {
        floors.filter { bpm >= $0.rounded() }.count
    }

    /// "<117", "117–135", …, "≥175", in bpm.
    var ranges: [String] {
        let bounds = roundedFloors
        return (0...4).map { zone in
            switch zone {
            case 0: "<\(bounds[0])"
            case 4: "≥\(bounds[3])"
            default: "\(bounds[zone - 1])–\(bounds[zone] - 1)"
            }
        }
    }

    /// "Z1 <117, Z2 117–135, … bpm (% of max HR)" for prompts and captions.
    var summary: String {
        ranges.enumerated().map { "Z\($0.offset + 1) \($0.element)" }.joined(separator: ", ") + " bpm (\(method.title))"
    }

    /// The zones in the order Garmin Connect lists them (zone 5 first), to type into the watch's heart rate zone settings.
    /// Garmin can't do % of HR reserve on every watch, but entering these bpm values gives the same zones.
    func garminText(maxHR: Double) -> String {
        let bounds = roundedFloors + [Int(maxHR.rounded())]
        var lines = ["Heart rate zones for Garmin Connect (\(method.title))", "Max HR: \(bounds[4]) bpm"]
        for zone in (1...4).reversed() {
            lines.append("Zone \(zone + 1): \(bounds[zone - 1])–\(bounds[zone] - (zone == 4 ? 0 : 1)) bpm")
        }
        lines.append(zone1Floor.map { "Zone 1: \(Int($0.rounded()))–\(bounds[0] - 1) bpm" } ?? "Zone 1: below \(bounds[0]) bpm")
        return lines.joined(separator: "\n")
    }

    /// Largest difference in where a zone starts, compared with zones copied earlier. Nil if nothing was copied.
    func drift(from copied: [Int]) -> Int? {
        guard copied.count == floors.count else { return nil }
        return zip(roundedFloors, copied).map { abs($0 - $1) }.max()
    }
}
