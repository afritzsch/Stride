import SwiftUI

/// Long-term progress, RPG style: an athlete level, skill levels, every metric by week/month/year, records and achievements.
struct ProgressOverviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("progressGranularity") private var granularity = ProgressGranularity.week
    @AppStorage("progressMetric") private var metric = ProgressMetric.distance

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.progressPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if let progress = model.progress {
                            if model.isLoadingArchive {
                                Label("Reading your full Apple Health history…", systemImage: "hourglass")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            LevelCard(progress: progress)
                            LevelHistoryCard(progress: progress, skill: nil)
                            SkillsCard(progress: progress)
                            GranularityPicker(selection: $granularity)
                            TrendCard(progress: progress, granularity: granularity, metric: $metric).id("trend")
                            ComparisonCard(progress: progress, granularity: granularity, selected: $metric).id("compare")
                            PersonalRecordsCard(records: progress.records).id("records")
                            AchievementsCard(achievements: progress.achievements).id("achievements")
                        } else if model.isLoadingHealth {
                            ProgressView("Reading Apple Health…").padding(.top, 60)
                        } else {
                            ContentUnavailableView("No data yet", systemImage: "trophy", description: Text("Connect Apple Health on the Dashboard to start levelling up."))
                        }
                    }
                    .padding()
                }
                .task(id: model.progress == nil) {
                    // Debug launch hook (-scrollTo trend | compare | records | achievements).
                    guard model.progress != nil, let target = model.consumeLaunchHooks().scrollTarget else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .navigationTitle("Progress")
            .navigationDestination(for: Skill.self) { SkillDetailView(skill: $0) }
            .refreshable {
                await model.refresh()
                await model.refreshArchive(force: true)
            }
        }
    }
}

// MARK: - Level

private struct LevelCard: View {
    var progress: ProgressReport

    private var level: LevelProgress { progress.athlete }

    var body: some View {
        Card {
            HStack(spacing: 16) {
                LevelRing(level: level.level, fraction: level.fraction, tint: .orange, size: 84, lineWidth: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(level.title).font(.title2.bold())
                    Text("\(Format.number(level.xp)) XP")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("\(Format.number(level.xpToNext)) XP to level \(level.level + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("+\(Format.number(progress.skillXP(nil, in: .week))) this week · +\(Format.number(progress.skillXP(nil, in: .month))) this month")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                LifetimeStat(value: progress.totalWorkouts.formatted(), label: "workouts")
                LifetimeStat(value: Format.number(progress.totalHours), label: "hours")
                LifetimeStat(value: Format.number(progress.totalKm), label: "km")
                LifetimeStat(value: "\(progress.currentWeekStreak)", label: "week streak", systemImage: "flame.fill")
            }
            if let first = progress.firstDate {
                Text("Since \(first.formatted(.dateTime.month(.wide).year())). Streak weeks have \(ProgressReport.activeWeekDays)+ training days; best \(progress.longestWeekStreak).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LifetimeStat: View {
    var value: String
    var label: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.orange) }
                Text(value).font(.headline).monospacedDigit()
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LevelRing: View {
    var level: Int
    var fraction: Double
    var tint: Color
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("LV").font(.system(size: size * 0.14, weight: .bold)).foregroundStyle(.secondary)
                Text("\(level)").font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level), \(Int(fraction * 100)) percent to the next")
    }
}
