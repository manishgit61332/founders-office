package com.foundersoffice.openloops.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Column
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.core.net.toUri
import com.foundersoffice.openloops.MainActivity
import com.foundersoffice.openloops.OpenLoopsApplication
import com.foundersoffice.openloops.data.WidgetProjectionEntity

/**
 * A passive bounded local projection. It has two compact lines, respects the
 * redaction setting, and deep-links only to a selected in-app item.
 */
class OpenLoopsSmallWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val projection = OpenLoopsApplication.container(context).projectionStore.current()
        provideContent { WidgetContent(context, projection, showEvent = false) }
    }
}

class OpenLoopsMediumWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val projection = OpenLoopsApplication.container(context).projectionStore.current()
        provideContent { WidgetContent(context, projection, showEvent = true) }
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
    val nextMoveText = if (projection.redacted) "Private Move" else projection.nextMoveTitle ?: "No active Moves"
    val nextEventText = if (projection.redacted) "Private event" else projection.nextEventTitle ?: "No upcoming event"
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(ColorProvider(day = Color(0xFFF7F7FA), night = Color(0xFF1F2937)))
            .padding(16.dp)
    ) {
        Text("Founder’s Office", style = TextStyle(fontWeight = FontWeight.Bold))
        Spacer(GlanceModifier.height(10.dp))
        Text("NEXT MOVE")
        Text(
            nextMoveText,
            modifier = GlanceModifier.fillMaxWidth().clickable(actionStartActivity(itemIntent(context, "move", projection.nextMoveId))),
            maxLines = 2
        )
        if (showEvent) {
            Spacer(GlanceModifier.height(8.dp))
            Text("UP NEXT")
            Text(
                listOfNotNull(projection.nextEventTime, nextEventText).joinToString(" · "),
                modifier = GlanceModifier.fillMaxWidth().clickable(actionStartActivity(itemIntent(context, "calendar", projection.nextEventId))),
                maxLines = 2
            )
        }
    }
}

private fun itemIntent(context: Context, kind: String, id: String?): Intent = Intent(context, MainActivity::class.java)
    .setData("openloops://$kind/${id ?: "home"}".toUri())
