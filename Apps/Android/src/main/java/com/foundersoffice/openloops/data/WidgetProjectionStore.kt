package com.foundersoffice.openloops.data

import android.content.Context
import androidx.glance.appwidget.updateAll
import com.foundersoffice.openloops.widget.OpenLoopsMediumWidget
import com.foundersoffice.openloops.widget.OpenLoopsSmallWidget
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
        dao.save(current.copy(
            nextMoveId = move?.id,
            nextMoveTitle = move?.title,
            updatedAt = Instant.now().toString()
        ))
        refreshWidgets()
    }

    suspend fun setNextEvent(event: LocalCalendarEvent?) {
        val current = dao.current() ?: emptyProjection()
        dao.save(current.copy(
            nextEventId = event?.id,
            nextEventTitle = event?.title,
            nextEventTime = event?.startTimeLabel,
            updatedAt = Instant.now().toString()
        ))
        refreshWidgets()
    }

    suspend fun setRedacted(redacted: Boolean) {
        val current = dao.current() ?: emptyProjection()
        dao.save(current.copy(redacted = redacted, updatedAt = Instant.now().toString()))
        refreshWidgets()
    }

    suspend fun current(): WidgetProjectionEntity = dao.current() ?: emptyProjection()

    private fun emptyProjection() = WidgetProjectionEntity(updatedAt = Instant.EPOCH.toString())

    private suspend fun refreshWidgets() {
        OpenLoopsSmallWidget().updateAll(context)
        OpenLoopsMediumWidget().updateAll(context)
    }
}
