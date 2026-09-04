import Foundation
import FounderOfficeCore
import Testing
@testable import OpenLoops

struct CalendarUpNextTests {
    @Test("Home uses reference metadata without removing events from Calendar")
    func homeSelectionPreservesTheCalendarFeed() {
        let now = Date(timeIntervalSince1970: 1_788_523_200)
        let holiday = CalendarSignal(
            id: "reference", title: "Reference event", startDate: now - 3_600,
            endDate: now + 43_200, isAllDay: true, calendarTitle: "Reference",
            accountTitle: "Test account", providerTitle: "Calendar", isReferenceCalendar: true
        )
        let personal = CalendarSignal(
            id: "personal", title: "Personal event", startDate: now + 600,
            endDate: now + 1_200, isAllDay: false, calendarTitle: "Personal",
            accountTitle: "Test account", providerTitle: "Calendar"
        )
        let feed = [holiday, personal]
        let next = CalendarEventPresentation.upNext(
            from: feed, at: now, startDate: \.startDate, endDate: \.endDate, kind: \.upNextKind
        )
        #expect(next == personal)
        #expect(feed == [holiday, personal])
        #expect(holiday.upNextKind == .calendarNotice)

        var invitation = holiday
        invitation.involvesCurrentUser = true
        #expect(invitation.upNextKind == .allDay)
    }
}
