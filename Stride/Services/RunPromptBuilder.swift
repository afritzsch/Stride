import Foundation

/// Brief for reviewing a single workout, with the context a coach would want around it.
nonisolated struct RunPromptBuilder {
    var detail: WorkoutDetail
    var snapshot: HealthSnapshot
    var metrics: MetricsReport
    var profile: UserProfile
    var plannedSession: PlannedDay?
    var note: String
    var compact: Bool
    var calendar = Calendar.current

    static let instructions = """
        You are an experienced endurance coach reviewing one session your athlete just completed, using data \
        from their watch (synced through Apple Health).

        Rules:
        - Work out the session's purpose from the plan, the athlete's note, or the structure of the splits and \
        heart rate, and judge it against that purpose.
        - If a measured effort is given, it is computed from time in the athlete's zones: use it as the effort \
        and never contradict it (don't call a hard session easy or lacking intensity).
        - Cite specific numbers: splits, pace, heart rate, time in zones, drift.
        - Use the athlete's heart-rate zones exactly as given (they match their watch); never assign zones from \
        % of max HR yourself.
        - Take context into account: recent load, last night's sleep, resting HR and HRV versus baseline, weather.
        - Aerobic decoupling under 5% on a steady run indicates good aerobic endurance; it's not meaningful for intervals.
        - Compare with the athlete's previous sessions of the same sport when relevant.
        - Be practical: what went well, what to change, how to recover, and what the next session should be.
        - If a metric is missing ("–"), don't guess. Address the athlete as "you". Be direct and concise.

        Writing:
        - Lists are bullet points: one short, plain point each, like a coach talking to the athlete. Never write \
        "Label: value" fragments, semicolon-separated lists, or copy lines from the brief.
        - The athlete already sees the stats, zones and data limitations in the app: interpret them, don't repeat them.
        - Data limitations describe how the watch recorded the session. They only limit what you can conclude; \
        never turn them into advice.
        """

    var prompt: String {
        let workout = detail.summary
        let maxHR = profile.effectiveMaxHeartRate
        let num = PromptBuilder.num
        var lines: [String] = []

        lines.append("ATHLETE: \(profile.primarySport), \(profile.experience.rawValue); max HR \(Int(maxHR)) bpm\(profile.isMaxHeartRateEstimated ? " (estimated)" : "")")
        lines.append("HR ZONES: \(metrics.heartRateZones.summary)")
        if profile.hasGoal {
            let target = profile.goalTarget.isEmpty ? "" : ", target \(profile.goalTarget)"
            lines.append("GOAL: \(profile.goalName.isEmpty ? "event" : profile.goalName) on \(label(profile.goalDate))\(target)")
        }
        if !profile.notes.isEmpty { lines.append("ATHLETE NOTES: \(profile.notes)") }

        lines.append("")
        lines.append("SESSION: \(workout.sport) on \(label(workout.start)) at \(workout.start.formatted(date: .omitted, time: .shortened))")
        var basics = ["duration \(WorkoutFormat.duration(workout.durationMinutes * 60))"]
        if let km = workout.distanceKm { basics.append("distance \(num(km, 2)) km") }
        if workout.isFootSport, let pace = workout.paceSecondsPerKm { basics.append("avg moving pace \(WorkoutFormat.pace(pace)) /km") }
        if !workout.isFootSport, let km = workout.distanceKm, km > 0 { basics.append("avg speed \(num(km / (workout.durationMinutes / 60), 1)) km/h") }
        basics.append("avg HR \(num(workout.averageHeartRate, 0))")
        basics.append("max HR \(num(workout.maxHeartRate, 0))")
        basics.append("load \(num(metrics.workoutLoad[workout.id], 0))")
        if let kcal = workout.activeEnergyKcal { basics.append("\(num(kcal, 0)) kcal") }
        lines.append("- " + basics.joined(separator: ", "))

        var extras: [String] = []
        if let elevation = detail.elevationGainM { extras.append("elevation gain \(num(elevation, 0)) m") }
        if let temperature = detail.temperatureC { extras.append("\(num(temperature, 0)) °C") }
        if let humidity = detail.humidityPercent { extras.append("\(num(humidity, 0))% humidity") }
        if let indoor = detail.isIndoor { extras.append(indoor ? "indoor" : "outdoor") }
        if let cadence = detail.cadence { extras.append("cadence \(num(cadence, 0)) \(workout.isFootSport ? "spm" : "rpm")") }
        if let power = detail.powerW { extras.append("avg power \(num(power, 0)) W") }
        if let stride = detail.strideLengthM { extras.append("stride \(num(stride, 2)) m") }
        if let oscillation = detail.verticalOscillationCm { extras.append("vertical oscillation \(num(oscillation, 1)) cm") }
        if let contact = detail.groundContactMs { extras.append("ground contact \(num(contact, 0)) ms") }
        if !extras.isEmpty { lines.append("- " + extras.joined(separator: ", ")) }

        let zones = detail.zoneSeconds(zones: metrics.heartRateZones)
        let zoneTotal = zones.reduce(0, +)
        if zoneTotal > 0 {
            let shares = zones.enumerated().map { "Z\($0.offset + 1) \(Int(($0.element / zoneTotal * 100).rounded()))%" }
            lines.append("- Time in HR zones: \(shares.joined(separator: ", "))")
        }
        if let effort = EffortLevel.measured(zoneSeconds: zones, durationMinutes: workout.durationMinutes) {
            let hard = Int(((zones[3] + zones[4]) / zoneTotal * 100).rounded())
            lines.append("- Measured effort: \(effort.rawValue) (\(hard)% of the time in Z4–Z5)")
        }
        if let decoupling = detail.decouplingPercent {
            lines.append("- Aerobic decoupling (pace:HR, 1st vs 2nd half): \(num(decoupling, 1))%")
        }
        if !detail.dataNotes.isEmpty {
            lines.append("")
            lines.append("DATA LIMITATIONS (how the watch recorded it, not advice material)")
            lines.append(contentsOf: detail.dataNotes.map { "- \($0)" })
        }

        if !detail.splits.isEmpty {
            lines.append("")
            lines.append("SPLITS (km | pace /km | avg HR)")
            for split in detail.splits {
                let distance = split.distanceKm < 0.99 ? " (\(num(split.distanceKm, 2)) km)" : ""
                lines.append("\(split.index)\(distance) | \(WorkoutFormat.pace(split.paceSecondsPerKm)) | \(num(split.averageHeartRate, 0))")
            }
        }

        let blockMinutes = workout.durationMinutes > 90 ? 5.0 : (compact ? 5 : 2)
        let blocks = detail.heartRateBlocks(minutes: blockMinutes)
        if blocks.contains(where: { $0 != nil }) {
            lines.append("")
            lines.append("HEART RATE (\(Int(blockMinutes))-min averages from start): " + blocks.map { num($0, 0) }.joined(separator: ", "))
        }

        if let plannedSession {
            lines.append("")
            lines.append("PLANNED FOR THIS DAY: \(plannedSession.session) (\(plannedSession.intensity.rawValue), \(plannedSession.durationMinutes) min). \(plannedSession.details)")
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            lines.append("")
            lines.append("ATHLETE'S NOTE ON THIS SESSION: \(trimmedNote)")
        }

        lines.append("")
        lines.append("CONTEXT")
        let day = calendar.startOfDay(for: workout.start)
        if let night = snapshot.sleep.first(where: { $0.date == day }) {
            lines.append("- Sleep the night before: \(num(night.asleepHours, 1)) h, bedtime \(night.bedtime.formatted(date: .omitted, time: .shortened))")
        } else {
            lines.append("- Sleep the night before: –")
        }
        let ind = metrics.indicators
        let today = snapshot.days.first { $0.date == day }
        // Leave out what's missing: small models otherwise echo "–" back to the athlete.
        if let resting = today?.restingHeartRate {
            lines.append("- Resting HR that day: \(num(resting, 0)) bpm (28-day avg \(num(ind.restingHR28, 0)))")
        }
        if let hrv = today?.hrvMs {
            lines.append("- HRV that day: \(num(hrv, 0)) ms (28-day avg \(num(ind.hrv28, 0)))")
        }
        // Load leading up to this session (not counting it), so the context is right for older workouts too.
        func loadBefore(days: Int) -> Double {
            (1...days).compactMap { calendar.date(byAdding: .day, value: -$0, to: day) }
                .map { metrics.dailyLoad[$0] ?? 0 }
                .reduce(0, +)
        }
        let acute = loadBefore(days: 7), chronic = loadBefore(days: 28) / 4
        lines.append("- Load in the 7 days before: \(num(acute, 0)); 4-week weekly avg before: \(num(chronic, 0)); ACWR: \(num(chronic > 0 ? acute / chronic : nil, 2))")

        let previous = snapshot.workouts
            .filter { $0.sport == workout.sport && $0.start < workout.start }
            .suffix(compact ? 3 : 6)
        if !previous.isEmpty {
            lines.append("")
            lines.append("PREVIOUS \(workout.sport.uppercased()) SESSIONS (date | min | km | pace | avg HR | load)")
            for session in previous {
                let pace = session.paceSecondsPerKm
                lines.append([
                    label(session.start),
                    num(session.durationMinutes, 0),
                    num(session.distanceKm, 1),
                    session.isFootSport ? WorkoutFormat.pace(pace) : "–",
                    num(session.averageHeartRate, 0),
                    num(metrics.workoutLoad[session.id], 0),
                ].joined(separator: " | "))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func label(_ date: Date) -> String {
        PromptBuilder.dayLabel(date, calendar: calendar)
    }
}
