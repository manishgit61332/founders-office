package com.foundersoffice.openloops.sync

import com.foundersoffice.openloops.auth.AuthAvailability
import com.foundersoffice.openloops.auth.ProductAuthConfiguration
import com.foundersoffice.openloops.auth.ProductSession
import com.foundersoffice.openloops.auth.SecureProductSessionStore
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

@Serializable
data class BootstrapRequest(
    @SerialName("p_local_workspace_id") val localWorkspaceId: String?,
    @SerialName("p_device_id") val deviceId: String,
    @SerialName("p_workspace_name") val workspaceName: String = "Founder's Office",
    @SerialName("p_display_name") val reviewedDisplayName: String?
)

@Serializable
data class AuthSessionIds(
    val accountId: String,
    val workspaceId: String,
    val deviceId: String,
    val identityProvider: String
)

@Serializable
data class BootstrapProfile(
    val accountId: String,
    val identityProvider: String,
    val displayName: String
)

@Serializable
data class BootstrapWorkspace(
    val id: String,
    val name: String,
    val revision: Long,
    val fieldClocks: Map<String, String>,
    val createdAt: String,
    val updatedAt: String
)

@Serializable
data class BootstrapResponse(
    val contractVersion: Int,
    val session: AuthSessionIds,
    val profile: BootstrapProfile,
    val workspace: BootstrapWorkspace,
    val startingCursor: Long,
    val latestCursor: Long
)

sealed interface RpcResult<out T> {
    data object Unconfigured : RpcResult<Nothing>
    data object NoSession : RpcResult<Nothing>
    data class Success<T>(val value: T) : RpcResult<T>
    data class Rejected(val statusCode: Int) : RpcResult<Nothing>
    data object InvalidResponse : RpcResult<Nothing>
    data object NetworkFailure : RpcResult<Nothing>
}

/**
 * A credential-free client of the checked-in v1 RPC surface. Every call is
 * authorized only with the per-device product session. It does not accept a
 * service-role key, provider secret, connector grant, or email tenancy key.
 */
class SupabaseSyncAdapter(
    private val configuration: ProductAuthConfiguration,
    private val sessionStore: SecureProductSessionStore,
    private val json: Json = Json { ignoreUnknownKeys = false }
) {
    suspend fun bootstrap(request: BootstrapRequest): RpcResult<BootstrapResponse> {
        if (configuration.availability != AuthAvailability.Ready) return RpcResult.Unconfigured
        val session = sessionStore.readSession() ?: return RpcResult.NoSession
        return post("bootstrap_workspace", json.encodeToString(BootstrapRequest.serializer(), request), session) { body ->
            json.decodeFromString<BootstrapResponse>(body).also { response ->
                require(response.contractVersion == 1)
                require(response.session.accountId == session.accountId)
                require(response.session.deviceId == request.deviceId)
                require(response.session.identityProvider == session.identityProvider)
                require(response.profile.accountId == session.accountId)
                require(response.profile.identityProvider == session.identityProvider)
                require(response.workspace.id == response.session.workspaceId)
            }
        }
    }

    suspend fun push(rawRequest: String): RpcResult<JsonElement> = callJson("push_operations", rawRequest)
    suspend fun pull(rawRequest: String): RpcResult<JsonElement> = callJson("pull_changes", rawRequest)
    suspend fun export(rawRequest: String): RpcResult<JsonElement> = callJson("export_workspace", rawRequest)
    suspend fun erase(rawRequest: String): RpcResult<JsonElement> = callJson("erase_workspace", rawRequest)

    private suspend fun callJson(path: String, rawRequest: String): RpcResult<JsonElement> {
        if (configuration.availability != AuthAvailability.Ready) return RpcResult.Unconfigured
        val session = sessionStore.readSession() ?: return RpcResult.NoSession
        return post(path, rawRequest, session) { body -> json.parseToJsonElement(body) }
    }

    private suspend fun <T> post(
        procedure: String,
        requestBody: String,
        session: ProductSession,
        decode: (String) -> T
    ): RpcResult<T> = withContext(Dispatchers.IO) {
        try {
            val connection = (URL(configuration.supabaseUrl.trimEnd('/') + "/rest/v1/rpc/$procedure").openConnection() as HttpURLConnection)
            connection.requestMethod = "POST"
            connection.connectTimeout = 10_000
            connection.readTimeout = 20_000
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer ${session.accessToken}")
            connection.setRequestProperty("apikey", configuration.publishableKey)
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.bufferedWriter(Charsets.UTF_8).use { it.write(requestBody) }
            val status = connection.responseCode
            if (status !in 200..299) return@withContext RpcResult.Rejected(status)
            val body = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { decode(body) }.fold(
                onSuccess = { RpcResult.Success(it) },
                onFailure = { RpcResult.InvalidResponse }
            )
        } catch (_: Exception) {
            RpcResult.NetworkFailure
        }
    }
}
