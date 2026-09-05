package com.foundersoffice.openloops.widget

import android.content.Context
import android.content.Intent
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.currentState
import androidx.glance.layout.Column
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.core.net.toUri
import androidx.compose.ui.unit.sp
import com.foundersoffice.openloops.MainActivity
import com.foundersoffice.openloops.OpenLoopsApplication
import com.foundersoffice.openloops.data.WidgetProjectionEntity

/**
 * A passive bounded local projection. It has two compact lines, respects the
 * redaction setting, and deep-links only to a selected in-app item.
 */
class OpenLoopsSmallWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val projection = OpenLoopsApplication.container(context).projectionStore.current()
        writeProjectionState(context, id, projection)
        provideContent {
            WidgetContent(context, projectionFrom(currentState<Preferences>()), showEvent = false)
        }
    }
}

class OpenLoopsMediumWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val projection = OpenLoopsApplication.container(context).projectionStore.current()
        writeProjectionState(context, id, projection)
        provideContent {
            WidgetContent(context, projectionFrom(currentState<Preferences>()), showEvent = true)
        }
    }
}

class OpenLoopsSmallWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OpenLoopsSmallWidget()
}

class OpenLoopsMediumWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OpenLoopsMediumWidget()
}

@Composable
private fun WidgetContent(context: Context, projection: WidgetProjectionEntity, showEvent: Boolean) {
    val copy = widgetCopy(projection)
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetColors.surface)
            .cornerRadius(24.dp)
            .padding(16.dp)
    ) {
        Text("FOUNDER’S OFFICE", style = WidgetStyles.brand)
        Spacer(GlanceModifier.height(12.dp))
        Text("NEXT MOVE", style = WidgetStyles.label)
        Text(
            copy.move,
            modifier = GlanceModifier.fillMaxWidth().clickable(actionStartActivity(itemIntent(context, "move", projection.nextMoveId))),
            maxLines = 2,
            style = WidgetStyles.primary
        )
        if (showEvent) {
            Spacer(GlanceModifier.height(12.dp))
            Text("UP NEXT", style = WidgetStyles.label)
            Text(
                copy.commitment,
                modifier = GlanceModifier.fillMaxWidth().clickable(actionStartActivity(itemIntent(context, "calendar", projection.nextEventId))),
                maxLines = 2,
                style = WidgetStyles.secondary
            )
        }
        Spacer(GlanceModifier.defaultWeight())
        Text("PRIVATE · TAP TO OPEN", style = WidgetStyles.footer)
    }
}

internal data class WidgetCopy(val move: String, val commitment: String)

internal fun widgetCopy(projection: WidgetProjectionEntity): WidgetCopy {
    val move = when {
        projection.nextMoveId == null -> "No active Moves"
        projection.redacted -> "Move details hidden"
        else -> projection.nextMoveTitle ?: "Open Founder’s Office"
    }
    val event = when {
        projection.nextEventId == null -> "No upcoming commitment"
        projection.redacted -> "Commitment details hidden"
        else -> listOfNotNull(projection.nextEventTime, projection.nextEventTitle).joinToString(" · ")
    }
    return WidgetCopy(move = move, commitment = event)
}

internal suspend fun refreshWidgetProjection(context: Context, projection: WidgetProjectionEntity) {
    val manager = GlanceAppWidgetManager(context)
    refreshWidgetType(context, manager, OpenLoopsSmallWidget(), OpenLoopsSmallWidget::class.java, projection)
    refreshWidgetType(context, manager, OpenLoopsMediumWidget(), OpenLoopsMediumWidget::class.java, projection)
}

private suspend fun refreshWidgetType(
    context: Context,
    manager: GlanceAppWidgetManager,
    widget: GlanceAppWidget,
    widgetClass: Class<out GlanceAppWidget>,
    projection: WidgetProjectionEntity
) {
    manager.getGlanceIds(widgetClass).forEach { id ->
        writeProjectionState(context, id, projection)
        widget.update(context, id)
    }
}

private suspend fun writeProjectionState(
    context: Context,
    id: GlanceId,
    projection: WidgetProjectionEntity
) {
    updateAppWidgetState(context, PreferencesGlanceStateDefinition, id) { preferences ->
        preferences.toMutablePreferences().apply {
            putOrRemove(WidgetStateKeys.nextMoveId, projection.nextMoveId)
            putOrRemove(WidgetStateKeys.nextMoveTitle, projection.nextMoveTitle)
            putOrRemove(WidgetStateKeys.nextEventId, projection.nextEventId)
            putOrRemove(WidgetStateKeys.nextEventTitle, projection.nextEventTitle)
            putOrRemove(WidgetStateKeys.nextEventTime, projection.nextEventTime)
            this[WidgetStateKeys.redacted] = projection.redacted
            this[WidgetStateKeys.updatedAt] = projection.updatedAt
        }
    }
}

private fun androidx.datastore.preferences.core.MutablePreferences.putOrRemove(
    key: Preferences.Key<String>,
    value: String?
) {
    if (value == null) remove(key) else this[key] = value
}

private fun projectionFrom(preferences: Preferences) = WidgetProjectionEntity(
    nextMoveId = preferences[WidgetStateKeys.nextMoveId],
    nextMoveTitle = preferences[WidgetStateKeys.nextMoveTitle],
    nextEventId = preferences[WidgetStateKeys.nextEventId],
    nextEventTitle = preferences[WidgetStateKeys.nextEventTitle],
    nextEventTime = preferences[WidgetStateKeys.nextEventTime],
    redacted = preferences[WidgetStateKeys.redacted] ?: true,
    updatedAt = preferences[WidgetStateKeys.updatedAt] ?: "1970-01-01T00:00:00Z"
)

private object WidgetStateKeys {
    val nextMoveId = stringPreferencesKey("next_move_id")
    val nextMoveTitle = stringPreferencesKey("next_move_title")
    val nextEventId = stringPreferencesKey("next_event_id")
    val nextEventTitle = stringPreferencesKey("next_event_title")
    val nextEventTime = stringPreferencesKey("next_event_time")
    val redacted = booleanPreferencesKey("redacted")
    val updatedAt = stringPreferencesKey("updated_at")
}

private object WidgetColors {
    val surface = ColorProvider(day = Color(0xFFFFFFFF), night = Color(0xFF0E0F12))
    val primary = ColorProvider(day = Color(0xFF111114), night = Color(0xFFF7F7F7))
    val secondary = ColorProvider(day = Color(0xFF636366), night = Color(0xFFA9A9AF))
    val accent = ColorProvider(day = Color(0xFF007AFF), night = Color(0xFF0A84FF))
}

private object WidgetStyles {
    val brand = TextStyle(
        color = WidgetColors.secondary,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium
    )
    val label = TextStyle(
        color = WidgetColors.accent,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold
    )
    val primary = TextStyle(
        color = WidgetColors.primary,
        fontSize = 17.sp,
        fontWeight = FontWeight.Bold
    )
    val secondary = TextStyle(
        color = WidgetColors.primary,
        fontSize = 14.sp,
        fontWeight = FontWeight.Medium
    )
    val footer = TextStyle(
        color = WidgetColors.secondary,
        fontSize = 9.sp,
        fontWeight = FontWeight.Medium
    )
}

private fun itemIntent(context: Context, kind: String, id: String?): Intent = Intent(context, MainActivity::class.java)
    .setData("openloops://$kind/${id ?: "home"}".toUri())
