namespace FoundersOffice.Core.Domain;

public sealed record WorkspaceSyncState(
    Guid LocalWorkspaceId,
    Guid DeviceId,
    Guid? AccountId,
    Guid? RemoteWorkspaceId,
    string? IdentityProvider,
    long Cursor,
    bool HasLocalData,
    bool HasQuarantinedOperations = false)
{
    public bool IsBound => AccountId is not null && RemoteWorkspaceId is not null;

    public Guid? BootstrapWorkspaceId => IsBound
        ? RemoteWorkspaceId
        : HasLocalData
            ? LocalWorkspaceId
            : null;
}

public sealed record RemoteWorkspaceChange(
    long Cursor,
    Guid OperationId,
    string EntityType,
    Guid EntityId,
    Move? Move);
