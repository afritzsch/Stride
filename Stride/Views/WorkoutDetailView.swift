import Charts
import MapKit
import SwiftUI

struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    var workout: WorkoutSummary

    @State private var detail: WorkoutDetail?
    @State private var loadError: String?
    @State private var note = ""
    @State private var analysisError: String?
    @State private var notice: String?

    private var zones: HeartRateZones { model.heartRateZones }
    private var isAnalyzing: Bool { model.analyzingWorkoutIDs.contains(workout.id) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    StatGrid(workout: workout, detail: detail, load: model.metrics?.workoutLoad[workout.id])
                    if workout.kind == .strength {
                        StrengthWorkoutSection(workout: workout)
                    }
                    if let detail {
                        if !detail.dataNotes.isEmpty {
                            Card {
                                ForEach(Array(detail.dataNotes.enumerated()), id: \.offset) { _, note in
                                    Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !detail.route.isEmpty {
                            RouteMap(route: detail.route, zones: zones, heartRate: detail.heartRate).id("route")
                        } else if detail.isIndoor != true, workout.isFootSport || workout.sport == "Cycling" {
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
                    analyzeCard.id("review")
                    if isAnalyzing, let preview = model.runPreviews[workout.id] {
                        RunAnalysisPreview(analysis: preview, showsEffort: workout.kind == .endurance)
                    } else if let saved = model.runAnalyses[workout.id] {
                        RunAnalysisContent(saved: saved, showsEffort: workout.kind == .endurance).id("analysis")
                    }
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
                if hooks.analyze, model.runAnalyses[workout.id] == nil {
                    await analyze()
                }
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

    private var analyzeCard: some View {
        Card(title: "Coach review") {
            TextField("How did it feel? What was the plan? (optional)", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            AnalyzeControls(
                isRunning: isAnalyzing,
                runningText: "Reviewing your session…",
                buttonTitle: model.runAnalyses[workout.id] == nil ? "Analyze this \(workout.sport.lowercased())" : "Analyze again",
                isDisabled: detail == nil,
                notice: notice,
                error: analysisError
            ) {
                Task { await analyze() }
            }
        }
    }

    private func load() async {
        guard detail == nil else { return }
        if note.isEmpty, let saved = model.runAnalyses[workout.id] { note = saved.note }
        do {
            let loaded = try await model.workoutDetail(for: workout)
            detail = loaded
            model.writeDebugState(detail: loaded)
        } catch {
            loadError = "Couldn't load this workout's details: \(error.localizedDescription)"
            model.debugLog("Workout detail failed: \(error)")
        }
    }

    private func analyze() async {
        guard let detail else { return }
        analysisError = nil
        notice = nil
        do {
            notice = try await model.analyzeWorkout(detail, note: note)
            if let notice { model.debugLog("Run analysis notice: \(notice)") }
        } catch {
            analysisError = error.localizedDescription
            model.debugLog("Run analysis failed: \(error)")
        }
    }
}

// MARK: - Stats

private struct StatGrid: View {
    var workout: WorkoutSummary
    var detail: WorkoutDetail?
    var load: Double?

    private var stats: [(String, String)] {
        var items: [(String, String)] = [("Time", WorkoutFormat.duration(workout.durationMinutes * 60))]
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(stats, id: \.0) { title, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .cardBackground()
    }
}

// MARK: - Heart rate

private struct HeartRateChart: View {
    var detail: WorkoutDetail

    /// Minute-level averages when readings are dense, so the line shows the trend instead of sensor noise.
    private var points: [(minutes: Double, bpm: Double)] {
        let start = detail.summary.start
        guard (detail.heartRateIntervalSeconds ?? .infinity) < 60 else {
            return detail.heartRate.map { ($0.date.timeIntervalSince(start) / 60, $0.value) }
        }
        return detail.heartRateBlocks(minutes: 1).enumerated().compactMap { index, bpm in
            bpm.map { (Double(index) + 0.5, $0) }
        }
    }

    var body: some View {
        let points = self.points
        let duration = max(detail.end.timeIntervalSince(detail.summary.start) / 60, 1)
        let low = (points.map(\.bpm).min() ?? 60) - 5
        Card(title: "Heart rate") {
            Chart(points, id: \.minutes) { point in
                AreaMark(
                    x: .value("Minutes", point.minutes),
                    yStart: .value("Min", low),
                    yEnd: .value("BPM", point.bpm)
                )
                .foregroundStyle(LinearGradient(colors: [.red.opacity(0.35), .red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Minutes", point.minutes), y: .value("BPM", point.bpm))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel("min")
            .frame(height: 180)
        }
    }
}

// MARK: - Route

private struct RouteMap: View {
    var route: [RoutePoint]
    var zones: HeartRateZones
    var heartRate: [TimedValue]

    @State private var isExpanded = false

    var body: some View {
        Card(title: "Route") {
            map(interactive: false)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 12))
                .onTapGesture { isExpanded = true }
            HStack {
                Text("\(route.count) GPS points · colored by heart rate zone")
                Spacer()
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { isExpanded = true }
                    .labelStyle(.iconOnly)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isExpanded) {
            NavigationStack {
                map(interactive: true)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Route")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Done") { isExpanded = false }
                    }
            }
        }
    }

    private func map(interactive: Bool) -> some View {
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(Color.heartRateZone(segment.zone), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = route.first {
                Marker("Start", systemImage: "play.fill", coordinate: first.coordinate).tint(.green)
            }
            if let first = route.first, let last = route.last, last.distance(to: first) > 50 {
                Marker("Finish", systemImage: "flag.checkered", coordinate: last.coordinate).tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// Consecutive stretches of the route in the same heart-rate zone (nil when there's no reading nearby).
    private var segments: [(zone: Int?, coordinates: [CLLocationCoordinate2D])] {
        var segments: [(zone: Int?, coordinates: [CLLocationCoordinate2D])] = []
        var hrIndex = 0
        for point in route {
            while hrIndex + 1 < heartRate.count, heartRate[hrIndex + 1].date <= point.date { hrIndex += 1 }
            let reading = heartRate.indices.contains(hrIndex) ? heartRate[hrIndex] : nil
            let zone = reading.flatMap { abs($0.date.timeIntervalSince(point.date)) <= WorkoutDetail.maxHeartRateGapSeconds ? zones.index(for: $0.value) : nil }
            if let last = segments.last, last.zone == zone {
                segments[segments.count - 1].coordinates.append(point.coordinate)
            } else {
                // Start each segment at the previous one's last point so the line has no gaps.
                let previous = segments.last?.coordinates.last
                segments.append((zone, (previous.map { [$0] } ?? []) + [point.coordinate]))
            }
        }
        return segments
    }
}

private extension RoutePoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

private struct ZoneBreakdown: View {
    var seconds: [Double]
    var zones: HeartRateZones

    var body: some View {
        let total = max(seconds.reduce(0, +), 1)
        Card(title: "Time in heart rate zones") {
            ForEach(Array(seconds.enumerated()).reversed(), id: \.offset) { index, value in
                HStack(spacing: 8) {
                    Text("Z\(index + 1)").font(.caption.bold()).frame(width: 24, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.heartRateZone(index).gradient)
                            .frame(width: max(2, proxy.size.width * value / total))
                    }
                    .frame(height: 14)
                    Text(WorkoutFormat.duration(value)).font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
                    Text("\(Int((value / total * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
            Text(zones.summary + ". Change them in Settings to match your watch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Splits

private struct SplitsCard: View {
    var splits: [Split]
    var decoupling: Double?

    var body: some View {
        let paces = splits.map(\.paceSecondsPerKm)
        let fastest = paces.min() ?? 0
        let slowest = paces.max() ?? 1
        Card(title: "Splits") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("km").gridColumnAlignment(.trailing)
                    Text("Pace")
                    Text("")
                    Text("HR").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(splits) { split in
                    GridRow {
                        Text(split.distanceKm < 0.99 ? Format.number(split.distanceKm, digits: 2) : "\(split.index)")
                            .font(.caption.bold())
                        Text(WorkoutFormat.pace(split.paceSecondsPerKm)).monospacedDigit()
                        GeometryReader { proxy in
                            // Faster splits get longer bars.
                            let range = max(slowest - fastest, 1)
                            let share = 0.35 + 0.65 * (slowest - split.paceSecondsPerKm) / range
                            RoundedRectangle(cornerRadius: 3)
                                .fill(split.paceSecondsPerKm == fastest ? Color.orange.gradient : Color.accentColor.gradient)
                                .frame(width: proxy.size.width * share)
                        }
                        .frame(height: 12)
                        Text(split.averageHeartRate.map { "\(Int($0))" } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            if let decoupling {
                Divider()
                HStack {
                    Text("Aerobic decoupling")
                    Spacer()
                    Text("\(Format.number(decoupling, digits: 1))%")
                        .bold()
                        .foregroundStyle(decoupling < 5 ? .green : .orange)
                }
                .font(.subheadline)
                Text("How much your heart rate drifted relative to pace from the first to the second half. Under 5% on a steady run means good aerobic endurance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Analysis

/// The coach review while Apple Intelligence is still writing it.
private struct RunAnalysisPreview: View {
    var analysis: RunAnalysis.PartiallyGenerated
    var showsEffort: Bool

    var body: some View {
        Card {
            if showsEffort, let effort = analysis.effort {
                StatusBadge(text: effort.rawValue.capitalized, color: effort.color)
            }
            if let headline = analysis.headline {
                Text(headline).font(.title3.bold())
            }
            ForEach(Array((analysis.summary ?? []).enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(point)
                }
                .font(.subheadline)
            }
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct RunAnalysisContent: View {
    var saved: SavedRunAnalysis
    /// Off for strength sessions, including reviews saved before they stopped getting a heart-rate effort.
    var showsEffort: Bool

    private var analysis: RunAnalysis { saved.analysis }
    private var effort: EffortLevel? { showsEffort ? analysis.effort : nil }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                GeneratedHeader(
                    status: effort?.rawValue.capitalized,
                    color: effort?.color ?? .secondary,
                    modelName: saved.modelName,
                    createdAt: saved.createdAt
                )
                Text(analysis.headline).font(.title3.bold())
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(analysis.summary, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(effort?.color ?? .secondary)
                            Text(point)
                        }
                    }
                }
                .font(.subheadline)
                if !analysis.planComparison.isEmpty {
                    Label(analysis.planComparison, systemImage: "calendar")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "What went well") {
                ForEach(Array(analysis.highlights.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.multicolor)
                }
            }
            Card(title: "Do differently") {
                ForEach(Array(analysis.improvements.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "arrow.up.right.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.primary, .orange)
                }
            }
            Card(title: "Recovery") {
                Text(analysis.recovery).font(.subheadline)
            }
            Card(title: "Next session") {
                Text(analysis.nextSession).font(.subheadline)
            }
        }
    }
}
