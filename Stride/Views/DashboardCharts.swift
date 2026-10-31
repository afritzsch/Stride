import Charts
import SwiftUI

struct WeeklyLoadChart: View {
    var weeks: [WeeklySummary]
    var isLink = false

    var body: some View {
        Card(title: "Weekly training load", isLink: isLink) {
            Chart(weeks) { week in
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Load", week.load)
                )
                .foregroundStyle(.orange.gradient)
                .cornerRadius(4)
            }
            .biweeklyDateAxis()
            .frame(height: 180)
        }
    }
}

struct SleepChart: View {
    var title = "Sleep, last 4 weeks"
    var nights: [SleepNight]
    var target: Double
    var isLink = false

    /// Nights within this many hours of the sleep target count as on target.
    static func isOnTarget(_ hours: Double, target: Double) -> Bool { hours >= target - 0.25 }

    var body: some View {
        Card(title: title, isLink: isLink) {
            Chart {
                ForEach(nights) { night in
                    BarMark(
                        x: .value("Night", night.date, unit: .day),
                        y: .value("Hours", night.asleepHours)
                    )
                    .foregroundStyle(Self.isOnTarget(night.asleepHours, target: target) ? Color.indigo.gradient : Color.orange.gradient)
                }
                RuleMark(y: .value("Target", target))
                    .referenceLine()
                    .annotation(position: .top, alignment: .leading) {
                        Text("Target").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .frame(height: 180)
        }
    }
}

struct RecoveryChart: View {
    var days: [DailyMetrics]

    var body: some View {
        Card(title: "Resting HR & HRV", isLink: true) {
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

struct WeightCard: View {
    var days: [DailyMetrics]
    var indicators: TrainingIndicators
    @State private var isLogging = false

    var body: some View {
        Card(title: "Weight, \(HealthKitService.windowWeeks) weeks") {
            Button("Log", systemImage: "plus") { isLogging = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } content: {
            if indicators.latestWeightKg == nil {
                Text("No weigh-ins in the last \(HealthKitService.windowWeeks) weeks. Log one here, or connect a scale that writes to Apple Health.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink(value: DashboardDestination.metric(.weight)) {
                    WeightChart(days: days, indicators: indicators, isLink: true)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $isLogging) {
            WeightEntrySheet(initialKg: indicators.latestWeightKg)
        }
    }
}

/// Latest weigh-in, trend vs the 4-week average, and a line of the days with a weigh-in.
struct WeightChart: View {
    var days: [DailyMetrics]
    var indicators: TrainingIndicators
    var isLink = false

    private var weighIns: [DailyMetrics] { days.filter { $0.bodyMassKg != nil } }

    /// Pad the axis so day-to-day noise isn't stretched across the whole chart height.
    private var yDomain: ClosedRange<Double> {
        let values = weighIns.compactMap(\.bodyMassKg)
        let low = values.min() ?? 0, high = values.max() ?? 0
        let padding = max(1, (high - low) * 0.2)
        return (low - padding).rounded(.down)...(high + padding).rounded(.up)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                if isLink { LinkChevron() }
            }
            Chart(weighIns) { day in
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
