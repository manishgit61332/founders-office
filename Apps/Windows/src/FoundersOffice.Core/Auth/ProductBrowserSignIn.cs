namespace FoundersOffice.Core.Auth;

/// <summary>
/// Owns one bounded browser attempt. Callback delivery never starts an attempt.
/// The caller must supply a registration-approved broker and owns its lifetime.
/// </summary>
public sealed class ProductBrowserSignIn : IAsyncDisposable
{
    public static readonly TimeSpan MaximumDuration = TimeSpan.FromMinutes(10);
    private readonly ProductSessionBroker _broker;
    private readonly SupabaseAuthConfiguration _configuration;
    private readonly ProductCallbackRouter _router;
    private readonly Func<Uri, CancellationToken, Task<bool>> _launchBrowser;
    private readonly TimeProvider _timeProvider;
    private readonly object _lock = new();
    private CancellationTokenSource? _attemptCancellation;
    private TaskCompletionSource<ProductCallbackOutcome>? _completion;
    private Task<ProductCallbackOutcome>? _attempt;
    private bool _disposed;
    private bool _cancelRequested;

    public ProductBrowserSignIn(
        ProductSessionBroker broker,
        SupabaseAuthConfiguration configuration,
        Func<Uri, CancellationToken, Task<bool>> launchBrowser,
        TimeProvider? timeProvider = null)
    {
        _broker = broker;
        _configuration = configuration.Validate();
        _router = new ProductCallbackRouter(configuration, broker);
        _launchBrowser = launchBrowser;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public Task<ProductCallbackOutcome> StartAsync(CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_attemptCancellation is not null)
            {
                return Task.FromResult(ProductCallbackOutcome.AlreadyInProgress);
            }

            var deadline = new CancellationTokenSource(MaximumDuration, _timeProvider);
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
            var completion = new TaskCompletionSource<ProductCallbackOutcome>(TaskCreationOptions.RunContinuationsAsynchronously);
            _attemptCancellation = cancellation;
            _cancelRequested = false;
            _completion = completion;
            _attempt = RunAsync(cancellation, deadline, completion, cancellationToken);
            return _attempt;
        }
    }

    public async Task<ProductCallbackOutcome> RouteAsync(Uri? callback)
    {
        if (callback is null || callback.OriginalString.Length > ProductCallbackRouter.MaximumCallbackCharacters ||
            !_configuration.AcceptsCallbackResponse(callback))
        {
            return ProductCallbackOutcome.Rejected;
        }

        TaskCompletionSource<ProductCallbackOutcome>? completion;
        CancellationToken cancellationToken;
        lock (_lock)
        {
            completion = _completion;
            cancellationToken = _attemptCancellation?.Token ?? new CancellationToken(canceled: true);
        }

        if (completion is null || cancellationToken.IsCancellationRequested)
        {
            return ProductCallbackOutcome.NoPendingFlow;
        }

        var outcome = await _router.RouteAsync(callback, cancellationToken).ConfigureAwait(false);
        // A concurrent replay must not beat the original exchange's completion.
        if (outcome != ProductCallbackOutcome.NoPendingFlow)
        {
            completion.TrySetResult(outcome);
        }

        return outcome;
    }

    public void Cancel()
    {
        lock (_lock)
        {
            _cancelRequested = true;
            _attemptCancellation?.Cancel();
        }
    }

    public async ValueTask DisposeAsync()
    {
        Task<ProductCallbackOutcome>? attempt;
        lock (_lock)
        {
            _disposed = true;
            _attemptCancellation?.Cancel();
            attempt = _attempt;
        }

        if (attempt is not null)
        {
            await attempt.ConfigureAwait(false);
        }

        GC.SuppressFinalize(this);
    }

    private async Task<ProductCallbackOutcome> RunAsync(
        CancellationTokenSource cancellation,
        CancellationTokenSource deadline,
        TaskCompletionSource<ProductCallbackOutcome> completion,
        CancellationToken callerCancellation)
    {
        // Leave the setup lock before invoking caller-provided browser code.
        await Task.Yield();
        try
        {
            cancellation.Token.ThrowIfCancellationRequested();
            var authorizationUri = _broker.BeginGoogleSignIn();
            if (!await _launchBrowser(authorizationUri, cancellation.Token).WaitAsync(cancellation.Token).ConfigureAwait(false))
            {
                return ProductCallbackOutcome.Failed;
            }

            return await completion.Task.WaitAsync(cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            lock (_lock)
            {
                return callerCancellation.IsCancellationRequested || _disposed || _cancelRequested
                    ? ProductCallbackOutcome.Cancelled
                    : ProductCallbackOutcome.TimedOut;
            }
        }
        catch (Exception)
        {
            return ProductCallbackOutcome.Failed;
        }
        finally
        {
            cancellation.Cancel();
            await _broker.CancelPendingSignInAsync(CancellationToken.None).ConfigureAwait(false);
            lock (_lock)
            {
                _completion = null;
                _attemptCancellation = null;
                cancellation.Dispose();
                deadline.Dispose();
            }
        }
    }
}
