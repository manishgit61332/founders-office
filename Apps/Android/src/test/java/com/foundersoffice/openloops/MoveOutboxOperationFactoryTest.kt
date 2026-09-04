package com.foundersoffice.openloops

import com.foundersoffice.openloops.data.MoveEntity
import com.foundersoffice.openloops.data.MoveOutboxOperationFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

class MoveOutboxOperationFactoryTest {
    @Test
    fun recordsOnlyTheChangedFieldsWithAStableOperationIdentity() {
        val move = MoveEntity(
            id = "44444444-4444-4444-8444-444444444444",
            title = "Synthetic Move",
            details = "",
            dueOn = "2026-09-08",
            priority = "P1",
            status = "next",
            previousStatus = null,
            completedAt = null,
            createdAt = "2026-09-05T10:00:00Z",
            updatedAt = "2026-09-05T10:01:00Z",
            serverRevision = 7
        )

        val operation = MoveOutboxOperationFactory(
            Json { encodeDefaults = true; explicitNulls = true },
            nextOperationId = { "33333333-3333-4333-8333-333333333333" }
        ).create(move, setOf("title", "details"))

        assertEquals("33333333-3333-4333-8333-333333333333", operation.operationId)
        assertEquals(7, operation.baseRevision)
        assertEquals("[\"details\",\"title\"]", operation.changedFieldsJson)
        assertTrue(requireNotNull(operation.payloadJson).contains("Synthetic Move"))
    }
}
