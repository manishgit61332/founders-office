package com.foundersoffice.openloops

import android.Manifest
import android.content.Intent
import android.graphics.Color as AndroidColor
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SyncDisabled
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Shapes
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
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
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

class MainActivity : ComponentActivity() {
    private var incomingData by mutableStateOf<Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
        )
        incomingData = intent?.data
        setContent {
            val viewModel: OpenLoopsViewModel = viewModel(
                factory = OpenLoopsViewModelFactory(OpenLoopsApplication.container(this))
            )
            val onboardingComplete by viewModel.onboardingComplete.collectAsStateWithLifecycle()
            LaunchedEffect(incomingData) { viewModel.handleCallback(incomingData) }
            FoundersOfficeTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    if (onboardingComplete) {
                        FoundersOfficeApp(viewModel, incomingData)
                    } else {
                        OnboardingScreen(viewModel::completeOnboarding)
                    }
                }
            }
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

private val InstrumentSerif = FontFamily(
    Font(R.font.instrument_serif_regular, weight = FontWeight.Normal)
)

private val FounderShapes = Shapes(
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(14.dp)
)

private val FounderTypography = Typography(
    headlineMedium = TextStyle(fontSize = 28.sp, lineHeight = 32.sp, fontWeight = FontWeight.Normal),
    titleLarge = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
    bodyLarge = TextStyle(fontSize = 17.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontSize = 15.sp, lineHeight = 21.sp),
    bodySmall = TextStyle(fontSize = 13.sp, lineHeight = 18.sp),
    labelLarge = TextStyle(fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.SemiBold),
    labelMedium = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium)
)

@Composable
private fun FoundersOfficeTheme(content: @Composable () -> Unit) {
    val lightColors: ColorScheme = lightColorScheme(
        primary = Color(0xFF007AFF),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFE3F0FF),
        onPrimaryContainer = Color(0xFF00315F),
        secondary = Color(0xFF636366),
        secondaryContainer = Color(0xFFE3F0FF),
        onSecondaryContainer = Color(0xFF00315F),
        background = Color(0xFFF5F5F7),
        surface = Color(0xFFF5F5F7),
        surfaceVariant = Color(0xFFFFFFFF),
        surfaceContainerLowest = Color(0xFFFFFFFF),
        surfaceContainerLow = Color(0xFFFFFFFF),
        surfaceContainer = Color(0xFFF5F5F7),
        surfaceContainerHigh = Color(0xFFF0F0F3),
        surfaceContainerHighest = Color(0xFFE9E9ED),
        onSurface = Color(0xFF111114),
        onSurfaceVariant = Color(0xFF5F5F66),
        outline = Color(0xFFC7C7CC),
        outlineVariant = Color(0xFFE0E0E4)
    )
    val darkColors: ColorScheme = darkColorScheme(
        primary = Color(0xFF0A84FF),
        onPrimary = Color.White,
        primaryContainer = Color(0xFF12375D),
        onPrimaryContainer = Color(0xFFDCEEFF),
        secondary = Color(0xFF98989D),
        secondaryContainer = Color(0xFF12375D),
        onSecondaryContainer = Color(0xFFDCEEFF),
        background = Color(0xFF0E0F12),
        surface = Color(0xFF0E0F12),
        surfaceVariant = Color(0xFF1D1E21),
        surfaceContainerLowest = Color(0xFF0A0B0D),
        surfaceContainerLow = Color(0xFF151619),
        surfaceContainer = Color(0xFF1A1B1E),
        surfaceContainerHigh = Color(0xFF202125),
        surfaceContainerHighest = Color(0xFF26272B),
        onSurface = Color(0xFFF7F7F7),
        onSurfaceVariant = Color(0xFFA9A9AF),
        outline = Color(0xFF48494F),
        outlineVariant = Color(0xFF2A2B2F)
    )
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColors else lightColors,
        typography = FounderTypography,
        shapes = FounderShapes,
        content = content
    )
}

@Composable
private fun OnboardingScreen(onContinue: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp, vertical = 36.dp),
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
            AssistChip(
                onClick = {},
                label = { Text("Private by default") },
                leadingIcon = { Icon(Icons.Outlined.Lock, contentDescription = null) }
            )
            Text(
                "Make the next move clear.",
                style = MaterialTheme.typography.headlineMedium.copy(fontFamily = InstrumentSerif),
                modifier = Modifier.semantics { heading() }
            )
            Text(
                "Founder’s Office keeps your Moves on this device and helps you focus on what matters now.",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OnboardingPoint("Capture a Move", "Add a clear action, priority, and optional deadline.")
            OnboardingPoint("See commitments", "Calendar access is optional and can be enabled later.")
            OnboardingPoint("Stay in control", "No account is required to start, and sign-in never uploads Moves by itself.")
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = onContinue,
                modifier = Modifier.fillMaxWidth().height(54.dp).testTag("onboarding-start")
            ) { Text("Start locally") }
            Text(
                "You can review privacy and account options in Settings.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun OnboardingPoint(title: String, detail: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun FoundersOfficeApp(viewModel: OpenLoopsViewModel, incomingData: Uri?) {
    var destination by rememberSaveable { mutableStateOf(Destination.Home) }
    var requestedMoveId by rememberSaveable { mutableStateOf<String?>(null) }
    var addMoveRequested by rememberSaveable { mutableStateOf(false) }
    val moves by viewModel.moves.collectAsStateWithLifecycle()
    val deletedMoves by viewModel.deletedMoves.collectAsStateWithLifecycle()
    val events by viewModel.calendarEvents.collectAsStateWithLifecycle()
    val notice by viewModel.notice.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(incomingData) {
        when {
            incomingData?.scheme == "openloops" && incomingData.host == "move" -> {
                destination = Destination.Moves
                requestedMoveId = incomingData.pathSegments.firstOrNull()?.takeUnless { it == "home" }
            }
            incomingData?.scheme == "openloops" && incomingData.host == "calendar" -> destination = Destination.Calendar
        }
    }
    LaunchedEffect(notice?.id) {
        val current = notice ?: return@LaunchedEffect
        val result = snackbar.showSnackbar(
            message = current.message,
            actionLabel = current.actionLabel,
            withDismissAction = current.actionLabel != null
        )
        if (result == SnackbarResult.ActionPerformed) current.action?.let(viewModel::performNoticeAction)
        viewModel.consumeNotice(current.id)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Top),
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar(
                containerColor = MaterialTheme.colorScheme.background,
                tonalElevation = 0.dp
            ) {
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
                        icon = { Icon(icon, contentDescription = null) },
                        label = { Text(item.title) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.primary,
                            selectedTextColor = MaterialTheme.colorScheme.onSurface,
                            indicatorColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
                        ),
                        modifier = Modifier.testTag("nav-${item.title.lowercase()}")
                    )
                }
            }
        }
    ) { padding ->
        when (destination) {
            Destination.Home -> HomeScreen(
                moves = moves,
                events = events,
                onAddMove = { destination = Destination.Moves; addMoveRequested = true },
                onOpenMove = { moveId ->
                    destination = Destination.Moves
                    requestedMoveId = moveId
                },
                onCompleteMove = viewModel::markDone,
                onOpenCalendar = { destination = Destination.Calendar },
                modifier = Modifier.padding(padding)
            )
            Destination.Moves -> MovesScreen(
                moves = moves,
                deletedMoves = deletedMoves,
                viewModel = viewModel,
                requestedMoveId = requestedMoveId,
                addMoveRequested = addMoveRequested,
                onRequestConsumed = { requestedMoveId = null; addMoveRequested = false },
                modifier = Modifier.padding(padding)
            )
            Destination.Calendar -> CalendarScreen(events, viewModel, Modifier.padding(padding))
            Destination.Settings -> SettingsScreen(viewModel, Modifier.padding(padding))
        }
    }
}

@Composable
private fun HomeScreen(
    moves: List<Move>,
    events: List<LocalCalendarEvent>,
    onAddMove: () -> Unit,
    onOpenMove: (String) -> Unit,
    onCompleteMove: (String) -> Unit,
    onOpenCalendar: () -> Unit,
    modifier: Modifier = Modifier
) {
    val activeMoves = moves.filter { it.status != MoveStatus.DONE }.sortedWith(moveOrdering)
    val nextMove = activeMoves.firstOrNull()
    val upNext = CalendarPresentation.upNext(events, java.time.Instant.now())
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 20.dp, top = 24.dp, end = 20.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Text(
                "FOUNDER’S OFFICE  ·  TODAY",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                letterSpacing = 0.8.sp
            )
            Text(
                "One clear next step",
                style = MaterialTheme.typography.headlineMedium.copy(fontFamily = InstrumentSerif),
                modifier = Modifier.padding(top = 6.dp).semantics { heading() }
            )
            Text(
                "Keep the office moving without the noise.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
        item {
            if (nextMove == null) {
                EmptyStateCard(
                    title = "Your desk is clear",
                    detail = "Add one Move you can advance next.",
                    actionLabel = "Add your first Move",
                    onAction = onAddMove
                )
            } else {
                NextMoveCard(
                    move = nextMove,
                    onOpen = { onOpenMove(nextMove.id) },
                    onComplete = { onCompleteMove(nextMove.id) }
                )
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CompactSignalCard(
                    label = "UP NEXT",
                    value = upNext?.title ?: "Time is clear",
                    detail = upNext?.startTimeLabel ?: "No commitment soon",
                    onClick = onOpenCalendar,
                    modifier = Modifier.weight(1f)
                )
                CompactSignalCard(
                    label = "COUNTDOWN",
                    value = countdownValue(nextMove?.dueOn),
                    detail = countdownDetail(nextMove?.dueOn),
                    onClick = nextMove?.let { { onOpenMove(it.id) } },
                    modifier = Modifier.weight(1f)
                )
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Lock,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    "Private on this device until you explicitly enable sync.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }
        }
    }
}

@Composable
private fun PageHeader(title: String, subtitle: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            "FOUNDER’S OFFICE",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            letterSpacing = 0.8.sp
        )
        Text(
            title,
            style = MaterialTheme.typography.headlineMedium.copy(fontFamily = InstrumentSerif),
            modifier = Modifier.semantics { heading() }
        )
        Text(
            subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun NextMoveCard(move: Move, onOpen: () -> Unit, onComplete: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("next-move-card")
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(width = 28.dp, height = 3.dp)
                        .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(2.dp))
                )
                Text(
                    "NEXT MOVE",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    letterSpacing = 0.8.sp,
                    modifier = Modifier.padding(start = 10.dp)
                )
                Spacer(Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Outlined.ArrowForward, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                move.title,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.11f),
                    shape = RoundedCornerShape(99.dp)
                ) {
                    Text(
                        move.priority.label,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                    )
                }
                move.dueOn?.let {
                    Text(
                        homeDueLabel(it),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 10.dp)
                    )
                }
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onComplete,
                    modifier = Modifier.semantics { contentDescription = "Complete ${move.title}" }
                ) {
                    Icon(
                        Icons.Outlined.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                }
            }
        }
    }
}

@Composable
private fun CompactSignalCard(
    label: String,
    value: String,
    detail: String,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .height(132.dp)
            .let { base -> if (onClick == null) base else base.clickable(onClick = onClick) },
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            Text(
                label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                letterSpacing = 0.7.sp
            )
            Text(
                value,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

private fun countdownValue(dueOn: LocalDate?): String {
    if (dueOn == null) return "No deadline"
    val days = ChronoUnit.DAYS.between(LocalDate.now(), dueOn)
    return when {
        days < 0 -> "${-days}d overdue"
        days == 0L -> "Today"
        days == 1L -> "Tomorrow"
        else -> "$days days"
    }
}

private fun countdownDetail(dueOn: LocalDate?): String = dueOn?.let {
    "Due ${it.format(DateTimeFormatter.ofPattern("MMM d"))}"
} ?: "Set one in Moves"

private fun homeDueLabel(dueOn: LocalDate): String = countdownDetail(dueOn)

@Composable
private fun SummaryCard(label: String, value: String, onClick: (() -> Unit)? = null) {
    Card(
        modifier = Modifier.fillMaxWidth().let { base -> if (onClick == null) base else base.clickable(onClick = onClick) },
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun EmptyStateCard(title: String, detail: String, actionLabel: String, onAction: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = onAction) { Text(actionLabel) }
        }
    }
}

@Composable
private fun MovesScreen(
    moves: List<Move>,
    deletedMoves: List<Move>,
    viewModel: OpenLoopsViewModel,
    requestedMoveId: String?,
    addMoveRequested: Boolean,
    onRequestConsumed: () -> Unit,
    modifier: Modifier = Modifier
) {
    var editingMoveId by rememberSaveable { mutableStateOf<String?>(null) }
    var adding by rememberSaveable { mutableStateOf(false) }
    var deletingMoveId by rememberSaveable { mutableStateOf<String?>(null) }
    var showDeleted by rememberSaveable { mutableStateOf(false) }
    val active = moves.filter { it.status != MoveStatus.DONE }.sortedWith(moveOrdering)
    val recentDone = moves.filter { it.status == MoveStatus.DONE }
        .sortedByDescending { it.completedAt }
        .filter { it.completedAt?.isAfter(java.time.Instant.now().minusSeconds(2 * 24 * 60 * 60)) == true }

    LaunchedEffect(requestedMoveId, addMoveRequested, moves) {
        if (addMoveRequested) adding = true
        if (requestedMoveId != null && moves.any { it.id == requestedMoveId }) editingMoveId = requestedMoveId
        if (addMoveRequested || requestedMoveId != null) onRequestConsumed()
    }

    Column(modifier = modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            PageHeader("Moves", "Choose what advances next", Modifier.weight(1f))
            Button(onClick = { adding = true }, modifier = Modifier.testTag("add-move")) { Text("Add") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 10.dp)) {
            FilterChip(selected = !showDeleted, onClick = { showDeleted = false }, label = { Text("Current") })
            FilterChip(
                selected = showDeleted,
                onClick = { showDeleted = true },
                label = { Text("Recently deleted (${deletedMoves.size})") }
            )
        }
        if (showDeleted) {
            if (deletedMoves.isEmpty()) {
                Text("No deleted Moves.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 16.dp))
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(bottom = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(deletedMoves, key = { it.id }) { move -> DeletedMoveRow(move, onRestore = { viewModel.restore(move.id) }) }
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(bottom = 20.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (active.isEmpty() && recentDone.isEmpty()) {
                    item {
                        EmptyStateCard(
                            title = "No Moves yet",
                            detail = "Start with the smallest useful next action.",
                            actionLabel = "Add a Move",
                            onAction = { adding = true }
                        )
                    }
                }
                items(active, key = { it.id }) { move ->
                    MoveRow(move, onEdit = { editingMoveId = move.id }, onToggleDone = { viewModel.markDone(move.id) })
                }
                if (recentDone.isNotEmpty()) {
                    item {
                        Text(
                            "Recent Done",
                            Modifier.padding(top = 16.dp),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                    }
                    items(recentDone, key = { it.id }) { move ->
                        MoveRow(move, onEdit = { editingMoveId = move.id }, onToggleDone = { viewModel.reopen(move.id) })
                    }
                }
            }
        }
    }

    if (adding) {
        MoveEditorDialog(
            title = "Add Move",
            existing = null,
            onDismiss = { adding = false },
            onDelete = null,
            onSave = { draft -> viewModel.addMove(draft); adding = false }
        )
    }
    moves.firstOrNull { it.id == editingMoveId }?.let { existing ->
        MoveEditorDialog(
            title = "Edit Move",
            existing = existing,
            onDismiss = { editingMoveId = null },
            onDelete = { deletingMoveId = existing.id; editingMoveId = null },
            onSave = { draft -> viewModel.editMove(existing.id, draft); editingMoveId = null }
        )
    }
    deletingMoveId?.let { moveId ->
        AlertDialog(
            onDismissRequest = { deletingMoveId = null },
            title = { Text("Delete this Move?") },
            text = { Text("You can restore it from Recently deleted.") },
            confirmButton = {
                Button(onClick = { viewModel.delete(moveId); deletingMoveId = null }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deletingMoveId = null }) { Text("Cancel") } }
        )
    }
}

@Composable
private fun MoveRow(move: Move, onEdit: () -> Unit, onToggleDone: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onEdit),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top
        ) {
            Checkbox(
                checked = move.status == MoveStatus.DONE,
                onCheckedChange = { onToggleDone() },
                modifier = Modifier.semantics {
                    contentDescription = if (move.status == MoveStatus.DONE) {
                        "Reopen ${move.title}"
                    } else {
                        "Complete ${move.title}"
                    }
                }
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    move.title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                if (move.details.isNotBlank()) {
                    Text(move.details, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    AssistChip(onClick = onEdit, label = { Text(move.priority.label) })
                    move.dueOn?.let { AssistChip(onClick = onEdit, label = { Text(it.toString()) }) }
                }
            }
        }
    }
}

@Composable
private fun DeletedMoveRow(move: Move, onRestore: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(move.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2)
                Text("Kept on this device", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onRestore) {
                Icon(Icons.Outlined.Restore, contentDescription = null)
                Text("Restore", modifier = Modifier.padding(start = 6.dp))
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
    onDelete: (() -> Unit)?,
    onSave: (MoveDraft) -> Unit
) {
    var moveTitle by remember(existing?.id) { mutableStateOf(existing?.title.orEmpty()) }
    var details by remember(existing?.id) { mutableStateOf(existing?.details.orEmpty()) }
    var dueOn by remember(existing?.id) { mutableStateOf(existing?.dueOn?.toString().orEmpty()) }
    var priority by remember(existing?.id) { mutableStateOf(existing?.priority ?: MovePriority.P2) }
    var dateError by rememberSaveable { mutableStateOf(false) }
    val titleValid = moveTitle.trim().isNotEmpty() && moveTitle.length <= 500
    val detailsValid = details.length <= 20_000
    AlertDialog(
        modifier = Modifier.imePadding(),
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item {
                    OutlinedTextField(
                        moveTitle,
                        { moveTitle = it },
                        label = { Text("Title") },
                        isError = moveTitle.isNotEmpty() && !titleValid,
                        supportingText = { if (moveTitle.length > 500) Text("Keep the title under 500 characters.") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("move-title")
                    )
                }
                item {
                    OutlinedTextField(
                        details,
                        { details = it },
                        label = { Text("Description") },
                        isError = !detailsValid,
                        supportingText = { if (!detailsValid) Text("Keep the description under 20,000 characters.") },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                item {
                    OutlinedTextField(
                        dueOn,
                        { dueOn = it; dateError = false },
                        label = { Text("Deadline") },
                        placeholder = { Text("YYYY-MM-DD") },
                        isError = dateError,
                        supportingText = { if (dateError) Text("Use a date such as 2026-09-08.") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                item {
                    Text("Priority", style = MaterialTheme.typography.labelLarge)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        MovePriority.entries.forEach { candidate ->
                            FilterChip(
                                selected = priority == candidate,
                                onClick = { priority = candidate },
                                label = { Text(candidate.wireValue) }
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = titleValid && detailsValid,
                onClick = {
                    val parsedDate = dueOn.trim().takeIf(String::isNotEmpty)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
                    dateError = dueOn.isNotBlank() && parsedDate == null
                    if (!dateError) onSave(MoveDraft(moveTitle, details, parsedDate, priority))
                },
                modifier = Modifier.testTag("save-move")
            ) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (onDelete != null) {
                    TextButton(onClick = onDelete) {
                        Icon(Icons.Outlined.DeleteOutline, contentDescription = null)
                        Text("Delete", modifier = Modifier.padding(start = 4.dp))
                    }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        }
    )
}

@Composable
private fun CalendarScreen(events: List<LocalCalendarEvent>, viewModel: OpenLoopsViewModel, modifier: Modifier = Modifier) {
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        viewModel.onCalendarPermissionResult(it)
    }
    val hasPermission = viewModel.hasCalendarPermission()
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            PageHeader("Calendar", "Upcoming commitments from calendars already connected to this device.")
        }
        item {
            Button(onClick = {
                if (hasPermission) viewModel.refreshCalendar() else permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
            }) {
                Icon(if (hasPermission) Icons.Outlined.Refresh else Icons.Outlined.CalendarMonth, contentDescription = null)
                Text(if (hasPermission) "Refresh" else "Allow calendar access", modifier = Modifier.padding(start = 8.dp))
            }
        }
        if (events.isEmpty()) {
            item {
                EmptyStateCard(
                    title = if (hasPermission) "No upcoming commitments" else "Calendar is optional",
                    detail = if (hasPermission) "Refresh after adding an event to your device calendar." else "Founder’s Office reads events only after you grant access.",
                    actionLabel = if (hasPermission) "Refresh" else "Allow access",
                    onAction = {
                        if (hasPermission) viewModel.refreshCalendar() else permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
                    }
                )
            }
        }
        items(events, key = { it.id }) { event ->
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
            ) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(event.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(event.startTimeLabel, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item {
            PageHeader("Settings", "Privacy, account, and device controls")
        }
        item {
            Text("Account & Sync", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            val status = when (availability) {
                AuthAvailability.Ready -> if (signedIn) "Signed in on this device" else "Ready for Google product sign-in"
                AuthAvailability.Unconfigured -> "Local-only mode"
                AuthAvailability.InvalidPublicConfiguration -> "Local-only: public configuration was rejected"
            }
            SummaryCard("Status", status)
        }
        if (availability == AuthAvailability.Ready) {
            item {
                if (signedIn) {
                    OutlinedButton(onClick = viewModel::signOut) { Text("Sign out on this device") }
                } else {
                    Button(onClick = viewModel::startGoogleSignIn) { Text("Sign in with Google") }
                }
            }
        }
        item {
            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
            ) {
                Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Outlined.SyncDisabled, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Sync is not enabled", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Moves remain local until the reviewed workspace setup and recovery gates are available.",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
            }
        }
        item { HorizontalDivider() }
        item {
            Text("Widget privacy", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Row(
                Modifier.fillMaxWidth().padding(top = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Hide Move and event details", modifier = Modifier.weight(1f))
                Switch(checked = widgetRedacted, onCheckedChange = viewModel::setWidgetRedacted)
            }
        }
        item { HorizontalDivider() }
        item {
            Text("About", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text("Founder’s Office ${BuildConfig.VERSION_NAME}", modifier = Modifier.padding(top = 6.dp))
            Text(
                "Calendar access is separate from product sign-in and is never copied between devices.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
    }
}

private val moveOrdering = compareBy<Move> { it.dueOn == null }
    .thenBy { it.dueOn }
    .thenBy { it.priority.ordinal }
    .thenBy { it.title.lowercase() }
