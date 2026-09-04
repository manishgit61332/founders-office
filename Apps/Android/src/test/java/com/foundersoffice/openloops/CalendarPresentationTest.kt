package com.foundersoffice.openloops

import com.foundersoffice.openloops.data.CalendarPresentation
import com.foundersoffice.openloops.data.LocalCalendarEvent
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CalendarPresentationTest {
    private val now = Instant.parse("2026-09-05T10:00:00Z")

    @Test
    fun choosesAnUnfinishedTimedCommitmentBeforeAnAllDayReferenceNotice() {
        val notice = event("notice", "2026-09-05T00:00:00Z", "2026-09-06T00:00:00Z", allDay = true, reference = true)
        val commitment = event("meeting", "2026-09-05T11:00:00Z", "2026-09-05T12:00:00Z")

        assertEquals("meeting", CalendarPresentation.upNext(listOf(notice, commitment), now)?.id)
    }

    @Test
    fun excludesFinishedEventsFromUpNext() {
        val finished = event("finished", "2026-09-05T08:00:00Z", "2026-09-05T09:00:00Z")

        assertNull(CalendarPresentation.upNext(listOf(finished), now))
    }

    private fun event(
        id: String,
        startsAt: String,
        endsAt: String,
        allDay: Boolean = false,
        reference: Boolean = false
    ) = LocalCalendarEvent(
        id = id,
        title = id,
        startsAt = Instant.parse(startsAt),
        endsAt = Instant.parse(endsAt),
        isAllDay = allDay,
        isReferenceCalendar = reference,
        involvesCurrentUser = false
    )
}
