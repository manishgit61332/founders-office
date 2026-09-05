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

sealed interface NoticeAction {
    data class RestoreMove(val moveId: String) : NoticeAction
}

data class UiNotice(
    val id: Long,
    val message: String,
    val actionLabel: String? = null,
    val action: NoticeAction? = null
)

class OpenLoopsViewModel(private val container: AppContainer) : ViewModel() {
    val moves: StateFlow<List<Move>> = container.workspaceRepository.visibleMoves.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList()
    )

    val deletedMoves: StateFlow<List<Move>> = container.workspaceRepository.deletedMoves.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList()
    )

    private val _calendarEvents = MutableStateFlow<List<LocalCalendarEvent>>(emptyList())
    val calendarEvents = _calendarEvents.asStateFlow()

    private val _notice = MutableStateFlow<UiNotice?>(null)
    val notice = _notice.asStateFlow()

    private val _onboardingComplete = MutableStateFlow(container.appPreferences.hasCompletedOnboarding)
    val onboardingComplete = _onboardingComplete.asStateFlow()

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

    fun reopen(id: String) = launchMessage("Move reopened.") {
        container.workspaceRepository.reopen(id)
    }

    fun delete(id: String) = viewModelScope.launch {
        try {
            container.workspaceRepository.delete(id)
            showNotice(
                message = "Move moved to Recently Deleted.",
                actionLabel = "Undo",
                action = NoticeAction.RestoreMove(id)
            )
        } catch (_: Exception) {
            showNotice("That local change could not be saved.")
        }
    }

    fun restore(id: String) = launchMessage("Move restored.") {
        container.workspaceRepository.restore(id)
    }

    fun refreshCalendar() = viewModelScope.launch {
        try {
            _calendarEvents.value = container.calendarRepository.refresh()
            if (_calendarEvents.value.isEmpty()) showNotice("No upcoming commitments found.")
        } catch (_: Exception) {
            _calendarEvents.value = emptyList()
            showNotice("Calendar could not be refreshed on this device.")
        }
    }

    fun onCalendarPermissionResult(granted: Boolean) {
        if (granted) refreshCalendar() else showNotice("Calendar access was not enabled.")
    }

    fun hasCalendarPermission(): Boolean = container.calendarRepository.hasPermission()

    fun startGoogleSignIn() = viewModelScope.launch {
        showNotice(when (container.productAuthGateway.start()) {
            GoogleAuthStartResult.Unconfigured -> "Google sign-in is not configured in this development build."
            GoogleAuthStartResult.ProtectedStorageUnavailable -> "Secure session storage is unavailable."
            GoogleAuthStartResult.LaunchedSystemBrowser -> "Continue sign-in in your system browser."
        })
    }

    fun handleCallback(uri: Uri?) = viewModelScope.launch {
        val callback = container.productAuthGateway.validateCallback(uri)
        if (callback !is GoogleAuthCallbackResult.ReadyToExchange) return@launch
        showNotice(when (container.productAuthGateway.exchange(callback)) {
            GoogleAuthExchangeResult.SignedIn -> {
                _signedIn.value = true
                "Signed in. Choose claim or attach explicitly before syncing."
            }
            GoogleAuthExchangeResult.Unconfigured -> "Google sign-in is not configured in this development build."
            GoogleAuthExchangeResult.Rejected -> "Sign-in could not be verified."
            GoogleAuthExchangeResult.StorageUnavailable -> "Secure session storage is unavailable."
            GoogleAuthExchangeResult.NetworkFailure -> "Sign-in needs a reachable reviewed service."
        })
    }

    fun signOut() = viewModelScope.launch {
        container.syncScheduler.clearForLogout()
        if (container.sessionStore.clearForLogout()) {
            _signedIn.value = false
            showNotice("Signed out. Local Moves remain on this device.")
        } else {
            showNotice("Secure session storage could not be cleared.")
        }
    }

    fun setWidgetRedacted(redacted: Boolean) = viewModelScope.launch {
        container.projectionStore.setRedacted(redacted)
        _widgetRedacted.value = redacted
    }

    fun completeOnboarding() {
        if (container.appPreferences.completeOnboarding()) {
            _onboardingComplete.value = true
        } else {
            showNotice("Setup could not be saved on this device.")
        }
    }

    fun performNoticeAction(action: NoticeAction) {
        when (action) {
            is NoticeAction.RestoreMove -> restore(action.moveId)
        }
    }

    fun consumeNotice(id: Long) {
        if (_notice.value?.id == id) _notice.value = null
    }

    private fun launchMessage(successMessage: String, work: suspend () -> Unit) = viewModelScope.launch {
        try {
            work()
            showNotice(successMessage)
        } catch (_: Exception) {
            showNotice("That local change could not be saved.")
        }
    }

    private fun showNotice(message: String, actionLabel: String? = null, action: NoticeAction? = null) {
        _notice.value = UiNotice(
            id = System.nanoTime(),
            message = message,
            actionLabel = actionLabel,
            action = action
        )
    }
}

class OpenLoopsViewModelFactory(private val container: AppContainer) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = OpenLoopsViewModel(container) as T
}
