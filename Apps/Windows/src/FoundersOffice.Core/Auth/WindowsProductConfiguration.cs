using System.Text;
using System.Text.Json;
using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Auth;

/// <summary>
/// Public beta configuration only. Loading it neither registers a protocol
/// callback nor authorizes browser sign-in or workspace provisioning.
/// </summary>
public sealed record WindowsProductConfiguration(
    SupabasePublicConfiguration Public,
    SupabaseAuthConfiguration Auth)
{
    public const string DevelopmentCallback = "founders-office-dev://auth/callback";
    public const int MaximumBytes = 16 * 1024;

    public static WindowsProductConfiguration Parse(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > MaximumBytes)
        {
            throw new ProductConfigurationException("public_configuration_too_large");
        }

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new ProductConfigurationException("public_configuration_invalid");
            }

            var fields = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name is not ("schemaVersion" or "supabaseURL" or "publishableKey" or "callbackURL") ||
                    !fields.Add(property.Name))
                {
                    throw new ProductConfigurationException("public_configuration_invalid");
                }
            }

            if (fields.Count != 4 || root.GetProperty("schemaVersion").ValueKind != JsonValueKind.Number ||
                !root.GetProperty("schemaVersion").TryGetInt32(out var version) || version != 1)
            {
                throw new ProductConfigurationException("public_configuration_invalid");
            }

            var endpoint = RequiredString(root, "supabaseURL");
            var key = RequiredString(root, "publishableKey");
            var callback = RequiredString(root, "callbackURL");
            if (!string.Equals(callback, DevelopmentCallback, StringComparison.Ordinal) ||
                !Uri.TryCreate(endpoint, UriKind.Absolute, out var projectUri))
            {
                throw new ProductConfigurationException("public_configuration_invalid");
            }

            return new WindowsProductConfiguration(
                new SupabasePublicConfiguration(projectUri, key).Validate(),
                new SupabaseAuthConfiguration(new Uri(callback)).Validate());
        }
        catch (JsonException)
        {
            throw new ProductConfigurationException("public_configuration_invalid");
        }
        catch (ArgumentException)
        {
            throw new ProductConfigurationException("public_configuration_invalid");
        }
    }

    public static async Task<WindowsProductConfiguration> LoadAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        try
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new ProductConfigurationException("public_configuration_link_refused");
            }

            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var bytes = new byte[MaximumBytes + 1];
            var count = await stream.ReadAtLeastAsync(bytes, bytes.Length, throwOnEndOfStream: false, cancellationToken)
                .ConfigureAwait(false);
            if (count > MaximumBytes)
            {
                throw new ProductConfigurationException("public_configuration_too_large");
            }

            return Parse(new UTF8Encoding(false, true).GetString(bytes, 0, count));
        }
        catch (FileNotFoundException)
        {
            throw new ProductConfigurationException("public_configuration_missing");
        }
        catch (DirectoryNotFoundException)
        {
            throw new ProductConfigurationException("public_configuration_missing");
        }
        catch (IOException)
        {
            throw new ProductConfigurationException("public_configuration_unreadable");
        }
        catch (UnauthorizedAccessException)
        {
            throw new ProductConfigurationException("public_configuration_unreadable");
        }
        catch (DecoderFallbackException)
        {
            throw new ProductConfigurationException("public_configuration_invalid");
        }
    }

    public override string ToString() => "WindowsProductConfiguration (public beta configuration)";

    private static string RequiredString(JsonElement root, string name)
    {
        var value = root.GetProperty(name);
        if (value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new ProductConfigurationException("public_configuration_invalid");
        }

        return value.GetString()!;
    }
}

public sealed class ProductConfigurationException(string code) : Exception(code)
{
    public string Code { get; } = code;
}
