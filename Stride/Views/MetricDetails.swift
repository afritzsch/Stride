import Charts
import SwiftUI

// MARK: - Load

struct LoadDetail: View {
    var snapshot: HealthSnapshot
    var metrics: MetricsReport

    private var ind: TrainingIndicators { metrics.indicators }
    private var lastWeek: [WorkoutSummary] {
        let start = snapshot.start(ofLast: 7)
        return snapshot.workouts.filter { $0.start >= start }.reversed()
    }

    var body: some View {
        StatsCard(rows: [
            ("Last 7 days", Format.number(ind.acuteLoad)),
            ("Average week, last 4 weeks", Format.number(ind.chronicLoad)),
            ("Training days in a row", "\(ind.consecutiveTrainingDays)"),
            ("Monotony, last 7 days", ind.monotony.map { Format.number($0, digits: 1) }),
        ])
        Card(title: "Daily load, last 4 weeks") {
            Chart(snapshot.days.filter { $0.date >= snapshot.start(ofLast: 28) }) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Load", metrics.dailyLoad[day.date] ?? 0))
                    .foregroundStyle(.orange.gradient)
            }
            .frame(height: 180)
        }
        WeeklyLoadChart(weeks: metrics.weeks)
        Card(title: "Workouts, last 7 days") {
            if lastWeek.isEmpty {
                Text("No workouts in the last 7 days.").font(.footnote).foregroundStyle(.secondary)
            }
            WorkoutLinkRows(workouts: lastWeek)
        }
        ExplanationCard(paragraphs: [
            "Each workout gets a load score from how long it was and how hard your heart worked: its average heart rate between your resting and maximum heart rate (Banister's TRIMP). Hard minutes count much more than easy ones: an easy hour scores about 50, an hour near threshold 150 or more.",
            "Workouts without heart rate count as moderate effort.",
            "**Monotony** is the average daily load divided by how much it varies. Above 2 means most days are equally hard, with too few easy or rest days in between.",
        ])
    }
}

// MARK: - Load ratio

struct LoadRatioDetail: View {
    var metrics: MetricsReport

    private var ind: TrainingIndicators { metrics.indicators }

    private var yMax: Double {
        max(2, (metrics.acwrHistory.map(\.value).max() ?? 0) + 0.2)
    }

    var body: some View {
        Card {
            if let acwr = ind.acwr {
                let ratio = LoadRatio(acwr)
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.number(acwr, digits: 2)).font(.largeTitle.bold()).monospacedDigit()
                    StatusBadge(text: ratio.summary, color: ratio.color)
                }
                Text("\(Format.number(ind.acuteLoad)) load in the last 7 days ÷ \(Format.number(ind.chronicLoad)) in your average week over the last 4 weeks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not enough history yet. The ratio needs 4 weeks of synced data, otherwise the usual week looks too light and any training reads as a spike.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        if !metrics.acwrHistory.isEmpty {
            Card(title: "Load ratio over time") {
                Chart {
                    RectangleMark(yStart: .value("Low", 0.8), yEnd: .value("High", 1.3))
                        .foregroundStyle(.green.opacity(0.15))
                    ForEach(metrics.acwrHistory) { point in
                        LineMark(x: .value("Day", point.date, unit: .day), y: .value("Ratio", point.value))
                            .foregroundStyle(.primary)
                    }
                }
                .chartYScale(domain: 0...yMax)
                .frame(height: 180)
                Text("Shaded: 0.8–1.3, load in line with what you're used to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ExplanationCard(paragraphs: [
            "The acute:chronic load ratio compares what you did in the **last 7 days** with what your body is used to: your **average week over the last 4 weeks**. 1.0 means this week matches a usual week.",
            "**0.8–1.3:** you're training about as much as you're adapted to. Good for steady progress.",
            "**Above 1.3**, and especially above 1.5, the load is rising faster than your body has adapted to. That's linked to a higher risk of injury and illness. One big week is fine; follow it with easier days instead of building on it.",
            "**Below 0.8:** you're doing less than usual. Right for a recovery week or a taper; over several weeks fitness starts to drop.",
        ])
    }
}

// MARK: - Sleep

struct SleepDetail: View {
    var snapshot: HealthSnapshot
    var indicators: TrainingIndicators
    var target: Double

    private var lastWeek: [SleepNight] {
        let start = snapshot.start(ofLast: 7)
        return snapshot.sleep.filter { $0.date >= start }.reversed()
    }

    private var onTarget14: String? {
        let nights = snapshot.sleep.filter { $0.date >= snapshot.start(ofLast: 14) }
        guard !nights.isEmpty else { return nil }
        return "\(nights.filter { SleepChart.isOnTarget($0.asleepHours, target: target) }.count) of \(nights.count)"
    }

    var body: some View {
        StatsCard(rows: [
            ("Average, last 7 nights", Format.hours(indicators.sleep7)),
            ("Average, last 4 weeks", Format.hours(indicators.sleep28)),
            ("Target", Format.hours(target)),
            ("Nights on target, last 2 weeks", onTarget14),
            ("Bedtime variability", indicators.bedtimeSDMinutes.map { "±\(Int($0)) min" }),
        ])
        SleepChart(title: "Sleep, \(HealthKitService.windowWeeks) weeks", nights: snapshot.sleep, target: target)
        Card(title: "Last 7 nights") {
            if lastWeek.isEmpty {
                Text("No sleep in Apple Health for the last 7 nights.").font(.footnote).foregroundStyle(.secondary)
            }
            DividedForEach(data: lastWeek) { night in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(night.date, format: .dateTime.weekday().day().month()).font(.subheadline.bold())
                        Text("\(night.bedtime.formatted(date: .omitted, time: .shortened)) – \(night.wakeTime.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.hours(night.asleepHours)).font(.subheadline.bold()).monospacedDigit()
                        if let deep = night.deepHours, let rem = night.remHours {
                            Text("Deep \(Format.hours(deep)) · REM \(Format.hours(rem))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        ExplanationCard(paragraphs: [
            "Time asleep, not time in bed: time awake during the night isn't counted. Nights are dated by the morning you woke up, and daytime naps are left out.",
            "**Bedtime variability** is how much your bedtime moved around over the last 2 weeks (one standard deviation). Within ±30 min is consistent; more than ±60 min acts like mild jet lag and makes sleep less restorative, even when the hours add up.",
            "Change the sleep target in Settings.",
        ])
    }
}

// MARK: - Resting HR

struct RestingHRDetail: View {
    var snapshot: HealthSnapshot
    var indicators: TrainingIndicators

    var body: some View {
        StatsCard(rows: [
            ("Average, last 7 days", indicators.restingHR7.map { "\(Format.number($0)) bpm" }),
            ("Average, last 4 weeks", indicators.restingHR28.map { "\(Format.number($0)) bpm" }),
            ("Lowest, last 4 weeks", snapshot.days.filter { $0.date >= snapshot.start(ofLast: 28) }
                .compactMap(\.restingHeartRate).min().map { "\(Format.number($0)) bpm" }),
        ])
        DailyLineChart(
            title: "Resting HR, \(HealthKitService.windowWeeks) weeks",
            points: snapshot.points(\.restingHeartRate),
            color: .red,
            baseline: indicators.restingHR28
        )
        ExplanationCard(paragraphs: [
            "Your heart rate at complete rest, as measured by your watch (usually during sleep).",
            "Compare it with your own average, not with other people. **5 bpm or more above** your 4-week average for a few days often means fatigue, a coming illness, stress, alcohol or short sleep: a good time for an easy day. A slow drop over months usually means your aerobic fitness is improving.",
            "Stride also uses it to set your heart rate zones and to score training load.",
        ])
    }
}

// MARK: - HRV

struct HRVDetail: View {
    var snapshot: HealthSnapshot
    var indicators: TrainingIndicators

    var body: some View {
        if indicators.hrv28 == nil {
            Card(title: "No HRV data") {
                Text("Apple Health has no heart rate variability from the last 4 weeks. Not every watch app shares HRV with Apple Health, so with some watches this stays empty. Stride works without it and uses resting heart rate and sleep instead.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            StatsCard(rows: [
                ("Average, last 7 days", indicators.hrv7.map { "\(Format.number($0)) ms" }),
                ("Average, last 4 weeks", indicators.hrv28.map { "\(Format.number($0)) ms" }),
            ])
            DailyLineChart(
                title: "HRV, \(HealthKitService.windowWeeks) weeks",
                points: snapshot.points(\.hrvMs),
                color: .pink,
                baseline: indicators.hrv28
            )
        }
        ExplanationCard(paragraphs: [
            "Heart rate variability is how much the time between heartbeats varies (SDNN, in milliseconds). A rested body varies more; stress, hard training, illness, alcohol and poor sleep lower it.",
            "Values differ a lot between people, so only compare with your own average. A 7-day average clearly **below** your 4-week average suggests you're not fully recovered.",
        ])
    }
}

// MARK: - Steps

struct StepsDetail: View {
    var snapshot: HealthSnapshot
    var indicators: TrainingIndicators
    var target: Int

    private var onTarget28: String {
        let days = snapshot.days.filter { $0.date >= snapshot.start(ofLast: 28) }.compactMap(\.steps)
        return "\(days.filter { $0 >= Double(target) }.count) of \(days.count)"
    }

    var body: some View {
        StatsCard(rows: [
            ("Average, last 7 days", Format.number(indicators.steps7)),
            ("Average, last 4 weeks", Format.number(indicators.steps28)),
            ("Days on target, last 4 weeks", onTarget28),
        ])
        Card(title: "Steps, \(HealthKitService.windowWeeks) weeks") {
            Chart {
                ForEach(snapshot.days) { day in
                    if let steps = day.steps {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Steps", steps))
                            .foregroundStyle(steps >= Double(target) ? Color.green.gradient : Color.gray.gradient)
                    }
                }
                RuleMark(y: .value("Target", target))
                    .referenceLine()
                    .annotation(position: .top, alignment: .leading) {
                        Text("Target").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .frame(height: 180)
        }
        ExplanationCard(paragraphs: [
            "Daily steps from all your devices, including workouts. Today only counts the steps so far.",
            "Steps show your everyday activity outside training. On rest days, an easy walk helps recovery more than sitting still.",
            "Change the step target in Settings.",
        ])
    }
}

// MARK: - Weight

struct WeightDetail: View {
    var snapshot: HealthSnapshot
    var indicators: TrainingIndicators
    @State private var isLogging = false

    private var weighIns: [DailyMetrics] { snapshot.days.filter { $0.bodyMassKg != nil }.reversed() }

    var body: some View {
        Card {
            if indicators.latestWeightKg == nil {
                Text("No weigh-ins in the last \(HealthKitService.windowWeeks) weeks.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                WeightChart(days: snapshot.days, indicators: indicators)
            }
            Button {
                isLogging = true
            } label: {
                Label("Log weight", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        if !weighIns.isEmpty {
            Card(title: "Weigh-ins") {
                DividedForEach(data: weighIns) { day in
                    LabeledContent {
                        Text("\(Format.number(day.bodyMassKg, digits: 1)) kg").monospacedDigit()
                    } label: {
                        Text(day.date, format: .dateTime.weekday().day().month())
                    }
                    .font(.subheadline)
                }
            }
        }
        ExplanationCard(paragraphs: [
            "Weight from Apple Health: weigh-ins you log here, and those from smart scales or other apps. Several weigh-ins on one day are averaged.",
            "Day to day, weight swings by 0.5–1 kg with water, salt and carbohydrate stores, so look at the weekly trend. The AI coach sees it too, so it can take a weight goal or a fast drop into account.",
        ])
        .sheet(isPresented: $isLogging) {
            WeightEntrySheet(initialKg: indicators.latestWeightKg)
        }
    }
}
