import Foundation
import UserNotifications

/// The debug state dump (Documents/debug-state.json): what the app computed, so tests can check numbers, not just pixels.
extension AppModel {
    private static var debugStateURL: URL { URL.documentsDirectory.appending(path: "debug-state.json") }

    /// Whether the dump is written: always in the Simulator; on a device (a debug build installed from Xcode is what
    /// runs there day to day) only when launched with `-debugState YES`, since it holds health data and AI prompts.
    static var writesDebugState: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        UserDefaults.standard.bool(forKey: DefaultsKey.debugState)
        #endif
    }

    /// Deletes a dump left on a device by an earlier version that always wrote it.
    static func removeUnwantedDebugState() {
        #if DEBUG
        if !writesDebugState { try? FileManager.default.removeItem(at: debugStateURL) }
        #endif
    }

    /// Writes the dump (no-op in release builds). Passing `detail` also makes it the workout the dump describes.
    func writeDebugState(detail: WorkoutDetail? = nil) {
        #if DEBUG
        guard Self.writesDebugState else { return }
        if let detail { debugDetail = detail }
        var state = debugOverviewState()
        state.merge(debugPlanState()) { $1 }
        state.merge(debugStrengthState()) { $1 }
        state["schedule"] = debugScheduleState()
        state["notifications"] = [
            "readiness": notificationSettings.readiness, "newWorkouts": notificationSettings.newWorkouts,
            "sessionReminders": notificationSettings.sessionReminders, "reminderLeadMinutes": notificationSettings.reminderLeadMinutes,
            "authorization": notificationAuthorization.rawValue, "recentlyHandled": Array(notificationLog.keys.suffix(10)),
        ] as [String: Any]
        state.merge(debugMetricsState()) { $1 }
        if UserDefaults.standard.string(forKey: DefaultsKey.route) == "chat" {
            // What the chat's tools return, so they can be checked without the model.
            let toolbox = CoachToolbox(model: self, chat: nil)
            state["coachTools"] = [
                "recentDays": toolbox.recentDays(7),
                "workouts": toolbox.workouts(days: 14, sport: "running"),
                "trends": toolbox.trends(),
                "raceForecast": toolbox.raceForecast(distance: "Half marathon", month: 4),
                "plan": toolbox.plan(),
                "freeTimes": toolbox.freeTimes(day: ""),
                "weather": toolbox.weather(day: PromptBuilder.dayLabel(.now, calendar: .current)),
            ]
        }
        if let progress { state["progress"] = Self.debugProgressState(progress) }
        if let detail = debugDetail, let snapshot, let metrics {
            state["detail"] = debugDetailState(detail, snapshot: snapshot, metrics: metrics)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.debugStateURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("Stride: couldn't write debug state: \(error)")
        }
        #endif
    }
}

#if DEBUG
private let isoFormatter = ISO8601DateFormatter()

/// Rounded for stable output; NSNull for missing or non-finite numbers.
private func rounded(_ value: Double?, _ digits: Int = 1) -> Any {
    guard let value, value.isFinite else { return NSNull() }
    let factor = pow(10, Double(digits))
    return (value * factor).rounded() / factor
}

private func label(_ date: Date) -> String { PromptBuilder.dayLabel(date, calendar: .current) }

private extension AppModel {
    func debugOverviewState() -> [String: Any] {
        [
            "generatedAt": isoFormatter.string(from: .now),
            "dataSource": fixture != nil ? "fixture" : (snapshot?.isDemo == true ? "demo" : "health"),
            "route": UserDefaults.standard.string(forKey: DefaultsKey.route) ?? NSNull(),
            "aiBlocker": aiBlocker ?? NSNull(),
            "healthError": healthError ?? NSNull(),
            "analysisError": analysisError ?? NSNull(),
            "analysisNotice": analysisNotice ?? NSNull(),
            "latestWeeklyHeadline": latestAnalysis?.report.headline ?? NSNull(),
            "events": debugEvents,
        ]
    }

    func debugPlanState() -> [String: Any] {
        var state: [String: Any] = [:]
        if let readiness {
            state["readiness"] = ["level": "\(readiness.level)", "signals": readiness.signals.map(\.text), "fine": readiness.fine]
        }
        if let adjustment = todayAdjustment {
            state["todayAdjustment"] = [
                "state": adjustment.state.rawValue,
                "original": adjustment.original.briefDescription,
                "suggested": adjustment.adjustment.session.briefDescription,
                "reason": adjustment.adjustment.reason,
            ]
        }
        if let adherence = planAdherence {
            state["planAdherence"] = adherence.days.map { day in
                ([label(day.date) + ": " + day.status.rawValue] + day.notes).joined(separator: "; ")
            }
        }
        if !athleteDays.isEmpty {
            state["athleteDays"] = athleteDays.map { label($0.date) + ": " + $0.day.briefDescription }
        }
        return state
    }

    func debugStrengthState() -> [String: Any] {
        guard let report = strength.report else { return [:] }
        return ["strength": [
            "source": "\(strength.source)",
            "loggedSessions": strength.sessions?.count ?? NSNull(),
            "syncError": strength.syncError ?? NSNull(),
            "sessionsPerWeek": rounded(report.sessionsPerWeek, 2),
            "minutesPerWeek": rounded(report.minutesPerWeek, 0),
            "volumeLast28Days": rounded(report.volumeLast28Days, 0),
            "weeks": report.weeks.map { "\(label($0.start)): \($0.sessions) sessions, \(Int($0.minutes)) min, volume \(Int($0.volumeKg ?? -1))" },
            "lifts": report.lifts.map { "\($0.title): \($0.timesDone)x, latest \(Int($0.latest ?? 0)) kg, change \(Int($0.change ?? 0))" },
            "records": report.records.map { "\(label($0.date)) \($0.title) \(Int($0.oneRepMax)) kg" },
            "entries": report.entries.prefix(8).map { "\(label($0.date)) \($0.title) watch:\($0.workout != nil) log:\($0.session != nil)" },
        ] as [String: Any]]
    }

    func debugScheduleState() -> [String: Any] {
        let schedule = self.schedule
        return [
            "active": schedule.isActive,
            "calendarAccess": "\(schedule.calendarAccess)",
            "weatherSource": schedule.forecast?.source.rawValue ?? NSNull(),
            "forecastHours": schedule.forecast?.hours.count ?? 0,
            "weatherError": schedule.weatherError ?? NSNull(),
            "days": schedule.days.map { day in
                [
                    "day": label(day.date),
                    "session": day.session.briefDescription,
                    "scheduled": day.scheduled.map { isoFormatter.string(from: $0.start) } ?? NSNull(),
                    "note": day.note ?? NSNull(),
                    "slots": day.slots.map { slot in
                        "\(SessionScheduler.time(slot.start, calendar: .current))–\(SessionScheduler.time(slot.end, calendar: .current)) score \(Int(slot.score.rounded())): "
                            + ([slot.weather?.summary].compactMap(\.self) + slot.reasons + slot.warnings).joined(separator: ", ")
                    },
                ] as [String: Any]
            },
        ]
    }

    func debugMetricsState() -> [String: Any] {
        guard let metrics else { return [:] }
        let ind = metrics.indicators
        return [
            "indicators": [
                "acuteLoad": rounded(ind.acuteLoad, 0), "chronicLoad": rounded(ind.chronicLoad, 0), "acwr": rounded(ind.acwr, 2),
                "sleep7": rounded(ind.sleep7), "restingHR7": rounded(ind.restingHR7), "restingHR28": rounded(ind.restingHR28),
                "hrv7": rounded(ind.hrv7), "hrv28": rounded(ind.hrv28), "steps7": rounded(ind.steps7, 0),
                "latestWeightKg": rounded(ind.latestWeightKg, 1), "weight7": rounded(ind.weight7, 1), "weight28": rounded(ind.weight28, 1),
            ],
            "workouts": workoutsNewestFirst.prefix(25).enumerated().map { index, workout in
                [
                    "index": index, "id": workout.id.uuidString, "sport": workout.sport, "source": workout.sourceName,
                    "start": isoFormatter.string(from: workout.start), "minutes": rounded(workout.durationMinutes),
                    "km": rounded(workout.distanceKm, 2),
                    "pace": workout.isFootSport ? WorkoutFormat.pace(workout.paceSecondsPerKm) : NSNull(),
                    "avgHR": rounded(workout.averageHeartRate, 0), "maxHR": rounded(workout.maxHeartRate, 0),
                    "load": rounded(metrics.workoutLoad[workout.id], 0),
                ] as [String: Any]
            },
        ]
    }

    static func debugProgressState(_ progress: ProgressReport) -> [String: Any] {
        [
            "firstDate": progress.firstDate.map { isoFormatter.string(from: $0) } ?? NSNull(),
            "athleteLevel": progress.athlete.level, "athleteXP": rounded(progress.athlete.xp, 0), "title": progress.athlete.title,
            "skills": Dictionary(uniqueKeysWithValues: progress.skills.map { ($0.key.rawValue, ["level": $0.value.level, "xp": rounded($0.value.xp, 0)]) }),
            "weekStreak": progress.currentWeekStreak, "longestWeekStreak": progress.longestWeekStreak,
            "totalWorkouts": progress.totalWorkouts, "totalKm": rounded(progress.totalKm, 0), "totalHours": rounded(progress.totalHours, 0),
            "records": progress.records.map { ["title": $0.title, "value": $0.value, "date": isoFormatter.string(from: $0.date)] },
            "achievementsUnlocked": progress.achievements.filter(\.isUnlocked).map(\.title),
        ]
    }

    func debugDetailState(_ detail: WorkoutDetail, snapshot: HealthSnapshot, metrics: MetricsReport) -> [String: Any] {
        let zones = detail.zoneSeconds(zones: metrics.heartRateZones)
        var state: [String: Any] = [
            "id": detail.summary.id.uuidString,
            "sport": detail.summary.sport,
            "heartRateSamples": detail.heartRate.count,
            "heartRateIntervalSeconds": rounded(detail.heartRateIntervalSeconds, 0),
            "zonesMinutes": zones.map { rounded($0 / 60) },
            "zoneRanges": metrics.heartRateZones.summary,
            "decouplingPercent": rounded(detail.decouplingPercent),
            "cadence": rounded(detail.cadence, 0),
            "elevationGainM": rounded(detail.elevationGainM, 0),
            "routePoints": detail.route.count,
            "dataNotes": detail.dataNotes,
            "splits": detail.splits.map {
                ["km": rounded($0.distanceKm, 2), "pace": WorkoutFormat.pace($0.paceSecondsPerKm), "avgHR": rounded($0.averageHeartRate, 0)] as [String: Any]
            },
            "prompt": RunPromptBuilder(
                detail: detail, snapshot: snapshot, metrics: metrics, profile: profile,
                plannedSession: plannedSession(on: detail.summary.start), note: runAnalyses[detail.summary.id]?.note ?? "",
                compact: false,
                strengthSession: strength.session(for: detail.summary), strengthHistory: strength.sessions ?? []
            ).prompt,
        ]
        if let saved = runAnalyses[detail.summary.id],
           let data = try? JSONEncoder().encode(saved.analysis),
           let json = try? JSONSerialization.jsonObject(with: data) {
            state["runAnalysis"] = json
            state["runAnalysisModel"] = saved.modelName
        }
        return state
    }
}
#endif
