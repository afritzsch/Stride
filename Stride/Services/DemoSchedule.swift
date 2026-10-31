import Foundation

/// A made-up calendar and forecast for demo data, so time suggestions can be tried without calendar access or a
/// network. Deterministic per day, so the same day always looks the same.
nonisolated enum DemoSchedule {
    static let placeName = "Demo city"

    /// `minutes` after midnight on the wall clock, so events keep their hour on days the clocks change.
    private static func time(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? day.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Office hours on weekdays plus a few fixed appointments, for the next `days` days from today.
    static func busy(days: Int = 8, now: Date = .now, calendar: Calendar = .current) -> [BusyInterval] {
        let today = calendar.startOfDay(for: now)
        var events: [BusyInterval] = []
        func add(_ day: Date, _ from: Int, _ to: Int, _ title: String) {
            events.append(BusyInterval(start: time(from, on: day, calendar: calendar), end: time(to, on: day, calendar: calendar), title: title))
        }
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            switch calendar.component(.weekday, from: day) { // 1 = Sunday
            case 2:
                add(day, 8 * 60 + 30, 17 * 60, "Work")
                add(day, 19 * 60, 20 * 60 + 30, "Choir")
            case 3:
                add(day, 7 * 60 + 30, 8 * 60, "Team call")
                add(day, 8 * 60 + 30, 17 * 60 + 30, "Work")
            case 4:
                add(day, 8 * 60 + 30, 17 * 60, "Work")
                add(day, 18 * 60, 19 * 60 + 30, "Dinner with friends")
            case 5:
                add(day, 8 * 60 + 30, 18 * 60, "Work")
            case 6:
                add(day, 8 * 60 + 30, 15 * 60, "Work")
            case 7:
                add(day, 10 * 60, 12 * 60, "Farmers market")
            default:
                add(day, 13 * 60, 17 * 60, "Family visit")
            }
        }
        return events
    }

    /// An autumn week: cool mornings, a wet afternoon, a rainy morning and a windy day, with sunrise and sunset.
    static func forecast(days: Int = 8, now: Date = .now, calendar: Calendar = .current) -> WeatherForecast {
        let today = calendar.startOfDay(for: now)
        var hours: [HourlyWeather] = []
        var sun: [SunTimes] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            var rng = SeededGenerator(seed: UInt64(day.timeIntervalSince1970 / 86400))
            let dayHigh = Double.random(in: 10...15, using: &rng)
            sun.append(SunTimes(date: day, sunrise: time(7 * 60 + 10, on: day, calendar: calendar), sunset: time(16 * 60 + 50, on: day, calendar: calendar)))
            for hour in 0..<24 {
                // Coolest around 5:00, warmest around 15:00.
                let warmth = (1 - cos(Double(hour - 5) / 24 * 2 * .pi)) / 2
                let temperature = dayHigh - 8 + 8 * warmth + Double.random(in: -0.5...0.5, using: &rng)
                var chance = Double.random(in: 0...0.15, using: &rng)
                var wind = Double.random(in: 6...16, using: &rng)
                var condition = SkyCondition.partlyCloudy
                if offset % 4 == 1, (14...19).contains(hour) {
                    chance = 0.7
                    condition = .rain
                } else if offset % 4 == 3, (6...11).contains(hour) {
                    chance = 0.6
                    condition = .drizzle
                } else if offset % 5 == 4 {
                    wind = Double.random(in: 32...42, using: &rng)
                    condition = .cloudy
                } else if hour < 7 || hour > 17 {
                    condition = .clear
                }
                hours.append(HourlyWeather(
                    date: day.addingTimeInterval(TimeInterval(hour * 3600)),
                    temperatureC: temperature,
                    apparentTemperatureC: temperature - wind / 10,
                    precipitationChance: chance,
                    precipitationMm: chance >= 0.5 ? 0.8 : 0,
                    windKph: wind,
                    uvIndex: (10...15).contains(hour) ? 2 : 0,
                    condition: condition
                ))
            }
        }
        return WeatherForecast(fetchedAt: now, source: .openMeteo, placeName: placeName, hours: hours, sun: sun)
    }
}
