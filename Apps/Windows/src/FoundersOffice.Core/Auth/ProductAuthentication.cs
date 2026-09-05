namespace FoundersOffice.Core.Auth;

public sealed record SupabaseAuthConfiguration(Uri CallbackUri)
{
    public SupabaseAuthConfiguration Validate()
    {
        if (!CallbackUri.IsAbsoluteUri || CallbackUri.Scheme is not ("founders-office" or "founders-office-dev") ||
            !string.Equals(CallbackUri.Host, "auth", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(CallbackUri.AbsolutePath, "/callback", StringComparison.Ordinal) ||
            CallbackUri.Port != -1 ||
            !string.IsNullOrEmpty(CallbackUri.UserInfo) || !string.IsNullOrEmpty(CallbackUri.Query) ||
            !string.IsNullOrEmpty(CallbackUri.Fragment) ||
            CallbackUri.AbsoluteUri.Contains("$(", StringComparison.Ordinal))
        {
            throw new ArgumentException("The authentication callback must be an absolute URI without credentials, query, or fragment.", nameof(CallbackUri));
        }

        return this;
    }

    public bool AcceptsCallbackResponse(Uri response) =>
        response.IsAbsoluteUri &&
        string.Equals(CallbackUri.Scheme, response.Scheme, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(CallbackUri.Host, response.Host, StringComparison.OrdinalIgnoreCase) &&
        CallbackUri.Port == response.Port &&
        string.Equals(
            CallbackUri.GetComponents(UriComponents.Path, UriFormat.UriEscaped),
            response.GetComponents(UriComponents.Path, UriFormat.UriEscaped),
            StringComparison.Ordinal) &&
        HasExactOriginalPath(response) &&
        string.IsNullOrEmpty(response.Fragment) && string.IsNullOrEmpty(response.UserInfo);

    private bool HasExactOriginalPath(Uri response)
    {
        // Uri normalizes dot segments and escaped unreserved characters. Do not
        // let that normalization widen the registered callback path.
        var endpoint = response.OriginalString.AsSpan();
        var queryOrFragment = endpoint.IndexOfAny('?', '#');
        if (queryOrFragment >= 0)
        {
            endpoint = endpoint[..queryOrFragment];
        }

        var authority = endpoint[(response.Scheme.Length + 3)..];
        var pathStart = authority.IndexOf('/');
        return pathStart >= 0 && authority[pathStart..].Equals(CallbackUri.AbsolutePath, StringComparison.Ordinal);
    }
}

public sealed record PendingPkceFlow(
    Uri AuthorizationUri,
    Uri CallbackUri,
    string CodeVerifier,
    DateTimeOffset ExpiresAt);

public sealed record ProductSession(
    Guid AccountId,
    string IdentityProvider,
    string AccessToken,
    string RefreshToken,
    DateTimeOffset ExpiresAt)
{
    public ProductSession Validate()
    {
        if (AccountId == Guid.Empty || IdentityProvider is not ("google" or "apple") ||
            !IsValidToken(AccessToken) || !IsValidToken(RefreshToken))
        {
            throw new ProductAuthenticationException("session_payload_invalid");
        }

        return this;
    }

    private static bool IsValidToken(string token) =>
        !string.IsNullOrWhiteSpace(token) && token.Length <= 16_384 && !token.Any(char.IsWhiteSpace);
}

public sealed record StoredProductSession(
    Guid AccountId,
    string IdentityProvider,
    string RefreshToken)
{
    public StoredProductSession Validate()
    {
        if (AccountId == Guid.Empty || IdentityProvider is not ("google" or "apple") ||
            string.IsNullOrWhiteSpace(RefreshToken) || RefreshToken.Length > 16_384 ||
            RefreshToken.Any(char.IsWhiteSpace))
        {
            throw new ProductAuthenticationException("stored_session_invalid");
        }

        return this;
    }
}

public interface IProductSessionStore
{
    Task<StoredProductSession?> LoadAsync(CancellationToken cancellationToken = default);

    Task SaveAsync(StoredProductSession session, CancellationToken cancellationToken = default);

    Task ClearAsync(CancellationToken cancellationToken = default);
}

public interface IProductAuthClient
{
    PendingPkceFlow BeginGoogleSignIn();

    Task<ProductSession> ExchangeCodeAsync(
        PendingPkceFlow flow,
        Uri callbackUri,
        CancellationToken cancellationToken = default);

    Task<ProductSession> RefreshAsync(
        string refreshToken,
        CancellationToken cancellationToken = default);
}

public sealed class ProductAuthenticationException : Exception
{
    public ProductAuthenticationException(string code)
        : base(code)
    {
        Code = code;
    }

    public ProductAuthenticationException(string code, Exception innerException)
        : base(code, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}
