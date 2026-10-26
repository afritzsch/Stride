import Charts
import SwiftUI

/// One skill up close: what it stands for, where its XP comes from, recent numbers, history and how to level it up.
struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    var skill: Skill
    @AppStorage("progressGranularity") private var granularity = ProgressGranularity.week

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let progress = model.progress {
                    header(progress)
                    LevelHistoryCard(progress: progress, skill: skill)
                    Card(title: "What it means") {
                        Text(skill.meaning).font(.subheadline)
                    }
                    Card(title: "How it's tracked") {
                        Label(skill.rule, systemImage: "star.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(skill.color)
                        Text(skill.tracking(profile: model.profile))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Card(title: "Last 4 weeks") {
                        ForEach(progress.recentStats(skill, profile: model.profile), id: \.label) { stat in
                            HStack {
                                Text(stat.label).font(.subheadline)
                                Spacer()
                                Text(stat.value).font(.subheadline.bold()).monospacedDigit()
                            }
                        }
                    }
                    history(progress)
                    Card(title: "How to level up") {
                        ForEach(skill.tips, id: \.self) { tip in
                            Label(tip, systemImage: "arrow.up.circle.fill")
                                .font(.subheadline)
                                .labelStyle(TipLabelStyle(tint: skill.color))
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(skill.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ progress: ProgressReport) -> some View {
        let level = progress.skills[skill] ?? LevelProgress(xp: 0, base: LevelProgress.skillBase)
        return Card {
            HStack(spacing: 16) {
                LevelRing(level: level.level, fraction: level.fraction, tint: skill.color, size: 84, lineWidth: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Label(skill.title, systemImage: skill.systemImage)
                        .font(.title2.bold())
                        .foregroundStyle(skill.color)
                    Text("\(Format.number(level.xp)) XP").font(.subheadline).monospacedDigit()
                    Text("\(Format.number(level.xpToNext)) XP to level \(level.level + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("+\(Format.number(progress.skillXP(skill, in: .week))) this week · +\(Format.number(progress.skillXP(skill, in: .month))) this month")
                        .font(.caption.bold())
                        .foregroundStyle(skill.color)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func history(_ progress: ProgressReport) -> some View {
        let buckets = progress.skillBuckets(skill, granularity: granularity)
        let values = buckets.compactMap(\.value)
        return Card(title: "XP earned") {
            Picker("Period", selection: $granularity) {
                ForEach(ProgressGranularity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(buckets, id: \.start) { bucket in
                    BarMark(x: .value("Period", bucket.start, unit: granularity.component), y: .value("XP", bucket.value ?? 0))
                        .foregroundStyle(skill.color.gradient)
                        .cornerRadius(3)
                }
                if let average = MetricsReport.mean(values) {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine()
                    AxisValueLabel(format: granularity.axisFormat)
                }
            }
            .frame(height: 180)
            Text("Avg \(Format.number(MetricsReport.mean(values))) XP per \(granularity.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TipLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
