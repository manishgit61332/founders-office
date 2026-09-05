package com.foundersoffice.openloops.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "moves")
data class MoveEntity(
    @PrimaryKey val id: String,
    val title: String,
    val details: String,
    val dueOn: String?,
    val priority: String,
    val status: String,
    val previousStatus: String?,
    val completedAt: String?,
    val createdAt: String,
    val updatedAt: String,
    val serverRevision: Long = 0,
    val deletedAt: String? = null
)

/** The payload mirrors a bounded v1 entity operation and never contains a token. */
@Entity(tableName = "sync_outbox")
data class OutboxOperationEntity(
    @PrimaryKey val operationId: String,
    val entityType: String,
    val entityId: String,
    val action: String,
    val baseRevision: Long,
    val changedFieldsJson: String,
    val fieldClocksJson: String,
    val payloadJson: String?,
    val occurredAt: String,
    val state: String = "pending"
)

@Entity(tableName = "sync_conflicts")
data class SyncConflictEntity(
    @PrimaryKey val operationId: String,
    val entityType: String,
    val entityId: String,
    val conflictingFieldsJson: String,
    val serverRecordJson: String?,
    val createdAt: String
)

/** One local row owns opaque identity binding and pull cursor state. */
@Entity(tableName = "sync_state")
data class SyncStateEntity(
    @PrimaryKey val id: String = CURRENT_SYNC_STATE,
    val deviceId: String,
    val accountId: String? = null,
    val workspaceId: String? = null,
    val identityProvider: String? = null,
    val cursor: Long = 0,
    val bindingState: String = "localOnly",
    val retryAttempt: Int = 0,
    val lastSuccessAt: String? = null
) {
    companion object {
        const val CURRENT_SYNC_STATE = "current"
    }
}

/** A widget reads this single bounded row, never the canonical Moves table. */
@Entity(tableName = "widget_projection")
data class WidgetProjectionEntity(
    @PrimaryKey val id: String = CURRENT_WIDGET_PROJECTION,
    val nextMoveId: String? = null,
    val nextMoveTitle: String? = null,
    val nextEventId: String? = null,
    val nextEventTitle: String? = null,
    val nextEventTime: String? = null,
    val redacted: Boolean = true,
    val updatedAt: String
) {
    companion object {
        const val CURRENT_WIDGET_PROJECTION = "current"
    }
}

@Dao
interface MoveDao {
    @Query("SELECT * FROM moves WHERE deletedAt IS NULL ORDER BY status, dueOn IS NULL, dueOn, priority, title")
    fun observeVisible(): Flow<List<MoveEntity>>

    @Query("SELECT * FROM moves WHERE deletedAt IS NOT NULL ORDER BY deletedAt DESC, title")
    fun observeDeleted(): Flow<List<MoveEntity>>

    @Query("SELECT * FROM moves WHERE id = :id LIMIT 1")
    suspend fun find(id: String): MoveEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(move: MoveEntity)

    @Query("SELECT * FROM moves WHERE deletedAt IS NULL AND status != 'done' ORDER BY dueOn IS NULL, dueOn, priority, title LIMIT 1")
    suspend fun nextActive(): MoveEntity?
}

@Dao
interface SyncStateDao {
    @Query("SELECT * FROM sync_state WHERE id = :id LIMIT 1")
    suspend fun current(id: String = SyncStateEntity.CURRENT_SYNC_STATE): SyncStateEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(state: SyncStateEntity)
}

@Dao
interface OutboxDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(operation: OutboxOperationEntity)

    @Query("SELECT * FROM sync_outbox WHERE state = 'pending' ORDER BY occurredAt ASC LIMIT :limit")
    suspend fun pending(limit: Int): List<OutboxOperationEntity>
}

@Dao
interface WidgetProjectionDao {
    @Query("SELECT * FROM widget_projection WHERE id = :id LIMIT 1")
    suspend fun current(id: String = WidgetProjectionEntity.CURRENT_WIDGET_PROJECTION): WidgetProjectionEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(projection: WidgetProjectionEntity)
}

@Database(
    entities = [MoveEntity::class, OutboxOperationEntity::class, SyncConflictEntity::class, SyncStateEntity::class, WidgetProjectionEntity::class],
    version = 1,
    exportSchema = false
)
abstract class LocalWorkspaceDatabase : RoomDatabase() {
    abstract fun moveDao(): MoveDao
    abstract fun outboxDao(): OutboxDao
    abstract fun syncStateDao(): SyncStateDao
    abstract fun widgetProjectionDao(): WidgetProjectionDao

    companion object {
        fun create(context: Context): LocalWorkspaceDatabase = Room.databaseBuilder(
            context,
            LocalWorkspaceDatabase::class.java,
            "founders-office-android.sqlite"
        ).build()
    }
}
