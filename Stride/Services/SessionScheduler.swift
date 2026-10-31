import Foundation

/// Finds times for planned sessions: free calendar gaps long enough for the session, ranked by weather, daylight
/// and when the athlete usually trains. Pure logic, so the harness can check it without EventKit or a network.
nonisolated enum SessionScheduler {
    /// Sports done indoors, where the weather doesn't matter.
    static let indoorSports: Set<String> = [Sport.strength, "Mobility", "Yoga", "HIIT", Sport.swimming, "Cross training"]

    static func isOutdoor(_ sport: String) -> Bool { !indoorSports.contains(sport) && sport != PlannedDay.rest }

    /// Comfortable "feels like" temperatures in °C. Cycling runs warmer because of the wind chill.
    static func comfortRange(for sport: String) -> ClosedRange<Double> {
        switch sport {
        case Sport.running: 4...18
        case Sport.cycling: 10...24
        case Sport.walking, Sport.hiking: 6...24
        default: 5...22
        }
    }

    // MARK: Search

    /// Candidate start times are on this grid.
    static let slotStep: TimeInterval = 15 * 60
    /// Sessions planned shorter than this (minutes) are scheduled as if they took this long.
    static let minSessionMinutes = 15
    /// Suggestions are at least this far apart (or a session's length, if longer).
    static let minSeparation: TimeInterval = 3600
    /// Gaps shorter than this don't count as free time in the weekly prompt.
    static let minUsefulGap: TimeInterval = 30 * 60

    /// Suggestions for one planned session, best first, at least an hour apart.
    static func schedule(
        date: Date,
        session: PlannedDay,
        busy: [BusyInterval],
        forecast: WeatherForecast?,
        settings: ScheduleSettings,
        habits: StartHabits,
        now: Date = .now,
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> DaySchedule {
        let day = calendar.startOfDay(for: date)
        let scheduled = busy.first { $0.sessionDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
        var result = DaySchedule(date: day, session: session, scheduled: scheduled, slots: [])
        guard !session.isRest else { return result }

        let duration = TimeInterval(max(session.durationMinutes, minSessionMinutes) * 60)
        // The session's own event doesn't block other times for it, so it can be moved.
        let blocking = busy.filter { $0 != scheduled }
        let upcoming = blocking.sorted { $0.start < $1.start }
        let gaps = freeGaps(on: day, busy: blocking, settings: settings, now: now, calendar: calendar)

        var candidates: [SlotSuggestion] = []
        for gap in gaps {
            var start = roundUp(gap.start, to: slotStep)
            while start.addingTimeInterval(duration) <= gap.end {
                let end = start.addingTimeInterval(duration)
                candidates.append(score(
                    start: start, end: end, session: session, nextEvent: upcoming.first { $0.start >= end },
                    forecast: forecast, habits: habits, calendar: calendar
                ))
                start = start.addingTimeInterval(slotStep)
            }
        }

        // Best first; on equal scores the earlier time wins. Keep picks apart so the choice is real.
        let separation = max(duration, minSeparation)
        for candidate in candidates.sorted(by: { ($0.score, $1.start) > ($1.score, $0.start) }) {
            guard result.slots.count < limit else { break }
            if result.slots.allSatisfy({ abs($0.start.timeIntervalSince(candidate.start)) >= separation }) {
                result.slots.append(candidate)
            }
        }

        if result.slots.isEmpty {
            result.note = noSlotNote(day: day, session: session, duration: duration, settings: settings, now: now, calendar: calendar)
        }
        return result
    }

    /// Why a day has no suggestions.
    private static func noSlotNote(day: Date, session: PlannedDay, duration: TimeInterval, settings: ScheduleSettings, now: Date, calendar: Calendar) -> String {
        let latest = clock(settings.latestMinute)
        guard calendar.isDate(day, inSameDayAs: now) else {
            return "No free \(session.durationMinutes) min between \(clock(settings.earliestMinute))–\(latest)."
        }
        let endOfWindow = day.addingTimeInterval(TimeInterval(settings.latestMinute * 60))
        return now.addingTimeInterval(duration) > endOfWindow
            ? "Too late today for \(session.durationMinutes) min before \(latest)."
            : "No free \(session.durationMinutes) min left today before \(latest)."
    }

    /// Free time on a day within the settings' window, with the buffer kept around events. For today it starts now.
    static func freeGaps(on date: Date, busy: [BusyInterval], settings: ScheduleSettings, now: Date = .now, calendar: Calendar = .current) -> [DateInterval] {
        let day = calendar.startOfDay(for: date)
        var start = day.addingTimeInterval(TimeInterval(settings.earliestMinute * 60))
        let end = day.addingTimeInterval(TimeInterval(settings.latestMinute * 60))
        if calendar.isDate(day, inSameDayAs: now) { start = max(start, now) }
        guard start < end else { return [] }

        let buffer = TimeInterval(settings.bufferMinutes * 60)
        let blocks = busy
            .map { DateInterval(start: $0.start.addingTimeInterval(-buffer), end: max($0.end, $0.start).addingTimeInterval(buffer)) }
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }

        var gaps: [DateInterval] = []
        var cursor = start
        for block in blocks {
            if block.start > cursor { gaps.append(DateInterval(start: cursor, end: block.start)) }
            cursor = max(cursor, block.end)
        }
        if cursor < end { gaps.append(DateInterval(start: cursor, end: end)) }
        return gaps
    }

    // MARK: Scoring

    /// Points: a slot starts at `baseScore`, loses penalties for weather and darkness, and gains for habit.
    private enum Points {
        static let baseScore = 88.0
        static let maxHabitBonus = 12.0
        /// A slot at this share of the usual start hour counts as "your usual time".
        static let usualTimeShare = 0.6

        static let rainPerChance = 40.0
        static let rainPerMillimeter = 4.0
        static let rainMillimeterCap = 5.0
        static let rainWarningChance = 0.5
        static let thunderstorm = 40.0
        static let snowOrSleet = 15.0

        static let coldPerDegree = 2.5, coldCap = 35.0, coldWarningMargin = 5.0
        static let hotPerDegree = 3.0, hotCap = 40.0, hotWarningMargin = 4.0

        static let windFreeKph = 25.0
        static let windPerKphCycling = 1.5, windPerKphOther = 0.8, windCap = 25.0
        static let strongUV = 7.0, strongUVPenalty = 8.0

        /// Penalty for a slot entirely outside daylight.
        static let darkness = 25.0
        /// Share of the slot in the dark that flags it as night, and that earns a warning.
        static let nightShare = 0.5, darkWarningShare = 0.3

        static let lateHardEndMinute = 20 * 60 + 30
        static let lateHardPenalty = 6.0
        /// "Done before <next event>" is mentioned when the event follows within this long.
        static let nextEventLookahead: TimeInterval = 90 * 60
    }

    private static func score(
        start: Date, end: Date, session: PlannedDay, nextEvent: BusyInterval?,
        forecast: WeatherForecast?, habits: StartHabits, calendar: Calendar
    ) -> SlotSuggestion {
        var penalty = 0.0
        var reasons: [String] = []
        var warnings: [String] = []
        var slotWeather: SlotWeather?
        let interval = DateInterval(start: start, end: end)
        let outdoor = isOutdoor(session.sport)

        if let hours = forecast?.hours(overlapping: interval), !hours.isEmpty {
            let weather = weather(over: hours)
            slotWeather = weather
            if outdoor { penalty += weatherPenalty(hours: hours, weather: weather, sport: session.sport, warnings: &warnings) }
        }

        if outdoor, let sun = forecast?.sun(on: start, calendar: calendar) {
            let light = DateInterval(start: sun.sunrise, end: max(sun.sunset, sun.sunrise))
            let lit = light.intersection(with: interval)?.duration ?? 0
            let darkShare = 1 - lit / interval.duration
            penalty += Points.darkness * darkShare
            slotWeather?.isNight = darkShare > Points.nightShare
            if darkShare > Points.darkWarningShare {
                warnings.append(start < sun.sunrise ? "Before sunrise (\(time(sun.sunrise, calendar: calendar)))" : "After sunset (\(time(sun.sunset, calendar: calendar)))")
            }
        }

        // A slot with nothing against it scores `baseScore`; the athlete's usual time adds up to `maxHabitBonus`.
        let habit = habits.share(at: start, calendar: calendar)
        let bonus = Points.maxHabitBonus * habit
        if habit >= Points.usualTimeShare { reasons.append("Your usual time") }

        // Hard sessions late in the evening push bedtime back.
        if session.intensity == .hard, minuteOfDay(end, calendar: calendar) > Points.lateHardEndMinute {
            penalty += Points.lateHardPenalty
            warnings.append("Late hard session can hurt sleep")
        }

        if let nextEvent, nextEvent.start.timeIntervalSince(end) <= Points.nextEventLookahead, !nextEvent.isSession {
            reasons.append("Done before \(nextEvent.title.isEmpty ? "your next event" : nextEvent.title) at \(time(nextEvent.start, calendar: calendar))")
        }

        return SlotSuggestion(
            start: start, end: end,
            score: min(max(Points.baseScore - penalty + bonus, 0), 100),
            weather: slotWeather, reasons: reasons, warnings: warnings
        )
    }

    /// The worst condition, average temperatures and wind, and highest rain chance over the hours a slot covers.
    private static func weather(over hours: [HourlyWeather]) -> SlotWeather {
        func average(_ value: KeyPath<HourlyWeather, Double>) -> Double {
            hours.map { $0[keyPath: value] }.reduce(0, +) / Double(hours.count)
        }
        return SlotWeather(
            condition: hours.max { $0.condition.severity < $1.condition.severity }?.condition ?? .cloudy,
            temperatureC: average(\.temperatureC),
            apparentTemperatureC: average(\.apparentTemperatureC),
            precipitationChance: hours.map(\.precipitationChance).max() ?? 0,
            windKph: average(\.windKph)
        )
    }

    /// Penalty for outdoor weather (rain, storms, temperature, wind, sun), adding what speaks against it to `warnings`.
    private static func weatherPenalty(hours: [HourlyWeather], weather: SlotWeather, sport: String, warnings: inout [String]) -> Double {
        let chance = weather.precipitationChance
        let millimeters = hours.map(\.precipitationMm).reduce(0, +)
        let feelsLike = weather.apparentTemperatureC
        let wind = weather.windKph
        let uv = hours.map(\.uvIndex).max() ?? 0

        var penalty = chance * Points.rainPerChance + min(millimeters, Points.rainMillimeterCap) * Points.rainPerMillimeter
        if chance >= Points.rainWarningChance { warnings.append("Rain likely (\(Int((chance * 100).rounded()))%)") }
        switch weather.condition {
        case .thunderstorm:
            penalty += Points.thunderstorm
            warnings.append("Thunderstorms")
        case .snow, .sleet:
            penalty += Points.snowOrSleet
            warnings.append(weather.condition.title)
        default: break
        }

        let comfort = comfortRange(for: sport)
        if feelsLike < comfort.lowerBound {
            penalty += min((comfort.lowerBound - feelsLike) * Points.coldPerDegree, Points.coldCap)
            if feelsLike < comfort.lowerBound - Points.coldWarningMargin { warnings.append("Cold: feels like \(Int(feelsLike.rounded())) °C") }
        } else if feelsLike > comfort.upperBound {
            penalty += min((feelsLike - comfort.upperBound) * Points.hotPerDegree, Points.hotCap)
            if feelsLike > comfort.upperBound + Points.hotWarningMargin { warnings.append("Hot: feels like \(Int(feelsLike.rounded())) °C") }
        }
        if wind > Points.windFreeKph {
            penalty += min((wind - Points.windFreeKph) * (sport == Sport.cycling ? Points.windPerKphCycling : Points.windPerKphOther), Points.windCap)
            warnings.append("Windy (\(Int(wind.rounded())) km/h)")
        }
        if uv >= Points.strongUV {
            penalty += Points.strongUVPenalty
            warnings.append("Strong sun (UV \(Int(uv.rounded())))")
        }
        return penalty
    }

    // MARK: Weekly prompt

    /// "Mon 27 Oct | 3.5 h free: 06:00–08:15, 17:15–21:00 | rain likely 15–18" for the weekly prompt.
    static func availabilityLine(
        date: Date, label: String, busy: [BusyInterval], forecast: WeatherForecast?, settings: ScheduleSettings,
        compact: Bool, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        // The athlete's own session events are part of the plan, not something to plan around.
        let gaps = freeGaps(on: date, busy: busy.filter { !$0.isSession }, settings: settings, now: now, calendar: calendar)
            .filter { $0.duration >= minUsefulGap }
        let hours = gaps.map(\.duration).reduce(0, +) / 3600
        var parts = [label, "\(PromptBuilder.num(hours, 1)) h free"]
        if !compact, !gaps.isEmpty {
            parts[1] += ": " + gaps.map { "\(time($0.start, calendar: calendar))–\(time($0.end, calendar: calendar))" }.joined(separator: ", ")
        }
        if let wet = wetHours(on: date, forecast: forecast, calendar: calendar, settings: settings) {
            parts.append("rain likely \(wet)")
        }
        return parts.joined(separator: " | ")
    }

    /// "15–18" for the span of daytime hours with a rain chance of 50% or more.
    private static func wetHours(on date: Date, forecast: WeatherForecast?, calendar: Calendar, settings: ScheduleSettings) -> String? {
        guard let forecast else { return nil }
        let wet = forecast.hours.filter {
            calendar.isDate($0.date, inSameDayAs: date) && $0.precipitationChance >= Points.rainWarningChance
        }.map { calendar.component(.hour, from: $0.date) }
            .filter { $0 * 60 >= settings.earliestMinute && $0 * 60 < settings.latestMinute }
        guard let first = wet.min(), let last = wet.max() else { return nil }
        return "\(first)–\(last + 1)"
    }

    // MARK: Clock helpers

    private static func roundUp(_ date: Date, to step: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    /// "06:00" from minutes after midnight.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        clock(minuteOfDay(date, calendar: calendar))
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

/// When the athlete usually starts workouts: a share per hour, 1 for the most common hour. Weekdays and weekends
/// are counted apart when each has enough workouts, since routines differ.
nonisolated struct StartHabits: Sendable {
    /// Weekdays or weekends need this many workouts to be counted apart from the rest.
    private static let minWorkoutsPerPart = 3.0

    private var weekday: [Int: Double]
    private var weekend: [Int: Double]

    init(workouts: [WorkoutSummary], calendar: Calendar = .current) {
        var weekdayCounts: [Int: Double] = [:]
        var weekendCounts: [Int: Double] = [:]
        for workout in workouts {
            let hour = calendar.component(.hour, from: workout.start)
            if calendar.isDateInWeekend(workout.start) {
                weekendCounts[hour, default: 0] += 1
            } else {
                weekdayCounts[hour, default: 0] += 1
            }
        }
        let all = weekdayCounts.merging(weekendCounts, uniquingKeysWith: +)
        func normalized(_ counts: [Int: Double]) -> [Int: Double] {
            let source = counts.values.reduce(0, +) >= Self.minWorkoutsPerPart ? counts : all
            guard let top = source.values.max(), top > 0 else { return [:] }
            return source.mapValues { $0 / top }
        }
        weekday = normalized(weekdayCounts)
        weekend = normalized(weekendCounts)
    }

    static let none = StartHabits(workouts: [])

    /// 0…1. Half credit for the hour before and after, so 17:30 still counts for someone who starts at 18:00.
    func share(at date: Date, calendar: Calendar = .current) -> Double {
        let shares = calendar.isDateInWeekend(date) ? weekend : weekday
        let hour = calendar.component(.hour, from: date)
        return max(shares[hour] ?? 0, (shares[hour - 1] ?? 0) / 2, (shares[hour + 1] ?? 0) / 2)
    }
}
