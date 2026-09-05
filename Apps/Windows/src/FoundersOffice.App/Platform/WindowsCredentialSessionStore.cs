using System.Globalization;
using System.Runtime.InteropServices;
using FoundersOffice.Core.Auth;
using Windows.Security.Credentials;

namespace FoundersOffice.App.Platform;

/// <summary>
/// Persists the product refresh session in Windows Credential Locker. Access
/// tokens and Google provider tokens are never written to disk by this app.
/// </summary>
public sealed class WindowsCredentialSessionStore : IProductSessionStore
{
    private readonly string _resourceName;
    private readonly PasswordVault _vault;

    public WindowsCredentialSessionStore(string configurationFingerprint)
    {
        if (configurationFingerprint.Length != 64 || !configurationFingerprint.All(Uri.IsHexDigit))
        {
            throw new ArgumentException("A reviewed public configuration fingerprint is required.", nameof(configurationFingerprint));
        }

        _resourceName = "FoundersOffice.Windows.Development.ProductSession.v2." + configurationFingerprint;
        _vault = new PasswordVault();
    }

    public Task<StoredProductSession?> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var credentials = FindCredentials();
        if (credentials.Count == 0)
        {
            return Task.FromResult<StoredProductSession?>(null);
        }

        if (credentials.Count != 1 || !TryParseUserName(credentials[0].UserName, out var accountId, out var provider))
        {
            Remove(credentials);
            throw new ProductAuthenticationException("stored_session_invalid");
        }

        var credential = credentials[0];
        credential.RetrievePassword();
        var session = new StoredProductSession(accountId, provider, credential.Password).Validate();
        return Task.FromResult<StoredProductSession?>(session);
    }

    public Task SaveAsync(StoredProductSession session, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        session.Validate();
        Remove(FindCredentials());
        var userName = string.Create(
            CultureInfo.InvariantCulture,
            $"{session.IdentityProvider}:{session.AccountId:D}");
        _vault.Add(new PasswordCredential(_resourceName, userName, session.RefreshToken));
        return Task.CompletedTask;
    }

    public Task ClearAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Remove(FindCredentials());
        return Task.CompletedTask;
    }

    private IReadOnlyList<PasswordCredential> FindCredentials()
    {
        try
        {
            return _vault.FindAllByResource(_resourceName);
        }
        catch (COMException exception) when ((uint)exception.HResult == 0x80070490)
        {
            return Array.Empty<PasswordCredential>();
        }
    }

    private void Remove(IEnumerable<PasswordCredential> credentials)
    {
        foreach (var credential in credentials)
        {
            _vault.Remove(credential);
        }
    }

    private static bool TryParseUserName(string value, out Guid accountId, out string provider)
    {
        var parts = value.Split(':', 2);
        if (parts.Length == 2 && parts[0] is "google" or "apple" && Guid.TryParse(parts[1], out accountId))
        {
            provider = parts[0];
            return accountId != Guid.Empty;
        }

        accountId = Guid.Empty;
        provider = string.Empty;
        return false;
    }
}
