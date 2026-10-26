import CoreLocation
import Foundation
import MapKit
#if WEATHERKIT
import WeatherKit
#endif

nonisolated enum WeatherError: LocalizedError {
    case locationDenied
    case locationUnavailable
    case placeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .locationDenied: "Location access is off. Allow it in Settings, or enter a place for the weather."
        case .locationUnavailable: "Couldn't find your location. Enter a place for the weather in Settings."
        case .placeNotFound(let text): "Couldn't find \"\(text)\"."
        }
    }
}

/// The forecast from the chosen source: Open-Meteo (free, no account) or Apple Weather (WeatherKit).
nonisolated enum WeatherClient {
    /// WeatherKit needs the `com.apple.developer.weatherkit` entitlement, which only paid Apple Developer accounts
    /// can get. Build with the WEATHERKIT compilation condition (and that entitlement) to offer it.
    #if WEATHERKIT
    static let isAppleWeatherInBuild = true
    #else
    static let isAppleWeatherInBuild = false
    #endif

    /// `place.name` is empty for the current location.
    static func forecast(source: WeatherSource, place: WeatherPlace, days: Int = 8) async throws -> WeatherForecast? {
        let name = place.name.isEmpty ? nil : place.name
        switch source {
        case .off:
            return nil
        case .apple where isAppleWeatherInBuild:
            #if WEATHERKIT
            return try await appleForecast(location: CLLocation(latitude: place.latitude, longitude: place.longitude), placeName: name, days: days)
            #else
            return nil
            #endif
        case .openMeteo, .apple:
            // A build without WeatherKit falls back to Open-Meteo for a setting saved by one with it.
            return try await OpenMeteo.fetch(latitude: place.latitude, longitude: place.longitude, placeName: name, days: days)
        }
    }

    #if WEATHERKIT
    private static func appleForecast(location: CLLocation, placeName: String?, days: Int) async throws -> WeatherForecast {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let (hourly, daily) = try await WeatherService.shared.weather(
            for: location,
            including: .hourly(startDate: start, endDate: end), .daily(startDate: start, endDate: end)
        )
        let hours = hourly.forecast.map { hour in
            HourlyWeather(
                date: hour.date,
                temperatureC: hour.temperature.converted(to: .celsius).value,
                apparentTemperatureC: hour.apparentTemperature.converted(to: .celsius).value,
                precipitationChance: hour.precipitationChance,
                precipitationMm: hour.precipitationAmount.converted(to: .millimeters).value,
                windKph: hour.wind.speed.converted(to: .kilometersPerHour).value,
                uvIndex: Double(hour.uvIndex.value),
                condition: SkyCondition(hour.condition)
            )
        }
        let sun = daily.forecast.compactMap { day -> SunTimes? in
            guard let sunrise = day.sun.sunrise, let sunset = day.sun.sunset else { return nil }
            return SunTimes(date: Calendar.current.startOfDay(for: day.date), sunrise: sunrise, sunset: sunset)
        }
        return WeatherForecast(fetchedAt: .now, source: .apple, placeName: placeName, hours: hours, sun: sun)
    }

    /// Apple requires its Weather mark and a link to the data sources wherever WeatherKit data is shown.
    static func appleAttribution() async -> (mark: URL, darkMark: URL, legal: URL)? {
        guard let attribution = try? await WeatherService.shared.attribution else { return nil }
        return (attribution.combinedMarkLightURL, attribution.combinedMarkDarkURL, attribution.legalPageURL)
    }
    #endif

    /// The device's approximate location. Asks for permission the first time.
    @MainActor
    static func currentLocation() async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { @MainActor in
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location { return location }
                    if update.authorizationDenied || update.authorizationDeniedGlobally { throw WeatherError.locationDenied }
                }
                throw WeatherError.locationUnavailable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw WeatherError.locationUnavailable
            }
            defer { group.cancelAll() }
            guard let location = try await group.next() else { throw WeatherError.locationUnavailable }
            return location
        }
    }

    /// Looks a place up by name, e.g. "Berlin" or "Prenzlauer Berg".
    @MainActor
    static func findPlace(_ text: String) async throws -> WeatherPlace {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let request = MKGeocodingRequest(addressString: query),
              let item = try await request.mapItems.first else { throw WeatherError.placeNotFound(query) }
        let coordinate = item.location.coordinate
        return WeatherPlace(name: item.name ?? query, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

#if WEATHERKIT
nonisolated extension SkyCondition {
    init(_ condition: WeatherCondition) {
        switch condition {
        case .clear, .mostlyClear, .hot, .frigid: self = .clear
        case .partlyCloudy: self = .partlyCloudy
        case .cloudy, .mostlyCloudy, .breezy, .windy, .haze, .smoky, .blowingDust: self = .cloudy
        case .foggy: self = .fog
        case .drizzle, .sunShowers: self = .drizzle
        case .rain: self = .rain
        case .heavyRain, .tropicalStorm, .hurricane: self = .heavyRain
        case .snow, .heavySnow, .flurries, .sunFlurries, .blowingSnow, .blizzard: self = .snow
        case .sleet, .freezingDrizzle, .freezingRain, .wintryMix, .hail: self = .sleet
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms: self = .thunderstorm
        @unknown default: self = .cloudy
        }
    }
}
#endif
