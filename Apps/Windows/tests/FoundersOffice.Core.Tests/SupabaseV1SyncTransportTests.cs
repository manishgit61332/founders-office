using System.Net;
using System.Text;
using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Tests;

public sealed class SupabaseV1SyncTransportTests
{
    [Fact]
    public async Task BootstrapUsesTheExactRpcAndCredentialHeaders()
    {
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                ReadFixture("bootstrap.response.json"),
                Encoding.UTF8,
                "application/json"),
        });
        using var client = new HttpClient(handler);
        using var transport = new SupabaseV1SyncTransport(
            client,
            new SupabasePublicConfiguration(new Uri("https://project.supabase.co/"), "sb_publishable_fixture"),
            _ => Task.FromResult("access-token-fixture"));

        var response = await transport.BootstrapAsync(new BootstrapRequestDto
        {
            DeviceId = Guid.Parse("22222222-2222-4222-8222-222222222222"),
            LocalWorkspaceId = null,
            WorkspaceName = "Founder's Office",
            ReviewedDisplayName = "Reviewed Founder Name",
        });

        Assert.Equal(1, response.ContractVersion);
        Assert.Equal("https://project.supabase.co/rest/v1/rpc/bootstrap_workspace", handler.RequestUri?.AbsoluteUri);
        Assert.Equal("Bearer", handler.AuthorizationScheme);
        Assert.Equal("access-token-fixture", handler.AuthorizationParameter);
        Assert.Equal("sb_publishable_fixture", handler.ApiKey);
        Assert.Contains("\"p_device_id\":\"22222222-2222-4222-8222-222222222222\"", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("p_local_workspace_id", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("access-token-fixture", handler.Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RedirectIsRefusedWithoutFollowingIt()
    {
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.TemporaryRedirect)
        {
            Headers = { Location = new Uri("https://unexpected.example/rpc") },
        });
        using var client = new HttpClient(handler);
        using var transport = new SupabaseV1SyncTransport(
            client,
            new SupabasePublicConfiguration(new Uri("https://project.supabase.co/"), "sb_publishable_fixture"),
            _ => Task.FromResult("access-token-fixture"));

        var error = await Assert.ThrowsAsync<SyncTransportException>(() =>
            transport.PullAsync(new PullRequestDto
            {
                WorkspaceId = Guid.NewGuid(),
                DeviceId = Guid.NewGuid(),
                Cursor = 0,
                Limit = 200,
            }));

        Assert.Equal("sync_redirect_refused", error.Code);
        Assert.Equal(1, handler.CallCount);
    }

    private static string ReadFixture(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ContractFixtures", name));

    private sealed class CapturingHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public int CallCount { get; private set; }

        public Uri? RequestUri { get; private set; }

        public string? AuthorizationScheme { get; private set; }

        public string? AuthorizationParameter { get; private set; }

        public string? ApiKey { get; private set; }

        public string Body { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount += 1;
            RequestUri = request.RequestUri;
            AuthorizationScheme = request.Headers.Authorization?.Scheme;
            AuthorizationParameter = request.Headers.Authorization?.Parameter;
            ApiKey = request.Headers.GetValues("apikey").Single();
            Body = request.Content is null
                ? string.Empty
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return responseFactory(request);
        }
    }
}
