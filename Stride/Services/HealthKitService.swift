import Foundation
import HealthKit

/// Reads training, sleep and recovery data from Apple Health, whichever watch or app wrote it.
nonisolated struct HealthKitService: Sendable {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
    }

    /// HealthKit never reveals whether read access was granted, only whether the prompt was shown.
    func needsAuthorizationPrompt() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status != .unnecessary
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchSnapshot(days: Int = 56, calendar: Calendar = .current) async throws -> HealthSnapshot {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            throw CocoaError(.featureUnsupported)
        }

        async let steps = dailyValues(.stepCount, unit: .count(), options: .cumulativeSum, from: start, to: now)
        async let energy = dailyValues(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, from: start, to: now)
        async let restingHR = dailyValues(.restingHeartRate, unit: Self.bpm, options: .discreteAverage, from: start, to: now)
        async let hrv = dailyValues(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), options: .discreteAverage, from: start, to: now)
        async let sleep = sleepNights(from: start.addingTimeInterval(-12 * 3600), to: now, calendar: calendar)
        async let workouts = workouts(from: start, to: now)

        let (stepsByDay, energyByDay, rhrByDay, hrvByDay) = await (steps, energy, restingHR, hrv)
        var dailyMetrics: [DailyMetrics] = []
        var day = start
        while day <= today {
            dailyMetrics.append(DailyMetrics(
                date: day,
                steps: stepsByDay[day],
                activeEnergyKcal: energyByDay[day],
                restingHeartRate: rhrByDay[day],
                hrvMs: hrvByDay[day]
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return HealthSnapshot(
            fetchedAt: now,
            days: dailyMetrics,
            sleep: try await sleep.filter { $0.date >= start },
            workouts: try await workouts,
            isDemo: false
        )
    }

    // MARK: - Daily quantities

    private func dailyValues(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async -> [Date: Double] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        // A type with no samples (or no permission) just yields an empty series.
        guard let collection = try? await descriptor.result(for: store) else { return [:] }
        var values: [Date: Double] = [:]
        for statistics in collection.statistics() {
            let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
            if let quantity {
                values[statistics.startDate] = quantity.doubleValue(for: unit)
            }
        }
        return values
    }

    // MARK: - Sleep

    private func sleepNights(from start: Date, to end: Date, calendar: Calendar) async throws -> [SleepNight] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)

        // Ignore daytime naps so they don't get merged into the night.
        let nightSamples = samples.filter {
            let hour = calendar.component(.hour, from: $0.startDate)
            return hour < 10 || hour >= 18
        }
        // Shift by 12h so a night that starts at 23:00 or 01:00 lands on the wake-up day.
        let nights = Dictionary(grouping: nightSamples) {
            calendar.startOfDay(for: $0.startDate.addingTimeInterval(12 * 3600))
        }

        let asleepValues = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        return nights.compactMap { date, samples -> SleepNight? in
            func intervals(_ values: [Int]) -> [DateInterval] {
                samples.filter { values.contains($0.value) }.map { DateInterval(start: $0.startDate, end: $0.endDate) }
            }
            var asleep = intervals(asleepValues)
            if asleep.isEmpty {
                // Some sources only write "in bed".
                asleep = intervals([HKCategoryValueSleepAnalysis.inBed.rawValue])
            }
            guard let bedtime = asleep.map(\.start).min(), let wake = asleep.map(\.end).max() else { return nil }

            // Union overlapping intervals so phone + watch data isn't double counted.
            let deep = Self.unionHours(intervals([HKCategoryValueSleepAnalysis.asleepDeep.rawValue]))
            let rem = Self.unionHours(intervals([HKCategoryValueSleepAnalysis.asleepREM.rawValue]))
            let awake = Self.unionHours(intervals([HKCategoryValueSleepAnalysis.awake.rawValue]))
            return SleepNight(
                date: date,
                bedtime: bedtime,
                wakeTime: wake,
                asleepHours: Self.unionHours(asleep),
                deepHours: deep > 0 ? deep : nil,
                remHours: rem > 0 ? rem : nil,
                awakeHours: awake > 0 ? awake : nil
            )
        }
        .filter { $0.asleepHours >= 1 }
        .sorted { $0.date < $1.date }
    }

    private static func unionHours(_ intervals: [DateInterval]) -> Double {
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                total += current?.duration ?? 0
                current = interval
            }
        }
        total += current?.duration ?? 0
        return total / 3600
    }

    // MARK: - Workouts

    private func workouts(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let workouts = try await descriptor.result(for: store)

        var summaries: [WorkoutSummary] = []
        for workout in workouts {
            let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
            let distance = distanceTypes
                .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) }
                .max()
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())

            var heartRate = workout.statistics(for: HKQuantityType(.heartRate))
            if heartRate?.averageQuantity() == nil {
                // Some apps don't attach heart rate to the workout; read the samples in its time range instead.
                heartRate = await heartRateStatistics(from: workout.startDate, to: workout.endDate)
            }

            summaries.append(WorkoutSummary(
                id: workout.uuid,
                start: workout.startDate,
                durationMinutes: workout.duration / 60,
                sport: workout.workoutActivityType.displayName,
                distanceKm: distance.flatMap { $0 > 0 ? $0 : nil },
                activeEnergyKcal: energy,
                averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: Self.bpm),
                maxHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: Self.bpm),
                sourceName: workout.sourceRevision.source.name
            ))
        }
        return summaries
    }

    private func heartRateStatistics(from start: Date, to end: Date) async -> HKStatistics? {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: [.discreteAverage, .discreteMax]
        )
        return try? await descriptor.result(for: store)
    }
}

nonisolated extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .hiking: "Hiking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair climbing"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .crossTraining: "Cross training"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .coreTraining: "Core"
        case .flexibility: "Mobility"
        case .downhillSkiing: "Skiing"
        case .crossCountrySkiing: "XC skiing"
        case .paddleSports: "Paddling"
        case .climbing: "Climbing"
        case .soccer: "Soccer"
        case .tennis: "Tennis"
        case .golf: "Golf"
        case .swimBikeRun: "Triathlon"
        default: "Other"
        }
    }
}
