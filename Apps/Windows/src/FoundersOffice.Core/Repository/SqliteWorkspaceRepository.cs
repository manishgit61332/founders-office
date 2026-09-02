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
public sealed class SqliteWorkspaceRepository : IWorkspaceRepository
{
    private const int CurrentSchemaVersion = 1;
    private readonly string _connectionString;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
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
                """,
                cancellationToken).ConfigureAwait(false);

            if (currentVersion == 0)
            {
                await ExecuteAsync(
                    connection,
                    transaction,
                    $"PRAGMA user_version = {CurrentSchemaVersion};",
                    cancellationToken).ConfigureAwait(false);
            }

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

    public async Task CompleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
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

    public async Task SoftDeleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default)
    {
        var existing = await FindMoveAsync(moveId, cancellationToken).ConfigureAwait(false)
            ?? throw new WorkspaceRepositoryException("move_not_found");
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

    public ValueTask DisposeAsync()
    {
        _writeGate.Dispose();
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
                field => clocks.TryGetValue(field, out var value) ? value : DateTimeOffset.UtcNow);
        return JsonSerializer.Serialize(selected);
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
        value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);

    private void EnsureInitialized()
    {
        if (!_initialized)
        {
            throw new InvalidOperationException("InitializeAsync must complete before repository use.");
        }
    }
}
