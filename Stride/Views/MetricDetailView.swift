import Charts
import SwiftUI

/// A dashboard indicator with its own detail screen.
enum DashboardMetric: String, Hashable, CaseIterable {
    case load, acwr, sleep, restingHR, hrv, steps, weight

    var title: String {
        switch self {
        case .load: "Training load"
        case .acwr: "Load ratio"
        case .sleep: "Sleep"
        case .restingHR: "Resting heart rate"
        case .hrv: "Heart rate variability"
        case .steps: "Steps"
        case .weight: "Weight"
        }
    }
}

/// How the acute:chronic ratio reads, for the dashboard tile and the detail screen.
struct LoadRatio {
    var value: Double

    init(_ value: Double) { self.value = value }

    var summary: String {
        switch value {
        case ..<0.8: "Lighter than usual"
        case ...1.3: "In your usual range"
        case ...1.5: "Ramping up fast"
        default: "Load spike"
        }
    }

    var color: Color {
        switch value {
        case ..<0.8: .orange
        case ...1.3: .green
        case ...1.5: .orange
        default: .red
        }
    }
}

struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    var metric: DashboardMetric

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let snapshot = model.snapshot, let metrics = model.metrics {
                    switch metric {
                    case .load: LoadDetail(snapshot: snapshot, metrics: metrics)
                    case .acwr: LoadRatioDetail(metrics: metrics)
                    case .sleep: SleepDetail(snapshot: snapshot, indicators: metrics.indicators, target: model.profile.sleepTargetHours)
                    case .restingHR: RestingHRDetail(snapshot: snapshot, indicators: metrics.indicators)
                    case .hrv: HRVDetail(snapshot: snapshot, indicators: metrics.indicators)
                    case .steps: StepsDetail(snapshot: snapshot, indicators: metrics.indicators, target: model.profile.dailyStepTarget)
                    case .weight: WeightDetail(snapshot: snapshot, indicators: metrics.indicators)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared pieces

struct ExplanationCard: View {
    var paragraphs: [String]

    var body: some View {
        Card(title: "What it means") {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(LocalizedStringKey(paragraph))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label/value rows; rows with a nil value are left out.
struct StatsCard: View {
    var rows: [(String, String?)]

    var body: some View {
        Card {
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { label, value in
                LabeledContent(label, value: value ?? "")
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
    }
}

/// One line per day with a value, with an optional dashed baseline.
struct DailyLineChart: View {
    var title: String
    var points: [DatedValue]
    var color: Color
    var baseline: Double?
    var baselineLabel = "4-wk avg"

    var body: some View {
        Card(title: title) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(color)
                    PointMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(color)
                        .symbolSize(12)
                }
                if let baseline {
                    RuleMark(y: .value(baselineLabel, baseline))
                        .referenceLine()
                        .annotation(position: .top, alignment: .leading) {
                            Text(baselineLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 180)
        }
    }
}

extension HealthSnapshot {
    /// Start of the window covering the last `days` days, today included.
    func start(ofLast days: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: fetchedAt)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }

    func points(_ value: (DailyMetrics) -> Double?) -> [DatedValue] {
        days.compactMap { day in value(day).map { DatedValue(date: day.date, value: $0) } }
    }
}
