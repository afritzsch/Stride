import Charts
import SwiftUI

struct Card<Content: View, Accessory: View>: View {
    var title: String?
    /// Shows a chevron next to the title, for cards wrapped in a NavigationLink.
    var isLink = false
    var accessory: Accessory
    var content: Content

    init(title: String? = nil, isLink: Bool = false, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isLink = isLink
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    if Accessory.self != EmptyView.self || isLink {
                        Spacer()
                    }
                    accessory
                    if isLink { LinkChevron() }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, isLink: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, isLink: isLink, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// The padded, rounded background shared by all cards.
    func cardBackground() -> some View {
        padding().background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

struct ErrorCard: View {
    var message: String

    var body: some View {
        Card { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
    }
}

/// Run button with progress, blocker, notice and error lines, for the weekly analysis and workout reviews.
struct AnalyzeControls: View {
    @Environment(AppModel.self) private var model
    var isRunning: Bool
    var runningText: String
    var buttonTitle: String
    var isDisabled = false
    var notice: String?
    var error: String?
    var action: () -> Void

    var body: some View {
        if isRunning {
            HStack(spacing: 12) {
                ProgressView()
                Text(runningText).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Button(action: action) {
                Label(buttonTitle, systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled || model.aiBlocker != nil)
        }
        if let blocker = model.aiBlocker {
            Text(blocker).font(.footnote).foregroundStyle(.orange)
        }
        if let notice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
    }
}

struct LinkChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var caption: String?
    var systemImage: String
    var tint: Color = .accentColor
    var isLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                if isLink {
                    Spacer(minLength: 4)
                    LinkChevron()
                }
            }
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .cardBackground()
    }
}

struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}

/// A status badge and which model wrote it when, the top line of a saved analysis or workout review.
struct GeneratedHeader: View {
    /// Nil leaves out the badge (strength reviews have no effort).
    var status: String?
    var color: Color
    var modelName: String
    var createdAt: Date

    var body: some View {
        HStack {
            if let status {
                StatusBadge(text: status, color: color)
            }
            Spacer()
            Text("\(modelName) · \(createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum Format {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func hours(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        let minutes = Int((value * 60).rounded())
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    static func delta(_ current: Double?, _ baseline: Double?, unit: String, digits: Int = 0) -> String? {
        guard let current, let baseline else { return nil }
        // Round before choosing the sign, so a tiny drop shows "+0", not "−0".
        let factor = pow(10, Double(digits))
        let diff = ((current - baseline) * factor).rounded() / factor
        let sign = diff < 0 ? "−" : "+"
        return "\(sign)\(abs(diff).formatted(.number.precision(.fractionLength(digits))))\(unit) vs 4-wk avg"
    }

    /// "Thursday 30 Oct", for day screens and sheets.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month())
    }
}

nonisolated extension PlannedDay {
    /// "45 min · Z2"; the zone only when there's a target.
    var durationAndZone: String {
        "\(durationMinutes) min" + (targetZone > 0 ? " · Z\(targetZone)" : "")
    }
}

nonisolated extension WorkoutSummary {
    /// "Running 42 min".
    var sportAndMinutes: String {
        "\(sport) \(Int(durationMinutes.rounded())) min"
    }
}

/// A grid of small caption/value pairs inside a card, for the stats of a workout or strength summary.
struct StatGrid: View {
    var stats: [(title: String, value: String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(stats, id: \.title) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.title).font(.caption).foregroundStyle(.secondary)
                    Text(stat.value).font(.headline).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .cardBackground()
    }
}

/// Rows with a divider between them, for lists inside a card.
struct DividedForEach<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    var data: Data
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        ForEach(data) { item in
            row(item)
            if item.id != data.last?.id { Divider() }
        }
    }
}

extension ChartContent {
    /// The dashed grey line for a target, average or baseline.
    func referenceLine() -> some ChartContent {
        lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.secondary)
    }
}

extension View {
    /// Date labels every two weeks, for charts with one bar per week.
    func biweeklyDateAxis() -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
    }
}
