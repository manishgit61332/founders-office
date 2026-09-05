package com.foundersoffice.openloops.auth

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import com.foundersoffice.openloops.BuildConfig
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val PRODUCT_CALLBACK = "com.foundersoffice.openloops://auth/callback"

data class ProductAuthConfiguration(
    val supabaseUrl: String,
    val publishableKey: String,
    val googleClientId: String,
    val callbackUrl: String = PRODUCT_CALLBACK
) {
    val availability: AuthAvailability
        get() = when {
            supabaseUrl.isBlank() || publishableKey.isBlank() || googleClientId.isBlank() -> AuthAvailability.Unconfigured
            !supabaseUrl.startsWith("https://") -> AuthAvailability.InvalidPublicConfiguration
            callbackUrl != PRODUCT_CALLBACK -> AuthAvailability.InvalidPublicConfiguration
            publishableKey.contains("service_role", ignoreCase = true) -> AuthAvailability.InvalidPublicConfiguration
            else -> AuthAvailability.Ready
        }

    companion object {
        fun fromBuildConfig() = ProductAuthConfiguration(
            supabaseUrl = BuildConfig.PUBLIC_SUPABASE_URL,
            publishableKey = BuildConfig.PUBLIC_SUPABASE_KEY,
            googleClientId = BuildConfig.PUBLIC_GOOGLE_CLIENT_ID
        )
    }
}

enum class AuthAvailability {
    Unconfigured,
    InvalidPublicConfiguration,
    Ready
}

@Serializable
data class ProductSession(
    val accountId: String,
    val identityProvider: String,
    val accessToken: String,
    val refreshToken: String
)

@Serializable
internal data class PendingPkceRequest(val state: String, val verifier: String)

@Serializable
private data class EncryptedValue(val iv: String, val ciphertext: String)

/**
 * Session and PKCE material stay encrypted with an Android Keystore-backed
 * key. Connector credentials are intentionally not represented here.
 */
@SuppressLint("ApplySharedPref", "UseKtx")
class SecureProductSessionStore(context: Context) {
    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    suspend fun readSession(): ProductSession? = withContext(Dispatchers.IO) {
        preferences.getString(SESSION_KEY, null)?.let { encrypted ->
            decrypt(encrypted)?.let { encoded ->
                runCatching { json.decodeFromString<ProductSession>(encoded) }.getOrNull()
            }
        }
    }

    suspend fun saveSession(session: ProductSession): Boolean = withContext(Dispatchers.IO) {
        val encrypted = encrypt(json.encodeToString(session)) ?: return@withContext false
        preferences.edit().putString(SESSION_KEY, encrypted).commit()
    }

    /** Logout clears the product session and outstanding OAuth state, not local Moves. */
    suspend fun clearForLogout(): Boolean = withContext(Dispatchers.IO) {
        val currentCleared = preferences.edit().clear().commit()
        val legacyCleared = appContext.getSharedPreferences(LEGACY_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        currentCleared && legacyCleared
    }

    internal suspend fun savePendingPkce(request: PendingPkceRequest): Boolean = withContext(Dispatchers.IO) {
        val encrypted = encrypt(json.encodeToString(request)) ?: return@withContext false
        preferences.edit().putString(PKCE_KEY, encrypted).commit()
    }

    internal suspend fun takePendingPkce(): PendingPkceRequest? = withContext(Dispatchers.IO) {
        val encrypted = preferences.getString(PKCE_KEY, null) ?: return@withContext null
        if (!preferences.edit().remove(PKCE_KEY).commit()) return@withContext null
        decrypt(encrypted)?.let { encoded ->
            runCatching { json.decodeFromString<PendingPkceRequest>(encoded) }.getOrNull()
        }
    }

    private fun encrypt(value: String): String? = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        json.encodeToString(EncryptedValue(
            iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            ciphertext = Base64.encodeToString(encrypted, Base64.NO_WRAP)
        ))
    }.getOrNull()

    private fun decrypt(value: String): String? = runCatching {
        val encrypted = json.decodeFromString<EncryptedValue>(value)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(128, Base64.decode(encrypted.iv, Base64.NO_WRAP))
        )
        cipher.doFinal(Base64.decode(encrypted.ciphertext, Base64.NO_WRAP)).toString(Charsets.UTF_8)
    }.getOrNull()

    @Synchronized
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            generateKey()
        }
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "founders-office-product-session-v2"
        const val PREFERENCES_NAME = "product-session-v2"
        const val LEGACY_PREFERENCES_NAME = "product-session"
        const val SESSION_KEY = "session"
        const val PKCE_KEY = "pending-pkce"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

sealed interface GoogleAuthStartResult {
    data object Unconfigured : GoogleAuthStartResult
    data object LaunchedSystemBrowser : GoogleAuthStartResult
    data object ProtectedStorageUnavailable : GoogleAuthStartResult
}

sealed interface GoogleAuthCallbackResult {
    data object Ignored : GoogleAuthCallbackResult
    data object InvalidState : GoogleAuthCallbackResult
    data object MissingCode : GoogleAuthCallbackResult
    data class ReadyToExchange(val code: String, val verifier: String) : GoogleAuthCallbackResult
}

sealed interface GoogleAuthExchangeResult {
    data object SignedIn : GoogleAuthExchangeResult
    data object Unconfigured : GoogleAuthExchangeResult
    data object Rejected : GoogleAuthExchangeResult
    data object StorageUnavailable : GoogleAuthExchangeResult
    data object NetworkFailure : GoogleAuthExchangeResult
}

@Serializable
private data class ExchangeRequest(
    val auth_code: String,
    val code_verifier: String
)

@Serializable
private data class ExchangeUser(val id: String)

@Serializable
private data class ExchangeResponse(
    val access_token: String,
    val refresh_token: String,
    val user: ExchangeUser
)

/**
 * Opens Google product sign-in in the system browser with PKCE. It never uses a
 * WebView, never asks for Calendar scopes, and never treats provider metadata
 * as a workspace identity. The server exchange occurs only after an exact
 * callback validates the encrypted PKCE state.
 */
class GoogleProductAuthGateway(
    private val context: Context,
    private val configuration: ProductAuthConfiguration,
    private val sessionStore: SecureProductSessionStore
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun start(): GoogleAuthStartResult {
        if (configuration.availability != AuthAvailability.Ready) return GoogleAuthStartResult.Unconfigured
        val request = PendingPkceRequest(
            state = randomUrlSafe(24),
            verifier = randomUrlSafe(48)
        )
        if (!sessionStore.savePendingPkce(request)) return GoogleAuthStartResult.ProtectedStorageUnavailable

        val challenge = sha256UrlSafe(request.verifier)
        val url = (configuration.supabaseUrl.trimEnd('/') + "/auth/v1/authorize").toUri()
            .buildUpon()
            .appendQueryParameter("provider", "google")
            .appendQueryParameter("redirect_to", configuration.callbackUrl)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", request.state)
            .appendQueryParameter("scopes", "openid email profile")
            .build()
        CustomTabsIntent.Builder().build().launchUrl(context, url)
        return GoogleAuthStartResult.LaunchedSystemBrowser
    }

    suspend fun validateCallback(uri: Uri?): GoogleAuthCallbackResult {
        if (uri == null || uri.toString().substringBefore('?') != PRODUCT_CALLBACK) {
            return GoogleAuthCallbackResult.Ignored
        }
        val pending = sessionStore.takePendingPkce() ?: return GoogleAuthCallbackResult.InvalidState
        val state = uri.getQueryParameter("state")
        if (state == null || !constantTimeEquals(state, pending.state)) {
            return GoogleAuthCallbackResult.InvalidState
        }
        val code = uri.getQueryParameter("code") ?: return GoogleAuthCallbackResult.MissingCode
        return GoogleAuthCallbackResult.ReadyToExchange(code, pending.verifier)
    }

    suspend fun exchange(callback: GoogleAuthCallbackResult): GoogleAuthExchangeResult {
        if (configuration.availability != AuthAvailability.Ready) return GoogleAuthExchangeResult.Unconfigured
        val ready = callback as? GoogleAuthCallbackResult.ReadyToExchange ?: return GoogleAuthExchangeResult.Rejected
        return withContext(Dispatchers.IO) {
            try {
                val connection = (URL(configuration.supabaseUrl.trimEnd('/') + "/auth/v1/token?grant_type=pkce")
                    .openConnection() as HttpURLConnection)
                connection.requestMethod = "POST"
                connection.connectTimeout = 10_000
                connection.readTimeout = 20_000
                connection.doOutput = true
                connection.setRequestProperty("apikey", configuration.publishableKey)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.bufferedWriter(Charsets.UTF_8).use { writer ->
                    writer.write(json.encodeToString(ExchangeRequest(ready.code, ready.verifier)))
                }
                if (connection.responseCode !in 200..299) return@withContext GoogleAuthExchangeResult.Rejected
                val response = json.decodeFromString<ExchangeResponse>(
                    connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                )
                if (runCatching { UUID.fromString(response.user.id) }.isFailure) {
                    return@withContext GoogleAuthExchangeResult.Rejected
                }
                val saved = sessionStore.saveSession(ProductSession(
                    accountId = response.user.id,
                    identityProvider = "google",
                    accessToken = response.access_token,
                    refreshToken = response.refresh_token
                ))
                if (saved) GoogleAuthExchangeResult.SignedIn else GoogleAuthExchangeResult.StorageUnavailable
            } catch (_: Exception) {
                GoogleAuthExchangeResult.NetworkFailure
            }
        }
    }

    private fun randomUrlSafe(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun sha256UrlSafe(value: String): String = Base64.encodeToString(
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.US_ASCII)),
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
    )

    private fun constantTimeEquals(left: String, right: String): Boolean {
        val leftBytes = left.toByteArray(Charsets.UTF_8)
        val rightBytes = right.toByteArray(Charsets.UTF_8)
        return MessageDigest.isEqual(leftBytes, rightBytes)
    }
}
