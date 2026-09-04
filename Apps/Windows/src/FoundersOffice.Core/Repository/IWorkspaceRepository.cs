using FoundersOffice.Core.Domain;

namespace FoundersOffice.Core.Repository;

public interface IWorkspaceRepository : IAsyncDisposable
{
    Task InitializeAsync(CancellationToken cancellationToken = default);

    Task<WorkspaceSnapshot> SnapshotAsync(CancellationToken cancellationToken = default);

    Task UpsertMoveAsync(Move move, CancellationToken cancellationToken = default);

    Task UpdateMoveAsync(
        Guid moveId,
        string title,
        string details,
        MovePriority priority,
        DateOnly? dueOn,
        CancellationToken cancellationToken = default);

    Task CompleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default);

    Task ReopenMoveAsync(Guid moveId, CancellationToken cancellationToken = default);

    Task SoftDeleteMoveAsync(Guid moveId, CancellationToken cancellationToken = default);

    Task ApplyRemoteMoveAsync(Move move, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<PendingSyncOperation>> PendingOperationsAsync(
        int limit = 100,
        CancellationToken cancellationToken = default);
}
