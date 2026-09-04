package com.foundersoffice.openloops

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.foundersoffice.openloops.auth.GoogleAuthCallbackResult
import com.foundersoffice.openloops.auth.GoogleAuthExchangeResult
import com.foundersoffice.openloops.auth.GoogleAuthStartResult
import com.foundersoffice.openloops.data.LocalCalendarEvent
import com.foundersoffice.openloops.data.Move
import com.foundersoffice.openloops.data.MoveDraft
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class OpenLoopsViewModel(private val container: AppContainer) : ViewModel() {
    val moves: StateFlow<List<Move>> = container.workspaceRepository.visibleMoves.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList()
    )

    private val _calendarEvents = MutableStateFlow<List<LocalCalendarEvent>>(emptyList())
    val calendarEvents = _calendarEvents.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    val notice = _notice.asStateFlow()

    private val _signedIn = MutableStateFlow(false)
    val signedIn = _signedIn.asStateFlow()

    private val _widgetRedacted = MutableStateFlow(false)
    val widgetRedacted = _widgetRedacted.asStateFlow()

    init {
        viewModelScope.launch {
            container.workspaceRepository.ensureDeviceIdentity()
            _signedIn.value = container.sessionStore.readSession() != null
            _widgetRedacted.value = container.projectionStore.current().redacted
        }
    }

    fun addMove(draft: MoveDraft) = launchMessage("Move added.") {
        container.workspaceRepository.addMove(draft)
    }

    fun editMove(id: String, draft: MoveDraft) = launchMessage("Move updated.") {
        container.workspaceRepository.editMove(id, draft)
    }

    fun markDone(id: String) = launchMessage("Move marked Done.") {
        container.workspaceRepository.markDone(id)
    }

    fun refreshCalendar() = viewModelScope.launch {
        _calendarEvents.value = container.calendarRepository.refresh()
        _notice.value = if (_calendarEvents.value.isEmpty()) "No upcoming commitments found." else null
    }

    fun hasCalendarPermission(): Boolean = container.calendarRepository.hasPermission()

    fun startGoogleSignIn() = viewModelScope.launch {
        _notice.value = when (container.productAuthGateway.start()) {
            GoogleAuthStartResult.Unconfigured -> "Google sign-in is not configured in this development build."
            GoogleAuthStartResult.ProtectedStorageUnavailable -> "Secure session storage is unavailable."
            GoogleAuthStartResult.LaunchedSystemBrowser -> "Continue sign-in in your system browser."
        }
    }

    fun handleCallback(uri: Uri?) = viewModelScope.launch {
        val callback = container.productAuthGateway.validateCallback(uri)
        if (callback !is GoogleAuthCallbackResult.ReadyToExchange) return@launch
        _notice.value = when (container.productAuthGateway.exchange(callback)) {
            GoogleAuthExchangeResult.SignedIn -> {
                _signedIn.value = true
                "Signed in. Choose claim or attach explicitly before syncing."
            }
            GoogleAuthExchangeResult.Unconfigured -> "Google sign-in is not configured in this development build."
            GoogleAuthExchangeResult.Rejected -> "Sign-in could not be verified."
            GoogleAuthExchangeResult.StorageUnavailable -> "Secure session storage is unavailable."
            GoogleAuthExchangeResult.NetworkFailure -> "Sign-in needs a reachable reviewed service."
        }
    }

    fun signOut() = viewModelScope.launch {
        container.syncScheduler.clearForLogout()
        if (container.sessionStore.clearForLogout()) {
            _signedIn.value = false
            _notice.value = "Signed out. Local Moves remain on this device."
        } else {
            _notice.value = "Secure session storage could not be cleared."
        }
    }

    fun setWidgetRedacted(redacted: Boolean) = viewModelScope.launch {
        container.projectionStore.setRedacted(redacted)
        _widgetRedacted.value = redacted
    }

    fun consumeNotice() {
        _notice.value = null
    }

    private fun launchMessage(successMessage: String, work: suspend () -> Unit) = viewModelScope.launch {
        try {
            work()
            _notice.value = successMessage
        } catch (_: Exception) {
            _notice.value = "That local change could not be saved."
        }
    }
}

class OpenLoopsViewModelFactory(private val container: AppContainer) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = OpenLoopsViewModel(container) as T
}
