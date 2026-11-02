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
                            MetricLink(metric: .load) { WeeklyLoadChart(weeks: metrics.weeks, isLink: true) }
                            MetricLink(metric: .sleep) {
                                SleepChart(nights: Array(snapshot.sleep.suffix(28)), target: model.profile.sleepTargetHours, isLink: true)
                            }
                            MetricLink(metric: .restingHR) { RecoveryChart(days: Array(snapshot.days.suffix(28))) }
                            WeightCard(days: snapshot.days, indicators: metrics.indicators)
                            StrengthDashboardCard()
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
                case .metric(let metric): MetricDetailView(metric: metric)
                case .strength: StrengthView()
                case .strengthSession(let session): StrengthSessionView(session: session)
                case .healthLog: HealthLogView()
                }
            }
            .refreshable {
                await model.refresh()
                await model.strength.sync(force: true)
            }
            .task(id: model.snapshot?.fetchedAt) {
                await model.schedule.refresh()
                // Before reviews, so a new gym session is reviewed with its exercises.
                await model.strength.sync()
                // The athlete sees today's readiness and new workouts here, so they won't notify later.
                model.checkNotifications()
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

private struct MetricLink<Label: View>: View {
    var metric: DashboardMetric
    @ViewBuilder var label: Label

    var body: some View {
        NavigationLink(value: DashboardDestination.metric(metric)) { label }
            .buttonStyle(.plain)
    }
}

private struct IndicatorGrid: View {
    var metrics: MetricsReport
    var profile: UserProfile

    private var ind: TrainingIndicators { metrics.indicators }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricLink(metric: .load) {
                MetricTile(
                    title: "Load, 7 days",
                    value: Format.number(ind.acuteLoad),
                    caption: "4-wk avg \(Format.number(ind.chronicLoad)) / week",
                    systemImage: "flame.fill",
                    tint: .orange,
                    isLink: true
                )
            }
            MetricLink(metric: .acwr) {
                MetricTile(
                    title: "Load ratio",
                    value: Format.number(ind.acwr, digits: 2),
                    caption: ind.acwr.map { LoadRatio($0).summary } ?? "Needs 4 weeks of data",
                    systemImage: "gauge.with.dots.needle.50percent",
                    tint: ind.acwr.map { LoadRatio($0).color } ?? .gray,
                    isLink: true
                )
            }
            MetricLink(metric: .sleep) {
                MetricTile(
                    title: "Sleep, 7 days",
                    value: Format.hours(ind.sleep7),
                    caption: ind.bedtimeSDMinutes.map { "Bedtime varies ±\(Int($0)) min" },
                    systemImage: "bed.double.fill",
                    tint: ind.sleep7.map { SleepChart.isOnTarget($0, target: profile.sleepTargetHours) ? .indigo : .orange } ?? .gray,
                    isLink: true
                )
            }
            MetricLink(metric: .restingHR) {
                MetricTile(
                    title: "Resting HR",
                    value: ind.restingHR7.map { "\(Format.number($0)) bpm" } ?? "–",
                    caption: Format.delta(ind.restingHR7, ind.restingHR28, unit: " bpm"),
                    systemImage: "heart.fill",
                    tint: .red,
                    isLink: true
                )
            }
            MetricLink(metric: .hrv) {
                MetricTile(
                    title: "HRV",
                    value: ind.hrv7.map { "\(Format.number($0)) ms" } ?? "–",
                    caption: ind.hrv28 == nil ? "None in Apple Health" : Format.delta(ind.hrv7, ind.hrv28, unit: " ms"),
                    systemImage: "waveform.path.ecg",
                    tint: .pink,
                    isLink: true
                )
            }
            MetricLink(metric: .steps) {
                MetricTile(
                    title: "Steps, 7 days",
                    value: Format.number(ind.steps7),
                    caption: "Target \(profile.dailyStepTarget.formatted())",
                    systemImage: "shoeprints.fill",
                    tint: .green,
                    isLink: true
                )
            }
        }
    }
}

private struct RecentWorkouts: View {
    var workouts: [WorkoutSummary]

    var body: some View {
        Card(title: "Recent workouts") {
            NavigationLink("See all", value: DashboardDestination.allWorkouts)
                .font(.subheadline)
        } content: {
            if workouts.isEmpty {
                Text("No workouts in the last \(HealthKitService.windowWeeks) weeks.").font(.footnote).foregroundStyle(.secondary)
            }
            WorkoutLinkRows(workouts: workouts)
        }
    }
}
