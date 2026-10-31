import Foundation
import FoundationModels

extension HealthFixture {
    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Hooks for driving the app from the Simulator (see tools/stride-mcp). Debug builds only read these
/// launch arguments:
///   -route dashboard | coach | chat | plan | settings | workouts | strength
///          | workout:<latest | latest-run | latest-strength | index | uuid>
///          | progress | skill:<endurance | power | strength | explorer | vitality | rest | discipline>
///          | metric:<load | acwr | sleep | restingHR | hrv | steps | weight>
///   -scrollTo <section>   scroll the first opened workout to route, heart-rate, zones, splits, review, or analysis;
///                         on the progress route: trend, compare, records, or achievements; on the plan route: adherence
///   -planSheet <sheet>    on the plan route, open week (the week editor), edit:<n> or time:<n> for the day n days from today
///   -analyze YES          review the first opened workout
///   -demoHevy NO          demo data without its made-up Hevy log, to see the strength screens from watch data only
///   -fixture <path>       replay an exported HealthFixture (default: Documents/fixture.json)
///   -exportFixture YES    write what the app reads to Documents/export.json
///   -probeModel YES       ask the on-device model for one word whatever `availability` says; writes Documents/model-probe.json
extension AppModel {
    static func loadFixture() -> HealthFixture? {
        let path = UserDefaults.standard.string(forKey: "fixture") ?? URL.documentsDirectory.appending(path: "fixture.json").path()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try HealthFixture.decoder().decode(HealthFixture.self, from: data)
        } catch {
            print("Stride: couldn't decode fixture at \(path): \(error)")
            return nil
        }
    }

    /// The -scrollTo and -analyze hooks, returned once so later workouts opened in the session don't repeat them.
    func consumeLaunchHooks() -> (scrollTarget: String?, analyze: Bool) {
        #if DEBUG
        guard !launchHooksConsumed else { return (nil, false) }
        launchHooksConsumed = true
        return (UserDefaults.standard.string(forKey: "scrollTo"), UserDefaults.standard.bool(forKey: "analyze"))
        #else
        return (nil, false)
        #endif
    }

    func applyLaunchRoute() {
        #if DEBUG
        guard let route = UserDefaults.standard.string(forKey: "route") else { return }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        dashboardPath = []
        progressPath = []
        switch parts.first ?? "" {
        case "progress": selectedTab = .progress
        case "skill":
            selectedTab = .progress
            if let skill = Skill(rawValue: parts.count > 1 ? parts[1] : "") { progressPath = [skill] }
        case "coach": selectedTab = .coach
        case "chat":
            selectedTab = .coach
            showsCoachChat = true
        case "plan": selectedTab = .plan
        case "settings": selectedTab = .settings
        case "workouts":
            selectedTab = .dashboard
            dashboardPath = [.allWorkouts]
        case "strength":
            selectedTab = .dashboard
            dashboardPath = [.strength]
        case "workout":
            selectedTab = .dashboard
            if let workout = workout(matching: parts.count > 1 ? parts[1] : "latest") {
                dashboardPath = [.workout(workout)]
            }
        case "metric":
            selectedTab = .dashboard
            if let metric = DashboardMetric(rawValue: parts.count > 1 ? parts[1] : "") {
                dashboardPath = [.metric(metric)]
            }
        default:
            selectedTab = .dashboard
        }
        #endif
    }

    func handleLaunchExport() async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "exportFixture") else { return }
        do {
            let url = try await exportHealthData()
            let target = URL.documentsDirectory.appending(path: "export.json")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            print("Stride: export failed: \(error)")
        }
        #endif
    }

    /// Newest-first selector: "latest", "latest-run", an index (0 = newest) or a workout UUID.
    func workout(matching selector: String) -> WorkoutSummary? {
        let newestFirst = Array((snapshot?.workouts ?? []).reversed())
        switch selector {
        case "latest": return newestFirst.first
        case "latest-run": return newestFirst.first { $0.sport == "Running" }
        case "latest-strength": return newestFirst.first { $0.kind == .strength }
        default:
            if let index = Int(selector), newestFirst.indices.contains(index) { return newestFirst[index] }
            return newestFirst.first { $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame }
        }
    }

    /// Records an error or notice for the debug state (no-op in release builds).
    func debugLog(_ message: String) {
        #if DEBUG
        print("Stride: \(message)")
        debugEvents = Array((debugEvents + ["\(ISO8601DateFormatter().string(from: .now)) \(message)"]).suffix(20))
        writeDebugState()
        #endif
    }

    /// Dumps what the app computed to Documents/debug-state.json so tests can check numbers, not just pixels.
    func writeDebugState(detail: WorkoutDetail? = nil) {
        #if DEBUG
        if let detail { debugDetail = detail }
        let iso = ISO8601DateFormatter()
        func round(_ value: Double?, _ digits: Int = 1) -> Any {
            guard let value, value.isFinite else { return NSNull() }
            let factor = pow(10, Double(digits))
            return (value * factor).rounded() / factor
        }

        var state: [String: Any] = [
            "generatedAt": iso.string(from: .now),
            "dataSource": fixture != nil ? "fixture" : (snapshot?.isDemo == true ? "demo" : "health"),
            "route": UserDefaults.standard.string(forKey: "route") ?? NSNull(),
            "aiBlocker": aiBlocker ?? NSNull(),
            "healthError": healthError ?? NSNull(),
            "analysisError": analysisError ?? NSNull(),
            "analysisNotice": analysisNotice ?? NSNull(),
            "latestWeeklyHeadline": latestAnalysis?.report.headline ?? NSNull(),
            "events": debugEvents,
        ]

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
                ([PromptBuilder.dayLabel(day.date, calendar: .current) + ": " + day.status.rawValue] + day.notes).joined(separator: "; ")
            }
        }

        if !athleteDays.isEmpty {
            state["athleteDays"] = athleteDays.map { PromptBuilder.dayLabel($0.date, calendar: .current) + ": " + $0.day.briefDescription }
        }
        if let report = strength.report {
            state["strength"] = [
                "source": "\(strength.source)",
                "loggedSessions": strength.sessions?.count ?? NSNull(),
                "syncError": strength.syncError ?? NSNull(),
                "sessionsPerWeek": round(report.sessionsPerWeek, 2),
                "minutesPerWeek": round(report.minutesPerWeek, 0),
                "volumeLast28Days": round(report.volumeLast28Days, 0),
                "weeks": report.weeks.map { "\(PromptBuilder.dayLabel($0.start, calendar: .current)): \($0.sessions) sessions, \(Int($0.minutes)) min, volume \(Int($0.volumeKg ?? -1))" },
                "lifts": report.lifts.map { "\($0.title): \($0.timesDone)x, latest \(Int($0.latest ?? 0)) kg, change \(Int($0.change ?? 0))" },
                "records": report.records.map { "\(PromptBuilder.dayLabel($0.date, calendar: .current)) \($0.title) \(Int($0.oneRepMax)) kg" },
                "entries": report.entries.prefix(8).map { "\(PromptBuilder.dayLabel($0.date, calendar: .current)) \($0.title) watch:\($0.workout != nil) log:\($0.session != nil)" },
            ] as [String: Any]
        }
        let schedule = self.schedule
        state["schedule"] = [
            "active": schedule.isActive,
            "calendarAccess": "\(schedule.calendarAccess)",
            "weatherSource": schedule.forecast?.source.rawValue ?? NSNull(),
            "forecastHours": schedule.forecast?.hours.count ?? 0,
            "weatherError": schedule.weatherError ?? NSNull(),
            "days": schedule.days.map { day in
                [
                    "day": PromptBuilder.dayLabel(day.date, calendar: .current),
                    "session": day.session.briefDescription,
                    "scheduled": day.scheduled.map { iso.string(from: $0.start) } ?? NSNull(),
                    "note": day.note ?? NSNull(),
                    "slots": day.slots.map { slot in
                        "\(SessionScheduler.time(slot.start, calendar: .current))–\(SessionScheduler.time(slot.end, calendar: .current)) score \(Int(slot.score.rounded())): "
                            + ([slot.weather?.summary].compactMap(\.self) + slot.reasons + slot.warnings).joined(separator: ", ")
                    },
                ] as [String: Any]
            },
        ] as [String: Any]

        if let metrics {
            let ind = metrics.indicators
            state["indicators"] = [
                "acuteLoad": round(ind.acuteLoad, 0), "chronicLoad": round(ind.chronicLoad, 0), "acwr": round(ind.acwr, 2),
                "sleep7": round(ind.sleep7), "restingHR7": round(ind.restingHR7), "restingHR28": round(ind.restingHR28),
                "hrv7": round(ind.hrv7), "hrv28": round(ind.hrv28), "steps7": round(ind.steps7, 0),
                "latestWeightKg": round(ind.latestWeightKg, 1), "weight7": round(ind.weight7, 1), "weight28": round(ind.weight28, 1),
            ]
            state["workouts"] = (snapshot?.workouts ?? []).reversed().prefix(25).enumerated().map { index, workout in
                [
                    "index": index, "id": workout.id.uuidString, "sport": workout.sport, "source": workout.sourceName,
                    "start": iso.string(from: workout.start), "minutes": round(workout.durationMinutes),
                    "km": round(workout.distanceKm, 2),
                    "pace": workout.isFootSport ? WorkoutFormat.pace(workout.paceSecondsPerKm) : NSNull(),
                    "avgHR": round(workout.averageHeartRate, 0), "maxHR": round(workout.maxHeartRate, 0),
                    "load": round(metrics.workoutLoad[workout.id], 0),
                ] as [String: Any]
            }
        }

        if UserDefaults.standard.string(forKey: "route") == "chat" {
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
        if let progress {
            state["progress"] = [
                "firstDate": progress.firstDate.map { iso.string(from: $0) } ?? NSNull(),
                "athleteLevel": progress.athlete.level, "athleteXP": round(progress.athlete.xp, 0), "title": progress.athlete.title,
                "skills": Dictionary(uniqueKeysWithValues: progress.skills.map { ($0.key.rawValue, ["level": $0.value.level, "xp": round($0.value.xp, 0)]) }),
                "weekStreak": progress.currentWeekStreak, "longestWeekStreak": progress.longestWeekStreak,
                "totalWorkouts": progress.totalWorkouts, "totalKm": round(progress.totalKm, 0), "totalHours": round(progress.totalHours, 0),
                "records": progress.records.map { ["title": $0.title, "value": $0.value, "date": iso.string(from: $0.date)] },
                "achievementsUnlocked": progress.achievements.filter(\.isUnlocked).map(\.title),
            ] as [String: Any]
        }

        if let detail = debugDetail, let snapshot, let metrics {
            let zones = detail.zoneSeconds(zones: metrics.heartRateZones)
            var detailState: [String: Any] = [
                "id": detail.summary.id.uuidString,
                "sport": detail.summary.sport,
                "heartRateSamples": detail.heartRate.count,
                "heartRateIntervalSeconds": round(detail.heartRateIntervalSeconds, 0),
                "zonesMinutes": zones.map { round($0 / 60) },
                "zoneRanges": metrics.heartRateZones.summary,
                "decouplingPercent": round(detail.decouplingPercent),
                "cadence": round(detail.cadence, 0),
                "elevationGainM": round(detail.elevationGainM, 0),
                "routePoints": detail.route.count,
                "dataNotes": detail.dataNotes,
                "splits": detail.splits.map {
                    ["km": round($0.distanceKm, 2), "pace": WorkoutFormat.pace($0.paceSecondsPerKm), "avgHR": round($0.averageHeartRate, 0)] as [String: Any]
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
                detailState["runAnalysis"] = json
                detailState["runAnalysisModel"] = saved.modelName
            }
            state["detail"] = detailState
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL.documentsDirectory.appending(path: "debug-state.json"), options: .atomic)
        } catch {
            print("Stride: couldn't write debug state: \(error)")
        }
        #endif
    }
}

#if DEBUG
extension AppModel {
    func probeModelIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "probeModel") else { return }
        let model = SystemLanguageModel.default
        var probe: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: .now),
            "availability": String(describing: model.availability),
            "supportsCurrentLocale": model.supportsLocale(),
            "locale": Locale.current.identifier,
        ]
        let url = URL.documentsDirectory.appending(path: "model-probe.json")
        func save() {
            let data = try? JSONSerialization.data(withJSONObject: probe, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: url)
        }
        save()  // before generating, in case it never returns
        do {
            probe["response"] = try await LanguageModelSession().respond(to: "Reply with the single word OK.").content
        } catch {
            probe["error"] = String(describing: error)
        }
        probe["availabilityAfter"] = String(describing: model.availability)
        save()
    }
}
#endif
