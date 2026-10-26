import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    /// Shows a chevron next to the title, for cards wrapped in a NavigationLink.
    var isLink = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    if isLink {
                        Spacer()
                        LinkChevron()
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
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
            .disabled(isDisabled || model.engineBlocker != nil)
        }
        if let blocker = model.engineBlocker {
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

extension Color {
    /// Heart-rate zone colors, Z1 (index 0) to Z5; the accent color for nil (no reading).
    static func heartRateZone(_ index: Int?) -> Color {
        guard let index else { return .accentColor }
        return [.gray, .blue, .green, .orange, .red][min(max(index, 0), 4)]
    }
}

extension EffortLevel {
    var color: Color {
        switch self {
        case .recovery: .gray
        case .easy: .green
        case .moderate: .blue
        case .hard: .orange
        case .maximal: .red
        }
    }
}

extension TrainingStatus {
    var color: Color {
        switch self {
        case .productive: .green
        case .maintaining: .blue
        case .overreaching: .red
        case .recovering: .teal
        case .detraining: .orange
        case .insufficientData: .gray
        }
    }
}

extension InsightTone {
    var color: Color {
        switch self {
        case .positive: .green
        case .neutral: .blue
        case .warning: .orange
        }
    }

    var systemImage: String {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .neutral: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }
}

extension SessionIntensity {
    var color: Color {
        switch self {
        case .rest: .gray
        case .easy: .green
        case .moderate: .orange
        case .hard: .red
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
}
