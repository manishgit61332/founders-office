package com.foundersoffice.openloops

import com.foundersoffice.openloops.sync.BootstrapResponse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.Json

class ContractFixtureTest {
    private val json = Json { ignoreUnknownKeys = false }

    @Test
    fun parsesTheCheckedInBootstrapFixtureWithoutChangingTheContract() {
        val fixture = requireNotNull(javaClass.classLoader?.getResourceAsStream("bootstrap.response.json"))
            .bufferedReader()
            .use { it.readText() }

        val response = json.decodeFromString(BootstrapResponse.serializer(), fixture)

        assertEquals(1, response.contractVersion)
        assertEquals(response.session.accountId, response.profile.accountId)
        assertEquals(response.session.workspaceId, response.workspace.id)
        assertEquals(0, response.startingCursor)
    }
}
