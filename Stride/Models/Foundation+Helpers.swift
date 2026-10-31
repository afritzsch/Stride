import Foundation

nonisolated extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when a version that saved it didn't have the field yet.
    /// Used by hand-written decoders so saved JSON keeps loading when fields are added.
    func decode<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

nonisolated extension Calendar {
    /// The same calendar with ISO 8601 weeks: Monday first, and week 1 holds at least four days of the year.
    var iso: Calendar {
        var calendar = self
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// First instant of the week containing `date`, in this calendar's week definition.
    func startOfWeek(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// First instant of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? date
    }
}
