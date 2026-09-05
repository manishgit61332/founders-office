using System.Net;
using System.Text;
using FoundersOffice.Core.Auth;
using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Tests;

public sealed class SupabaseProductAuthClientTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 5, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData("service_role_fixture")]
    [InlineData("sb_secret_fixture")]
    [InlineData("an-arbitrary-client-key")]
    [InlineData("sb_publishable_placeholder")]
    public void PublicConfigurationRejectsSecretOrUnreviewedKeyShapes(string key)
    {
        var configuration = new SupabasePublicConfiguration(
            new Uri("https://project.supabase.co/"),
            key);

        Assert.Throws<ArgumentException>(() => configuration.Validate());
    }

    [Theory]
    [InlineData("https://accounts.example.test/auth/callback")]
    [InlineData("founders-office://attacker/callback")]
    [InlineData("founders-office://auth/other")]
    [InlineData("founders-office://auth/callback?code=unexpected")]
    public void CallbackConfigurationUsesTheReviewedCustomSchemeBoundary(string callback)
    {
        var configuration = new SupabaseAuthConfiguration(new Uri(callback));

        Assert.Throws<ArgumentException>(() => configuration.Validate());
    }

    [Fact]
    public async Task GooglePkceExchangesOnlyTheAuthorizationCodeAndVerifier()
    {
        var accountId = Guid.Parse("11111111-1111-4111-8111-111111111111");
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                $$"""
                {
                  "access_token": "product-access-token",
                  "token_type": "bearer",
                  "expires_in": 3600,
                  "expires_at": {{Now.AddHours(1).ToUnixTimeSeconds()}},
                  "refresh_token": "product-refresh-token",
                  "user": {
                    "id": "{{accountId:D}}",
                    "app_metadata": { "provider": "google", "providers": ["google"] }
                  }
                }
                """,
                Encoding.UTF8,
                "application/json"),
        });
        using var client = new HttpClient(handler);
        using var authClient = new SupabaseProductAuthClient(
            client,
            new SupabasePublicConfiguration(new Uri("https://project.supabase.co/"), "sb_publishable_fixture"),
            new SupabaseAuthConfiguration(new Uri("founders-office://auth/callback")),
            () => Now);

        var flow = authClient.BeginGoogleSignIn();
        var session = await authClient.ExchangeCodeAsync(
            flow,
            new Uri("founders-office://auth/callback?code=authorization-code"));

        Assert.Equal(accountId, session.AccountId);
        Assert.Equal("google", session.IdentityProvider);
        Assert.Equal("product-access-token", session.AccessToken);
        Assert.Equal("product-refresh-token", session.RefreshToken);
        Assert.StartsWith(
            "https://project.supabase.co/auth/v1/authorize?provider=google&redirect_to=",
            flow.AuthorizationUri.AbsoluteUri,
            StringComparison.Ordinal);
        Assert.Contains("code_challenge_method=s256", flow.AuthorizationUri.Query, StringComparison.Ordinal);
        Assert.Equal(
            "https://project.supabase.co/auth/v1/token?grant_type=pkce",
            handler.RequestUri?.AbsoluteUri);
        Assert.Equal("sb_publishable_fixture", handler.ApiKey);
        Assert.Contains("\"auth_code\":\"authorization-code\"", handler.Body, StringComparison.Ordinal);
        Assert.Contains("\"code_verifier\":", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("product-access-token", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("product-refresh-token", handler.Body, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("other-app://auth/callback?code=synthetic")]
    [InlineData("founders-office-dev://auth/callback?code=synthetic")]
    [InlineData("founders-office://auth/Callback?code=synthetic")]
    [InlineData("founders-office://auth/callback/?code=synthetic")]
    [InlineData("founders-office://auth/callback%2f?code=synthetic")]
    [InlineData("founders-office://auth/%63allback?code=synthetic")]
    [InlineData("founders-office://auth/other/../callback?code=synthetic")]
    [InlineData("founders-office://auth:1234/callback?code=synthetic")]
    [InlineData("founders-office://user@auth/callback?code=synthetic")]
    [InlineData("founders-office://auth/callback?code=synthetic#fragment")]
    [InlineData("founders-office://auth/callback?code=synthetic&code=duplicate")]
    public async Task InvalidCallbackIsRejectedBeforeNetworkAccess(string callback)
    {
        var handler = new CapturingHandler(_ => throw new InvalidOperationException("Network must not be used."));
        using var client = new HttpClient(handler);
        using var authClient = new SupabaseProductAuthClient(
            client,
            new SupabasePublicConfiguration(new Uri("https://project.supabase.co/"), "sb_publishable_fixture"),
            new SupabaseAuthConfiguration(new Uri("founders-office://auth/callback")),
            () => Now);
        var flow = authClient.BeginGoogleSignIn();

        var error = await Assert.ThrowsAsync<ProductAuthenticationException>(() =>
            authClient.ExchangeCodeAsync(flow, new Uri(callback)));

        Assert.Equal("auth_callback_invalid", error.Code);
        Assert.Equal(0, handler.CallCount);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ExpiredOrRetargetedPendingFlowIsRejectedBeforeNetworkAccess(bool expired)
    {
        var handler = new CapturingHandler(_ => throw new InvalidOperationException("Network must not be used."));
        using var client = new HttpClient(handler);
        using var authClient = new SupabaseProductAuthClient(
            client,
            new SupabasePublicConfiguration(new Uri("https://project.supabase.co/"), "sb_publishable_fixture"),
            new SupabaseAuthConfiguration(new Uri("founders-office://auth/callback")),
            () => Now);
        var flow = authClient.BeginGoogleSignIn();
        flow = expired
            ? flow with { ExpiresAt = Now }
            : flow with { CallbackUri = new Uri("other-app://auth/callback") };

        var error = await Assert.ThrowsAsync<ProductAuthenticationException>(() =>
            authClient.ExchangeCodeAsync(flow, new Uri("founders-office://auth/callback?code=synthetic")));

        Assert.Equal("auth_callback_invalid", error.Code);
        Assert.Equal(0, handler.CallCount);
    }

    private sealed class CapturingHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public int CallCount { get; private set; }

        public Uri? RequestUri { get; private set; }

        public string? ApiKey { get; private set; }

        public string Body { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount += 1;
            RequestUri = request.RequestUri;
            ApiKey = request.Headers.GetValues("apikey").Single();
            Body = request.Content is null
                ? string.Empty
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return responseFactory(request);
        }
    }
}
