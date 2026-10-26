import EventKit
import SwiftUI
import UIKit

/// Calendar and weather settings for time suggestions.
struct ScheduleSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var placeText = ""
    @State private var placeError: String?
    @State private var isFindingPlace = false

    var body: some View {
        @Bindable var schedule = model.schedule

        Section {
            Toggle("Suggest training times", isOn: Binding(
                get: { schedule.settings.suggestTimes && schedule.calendarAccess == .granted },
                set: { isOn in
                    if isOn {
                        Task { await schedule.enable() }
                    } else {
                        schedule.settings.suggestTimes = false
                    }
                }
            ))
            if schedule.calendarAccess == .denied {
                Text("Calendar access is off.").foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if schedule.settings.suggestTimes || schedule.isDemo {
                if schedule.calendarAccess == .granted {
                    Picker("Add sessions to", selection: $schedule.settings.calendarID) {
                        Text("Default calendar").tag(String?.none)
                        ForEach(schedule.calendar.writableCalendars(), id: \.calendarIdentifier) { calendar in
                            Text(calendar.title).tag(Optional(calendar.calendarIdentifier))
                        }
                    }
                }
                DatePicker("Earliest", selection: minutes($schedule.settings.earliestMinute), displayedComponents: .hourAndMinute)
                DatePicker("Latest", selection: minutes($schedule.settings.latestMinute), displayedComponents: .hourAndMinute)
                Stepper("Keep free around events: \(schedule.settings.bufferMinutes) min", value: $schedule.settings.bufferMinutes, in: 0...60, step: 5)
            }
        } header: {
            Text("Calendar")
        } footer: {
            if schedule.isDemo {
                Text("Demo data uses a made-up calendar and forecast, and sessions you add aren't written to your calendar.")
            } else {
                Text("Stride reads when you're busy from all your calendars (all-day and free events don't count) and only adds the sessions you pick. Your calendar stays on your iPhone.")
            }
        }

        Section {
            Picker("Forecast", selection: $schedule.settings.weatherSource) {
                ForEach(WeatherSource.allCases.filter { $0 != .apple || WeatherClient.isAppleWeatherInBuild }) { Text($0.title).tag($0) }
            }
            if !WeatherClient.isAppleWeatherInBuild {
                LabeledContent("Apple Weather", value: "Needs paid developer account")
            }
            if schedule.settings.weatherSource != .off {
                Picker("Location", selection: $schedule.settings.useCurrentLocation) {
                    Text("Current location").tag(true)
                    Text("A place").tag(false)
                }
                if !schedule.settings.useCurrentLocation {
                    HStack {
                        TextField(schedule.settings.place?.name ?? "City or area", text: $placeText)
                            .onSubmit(findPlace)
                            .submitLabel(.search)
                        if isFindingPlace {
                            ProgressView()
                        } else {
                            Button("Find", action: findPlace).disabled(placeText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let place = schedule.settings.place {
                        LabeledContent("Forecast for", value: place.name)
                    }
                    if let placeError {
                        Text(placeError).foregroundStyle(.red)
                    }
                }
                if let error = schedule.weatherError, !schedule.isDemo {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Weather")
        } footer: {
            switch schedule.settings.weatherSource {
            case .openMeteo:
                Text("Free forecast from Open-Meteo, without an account. Only your location, rounded to about 1 km, is sent.")
            case .apple:
                Text("Apple Weather (WeatherKit). Your location is sent to Apple for the forecast.")
            case .off:
                Text("Times are suggested from your calendar alone.")
            }
        }
    }

    /// A time-of-day binding over minutes after midnight.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return Binding(
            get: { today.addingTimeInterval(TimeInterval(value.wrappedValue * 60)) },
            set: { value.wrappedValue = calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
        )
    }

    private func findPlace() {
        let text = placeText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isFindingPlace = true
        Task {
            defer { isFindingPlace = false }
            do {
                model.schedule.settings.place = try await WeatherClient.findPlace(text)
                placeText = ""
                placeError = nil
            } catch {
                placeError = error.localizedDescription
            }
        }
    }
}
