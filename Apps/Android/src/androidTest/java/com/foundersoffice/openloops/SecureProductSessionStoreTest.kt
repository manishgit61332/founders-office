package com.foundersoffice.openloops

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.foundersoffice.openloops.auth.ProductSession
import com.foundersoffice.openloops.auth.SecureProductSessionStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureProductSessionStoreTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val store = SecureProductSessionStore(context)

    @Before
    fun clearStoredSession() = runBlocking {
        assertTrue(store.clearForLogout())
    }

    @Test
    fun sessionRoundTripsWithoutPlaintextPreferences() = runBlocking {
        val session = ProductSession(
            accountId = "10000000-0000-4000-8000-000000000001",
            identityProvider = "google",
            accessToken = "synthetic-access-token",
            refreshToken = "synthetic-refresh-token"
        )

        assertTrue(store.saveSession(session))
        assertEquals(session, store.readSession())
        val storedValues = context.getSharedPreferences("product-session-v2", Context.MODE_PRIVATE)
            .all
            .values
            .joinToString()
        assertFalse(storedValues.contains(session.accessToken))
        assertFalse(storedValues.contains(session.refreshToken))

        assertTrue(store.clearForLogout())
        assertNull(store.readSession())
    }
}
