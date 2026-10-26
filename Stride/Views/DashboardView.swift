import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.dashboardPath) {
            ScrollView {
                VStack(spacing: 16) {
                    if model.needsHealthAuthorization {
                        ConnectHealthCard()
                    }
                    if let error = model.healthError {
                        ErrorCard(message: error)
                    }
                    if let snapshot = model.snapshot, let metrics = model.metrics {
                        if snapshot.isDemo {
                            Label("Showing demo data. Turn it off in Settings to use your Apple Health data.", systemImage: "wand.and.stars")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if snapshot.isEmpty {
                            NoDataCard()
                        } else {
                            TodayCard()
                            IndicatorGrid(metrics: metrics, profile: model.profile)
                            WeeklyLoadChart(weeks: metrics.weeks)
                            SleepChart(nights: Array(snapshot.sleep.suffix(28)), target: model.profile.sleepTargetHours)
                            RecoveryChart(days: Array(snapshot.days.suffix(28)))
                            if metrics.indicators.latestWeightKg != nil {
                                WeightChart(days: snapshot.days.filter { $0.bodyMassKg != nil }, indicators: metrics.indicators)
                            }
                            RecentWorkouts(workouts: Array(snapshot.workouts.suffix(8).reversed()))
                        }
                    } else if model.isLoadingHealth {
                        ProgressView("Reading Apple Health…").padding(.top, 60)
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .navigationDestination(for: DashboardDestination.self) { destination in
                switch destination {
                case .allWorkouts: WorkoutListView()
                case .workout(let workout): WorkoutDetailView(workout: workout)
                }
            }
            .refreshable { await model.refresh() }
            .task(id: model.snapshot?.fetchedAt) {
                await model.adjustTodayIfNeeded(automatically: true)
                await model.reviewNewWorkouts()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isLoadingHealth)
                }
            }
        }
    }
}

private struct ConnectHealthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Connect Apple Health") {
            Text("Stride reads your workouts, sleep, and heart rate from Apple Health. Apple Watch writes there automatically. Other watches need their app to sync:")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. In your watch's app, turn on Apple Health sync. In **Garmin Connect**, for example: More → Settings → Connected Apps → **Apple Health**.")
                Text("2. Make sure activities, sleep, heart rate, and steps are shared.")
                Text("3. Tap the button below and allow read access.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button {
                Task { await model.connectHealth() }
            } label: {
                Label("Connect Apple Health", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct NoDataCard: View {
    var body: some View {
        Card(title: "No data yet") {
            Text("Apple Health has no workouts, sleep, or heart rate for the last \(HealthKitService.windowWeeks) weeks. Check that your watch's app is syncing to Apple Health, and that this app has read access under Settings → Health → Data Access & Devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Today's planned session next to this morning's recovery signals, with a lighter version when they're off.
private struct TodayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let readiness = model.readiness
        Card {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                if let readiness, readiness.level != .unknown {
                    StatusBadge(text: readiness.level.title, color: readiness.level.color)
                }
            }
            if let readiness, !readiness.signals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(readiness.signals, id: \.self) { signal in
                        Label(signal.text, systemImage: signal.isStrong ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                            .foregroundStyle(signal.isStrong ? .orange : .secondary)
                    }
                }
                .font(.footnote)
            }

            if !model.todaysWorkouts.isEmpty {
                Label("Done: " + model.todaysWorkouts.map { "\($0.sport) \(Int($0.durationMinutes.rounded())) min" }.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                ForEach(model.todaysWorkouts) { workout in
                    if let review = model.runAnalyses[workout.id] {
                        NavigationLink(value: DashboardDestination.workout(workout)) {
                            Label(review.analysis.headline, systemImage: "sparkles").font(.footnote)
                        }
                    } else if model.analyzingWorkoutIDs.contains(workout.id) {
                        Label("Reviewing your \(workout.sport.lowercased())…", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let planned = model.todaysPlan {
                PlannedLine(day: planned, prefix: "Planned")
                adjustment(for: planned, readiness: readiness)
            } else {
                Text("No session planned for today. Run an analysis on the AI Coach tab to get a plan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func adjustment(for planned: PlannedDay, readiness: Readiness?) -> some View {
        if let saved = model.todayAdjustment, Calendar.current.isDateInToday(saved.date) {
            switch saved.state {
            case .suggested:
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    PlannedLine(day: saved.adjustment.session, prefix: "Suggested")
                    Text(saved.adjustment.reason).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Use this") { model.resolveTodayAdjustment(accept: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Keep plan") { model.resolveTodayAdjustment(accept: false) }
                            .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                }
            case .accepted:
                Label("Adjusted for how you recovered", systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
            case .declined:
                EmptyView()
            }
        } else if model.isAdjustingToday {
            HStack(spacing: 8) {
                ProgressView()
                Text("Adjusting today's session…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if !planned.isRest, readiness?.suggestsAdjusting == true {
            Button("Adjust for today", systemImage: "wand.and.stars") {
                Task { await model.adjustTodayIfNeeded(automatically: false) }
            }
            .font(.subheadline)
            .disabled(model.aiBlocker != nil)
            if let error = model.adjustmentError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

private struct PlannedLine: View {
    var day: PlannedDay
    var prefix: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(day.intensity.color).frame(width: 8, height: 8)
            Text("\(Text("\(prefix):").foregroundStyle(.secondary)) \(Text(day.isRest ? "Rest" : day.session).bold())")
            Spacer()
            if day.durationMinutes > 0 {
                Text("\(day.durationMinutes) min" + (day.targetZone > 0 ? " · Z\(day.targetZone)" : ""))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }
}

extension Readiness.Level {
    var color: Color {
        switch self {
        case .unknown: .gray
        case .good: .green
        case .caution: .yellow
        case .low: .orange
        }
    }
}

private struct IndicatorGrid: View {
    var metrics: MetricsReport
    var profile: UserProfile

    private var ind: TrainingIndicators { metrics.indicators }
    /// Nights within this many hours of the sleep target count as on target.
    static let sleepTolerance = 0.25

    private var acwrTint: Color {
        guard let acwr = ind.acwr else { return .gray }
        switch acwr {
        case ..<0.8: return .orange
        case ...1.3: return .green
        default: return .red
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricTile(
                title: "Load, 7 days",
                value: Format.number(ind.acuteLoad),
                caption: "4-wk avg \(Format.number(ind.chronicLoad)) / week",
                systemImage: "flame.fill",
                tint: .orange
            )
            MetricTile(
                title: "Acute:chronic",
                value: Format.number(ind.acwr, digits: 2),
                caption: "Sweet spot 0.8–1.3",
                systemImage: "gauge.with.dots.needle.50percent",
                tint: acwrTint
            )
            MetricTile(
                title: "Sleep, 7 days",
                value: Format.hours(ind.sleep7),
                caption: ind.bedtimeSDMinutes.map { "Bedtime varies ±\(Int($0)) min" },
                systemImage: "bed.double.fill",
                tint: ind.sleep7.map { $0 >= profile.sleepTargetHours - Self.sleepTolerance ? .indigo : .orange } ?? .gray
            )
            MetricTile(
                title: "Resting HR",
                value: ind.restingHR7.map { "\(Format.number($0)) bpm" } ?? "–",
                caption: Format.delta(ind.restingHR7, ind.restingHR28, unit: " bpm"),
                systemImage: "heart.fill",
                tint: .red
            )
            MetricTile(
                title: "HRV",
                value: ind.hrv7.map { "\(Format.number($0)) ms" } ?? "–",
                caption: Format.delta(ind.hrv7, ind.hrv28, unit: " ms"),
                systemImage: "waveform.path.ecg",
                tint: .pink
            )
            MetricTile(
                title: "Steps, 7 days",
                value: Format.number(ind.steps7),
                caption: "Target \(profile.dailyStepTarget.formatted())",
                systemImage: "shoeprints.fill",
                tint: .green
            )
        }
    }
}

private struct WeeklyLoadChart: View {
    var weeks: [WeeklySummary]

    var body: some View {
        Card(title: "Weekly training load") {
            Chart(weeks) { week in
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Load", week.load)
                )
                .foregroundStyle(.orange.gradient)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 180)
        }
    }
}

private struct SleepChart: View {
    var nights: [SleepNight]
    var target: Double

    var body: some View {
        Card(title: "Sleep, last 4 weeks") {
            Chart {
                ForEach(nights) { night in
                    BarMark(
                        x: .value("Night", night.date, unit: .day),
                        y: .value("Hours", night.asleepHours)
                    )
                    .foregroundStyle(night.asleepHours >= target - IndicatorGrid.sleepTolerance ? Color.indigo.gradient : Color.orange.gradient)
                }
                RuleMark(y: .value("Target", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Target").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .frame(height: 180)
        }
    }
}

private struct RecoveryChart: View {
    var days: [DailyMetrics]

    var body: some View {
        Card(title: "Resting HR & HRV") {
            Chart {
                ForEach(days) { day in
                    if let rhr = day.restingHeartRate {
                        LineMark(x: .value("Day", day.date, unit: .day), y: .value("Value", rhr))
                            .foregroundStyle(by: .value("Metric", "Resting HR (bpm)"))
                    }
                    if let hrv = day.hrvMs {
                        LineMark(x: .value("Day", day.date, unit: .day), y: .value("Value", hrv))
                            .foregroundStyle(by: .value("Metric", "HRV (ms)"))
                    }
                }
            }
            .chartForegroundStyleScale(["Resting HR (bpm)": Color.red, "HRV (ms)": Color.pink.opacity(0.6)])
            .chartLegend(position: .bottom)
            .frame(height: 180)
        }
    }
}

private struct WeightChart: View {
    var days: [DailyMetrics]
    var indicators: TrainingIndicators

    /// Pad the axis so day-to-day noise isn't stretched across the whole chart height.
    private var yDomain: ClosedRange<Double> {
        let values = days.compactMap(\.bodyMassKg)
        let low = values.min() ?? 0, high = values.max() ?? 0
        let padding = max(1, (high - low) * 0.2)
        return (low - padding).rounded(.down)...(high + padding).rounded(.up)
    }

    var body: some View {
        Card(title: "Weight, 8 weeks") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.number(indicators.latestWeightKg, digits: 1)) kg")
                    .font(.title2.bold())
                    .monospacedDigit()
                if let date = indicators.latestWeightDate {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let delta = Format.delta(indicators.weight7, indicators.weight28, unit: " kg", digits: 1) {
                    Text(delta).font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart(days) { day in
                if let kg = day.bodyMassKg {
                    LineMark(x: .value("Day", day.date, unit: .day), y: .value("Weight", kg))
                        .foregroundStyle(.teal)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Day", day.date, unit: .day), y: .value("Weight", kg))
                        .foregroundStyle(.teal)
                        .symbolSize(16)
                }
            }
            .chartYScale(domain: yDomain)
            .frame(height: 160)
        }
    }
}

private struct RecentWorkouts: View {
    var workouts: [WorkoutSummary]

    var body: some View {
        Card {
            HStack {
                Text("Recent workouts").font(.headline)
                Spacer()
                NavigationLink("See all", value: DashboardDestination.allWorkouts)
                    .font(.subheadline)
            }
            if workouts.isEmpty {
                Text("No workouts in the last \(HealthKitService.windowWeeks) weeks.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(workouts) { workout in
                NavigationLink(value: DashboardDestination.workout(workout)) {
                    HStack {
                        WorkoutRow(workout: workout)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                if workout.id != workouts.last?.id { Divider() }
            }
        }
    }
}
