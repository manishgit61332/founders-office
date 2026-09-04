using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Auth;

/// <summary>
/// Implements Supabase Auth's Google PKCE flow. Provider credentials never
/// enter the app; only the resulting product session crosses this boundary.
/// </summary>
public sealed class SupabaseProductAuthClient : IProductAuthClient, IDisposable
{
    private const int MaximumResponseBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    private readonly HttpClient _httpClient;
    private readonly SupabasePublicConfiguration _publicConfiguration;
    private readonly SupabaseAuthConfiguration _authConfiguration;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly bool _ownsHttpClient;
    private bool _disposed;

    public SupabaseProductAuthClient(
        HttpClient httpClient,
        SupabasePublicConfiguration publicConfiguration,
        SupabaseAuthConfiguration authConfiguration,
        Func<DateTimeOffset>? utcNow = null)
        : this(httpClient, publicConfiguration, authConfiguration, utcNow, ownsHttpClient: false)
    {
    }

    private SupabaseProductAuthClient(
        HttpClient httpClient,
        SupabasePublicConfiguration publicConfiguration,
        SupabaseAuthConfiguration authConfiguration,
        Func<DateTimeOffset>? utcNow,
        bool ownsHttpClient)
    {
        _httpClient = httpClient;
        _publicConfiguration = publicConfiguration.Validate();
        _authConfiguration = authConfiguration.Validate();
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
        _ownsHttpClient = ownsHttpClient;
    }

    public static SupabaseProductAuthClient Create(
        SupabasePublicConfiguration publicConfiguration,
        SupabaseAuthConfiguration authConfiguration)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ConnectTimeout = TimeSpan.FromSeconds(15),
        };
        return new SupabaseProductAuthClient(
            new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) },
            publicConfiguration,
            authConfiguration,
            utcNow: null,
            ownsHttpClient: true);
    }

    public PendingPkceFlow BeginGoogleSignIn()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var query = string.Join(
            "&",
            "provider=google",
            $"redirect_to={Uri.EscapeDataString(_authConfiguration.CallbackUri.AbsoluteUri)}",
            $"code_challenge={Uri.EscapeDataString(challenge)}",
            "code_challenge_method=s256");
        var authorizationUri = new Uri(
            _publicConfiguration.ProjectUrl,
            $"auth/v1/authorize?{query}");
        return new PendingPkceFlow(
            authorizationUri,
            _authConfiguration.CallbackUri,
            verifier,
            _utcNow().AddMinutes(10));
    }

    public async Task<ProductSession> ExchangeCodeAsync(
        PendingPkceFlow flow,
        Uri callbackUri,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_utcNow() > flow.ExpiresAt || !CallbackMatches(flow.CallbackUri, callbackUri))
        {
            throw new ProductAuthenticationException("auth_callback_invalid");
        }

        var query = ParseQuery(callbackUri.Query);
        if (query.ContainsKey("error"))
        {
            throw new ProductAuthenticationException("auth_provider_refused");
        }

        if (!query.TryGetValue("code", out var code) || !IsValidCode(code) ||
            string.IsNullOrWhiteSpace(flow.CodeVerifier) || flow.CodeVerifier.Length > 256)
        {
            throw new ProductAuthenticationException("auth_callback_invalid");
        }

        var body = JsonSerializer.Serialize(
            new PkceExchangeRequest(code, flow.CodeVerifier),
            JsonOptions);
        return await PostTokenAsync("pkce", body, cancellationToken).ConfigureAwait(false);
    }

    public Task<ProductSession> RefreshAsync(
        string refreshToken,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!IsValidCode(refreshToken))
        {
            throw new ProductAuthenticationException("stored_session_invalid");
        }

        var body = JsonSerializer.Serialize(new RefreshRequest(refreshToken), JsonOptions);
        return PostTokenAsync("refresh_token", body, cancellationToken);
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

    private async Task<ProductSession> PostTokenAsync(
        string grantType,
        string json,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(_publicConfiguration.ProjectUrl, $"auth/v1/token?grant_type={grantType}"));
        request.Headers.Add("apikey", _publicConfiguration.PublishableKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");

        using var response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is >= HttpStatusCode.MultipleChoices and < HttpStatusCode.BadRequest)
        {
            throw new ProductAuthenticationException("auth_redirect_refused");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new ProductAuthenticationException(response.StatusCode switch
            {
                HttpStatusCode.BadRequest => "auth_exchange_rejected",
                HttpStatusCode.Unauthorized => "session_unauthorized",
                HttpStatusCode.TooManyRequests => "auth_rate_limited",
                HttpStatusCode.ServiceUnavailable => "auth_service_unavailable",
                _ => "auth_request_failed",
            });
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (!string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase))
        {
            throw new ProductAuthenticationException("auth_content_type_invalid");
        }

        var jsonResponse = await ReadBoundedResponseAsync(response, cancellationToken).ConfigureAwait(false);
        try
        {
            var payload = JsonSerializer.Deserialize<TokenResponse>(jsonResponse, JsonOptions)
                ?? throw new ProductAuthenticationException("auth_response_invalid");
            var provider = payload.User?.AppMetadata?.Provider;
            var expiresAt = payload.ExpiresAt is { } unixSeconds
                ? DateTimeOffset.FromUnixTimeSeconds(unixSeconds)
                : _utcNow().AddSeconds(payload.ExpiresIn);
            if (!string.Equals(payload.TokenType, "bearer", StringComparison.OrdinalIgnoreCase) ||
                payload.User is null || payload.User.Id == Guid.Empty ||
                provider is not ("google" or "apple") ||
                payload.AccessToken is null || payload.RefreshToken is null ||
                payload.ExpiresIn <= 0 || expiresAt <= _utcNow())
            {
                throw new ProductAuthenticationException("auth_response_invalid");
            }

            return new ProductSession(
                payload.User.Id,
                provider,
                payload.AccessToken,
                payload.RefreshToken,
                expiresAt).Validate();
        }
        catch (JsonException exception)
        {
            throw new ProductAuthenticationException("auth_response_invalid", exception);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new ProductAuthenticationException("auth_response_invalid", exception);
        }
    }

    private static async Task<string> ReadBoundedResponseAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is > MaximumResponseBytes)
        {
            throw new ProductAuthenticationException("auth_response_too_large");
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
                throw new ProductAuthenticationException("auth_response_too_large");
            }

            await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
        }

        return Encoding.UTF8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
    }

    private static bool CallbackMatches(Uri expected, Uri actual) =>
        string.Equals(
            expected.GetLeftPart(UriPartial.Path).TrimEnd('/'),
            actual.GetLeftPart(UriPartial.Path).TrimEnd('/'),
            StringComparison.OrdinalIgnoreCase) &&
        string.IsNullOrEmpty(actual.Fragment) &&
        string.IsNullOrEmpty(actual.UserInfo);

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            var key = Uri.UnescapeDataString(parts[0].Replace('+', ' '));
            var value = parts.Length == 2
                ? Uri.UnescapeDataString(parts[1].Replace('+', ' '))
                : string.Empty;
            if (!values.TryAdd(key, value))
            {
                throw new ProductAuthenticationException("auth_callback_invalid");
            }
        }

        return values;
    }

    private static bool IsValidCode(string value) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= 16_384 && !value.Any(char.IsWhiteSpace);

    private static string Base64Url(byte[] value) =>
        Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private sealed record PkceExchangeRequest(
        [property: JsonPropertyName("auth_code")] string AuthCode,
        [property: JsonPropertyName("code_verifier")] string CodeVerifier);

    private sealed record RefreshRequest(
        [property: JsonPropertyName("refresh_token")] string RefreshToken);

    private sealed record TokenResponse(
        [property: JsonPropertyName("access_token")] string? AccessToken,
        [property: JsonPropertyName("token_type")] string? TokenType,
        [property: JsonPropertyName("expires_in")] long ExpiresIn,
        [property: JsonPropertyName("expires_at")] long? ExpiresAt,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken,
        [property: JsonPropertyName("user")] AuthUser? User);

    private sealed record AuthUser(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("app_metadata")] AuthAppMetadata? AppMetadata);

    private sealed record AuthAppMetadata(
        [property: JsonPropertyName("provider")] string? Provider);
}
