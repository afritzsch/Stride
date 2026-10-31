import SwiftUI

/// The session's time: in the calendar already, the best free time with an add button, or why there's none.
struct SessionTimeLine: View {
    @Environment(AppModel.self) private var model
    var schedule: DaySchedule
    var onMore: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let scheduled = schedule.scheduled {
                    Label("In your calendar \(SlotFormat.range(scheduled.start, scheduled.end))", systemImage: "calendar.badge.checkmark")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Change", action: onMore)
                } else if let best = schedule.best {
                    Image(systemName: best.weather?.systemImage ?? "clock")
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Best time: \(SlotFormat.range(best.start, best.end))").bold()
                        Text(SlotFormat.detail(best)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Add", systemImage: "calendar.badge.plus") {
                        do {
                            try model.schedule.add(schedule.session, on: schedule.date, at: best.start)
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Add to calendar at \(SlotFormat.range(best.start, best.end))")
                    Button("Other times", systemImage: "ellipsis.circle", action: onMore)
                        .labelStyle(.iconOnly)
                } else {
                    Label(schedule.note ?? "No free time", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pick a time", action: onMore)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.subheadline)
    }
}

enum SlotFormat {
    static func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /// "9 °C, dry · Your usual time · After sunset (16:50)".
    static func detail(_ slot: SlotSuggestion) -> String {
        ([slot.weather?.summary].compactMap(\.self) + slot.reasons + slot.warnings).joined(separator: " · ")
    }
}
