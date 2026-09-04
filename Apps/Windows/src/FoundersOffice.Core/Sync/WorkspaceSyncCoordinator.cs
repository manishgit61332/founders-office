using System.Globalization;
using System.Text;
using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;

namespace FoundersOffice.Core.Sync;

public enum SyncRunOutcome
{
    Synced,
    MoreWork,
    ConflictNeedsReview,
    AccountMismatch,
    ProvisioningChoiceRequired,
    AttachmentNeedsReview,
}

public enum WorkspaceProvisioningChoice
{
    ClaimLocalWorkspace,
    AttachExistingWorkspace,
}

public sealed record SyncRunResult(
    SyncRunOutcome Outcome,
    int PushedOperationCount,
    int PulledChangeCount,
    long Cursor);

public sealed record ReviewedDisplayName
{
    private ReviewedDisplayName(string value)
    {
        Value = value;
    }

    public string Value { get; }

    public static ReviewedDisplayName Create(string input)
    {
        var value = input.Normalize(NormalizationForm.FormC).Trim();
        var runes = value.EnumerateRunes().ToArray();
        if (runes.Length is < 1 or > 80 || Encoding.UTF8.GetByteCount(value) > 320 ||
            !runes.Any(IsVisibleIdentityRune) || runes.Any(IsForbiddenRune))
        {
            throw new ArgumentException("The reviewed display name does not meet the v1 contract.", nameof(input));
        }

        return new ReviewedDisplayName(value);
    }

    private static bool IsVisibleIdentityRune(Rune rune)
    {
        var category = Rune.GetUnicodeCategory(rune);
        return category is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or
            UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or
            UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber or
            UnicodeCategory.MathSymbol or UnicodeCategory.CurrencySymbol or UnicodeCategory.ModifierSymbol or
            UnicodeCategory.OtherSymbol;
    }

    private static bool IsForbiddenRune(Rune rune)
    {
        var category = Rune.GetUnicodeCategory(rune);
        return category is UnicodeCategory.Control or UnicodeCategory.LineSeparator or
            UnicodeCategory.ParagraphSeparator or UnicodeCategory.Format;
    }
}

/// <summary>
/// Runs one bounded, serialized v1 sync drain. Local operations are sent one at
/// a time so later offline edits can be durably rebased after each accepted
/// revision. A conflict stops before pull can replace an unresolved local edit.
/// </summary>
public sealed class WorkspaceSyncCoordinator : IDisposable
{
    private const int MaximumPushesPerRun = 100;
    private const int MaximumPullPagesPerRun = 20;
    private readonly IWorkspaceRepository _repository;
    private readonly IV1SyncTransport _transport;
    private readonly SemaphoreSlim _runGate = new(1, 1);
    private bool _disposed;

    public WorkspaceSyncCoordinator(IWorkspaceRepository repository, IV1SyncTransport transport)
    {
        _repository = repository;
        _transport = transport;
    }

    public async Task<SyncRunResult> RunAsync(
        ProductIdentity identity,
        ReviewedDisplayName? reviewedDisplayName = null,
        WorkspaceProvisioningChoice? provisioningChoice = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        identity.Validate();
        await _runGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
            if (state.AccountId is not null && state.AccountId != identity.AccountId)
            {
                return new SyncRunResult(SyncRunOutcome.AccountMismatch, 0, 0, state.Cursor);
            }

            if (!state.IsBound && provisioningChoice is null)
            {
                return new SyncRunResult(SyncRunOutcome.ProvisioningChoiceRequired, 0, 0, state.Cursor);
            }

            if (!state.IsBound && state.HasLocalData &&
                provisioningChoice == WorkspaceProvisioningChoice.AttachExistingWorkspace)
            {
                return new SyncRunResult(SyncRunOutcome.AttachmentNeedsReview, 0, 0, state.Cursor);
            }

            var bootstrapWorkspaceId = state.IsBound
                ? state.RemoteWorkspaceId
                : provisioningChoice == WorkspaceProvisioningChoice.ClaimLocalWorkspace
                    ? state.LocalWorkspaceId
                    : null;

            var bootstrap = await _transport.BootstrapAsync(
                new BootstrapRequestDto
                {
                    DeviceId = state.DeviceId,
                    LocalWorkspaceId = bootstrapWorkspaceId,
                    WorkspaceName = "Founder's Office",
                    ReviewedDisplayName = reviewedDisplayName?.Value,
                },
                cancellationToken).ConfigureAwait(false);
            ValidateBootstrap(identity, state, bootstrap);

            try
            {
                await _repository.BindWorkspaceAsync(
                    identity.AccountId,
                    bootstrap.Workspace.Id,
                    state.DeviceId,
                    identity.IdentityProvider,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (WorkspaceRepositoryException exception)
                when (exception.Code == "workspace_attachment_requires_review")
            {
                return new SyncRunResult(SyncRunOutcome.AttachmentNeedsReview, 0, 0, state.Cursor);
            }

            var pushed = 0;
            while (pushed < MaximumPushesPerRun)
            {
                var pending = await _repository.PendingOperationsAsync(1, cancellationToken).ConfigureAwait(false);
                if (pending.Count == 0)
                {
                    break;
                }

                var operation = pending[0];
                var response = await _transport.PushAsync(
                    new PushRequestDto
                    {
                        WorkspaceId = bootstrap.Workspace.Id,
                        DeviceId = state.DeviceId,
                        Operations = [V1ContractAdapter.MapPendingOperation(operation)],
                    },
                    cancellationToken).ConfigureAwait(false);
                if (response.WorkspaceId != bootstrap.Workspace.Id || response.Results.Count != 1 ||
                    response.Results[0].OperationId != operation.OperationId)
                {
                    throw new SyncCoordinatorException("push_response_scope_mismatch");
                }

                var result = response.Results[0];
                if (result.Status == "conflict")
                {
                    await _repository.QuarantineOperationAsync(operation.OperationId, cancellationToken)
                        .ConfigureAwait(false);
                    var conflictState = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
                    return new SyncRunResult(
                        SyncRunOutcome.ConflictNeedsReview,
                        pushed,
                        0,
                        conflictState.Cursor);
                }

                if (result.Status is not ("accepted" or "duplicate") || result.Revision is null)
                {
                    throw new SyncCoordinatorException("push_result_invalid");
                }

                await _repository.AcknowledgeOperationAsync(
                    operation.OperationId,
                    operation.EntityId,
                    result.Revision.Value,
                    cancellationToken).ConfigureAwait(false);
                pushed += 1;
            }

            if ((await _repository.PendingOperationsAsync(1, cancellationToken).ConfigureAwait(false)).Count != 0)
            {
                var moreWorkState = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
                return new SyncRunResult(SyncRunOutcome.MoreWork, pushed, 0, moreWorkState.Cursor);
            }

            var pulled = 0;
            for (var pageNumber = 0; pageNumber < MaximumPullPagesPerRun; pageNumber += 1)
            {
                state = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
                var response = await _transport.PullAsync(
                    new PullRequestDto
                    {
                        WorkspaceId = bootstrap.Workspace.Id,
                        DeviceId = state.DeviceId,
                        Cursor = state.Cursor,
                        Limit = 200,
                    },
                    cancellationToken).ConfigureAwait(false);
                if (response.WorkspaceId != bootstrap.Workspace.Id || response.FromCursor != state.Cursor)
                {
                    throw new SyncCoordinatorException("pull_response_scope_mismatch");
                }

                var changes = response.Changes.Select(change => new RemoteWorkspaceChange(
                    change.Cursor,
                    change.OperationId,
                    change.EntityType,
                    change.EntityId,
                    change.EntityType == "move" ? V1ContractAdapter.MapMoveChange(change) : null)).ToArray();
                await _repository.ApplyPullPageAsync(
                    response.WorkspaceId,
                    response.FromCursor,
                    response.NextCursor,
                    changes,
                    cancellationToken).ConfigureAwait(false);
                pulled += changes.Length;

                if (!response.HasMore)
                {
                    var completeState = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
                    return new SyncRunResult(SyncRunOutcome.Synced, pushed, pulled, completeState.Cursor);
                }
            }

            state = await _repository.SyncStateAsync(cancellationToken).ConfigureAwait(false);
            return new SyncRunResult(SyncRunOutcome.MoreWork, pushed, pulled, state.Cursor);
        }
        finally
        {
            _runGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _runGate.Dispose();
        GC.SuppressFinalize(this);
    }

    private static void ValidateBootstrap(
        ProductIdentity identity,
        WorkspaceSyncState state,
        BootstrapResponseDto response)
    {
        if (response.Session.AccountId != identity.AccountId ||
            !string.Equals(response.Session.IdentityProvider, identity.IdentityProvider, StringComparison.Ordinal) ||
            response.Session.DeviceId != state.DeviceId || response.StartingCursor != 0)
        {
            throw new SyncCoordinatorException("bootstrap_session_scope_mismatch");
        }
    }
}

public sealed class SyncCoordinatorException : Exception
{
    public SyncCoordinatorException(string code)
        : base(code)
    {
        Code = code;
    }

    public string Code { get; }
}
