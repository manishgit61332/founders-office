import Foundation

public enum CalendarEventPresentation {
    public enum Kind: Int, Sendable {
        case timed
        case allDay
        case calendarNotice
    }

    /// EventKit does not expose a portable "public holiday" or event-author
    /// flag. Treat all-day reference feeds as notices, without inspecting event
    /// titles or mistaking every all-day event or read-only meeting for one.
    public static func kind(
        isAllDay: Bool,
        isReferenceCalendar: Bool,
        involvesCurrentUser: Bool
    ) -> Kind {
        guard isAllDay else { return .timed }
        return isReferenceCalendar && !involvesCurrentUser ? .calendarNotice : .allDay
    }

    /// Selects the next unfinished commitment, with calendar notices as fallback.
    ///
    /// Calendar feeds commonly include every event from the start of today so
    /// the day view can retain its history. A glanceable "Up next" surface
    /// must use an event's end, rather than its start or feed position, to
    /// avoid presenting a meeting after it has finished. Within the earliest
    /// eligible day, timed commitments precede personal all-day events. An
    /// all-day commitment today still precedes a meeting tomorrow. Holiday and
    /// other reference-calendar notices never displace a personal commitment.
    public static func upNext<Event>(
        from events: [Event],
        at referenceDate: Date,
        startDate: (Event) -> Date,
        endDate: (Event) -> Date,
        kind: (Event) -> Kind = { _ in .timed },
        calendar: Calendar = .current
    ) -> Event? {
        events.enumerated()
            .filter { endDate($0.element) > referenceDate }
            .min { lhs, rhs in
                let lhsKind = kind(lhs.element)
                let rhsKind = kind(rhs.element)
                if (lhsKind == .calendarNotice) != (rhsKind == .calendarNotice) {
                    return lhsKind != .calendarNotice
                }

                let lhsStart = startDate(lhs.element)
                let rhsStart = startDate(rhs.element)
                // Ongoing and overnight events belong to today's candidates.
                // Calendar arithmetic preserves local-day boundaries through DST.
                let lhsDay = calendar.startOfDay(for: max(lhsStart, referenceDate))
                let rhsDay = calendar.startOfDay(for: max(rhsStart, referenceDate))
                if lhsDay != rhsDay { return lhsDay < rhsDay }
                if lhsKind != rhsKind { return lhsKind.rawValue < rhsKind.rawValue }
                if lhsStart != rhsStart { return lhsStart < rhsStart }

                let lhsEnd = endDate(lhs.element)
                let rhsEnd = endDate(rhs.element)
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }

                return lhs.offset < rhs.offset
            }?
            .element
    }
}
