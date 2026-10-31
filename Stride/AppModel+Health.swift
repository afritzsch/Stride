import Foundation

/// Reading Apple Health (or demo data, or a fixture), the metrics computed from it, and the long history archive.
extension AppModel {
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        healthError = nil
        defer {
            writeDebugState()
            if generation == refreshGeneration { Task { await refreshArchive() } }
        }
        // A fixture wins over demo data; both are replayed without asking HealthKit.
        if let replayed = fixture?.snapshot ?? (useDemoData ? DemoData.snapshot() : nil) {
            snapshot = replayed
            needsHealthAuthorization = false
            isLoadingHealth = false  // an older refresh for the real data may still be running
            recomputeMetrics()
            return
        }
        // Don't keep showing (or analyzing) demo data once it's switched off.
        if snapshot?.isDemo == true {
            snapshot = nil
            metrics = nil
        }
        guard HealthKitService.isAvailable else {
            isLoadingHealth = false
            healthError = "Apple Health isn't available on this device."
            return
        }
        let needsAuthorization = await health.needsAuthorizationPrompt()
        guard generation == refreshGeneration else { return }
        needsHealthAuthorization = needsAuthorization
        guard !needsAuthorization else {
            isLoadingHealth = false
            return
        }

        isLoadingHealth = true
        defer { if generation == refreshGeneration { isLoadingHealth = false } }
        do {
            let fetched = try await health.fetchSnapshot()
            guard generation == refreshGeneration else { return }
            snapshot = fetched
            recomputeMetrics()
        } catch {
            guard generation == refreshGeneration else { return }
            healthError = error.localizedDescription
        }
    }

    func connectHealth() async {
        do {
            try await health.requestAuthorization()
            await refresh()
        } catch {
            healthError = error.localizedDescription
        }
    }

    /// Demo data and fixtures are replayed, so weigh-ins only go to Apple Health when it's the data source.
    var savesToHealth: Bool { fixture == nil && snapshot?.isDemo != true }

    /// Saves a weigh-in to Apple Health, or for demo data and fixtures only to the data in memory (until the next refresh).
    func logWeight(kg: Double, at date: Date) async throws {
        guard savesToHealth else {
            let calendar = Calendar.current
            guard var updated = snapshot,
                  let index = updated.days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) else { return }
            updated.days[index].bodyMassKg = kg
            snapshot = updated
            recomputeMetrics()
            writeDebugState()
            return
        }
        try await health.saveBodyMass(kg: kg, at: date)
        await refresh()
    }

    func recomputeMetrics() {
        metrics = snapshot.map { MetricsReport(snapshot: $0, profile: profile) }
        // Never mix demo history with real data (or the reverse) while the archive catches up after a switch.
        let archive = archive?.isDemo == snapshot?.isDemo ? archive : nil
        progress = snapshot.map { ProgressReport(snapshot: $0.prepending(archive), profile: profile) }
    }

    /// Loads the long history behind the snapshot. Apple Health is reread at most once a week unless forced,
    /// since years of workouts and sleep take a while; the snapshot covers recent changes in between.
    func refreshArchive(force: Bool = false) async {
        guard let snapshot, !isLoadingArchive else { return }
        if fixture != nil {
            // Fixtures only hold the snapshot window.
            archive = nil
        } else if snapshot.isDemo {
            archive = DemoData.archive(before: snapshot.days.first?.date ?? snapshot.fetchedAt)
        } else {
            if archive?.isDemo != false { archive = JSONStore.load(HealthSnapshot.self, from: JSONStore.archive) }
            if force || archive.map({ Date.now.timeIntervalSince($0.fetchedAt) > Limits.archiveMaxAge }) ?? true {
                isLoadingArchive = true
                defer { isLoadingArchive = false }
                do {
                    let fetched = try await health.fetchHistory()
                    // Demo data or a fixture may have been switched on meanwhile.
                    guard self.snapshot?.isDemo == false, fixture == nil else { return }
                    archive = fetched
                    if !JSONStore.save(fetched, to: JSONStore.archive) {
                        debugLog("Couldn't cache the history archive; it will be read again next time.")
                    }
                } catch {
                    debugLog("Reading history failed: \(error)")
                }
            }
        }
        recomputeMetrics()
        writeDebugState()
    }

    func workoutDetail(for workout: WorkoutSummary) async throws -> WorkoutDetail {
        if let fixture {
            guard let raw = fixture.workouts.first(where: { $0.workoutID == workout.id }) else { throw CocoaError(.fileNoSuchFile) }
            return WorkoutDetail.build(summary: workout, raw: raw)
        }
        if snapshot?.isDemo == true { return DemoData.detail(for: workout) }
        return try await health.workoutDetail(for: workout)
    }

    /// Where the debug export is written; deleted again when Settings is left and on the next launch.
    static let healthExportURL = URL.temporaryDirectory.appending(path: "stride-health-export.json")

    /// Writes everything the app reads to a JSON file for debugging, and returns its location. GPS routes show
    /// where the athlete lives and trains, so they're left out unless `includeRoutes` (splits that come from GPS
    /// then don't replay).
    func exportHealthData(includeRoutes: Bool) async throws -> URL {
        var export: HealthFixture
        if let fixture {
            export = fixture
        } else if let snapshot, snapshot.isDemo {
            export = HealthFixture(exportedAt: .now, snapshot: snapshot, workouts: snapshot.workouts.map(DemoData.rawWorkout))
        } else {
            export = try await health.exportFixture()
        }
        if !includeRoutes {
            for index in export.workouts.indices { export.workouts[index].route = nil }
        }
        let url = Self.healthExportURL
        try HealthFixture.encoder().encode(export).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes the debug export, so raw health data doesn't linger in the app's temporary folder.
    static func deleteHealthExport() {
        try? FileManager.default.removeItem(at: healthExportURL)
    }
}
