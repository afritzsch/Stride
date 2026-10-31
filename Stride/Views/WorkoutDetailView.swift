import SwiftUI

struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    var workout: WorkoutSummary

    @State private var detail: WorkoutDetail?
    @State private var loadError: String?
    /// Debug launch hook (-analyze): hands the review section the go-ahead once the workout has loaded.
    @State private var analyzesOnLoad = false

    private var zones: HeartRateZones { model.heartRateZones }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    WorkoutStats(workout: workout, detail: detail, load: model.metrics?.workoutLoad[workout.id])
                    if workout.kind == .strength {
                        StrengthWorkoutSection(workout: workout)
                    }
                    if let detail {
                        if !detail.dataNotes.isEmpty {
                            Card {
                                ForEach(detail.dataNotes, id: \.self) { note in
                                    Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !detail.route.isEmpty {
                            RouteMap(route: detail.route, zones: zones, heartRate: detail.heartRate).id("route")
                        } else if detail.isIndoor != true, workout.isFootSport || workout.sport == Sport.cycling {
                            Card {
                                Label("No GPS route was shared to Apple Health for this workout.", systemImage: "map")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !detail.heartRate.isEmpty {
                            HeartRateChart(detail: detail).id("heart-rate")
                            ZoneBreakdown(seconds: detail.zoneSeconds(zones: zones), zones: zones).id("zones")
                        }
                        if !detail.splits.isEmpty {
                            SplitsCard(splits: detail.splits, decoupling: detail.decouplingPercent).id("splits")
                        }
                    } else if let loadError {
                        ErrorCard(message: loadError)
                    } else {
                        ProgressView().padding()
                    }
                    CoachReviewSection(workout: workout, detail: detail, analyzesOnLoad: analyzesOnLoad)
                }
                .padding()
            }
            .navigationTitle(workout.sport)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if model.runAnalyses[workout.id] == nil {
                    AppleAnalyzer.prewarm(instructions: RunPromptBuilder.instructions(for: workout.kind))
                }
                if workout.kind == .strength { await model.strength.sync() }
                await load()
                let hooks = model.consumeLaunchHooks()
                if let target = hooks.scrollTarget {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(target, anchor: .top)
                }
                analyzesOnLoad = hooks.analyze
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title2.bold())
            Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(workout.sourceName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let planned = model.plannedSession(on: workout.start) {
                Label("Planned: \(planned.session), \(planned.durationMinutes) min", systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(planned.intensity.color)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        guard detail == nil else { return }
        do {
            let loaded = try await model.workoutDetail(for: workout)
            detail = loaded
            model.writeDebugState(detail: loaded)
        } catch {
            loadError = "Couldn't load this workout's details: \(error.localizedDescription)"
            model.debugLog("Workout detail failed: \(error)")
        }
    }
}

// MARK: - Stats

private struct WorkoutStats: View {
    var workout: WorkoutSummary
    var detail: WorkoutDetail?
    var load: Double?

    private var stats: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = [("Time", WorkoutFormat.duration(workout.durationMinutes * 60))]
        if let km = workout.distanceKm {
            items.append(("Distance", "\(Format.number(km, digits: 2)) km"))
            if workout.isFootSport {
                items.append(("Avg pace", "\(WorkoutFormat.pace(workout.paceSecondsPerKm)) /km"))
            } else {
                items.append(("Avg speed", "\(Format.number(km / (workout.durationMinutes / 60), digits: 1)) km/h"))
            }
        }
        if let hr = workout.averageHeartRate { items.append(("Avg HR", "\(Int(hr)) bpm")) }
        if let hr = workout.maxHeartRate { items.append(("Max HR", "\(Int(hr)) bpm")) }
        if let load { items.append(("Load", Format.number(load))) }
        if let kcal = workout.activeEnergyKcal { items.append(("Calories", "\(Int(kcal)) kcal")) }
        if let detail {
            if let elevation = detail.elevationGainM { items.append(("Elevation", "\(Int(elevation)) m")) }
            if let cadence = detail.cadence { items.append(("Cadence", "\(Int(cadence)) \(workout.isFootSport ? "spm" : "rpm")")) }
            if let power = detail.powerW { items.append(("Power", "\(Int(power)) W")) }
            if let stride = detail.strideLengthM { items.append(("Stride", "\(Format.number(stride, digits: 2)) m")) }
            if let oscillation = detail.verticalOscillationCm { items.append(("Vert. osc.", "\(Format.number(oscillation, digits: 1)) cm")) }
            if let contact = detail.groundContactMs { items.append(("Ground contact", "\(Int(contact)) ms")) }
            if let temperature = detail.temperatureC {
                let humidity = detail.humidityPercent.map { ", \(Int($0))%" } ?? ""
                items.append(("Weather", "\(Int(temperature.rounded()))°C\(humidity)"))
            }
        }
        return items
    }

    var body: some View {
        StatGrid(stats: stats)
    }
}
