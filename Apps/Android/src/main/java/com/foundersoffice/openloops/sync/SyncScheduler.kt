package com.foundersoffice.openloops.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.foundersoffice.openloops.auth.AuthAvailability
import com.foundersoffice.openloops.auth.ProductAuthConfiguration
import com.foundersoffice.openloops.auth.SecureProductSessionStore
import java.util.concurrent.TimeUnit

/** Bounded foreground-triggered sync only; no periodic five-minute work exists. */
class SyncScheduler(
    private val context: Context,
    private val configuration: ProductAuthConfiguration,
    private val sessionStore: SecureProductSessionStore
) {
    suspend fun requestForegroundSync(): Boolean {
        if (configuration.availability != AuthAvailability.Ready || sessionStore.readSession() == null) return false
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            .addTag(SYNC_TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(SYNC_WORK_NAME, ExistingWorkPolicy.KEEP, request)
        return true
    }

    fun clearForLogout() {
        WorkManager.getInstance(context).cancelAllWorkByTag(SYNC_TAG)
    }

    private companion object {
        const val SYNC_WORK_NAME = "founders-office-explicit-sync"
        const val SYNC_TAG = "founders-office-sync"
    }
}

/**
 * A development safety gate. It is not enqueued by the current UI. Full
 * bootstrap/outbox/pull reconciliation remains disabled until the reviewed
 * server configuration and platform contract acceptance exist.
 */
class SyncWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result = Result.failure()
}
