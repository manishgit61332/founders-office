using System.Globalization;
using System.Text.Json;
using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;
using FoundersOffice.Core.Sync;
using Microsoft.Data.Sqlite;

namespace FoundersOffice.Core.Tests;

public sealed class WorkspaceSyncCoordinatorTests
{
    [Fact]
    public async Task OfflineMovePushesThenPullsItsAuthoritativeRevision()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        var local = Move.Create("Created offline");
        await fixture.Repository.UpsertMoveAsync(local);
        var state = await fixture.Repository.SyncStateAsync();
        var accountId = Guid.NewGuid();
        var pending = Assert.Single(await fixture.Repository.PendingOperationsAsync());
        var remote = local with
        {
            Revision = 1,
            FieldClocks = local.FieldClocks.Count == 0
                ? new Dictionary<string, DateTimeOffset> { ["title"] = local.UpdatedAt }
                : local.FieldClocks,
        };
        var transport = new FakeTransport
        {
            BootstrapResponse = Bootstrap(accountId, state.LocalWorkspaceId, state.DeviceId),
            PushResponses =
            [
                new PushResponseDto(
                    1,
                    state.LocalWorkspaceId,
                    1,
                    [new OperationResultDto(pending.OperationId, "accepted", 1, 1, null)]),
            ],
            PullResponses = [Pull(state.LocalWorkspaceId, 0, remote, pending.OperationId)],
        };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);

        var result = await coordinator.RunAsync(
            new ProductIdentity(accountId, "google"),
            provisioningChoice: WorkspaceProvisioningChoice.ClaimLocalWorkspace);

        Assert.Equal(SyncRunOutcome.Synced, result.Outcome);
        Assert.Equal(1, result.PushedOperationCount);
        Assert.Equal(1, result.PulledChangeCount);
        Assert.Equal(1, result.Cursor);
        Assert.Equal(state.LocalWorkspaceId, Assert.Single(transport.BootstrapRequests).LocalWorkspaceId);
        Assert.Empty(await fixture.Repository.PendingOperationsAsync());
        Assert.Equal(1, Assert.Single((await fixture.Repository.SnapshotAsync()).Moves).Revision);
    }

    [Fact]
    public async Task FreshDeviceAttachesWithoutClaimingALocalWorkspace()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        var state = await fixture.Repository.SyncStateAsync();
        var accountId = Guid.NewGuid();
        var remoteWorkspaceId = Guid.NewGuid();
        var transport = new FakeTransport
        {
            BootstrapResponse = Bootstrap(accountId, remoteWorkspaceId, state.DeviceId),
            PullResponses = [EmptyPull(remoteWorkspaceId)],
        };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);

        var result = await coordinator.RunAsync(
            new ProductIdentity(accountId, "google"),
            provisioningChoice: WorkspaceProvisioningChoice.AttachExistingWorkspace);

        Assert.Equal(SyncRunOutcome.Synced, result.Outcome);
        Assert.Null(Assert.Single(transport.BootstrapRequests).LocalWorkspaceId);
        var bound = await fixture.Repository.SyncStateAsync();
        Assert.Equal(accountId, bound.AccountId);
        Assert.Equal(remoteWorkspaceId, bound.RemoteWorkspaceId);
    }

    [Fact]
    public async Task MacMoveFixturePullsIntoFreshWindowsWorkspace()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        var state = await fixture.Repository.SyncStateAsync();
        var accountId = Guid.NewGuid();
        var remoteWorkspaceId = Guid.Parse("11111111-1111-4111-8111-111111111111");
        var pull = V1ContractAdapter.ParsePullResponse(
            File.ReadAllText(Path.Combine(
                AppContext.BaseDirectory,
                "SyntheticFixtures",
                "mac-move.pull.response.json")));
        var transport = new FakeTransport
        {
            BootstrapResponse = Bootstrap(accountId, remoteWorkspaceId, state.DeviceId),
            PullResponses = [pull],
        };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);

        var result = await coordinator.RunAsync(
            new ProductIdentity(accountId, "google"),
            provisioningChoice: WorkspaceProvisioningChoice.AttachExistingWorkspace);

        Assert.Equal(SyncRunOutcome.Synced, result.Outcome);
        Assert.Equal(1, result.PulledChangeCount);
        var move = Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
        Assert.Equal("Review the shared launch plan", move.Title);
        Assert.Equal("founders-office-macos", move.Source);
        Assert.Equal(4, move.Revision);
    }

    [Fact]
    public async Task ExistingLocalDataRequiresExplicitChoiceAndExportBeforeAttach()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        await fixture.Repository.UpsertMoveAsync(Move.Create("Do not replace me"));
        var state = await fixture.Repository.SyncStateAsync();
        var accountId = Guid.NewGuid();
        var transport = new FakeTransport { BootstrapResponse = Bootstrap(accountId, Guid.NewGuid(), state.DeviceId) };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);

        var withoutChoice = await coordinator.RunAsync(new ProductIdentity(accountId, "google"));
        var attach = await coordinator.RunAsync(
            new ProductIdentity(accountId, "google"),
            provisioningChoice: WorkspaceProvisioningChoice.AttachExistingWorkspace);

        Assert.Equal(SyncRunOutcome.ProvisioningChoiceRequired, withoutChoice.Outcome);
        Assert.Equal(SyncRunOutcome.AttachmentNeedsReview, attach.Outcome);
        Assert.Empty(transport.BootstrapRequests);
        Assert.Empty(transport.PushRequests);
        Assert.Empty(transport.PullRequests);
        Assert.Single((await fixture.Repository.SnapshotAsync()).Moves);
    }

    [Fact]
    public async Task ASecondAccountCannotSendTheFirstAccountsWorkspaceId()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        var state = await fixture.Repository.SyncStateAsync();
        var firstAccount = Guid.NewGuid();
        var remoteWorkspaceId = Guid.NewGuid();
        var transport = new FakeTransport
        {
            BootstrapResponse = Bootstrap(firstAccount, remoteWorkspaceId, state.DeviceId),
            PullResponses = [EmptyPull(remoteWorkspaceId)],
        };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);
        Assert.Equal(
            SyncRunOutcome.Synced,
            (await coordinator.RunAsync(
                new ProductIdentity(firstAccount, "google"),
                provisioningChoice: WorkspaceProvisioningChoice.AttachExistingWorkspace)).Outcome);

        var result = await coordinator.RunAsync(new ProductIdentity(Guid.NewGuid(), "google"));

        Assert.Equal(SyncRunOutcome.AccountMismatch, result.Outcome);
        Assert.Single(transport.BootstrapRequests);
    }

    [Fact]
    public async Task ConflictQuarantinesTheOperationAndStopsBeforePull()
    {
        await using var fixture = await SyncFixture.CreateAsync();
        var local = Move.Create("Conflicting local Move");
        await fixture.Repository.UpsertMoveAsync(local);
        var state = await fixture.Repository.SyncStateAsync();
        var accountId = Guid.NewGuid();
        var pending = Assert.Single(await fixture.Repository.PendingOperationsAsync());
        var conflict = new SyncConflictDto(
            pending.OperationId,
            "move",
            local.Id,
            0,
            2,
            "overlappingChanges",
            ["title"],
            null);
        var transport = new FakeTransport
        {
            BootstrapResponse = Bootstrap(accountId, state.LocalWorkspaceId, state.DeviceId),
            PushResponses =
            [
                new PushResponseDto(
                    1,
                    state.LocalWorkspaceId,
                    2,
                    [new OperationResultDto(pending.OperationId, "conflict", null, null, conflict)]),
            ],
        };
        using var coordinator = new WorkspaceSyncCoordinator(fixture.Repository, transport);

        var result = await coordinator.RunAsync(
            new ProductIdentity(accountId, "google"),
            provisioningChoice: WorkspaceProvisioningChoice.ClaimLocalWorkspace);

        Assert.Equal(SyncRunOutcome.ConflictNeedsReview, result.Outcome);
        Assert.Empty(transport.PullRequests);
        Assert.Empty(await fixture.Repository.PendingOperationsAsync());
        Assert.Equal("Conflicting local Move", Assert.Single((await fixture.Repository.SnapshotAsync()).Moves).Title);
        Assert.True((await fixture.Repository.SyncStateAsync()).HasQuarantinedOperations);
        await fixture.Repository.DisposeAsync();
        await using var reopened = new SqliteWorkspaceRepository(fixture.Path);
        await reopened.InitializeAsync();
        using var restarted = new WorkspaceSyncCoordinator(reopened, transport);
        Assert.Equal(SyncRunOutcome.ConflictNeedsReview,
            (await restarted.RunAsync(new ProductIdentity(accountId, "google"))).Outcome);
        Assert.Single(transport.BootstrapRequests);
        Assert.Single(transport.PushRequests);
        Assert.Empty(transport.PullRequests);
        var error = await Assert.ThrowsAsync<WorkspaceRepositoryException>(() => reopened.ApplyPullPageAsync(
            state.LocalWorkspaceId, 0, 1,
            [new RemoteWorkspaceChange(1, Guid.NewGuid(), "move", local.Id,
                local with { Title = "Must not replace quarantined data", Revision = 2 })]));
        Assert.Equal("pull_change_has_pending_local_edit", error.Code);
        Assert.Equal("Conflicting local Move", Assert.Single((await reopened.SnapshotAsync()).Moves).Title);
        Assert.Equal(0, (await reopened.SyncStateAsync()).Cursor);
    }

    private static BootstrapResponseDto Bootstrap(Guid accountId, Guid workspaceId, Guid deviceId)
    {
        var now = DateTimeOffset.Parse("2026-09-04T10:00:00Z", CultureInfo.InvariantCulture);
        return new BootstrapResponseDto
        {
            ContractVersion = 1,
            Session = new AuthSessionIdsDto
            {
                AccountId = accountId,
                WorkspaceId = workspaceId,
                DeviceId = deviceId,
                IdentityProvider = "google",
            },
            Profile = new ProfileRecordDto
            {
                AccountId = accountId,
                IdentityProvider = "google",
                DisplayName = "Reviewed Founder",
            },
            Workspace = new WorkspaceRecordDto
            {
                Id = workspaceId,
                Name = "Founder's Office",
                Revision = 1,
                FieldClocks = new Dictionary<string, DateTimeOffset> { ["name"] = now },
                CreatedAt = now,
                UpdatedAt = now,
            },
            StartingCursor = 0,
            LatestCursor = 0,
        };
    }

    private static PullResponseDto Pull(Guid workspaceId, long fromCursor, Move move, Guid operationId)
    {
        var record = JsonSerializer.SerializeToElement(new
        {
            id = move.Id,
            title = move.Title,
            details = move.Details,
            status = "doing",
            previousStatus = (string?)null,
            priority = move.Priority.ToString(),
            dueOn = move.DueOn,
            completedAt = move.CompletedAt,
            deletedAt = move.DeletedAt,
            source = move.Source,
            revision = move.Revision,
            fieldClocks = move.FieldClocks,
            createdAt = move.CreatedAt,
            updatedAt = move.UpdatedAt,
        });
        return new PullResponseDto
        {
            ContractVersion = 1,
            WorkspaceId = workspaceId,
            FromCursor = fromCursor,
            NextCursor = fromCursor + 1,
            LatestCursor = fromCursor + 1,
            HasMore = false,
            Changes =
            [
                new SyncChangeDto
                {
                    Cursor = fromCursor + 1,
                    OperationId = operationId,
                    EntityType = "move",
                    EntityId = move.Id,
                    Action = "upsert",
                    Revision = move.Revision,
                    ChangedFields = ["title"],
                    ChangedAt = move.UpdatedAt,
                    Record = record,
                },
            ],
        };
    }

    private static PullResponseDto EmptyPull(Guid workspaceId) => new()
    {
        ContractVersion = 1,
        WorkspaceId = workspaceId,
        FromCursor = 0,
        NextCursor = 0,
        LatestCursor = 0,
        HasMore = false,
        Changes = [],
    };

    private sealed class FakeTransport : IV1SyncTransport
    {
        private int _pushIndex;
        private int _pullIndex;

        public required BootstrapResponseDto BootstrapResponse { get; init; }

        public IReadOnlyList<PushResponseDto> PushResponses { get; init; } = [];

        public IReadOnlyList<PullResponseDto> PullResponses { get; init; } = [];

        public List<BootstrapRequestDto> BootstrapRequests { get; } = [];

        public List<PushRequestDto> PushRequests { get; } = [];

        public List<PullRequestDto> PullRequests { get; } = [];

        public Task<BootstrapResponseDto> BootstrapAsync(
            BootstrapRequestDto request,
            CancellationToken cancellationToken = default)
        {
            BootstrapRequests.Add(request);
            return Task.FromResult(BootstrapResponse);
        }

        public Task<PushResponseDto> PushAsync(
            PushRequestDto request,
            CancellationToken cancellationToken = default)
        {
            PushRequests.Add(request);
            return Task.FromResult(PushResponses[_pushIndex++]);
        }

        public Task<PullResponseDto> PullAsync(
            PullRequestDto request,
            CancellationToken cancellationToken = default)
        {
            PullRequests.Add(request);
            return Task.FromResult(PullResponses[_pullIndex++]);
        }
    }

    private sealed class SyncFixture : IAsyncDisposable
    {
        private SyncFixture(string path, SqliteWorkspaceRepository repository)
        {
            Path = path;
            Repository = repository;
        }

        public string Path { get; }

        public SqliteWorkspaceRepository Repository { get; }

        public static async Task<SyncFixture> CreateAsync()
        {
            var path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"founder-office-sync-test-{Guid.NewGuid():N}.sqlite3");
            var repository = new SqliteWorkspaceRepository(path);
            await repository.InitializeAsync();
            return new SyncFixture(path, repository);
        }

        public async ValueTask DisposeAsync()
        {
            await Repository.DisposeAsync();
            SqliteConnection.ClearAllPools();
            File.Delete(Path);
        }
    }
}
