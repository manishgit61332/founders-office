namespace FoundersOffice.Core.Domain;

public sealed record WorkspaceSnapshot(
    IReadOnlyList<Move> Moves,
    int PendingOperationCount,
    DateTimeOffset CapturedAt);

public sealed record PendingSyncOperation(
    Guid OperationId,
    Guid EntityId,
    string EntityType,
    string Action,
    long BaseRevision,
    string ChangedFieldsJson,
    string FieldClocksJson,
    string? PayloadJson,
    DateTimeOffset OccurredAt);
