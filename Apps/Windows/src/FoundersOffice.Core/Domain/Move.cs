namespace FoundersOffice.Core.Domain;

public enum MoveStatus
{
    Doing,
    Next,
    Blocked,
    Done,
}

public enum MovePriority
{
    P0,
    P1,
    P2,
    P3,
}

/// <summary>
/// Windows representation of the v1 MoveRecord contract. Customer-facing
/// surfaces call these Moves; OpenLoop remains an Apple compatibility name.
/// </summary>
public sealed record Move(
    Guid Id,
    string Title,
    string Details,
    MoveStatus Status,
    MoveStatus? PreviousStatus,
    MovePriority Priority,
    DateOnly? DueOn,
    DateTimeOffset? CompletedAt,
    DateTimeOffset? DeletedAt,
    string Source,
    long Revision,
    IReadOnlyDictionary<string, DateTimeOffset> FieldClocks,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public bool IsDeleted => DeletedAt is not null;

    public static Move Create(
        string title,
        string details = "",
        MovePriority priority = MovePriority.P1,
        DateOnly? dueOn = null,
        DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        var normalizedTitle = title.Trim();
        var normalizedDetails = details.Trim();
        ValidateText(normalizedTitle, normalizedDetails);

        return new Move(
            Guid.NewGuid(),
            normalizedTitle,
            normalizedDetails,
            MoveStatus.Doing,
            null,
            priority,
            dueOn,
            null,
            null,
            "founders-office-windows",
            0,
            new Dictionary<string, DateTimeOffset>(),
            timestamp,
            timestamp);
    }

    public Move Validate()
    {
        ValidateText(Title, Details);
        if (Id == Guid.Empty)
        {
            throw new ArgumentException("A Move ID must not be empty.", nameof(Id));
        }

        if (Revision < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(Revision));
        }

        if (string.IsNullOrWhiteSpace(Source) || Source.Length > 64)
        {
            throw new ArgumentException("A Move source must contain 1–64 characters.", nameof(Source));
        }

        return this;
    }

    private static void ValidateText(string title, string details)
    {
        if (string.IsNullOrWhiteSpace(title) || title.Length > 500)
        {
            throw new ArgumentException("A Move title must contain 1–500 characters.", nameof(title));
        }

        if (details.Length > 20_000)
        {
            throw new ArgumentException("Move details must contain at most 20,000 characters.", nameof(details));
        }
    }
}
