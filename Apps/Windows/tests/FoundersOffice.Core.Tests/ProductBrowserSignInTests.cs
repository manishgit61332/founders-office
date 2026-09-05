using FoundersOffice.Core.Auth;
using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Tests;

public sealed class ProductBrowserSignInTests
{
    private static readonly WindowsProductConfiguration Configuration = new(
        new SupabasePublicConfiguration(new Uri("https://project.supabase.co"), "sb_publishable_fixture"),
        new SupabaseAuthConfiguration(new Uri(WindowsProductConfiguration.DevelopmentCallback)));
    private static readonly Uri Callback = new(WindowsProductConfiguration.DevelopmentCallback + "?code=synthetic");

    [Fact]
    public void RegistrationGateDoesNotConstructServicesForMissingOrDifferentApproval()
    {
        var calls = 0;
        ProductSessionBroker Factory(WindowsProductConfiguration _) { calls++; return new(new TestAuth(), new MemoryStore()); }
        var approval = new ReviewedProductAuthRegistration(ReviewedProductAuthRegistration.Fingerprint(Configuration));

        Assert.Null(ReviewedProductAuthRegistration.CreateBrokerIfApproved(Configuration, null, Factory));
        Assert.Null(ReviewedProductAuthRegistration.CreateBrokerIfApproved(
            Configuration with { Public = Configuration.Public with { PublishableKey = "sb_publishable_different_fixture" } }, approval, Factory));
        Assert.Null(ReviewedProductAuthRegistration.CreateBrokerIfApproved(
            Configuration with { Public = Configuration.Public with { ProjectUrl = new Uri("https://other.supabase.co") } }, approval, Factory));
        Assert.Null(ReviewedProductAuthRegistration.CreateBrokerIfApproved(
            Configuration with { Auth = new SupabaseAuthConfiguration(new Uri("founders-office://auth/callback")) }, approval, Factory));
        Assert.Equal(0, calls);
        using var broker = ReviewedProductAuthRegistration.CreateBrokerIfApproved(Configuration, approval, Factory);
        Assert.NotNull(broker);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task BrowserAttemptAcceptsOneCallbackAndPublishesOnlyDurableIdentity()
    {
        var auth = new TestAuth();
        var store = new MemoryStore();
        using var broker = new ProductSessionBroker(auth, store);
        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var browser = new ProductBrowserSignIn(broker, Configuration.Auth, (_, _) =>
        {
            opened.SetResult();
            return Task.FromResult(true);
        });

        var attempt = browser.StartAsync();
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(ProductCallbackOutcome.AlreadyInProgress, await browser.StartAsync());
        Assert.Equal(ProductCallbackOutcome.Rejected,
            await browser.RouteAsync(new Uri("other-app://auth/callback?code=synthetic")));
        Assert.False(attempt.IsCompleted);
        Assert.Null(broker.Identity);
        Assert.Equal(ProductCallbackOutcome.ProductSignedIn, await browser.RouteAsync(Callback));
        Assert.Equal(ProductCallbackOutcome.ProductSignedIn, await attempt.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.NotNull(broker.Identity);
        Assert.Equal(1, store.SaveCount);
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await browser.RouteAsync(Callback));
        Assert.Equal(1, auth.Exchanges);
    }

    [Fact]
    public async Task ManualCancellationClearsOnlyThePendingAttempt()
    {
        var auth = new TestAuth();
        var store = new MemoryStore();
        using var broker = new ProductSessionBroker(auth, store);
        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var browser = new ProductBrowserSignIn(broker, Configuration.Auth, (_, _) =>
        {
            opened.SetResult();
            return Task.FromResult(true);
        });
        var attempt = browser.StartAsync();
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(5));

        browser.Cancel();

        Assert.Equal(ProductCallbackOutcome.Cancelled, await attempt.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await browser.RouteAsync(Callback));
        Assert.Equal(0, auth.Exchanges);
        Assert.Equal(0, store.SaveCount);
    }

    [Fact]
    public async Task RefusedBrowserLaunchLeavesNoReusablePendingFlow()
    {
        var auth = new TestAuth();
        using var broker = new ProductSessionBroker(auth, new MemoryStore());
        await using var browser = new ProductBrowserSignIn(broker, Configuration.Auth, (_, _) => Task.FromResult(false));

        Assert.Equal(ProductCallbackOutcome.Failed, await browser.StartAsync());
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await browser.RouteAsync(Callback));
        Assert.Equal(0, auth.Exchanges);
    }

    [Fact]
    public async Task SecureReadBackFailureCannotPublishSignedIn()
    {
        using var broker = new ProductSessionBroker(new TestAuth(), new MemoryStore { FailReadBack = true });
        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var browser = new ProductBrowserSignIn(broker, Configuration.Auth, (_, _) =>
        {
            opened.SetResult();
            return Task.FromResult(true);
        });
        var attempt = browser.StartAsync();
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(ProductCallbackOutcome.Rejected, await browser.RouteAsync(Callback));
        Assert.Equal(ProductCallbackOutcome.Rejected, await attempt.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Null(broker.Identity);
    }

    [Fact]
    public async Task TenMinuteDeadlineExpiresWithoutLeavingAPendingVerifier()
    {
        var auth = new TestAuth();
        using var broker = new ProductSessionBroker(auth, new MemoryStore());
        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var time = new ControlledTimeProvider();
        await using var browser = new ProductBrowserSignIn(broker, Configuration.Auth, (_, _) =>
        {
            opened.SetResult();
            return Task.FromResult(true);
        }, time);
        var attempt = browser.StartAsync();
        await opened.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(TimeSpan.FromMinutes(10), time.DueTime);
        time.Fire();

        Assert.Equal(ProductCallbackOutcome.TimedOut, await attempt.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(ProductCallbackOutcome.NoPendingFlow, await browser.RouteAsync(Callback));
        Assert.Equal(0, auth.Exchanges);
    }

    private sealed class ControlledTimeProvider : TimeProvider, IDisposable
    {
        private ControlledTimer? _timer;
        public TimeSpan DueTime { get; private set; }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            DueTime = dueTime;
            _timer = new ControlledTimer(callback, state);
            return _timer;
        }
        public void Fire() => _timer!.Fire();
        public void Dispose() => _timer?.Dispose();

        private sealed class ControlledTimer(TimerCallback callback, object? state) : ITimer
        {
            private bool _disposed;
            public bool Change(TimeSpan dueTime, TimeSpan period) => !_disposed;
            public void Dispose() => _disposed = true;
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
            public void Fire() { if (!_disposed) { callback(state); } }
        }
    }

    private sealed class TestAuth : IProductAuthClient
    {
        public int Exchanges { get; private set; }
        public PendingPkceFlow BeginGoogleSignIn() => new(new Uri("https://project.supabase.co/authorize"),
            Configuration.Auth.CallbackUri, "synthetic-verifier", DateTimeOffset.UtcNow.AddMinutes(10));
        public Task<ProductSession> ExchangeCodeAsync(PendingPkceFlow flow, Uri callbackUri, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Exchanges++;
            return Task.FromResult(new ProductSession(Guid.Parse("11111111-1111-4111-8111-111111111111"),
                "google", "synthetic-access", "synthetic-refresh", DateTimeOffset.UtcNow.AddHours(1)));
        }
        public Task<ProductSession> RefreshAsync(string refreshToken, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("No refresh is needed in this fixture.");
    }

    private sealed class MemoryStore : IProductSessionStore
    {
        private StoredProductSession? _session;
        public int SaveCount { get; private set; }
        public bool FailReadBack { get; init; }
        public Task<StoredProductSession?> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(FailReadBack ? null : _session);
        public Task SaveAsync(StoredProductSession session, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _session = session;
            SaveCount++;
            return Task.CompletedTask;
        }
        public Task ClearAsync(CancellationToken cancellationToken = default) { _session = null; return Task.CompletedTask; }
    }
}
