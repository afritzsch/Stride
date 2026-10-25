import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var caption: String?
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
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
        .padding()
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
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
        let diff = current - baseline
        let sign = diff >= 0 ? "+" : "−"
        return "\(sign)\(abs(diff).formatted(.number.precision(.fractionLength(digits))))\(unit) vs 4-wk avg"
    }
}
