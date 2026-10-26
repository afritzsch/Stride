import Foundation

/// Free forecast API without a key (open-meteo.com, CC BY 4.0). Only the location, rounded to about 1 km,
/// leaves the device.
nonisolated enum OpenMeteo {
    static let attribution = "Weather data by Open-Meteo.com"
    static let attributionURL = URL(string: "https://open-meteo.com/")!

    static func url(latitude: Double, longitude: Double, days: Int) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let rounded = { (value: Double) in String(format: "%.2f", value) }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: rounded(latitude)),
            URLQueryItem(name: "longitude", value: rounded(longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m,uv_index"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "forecast_days", value: "\(min(max(days, 1), 16))"),
        ]
        return components.url!
    }

    static func fetch(latitude: Double, longitude: Double, placeName: String?, days: Int = 8) async throws -> WeatherForecast {
        let (data, response) = try await URLSession.shared.data(from: url(latitude: latitude, longitude: longitude, days: days))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The weather service answered with status \(http.statusCode)."])
        }
        return try parse(data, placeName: placeName)
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            var time: [Double]
            var temperature_2m: [Double?]
            var apparent_temperature: [Double?]
            var precipitation_probability: [Double?]
            var precipitation: [Double?]
            var weather_code: [Int?]
            var wind_speed_10m: [Double?]
            var uv_index: [Double?]
        }

        struct Daily: Decodable {
            var time: [Double]
            var sunrise: [Double?]
            var sunset: [Double?]
        }

        var hourly: Hourly
        var daily: Daily?
    }

    /// Hours without a temperature are dropped; other missing values count as nothing (no rain, no wind).
    static func parse(_ data: Data, placeName: String?, fetchedAt: Date = .now) throws -> WeatherForecast {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let hourly = response.hourly
        func value<T>(_ values: [T?], _ index: Int) -> T? { values.indices.contains(index) ? values[index] : nil }

        let hours = hourly.time.indices.compactMap { index -> HourlyWeather? in
            guard let temperature = value(hourly.temperature_2m, index) else { return nil }
            return HourlyWeather(
                date: Date(timeIntervalSince1970: hourly.time[index]),
                temperatureC: temperature,
                apparentTemperatureC: value(hourly.apparent_temperature, index) ?? temperature,
                precipitationChance: (value(hourly.precipitation_probability, index) ?? 0) / 100,
                precipitationMm: value(hourly.precipitation, index) ?? 0,
                windKph: value(hourly.wind_speed_10m, index) ?? 0,
                uvIndex: value(hourly.uv_index, index) ?? 0,
                condition: SkyCondition.wmo(value(hourly.weather_code, index) ?? 3)
            )
        }
        let sun = (response.daily.map { daily in
            daily.time.indices.compactMap { index -> SunTimes? in
                guard let sunrise = value(daily.sunrise, index), let sunset = value(daily.sunset, index) else { return nil }
                return SunTimes(
                    date: Date(timeIntervalSince1970: daily.time[index]),
                    sunrise: Date(timeIntervalSince1970: sunrise),
                    sunset: Date(timeIntervalSince1970: sunset)
                )
            }
        }) ?? []
        return WeatherForecast(fetchedAt: fetchedAt, source: .openMeteo, placeName: placeName, hours: hours, sun: sun)
    }
}
