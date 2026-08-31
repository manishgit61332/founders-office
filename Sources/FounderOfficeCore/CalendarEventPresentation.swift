import Foundation

public enum CalendarEventPresentation {
    /// Selects the earliest event that has not finished at `referenceDate`.
    ///
    /// Calendar feeds commonly include every event from the start of today so
    /// the day view can retain its history. A glanceable "Up next" surface
    /// must use an event's end, rather than its start or feed position, to
    /// avoid presenting a meeting after it has finished.
    public static func upNext<Event>(
        from events: [Event],
        at referenceDate: Date,
        startDate: (Event) -> Date,
        endDate: (Event) -> Date
    ) -> Event? {
        events.enumerated()
            .filter { endDate($0.element) > referenceDate }
            .min { lhs, rhs in
                let lhsStart = startDate(lhs.element)
                let rhsStart = startDate(rhs.element)
                if lhsStart != rhsStart { return lhsStart < rhsStart }

                let lhsEnd = endDate(lhs.element)
                let rhsEnd = endDate(rhs.element)
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }

                return lhs.offset < rhs.offset
            }?
            .element
    }
}
