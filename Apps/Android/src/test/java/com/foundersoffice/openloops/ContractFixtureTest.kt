package com.foundersoffice.openloops

import com.foundersoffice.openloops.sync.BootstrapResponse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.Json

class ContractFixtureTest {
    @Test
    fun parsesTheCheckedInBootstrapFixtureWithoutChangingTheContract() {
        val fixture = requireNotNull(javaClass.classLoader?.getResourceAsStream("bootstrap.response.json"))
            .bufferedReader()
            .use { it.readText() }

        val response = Json { ignoreUnknownKeys = false }.decodeFromString(BootstrapResponse.serializer(), fixture)

        assertEquals(1, response.contractVersion)
        assertEquals(response.session.accountId, response.profile.accountId)
        assertEquals(response.session.workspaceId, response.workspace.id)
        assertEquals(0, response.startingCursor)
    }
}
