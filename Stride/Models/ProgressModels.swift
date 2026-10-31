import Foundation

/// Level from cumulative XP. Reaching level L takes `base × L²` XP, so each level takes a bit longer than the last.
nonisolated struct LevelProgress: Sendable, Equatable {
    var xp: Double
    var level: Int
    var levelStartXP: Double
    var nextLevelXP: Double

    init(xp: Double, base: Double) {
        self.xp = xp
        level = Int((max(xp, 0) / base).squareRoot())
        levelStartXP = base * Double(level * level)
        nextLevelXP = base * Double((level + 1) * (level + 1))
    }

    var fraction: Double { min(max((xp - levelStartXP) / (nextLevelXP - levelStartXP), 0), 1) }
    var xpToNext: Double { nextLevelXP - xp }

    static let athleteBase = 100.0
    static let skillBase = 20.0

    /// A rank name every 10 levels.
    var title: String { Self.rankTitle(level: level) }

    static func rankTitle(level: Int) -> String {
        let titles = ["Novice", "Apprentice", "Contender", "Athlete", "Veteran", "Elite", "Champion", "Master", "Grandmaster", "Legend"]
        return titles[min(max(level, 0) / 10, titles.count - 1)]
    }
}

nonisolated struct PersonalRecord: Identifiable, Sendable {
    var id: String
    var title: String
    var value: String
    var date: Date
    var systemImage: String
}

nonisolated struct Achievement: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String
    var target: Double
    var current: Double
    var unlockedAt: Date?

    var isUnlocked: Bool { unlockedAt != nil }
    var fraction: Double { min(current / target, 1) }
}

nonisolated struct PeriodComparison: Identifiable, Sendable {
    var metric: ProgressMetric
    var current: Double?
    var previous: Double?

    var id: ProgressMetric { metric }
}
