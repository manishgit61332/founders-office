package com.foundersoffice.openloops.data

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class LocalCalendarEvent(
    val id: String,
    val title: String,
    val startsAt: Instant,
    val endsAt: Instant,
    val isAllDay: Boolean,
    val isReferenceCalendar: Boolean,
    val involvesCurrentUser: Boolean
) {
    val startTimeLabel: String
        get() = if (isAllDay) "All day" else DateTimeFormatter.ofPattern("EEE h:mm a")
            .format(LocalDateTime.ofInstant(startsAt, ZoneId.systemDefault()))
}

enum class CalendarKind { Timed, AllDay, CalendarNotice }

/** Platform-neutral ordering mirrored from the shared Calendar presentation policy. */
object CalendarPresentation {
    fun kind(event: LocalCalendarEvent): CalendarKind = when {
        !event.isAllDay -> CalendarKind.Timed
        event.isReferenceCalendar && !event.involvesCurrentUser -> CalendarKind.CalendarNotice
        else -> CalendarKind.AllDay
    }

    fun upNext(events: List<LocalCalendarEvent>, reference: Instant): LocalCalendarEvent? =
        events.withIndex()
            .filter { it.value.endsAt > reference }
            .minWithOrNull(compareBy<IndexedValue<LocalCalendarEvent>> {
                if (kind(it.value) == CalendarKind.CalendarNotice) 1 else 0
            }.thenBy {
                LocalDateTime.ofInstant(maxOf(it.value.startsAt, reference), ZoneId.systemDefault()).toLocalDate()
            }.thenBy { kind(it.value).ordinal }.thenBy { it.value.startsAt }.thenBy { it.value.endsAt }.thenBy { it.index })
            ?.value
}

/**
 * Reads only locally-authorized CalendarProvider data. Calendar permissions and
 * event contents are never uploaded, derived into account keys, or copied to a
 * different operating system.
 */
class CalendarRepository(
    private val context: Context,
    private val projectionStore: WidgetProjectionStore
) {
    fun hasPermission(): Boolean = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.READ_CALENDAR
    ) == PackageManager.PERMISSION_GRANTED

    suspend fun refresh(reference: Instant = Instant.now()): List<LocalCalendarEvent> = withContext(Dispatchers.IO) {
        if (!hasPermission()) return@withContext emptyList()
        val calendarAccess = mutableMapOf<Long, Int>()
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL),
            null,
            null,
            null
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID)
            val accessIndex = cursor.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
            while (cursor.moveToNext()) calendarAccess[cursor.getLong(idIndex)] = cursor.getInt(accessIndex)
        }

        val end = reference.plusSeconds(30L * 24 * 60 * 60)
        val instanceBuilder = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(instanceBuilder, reference.toEpochMilli())
        ContentUris.appendId(instanceBuilder, end.toEpochMilli())
        val uri = instanceBuilder.build()
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.SELF_ATTENDEE_STATUS
        )
        val events = buildList {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                val eventId = cursor.getColumnIndexOrThrow(CalendarContract.Instances.EVENT_ID)
                val title = cursor.getColumnIndexOrThrow(CalendarContract.Instances.TITLE)
                val begin = cursor.getColumnIndexOrThrow(CalendarContract.Instances.BEGIN)
                val endIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.END)
                val allDay = cursor.getColumnIndexOrThrow(CalendarContract.Instances.ALL_DAY)
                val calendarId = cursor.getColumnIndexOrThrow(CalendarContract.Instances.CALENDAR_ID)
                val attendee = cursor.getColumnIndexOrThrow(CalendarContract.Instances.SELF_ATTENDEE_STATUS)
                while (cursor.moveToNext()) {
                    val accessLevel = calendarAccess[cursor.getLong(calendarId)] ?: CalendarContract.Calendars.CAL_ACCESS_READ
                    add(LocalCalendarEvent(
                        id = cursor.getLong(eventId).toString(),
                        title = cursor.getString(title).orEmpty().ifBlank { "Untitled event" },
                        startsAt = Instant.ofEpochMilli(cursor.getLong(begin)),
                        endsAt = Instant.ofEpochMilli(cursor.getLong(endIndex)),
                        isAllDay = cursor.getInt(allDay) != 0,
                        isReferenceCalendar = accessLevel < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR,
                        involvesCurrentUser = cursor.getInt(attendee) != CalendarContract.Attendees.ATTENDEE_STATUS_NONE
                    ))
                }
            }
        }
        projectionStore.setNextEvent(CalendarPresentation.upNext(events, reference))
        events.sortedWith(compareBy<LocalCalendarEvent> { it.startsAt }.thenBy { it.endsAt })
    }
}
