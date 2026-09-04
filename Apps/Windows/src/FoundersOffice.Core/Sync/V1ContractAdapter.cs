using System.Text.Json;
using System.Text.Json.Serialization;
using FoundersOffice.Core.Domain;

namespace FoundersOffice.Core.Sync;

/// <summary>
/// Hand-mapped Windows adapter for contracts/v1. It intentionally consumes the
/// checked-in language-neutral fixtures instead of defining a Windows-only wire
/// protocol. Unknown fields fail closed until the shared contract is reviewed.
/// </summary>
public static class V1ContractAdapter
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static string SerializeBootstrapRequest(BootstrapRequestDto request)
    {
        if (request.DeviceId == Guid.Empty || string.IsNullOrWhiteSpace(request.WorkspaceName) ||
            request.WorkspaceName.Length > 120)
        {
            throw new ContractMappingException("bootstrap_request_invalid");
        }

        return JsonSerializer.Serialize(request, Options);
    }

    public static string SerializePushRequest(PushRequestDto request)
    {
        if (request.WorkspaceId == Guid.Empty || request.DeviceId == Guid.Empty ||
            request.Operations.Count is < 1 or > 100)
        {
            throw new ContractMappingException("push_request_invalid");
        }

        foreach (var operation in request.Operations)
        {
            ValidateOperation(operation);
        }

        return JsonSerializer.Serialize(request, Options);
    }

    public static string SerializePullRequest(PullRequestDto request)
    {
        if (request.WorkspaceId == Guid.Empty || request.DeviceId == Guid.Empty ||
            request.Cursor < 0 || request.Limit is < 1 or > 500)
        {
            throw new ContractMappingException("pull_request_invalid");
        }

        return JsonSerializer.Serialize(request, Options);
    }

    public static SyncOperationDto MapPendingOperation(PendingSyncOperation operation)
    {
        try
        {
            var changedFields = JsonSerializer.Deserialize<IReadOnlyList<string>>(
                operation.ChangedFieldsJson,
                Options) ?? throw new ContractMappingException("operation_changed_fields_invalid");
            var fieldClocks = JsonSerializer.Deserialize<Dictionary<string, string>>(
                operation.FieldClocksJson,
                Options) ?? throw new ContractMappingException("operation_field_clocks_invalid");
            JsonElement? payload = null;
            if (operation.PayloadJson is not null)
            {
                using var document = JsonDocument.Parse(operation.PayloadJson);
                payload = document.RootElement.Clone();
            }
            var mapped = new SyncOperationDto
            {
                OperationId = operation.OperationId,
                EntityType = operation.EntityType,
                EntityId = operation.EntityId,
                Action = operation.Action,
                BaseRevision = operation.BaseRevision,
                ChangedFields = changedFields,
                FieldClocks = fieldClocks,
                Payload = payload,
                OccurredAt = FormatTimestamp(operation.OccurredAt),
            };
            ValidateOperation(mapped);
            return mapped;
        }
        catch (JsonException exception)
        {
            throw new ContractMappingException("operation_payload_invalid", exception);
        }
    }

    public static BootstrapResponseDto ParseBootstrapResponse(string json)
    {
        var response = Deserialize<BootstrapResponseDto>(json);
        RequireVersion(response.ContractVersion);
        if (response.StartingCursor != 0 || response.LatestCursor < 0 ||
            response.Session.AccountId == Guid.Empty || response.Session.WorkspaceId == Guid.Empty ||
            response.Session.DeviceId == Guid.Empty || response.Profile.AccountId == Guid.Empty ||
            response.Workspace.Id == Guid.Empty || response.Workspace.Revision < 1 ||
            string.IsNullOrWhiteSpace(response.Workspace.Name) || response.Workspace.Name.Length > 120 ||
            response.Workspace.FieldClocks.Count is < 1 or > 32)
        {
            throw new ContractMappingException("bootstrap_response_invalid");
        }

        if (response.Session.WorkspaceId != response.Workspace.Id ||
            response.Session.AccountId != response.Profile.AccountId ||
            response.Session.IdentityProvider != response.Profile.IdentityProvider)
        {
            throw new ContractMappingException("bootstrap_identity_mismatch");
        }

        ValidateIdentityProvider(response.Session.IdentityProvider);
        return response;
    }

    public static PullResponseDto ParsePullResponse(string json)
    {
        var response = Deserialize<PullResponseDto>(json);
        RequireVersion(response.ContractVersion);
        if (response.WorkspaceId == Guid.Empty || response.FromCursor < 0 ||
            response.NextCursor < response.FromCursor ||
            response.LatestCursor < response.NextCursor)
        {
            throw new ContractMappingException("pull_cursor_invalid");
        }

        long previousCursor = response.FromCursor;
        foreach (var change in response.Changes)
        {
            if (change.Cursor <= previousCursor || change.Cursor > response.NextCursor)
            {
                throw new ContractMappingException("pull_change_cursor_invalid");
            }

            if (change.OperationId == Guid.Empty || change.EntityId == Guid.Empty || change.Revision < 1 ||
                change.EntityType is not ("workspace" or "profile" or "move" or "appearance" or
                    "primaryGoal" or "milestone" or "asset") ||
                change.Action is not ("upsert" or "delete") ||
                change.Record.ValueKind != JsonValueKind.Object)
            {
                throw new ContractMappingException("pull_change_identity_invalid");
            }

            if (change.ChangedFields.Count is < 1 or > 32 ||
                change.ChangedFields.Distinct(StringComparer.Ordinal).Count() != change.ChangedFields.Count)
            {
                throw new ContractMappingException("pull_changed_fields_invalid");
            }

            previousCursor = change.Cursor;
        }

        if ((response.Changes.Count == 0 && response.NextCursor != response.FromCursor) ||
            (response.Changes.Count > 0 && previousCursor != response.NextCursor) ||
            (response.HasMore && response.NextCursor >= response.LatestCursor) ||
            (!response.HasMore && response.NextCursor != response.LatestCursor))
        {
            throw new ContractMappingException("pull_page_boundary_invalid");
        }

        return response;
    }

    public static PushResponseDto ParsePushResponse(string json)
    {
        var wire = Deserialize<PushResponseWireDto>(json);
        RequireVersion(wire.ContractVersion);
        if (wire.WorkspaceId == Guid.Empty || wire.LatestCursor < 0 || wire.Results.Count is < 1 or > 100 ||
            wire.Results.Select(result => result.OperationId).Distinct().Count() != wire.Results.Count)
        {
            throw new ContractMappingException("push_response_invalid");
        }

        var results = wire.Results.Select(MapOperationResult).ToArray();
        return new PushResponseDto(wire.ContractVersion, wire.WorkspaceId, wire.LatestCursor, results);
    }

    public static IReadOnlyList<Move> MapMoveChanges(PullResponseDto response)
    {
        var moves = new List<Move>();
        foreach (var change in response.Changes.Where(change => change.EntityType == "move"))
        {
            moves.Add(MapMoveChange(change));
        }

        return moves;
    }

    public static Move MapMoveChange(SyncChangeDto change)
    {
        if (change.EntityType != "move" ||
            change.Record.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            throw new ContractMappingException("move_record_missing");
        }

        var record = change.Record.Deserialize<MoveRecordDto>(Options)
            ?? throw new ContractMappingException("move_record_invalid");
        if (record.Id != change.EntityId || record.Revision != change.Revision)
        {
            throw new ContractMappingException("move_change_mismatch");
        }

        if (record.Revision < 1 || record.FieldClocks.Count is < 1 or > 32 ||
            change.ChangedFields.Any(field => !record.FieldClocks.ContainsKey(field)) ||
            (change.Action == "delete" && record.DeletedAt is null))
        {
            throw new ContractMappingException("move_change_invalid");
        }

        return new Move(
            record.Id,
            record.Title,
            record.Details,
            ParseStatus(record.Status),
            record.PreviousStatus is null ? null : ParseStatus(record.PreviousStatus),
            ParsePriority(record.Priority),
            record.DueOn,
            record.CompletedAt,
            record.DeletedAt,
            record.Source,
            record.Revision,
            record.FieldClocks,
            record.CreatedAt,
            record.UpdatedAt).Validate();
    }

    private static T Deserialize<T>(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, Options)
                ?? throw new ContractMappingException("contract_payload_empty");
        }
        catch (JsonException exception)
        {
            throw new ContractMappingException("contract_payload_invalid", exception);
        }
    }

    private static OperationResultDto MapOperationResult(OperationResultWireDto wire)
    {
        if (wire.OperationId == Guid.Empty)
        {
            throw new ContractMappingException("push_result_identity_invalid");
        }

        if (wire.Status is "accepted" or "duplicate")
        {
            if (wire.Revision is null or < 0 || wire.Cursor is null or < 1 || wire.Conflict is not null)
            {
                throw new ContractMappingException("push_result_accepted_invalid");
            }

            return new OperationResultDto(wire.OperationId, wire.Status, wire.Revision, wire.Cursor, null);
        }

        if (wire.Status != "conflict" || wire.Revision is not null || wire.Cursor is not null || wire.Conflict is null)
        {
            throw new ContractMappingException("push_result_status_invalid");
        }

        var conflict = wire.Conflict;
        if (conflict.OperationId != wire.OperationId || conflict.EntityType != "move" ||
            conflict.EntityId == Guid.Empty ||
            conflict.BaseRevision < 0 || conflict.CurrentRevision < 0 ||
            conflict.Reason is not ("revisionMismatch" or "overlappingChanges" or "fieldClockLost" or "missingRecord") ||
            conflict.ConflictingFields.Count > 32 ||
            conflict.ConflictingFields.Distinct(StringComparer.Ordinal).Count() != conflict.ConflictingFields.Count ||
            ((conflict.Reason is "overlappingChanges" or "fieldClockLost") &&
             conflict.ConflictingFields.Count == 0))
        {
            throw new ContractMappingException("push_conflict_invalid");
        }

        return new OperationResultDto(
            wire.OperationId,
            wire.Status,
            null,
            null,
            new SyncConflictDto(
                conflict.OperationId,
                conflict.EntityType,
                conflict.EntityId,
                conflict.BaseRevision,
                conflict.CurrentRevision,
                conflict.Reason,
                conflict.ConflictingFields,
                conflict.ServerRecord));
    }

    private static void ValidateOperation(SyncOperationDto operation)
    {
        if (operation.ContractVersion != 1 || operation.OperationId == Guid.Empty ||
            operation.EntityId == Guid.Empty || operation.EntityType != "move" ||
            operation.Action is not ("upsert" or "delete") || operation.BaseRevision < 0 ||
            operation.ChangedFields.Count is < 1 or > 32 ||
            operation.ChangedFields.Distinct(StringComparer.Ordinal).Count() != operation.ChangedFields.Count ||
            operation.FieldClocks.Count != operation.ChangedFields.Count ||
            operation.ChangedFields.Any(field => !operation.FieldClocks.ContainsKey(field)))
        {
            throw new ContractMappingException("operation_invalid");
        }

        if ((operation.Action == "upsert" && operation.Payload is null) ||
            (operation.Action == "delete" && operation.Payload is not null))
        {
            throw new ContractMappingException("operation_payload_invalid");
        }
    }

    private static void RequireVersion(int version)
    {
        if (version != 1)
        {
            throw new ContractMappingException("contract_version_unsupported");
        }
    }

    private static void ValidateIdentityProvider(string provider)
    {
        if (provider is not ("google" or "apple"))
        {
            throw new ContractMappingException("identity_provider_unsupported");
        }
    }

    private static MoveStatus ParseStatus(string status) => status switch
    {
        "doing" => MoveStatus.Doing,
        "next" => MoveStatus.Next,
        "blocked" => MoveStatus.Blocked,
        "done" => MoveStatus.Done,
        _ => throw new ContractMappingException("move_status_unsupported"),
    };

    private static MovePriority ParsePriority(string priority) => priority switch
    {
        "P0" => MovePriority.P0,
        "P1" => MovePriority.P1,
        "P2" => MovePriority.P2,
        "P3" => MovePriority.P3,
        _ => throw new ContractMappingException("move_priority_unsupported"),
    };

    private static string FormatTimestamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", System.Globalization.CultureInfo.InvariantCulture);
}

public sealed class ContractMappingException : Exception
{
    public ContractMappingException(string code, Exception? innerException = null)
        : base(code, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}
