package com.foundersoffice.openloops

import android.app.Application
import android.content.Context
import com.foundersoffice.openloops.auth.GoogleProductAuthGateway
import com.foundersoffice.openloops.auth.ProductAuthConfiguration
import com.foundersoffice.openloops.auth.SecureProductSessionStore
import com.foundersoffice.openloops.data.CalendarRepository
import com.foundersoffice.openloops.data.LocalWorkspaceDatabase
import com.foundersoffice.openloops.data.LocalWorkspaceRepository
import com.foundersoffice.openloops.data.WidgetProjectionStore
import com.foundersoffice.openloops.sync.SupabaseSyncAdapter
import com.foundersoffice.openloops.sync.SyncScheduler

class OpenLoopsApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }

    companion object {
        fun container(context: Context): AppContainer =
            (context.applicationContext as OpenLoopsApplication).container
    }
}

/**
 * The only application composition root. It deliberately receives no provider
 * secret, connector grant, personal calendar account, or server-side key.
 */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext
    private val database = LocalWorkspaceDatabase.create(appContext)

    val projectionStore = WidgetProjectionStore(appContext, database.widgetProjectionDao())
    val workspaceRepository = LocalWorkspaceRepository(
        database = database,
        projectionStore = projectionStore
    )
    val calendarRepository = CalendarRepository(appContext, projectionStore)
    val productAuthConfiguration = ProductAuthConfiguration.fromBuildConfig()
    val sessionStore = SecureProductSessionStore(appContext)
    val productAuthGateway = GoogleProductAuthGateway(
        context = appContext,
        configuration = productAuthConfiguration,
        sessionStore = sessionStore
    )
    val syncAdapter = SupabaseSyncAdapter(productAuthConfiguration, sessionStore)
    val syncScheduler = SyncScheduler(appContext, productAuthConfiguration, sessionStore)
}
