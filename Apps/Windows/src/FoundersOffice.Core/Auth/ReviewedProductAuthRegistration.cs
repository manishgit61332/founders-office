using System.Security.Cryptography;
using System.Text;

namespace FoundersOffice.Core.Auth;

/// <summary>
/// Pins public configuration to an external registration review. This value
/// records an approval; it cannot discover or prove a provider's allowlist.
/// </summary>
public sealed record ReviewedProductAuthRegistration(string ConfigurationFingerprint)
{
    public bool Matches(WindowsProductConfiguration configuration) =>
        ConfigurationFingerprint.Length == 64 &&
        configuration.Auth.CallbackUri.AbsoluteUri == WindowsProductConfiguration.DevelopmentCallback &&
        string.Equals(ConfigurationFingerprint, Fingerprint(configuration), StringComparison.Ordinal);

    public static string Fingerprint(WindowsProductConfiguration configuration)
    {
        configuration.Public.Validate();
        configuration.Auth.Validate();
        var input = string.Join('\n', "windows-beta-product-auth-v1",
            configuration.Public.ProjectUrl.AbsoluteUri,
            configuration.Public.PublishableKey,
            configuration.Auth.CallbackUri.AbsoluteUri);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(input)));
    }

    public static ProductSessionBroker? CreateBrokerIfApproved(
        WindowsProductConfiguration configuration,
        ReviewedProductAuthRegistration? approval,
        Func<WindowsProductConfiguration, ProductSessionBroker> factory) =>
        approval?.Matches(configuration) == true ? factory(configuration) : null;
}
