using System.Text.Json;
using System.Text.Json.Serialization;

namespace FoundersOffice.Core.Sync;

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
