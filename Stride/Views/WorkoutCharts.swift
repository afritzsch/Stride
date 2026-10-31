import Charts
import SwiftUI

struct HeartRateChart: View {
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

struct ZoneBreakdown: View {
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
                .accessibilityElement(children: .combine)
            }
            Text(zones.summary + ". Change them in Settings to match your watch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Splits

struct SplitsCard: View {
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
