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

    public static BootstrapResponseDto ParseBootstrapResponse(string json)
    {
        var response = Deserialize<BootstrapResponseDto>(json);
        RequireVersion(response.ContractVersion);
        if (response.StartingCursor != 0 || response.LatestCursor < 0)
        {
            throw new ContractMappingException("bootstrap_cursor_invalid");
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
        if (response.FromCursor < 0 || response.NextCursor < response.FromCursor ||
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

            if (change.OperationId == Guid.Empty || change.EntityId == Guid.Empty || change.Revision < 0)
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

        return response;
    }

    public static IReadOnlyList<Move> MapMoveChanges(PullResponseDto response)
    {
        var moves = new List<Move>();
        foreach (var change in response.Changes.Where(change => change.EntityType == "move"))
        {
            if (change.Record.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            {
                throw new ContractMappingException("move_record_missing");
            }

            var record = change.Record.Deserialize<MoveRecordDto>(Options)
                ?? throw new ContractMappingException("move_record_invalid");
            if (record.Id != change.EntityId || record.Revision != change.Revision)
            {
                throw new ContractMappingException("move_change_mismatch");
            }

            var move = new Move(
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
            moves.Add(move);
        }

        return moves;
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
