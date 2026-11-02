import Foundation

/// Pain and illness the athlete logs themselves: the watch can't tell a sore calf or a cold, and both should change
/// the plan. Code turns each logged issue into limits per day (`DayLimit`), which the plan check, the weekly prompt,
/// readiness and today's adjustment all follow.
nonisolated struct HealthIssue: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case pain, illness
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Severity: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
        case mild = 1, moderate, severe

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .mild: "Mild"
            case .moderate: "Moderate"
            case .severe: "Severe"
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Side: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, left, right, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "–"
            case .left: "Left"
            case .right: "Right"
            case .both: "Both"
            }
        }
    }

    enum BodyPart: String, Codable, CaseIterable, Identifiable, Sendable {
        case foot, ankle, achilles, calf, shin, knee, hamstring, quad, hip, lowerBack, upperBack, neck, shoulder, elbow, wrist, other

        var id: String { rawValue }
        var title: String {
            switch self {
            case .achilles: "Achilles"
            case .lowerBack: "Lower back"
            case .upperBack: "Upper back"
            case .hip: "Hip / groin"
            default: rawValue.capitalized
            }
        }

        /// Whether left/right makes sense.
        var hasSide: Bool {
            switch self {
            case .lowerBack, .upperBack, .neck, .other: false
            default: true
            }
        }

        /// Sports that load this part and are best avoided while it hurts more than mildly.
        var strainingSports: [String] {
            switch self {
            case .foot, .ankle, .achilles, .calf, .shin, .knee: [Sport.running, "HIIT", Sport.hiking]
            case .hamstring, .quad, .hip: [Sport.running, "HIIT"]
            case .lowerBack: ["Rowing", "HIIT"]
            case .shoulder, .elbow, .wrist: [Sport.swimming, "Rowing"]
            case .neck, .upperBack: [Sport.swimming]
            case .other: []
            }
        }
    }

    enum Illness: String, Codable, CaseIterable, Identifiable, Sendable {
        case headCold, fever, chest, stomach, other

        var id: String { rawValue }
        var title: String {
            switch self {
            case .headCold: "Head cold"
            case .fever: "Fever / flu"
            case .chest: "Cough / chest"
            case .stomach: "Stomach bug"
            case .other: "Feeling ill"
            }
        }

        /// The "neck check": symptoms below the neck (fever, chest, stomach) mean no training at all; a cold in
        /// the head allows easy sessions.
        var isBelowNeck: Bool {
            switch self {
            case .fever, .chest, .stomach: true
            case .headCold, .other: false
            }
        }
    }

    /// How it felt on a day. The latest one is the current severity.
    struct CheckIn: Codable, Hashable, Sendable {
        /// Start of the local day.
        var date: Date
        var severity: Severity
    }

    var id = UUID()
    var kind: Kind
    var bodyPart: BodyPart = .other
    var side: Side = .none
    var illness: Illness = .other
    /// Oldest first, never empty, at most one per day.
    var checkIns: [CheckIn]
    /// The first day it was gone, nil while it's ongoing.
    var resolvedOn: Date?
    var note = ""

    /// Days the limits still apply after the last check-in. Nobody knows how a sore calf feels next week, so the
    /// plan only assumes it lasts a few days; checking in again extends it.
    static let horizonDays = 3
    /// After an illness, the first days back are easy.
    static let returnDays = 2

    init(kind: Kind, bodyPart: BodyPart = .other, side: Side = .none, illness: Illness = .other, severity: Severity, started: Date, note: String = "", calendar: Calendar = .current) {
        self.kind = kind
        self.bodyPart = bodyPart
        self.side = side
        self.illness = illness
        self.checkIns = [CheckIn(date: calendar.startOfDay(for: started), severity: severity)]
        self.note = note
    }

    var started: Date { checkIns.first?.date ?? .distantPast }
    var severity: Severity { checkIns.last?.severity ?? .mild }
    var lastCheckIn: Date { checkIns.last?.date ?? started }
    var isOngoing: Bool { resolvedOn == nil }

    /// "Left calf pain", "Lower back pain", "Head cold".
    var title: String {
        switch kind {
        case .illness:
            return illness.title
        case .pain:
            let side = bodyPart.hasSide && side != .none ? (side == .both ? "Both " : "\(side.title) ") : ""
            let part = bodyPart == .other ? "Pain" : "\(bodyPart.title.lowercased()) pain"
            return side.isEmpty ? part.prefix(1).uppercased() + part.dropFirst() : side + part
        }
    }

    /// The severity on a day: the latest check-in on or before it. Nil before it started or once it was gone.
    func severity(on date: Date, calendar: Calendar = .current) -> Severity? {
        let day = calendar.startOfDay(for: date)
        guard day >= started else { return nil }
        if let resolvedOn, day >= calendar.startOfDay(for: resolvedOn) { return nil }
        return checkIns.last { $0.date <= day }?.severity
    }

    /// Whether the plan should still assume it on that day: from the start until `horizonDays` after the last
    /// check-in, while it's ongoing.
    func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        guard severity(on: date, calendar: calendar) != nil,
              let horizon = calendar.date(byAdding: .day, value: Self.horizonDays, to: lastCheckIn) else { return false }
        return calendar.startOfDay(for: date) <= horizon
    }

    /// "better", "worse" or nil, comparing the last two check-ins.
    var trend: String? {
        guard checkIns.count >= 2 else { return nil }
        let last = checkIns[checkIns.count - 1].severity, before = checkIns[checkIns.count - 2].severity
        return last < before ? "better" : last > before ? "worse" : nil
    }

    /// Records today's severity, replacing a check-in from the same day.
    mutating func checkIn(_ severity: Severity, on date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        checkIns.removeAll { $0.date == day }
        checkIns.append(CheckIn(date: day, severity: severity))
        checkIns.sort { $0.date < $1.date }
        resolvedOn = nil
    }

    /// The limit this issue puts on a day, nil when it puts none.
    func limit(on date: Date, calendar: Calendar = .current) -> DayLimit? {
        let day = calendar.startOfDay(for: date)
        if kind == .illness, let resolvedOn {
            let gone = calendar.startOfDay(for: resolvedOn)
            if let back = calendar.date(byAdding: .day, value: Self.returnDays, to: gone), day >= gone, day < back {
                return DayLimit(maxIntensity: .easy, reasons: ["first days back after \(illness.title.lowercased())"])
            }
            return nil
        }
        guard applies(on: day, calendar: calendar), let severity = severity(on: day, calendar: calendar) else { return nil }
        let reason = "\(title.lowercased()), \(severity.title.lowercased())"
        switch kind {
        case .illness:
            if illness.isBelowNeck || severity == .severe {
                return DayLimit(maxIntensity: .rest, reasons: [reason + (illness.isBelowNeck ? ", below the neck: no training" : "")])
            }
            return DayLimit(maxIntensity: .easy, reasons: [reason])
        case .pain:
            switch severity {
            case .severe: return DayLimit(maxIntensity: .rest, reasons: [reason])
            case .moderate: return DayLimit(maxIntensity: .easy, avoidSports: Set(bodyPart.strainingSports), reasons: [reason])
            case .mild: return DayLimit(maxIntensity: .moderate, reasons: [reason])
            }
        }
    }

    /// One line for prompts: "Left calf pain: moderate since Mon 26 Oct (better than before); note: …".
    func promptLine(calendar: Calendar) -> String {
        var line = "\(title): \(severity.title.lowercased()), since \(PromptBuilder.dayLabel(started, calendar: calendar))"
        if let trend { line += " (\(trend) than before)" }
        if let resolvedOn { line = "\(title): gone since \(PromptBuilder.dayLabel(resolvedOn, calendar: calendar))" }
        if !note.isEmpty { line += "; note: \(PromptBuilder.quote(note, limit: 100))" }
        return line
    }
}

/// What a day's plan may hold given the logged issues: the hardest intensity (rest = no training) and sports to avoid.
nonisolated struct DayLimit: Hashable, Sendable {
    var maxIntensity: SessionIntensity
    var avoidSports: Set<String> = []
    /// What causes it, e.g. "left calf pain (moderate)".
    var reasons: [String]

    var reason: String { reasons.joined(separator: ", ") }

    /// Both limits at once: the stricter intensity and every sport to avoid.
    func merged(with other: DayLimit) -> DayLimit {
        DayLimit(
            maxIntensity: other.maxIntensity.rank < maxIntensity.rank ? other.maxIntensity : maxIntensity,
            avoidSports: avoidSports.union(other.avoidSports),
            reasons: reasons + other.reasons.filter { !reasons.contains($0) }
        )
    }

    /// "rest", "easy only, no Running or HIIT", "nothing hard".
    var summary: String {
        var parts: [String] = []
        switch maxIntensity {
        case .rest: return "rest"
        case .easy: parts.append("easy only")
        case .moderate: parts.append("nothing hard")
        case .hard: break
        }
        if !avoidSports.isEmpty { parts.append("no " + Self.list(avoidSports.sorted())) }
        return parts.joined(separator: ", ")
    }

    /// Whether a planned day breaks it.
    func isBroken(by day: PlannedDay) -> Bool {
        !day.isRest && (day.intensity.rank > maxIntensity.rank || avoidSports.contains(day.sport))
    }

    /// The day made to fit, nil when it already does. Rest stays rest; a sport to avoid becomes easy cross
    /// training of the same length (code can't know which other sport the athlete has, so the details say).
    func apply(to day: PlannedDay) -> PlannedDay? {
        guard isBroken(by: day) else { return nil }
        var day = day
        if maxIntensity == .rest {
            day.sport = PlannedDay.rest
            day.intensity = .rest
            day.session = PlannedDay.rest
            day.durationMinutes = 0
            day.targetZone = 0
            day.details = "Rest: \(reason)."
            return day
        }
        if avoidSports.contains(day.sport) {
            day.details = "No \(day.sport.lowercased()) while it hurts (\(reason)): cycling, swimming or another pain-free option, or rest."
            day.sport = "Cross training"
            day.intensity = .easy
            day.session = "Easy cross training"
            day.targetZone = day.targetZone == 0 ? 0 : min(day.targetZone, 2)
            return day
        }
        day.intensity = maxIntensity
        day.targetZone = day.targetZone == 0 ? 0 : min(day.targetZone, maxIntensity == .easy ? 2 : 3)
        day.session = day.defaultTitle
        day.details = "Keep it \(maxIntensity == .easy ? "easy" : "steady, nothing hard") (\(reason))."
        return day
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
        }
    }
}

/// The athlete's logged issues, and what they mean for days and prompts.
nonisolated struct HealthLog: Sendable {
    var issues: [HealthIssue]
    var calendar = Calendar.current

    /// Resolved issues are kept this long, for the coach's context and the athlete's own history.
    static let retentionDays = 180

    var ongoing: [HealthIssue] { issues.filter(\.isOngoing) }

    /// All limits on a day, merged; nil when nothing limits it.
    func limit(on date: Date) -> DayLimit? {
        issues.compactMap { $0.limit(on: date, calendar: calendar) }.reduce(nil) { $0?.merged(with: $1) ?? $1 }
    }

    /// One limit per day from `start`, nil where there's none.
    func limits(start: Date, days: Int = 7) -> [DayLimit?] {
        (0..<days).map { offset in
            calendar.date(byAdding: .day, value: offset, to: start).flatMap(limit(on:))
        }
    }

    /// Issues worth telling the coach about on `date`: ongoing ones, and ones gone within the last two weeks.
    func relevant(on date: Date) -> [HealthIssue] {
        let since = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: date)) ?? date
        return issues
            .filter { $0.started <= date && ($0.resolvedOn.map { $0 >= since } ?? true) }
            .sorted { ($0.isOngoing ? 0 : 1, $1.started) < ($1.isOngoing ? 0 : 1, $0.started) }
    }

    /// The HEALTH LOG prompt lines: the issues, then the limits for the plan's days, consecutive equal days grouped.
    func promptLines(planStart: Date, days: Int = 7, compact: Bool) -> [String] {
        let shown = relevant(on: planStart).prefix(compact ? 2 : 4)
        guard !shown.isEmpty else { return [] }
        var lines = ["HEALTH LOG (pain and illness the athlete logged)"]
        lines += shown.map { "- " + $0.promptLine(calendar: calendar) }
        let limits = limits(start: planStart, days: days)
        var index = 0
        while index < limits.count {
            guard let limit = limits[index] else { index += 1; continue }
            var end = index
            while end + 1 < limits.count, limits[end + 1] == limit { end += 1 }
            let first = calendar.date(byAdding: .day, value: index, to: planStart) ?? planStart
            let last = calendar.date(byAdding: .day, value: end, to: planStart) ?? planStart
            let range = index == end ? PromptBuilder.dayLabel(first, calendar: calendar)
                : "\(PromptBuilder.dayLabel(first, calendar: calendar)) to \(PromptBuilder.dayLabel(last, calendar: calendar))"
            lines.append("- Limit \(range): \(limit.summary) (\(limit.reason))")
            index = end + 1
        }
        return lines
    }

    /// Readiness signals for today: an ongoing issue is a strong signal unless it's mild pain; the first days
    /// back after an illness are a mild one.
    func signals(on date: Date) -> [Readiness.Signal] {
        issues.compactMap { issue in
            if let severity = issue.severity(on: date, calendar: calendar) {
                let strong = issue.kind == .illness || severity > .mild
                return Readiness.Signal(isStrong: strong, text: "You logged \(issue.title.lowercased()) (\(severity.title.lowercased()))", isLogged: true)
            }
            if issue.kind == .illness, issue.limit(on: date, calendar: calendar) != nil {
                return Readiness.Signal(isStrong: false, text: "Back from \(issue.illness.title.lowercased()): ease in", isLogged: true)
            }
            return nil
        }
    }

    /// Old resolved issues dropped.
    func pruned(now: Date) -> [HealthIssue] {
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now
        return issues.filter { $0.resolvedOn.map { $0 >= cutoff } ?? true }
    }
}
