import Foundation

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
///   -route dashboard | coach | plan | settings | workouts | workout:<latest | latest-run | index | uuid>
///   -scrollTo <section>   scroll the first opened workout to route, heart-rate, zones, splits, review, or analysis
///   -analyze YES          review the first opened workout
///   -fixture <path>       replay an exported HealthFixture (default: Documents/fixture.json)
///   -exportFixture YES    write what the app reads to Documents/export.json
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
        switch parts.first ?? "" {
        case "coach": selectedTab = .coach
        case "plan": selectedTab = .plan
        case "settings": selectedTab = .settings
        case "workouts":
            selectedTab = .dashboard
            dashboardPath = [.allWorkouts]
        case "workout":
            selectedTab = .dashboard
            if let workout = workout(matching: parts.count > 1 ? parts[1] : "latest") {
                dashboardPath = [.workout(workout)]
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
            "engine": engine.rawValue,
            "engineBlocker": engineBlocker ?? NSNull(),
            "healthError": healthError ?? NSNull(),
            "analysisError": analysisError ?? NSNull(),
            "analysisNotice": analysisNotice ?? NSNull(),
            "latestWeeklyHeadline": latestAnalysis?.report.headline ?? NSNull(),
            "events": debugEvents,
        ]

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
                    compact: false
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
