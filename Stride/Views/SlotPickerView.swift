import SwiftUI

/// Times for one day's session: the suggestions, a time of the athlete's choosing, and the day's calendar.
struct SlotPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var date: Date
    @State private var customStart: Date?
    @State private var error: String?

    var body: some View {
        let schedule = model.schedule
        NavigationStack {
            List {
                if let day = schedule.schedule(on: date) {
                    content(day, schedule: schedule)
                } else {
                    ContentUnavailableView(
                        "No session to schedule",
                        systemImage: "calendar",
                        description: Text(schedule.isActive ? "Nothing is planned for this day." : "Turn on time suggestions on the Plan tab or in Settings.")
                    )
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(date.formatted(.dateTime.weekday(.wide).day().month()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func content(_ day: DaySchedule, schedule: ScheduleModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.session.session).font(.headline)
                Text(day.session.briefDescription).font(.footnote).foregroundStyle(.secondary)
            }
        }

        if let scheduled = day.scheduled {
            Section("In your calendar") {
                Label(SlotFormat.range(scheduled.start, scheduled.end), systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(.green)
                Button("Remove from calendar", systemImage: "calendar.badge.minus", role: .destructive) {
                    perform { try schedule.removeSession(on: day.date) }
                }
            }
        }

        Section {
            if day.slots.isEmpty {
                Text(day.note ?? "No free time.").foregroundStyle(.secondary)
            }
            ForEach(day.slots) { slot in
                Button {
                    perform { try schedule.add(day.session, on: day.date, at: slot.start) }
                } label: {
                    SlotRow(slot: slot, isBest: slot == day.best, action: day.scheduled == nil ? "Add" : "Move here")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Suggested times")
        } footer: {
            Text("Ranked by free time, weather, daylight and when you usually train. \(SessionScheduler.isOutdoor(day.session.sport) ? "" : "\(day.session.sport) is indoors, so the weather doesn't count.")")
        }

        Section("Another time") {
            let start = Binding(
                get: { customStart ?? day.best?.start ?? Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day.date) ?? day.date },
                set: { customStart = $0 }
            )
            DatePicker("Start", selection: start, displayedComponents: .hourAndMinute)
            let end = start.wrappedValue.addingTimeInterval(TimeInterval(max(day.session.durationMinutes, 15) * 60))
            if let clash = schedule.busy.first(where: { !$0.isSession && $0.start < end && $0.end > start.wrappedValue }) {
                Label("Overlaps \(clash.title.isEmpty ? "an event" : clash.title) (\(SlotFormat.range(clash.start, clash.end)))", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Add at \(start.wrappedValue.formatted(date: .omitted, time: .shortened))", systemImage: "calendar.badge.plus") {
                perform { try schedule.add(day.session, on: day.date, at: start.wrappedValue) }
            }
        }

        let events = schedule.busy.filter { Calendar.current.isDate($0.start, inSameDayAs: day.date) && !$0.isSession }
        if !events.isEmpty {
            Section("Your calendar that day") {
                ForEach(events, id: \.self) { event in
                    LabeledContent(event.title.isEmpty ? "Busy" : event.title, value: SlotFormat.range(event.start, event.end))
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SlotRow: View {
    var slot: SlotSuggestion
    var isBest: Bool
    var action: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: slot.weather?.systemImage ?? "clock")
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(SlotFormat.range(slot.start, slot.end)).font(.headline)
                    if isBest { StatusBadge(text: "Best", color: .green) }
                }
                if let weather = slot.weather {
                    Text(weather.summary + (weather.windKph >= 20 ? ", wind \(Int(weather.windKph.rounded())) km/h" : ""))
                        .font(.subheadline)
                }
                ForEach(slot.reasons, id: \.self) { Label($0, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                ForEach(slot.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Text(action).font(.subheadline.bold()).foregroundStyle(.tint)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
