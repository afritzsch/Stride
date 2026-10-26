import Foundation

/// A calendar event that blocks time. Events Stride added for a planned session carry that session's day.
nonisolated struct BusyInterval: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var title: String
    /// Start of the day of the planned session this event is for, if Stride added it.
    var sessionDate: Date?
    /// The calendar event's identifier, to move or remove a session Stride added.
    var eventID: String?

    var isSession: Bool { sessionDate != nil }
}

nonisolated enum SkyCondition: String, Codable, Sendable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, snow, sleet, thunderstorm

    var title: String {
        switch self {
        case .clear: "Clear"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .snow: "Snow"
        case .sleet: "Sleet"
        case .thunderstorm: "Thunderstorms"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow: "cloud.snow.fill"
        case .sleet: "cloud.sleet.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }

    /// Worse conditions rank higher, so a slot shows the worst hour it covers.
    var severity: Int {
        switch self {
        case .clear: 0
        case .partlyCloudy: 1
        case .cloudy: 2
        case .fog: 3
        case .drizzle: 4
        case .rain: 5
        case .snow: 6
        case .sleet: 7
        case .heavyRain: 8
        case .thunderstorm: 9
        }
    }

    /// WMO weather interpretation codes, as Open-Meteo reports them.
    static func wmo(_ code: Int) -> SkyCondition {
        switch code {
        case 0: .clear
        case 1, 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 51, 53, 55: .drizzle
        case 56, 57, 66, 67: .sleet
        case 61, 63, 80, 81: .rain
        case 65, 82: .heavyRain
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 99: .thunderstorm
        default: .cloudy
        }
    }
}

/// One hour of forecast, starting at `date`.
nonisolated struct HourlyWeather: Codable, Hashable, Sendable {
    var date: Date
    var temperatureC: Double
    var apparentTemperatureC: Double
    /// 0…1.
    var precipitationChance: Double
    var precipitationMm: Double
    var windKph: Double
    var uvIndex: Double
    var condition: SkyCondition
}

nonisolated struct SunTimes: Codable, Hashable, Sendable {
    /// Start of the local day.
    var date: Date
    var sunrise: Date
    var sunset: Date
}

nonisolated enum WeatherSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case openMeteo, apple, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openMeteo: "Open-Meteo"
        case .apple: "Apple Weather"
        case .off: "Off"
        }
    }
}

nonisolated struct WeatherForecast: Codable, Sendable {
    var fetchedAt: Date
    var source: WeatherSource
    var placeName: String?
    /// Ascending by date.
    var hours: [HourlyWeather]
    var sun: [SunTimes]

    /// Hours that overlap the interval.
    func hours(overlapping interval: DateInterval) -> [HourlyWeather] {
        hours.filter { $0.date < interval.end && $0.date.addingTimeInterval(3600) > interval.start }
    }

    func sun(on date: Date, calendar: Calendar) -> SunTimes? {
        sun.first { calendar.isDate($0.date, inSameDayAs: date) }
    }
}

nonisolated struct WeatherPlace: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

/// When and where to look for training time.
nonisolated struct ScheduleSettings: Codable, Equatable, Sendable {
    /// Suggest times from the calendar (needs calendar access).
    var suggestTimes = false
    var weatherSource = WeatherSource.openMeteo
    /// Weather for the current location, or for `place`.
    var useCurrentLocation = true
    var place: WeatherPlace?
    /// Minutes after midnight.
    var earliestMinute = 6 * 60
    var latestMinute = 21 * 60
    /// Kept free before and after other events.
    var bufferMinutes = 15
    /// Calendar that sessions are added to; nil uses the default calendar.
    var calendarID: String?
}

nonisolated extension ScheduleSettings {
    /// Decodes field by field so settings saved by an older version keep their values when fields are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = ScheduleSettings()
        suggestTimes = try value(.suggestTimes, defaults.suggestTimes)
        weatherSource = try value(.weatherSource, defaults.weatherSource)
        useCurrentLocation = try value(.useCurrentLocation, defaults.useCurrentLocation)
        place = try container.decodeIfPresent(WeatherPlace.self, forKey: .place)
        earliestMinute = try value(.earliestMinute, defaults.earliestMinute)
        latestMinute = try value(.latestMinute, defaults.latestMinute)
        bufferMinutes = try value(.bufferMinutes, defaults.bufferMinutes)
        calendarID = try container.decodeIfPresent(String.self, forKey: .calendarID)
    }
}

/// The weather over a suggested slot: the worst condition and the highest rain chance it covers.
nonisolated struct SlotWeather: Hashable, Sendable {
    var condition: SkyCondition
    var temperatureC: Double
    var apparentTemperatureC: Double
    var precipitationChance: Double
    var windKph: Double
    /// Mostly before sunrise or after sunset.
    var isNight = false

    var systemImage: String {
        guard isNight else { return condition.systemImage }
        switch condition {
        case .clear: return "moon.stars.fill"
        case .partlyCloudy: return "cloud.moon.fill"
        default: return condition.systemImage
        }
    }

    /// "9 °C, dry" or "14 °C, rain 60%".
    var summary: String {
        let temperature = "\(Int(temperatureC.rounded())) °C"
        let chance = Int((precipitationChance * 100).rounded())
        guard chance >= 30 else { return "\(temperature), dry" }
        // Snow and worse are named; lighter conditions with a rain chance are just "rain".
        let kind = condition.severity >= SkyCondition.snow.severity ? condition.title.lowercased() : "rain"
        return "\(temperature), \(kind) \(chance)%"
    }
}

/// A time for a planned session, with a score (0–100) and what went into it.
nonisolated struct SlotSuggestion: Hashable, Identifiable, Sendable {
    var start: Date
    var end: Date
    var score: Double
    var weather: SlotWeather?
    /// What speaks for this time, e.g. "Your usual time".
    var reasons: [String]
    /// What speaks against it, e.g. "Rain likely (70%)".
    var warnings: [String]

    var id: Date { start }
}

/// Suggested times for one planned day.
nonisolated struct DaySchedule: Hashable, Identifiable, Sendable {
    var date: Date
    var session: PlannedDay
    /// The calendar event Stride added for this session, if any.
    var scheduled: BusyInterval?
    /// Best first.
    var slots: [SlotSuggestion]
    /// Why there are no slots.
    var note: String?

    var id: Date { date }
    var best: SlotSuggestion? { slots.first }
}
