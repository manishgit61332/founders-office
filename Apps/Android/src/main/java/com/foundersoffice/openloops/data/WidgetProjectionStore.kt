package com.foundersoffice.openloops.data

import android.content.Context
import com.foundersoffice.openloops.widget.refreshWidgetProjection
import java.time.Instant

/**
 * Keeps the widget projection intentionally small and independent from the
 * canonical Room tables. Projection updates are event-driven by foreground
 * writes and calendar refreshes; the widget never runs a sync loop itself.
 */
class WidgetProjectionStore(
    private val context: Context,
    private val dao: WidgetProjectionDao
) {
    suspend fun setNextMove(move: Move?) {
        val current = dao.current() ?: emptyProjection()
        val updated = current.copy(
            nextMoveId = move?.id,
            nextMoveTitle = move?.title,
            updatedAt = Instant.now().toString()
        )
        dao.save(updated)
        refreshWidgetProjection(context, updated)
    }

    suspend fun setNextEvent(event: LocalCalendarEvent?) {
        val current = dao.current() ?: emptyProjection()
        val updated = current.copy(
            nextEventId = event?.id,
            nextEventTitle = event?.title,
            nextEventTime = event?.startTimeLabel,
            updatedAt = Instant.now().toString()
        )
        dao.save(updated)
        refreshWidgetProjection(context, updated)
    }

    suspend fun setRedacted(redacted: Boolean) {
        val current = dao.current() ?: emptyProjection()
        val updated = current.copy(redacted = redacted, updatedAt = Instant.now().toString())
        dao.save(updated)
        refreshWidgetProjection(context, updated)
    }

    suspend fun current(): WidgetProjectionEntity = dao.current() ?: emptyProjection()

    private fun emptyProjection() = WidgetProjectionEntity(redacted = true, updatedAt = Instant.EPOCH.toString())
}
