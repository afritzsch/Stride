import Charts
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
                            RecordsCard(records: progress.records).id("records")
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

// MARK: - Level history

/// The level over time, for the athlete (nil skill) or one skill, with a marker at each new rank.
struct LevelHistoryCard: View {
    enum Range: String, CaseIterable, Identifiable {
        case halfYear = "6M", year = "1Y", all = "All"

        var id: String { rawValue }
        var months: Int? {
            switch self {
            case .halfYear: 6
            case .year: 12
            case .all: nil
            }
        }
    }

    var progress: ProgressReport
    var skill: Skill?
    @AppStorage("levelHistoryRange") private var range = Range.all

    private var tint: Color { skill?.color ?? .orange }

    var body: some View {
        let all = progress.levelHistory(skill)
        let cutoff = range.months.flatMap { Calendar.current.date(byAdding: .month, value: -$0, to: progress.lastDate) }
        let points = cutoff.map { cutoff in all.filter { $0.date >= cutoff } } ?? all
        Card {
            HStack {
                Text("Level history").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if let first = points.first, let last = points.last, points.count > 1 {
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(x: .value("Week", point.date, unit: .weekOfYear), y: .value("Level", point.level))
                            .foregroundStyle(tint.opacity(0.15).gradient)
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Week", point.date, unit: .weekOfYear), y: .value("Level", point.level))
                            .foregroundStyle(tint)
                            .interpolationMethod(.monotone)
                    }
                    if skill == nil {
                        ForEach(rankUps(points), id: \.date) { rank in
                            PointMark(x: .value("Week", rank.date, unit: .weekOfYear), y: .value("Level", rank.level))
                                .foregroundStyle(tint)
                                .symbolSize(50)
                                .annotation(position: .topLeading, spacing: 2) {
                                    Text(rank.title).font(.caption2.bold()).foregroundStyle(.secondary)
                                }
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: range == .all))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisValueLabel(format: range == .halfYear ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year(.twoDigits))
                    }
                }
                .frame(height: 180)
                let gained = Int(last.level) - Int(first.level)
                Text("Level \(Int(first.level)) → \(Int(last.level)): +\(gained) level\(gained == 1 ? "" : "s") since \(first.date.formatted(.dateTime.month(.abbreviated).year())).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Your level history appears after your first full week.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// The first week at each new rank (every 10 levels).
    private func rankUps(_ points: [(date: Date, level: Double)]) -> [(date: Date, level: Double, title: String)] {
        var result: [(Date, Double, String)] = []
        var previous = points.first.map { Int($0.level) / 10 } ?? 0
        for point in points.dropFirst() where Int(point.level) / 10 > previous {
            previous = Int(point.level) / 10
            result.append((point.date, point.level, LevelProgress.rankTitle(level: Int(point.level))))
        }
        return result
    }
}

// MARK: - Skills

private struct SkillsCard: View {
    var progress: ProgressReport
    @State private var showsRules = false

    var body: some View {
        Card(title: "Skills") {
            ForEach(Skill.allCases) { skill in
                let level = progress.skills[skill] ?? LevelProgress(xp: 0, base: LevelProgress.skillBase)
                NavigationLink(value: skill) {
                    HStack(spacing: 12) {
                        Image(systemName: skill.systemImage)
                            .foregroundStyle(skill.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(skill.title).font(.subheadline.bold())
                                Text("Lv \(level.level)").font(.subheadline).monospacedDigit().foregroundStyle(skill.color)
                                Spacer()
                                let week = progress.skillXP(skill, in: .week)
                                if week > 0 {
                                    Text("+\(Format.number(week)) this week").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: level.fraction).tint(skill.color)
                        }
                        LinkChevron()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            DisclosureGroup("How XP works", isExpanded: $showsRules) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Skill.allCases) { skill in
                        Text("**\(skill.title):** \(skill.rule)")
                    }
                    Text("Your athlete level adds up all skill XP. Each level takes a little more XP than the last, and XP never goes down.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Trend

/// Week, month or year, for the charts that bucket by period.
struct GranularityPicker: View {
    @Binding var selection: ProgressGranularity

    var body: some View {
        Picker("Period", selection: $selection) {
            ForEach(ProgressGranularity.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct TrendCard: View {
    var progress: ProgressReport
    var granularity: ProgressGranularity
    @Binding var metric: ProgressMetric

    private var buckets: [(start: Date, value: Double?)] { progress.buckets(metric, granularity: granularity) }

    var body: some View {
        let buckets = buckets
        let values = buckets.compactMap(\.value)
        Card {
            HStack {
                Menu {
                    Picker("Metric", selection: $metric) {
                        ForEach(ProgressMetric.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Label(metric.title, systemImage: metric.systemImage).font(.headline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                Spacer()
            }
            if values.isEmpty {
                Text("No \(metric.title.lowercased()) data in this range.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(buckets, id: \.start) { bucket in
                        if let value = bucket.value {
                            if metric.isSum {
                                BarMark(x: .value("Period", bucket.start, unit: granularity.component), y: .value(metric.title, value))
                                    .foregroundStyle(metric.color.gradient)
                                    .cornerRadius(3)
                            } else {
                                LineMark(x: .value("Period", bucket.start, unit: granularity.component), y: .value(metric.title, value))
                                    .foregroundStyle(metric.color)
                                    .interpolationMethod(.catmullRom)
                                PointMark(x: .value("Period", bucket.start, unit: granularity.component), y: .value(metric.title, value))
                                    .foregroundStyle(metric.color)
                                    .symbolSize(20)
                            }
                        }
                    }
                    if let average = MetricsReport.mean(values) {
                        RuleMark(y: .value("Average", average))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: metric.isSum))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisValueLabel(format: granularity.axisFormat)
                    }
                }
                .frame(height: 200)
                HStack {
                    if let higherIsBetter = metric.higherIsBetter,
                       let best = buckets.filter({ $0.value != nil }).max(by: { higherIsBetter ? $0.value! < $1.value! : $0.value! > $1.value! }) {
                        Text("Best: \(metric.format(best.value)) (\(best.start.formatted(granularity.axisFormat)))")
                    }
                    Spacer()
                    Text("Avg \(metric.format(MetricsReport.mean(values)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Comparison

private struct ComparisonCard: View {
    var progress: ProgressReport
    var granularity: ProgressGranularity
    @Binding var selected: ProgressMetric

    var body: some View {
        Card(title: "\(granularity.currentTitle) vs \(granularity.previousTitle)") {
            Text("So far, against the same days of \(granularity.previousTitle). Tap a row to chart it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(ProgressMetric.allCases) { metric in
                let comparison = progress.comparison(metric, granularity: granularity)
                Button {
                    selected = metric
                } label: {
                    HStack {
                        Image(systemName: metric.systemImage)
                            .foregroundStyle(metric.color)
                            .frame(width: 22)
                        Text(metric.title).font(.subheadline)
                        Spacer()
                        Text(metric.format(comparison.current)).font(.subheadline.bold()).monospacedDigit()
                        DeltaLabel(metric: metric, current: comparison.current, previous: comparison.previous)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(metric == selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                if metric != ProgressMetric.allCases.last { Divider() }
            }
        }
    }
}

private struct DeltaLabel: View {
    var metric: ProgressMetric
    var current: Double?
    var previous: Double?

    var body: some View {
        if let current, let previous {
            let diff = current - previous
            let text: String = if metric.isSum {
                // Percentages read better for totals; an empty previous period has no percentage.
                previous > 0 ? "\(diff < 0 ? "−" : "+")\(Format.number(abs(diff) / previous * 100))%" : current > 0 ? "new" : "±0"
            } else {
                "\(diff < 0 ? "−" : "+")\(Format.number(abs(diff), digits: metric.digits))"
            }
            Text(text)
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(color(diff))
        } else {
            Text("–").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func color(_ diff: Double) -> Color {
        guard let higherIsBetter = metric.higherIsBetter, abs(diff) > 1e-9 else { return .secondary }
        return (diff > 0) == higherIsBetter ? .green : .orange
    }
}

// MARK: - Records & achievements

private struct RecordsCard: View {
    var records: [PersonalRecord]

    var body: some View {
        Card(title: "Personal records") {
            if records.isEmpty {
                Text("Records appear once you've logged workouts.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                HStack {
                    Image(systemName: record.systemImage).foregroundStyle(.yellow).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.subheadline)
                        Text(record.date, format: .dateTime.day().month(.abbreviated).year()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.value).font(.subheadline.bold()).monospacedDigit()
                }
                if record.id != records.last?.id { Divider() }
            }
        }
    }
}

private struct AchievementsCard: View {
    var achievements: [Achievement]

    /// Unlocked first (newest first), then the locked ones closest to done.
    private var sorted: [Achievement] {
        achievements.filter(\.isUnlocked).sorted { $0.unlockedAt! > $1.unlockedAt! }
            + achievements.filter { !$0.isUnlocked }.sorted { $0.fraction > $1.fraction }
    }

    var body: some View {
        Card {
            HStack {
                Text("Achievements").font(.headline)
                Spacer()
                Text("\(achievements.filter(\.isUnlocked).count) / \(achievements.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(sorted) { AchievementBadge(achievement: $0) }
            }
        }
    }
}

private struct AchievementBadge: View {
    var achievement: Achievement

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: achievement.systemImage)
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(achievement.isUnlocked ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(.fill.tertiary), in: .circle)
                .foregroundStyle(achievement.isUnlocked ? .black : .secondary)
            Text(achievement.title)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let date = achievement.unlockedAt {
                Text(date, format: .dateTime.month(.abbreviated).year(.twoDigits)).font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView(value: achievement.fraction).tint(.yellow)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(achievement.isUnlocked ? 1 : 0.75)
        .accessibilityElement(children: .combine)
        .accessibilityHint(achievement.detail)
    }
}

// MARK: - Styling

extension Skill {
    var color: Color {
        switch self {
        case .endurance: .blue
        case .power: .red
        case .strength: .purple
        case .explorer: .green
        case .vitality: .mint
        case .rest: .indigo
        case .discipline: .orange
        }
    }
}

extension ProgressMetric {
    var color: Color {
        switch self {
        case .xp: .orange
        case .distance, .runDistance: .green
        case .trainingTime, .sessions: .blue
        case .load: .orange
        case .steps: .mint
        case .activeEnergy: .yellow
        case .sleep: .indigo
        case .restingHR: .red
        case .hrv: .pink
        case .weight: .teal
        }
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "–" }
        switch self {
        case .trainingTime, .sleep: return Format.hours(value)
        case .sessions: return Format.number(value)
        default: return "\(Format.number(value, digits: digits)) \(unit)"
        }
    }
}

extension ProgressGranularity {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .week: .dateTime.day().month(.abbreviated)
        case .month: .dateTime.month(.abbreviated).year(.twoDigits)
        case .year: .dateTime.year()
        }
    }
}
