import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.needsHealthAuthorization {
                        ConnectHealthCard()
                    }
                    if let error = model.healthError {
                        Card { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
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
                            IndicatorGrid(metrics: metrics, profile: model.profile)
                            WeeklyLoadChart(weeks: metrics.weeks)
                            SleepChart(nights: Array(snapshot.sleep.suffix(28)), target: model.profile.sleepTargetHours)
                            RecoveryChart(days: Array(snapshot.days.suffix(28)))
                            RecentWorkouts(workouts: Array(snapshot.workouts.suffix(8).reversed()), metrics: metrics)
                        }
                    } else if model.isLoadingHealth {
                        ProgressView("Reading Apple Health…").padding(.top, 60)
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .refreshable { await model.refresh() }
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
            Text("Apple Health has no workouts, sleep, or heart rate for the last 8 weeks. Check that your watch's app is syncing to Apple Health, and that this app has read access under Settings → Health → Data Access & Devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct IndicatorGrid: View {
    var metrics: MetricsReport
    var profile: UserProfile

    private var ind: TrainingIndicators { metrics.indicators }

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
                tint: (ind.sleep7 ?? 0) >= profile.sleepTargetHours - 0.25 ? .indigo : .orange
            )
            MetricTile(
                title: "Resting HR",
                value: "\(Format.number(ind.restingHR7)) bpm",
                caption: Format.delta(ind.restingHR7, ind.restingHR28, unit: " bpm"),
                systemImage: "heart.fill",
                tint: .red
            )
            MetricTile(
                title: "HRV",
                value: "\(Format.number(ind.hrv7)) ms",
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
                    .foregroundStyle(night.asleepHours >= target - 0.25 ? Color.indigo.gradient : Color.orange.gradient)
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

private struct RecentWorkouts: View {
    var workouts: [WorkoutSummary]
    var metrics: MetricsReport

    var body: some View {
        Card(title: "Recent workouts") {
            if workouts.isEmpty {
                Text("No workouts in the last 8 weeks.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(workouts) { workout in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.sport).font(.subheadline.bold())
                        Text(workout.start.formatted(.dateTime.weekday().day().month()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text([
                            "\(Int(workout.durationMinutes)) min",
                            workout.distanceKm.map { "\(Format.number($0, digits: 1)) km" },
                            workout.averageHeartRate.map { "\(Int($0)) bpm" },
                        ].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        Text("Load \(Format.number(metrics.workoutLoad[workout.id]))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                if workout.id != workouts.last?.id { Divider() }
            }
        }
    }
}
