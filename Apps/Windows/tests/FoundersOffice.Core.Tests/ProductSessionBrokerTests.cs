using FoundersOffice.Core.Auth;

namespace FoundersOffice.Core.Tests;

public sealed class ProductSessionBrokerTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 5, 12, 0, 0, TimeSpan.Zero);
    private static readonly Guid AccountId = Guid.Parse("11111111-1111-4111-8111-111111111111");

    [Fact]
    public async Task SecureRefreshSessionRestoresAcrossBrokerInstances()
    {
        var store = new MemorySessionStore();
        var auth = new FakeAuthClient(AccountId);
        using (var firstBroker = new ProductSessionBroker(auth, store, () => Now))
        {
            var authorizationUri = firstBroker.BeginGoogleSignIn();
            Assert.Equal("https://project.supabase.co/authorize", authorizationUri.AbsoluteUri);
            var identity = await firstBroker.CompleteSignInAsync(
                new Uri("founders-office://auth/callback?code=fixture"));
            Assert.Equal(AccountId, identity.AccountId);
            Assert.Equal("refresh-1", store.Session?.RefreshToken);
        }

        using var restoredBroker = new ProductSessionBroker(auth, store, () => Now);
        var restoredIdentity = await restoredBroker.RestoreAsync();

        Assert.Equal(AccountId, restoredIdentity?.AccountId);
        Assert.Equal("google", restoredIdentity?.IdentityProvider);
        Assert.Equal("access-2", await restoredBroker.GetAccessTokenAsync());
        Assert.Equal("refresh-2", store.Session?.RefreshToken);
        Assert.Equal(1, auth.RefreshCount);
    }

    [Fact]
    public async Task RestoreClearsSessionWhenServerIdentityChanges()
    {
        var store = new MemorySessionStore
        {
            Session = new StoredProductSession(AccountId, "google", "old-refresh"),
        };
        var auth = new FakeAuthClient(Guid.Parse("22222222-2222-4222-8222-222222222222"));
        using var broker = new ProductSessionBroker(auth, store, () => Now);

        var error = await Assert.ThrowsAsync<ProductAuthenticationException>(() => broker.RestoreAsync());

        Assert.Equal("stored_session_identity_mismatch", error.Code);
        Assert.Null(store.Session);
    }

    private sealed class FakeAuthClient(Guid accountId) : IProductAuthClient
    {
        public int RefreshCount { get; private set; }

        public PendingPkceFlow BeginGoogleSignIn() => new(
            new Uri("https://project.supabase.co/authorize"),
            new Uri("founders-office://auth/callback"),
            "verifier",
            Now.AddMinutes(10));

        public Task<ProductSession> ExchangeCodeAsync(
            PendingPkceFlow flow,
            Uri callbackUri,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new ProductSession(
                accountId,
                "google",
                "access-1",
                "refresh-1",
                Now.AddHours(1)));

        public Task<ProductSession> RefreshAsync(
            string refreshToken,
            CancellationToken cancellationToken = default)
        {
            RefreshCount += 1;
            return Task.FromResult(new ProductSession(
                accountId,
                "google",
                $"access-{RefreshCount + 1}",
                $"refresh-{RefreshCount + 1}",
                Now.AddHours(1)));
        }
    }

    private sealed class MemorySessionStore : IProductSessionStore
    {
        public StoredProductSession? Session { get; set; }

        public Task<StoredProductSession?> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(Session);

        public Task SaveAsync(StoredProductSession session, CancellationToken cancellationToken = default)
        {
            Session = session;
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            Session = null;
            return Task.CompletedTask;
        }
    }
}
