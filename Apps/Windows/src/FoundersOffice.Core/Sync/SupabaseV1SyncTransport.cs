using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace FoundersOffice.Core.Sync;

public sealed record SupabasePublicConfiguration(Uri ProjectUrl, string PublishableKey)
{
    public SupabasePublicConfiguration Validate()
    {
        if (!ProjectUrl.IsAbsoluteUri || ProjectUrl.Scheme != Uri.UriSchemeHttps ||
            !string.Equals(ProjectUrl.AbsolutePath, "/", StringComparison.Ordinal) ||
            !string.IsNullOrEmpty(ProjectUrl.Query) || !string.IsNullOrEmpty(ProjectUrl.Fragment))
        {
            throw new ArgumentException("The Supabase project URL must be an HTTPS origin.", nameof(ProjectUrl));
        }

        if (!IsPublishableClientKey(PublishableKey))
        {
            throw new ArgumentException("A valid Supabase publishable key is required.", nameof(PublishableKey));
        }

        return this;
    }

    private static bool IsPublishableClientKey(string key)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Length > 4096 || key.Any(char.IsWhiteSpace) ||
            key.Contains("placeholder", StringComparison.OrdinalIgnoreCase) ||
            key.Contains("$(", StringComparison.Ordinal) ||
            key.StartsWith("sb_secret_", StringComparison.Ordinal) ||
            key.StartsWith("service_role", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (key.StartsWith("sb_publishable_", StringComparison.Ordinal))
        {
            return key.Length >= 20;
        }

        var segments = key.Split('.');
        if (segments.Length != 3)
        {
            return false;
        }

        try
        {
            var payload = segments[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + ((4 - (payload.Length % 4)) % 4), '=');
            using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
            return document.RootElement.TryGetProperty("role", out var role) &&
                string.Equals(role.GetString(), "anon", StringComparison.Ordinal);
        }
        catch (FormatException)
        {
            return false;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}

/// <summary>
/// Credential-sparse HTTPS adapter for the shared v1 RPCs. The access token is
/// requested immediately before each call and is never retained or logged.
/// </summary>
public sealed class SupabaseV1SyncTransport : IV1SyncTransport, IDisposable
{
    private const int MaximumResponseBytes = 4 * 1024 * 1024;
    private readonly HttpClient _httpClient;
    private readonly SupabasePublicConfiguration _configuration;
    private readonly Func<CancellationToken, Task<string>> _accessTokenProvider;
    private readonly bool _ownsHttpClient;
    private bool _disposed;

    public SupabaseV1SyncTransport(
        HttpClient httpClient,
        SupabasePublicConfiguration configuration,
        Func<CancellationToken, Task<string>> accessTokenProvider)
        : this(httpClient, configuration, accessTokenProvider, ownsHttpClient: false)
    {
    }

    private SupabaseV1SyncTransport(
        HttpClient httpClient,
        SupabasePublicConfiguration configuration,
        Func<CancellationToken, Task<string>> accessTokenProvider,
        bool ownsHttpClient)
    {
        _httpClient = httpClient;
        _configuration = configuration.Validate();
        _accessTokenProvider = accessTokenProvider;
        _ownsHttpClient = ownsHttpClient;
    }

    public static SupabaseV1SyncTransport Create(
        SupabasePublicConfiguration configuration,
        Func<CancellationToken, Task<string>> accessTokenProvider)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ConnectTimeout = TimeSpan.FromSeconds(15),
        };
        return new SupabaseV1SyncTransport(
            new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) },
            configuration,
            accessTokenProvider,
            ownsHttpClient: true);
    }

    public async Task<BootstrapResponseDto> BootstrapAsync(
        BootstrapRequestDto request,
        CancellationToken cancellationToken = default)
    {
        var json = await PostAsync(
            "rest/v1/rpc/bootstrap_workspace",
            V1ContractAdapter.SerializeBootstrapRequest(request),
            cancellationToken).ConfigureAwait(false);
        return V1ContractAdapter.ParseBootstrapResponse(json);
    }

    public async Task<PushResponseDto> PushAsync(
        PushRequestDto request,
        CancellationToken cancellationToken = default)
    {
        var json = await PostAsync(
            "rest/v1/rpc/push_operations",
            V1ContractAdapter.SerializePushRequest(request),
            cancellationToken).ConfigureAwait(false);
        return V1ContractAdapter.ParsePushResponse(json);
    }

    public async Task<PullResponseDto> PullAsync(
        PullRequestDto request,
        CancellationToken cancellationToken = default)
    {
        var json = await PostAsync(
            "rest/v1/rpc/pull_changes",
            V1ContractAdapter.SerializePullRequest(request),
            cancellationToken).ConfigureAwait(false);
        return V1ContractAdapter.ParsePullResponse(json);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }

        GC.SuppressFinalize(this);
    }

    private async Task<string> PostAsync(
        string relativePath,
        string json,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var accessToken = await _accessTokenProvider(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(accessToken) || accessToken.Length > 16_384 || accessToken.Any(char.IsWhiteSpace))
        {
            throw new SyncTransportException("session_token_invalid");
        }

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(_configuration.ProjectUrl, relativePath));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.Add("apikey", _configuration.PublishableKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");

        using var response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is >= HttpStatusCode.MultipleChoices and < HttpStatusCode.BadRequest)
        {
            throw new SyncTransportException("sync_redirect_refused");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new SyncTransportException(response.StatusCode switch
            {
                HttpStatusCode.BadRequest => "sync_request_rejected",
                HttpStatusCode.Unauthorized => "session_unauthorized",
                HttpStatusCode.Forbidden => "workspace_forbidden",
                HttpStatusCode.Conflict => "workspace_attachment_conflict",
                HttpStatusCode.ServiceUnavailable => "sync_service_unavailable",
                _ => "sync_request_failed",
            });
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (!string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase))
        {
            throw new SyncTransportException("sync_content_type_invalid");
        }

        if (response.Content.Headers.ContentLength is > MaximumResponseBytes)
        {
            throw new SyncTransportException("sync_response_too_large");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                break;
            }

            if (output.Length + count > MaximumResponseBytes)
            {
                throw new SyncTransportException("sync_response_too_large");
            }

            await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
        }

        return Encoding.UTF8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
    }
}

public sealed class SyncTransportException : Exception
{
    public SyncTransportException(string code)
        : base(code)
    {
        Code = code;
    }

    public string Code { get; }
}
