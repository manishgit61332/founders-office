import Foundation

/// A date-only planning value in the proleptic Gregorian calendar.
///
/// `PlanningDay` deliberately has no time zone. Persist planning deadlines by
/// converting the day to a canonical `Date` with `PlanningDate.storedDate(for:)`.
public struct PlanningDay: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }

        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: PlanningDay, rhs: PlanningDay) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

/// Converts between local date-picker values and date-only deadline storage.
///
/// Stored deadlines use noon UTC for the selected Gregorian calendar day. Noon
/// UTC is compatible with existing canonical Founder Office data while keeping
/// a stable, sortable `Date` representation. When reading legacy timestamps
/// that are not noon UTC, their UTC year, month, and day remain authoritative.
public enum PlanningDate {
    /// Returns true when a stored value already uses the date-only noon-UTC
    /// representation introduced with planning schema 3.
    public static func isCanonicalStoredDate(_ date: Date) -> Bool {
        storedDate(for: day(fromStored: date)) == date
    }

    /// Returns the Gregorian calendar day shown in the supplied local calendar's
    /// time zone. The calendar identifier and locale do not change storage.
    public static func day(
        fromLocal date: Date,
        calendar: Calendar = .current
    ) -> PlanningDay {
        let localCalendar = gregorianCalendar(timeZone: calendar.timeZone)
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        return PlanningDay(
            validatedYear: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    /// Returns the stored calendar day, interpreting UTC components as the
    /// date-only source of truth.
    public static func day(fromStored date: Date) -> PlanningDay {
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return PlanningDay(
            validatedYear: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    /// Converts a date selected in a local date picker to canonical noon UTC.
    public static func storedDate(
        fromLocal date: Date,
        calendar: Calendar = .current
    ) -> Date {
        storedDate(for: day(fromLocal: date, calendar: calendar))
    }

    /// Converts a planning day to its canonical noon-UTC persisted value.
    public static func storedDate(for day: PlanningDay) -> Date {
        var components = DateComponents()
        components.timeZone = utcCalendar.timeZone
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 12
        return utcCalendar.date(from: components)!
    }

    /// Rebuilds a local-noon `Date` so a date picker or formatter displays the
    /// stored planning day without applying the UTC offset to that day.
    public static func localDate(
        fromStored date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let storedDay = day(fromStored: date)
        let localCalendar = gregorianCalendar(timeZone: calendar.timeZone)
        var components = DateComponents()
        components.timeZone = localCalendar.timeZone
        components.year = storedDay.year
        components.month = storedDay.month
        components.day = storedDay.day
        components.hour = 12
        return localCalendar.date(from: components)!
    }

    private static var utcCalendar: Calendar {
        gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

private extension PlanningDay {
    init(validatedYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}
