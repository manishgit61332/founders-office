package com.foundersoffice.openloops

import com.foundersoffice.openloops.data.WidgetProjectionEntity
import com.foundersoffice.openloops.widget.widgetCopy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WidgetPresentationTest {
    @Test
    fun projectionIsPrivateByDefault() {
        val projection = WidgetProjectionEntity(updatedAt = "2026-09-05T00:00:00Z")

        assertTrue(projection.redacted)
    }

    @Test
    fun redactedProjectionNeverExposesMoveOrCommitmentText() {
        val copy = widgetCopy(
            WidgetProjectionEntity(
                nextMoveId = "move-1",
                nextMoveTitle = "Synthetic confidential Move",
                nextEventId = "event-1",
                nextEventTitle = "Synthetic private commitment",
                nextEventTime = "9:30 AM",
                redacted = true,
                updatedAt = "2026-09-05T00:00:00Z"
            )
        )

        assertEquals("Move details hidden", copy.move)
        assertEquals("Commitment details hidden", copy.commitment)
    }

    @Test
    fun visibleProjectionKeepsTheCompactMoveFirstHierarchy() {
        val copy = widgetCopy(
            WidgetProjectionEntity(
                nextMoveId = "move-1",
                nextMoveTitle = "Prepare the launch brief",
                nextEventId = "event-1",
                nextEventTitle = "Synthetic launch review",
                nextEventTime = "9:30 AM",
                redacted = false,
                updatedAt = "2026-09-05T00:00:00Z"
            )
        )

        assertEquals("Prepare the launch brief", copy.move)
        assertEquals("9:30 AM · Synthetic launch review", copy.commitment)
    }
}
