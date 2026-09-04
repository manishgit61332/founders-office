package com.foundersoffice.openloops.data

import androidx.room.withTransaction
import java.time.Instant
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

enum class MovePriority(val wireValue: String, val label: String) {
    P0("P0", "Critical"),
    P1("P1", "High"),
    P2("P2", "Medium"),
    P3("P3", "Low");

    companion object {
        fun fromWire(value: String) = entries.firstOrNull { it.wireValue == value } ?: P2
    }
}

enum class MoveStatus(val wireValue: String, val label: String) {
    DOING("doing", "Doing"),
    NEXT("next", "Next"),
    BLOCKED("blocked", "Blocked"),
    DONE("done", "Done");

    companion object {
        fun fromWire(value: String) = entries.firstOrNull { it.wireValue == value } ?: NEXT
    }
}

data class Move(
    val id: String,
    val title: String,
    val details: String,
    val dueOn: LocalDate?,
    val priority: MovePriority,
    val status: MoveStatus,
    val completedAt: Instant?
)

data class MoveDraft(
    val title: String,
    val details: String,
    val dueOn: LocalDate?,
    val priority: MovePriority
)

@Serializable
internal data class MovePayload(
    val title: String,
    val details: String,
    val status: String,
    val previousStatus: String?,
    val priority: String,
    val dueOn: String?,
    val completedAt: String?,
    val source: String,
    val createdAt: String
)

/** Pure operation factory so local mutation behavior is testable without a device. */
internal class MoveOutboxOperationFactory(
    private val json: Json,
    private val nextOperationId: () -> String = { UUID.randomUUID().toString() }
) {
    fun create(move: MoveEntity, changedFields: Set<String>): OutboxOperationEntity {
        require(changedFields.isNotEmpty())
        val occurredAt = move.updatedAt
        return OutboxOperationEntity(
            operationId = nextOperationId(),
            entityType = "move",
            entityId = move.id,
            action = "upsert",
            baseRevision = move.serverRevision,
            changedFieldsJson = json.encodeToString(changedFields.sorted()),
            fieldClocksJson = json.encodeToString(changedFields.associateWith { occurredAt }),
            payloadJson = json.encodeToString(move.asPayload()),
            occurredAt = occurredAt
        )
    }
}

/**
 * Local-first Move persistence. Each successful local write atomically creates
 * a single idempotent v1-shaped outbox operation. Nothing leaves this database
 * until the customer makes an explicit provisioning decision and the reviewed
 * server adapter is available.
 */
class LocalWorkspaceRepository(
    private val database: LocalWorkspaceDatabase,
    private val projectionStore: WidgetProjectionStore,
    private val now: () -> Instant = { Instant.now() }
) {
    private val moveDao = database.moveDao()
    private val syncStateDao = database.syncStateDao()
    private val json = Json { encodeDefaults = true; explicitNulls = true }
    private val operationFactory = MoveOutboxOperationFactory(json)

    val visibleMoves: Flow<List<Move>> = moveDao.observeVisible().map { entities ->
        entities.map(::toMove)
    }

    suspend fun ensureDeviceIdentity(): String {
        val existing = syncStateDao.current()
        if (existing != null) return existing.deviceId
        val state = SyncStateEntity(deviceId = UUID.randomUUID().toString())
        syncStateDao.save(state)
        return state.deviceId
    }

    suspend fun addMove(draft: MoveDraft): Move {
        require(draft.title.trim().isNotEmpty()) { "A Move needs a title." }
        val timestamp = now().toString()
        val move = MoveEntity(
            id = UUID.randomUUID().toString(),
            title = draft.title.trim(),
            details = draft.details.trim(),
            dueOn = draft.dueOn?.toString(),
            priority = draft.priority.wireValue,
            status = MoveStatus.NEXT.wireValue,
            previousStatus = null,
            completedAt = null,
            createdAt = timestamp,
            updatedAt = timestamp
        )
        writeMove(move, changedFields = CREATE_FIELDS)
        return toMove(move)
    }

    suspend fun editMove(id: String, draft: MoveDraft): Move {
        require(draft.title.trim().isNotEmpty()) { "A Move needs a title." }
        val current = requireNotNull(moveDao.find(id)) { "The Move is no longer available." }
        val updated = current.copy(
            title = draft.title.trim(),
            details = draft.details.trim(),
            dueOn = draft.dueOn?.toString(),
            priority = draft.priority.wireValue,
            updatedAt = now().toString()
        )
        val changed = buildSet {
            if (updated.title != current.title) add("title")
            if (updated.details != current.details) add("details")
            if (updated.dueOn != current.dueOn) add("dueOn")
            if (updated.priority != current.priority) add("priority")
        }
        if (changed.isNotEmpty()) writeMove(updated, changed)
        return toMove(updated)
    }

    suspend fun markDone(id: String) {
        val current = requireNotNull(moveDao.find(id)) { "The Move is no longer available." }
        if (current.status == MoveStatus.DONE.wireValue) return
        val timestamp = now().toString()
        val updated = current.copy(
            previousStatus = current.status,
            status = MoveStatus.DONE.wireValue,
            completedAt = timestamp,
            updatedAt = timestamp
        )
        writeMove(updated, setOf("status", "previousStatus", "completedAt"))
    }

    suspend fun pendingOperationCount(): Int = database.outboxDao().pending(512).size

    private suspend fun writeMove(move: MoveEntity, changedFields: Set<String>) {
        val operation = operationFactory.create(move, changedFields)
        database.withTransaction {
            moveDao.upsert(move)
            database.outboxDao().insert(operation)
        }
        projectionStore.setNextMove(moveDao.nextActive()?.let(::toMove))
    }

    private fun toMove(entity: MoveEntity) = Move(
        id = entity.id,
        title = entity.title,
        details = entity.details,
        dueOn = entity.dueOn?.let(LocalDate::parse),
        priority = MovePriority.fromWire(entity.priority),
        status = MoveStatus.fromWire(entity.status),
        completedAt = entity.completedAt?.let(Instant::parse)
    )

    companion object {
        private val CREATE_FIELDS = setOf(
            "title", "details", "status", "priority", "dueOn", "source", "createdAt"
        )
    }
}

internal fun MoveEntity.asPayload() = MovePayload(
    title = title,
    details = details,
    status = status,
    previousStatus = previousStatus,
    priority = priority,
    dueOn = dueOn,
    completedAt = completedAt,
    source = "founders-office",
    createdAt = createdAt
)
