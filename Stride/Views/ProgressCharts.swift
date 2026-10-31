import Charts
import SwiftUI

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
        Card(title: "Level history") {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        } content: {
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

struct TrendCard: View {
    var progress: ProgressReport
    var granularity: ProgressGranularity
    @Binding var metric: ProgressMetric

    private var buckets: [(start: Date, value: Double?)] { progress.buckets(metric, granularity: granularity) }

    /// The best period for metrics where one direction is better.
    private func best(of buckets: [(start: Date, value: Double?)]) -> (start: Date, value: Double)? {
        guard let higherIsBetter = metric.higherIsBetter else { return nil }
        let measured = buckets.compactMap { bucket in bucket.value.map { (start: bucket.start, value: $0) } }
        return measured.max { higherIsBetter ? $0.value < $1.value : $0.value > $1.value }
    }

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
                            .referenceLine()
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
                    if let best = best(of: buckets) {
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

struct ComparisonCard: View {
    var progress: ProgressReport
    var granularity: ProgressGranularity
    @Binding var selected: ProgressMetric

    var body: some View {
        Card(title: "\(granularity.currentTitle) vs \(granularity.previousTitle)") {
            Text("So far, against the same days of \(granularity.previousTitle). Tap a row to chart it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DividedForEach(data: progress.comparisons(granularity: granularity)) { comparison in
                let metric = comparison.metric
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
