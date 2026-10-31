import SwiftUI

/// A date shown in a sheet (a day to edit or to find a time for).
struct PlanDate: Identifiable {
    var date: Date
    var id: Date { date }
}

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PlanDate?
    @State private var picking: PlanDate?
    @State private var editsWeek = false

    /// Today and the next 7 days, so the last day of a plan that starts tomorrow is shown too.
    private var dates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        PlanSummary(dates: Array(dates.prefix(7)))
                        if !model.schedule.isActive {
                            ScheduleIntroCard()
                        } else if let error = model.schedule.weatherError {
                            Label(error, systemImage: "cloud.slash")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(dates, id: \.self) { date in
                            PlanDayCard(
                                date: date,
                                onEdit: { editing = PlanDate(date: date) },
                                onPickTime: { picking = PlanDate(date: date) }
                            )
                        }
                        if model.latestAnalysis == nil {
                            Text("Run an analysis on the AI Coach tab for a 7-day plan built around your data, or plan days yourself: tap a day.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let adherence = model.planAdherence, !adherence.completed.isEmpty {
                            AdherenceList(days: adherence.completed).id("adherence")
                        }
                        WeatherAttributionView()
                    }
                    .padding()
                }
                .task {
                    #if DEBUG
                    // -scrollTo adherence and -planSheet week | edit:<day> | time:<day> (see AppModel+Debug).
                    if let target = UserDefaults.standard.string(forKey: "scrollTo") {
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo(target, anchor: .top)
                    }
                    if let sheet = UserDefaults.standard.string(forKey: "planSheet") {
                        let parts = sheet.split(separator: ":").map(String.init)
                        let date = dates[min(max(Int(parts.last ?? "") ?? 0, 0), dates.count - 1)]
                        switch parts.first {
                        case "week": editsWeek = true
                        case "edit": editing = PlanDate(date: date)
                        case "time": picking = PlanDate(date: date)
                        default: break
                        }
                    }
                    #endif
                }
            }
            .navigationTitle("This Week")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Plan week", systemImage: "square.and.pencil") { editsWeek = true }
                }
            }
            .sheet(item: $editing) { PlanDayEditor(date: $0.date, initial: model.plannedSession(on: $0.date)) }
            .sheet(item: $picking) { SlotPickerView(date: $0.date) }
            .sheet(isPresented: $editsWeek) {
                WeekPlanEditor(dates: Array(dates.prefix(7)), initial: dates.prefix(7).map(model.plannedSession(on:)))
            }
            .task { await model.schedule.refresh() }
            .refreshable { await model.schedule.refresh(forceWeather: true) }
        }
    }
}

/// Hours and sessions for the next 7 days, and the rules they break.
private struct PlanSummary: View {
    @Environment(AppModel.self) private var model
    var dates: [Date]

    var body: some View {
        let days = dates.map { model.plannedSession(on: $0) }
        let minutes = days.compactMap(\.self).map(\.durationMinutes).reduce(0, +)
        let sessions = days.compactMap(\.self).filter { !$0.isRest }.count
        let problems = WeekPlanEditor.problems(days: days, dates: dates, profile: model.profile)
        VStack(alignment: .leading, spacing: 6) {
            Text("Next 7 days: \(Format.hours(Double(minutes) / 60)) over ^[\(sessions) session](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Offers calendar and weather suggestions until they're on.
private struct ScheduleIntroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let schedule = model.schedule
        Card {
            Label("Find times for your sessions", systemImage: "calendar.badge.clock").font(.headline)
            Text("Stride can look for free time in your calendar, check the forecast, and suggest when to train. Sessions you pick go into your calendar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if schedule.calendarAccess == .denied {
                Text("Calendar access is off. Allow full access in Settings → Apps → Stride → Calendars.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Button("Use my calendar", systemImage: "calendar") {
                    Task { await schedule.enable() }
                }
                .buttonStyle(.borderedProminent)
                .font(.subheadline)
            }
        }
    }
}

/// One day: the session (tap to edit) and when to do it.
private struct PlanDayCard: View {
    @Environment(AppModel.self) private var model
    var date: Date
    var onEdit: () -> Void
    var onPickTime: () -> Void

    var body: some View {
        let day = model.plannedSession(on: date)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(day?.intensity.color ?? Color.secondary.opacity(0.3))
                        .frame(width: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(PlanDayCard.title(for: date)).font(.caption.bold()).foregroundStyle(.secondary)
                            if model.isAthletePlanned(on: date) {
                                Text("Your plan").font(.caption2.bold()).foregroundStyle(.blue)
                            }
                            Spacer()
                            if let day { StatusBadge(text: day.intensity.rawValue.capitalized, color: day.intensity.color) }
                        }
                        if let day {
                            PlannedDayContent(day: day)
                        } else {
                            Text("Nothing planned").font(.headline).foregroundStyle(.secondary)
                            Text("Tap to plan this day").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this day")
            if let schedule = model.schedule.schedule(on: date) {
                Divider()
                SessionTimeLine(schedule: schedule, onMore: onPickTime)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// "Today", "Tomorrow", or "Thursday 30 Oct".
    static func title(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return Format.day(date)
    }
}

/// Session title, length, zone and details.
private struct PlannedDayContent: View {
    var day: PlannedDay

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(day.session).font(.headline)
            if day.durationMinutes > 0 {
                Text("\(day.durationMinutes) min").font(.subheadline).foregroundStyle(.secondary)
            }
            if day.targetZone > 0 {
                Text("Z\(day.targetZone)")
                    .font(.caption.bold())
                    .foregroundStyle(Color.heartRateZone(day.targetZone - 1))
            }
        }
        if !day.details.isEmpty {
            Text(day.details).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

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

/// Where the forecast comes from. Open-Meteo asks for credit, and Apple requires its mark next to WeatherKit data.
private struct WeatherAttributionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let schedule = model.schedule
        if schedule.isActive, let forecast = schedule.forecast {
            VStack(alignment: .leading, spacing: 4) {
                if schedule.isDemo {
                    Text("Demo calendar and forecast")
                } else if forecast.source == .apple, let attribution = schedule.appleAttribution {
                    HStack(spacing: 8) {
                        AsyncImage(url: colorScheme == .dark ? attribution.darkMark : attribution.mark) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text("Apple Weather")
                        }
                        .frame(height: 12)
                        Link("Data sources", destination: attribution.legal)
                    }
                } else {
                    Link(OpenMeteo.attribution, destination: OpenMeteo.attributionURL)
                }
                if let place = forecast.placeName, !schedule.isDemo {
                    Text("Forecast for \(place)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A saved analysis's plan, for past analyses.
struct WeekPlanList: View {
    var analysis: SavedAnalysis

    private var totalMinutes: Int { analysis.report.weekPlan.map(\.durationMinutes).reduce(0, +) }
    private var sessionCount: Int { analysis.report.weekPlan.filter { $0.intensity != .rest }.count }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("From \(analysis.planStartDate.formatted(date: .abbreviated, time: .omitted)): \(Format.hours(Double(totalMinutes) / 60)) over ^[\(sessionCount) session](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(Array(analysis.report.weekPlan.enumerated()), id: \.offset) { _, day in
                PlannedDayRow(day: day)
            }
        }
    }
}

private struct PlannedDayRow: View {
    var day: PlannedDay

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(day.intensity.color)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(day.day).font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(text: day.intensity.rawValue.capitalized, color: day.intensity.color)
                }
                PlannedDayContent(day: day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// How the days of earlier plans went, newest first.
private struct AdherenceList: View {
    var days: [PlanAdherence.Day]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How last week went").font(.headline)
                Spacer()
                Text(PlanAdherence.summary(of: days)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            ForEach(days.reversed()) { day in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: day.status.systemImage)
                        .foregroundStyle(day.status.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday().day().month())).font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text(day.status.title).font(.caption).foregroundStyle(day.status.color)
                        }
                        Text(day.planned.isRest ? "Rest" : "\(day.planned.session), \(day.planned.durationMinutes) min").font(.subheadline)
                        if !day.workouts.isEmpty {
                            Text("Did: " + day.workouts.map(\.sportAndMinutes).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(day.notes, id: \.self) { note in
                            Text(note.prefix(1).capitalized + note.dropFirst()).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if day.id != days.first?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension PlanAdherence.Status {
    var color: Color {
        switch self {
        case .done, .rested: .green
        case .modified: .orange
        case .missed: .red
        case .extra: .purple
        case .pending: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .rested: "moon.zzz.fill"
        case .modified: "arrow.triangle.swap"
        case .missed: "xmark.circle.fill"
        case .extra: "plus.circle.fill"
        case .pending: "clock"
        }
    }
}
