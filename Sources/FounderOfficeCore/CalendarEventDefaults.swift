import Foundation

public enum CalendarEventDefaults {
    /// Suggests a start inside the selected calendar day. Today uses the next
    /// local half-hour when possible; a late-night editor stays on Today.
    public static func suggestedStart(
        for selectedDay: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        let selectedDayStart = calendar.startOfDay(for: selectedDay)
        guard calendar.isDate(selectedDay, inSameDayAs: now) else {
            return calendar.date(byAdding: .hour, value: 9, to: selectedDayStart)
                ?? selectedDayStart
        }

        let elapsed = now.timeIntervalSince(selectedDayStart)
        let interval: TimeInterval = 30 * 60
        let rounded = selectedDayStart.addingTimeInterval(ceil(elapsed / interval) * interval)
        return calendar.isDate(rounded, inSameDayAs: selectedDay) ? rounded : now
    }
}
