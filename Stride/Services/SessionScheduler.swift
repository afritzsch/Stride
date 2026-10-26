import Foundation

/// Finds times for planned sessions: free calendar gaps long enough for the session, ranked by weather, daylight
/// and when the athlete usually trains. Pure logic, so the harness can check it without EventKit or a network.
nonisolated enum SessionScheduler {
    /// Sports done indoors, where the weather doesn't matter.
    static let indoorSports: Set<String> = ["Strength", "Mobility", "Yoga", "HIIT", "Swimming", "Cross training"]

    static func isOutdoor(_ sport: String) -> Bool { !indoorSports.contains(sport) && sport != PlannedDay.rest }

    /// Comfortable "feels like" temperatures in °C. Cycling runs warmer because of the wind chill.
    static func comfortRange(for sport: String) -> ClosedRange<Double> {
        switch sport {
        case "Running": 4...18
        case "Cycling": 10...24
        case "Walking", "Hiking": 6...24
        default: 5...22
        }
    }

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

        let duration = TimeInterval(max(session.durationMinutes, 15) * 60)
        // The session's own event doesn't block other times for it, so it can be moved.
        let blocking = busy.filter { $0 != scheduled }
        let gaps = freeGaps(on: day, busy: blocking, settings: settings, now: now, calendar: calendar)
        let step: TimeInterval = 15 * 60

        var candidates: [SlotSuggestion] = []
        for gap in gaps {
            var start = roundUp(gap.start, to: step)
            while start.addingTimeInterval(duration) <= gap.end {
                let end = start.addingTimeInterval(duration)
                candidates.append(score(
                    start: start, end: end, session: session, nextEvent: blocking.filter { $0.start >= end }.min { $0.start < $1.start },
                    forecast: forecast, habits: habits, calendar: calendar
                ))
                start = start.addingTimeInterval(step)
            }
        }

        // Best first; on equal scores the earlier time wins. Keep picks apart so the choice is real.
        let separation = max(duration, 3600)
        for candidate in candidates.sorted(by: { ($0.score, $1.start) > ($1.score, $0.start) }) {
            guard result.slots.count < limit else { break }
            if result.slots.allSatisfy({ abs($0.start.timeIntervalSince(candidate.start)) >= separation }) {
                result.slots.append(candidate)
            }
        }

        if result.slots.isEmpty {
            let window = "\(clock(settings.earliestMinute))–\(clock(settings.latestMinute))"
            let endOfWindow = day.addingTimeInterval(TimeInterval(settings.latestMinute * 60))
            if calendar.isDate(day, inSameDayAs: now) {
                result.note = now.addingTimeInterval(duration) > endOfWindow
                    ? "Too late today for \(session.durationMinutes) min before \(clock(settings.latestMinute))."
                    : "No free \(session.durationMinutes) min left today before \(clock(settings.latestMinute))."
            } else {
                result.note = "No free \(session.durationMinutes) min between \(window)."
            }
        }
        return result
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

    private static func score(
        start: Date, end: Date, session: PlannedDay, nextEvent: BusyInterval?,
        forecast: WeatherForecast?, habits: StartHabits, calendar: Calendar
    ) -> SlotSuggestion {
        var penalty = 0.0
        var bonus = 0.0
        var reasons: [String] = []
        var warnings: [String] = []
        var slotWeather: SlotWeather?
        let interval = DateInterval(start: start, end: end)
        let outdoor = isOutdoor(session.sport)

        if let hours = forecast?.hours(overlapping: interval), !hours.isEmpty {
            let chance = hours.map(\.precipitationChance).max() ?? 0
            let millimeters = hours.map(\.precipitationMm).reduce(0, +)
            let feelsLike = hours.map(\.apparentTemperatureC).reduce(0, +) / Double(hours.count)
            let wind = hours.map(\.windKph).reduce(0, +) / Double(hours.count)
            let uv = hours.map(\.uvIndex).max() ?? 0
            let worst = hours.max { $0.condition.severity < $1.condition.severity }?.condition ?? .cloudy
            slotWeather = SlotWeather(
                condition: worst,
                temperatureC: hours.map(\.temperatureC).reduce(0, +) / Double(hours.count),
                apparentTemperatureC: feelsLike,
                precipitationChance: chance,
                windKph: wind
            )

            if outdoor {
                penalty += chance * 40 + min(millimeters, 5) * 4
                if chance >= 0.5 { warnings.append("Rain likely (\(Int((chance * 100).rounded()))%)") }
                switch worst {
                case .thunderstorm:
                    penalty += 40
                    warnings.append("Thunderstorms")
                case .snow, .sleet:
                    penalty += 15
                    warnings.append(worst.title)
                default: break
                }

                let comfort = comfortRange(for: session.sport)
                if feelsLike < comfort.lowerBound {
                    penalty += min((comfort.lowerBound - feelsLike) * 2.5, 35)
                    if feelsLike < comfort.lowerBound - 5 { warnings.append("Cold: feels like \(Int(feelsLike.rounded())) °C") }
                } else if feelsLike > comfort.upperBound {
                    penalty += min((feelsLike - comfort.upperBound) * 3, 40)
                    if feelsLike > comfort.upperBound + 4 { warnings.append("Hot: feels like \(Int(feelsLike.rounded())) °C") }
                }
                if wind > 25 {
                    penalty += min((wind - 25) * (session.sport == "Cycling" ? 1.5 : 0.8), 25)
                    warnings.append("Windy (\(Int(wind.rounded())) km/h)")
                }
                if uv >= 7 {
                    penalty += 8
                    warnings.append("Strong sun (UV \(Int(uv.rounded())))")
                }
            }
        }

        if outdoor, let sun = forecast?.sun(on: start, calendar: calendar) {
            let light = DateInterval(start: sun.sunrise, end: max(sun.sunset, sun.sunrise))
            let lit = light.intersection(with: interval)?.duration ?? 0
            let darkShare = 1 - lit / interval.duration
            penalty += 25 * darkShare
            slotWeather?.isNight = darkShare > 0.5
            if darkShare > 0.3 {
                warnings.append(start < sun.sunrise ? "Before sunrise (\(time(sun.sunrise, calendar: calendar)))" : "After sunset (\(time(sun.sunset, calendar: calendar)))")
            }
        }

        // A slot with nothing against it scores 88; the athlete's usual time adds up to 12.
        let habit = habits.share(at: start, calendar: calendar)
        bonus += 12 * habit
        if habit >= 0.6 { reasons.append("Your usual time") }

        // Hard sessions late in the evening push bedtime back.
        if session.intensity == .hard, calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end) > 20 * 60 + 30 {
            penalty += 6
            warnings.append("Late hard session can hurt sleep")
        }

        if let nextEvent, nextEvent.start.timeIntervalSince(end) <= 90 * 60, !nextEvent.isSession {
            reasons.append("Done before \(nextEvent.title.isEmpty ? "your next event" : nextEvent.title) at \(time(nextEvent.start, calendar: calendar))")
        }

        return SlotSuggestion(
            start: start, end: end,
            score: min(max(88 - penalty + bonus, 0), 100),
            weather: slotWeather, reasons: reasons, warnings: warnings
        )
    }

    /// "Mon 27 Oct | 3.5 h free: 06:00–08:15, 17:15–21:00 | rain likely 15–18" for the weekly prompt.
    static func availabilityLine(
        date: Date, label: String, busy: [BusyInterval], forecast: WeatherForecast?, settings: ScheduleSettings,
        compact: Bool, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        // The athlete's own session events are part of the plan, not something to plan around.
        let gaps = freeGaps(on: date, busy: busy.filter { !$0.isSession }, settings: settings, now: now, calendar: calendar)
            .filter { $0.duration >= 30 * 60 }
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
            calendar.isDate($0.date, inSameDayAs: date) && $0.precipitationChance >= 0.5
        }.map { calendar.component(.hour, from: $0.date) }
            .filter { $0 * 60 >= settings.earliestMinute && $0 * 60 < settings.latestMinute }
        guard let first = wet.min(), let last = wet.max() else { return nil }
        return "\(first)–\(last + 1)"
    }

    private static func roundUp(_ date: Date, to step: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    /// "06:00" from minutes after midnight.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        clock(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }
}

/// When the athlete usually starts workouts: a share per hour, 1 for the most common hour. Weekdays and weekends
/// are counted apart when each has enough workouts, since routines differ.
nonisolated struct StartHabits: Sendable {
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
            let source = counts.values.reduce(0, +) >= 3 ? counts : all
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
