package com.foundersoffice.openloops

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.foundersoffice.openloops.auth.AuthAvailability
import com.foundersoffice.openloops.data.CalendarPresentation
import com.foundersoffice.openloops.data.LocalCalendarEvent
import com.foundersoffice.openloops.data.Move
import com.foundersoffice.openloops.data.MoveDraft
import com.foundersoffice.openloops.data.MovePriority
import com.foundersoffice.openloops.data.MoveStatus
import java.time.LocalDate

class MainActivity : ComponentActivity() {
    private var incomingData by mutableStateOf<android.net.Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incomingData = intent?.data
        setContent {
            val viewModel: OpenLoopsViewModel = viewModel(
                factory = OpenLoopsViewModelFactory(OpenLoopsApplication.container(this))
            )
            LaunchedEffect(incomingData) { viewModel.handleCallback(incomingData) }
            FoundersOfficeTheme { OpenLoopsApp(viewModel) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingData = intent.data
    }
}

private enum class Destination(val title: String) {
    Home("Home"), Moves("Moves"), Calendar("Calendar"), Settings("Settings")
}

@Composable
private fun FoundersOfficeTheme(content: @Composable () -> Unit) {
    val colors: ColorScheme = lightColorScheme(
        primary = Color(0xFF1D4ED8),
        onPrimary = Color.White,
        secondary = Color(0xFF5B21B6),
        surface = Color(0xFFF9FAFB),
        onSurface = Color(0xFF111827)
    )
    MaterialTheme(colorScheme = colors, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OpenLoopsApp(viewModel: OpenLoopsViewModel) {
    var destination by remember { mutableStateOf(Destination.Home) }
    val moves by viewModel.moves.collectAsStateWithLifecycle()
    val events by viewModel.calendarEvents.collectAsStateWithLifecycle()
    val notice by viewModel.notice.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(notice) {
        notice?.let {
            snackbar.showSnackbar(it)
            viewModel.consumeNotice()
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text(destination.title, fontWeight = FontWeight.Bold) }) },
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                Destination.entries.forEach { item ->
                    val icon = when (item) {
                        Destination.Home -> Icons.Outlined.Home
                        Destination.Moves -> Icons.Outlined.CheckCircle
                        Destination.Calendar -> Icons.Outlined.CalendarMonth
                        Destination.Settings -> Icons.Outlined.Settings
                    }
                    NavigationBarItem(
                        selected = destination == item,
                        onClick = { destination = item },
                        icon = { Icon(icon, contentDescription = item.title) },
                        label = { Text(item.title) }
                    )
                }
            }
        }
    ) { padding ->
        when (destination) {
            Destination.Home -> HomeScreen(moves, events, Modifier.padding(padding))
            Destination.Moves -> MovesScreen(moves, viewModel, Modifier.padding(padding))
            Destination.Calendar -> CalendarScreen(events, viewModel, Modifier.padding(padding))
            Destination.Settings -> SettingsScreen(viewModel, Modifier.padding(padding))
        }
    }
}

@Composable
private fun HomeScreen(moves: List<Move>, events: List<LocalCalendarEvent>, modifier: Modifier = Modifier) {
    val activeMoves = moves.filter { it.status != MoveStatus.DONE }.sortedWith(moveOrdering)
    val upNext = CalendarPresentation.upNext(events, java.time.Instant.now())
    LazyColumn(
        modifier = modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item { Text("One clear next step", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        item {
            SummaryCard("Next Move", activeMoves.firstOrNull()?.title ?: "Add a Move when you are ready.")
        }
        item {
            SummaryCard(
                "Up next",
                upNext?.let { listOfNotNull(it.startTimeLabel, it.title).joinToString(" · ") }
                    ?: "Calendar stays local until you grant access."
            )
        }
        item { SummaryCard("Primary goal", "No primary goal set yet.") }
    }
}

@Composable
private fun SummaryCard(label: String, value: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun MovesScreen(moves: List<Move>, viewModel: OpenLoopsViewModel, modifier: Modifier = Modifier) {
    var composer by remember { mutableStateOf<Move?>(null) }
    var adding by remember { mutableStateOf(false) }
    val active = moves.filter { it.status != MoveStatus.DONE }.sortedWith(moveOrdering)
    val recentDone = moves.filter { it.status == MoveStatus.DONE }
        .sortedByDescending { it.completedAt }
        .filter { it.completedAt?.isAfter(java.time.Instant.now().minusSeconds(2 * 24 * 60 * 60)) == true }

    Column(modifier = modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("Moves", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Button(onClick = { adding = true }) { Text("Add Move") }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(active, key = { it.id }) { move ->
                MoveRow(move, onEdit = { composer = move }, onDone = { viewModel.markDone(move.id) })
            }
            if (recentDone.isNotEmpty()) {
                item { Text("Recent Done", Modifier.padding(top = 16.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
                items(recentDone, key = { it.id }) { move -> MoveRow(move, onEdit = { composer = move }, onDone = {}) }
            }
        }
    }
    if (adding) {
        MoveEditorDialog(
            title = "Add Move",
            existing = null,
            onDismiss = { adding = false },
            onSave = { draft -> viewModel.addMove(draft); adding = false }
        )
    }
    composer?.let { existing ->
        MoveEditorDialog(
            title = "Edit Move",
            existing = existing,
            onDismiss = { composer = null },
            onSave = { draft -> viewModel.editMove(existing.id, draft); composer = null }
        )
    }
}

@Composable
private fun MoveRow(move: Move, onEdit: () -> Unit, onDone: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onEdit)) {
        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Checkbox(
                checked = move.status == MoveStatus.DONE,
                enabled = move.status != MoveStatus.DONE,
                onCheckedChange = { if (it) onDone() },
                modifier = Modifier.semantics { contentDescription = "Mark ${move.title} Done" }
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(move.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                if (move.details.isNotBlank()) Text(move.details, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    AssistChip(onClick = onEdit, label = { Text(move.priority.label) })
                    move.dueOn?.let { AssistChip(onClick = onEdit, label = { Text(it.toString()) }) }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MoveEditorDialog(
    title: String,
    existing: Move?,
    onDismiss: () -> Unit,
    onSave: (MoveDraft) -> Unit
) {
    var moveTitle by remember(existing) { mutableStateOf(existing?.title.orEmpty()) }
    var details by remember(existing) { mutableStateOf(existing?.details.orEmpty()) }
    var dueOn by remember(existing) { mutableStateOf(existing?.dueOn?.toString().orEmpty()) }
    var priority by remember(existing) { mutableStateOf(existing?.priority ?: MovePriority.P2) }
    var dateError by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(moveTitle, { moveTitle = it }, label = { Text("Title") }, singleLine = true)
                OutlinedTextField(details, { details = it }, label = { Text("Description") })
                OutlinedTextField(
                    dueOn,
                    { dueOn = it; dateError = false },
                    label = { Text("Deadline (YYYY-MM-DD)") },
                    isError = dateError,
                    singleLine = true
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    MovePriority.entries.forEach { candidate ->
                        FilterChip(
                            selected = priority == candidate,
                            onClick = { priority = candidate },
                            label = { Text(candidate.label) }
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                val parsedDate = dueOn.trim().takeIf(String::isNotEmpty)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
                dateError = dueOn.isNotBlank() && parsedDate == null
                if (!dateError && moveTitle.isNotBlank()) onSave(MoveDraft(moveTitle, details, parsedDate, priority))
            }) { Text("Save") }
        },
        dismissButton = { OutlinedButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun CalendarScreen(events: List<LocalCalendarEvent>, viewModel: OpenLoopsViewModel, modifier: Modifier = Modifier) {
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) viewModel.refreshCalendar()
    }
    Column(modifier = modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Calendar", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("Commitments stay on this device. Finished events do not appear in Up next.")
        Button(onClick = {
            if (viewModel.hasCalendarPermission()) viewModel.refreshCalendar()
            else permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
        }) {
            Text(if (viewModel.hasCalendarPermission()) "Refresh calendar" else "Allow calendar access")
        }
        if (events.isEmpty()) Text("No events loaded yet.")
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(events, key = { it.id }) { event ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text(event.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(event.startTimeLabel)
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsScreen(viewModel: OpenLoopsViewModel, modifier: Modifier = Modifier) {
    val signedIn by viewModel.signedIn.collectAsStateWithLifecycle()
    val widgetRedacted by viewModel.widgetRedacted.collectAsStateWithLifecycle()
    val availability = OpenLoopsApplication.container(androidx.compose.ui.platform.LocalContext.current)
        .productAuthConfiguration.availability
    Column(
        modifier = modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Account & Sync", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        val status = when (availability) {
            AuthAvailability.Ready -> if (signedIn) "Signed in on this device" else "Ready for Google product sign-in"
            AuthAvailability.Unconfigured -> "Local-only: Google and sync are not configured"
            AuthAvailability.InvalidPublicConfiguration -> "Local-only: public configuration was rejected"
        }
        SummaryCard("Status", status)
        Button(
            enabled = !signedIn && availability == AuthAvailability.Ready,
            onClick = viewModel::startGoogleSignIn
        ) { Text("Sign in with Google") }
        if (signedIn) {
            OutlinedButton(onClick = viewModel::signOut) { Text("Sign out on this device") }
        }
        HorizontalDivider()
        Text("Workspace", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text("Sign-in never uploads local Moves. Claim and attach stay disabled until the reviewed server and export-replace gates pass.")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(enabled = false, onClick = {}) { Text("Claim local workspace") }
            OutlinedButton(enabled = false, onClick = {}) { Text("Attach existing workspace") }
        }
        OutlinedButton(enabled = false, onClick = {}) { Text("Sync locked pending workspace setup") }
        HorizontalDivider()
        Text("Widget privacy", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Hide Move and event details")
            Switch(checked = widgetRedacted, onCheckedChange = viewModel::setWidgetRedacted)
        }
        Text("Connections are separate from product sign-in. Calendar permissions and connector grants are never copied between devices.")
    }
}

private val moveOrdering = compareBy<Move> { it.dueOn == null }
    .thenBy { it.dueOn }
    .thenBy { it.priority.ordinal }
    .thenBy { it.title.lowercase() }
