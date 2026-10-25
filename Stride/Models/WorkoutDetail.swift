import Foundation

nonisolated struct TimedValue: Hashable, Sendable {
    var date: Date
    var value: Double
}

nonisolated struct DistanceSample: Sendable {
    var start: Date
    var end: Date
    var meters: Double
}

/// A HealthKit quantity sample reduced to plain values, so workout processing can run on HealthKit data,
/// demo data, or an exported fixture alike.
nonisolated struct RawSample: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var value: Double
    var source: String
}

/// One GPS fix from a workout route.
nonisolated struct RoutePoint: Codable, Hashable, Sendable {
    var date: Date
    var latitude: Double
    var longitude: Double
    var altitudeM: Double?
    /// Horizontal accuracy radius in meters.
    var accuracyM: Double?

    /// Great-circle distance in meters.
    func distance(to other: RoutePoint) -> Double {
        let radians = Double.pi / 180
        let dLat = (other.latitude - latitude) * radians, dLon = (other.longitude - longitude) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * radians) * cos(other.latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(a)))
    }
}

/// Everything read from HealthKit for one workout, before any processing.
nonisolated struct RawWorkoutData: Codable, Sendable {
    var workoutID: UUID
    var start: Date
    var end: Date
    var source: String
    /// bpm, every source, overlapping the workout.
    var heartRate: [RawSample]
    /// Meters of walking/running distance, every source, overlapping the workout.
    var distance: [RawSample]
    var steps: [RawSample]
    var elevationGainM: Double?
    var temperatureC: Double?
    var humidityPercent: Double?
    var isIndoor: Bool?
    var powerW: Double?
    var cyclingCadence: Double?
    var strideLengthM: Double?
    var verticalOscillationCm: Double?
    var groundContactMs: Double?
    /// GPS fixes; nil in fixtures exported before routes were read.
    var route: [RoutePoint]?
}

/// A full export of what the app reads, for replaying someone's real data in the Simulator.
nonisolated struct HealthFixture: Codable, Sendable {
    var exportedAt: Date
    var snapshot: HealthSnapshot
    var workouts: [RawWorkoutData]
}

nonisolated struct Split: Hashable, Identifiable, Sendable {
    /// 1-based kilometer number.
    var index: Int
    /// 1.0 except for a final partial split.
    var distanceKm: Double
    var start: Date
    var duration: TimeInterval
    var averageHeartRate: Double?

    var id: Int { index }
    var paceSecondsPerKm: Double { duration / distanceKm }
}

/// Everything Apple Health has about one workout, loaded on demand when it's opened.
nonisolated struct WorkoutDetail: Sendable {
    var summary: WorkoutSummary
    var end: Date
    var heartRate: [TimedValue]
    var splits: [Split]
    var elevationGainM: Double?
    var temperatureC: Double?
    var humidityPercent: Double?
    var isIndoor: Bool?
    var cadence: Double?
    var powerW: Double?
    var strideLengthM: Double?
    var verticalOscillationCm: Double?
    var groundContactMs: Double?
    /// GPS fixes inside the workout window, empty when no route was shared.
    var route: [RoutePoint] = []
    /// Typical gap between heart-rate readings, in seconds.
    var heartRateIntervalSeconds: Double?
    /// Data-quality caveats to show the athlete and pass to the AI.
    var dataNotes: [String] = []

    var averagePaceSecondsPerKm: Double? {
        guard let km = summary.distanceKm, km > 0 else { return nil }
        return summary.durationMinutes * 60 / km
    }

    /// Seconds in each of the five heart-rate zones.
    func zoneSeconds(zones: HeartRateZones) -> [Double] {
        var seconds = Array(repeating: 0.0, count: 5)
        for (index, sample) in heartRate.enumerated() {
            let next = index + 1 < heartRate.count ? heartRate[index + 1].date : end
            // Cap gaps so a sparse series or a pause doesn't credit one reading with minutes of time.
            let gap = min(max(next.timeIntervalSince(sample.date), 0), 300)
            seconds[zones.index(for: sample.value)] += gap
        }
        return seconds
    }

    /// Pace:HR decoupling between the first and second half, in percent. Below ~5% on a steady run
    /// suggests good aerobic endurance. Not meaningful for intervals.
    var decouplingPercent: Double? {
        guard summary.durationMinutes >= 30, splits.count >= 4 else { return nil }
        let half = splits.count / 2
        func efficiency(_ splits: ArraySlice<Split>) -> Double? {
            let time = splits.map(\.duration).reduce(0, +)
            let distance = splits.map(\.distanceKm).reduce(0, +)
            var weightedHR = 0.0
            for split in splits {
                guard let hr = split.averageHeartRate else { return nil }
                weightedHR += hr * split.duration
            }
            guard time > 0, weightedHR > 0 else { return nil }
            return (distance / time) / (weightedHR / time)
        }
        guard let first = efficiency(splits[..<half]), let second = efficiency(splits[half...]), first > 0 else { return nil }
        return (first - second) / first * 100
    }

    /// Average heart rate per block of `minutes`, for spotting intervals in the trace.
    func heartRateBlocks(minutes: Double) -> [Double?] {
        let blockLength = minutes * 60
        let count = max(1, Int((end.timeIntervalSince(summary.start) / blockLength).rounded(.up)))
        var sums = Array(repeating: 0.0, count: count)
        var counts = Array(repeating: 0, count: count)
        for sample in heartRate {
            let block = Int(sample.date.timeIntervalSince(summary.start) / blockLength)
            guard (0..<count).contains(block) else { continue }
            sums[block] += sample.value
            counts[block] += 1
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : nil }
    }

    /// Turns raw samples into splits, cadence and zones, refusing to derive numbers from data that's too coarse.
    static func build(summary: WorkoutSummary, raw: RawWorkoutData) -> WorkoutDetail {
        let window = DateInterval(start: raw.start, end: max(raw.end, raw.start))
        var notes: [String] = []

        // Prefer the workout's own source (e.g. Garmin) so phone and watch data aren't mixed or double counted.
        func preferred(_ samples: [RawSample]) -> [RawSample] {
            let own = samples.filter { $0.source == raw.source }
            return (own.isEmpty ? samples : own).sorted { $0.start < $1.start }
        }
        /// Cuts samples to the workout window, prorating values of samples that stick out.
        func clipped(_ samples: [RawSample]) -> [RawSample] {
            samples.compactMap { sample in
                let length = sample.end.timeIntervalSince(sample.start)
                guard length > 0 else { return window.contains(sample.start) ? sample : nil }
                let start = max(sample.start, window.start), end = min(sample.end, window.end)
                guard end > start else { return nil }
                return RawSample(start: start, end: end, value: sample.value * end.timeIntervalSince(start) / length, source: sample.source)
            }
        }
        func medianDuration(_ samples: [RawSample]) -> Double? {
            MetricsReport.median(samples.map { $0.end.timeIntervalSince($0.start) })
        }

        let heartRate = preferred(raw.heartRate)
            .filter { window.contains($0.start) }
            .map { TimedValue(date: $0.start, value: $0.value) }
        let gaps = zip(heartRate.dropFirst(), heartRate).map { $0.date.timeIntervalSince($1.date) }
        let heartRateInterval = MetricsReport.median(gaps)
        if heartRate.isEmpty {
            notes.append("No heart-rate readings were shared for this workout.")
        } else if let heartRateInterval, heartRateInterval > 30 {
            notes.append("Heart rate was only recorded about every \(Int(heartRateInterval.rounded())) s, so the chart and zones are approximate.")
        }

        let route = (raw.route ?? [])
            .filter { window.contains($0.date) && ($0.accuracyM ?? 0) <= 50 }
            .sorted { $0.date < $1.date }

        var splits: [Split] = []
        if summary.isFootSport {
            let ownDistance = preferred(raw.distance)
            let distance = clipped(ownDistance)
            let covered = distance.map(\.value).reduce(0, +)
            let expected = (summary.distanceKm ?? 0) * 1000
            let isGranular = (medianDuration(ownDistance) ?? .infinity) <= 120 && distance.count >= 3
            let isConsistent = expected <= 0 || abs(covered - expected) / expected <= 0.15
            if isGranular && isConsistent {
                splits = Self.splits(
                    from: distance.map { DistanceSample(start: $0.start, end: $0.end, meters: $0.value) },
                    heartRate: heartRate,
                    workoutStart: raw.start
                )
            } else if let gps = Self.distanceSamples(route: route, expectedMeters: expected) {
                splits = Self.splits(from: gps, heartRate: heartRate, workoutStart: raw.start)
                notes.append("Km splits are computed from the GPS route, so they can differ slightly from your watch's.")
            } else if !ownDistance.isEmpty || expected > 0 {
                notes.append(isGranular
                    ? "Distance samples don't add up to the workout's distance, so km splits are hidden."
                    : "Distance was only shared in coarse chunks, so km splits aren't available.")
            }
        }

        var cadence: Double?
        if summary.isFootSport {
            let ownSteps = preferred(raw.steps)
            if (medianDuration(ownSteps) ?? .infinity) <= 120 {
                let perMinute = clipped(ownSteps).map(\.value).reduce(0, +) / max(window.duration / 60, 1)
                cadence = (90...230).contains(perMinute) ? perMinute : nil
            }
        } else {
            cadence = raw.cyclingCadence
        }

        return WorkoutDetail(
            summary: summary,
            end: raw.end,
            heartRate: heartRate,
            splits: splits,
            elevationGainM: raw.elevationGainM,
            temperatureC: raw.temperatureC,
            humidityPercent: raw.humidityPercent,
            isIndoor: raw.isIndoor,
            cadence: cadence,
            powerW: raw.powerW,
            strideLengthM: raw.strideLengthM,
            verticalOscillationCm: raw.verticalOscillationCm,
            groundContactMs: raw.groundContactMs,
            route: route,
            heartRateIntervalSeconds: heartRateInterval,
            dataNotes: notes
        )
    }

    /// Distance between consecutive GPS fixes, scaled to the workout's distance. Nil when the route is too
    /// sparse or its length doesn't match the workout's within 15%.
    static func distanceSamples(route: [RoutePoint], expectedMeters: Double) -> [DistanceSample]? {
        guard route.count >= 10 else { return nil }
        let gaps = zip(route.dropFirst(), route).map { $0.date.timeIntervalSince($1.date) }
        guard let gap = MetricsReport.median(gaps), gap <= 15 else { return nil }
        let samples = zip(route, route.dropFirst()).map { DistanceSample(start: $0.date, end: $1.date, meters: $0.distance(to: $1)) }
        let covered = samples.map(\.meters).reduce(0, +)
        guard covered > 0 else { return nil }
        guard expectedMeters > 0 else { return samples }
        guard abs(covered - expectedMeters) / expectedMeters <= 0.15 else { return nil }
        // Scale so split boundaries line up with the watch's total distance.
        let scale = expectedMeters / covered
        return samples.map { DistanceSample(start: $0.start, end: $0.end, meters: $0.meters * scale) }
    }

    /// Kilometer splits from distance samples, assuming constant speed within each sample.
    static func splits(from samples: [DistanceSample], heartRate: [TimedValue], workoutStart: Date) -> [Split] {
        var splits: [Split] = []
        var covered = 0.0
        var nextBoundary = 1000.0
        var splitStart = workoutStart
        var lastEnd = workoutStart

        func appendSplit(distance: Double, until end: Date) {
            let hr = heartRate.filter { $0.date >= splitStart && $0.date < end }.map(\.value)
            splits.append(Split(
                index: splits.count + 1,
                distanceKm: distance / 1000,
                start: splitStart,
                duration: end.timeIntervalSince(splitStart),
                averageHeartRate: hr.isEmpty ? nil : hr.reduce(0, +) / Double(hr.count)
            ))
            splitStart = end
        }

        for sample in samples.sorted(by: { $0.start < $1.start }) where sample.meters > 0 {
            let sampleDuration = sample.end.timeIntervalSince(sample.start)
            var used = 0.0
            while covered + (sample.meters - used) >= nextBoundary {
                used += nextBoundary - covered
                let crossing = sample.start.addingTimeInterval(sampleDuration * used / sample.meters)
                appendSplit(distance: 1000, until: crossing)
                covered = nextBoundary
                nextBoundary += 1000
            }
            covered += sample.meters - used
            lastEnd = max(lastEnd, sample.end)
        }

        let remainder = covered - (nextBoundary - 1000)
        if remainder >= 50 {
            appendSplit(distance: remainder, until: lastEnd)
        }
        return splits
    }
}

nonisolated extension WorkoutSummary {
    var isFootSport: Bool { ["Running", "Walking", "Hiking"].contains(sport) }
}

nonisolated enum WorkoutFormat {
    /// "5:12" for seconds per km.
    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else { return "–" }
        let total = Int(secondsPerKm.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// "47:12" or "1:47:12".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
            : "\(minutes):\(String(format: "%02d", secs))"
    }
}
