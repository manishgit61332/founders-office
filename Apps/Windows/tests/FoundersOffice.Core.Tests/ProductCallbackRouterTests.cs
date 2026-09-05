using FoundersOffice.Core.Auth;

namespace FoundersOffice.Core.Tests;

public sealed class ProductCallbackRouterTests
{
    private static readonly SupabaseAuthConfiguration Configuration = new(
        new Uri(WindowsProductConfiguration.DevelopmentCallback));
    private static readonly Uri Callback = new(WindowsProductConfiguration.DevelopmentCallback + "?code=synthetic");

    [Fact]
    public async Task DevelopmentBuildCannotConstructASessionFromAProtocolLaunch()
    {
        var router = new ProductCallbackRouter(Configuration);

        Assert.Equal(ProductCallbackOutcome.SignInUnavailable, await router.RouteAsync(Callback));
        Assert.Equal(ProductCallbackOutcome.Rejected, await router.RouteAsync(null));
        Assert.Equal(ProductCallbackOutcome.Rejected, await router.RouteAsync(new Uri("/callback", UriKind.Relative)));
        Assert.Equal(ProductCallbackOutcome.Rejected, await router.RouteAsync(new Uri(
            WindowsProductConfiguration.DevelopmentCallback + "?code=" +
            new string('x', ProductCallbackRouter.MaximumCallbackCharacters))));
    }

    [Theory]
    [InlineData("other-app://auth/callback?code=synthetic")]
    [InlineData("founders-office://auth/callback?code=synthetic")]
    [InlineData("founders-office-dev://auth/Callback?code=synthetic")]
    [InlineData("founders-office-dev://auth/callback/?code=synthetic")]
    [InlineData("founders-office-dev://auth/%63allback?code=synthetic")]
    [InlineData("founders-office-dev://auth/callback?code=synthetic#fragment")]
    public async Task ForeignOrMalformedActivationDoesNotConsumeThePendingFlow(string callback)
    {
        var auth = new SyntheticAuthClient();
        var store = new MemoryStore();
        using var broker = new ProductSessionBroker(auth, store);
        var router = new ProductCallbackRouter(Configuration, broker);
        broker.BeginGoogleSignIn();

        Assert.Equal(ProductCallbackOutcome.Rejected, await router.RouteAsync(new Uri(callback)));
        Assert.Equal(0, auth.ExchangeCount);
        Assert.Equal(0, store.SaveCount);
        Assert.Equal(ProductCallbackOutcome.ProductSignedIn, await router.RouteAsync(Callback));
        Assert.Equal(1, auth.ExchangeCount);
    }

    [Fact]
    public async Task ColdStartAndAnotherBrokerCannotRecoverTheOwningProcessVerifier()
    {
        var auth = new SyntheticAuthClient();
        var store = new MemoryStore();
        using var owner = new ProductSessionBroker(auth, store);
        using var other = new ProductSessionBroker(auth, store);
        owner.BeginGoogleSignIn();

        Assert.Equal(ProductCallbackOutcome.NoPendingFlow,
            await new ProductCallbackRouter(Configuration, other).RouteAsync(Callback));
        Assert.Null(other.Identity);
        Assert.Equal(0, auth.ExchangeCount);
        Assert.Equal(ProductCallbackOutcome.ProductSignedIn,
            await new ProductCallbackRouter(Configuration, owner).RouteAsync(Callback));
        Assert.Equal(1, auth.ExchangeCount);
        Assert.Equal(1, store.SaveCount);
    }

    [Fact]
    public async Task ConcurrentDeliveryAndReplayExchangeAndPersistExactlyOnce()
    {
        var auth = new SyntheticAuthClient();
        var store = new MemoryStore();
        using var broker = new ProductSessionBroker(auth, store);
        var router = new ProductCallbackRouter(Configuration, broker);
        broker.BeginGoogleSignIn();

        var outcomes = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(() => router.RouteAsync(Callback))));

        Assert.Single(outcomes, outcome => outcome == ProductCallbackOutcome.ProductSignedIn);
        Assert.Equal(7, outcomes.Count(outcome => outcome == ProductCallbackOutcome.NoPendingFlow));
        Assert.Equal(1, auth.ExchangeCount);
        Assert.Equal(1, store.SaveCount);
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await router.RouteAsync(Callback));
    }

    [Fact]
    public async Task FailedExchangeReturnsOnlyAnOutcomeAndCannotBeReplayed()
    {
        var auth = new SyntheticAuthClient { FailExchange = true };
        var store = new MemoryStore();
        using var broker = new ProductSessionBroker(auth, store);
        var router = new ProductCallbackRouter(Configuration, broker);
        broker.BeginGoogleSignIn();

        Assert.Equal(ProductCallbackOutcome.Failed, await router.RouteAsync(Callback));
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await router.RouteAsync(Callback));
        Assert.Equal(0, store.SaveCount);
        Assert.Null(broker.Identity);
    }

    private sealed class SyntheticAuthClient : IProductAuthClient
    {
        public int ExchangeCount { get; private set; }
        public bool FailExchange { get; init; }

        public PendingPkceFlow BeginGoogleSignIn() => new(
            new Uri("https://project.supabase.co/authorize"), Configuration.CallbackUri,
            "synthetic-in-memory-verifier", DateTimeOffset.UtcNow.AddMinutes(10));

        public async Task<ProductSession> ExchangeCodeAsync(
            PendingPkceFlow flow, Uri callbackUri, CancellationToken cancellationToken = default)
        {
            ExchangeCount += 1;
            await Task.Yield();
            if (FailExchange)
            {
                throw new InvalidOperationException("synthetic-sensitive-error-must-not-escape");
            }

            return new ProductSession(Guid.Parse("11111111-1111-4111-8111-111111111111"),
                "google", "synthetic-access", "synthetic-refresh", DateTimeOffset.UtcNow.AddHours(1));
        }

        public Task<ProductSession> RefreshAsync(string refreshToken, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Refresh must not reconstruct a pending sign-in.");
    }

    private sealed class MemoryStore : IProductSessionStore
    {
        private StoredProductSession? _session;
        public int SaveCount { get; private set; }

        public Task<StoredProductSession?> LoadAsync(CancellationToken cancellationToken = default) => Task.FromResult(_session);

        public Task SaveAsync(StoredProductSession session, CancellationToken cancellationToken = default)
        {
            _session = session;
            SaveCount += 1;
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _session = null;
            return Task.CompletedTask;
        }
    }
}
