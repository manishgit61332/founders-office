using System.Text.Json;
using System.Text.Json.Serialization;

namespace FoundersOffice.Core.Sync;

public sealed record BootstrapRequestDto
{
    [JsonPropertyName("p_device_id")]
    public required Guid DeviceId { get; init; }

    [JsonPropertyName("p_local_workspace_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Guid? LocalWorkspaceId { get; init; }

    [JsonPropertyName("p_workspace_name")]
    public required string WorkspaceName { get; init; }

    [JsonPropertyName("p_display_name")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ReviewedDisplayName { get; init; }
}

public sealed record PushRequestDto
{
    [JsonPropertyName("p_workspace_id")]
    public required Guid WorkspaceId { get; init; }

    [JsonPropertyName("p_device_id")]
    public required Guid DeviceId { get; init; }

    [JsonPropertyName("p_operations")]
    public required IReadOnlyList<SyncOperationDto> Operations { get; init; }
}

public sealed record PullRequestDto
{
    [JsonPropertyName("p_workspace_id")]
    public required Guid WorkspaceId { get; init; }

    [JsonPropertyName("p_device_id")]
    public required Guid DeviceId { get; init; }

    [JsonPropertyName("p_cursor")]
    public required long Cursor { get; init; }

    [JsonPropertyName("p_limit")]
    public required int Limit { get; init; }
}

public sealed record SyncOperationDto
{
    [JsonPropertyName("contractVersion")]
    public int ContractVersion { get; init; } = 1;

    [JsonPropertyName("operationId")]
    public required Guid OperationId { get; init; }

    [JsonPropertyName("entityType")]
    public required string EntityType { get; init; }

    [JsonPropertyName("entityId")]
    public required Guid EntityId { get; init; }

    [JsonPropertyName("action")]
    public required string Action { get; init; }

    [JsonPropertyName("baseRevision")]
    public required long BaseRevision { get; init; }

    [JsonPropertyName("changedFields")]
    public required IReadOnlyList<string> ChangedFields { get; init; }

    [JsonPropertyName("fieldClocks")]
    public required IReadOnlyDictionary<string, string> FieldClocks { get; init; }

    [JsonPropertyName("payload")]
    public JsonElement? Payload { get; init; }

    [JsonPropertyName("occurredAt")]
    public required string OccurredAt { get; init; }
}

public sealed record AuthSessionIdsDto
{
    [JsonPropertyName("accountId")]
    public required Guid AccountId { get; init; }

    [JsonPropertyName("workspaceId")]
    public required Guid WorkspaceId { get; init; }

    [JsonPropertyName("deviceId")]
    public required Guid DeviceId { get; init; }

    [JsonPropertyName("identityProvider")]
    public required string IdentityProvider { get; init; }
}

public sealed record ProfileRecordDto
{
    [JsonPropertyName("accountId")]
    public required Guid AccountId { get; init; }

    [JsonPropertyName("identityProvider")]
    public required string IdentityProvider { get; init; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; init; }
}

public sealed record WorkspaceRecordDto
{
    [JsonPropertyName("id")]
    public required Guid Id { get; init; }

    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("revision")]
    public required long Revision { get; init; }

    [JsonPropertyName("fieldClocks")]
    public required Dictionary<string, DateTimeOffset> FieldClocks { get; init; }

    [JsonPropertyName("createdAt")]
    public required DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updatedAt")]
    public required DateTimeOffset UpdatedAt { get; init; }
}

public sealed record BootstrapResponseDto
{
    [JsonPropertyName("contractVersion")]
    public required int ContractVersion { get; init; }

    [JsonPropertyName("session")]
    public required AuthSessionIdsDto Session { get; init; }

    [JsonPropertyName("profile")]
    public required ProfileRecordDto Profile { get; init; }

    [JsonPropertyName("workspace")]
    public required WorkspaceRecordDto Workspace { get; init; }

    [JsonPropertyName("startingCursor")]
    public required long StartingCursor { get; init; }

    [JsonPropertyName("latestCursor")]
    public required long LatestCursor { get; init; }
}

public sealed record PullResponseDto
{
    [JsonPropertyName("contractVersion")]
    public required int ContractVersion { get; init; }

    [JsonPropertyName("workspaceId")]
    public required Guid WorkspaceId { get; init; }

    [JsonPropertyName("fromCursor")]
    public required long FromCursor { get; init; }

    [JsonPropertyName("nextCursor")]
    public required long NextCursor { get; init; }

    [JsonPropertyName("latestCursor")]
    public required long LatestCursor { get; init; }

    [JsonPropertyName("hasMore")]
    public required bool HasMore { get; init; }

    [JsonPropertyName("changes")]
    public required IReadOnlyList<SyncChangeDto> Changes { get; init; }
}

public sealed record PushResponseDto(
    int ContractVersion,
    Guid WorkspaceId,
    long LatestCursor,
    IReadOnlyList<OperationResultDto> Results);

public sealed record OperationResultDto(
    Guid OperationId,
    string Status,
    long? Revision,
    long? Cursor,
    SyncConflictDto? Conflict);

public sealed record SyncConflictDto(
    Guid OperationId,
    string EntityType,
    Guid EntityId,
    long BaseRevision,
    long CurrentRevision,
    string Reason,
    IReadOnlyList<string> ConflictingFields,
    JsonElement? ServerRecord);

public sealed record SyncChangeDto
{
    [JsonPropertyName("cursor")]
    public required long Cursor { get; init; }

    [JsonPropertyName("operationId")]
    public required Guid OperationId { get; init; }

    [JsonPropertyName("entityType")]
    public required string EntityType { get; init; }

    [JsonPropertyName("entityId")]
    public required Guid EntityId { get; init; }

    [JsonPropertyName("action")]
    public required string Action { get; init; }

    [JsonPropertyName("revision")]
    public required long Revision { get; init; }

    [JsonPropertyName("changedFields")]
    public required IReadOnlyList<string> ChangedFields { get; init; }

    [JsonPropertyName("changedAt")]
    public required DateTimeOffset ChangedAt { get; init; }

    [JsonPropertyName("record")]
    public required JsonElement Record { get; init; }
}

internal sealed record MoveRecordDto
{
    [JsonPropertyName("id")]
    public required Guid Id { get; init; }

    [JsonPropertyName("title")]
    public required string Title { get; init; }

    [JsonPropertyName("details")]
    public required string Details { get; init; }

    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("previousStatus")]
    public string? PreviousStatus { get; init; }

    [JsonPropertyName("priority")]
    public required string Priority { get; init; }

    [JsonPropertyName("dueOn")]
    public DateOnly? DueOn { get; init; }

    [JsonPropertyName("completedAt")]
    public DateTimeOffset? CompletedAt { get; init; }

    [JsonPropertyName("deletedAt")]
    public DateTimeOffset? DeletedAt { get; init; }

    [JsonPropertyName("source")]
    public required string Source { get; init; }

    [JsonPropertyName("revision")]
    public required long Revision { get; init; }

    [JsonPropertyName("fieldClocks")]
    public required Dictionary<string, DateTimeOffset> FieldClocks { get; init; }

    [JsonPropertyName("createdAt")]
    public required DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updatedAt")]
    public required DateTimeOffset UpdatedAt { get; init; }
}

internal sealed record PushResponseWireDto
{
    [JsonPropertyName("contractVersion")]
    public required int ContractVersion { get; init; }

    [JsonPropertyName("workspaceId")]
    public required Guid WorkspaceId { get; init; }

    [JsonPropertyName("latestCursor")]
    public required long LatestCursor { get; init; }

    [JsonPropertyName("results")]
    public required IReadOnlyList<OperationResultWireDto> Results { get; init; }
}

internal sealed record OperationResultWireDto
{
    [JsonPropertyName("operationId")]
    public required Guid OperationId { get; init; }

    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("revision")]
    public long? Revision { get; init; }

    [JsonPropertyName("cursor")]
    public long? Cursor { get; init; }

    [JsonPropertyName("conflict")]
    public SyncConflictWireDto? Conflict { get; init; }
}

internal sealed record SyncConflictWireDto
{
    [JsonPropertyName("operationId")]
    public required Guid OperationId { get; init; }

    [JsonPropertyName("entityType")]
    public required string EntityType { get; init; }

    [JsonPropertyName("entityId")]
    public required Guid EntityId { get; init; }

    [JsonPropertyName("baseRevision")]
    public required long BaseRevision { get; init; }

    [JsonPropertyName("currentRevision")]
    public required long CurrentRevision { get; init; }

    [JsonPropertyName("reason")]
    public required string Reason { get; init; }

    [JsonPropertyName("conflictingFields")]
    public required IReadOnlyList<string> ConflictingFields { get; init; }

    [JsonPropertyName("serverRecord")]
    public JsonElement? ServerRecord { get; init; }
}
