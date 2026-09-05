using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Auth;

/// <summary>
/// Keeps access tokens in memory and persists only the minimum refresh session
/// through an operating-system secure store supplied by the app layer.
/// </summary>
public sealed class ProductSessionBroker : IDisposable
{
    private static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(2);
    private readonly IProductAuthClient _authClient;
    private readonly IProductSessionStore _sessionStore;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PendingPkceFlow? _pendingFlow;
    private ProductSession? _session;
    private bool _disposed;

    public ProductSessionBroker(
        IProductAuthClient authClient,
        IProductSessionStore sessionStore,
        Func<DateTimeOffset>? utcNow = null)
    {
        _authClient = authClient;
        _sessionStore = sessionStore;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
    }

    public ProductIdentity? Identity => _session is null
        ? null
        : new ProductIdentity(_session.AccountId, _session.IdentityProvider);

    public Uri BeginGoogleSignIn()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_gate.Wait(0))
        {
            throw new ProductAuthenticationException("auth_operation_in_progress");
        }

        try
        {
            _pendingFlow = _authClient.BeginGoogleSignIn();
            return _pendingFlow.AuthorizationUri;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task CancelPendingSignInAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _pendingFlow = null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<ProductIdentity> CompleteSignInAsync(
        Uri callbackUri,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var flow = _pendingFlow ?? throw new ProductAuthenticationException("auth_flow_missing");
            _pendingFlow = null;
            var session = await _authClient.ExchangeCodeAsync(flow, callbackUri, cancellationToken)
                .ConfigureAwait(false);
            await PersistAsync(session, cancellationToken).ConfigureAwait(false);
            _session = session;
            return new ProductIdentity(session.AccountId, session.IdentityProvider);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<ProductIdentity?> RestoreAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var stored = await _sessionStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            if (stored is null)
            {
                _session = null;
                return null;
            }

            stored.Validate();
            var refreshed = await _authClient.RefreshAsync(stored.RefreshToken, cancellationToken)
                .ConfigureAwait(false);
            if (refreshed.AccountId != stored.AccountId ||
                !string.Equals(refreshed.IdentityProvider, stored.IdentityProvider, StringComparison.Ordinal))
            {
                await _sessionStore.ClearAsync(cancellationToken).ConfigureAwait(false);
                _session = null;
                throw new ProductAuthenticationException("stored_session_identity_mismatch");
            }

            await PersistAsync(refreshed, cancellationToken).ConfigureAwait(false);
            _session = refreshed;
            return new ProductIdentity(refreshed.AccountId, refreshed.IdentityProvider);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var session = _session ?? throw new ProductAuthenticationException("session_missing");
            if (session.ExpiresAt <= _utcNow().Add(RefreshMargin))
            {
                var refreshed = await _authClient.RefreshAsync(session.RefreshToken, cancellationToken)
                    .ConfigureAwait(false);
                if (refreshed.AccountId != session.AccountId ||
                    !string.Equals(refreshed.IdentityProvider, session.IdentityProvider, StringComparison.Ordinal))
                {
                    await _sessionStore.ClearAsync(cancellationToken).ConfigureAwait(false);
                    _session = null;
                    throw new ProductAuthenticationException("session_identity_changed");
                }

                await PersistAsync(refreshed, cancellationToken).ConfigureAwait(false);
                _session = refreshed;
                session = refreshed;
            }

            return session.AccessToken;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SignOutAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _pendingFlow = null;
            _session = null;
            await _sessionStore.ClearAsync(cancellationToken).ConfigureAwait(false);
            if (await _sessionStore.LoadAsync(cancellationToken).ConfigureAwait(false) is not null)
            {
                throw new ProductAuthenticationException("session_removal_failed");
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _pendingFlow = null;
        _session = null;
        _gate.Dispose();
        GC.SuppressFinalize(this);
    }

    private async Task PersistAsync(ProductSession session, CancellationToken cancellationToken)
    {
        var expected = new StoredProductSession(
            session.AccountId,
            session.IdentityProvider,
            session.RefreshToken).Validate();
        await _sessionStore.SaveAsync(expected, cancellationToken).ConfigureAwait(false);
        var persisted = await _sessionStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        if (persisted != expected)
        {
            throw new ProductAuthenticationException("session_persistence_failed");
        }
    }
}
