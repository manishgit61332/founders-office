using System.Globalization;
using System.Text.Json;
using FoundersOffice.Core.Domain;
using Microsoft.Data.Sqlite;

namespace FoundersOffice.Core.Repository;

/// <summary>
/// Serialized, offline-first Windows store. Every local canonical mutation and
/// its outbox operation share one SQLite transaction. Provider credentials are
/// deliberately outside this database and belong in Windows Credential Locker.
/// </summary>
public sealed class SqliteWorkspaceRepository : IWorkspaceRepository, IDisposable
{
    private const int CurrentSchemaVersion = 2;
    private readonly string _connectionString;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private bool _disposed;
    private bool _initialized;

    public SqliteWorkspaceRepository(string databasePath)
    {
        if (string.IsNullOrWhiteSpace(databasePath))
        {
            throw new ArgumentException("A database path is required.", nameof(databasePath));
        }

        var parent = Path.GetDirectoryName(databasePath);
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }

        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = true,
        }.ToString();
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_initialized)
            {
                return;
            }

            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

            var currentVersion = await ReadSchemaVersionAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
            if (currentVersion > CurrentSchemaVersion)
            {
                throw new WorkspaceRepositoryException("workspace_schema_newer_than_client");
            }

            await ExecuteAsync(
                connection,
                transaction,
                """
                CREATE TABLE IF NOT EXISTS moves (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    details TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('doing', 'next', 'blocked', 'done')),
                    previous_status TEXT NULL CHECK (previous_status IS NULL OR previous_status IN ('doing', 'next', 'blocked', 'done')),
                    priority TEXT NOT NULL CHECK (priority IN ('P0', 'P1', 'P2', 'P3')),
                    due_on TEXT NULL,
                    completed_at TEXT NULL,
                    deleted_at TEXT NULL,
                    source TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK (revision >= 0),
                    field_clocks_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS moves_surface_index
                    ON moves(deleted_at, status, priority, due_on, updated_at);

                CREATE TABLE IF NOT EXISTS sync_outbox (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    action TEXT NOT NULL CHECK (action IN ('upsert', 'delete')),
                    base_revision INTEGER NOT NULL CHECK (base_revision >= 0),
                    changed_fields_json TEXT NOT NULL,
                    field_clocks_json TEXT NOT NULL,
                    payload_json TEXT NULL,
                    occurred_at TEXT NOT NULL,
                    delivery_state TEXT NOT NULL DEFAULT 'pending' CHECK (delivery_state IN ('pending', 'quarantined'))
                );

                CREATE INDEX IF NOT EXISTS sync_outbox_pending_index
                    ON sync_outbox(delivery_state, occurred_at, operation_id);

                CREATE TABLE IF NOT EXISTS workspace_sync_state (
                    singleton_id INTEGER PRIMARY KEY NOT NULL CHECK (singleton_id = 1),
                    local_workspace_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    account_id TEXT NULL,
                    remote_workspace_id TEXT NULL,
                    identity_provider TEXT NULL CHECK (identity_provider IS NULL OR identity_provider IN ('google', 'apple')),
                    cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
                    CHECK ((account_id IS NULL AND remote_workspace_id IS NULL AND identity_provider IS NULL) OR
                           (account_id IS NOT NULL AND remote_workspace_id IS NOT NULL AND identity_provider IS NOT NULL))
                );

                CREATE TABLE IF NOT EXISTS sync_inbox (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    cursor INTEGER NOT NULL UNIQUE CHECK (cursor > 0),
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL
                );
                """,
                cancellationToken).ConfigureAwait(false);

            await EnsureSyncStateRowAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
            await ExecuteAsync(
                connection,
                transaction,
                $"PRAGMA user_version = {CurrentSchemaVersion};",
                cancellationToken).ConfigureAwait(false);

            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            _initialized = true;
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("workspace_initialize_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task<WorkspaceSnapshot> SnapshotAsync(CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT id, title, details, status, previous_status, priority, due_on,
                       completed_at, deleted_at, source, revision, field_clocks_json,
                       created_at, updated_at
                FROM moves
                WHERE deleted_at IS NULL
                ORDER BY
                    CASE status WHEN 'doing' THEN 0 WHEN 'next' THEN 1 WHEN 'blocked' THEN 2 ELSE 3 END,
                    CASE priority WHEN 'P0' THEN 0 WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
                    CASE WHEN due_on IS NULL THEN 1 ELSE 0 END,
                    due_on,
                    updated_at DESC;
                """;

            var moves = new List<Move>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                moves.Add(ReadMove(reader));
            }

            await reader.DisposeAsync().ConfigureAwait(false);
            await using var countCommand = connection.CreateCommand();
            countCommand.CommandText = "SELECT COUNT(*) FROM sync_outbox WHERE delivery_state = 'pending';";
            var pending = Convert.ToInt32(
                await countCommand.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
                CultureInfo.InvariantCulture);

            return new WorkspaceSnapshot(moves, pending, DateTimeOffset.UtcNow);
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("workspace_snapshot_failed", exception);
        }
    }

    public Task UpsertMoveAsync(Move move, CancellationToken cancellationToken = default)
    {
        move.Validate();
        var now = DateTimeOffset.UtcNow;
        var changedFields = new[]
        {
            "title", "details", "status", "previousStatus", "priority", "dueOn",
            "completedAt", "source", "createdAt",
        };
        var clocks = changedFields.ToDictionary(field => field, _ => now);
        var localMove = move with { FieldClocks = clocks, UpdatedAt = now };
        return PersistLocalMutationAsync(localMove, "upsert", changedFields, BuildMovePayload(localMove), cancellationToken);
    }

    public async Task UpdateMoveAsync(
        Guid moveId,
        string title,
        string details,
        MovePriority priority,
        DateOnly? dueOn,
        CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
        EnsureMutable(existing);

        var updated = existing with
        {
            Title = title.Trim(),
            Details = details.Trim(),
            Priority = priority,
            DueOn = dueOn,
        };
        updated.Validate();

        var changedFields = new List<string>(4);
        if (!string.Equals(existing.Title, updated.Title, StringComparison.Ordinal))
        {
            changedFields.Add("title");
        }

        if (!string.Equals(existing.Details, updated.Details, StringComparison.Ordinal))
        {
            changedFields.Add("details");
        }

        if (existing.Priority != updated.Priority)
        {
            changedFields.Add("priority");
        }

        if (existing.DueOn != updated.DueOn)
        {
            changedFields.Add("dueOn");
        }

        if (changedFields.Count == 0)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var clocks = new Dictionary<string, DateTimeOffset>(existing.FieldClocks);
        foreach (var field in changedFields)
        {
            clocks[field] = now;
        }

        updated = updated with { UpdatedAt = now, FieldClocks = clocks };
        await PersistLocalMutationAsync(
                updated,
                "upsert",
                changedFields,
                BuildMovePayload(updated, changedFields),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task CompleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
        EnsureMutable(existing);
        if (existing.Status == MoveStatus.Done)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var clocks = new Dictionary<string, DateTimeOffset>(existing.FieldClocks)
        {
            ["status"] = now,
            ["previousStatus"] = now,
            ["completedAt"] = now,
        };
        var completed = existing with
        {
            PreviousStatus = existing.Status,
            Status = MoveStatus.Done,
            CompletedAt = now,
            UpdatedAt = now,
            FieldClocks = clocks,
        };
        var fields = new[] { "status", "previousStatus", "completedAt" };
        await PersistLocalMutationAsync(completed, "upsert", fields, BuildMovePayload(completed, fields), cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ReopenMoveAsync(Guid moveId, CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
        EnsureMutable(existing);
        if (existing.Status != MoveStatus.Done)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var clocks = new Dictionary<string, DateTimeOffset>(existing.FieldClocks)
        {
            ["status"] = now,
            ["previousStatus"] = now,
            ["completedAt"] = now,
        };
        var reopened = existing with
        {
            Status = existing.PreviousStatus is MoveStatus.Doing or MoveStatus.Next or MoveStatus.Blocked
                ? existing.PreviousStatus.Value
                : MoveStatus.Doing,
            PreviousStatus = null,
            CompletedAt = null,
            UpdatedAt = now,
            FieldClocks = clocks,
        };
        var fields = new[] { "status", "previousStatus", "completedAt" };
        await PersistLocalMutationAsync(reopened, "upsert", fields, BuildMovePayload(reopened, fields), cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task SoftDeleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
        if (existing.IsDeleted)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var clocks = new Dictionary<string, DateTimeOffset>(existing.FieldClocks)
        {
            ["deletedAt"] = now,
        };
        var deleted = existing with { DeletedAt = now, UpdatedAt = now, FieldClocks = clocks };
        await PersistLocalMutationAsync(deleted, "delete", ["deletedAt"], null, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ApplyRemoteMoveAsync(Move move, CancellationToken cancellationToken = default)
    {
        move.Validate();
        EnsureInitialized();
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
            await UpsertMoveRowAsync(connection, transaction, move, cancellationToken).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("remote_move_apply_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task<IReadOnlyList<PendingSyncOperation>> PendingOperationsAsync(
        int limit = 100,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        if (limit is < 1 or > 1_000)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT operation_id, entity_id, entity_type, action, base_revision,
                   changed_fields_json, field_clocks_json, payload_json, occurred_at
            FROM sync_outbox
            WHERE delivery_state = 'pending'
            ORDER BY occurred_at, operation_id
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$limit", limit);

        var operations = new List<PendingSyncOperation>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            operations.Add(new PendingSyncOperation(
                Guid.Parse(reader.GetString(0)),
                Guid.Parse(reader.GetString(1)),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetInt64(4),
                reader.GetString(5),
                reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetString(7),
                ParseTimestamp(reader.GetString(8))));
        }

        return operations;
    }

    public async Task<WorkspaceSyncState> SyncStateAsync(CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        return await ReadSyncStateAsync(connection, transaction: null, cancellationToken).ConfigureAwait(false);
    }

    public async Task BindWorkspaceAsync(
        Guid accountId,
        Guid remoteWorkspaceId,
        Guid deviceId,
        string identityProvider,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        if (accountId == Guid.Empty || remoteWorkspaceId == Guid.Empty || deviceId == Guid.Empty ||
            identityProvider is not ("google" or "apple"))
        {
            throw new ArgumentException("A complete reviewed workspace binding is required.");
        }

        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
            var state = await ReadSyncStateAsync(connection, transaction, cancellationToken).ConfigureAwait(false);

            if (state.DeviceId != deviceId)
            {
                throw new WorkspaceRepositoryException("workspace_device_mismatch");
            }

            if (state.IsBound && state.AccountId != accountId)
            {
                throw new WorkspaceRepositoryException("workspace_account_mismatch");
            }

            if (state.IsBound && state.RemoteWorkspaceId != remoteWorkspaceId)
            {
                throw new WorkspaceRepositoryException("workspace_remote_identity_mismatch");
            }

            if (state.IsBound && !string.Equals(state.IdentityProvider, identityProvider, StringComparison.Ordinal))
            {
                throw new WorkspaceRepositoryException("workspace_provider_mismatch");
            }

            if (!state.IsBound && state.HasLocalData && state.LocalWorkspaceId != remoteWorkspaceId)
            {
                throw new WorkspaceRepositoryException("workspace_attachment_requires_review");
            }

            await using var command = connection.CreateCommand();
            command.Transaction = (SqliteTransaction)transaction;
            command.CommandText = """
                UPDATE workspace_sync_state
                SET account_id = $account_id,
                    remote_workspace_id = $remote_workspace_id,
                    identity_provider = $identity_provider
                WHERE singleton_id = 1;
                """;
            command.Parameters.AddWithValue("$account_id", accountId.ToString("D"));
            command.Parameters.AddWithValue("$remote_workspace_id", remoteWorkspaceId.ToString("D"));
            command.Parameters.AddWithValue("$identity_provider", identityProvider);
            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("workspace_bind_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task AcknowledgeOperationAsync(
        Guid operationId,
        Guid entityId,
        long revision,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        if (operationId == Guid.Empty || entityId == Guid.Empty || revision < 1)
        {
            throw new ArgumentException("A valid operation acknowledgement is required.");
        }

        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

            await using var find = connection.CreateCommand();
            find.Transaction = (SqliteTransaction)transaction;
            find.CommandText = """
                SELECT entity_id, entity_type
                FROM sync_outbox
                WHERE operation_id = $operation_id AND delivery_state = 'pending';
                """;
            find.Parameters.AddWithValue("$operation_id", operationId.ToString("D"));
            await using var reader = await find.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                throw new WorkspaceRepositoryException("sync_operation_not_pending");
            }

            var storedEntityId = Guid.Parse(reader.GetString(0));
            var entityType = reader.GetString(1);
            await reader.DisposeAsync().ConfigureAwait(false);
            if (storedEntityId != entityId)
            {
                throw new WorkspaceRepositoryException("sync_operation_entity_mismatch");
            }

            await using var delete = connection.CreateCommand();
            delete.Transaction = (SqliteTransaction)transaction;
            delete.CommandText = "DELETE FROM sync_outbox WHERE operation_id = $operation_id;";
            delete.Parameters.AddWithValue("$operation_id", operationId.ToString("D"));
            await delete.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);

            if (entityType == "move")
            {
                await using var updateMove = connection.CreateCommand();
                updateMove.Transaction = (SqliteTransaction)transaction;
                updateMove.CommandText = "UPDATE moves SET revision = $revision WHERE id = $entity_id;";
                updateMove.Parameters.AddWithValue("$revision", revision);
                updateMove.Parameters.AddWithValue("$entity_id", entityId.ToString("D"));
                await updateMove.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);

                await using var rebase = connection.CreateCommand();
                rebase.Transaction = (SqliteTransaction)transaction;
                rebase.CommandText = """
                    UPDATE sync_outbox
                    SET base_revision = $revision
                    WHERE entity_id = $entity_id AND delivery_state = 'pending';
                    """;
                rebase.Parameters.AddWithValue("$revision", revision);
                rebase.Parameters.AddWithValue("$entity_id", entityId.ToString("D"));
                await rebase.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }

            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("sync_acknowledgement_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task QuarantineOperationAsync(
        Guid operationId,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        if (operationId == Guid.Empty)
        {
            throw new ArgumentException("A valid operation ID is required.", nameof(operationId));
        }

        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE sync_outbox
                SET delivery_state = 'quarantined'
                WHERE operation_id = $operation_id AND delivery_state = 'pending';
                """;
            command.Parameters.AddWithValue("$operation_id", operationId.ToString("D"));
            if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
            {
                throw new WorkspaceRepositoryException("sync_operation_not_pending");
            }
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("sync_quarantine_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public async Task ApplyPullPageAsync(
        Guid workspaceId,
        long fromCursor,
        long nextCursor,
        IReadOnlyList<RemoteWorkspaceChange> changes,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        if (workspaceId == Guid.Empty || fromCursor < 0 || nextCursor < fromCursor)
        {
            throw new ArgumentException("A valid pull page boundary is required.");
        }

        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
            var state = await ReadSyncStateAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
            if (state.RemoteWorkspaceId != workspaceId)
            {
                throw new WorkspaceRepositoryException("pull_workspace_mismatch");
            }

            if (state.Cursor != fromCursor)
            {
                throw new WorkspaceRepositoryException("pull_cursor_stale");
            }

            long priorCursor = fromCursor;
            foreach (var change in changes)
            {
                if (change.Cursor <= priorCursor || change.Cursor > nextCursor ||
                    change.OperationId == Guid.Empty || change.EntityId == Guid.Empty)
                {
                    throw new WorkspaceRepositoryException("pull_change_invalid");
                }

                if (change.EntityType != "move" || change.Move is null)
                {
                    throw new WorkspaceRepositoryException("pull_entity_unsupported");
                }

                await using var pending = connection.CreateCommand();
                pending.Transaction = (SqliteTransaction)transaction;
                pending.CommandText = """
                    SELECT COUNT(*) FROM sync_outbox
                    WHERE entity_type = $entity_type AND entity_id = $entity_id AND delivery_state = 'pending';
                    """;
                pending.Parameters.AddWithValue("$entity_type", change.EntityType);
                pending.Parameters.AddWithValue("$entity_id", change.EntityId.ToString("D"));
                var pendingCount = Convert.ToInt32(
                    await pending.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
                    CultureInfo.InvariantCulture);
                if (pendingCount != 0)
                {
                    throw new WorkspaceRepositoryException("pull_change_has_pending_local_edit");
                }

                if (change.Move.Id != change.EntityId)
                {
                    throw new WorkspaceRepositoryException("pull_move_identity_mismatch");
                }

                await UpsertMoveRowAsync(connection, transaction, change.Move.Validate(), cancellationToken)
                    .ConfigureAwait(false);

                await using var inbox = connection.CreateCommand();
                inbox.Transaction = (SqliteTransaction)transaction;
                inbox.CommandText = """
                    INSERT INTO sync_inbox(operation_id, cursor, entity_type, entity_id)
                    VALUES($operation_id, $cursor, $entity_type, $entity_id);
                    """;
                inbox.Parameters.AddWithValue("$operation_id", change.OperationId.ToString("D"));
                inbox.Parameters.AddWithValue("$cursor", change.Cursor);
                inbox.Parameters.AddWithValue("$entity_type", change.EntityType);
                inbox.Parameters.AddWithValue("$entity_id", change.EntityId.ToString("D"));
                await inbox.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
                priorCursor = change.Cursor;
            }

            if ((changes.Count == 0 && nextCursor != fromCursor) ||
                (changes.Count > 0 && priorCursor != nextCursor))
            {
                throw new WorkspaceRepositoryException("pull_page_boundary_invalid");
            }

            await using var advance = connection.CreateCommand();
            advance.Transaction = (SqliteTransaction)transaction;
            advance.CommandText = "UPDATE workspace_sync_state SET cursor = $cursor WHERE singleton_id = 1;";
            advance.Parameters.AddWithValue("$cursor", nextCursor);
            await advance.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("pull_page_apply_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _writeGate.Dispose();
        GC.SuppressFinalize(this);
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task PersistLocalMutationAsync(
        Move move,
        string action,
        IReadOnlyList<string> changedFields,
        string? payloadJson,
        CancellationToken cancellationToken)
    {
        EnsureInitialized();
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
            await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
            await UpsertMoveRowAsync(connection, transaction, move, cancellationToken).ConfigureAwait(false);

            await using var operation = connection.CreateCommand();
            operation.Transaction = (SqliteTransaction)transaction;
            operation.CommandText = """
                INSERT INTO sync_outbox(
                    operation_id, entity_type, entity_id, action, base_revision,
                    changed_fields_json, field_clocks_json, payload_json, occurred_at, delivery_state)
                VALUES(
                    $operation_id, 'move', $entity_id, $action, $base_revision,
                    $changed_fields_json, $field_clocks_json, $payload_json, $occurred_at, 'pending');
                """;
            operation.Parameters.AddWithValue("$operation_id", Guid.NewGuid().ToString("D"));
            operation.Parameters.AddWithValue("$entity_id", move.Id.ToString("D"));
            operation.Parameters.AddWithValue("$action", action);
            operation.Parameters.AddWithValue("$base_revision", move.Revision);
            operation.Parameters.AddWithValue("$changed_fields_json", JsonSerializer.Serialize(changedFields));
            operation.Parameters.AddWithValue("$field_clocks_json", SerializeFieldClocks(move.FieldClocks, changedFields));
            operation.Parameters.AddWithValue("$payload_json", (object?)payloadJson ?? DBNull.Value);
            operation.Parameters.AddWithValue("$occurred_at", FormatTimestamp(move.UpdatedAt));
            await operation.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);

            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (WorkspaceRepositoryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new WorkspaceRepositoryException("workspace_mutation_failed", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task<Move?> FindMoveAsync(Guid moveId, CancellationToken cancellationToken)
    {
        EnsureInitialized();
        await using var connection = await OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id, title, details, status, previous_status, priority, due_on,
                   completed_at, deleted_at, source, revision, field_clocks_json,
                   created_at, updated_at
            FROM moves WHERE id = $id;
            """;
        command.Parameters.AddWithValue("$id", moveId.ToString("D"));
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ? ReadMove(reader) : null;
    }

    private static async Task UpsertMoveRowAsync(
        SqliteConnection connection,
        System.Data.Common.DbTransaction transaction,
        Move move,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = (SqliteTransaction)transaction;
        command.CommandText = """
            INSERT INTO moves(
                id, title, details, status, previous_status, priority, due_on,
                completed_at, deleted_at, source, revision, field_clocks_json,
                created_at, updated_at)
            VALUES(
                $id, $title, $details, $status, $previous_status, $priority, $due_on,
                $completed_at, $deleted_at, $source, $revision, $field_clocks_json,
                $created_at, $updated_at)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                details = excluded.details,
                status = excluded.status,
                previous_status = excluded.previous_status,
                priority = excluded.priority,
                due_on = excluded.due_on,
                completed_at = excluded.completed_at,
                deleted_at = excluded.deleted_at,
                source = excluded.source,
                revision = excluded.revision,
                field_clocks_json = excluded.field_clocks_json,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """;
        command.Parameters.AddWithValue("$id", move.Id.ToString("D"));
        command.Parameters.AddWithValue("$title", move.Title);
        command.Parameters.AddWithValue("$details", move.Details);
        command.Parameters.AddWithValue("$status", ToWire(move.Status));
        command.Parameters.AddWithValue("$previous_status", move.PreviousStatus is null ? DBNull.Value : ToWire(move.PreviousStatus.Value));
        command.Parameters.AddWithValue("$priority", move.Priority.ToString());
        command.Parameters.AddWithValue("$due_on", move.DueOn is null ? DBNull.Value : move.DueOn.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        command.Parameters.AddWithValue("$completed_at", move.CompletedAt is null ? DBNull.Value : FormatTimestamp(move.CompletedAt.Value));
        command.Parameters.AddWithValue("$deleted_at", move.DeletedAt is null ? DBNull.Value : FormatTimestamp(move.DeletedAt.Value));
        command.Parameters.AddWithValue("$source", move.Source);
        command.Parameters.AddWithValue("$revision", move.Revision);
        command.Parameters.AddWithValue("$field_clocks_json", SerializeFieldClocks(move.FieldClocks));
        command.Parameters.AddWithValue("$created_at", FormatTimestamp(move.CreatedAt));
        command.Parameters.AddWithValue("$updated_at", FormatTimestamp(move.UpdatedAt));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    private static Move ReadMove(SqliteDataReader reader)
    {
        var clocks = JsonSerializer.Deserialize<Dictionary<string, DateTimeOffset>>(reader.GetString(11))
            ?? new Dictionary<string, DateTimeOffset>();
        return new Move(
            Guid.Parse(reader.GetString(0)),
            reader.GetString(1),
            reader.GetString(2),
            ParseStatus(reader.GetString(3)),
            reader.IsDBNull(4) ? null : ParseStatus(reader.GetString(4)),
            Enum.Parse<MovePriority>(reader.GetString(5), ignoreCase: false),
            reader.IsDBNull(6) ? null : DateOnly.ParseExact(reader.GetString(6), "yyyy-MM-dd", CultureInfo.InvariantCulture),
            reader.IsDBNull(7) ? null : ParseTimestamp(reader.GetString(7)),
            reader.IsDBNull(8) ? null : ParseTimestamp(reader.GetString(8)),
            reader.GetString(9),
            reader.GetInt64(10),
            clocks,
            ParseTimestamp(reader.GetString(12)),
            ParseTimestamp(reader.GetString(13)));
    }

    private static string BuildMovePayload(Move move, IReadOnlyList<string>? fields = null)
    {
        var include = fields?.ToHashSet(StringComparer.Ordinal);
        var payload = new Dictionary<string, object?>();

        void Add(string name, object? value)
        {
            if (include is null || include.Contains(name))
            {
                payload[name] = value;
            }
        }

        Add("title", move.Title);
        Add("details", move.Details);
        Add("status", ToWire(move.Status));
        Add("previousStatus", move.PreviousStatus is null ? null : ToWire(move.PreviousStatus.Value));
        Add("priority", move.Priority.ToString());
        Add("dueOn", move.DueOn?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        Add("completedAt", move.CompletedAt is null ? null : FormatTimestamp(move.CompletedAt.Value));
        Add("source", move.Source);
        Add("createdAt", FormatTimestamp(move.CreatedAt));
        return JsonSerializer.Serialize(payload);
    }

    private static string SerializeFieldClocks(
        IReadOnlyDictionary<string, DateTimeOffset> clocks,
        IReadOnlyList<string>? fields = null)
    {
        var selected = fields is null
            ? clocks
            : fields.ToDictionary(
                field => field,
                field => clocks.TryGetValue(field, out var value)
                    ? value
                    : throw new WorkspaceRepositoryException("move_field_clock_missing"));
        return JsonSerializer.Serialize(selected);
    }

    private static async Task EnsureSyncStateRowAsync(
        SqliteConnection connection,
        System.Data.Common.DbTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = (SqliteTransaction)transaction;
        command.CommandText = """
            INSERT OR IGNORE INTO workspace_sync_state(
                singleton_id, local_workspace_id, device_id, account_id,
                remote_workspace_id, identity_provider, cursor)
            VALUES(1, $local_workspace_id, $device_id, NULL, NULL, NULL, 0);
            """;
        command.Parameters.AddWithValue("$local_workspace_id", Guid.NewGuid().ToString("D"));
        command.Parameters.AddWithValue("$device_id", Guid.NewGuid().ToString("D"));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<WorkspaceSyncState> ReadSyncStateAsync(
        SqliteConnection connection,
        System.Data.Common.DbTransaction? transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction as SqliteTransaction;
        command.CommandText = """
            SELECT local_workspace_id, device_id, account_id, remote_workspace_id,
                   identity_provider, cursor,
                   EXISTS(SELECT 1 FROM moves) OR EXISTS(SELECT 1 FROM sync_outbox)
            FROM workspace_sync_state
            WHERE singleton_id = 1;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            throw new WorkspaceRepositoryException("workspace_sync_state_missing");
        }

        return new WorkspaceSyncState(
            Guid.Parse(reader.GetString(0)),
            Guid.Parse(reader.GetString(1)),
            reader.IsDBNull(2) ? null : Guid.Parse(reader.GetString(2)),
            reader.IsDBNull(3) ? null : Guid.Parse(reader.GetString(3)),
            reader.IsDBNull(4) ? null : reader.GetString(4),
            reader.GetInt64(5),
            reader.GetBoolean(6));
    }

    private async Task<SqliteConnection> OpenConnectionAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;";
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return connection;
    }

    private static async Task<int> ReadSchemaVersionAsync(
        SqliteConnection connection,
        System.Data.Common.DbTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = (SqliteTransaction)transaction;
        command.CommandText = "PRAGMA user_version;";
        return Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
            CultureInfo.InvariantCulture);
    }

    private static async Task ExecuteAsync(
        SqliteConnection connection,
        System.Data.Common.DbTransaction transaction,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = (SqliteTransaction)transaction;
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    private static string ToWire(MoveStatus status) => status switch
    {
        MoveStatus.Doing => "doing",
        MoveStatus.Next => "next",
        MoveStatus.Blocked => "blocked",
        MoveStatus.Done => "done",
        _ => throw new ArgumentOutOfRangeException(nameof(status)),
    };

    private static MoveStatus ParseStatus(string value) => value switch
    {
        "doing" => MoveStatus.Doing,
        "next" => MoveStatus.Next,
        "blocked" => MoveStatus.Blocked,
        "done" => MoveStatus.Done,
        _ => throw new WorkspaceRepositoryException("move_status_invalid"),
    };

    private static string FormatTimestamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", CultureInfo.InvariantCulture);

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);

    private static void EnsureMutable(Move move)
    {
        if (move.IsDeleted)
        {
            throw new WorkspaceRepositoryException("move_deleted");
        }
    }

    private void EnsureInitialized()
    {
        if (!_initialized)
        {
            throw new InvalidOperationException("InitializeAsync must complete before repository use.");
        }
    }
}
