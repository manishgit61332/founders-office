using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;
using Microsoft.Data.Sqlite;
using System.Globalization;

namespace FoundersOffice.Core.Tests;

public sealed class SqliteWorkspaceRepositoryTests
{
    [Fact]
    public async Task UpsertPersistsMoveAndMatchingOutboxOperationAtomically()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var move = Move.Create(
            "Prepare the release note",
            "Keep the explanation short.",
            MovePriority.P0,
            new DateOnly(2026, 9, 3),
            DateTimeOffset.Parse("2026-09-02T08:00:00Z", CultureInfo.InvariantCulture));

        await fixture.Repository.UpsertMoveAsync(move);

        var snapshot = await fixture.Repository.SnapshotAsync();
        var operation = Assert.Single(await fixture.Repository.PendingOperationsAsync());
        var persisted = Assert.Single(snapshot.Moves);
        Assert.Equal(move.Id, persisted.Id);
        Assert.Equal("Prepare the release note", persisted.Title);
        Assert.Equal(new DateOnly(2026, 9, 3), persisted.DueOn);
        Assert.Equal(1, snapshot.PendingOperationCount);
        Assert.Equal(move.Id, operation.EntityId);
        Assert.Equal("move", operation.EntityType);
        Assert.Equal("upsert", operation.Action);
        Assert.Contains("\"details\"", operation.ChangedFieldsJson, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CompleteAndDeleteKeepHistoryButRemoveDeletedMoveFromSurface()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var move = Move.Create("Review the build");
        await fixture.Repository.UpsertMoveAsync(move);

        await fixture.Repository.CompleteMoveAsync(move.Id);
        var completed = Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
        Assert.Equal(MoveStatus.Done, completed.Status);
        Assert.NotNull(completed.CompletedAt);

        await fixture.Repository.SoftDeleteMoveAsync(move.Id);
        Assert.Empty((await fixture.Repository.SnapshotAsync()).Moves);
        var operations = await fixture.Repository.PendingOperationsAsync();
        Assert.Equal(3, operations.Count);
        Assert.Equal("delete", operations[^1].Action);
        Assert.Null(operations[^1].PayloadJson);
    }

    [Fact]
    public async Task EditChangesOnlySelectedFieldsAndPreservesMoveState()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var move = Move.Create("Draft title", "Draft details");
        await fixture.Repository.UpsertMoveAsync(move);

        await fixture.Repository.UpdateMoveAsync(
            move.Id,
            "Final title",
            "Final details",
            MovePriority.P0,
            new DateOnly(2026, 9, 12));

        var updated = Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
        Assert.Equal("Final title", updated.Title);
        Assert.Equal("Final details", updated.Details);
        Assert.Equal(MovePriority.P0, updated.Priority);
        Assert.Equal(new DateOnly(2026, 9, 12), updated.DueOn);
        Assert.Equal(MoveStatus.Doing, updated.Status);

        var operations = await fixture.Repository.PendingOperationsAsync();
        Assert.Equal(2, operations.Count);
        Assert.Equal(
            "[\"title\",\"details\",\"priority\",\"dueOn\"]",
            operations[^1].ChangedFieldsJson);
        Assert.DoesNotContain("\"status\"", operations[^1].PayloadJson, StringComparison.Ordinal);
        Assert.Contains("\"dueOn\":\"2026-09-12\"", operations[^1].PayloadJson, StringComparison.Ordinal);
    }

    [Fact]
    public async Task EditingWithoutChangesDoesNotCreateAnotherOperation()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var move = Move.Create("No changes", "Same details", MovePriority.P2);
        await fixture.Repository.UpsertMoveAsync(move);

        await fixture.Repository.UpdateMoveAsync(
            move.Id,
            " No changes ",
            " Same details ",
            MovePriority.P2,
            null);

        Assert.Single(await fixture.Repository.PendingOperationsAsync());
    }

    [Fact]
    public async Task CompletedMoveCanReturnFromHistory()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var move = Move.Create("Reopen this", priority: MovePriority.P3);
        await fixture.Repository.UpsertMoveAsync(move);
        await fixture.Repository.CompleteMoveAsync(move.Id);

        await fixture.Repository.ReopenMoveAsync(move.Id);

        var reopened = Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
        Assert.Equal(MoveStatus.Doing, reopened.Status);
        Assert.Null(reopened.PreviousStatus);
        Assert.Null(reopened.CompletedAt);
        Assert.Equal(3, (await fixture.Repository.PendingOperationsAsync()).Count);
    }

    [Fact]
    public async Task ApplyingRemoteMoveDoesNotCreateAnOutboundEcho()
    {
        await using var fixture = await RepositoryFixture.CreateAsync();
        var timestamp = DateTimeOffset.Parse("2026-09-02T08:00:00Z", CultureInfo.InvariantCulture);
        var remote = Move.Create("Remote Move", now: timestamp) with
        {
            Revision = 9,
            FieldClocks = new Dictionary<string, DateTimeOffset> { ["title"] = timestamp },
        };

        await fixture.Repository.ApplyRemoteMoveAsync(remote);

        Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
        Assert.Empty(await fixture.Repository.PendingOperationsAsync());
    }

    [Fact]
    public async Task NewerSchemaRefusesToOpenWithoutChangingIt()
    {
        var path = Path.Combine(Path.GetTempPath(), $"founder-office-newer-{Guid.NewGuid():N}.sqlite3");
        try
        {
            await using (var connection = new SqliteConnection($"Data Source={path}"))
            {
                await connection.OpenAsync();
                await using var command = connection.CreateCommand();
                command.CommandText = "PRAGMA user_version = 99;";
                await command.ExecuteNonQueryAsync();
            }

            await using var repository = new SqliteWorkspaceRepository(path);
            var error = await Assert.ThrowsAsync<WorkspaceRepositoryException>(() => repository.InitializeAsync());
            Assert.Equal("workspace_schema_newer_than_client", error.Code);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    }

    private sealed class RepositoryFixture : IAsyncDisposable
    {
        private RepositoryFixture(string path, SqliteWorkspaceRepository repository)
        {
            Path = path;
            Repository = repository;
        }

        private string Path { get; }

        public SqliteWorkspaceRepository Repository { get; }

        public static async Task<RepositoryFixture> CreateAsync()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"founder-office-test-{Guid.NewGuid():N}.sqlite3");
            var repository = new SqliteWorkspaceRepository(path);
            await repository.InitializeAsync();
            return new RepositoryFixture(path, repository);
        }

        public async ValueTask DisposeAsync()
        {
            await Repository.DisposeAsync();
            SqliteConnection.ClearAllPools();
            File.Delete(Path);
        }
    }
}
