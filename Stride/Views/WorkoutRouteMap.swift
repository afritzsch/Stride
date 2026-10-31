import MapKit
import SwiftUI

struct RouteMap: View {
    var route: [RoutePoint]
    var zones: HeartRateZones
    var heartRate: [TimedValue]

    private typealias Segment = (zone: Int?, coordinates: [CLLocationCoordinate2D])

    @State private var isExpanded = false

    var body: some View {
        let segments = segments
        Card(title: "Route") {
            map(interactive: false, segments: segments)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 12))
                .onTapGesture { isExpanded = true }
                .accessibilityHidden(true)
            HStack {
                Text("\(route.count) GPS points · colored by heart rate zone")
                Spacer()
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { isExpanded = true }
                    .labelStyle(.iconOnly)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isExpanded) {
            NavigationStack {
                map(interactive: true, segments: segments)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Route")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Done") { isExpanded = false }
                    }
            }
        }
    }

    private func map(interactive: Bool, segments: [Segment]) -> some View {
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(Color.heartRateZone(segment.zone), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = route.first {
                Marker("Start", systemImage: "play.fill", coordinate: first.coordinate).tint(.green)
            }
            if let first = route.first, let last = route.last, last.distance(to: first) > 50 {
                Marker("Finish", systemImage: "flag.checkered", coordinate: last.coordinate).tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// Consecutive stretches of the route in the same heart-rate zone (nil when there's no reading nearby).
    private var segments: [Segment] {
        var segments: [Segment] = []
        var hrIndex = 0
        for point in route {
            while hrIndex + 1 < heartRate.count, heartRate[hrIndex + 1].date <= point.date { hrIndex += 1 }
            let reading = heartRate.indices.contains(hrIndex) ? heartRate[hrIndex] : nil
            let zone = reading.flatMap { abs($0.date.timeIntervalSince(point.date)) <= WorkoutDetail.maxHeartRateGapSeconds ? zones.index(for: $0.value) : nil }
            if let last = segments.last, last.zone == zone {
                segments[segments.count - 1].coordinates.append(point.coordinate)
            } else {
                // Start each segment at the previous one's last point so the line has no gaps.
                let previous = segments.last?.coordinates.last
                segments.append((zone, (previous.map { [$0] } ?? []) + [point.coordinate]))
            }
        }
        return segments
    }
}

private extension RoutePoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
