using System.Text;
using System.Text.Json;
using FoundersOffice.Core.Auth;

namespace FoundersOffice.Core.Tests;

public sealed class WindowsProductConfigurationTests
{
    private const string ValidJson = """
        {"schemaVersion":1,"supabaseURL":"https://project.supabase.co","publishableKey":"sb_publishable_fixture","callbackURL":"founders-office-dev://auth/callback"}
        """;

    [Fact]
    public void ParsesPublicFieldsWithoutExposingTheirValuesInDiagnostics()
    {
        var configuration = WindowsProductConfiguration.Parse(ValidJson);

        Assert.Equal("https://project.supabase.co/", configuration.Public.ProjectUrl.AbsoluteUri);
        Assert.Equal("sb_publishable_fixture", configuration.Public.PublishableKey);
        Assert.Equal(WindowsProductConfiguration.DevelopmentCallback, configuration.Auth.CallbackUri.AbsoluteUri);
        Assert.DoesNotContain("project.supabase.co", configuration.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("sb_publishable_fixture", configuration.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{")]
    public void RejectsInvalidRootOrMissingFields(string json) => AssertInvalid(json);

    [Theory]
    [InlineData("schemaVersion", "2")]
    [InlineData("schemaVersion", "1.5")]
    [InlineData("schemaVersion", "\"1\"")]
    [InlineData("supabaseURL", "null")]
    [InlineData("publishableKey", "42")]
    [InlineData("callbackURL", "\"founders-office://auth/callback\"")]
    [InlineData("callbackURL", "\"founders-office-dev://auth/Callback\"")]
    [InlineData("callbackURL", "\"founders-office-dev://auth/callback/\"")]
    public void RejectsWrongTypesVersionsAndAlternateCallbacks(string field, string value)
    {
        var fields = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(ValidJson)!;
        fields[field] = JsonSerializer.Deserialize<JsonElement>(value);
        AssertInvalid(JsonSerializer.Serialize(fields));
    }

    [Theory]
    [InlineData(",\"schemaVersion\":1")]
    [InlineData(",\"SchemaVersion\":1")]
    [InlineData(",\"refreshToken\":\"synthetic-sensitive-value\"")]
    [InlineData(",\"callbackRegistered\":true")]
    public void RejectsDuplicatesUnknownFieldsAndSelfCertifiedRegistration(string extra) =>
        AssertInvalid(ValidJson[..^1] + extra + "}");

    [Theory]
    [InlineData("http://project.supabase.co")]
    [InlineData("https://user:synthetic-sensitive-value@project.supabase.co")]
    [InlineData("https://project.supabase.co/path")]
    [InlineData("https://project.supabase.co/?other=1")]
    [InlineData("https://project.supabase.co/#fragment")]
    public void RejectsNonOriginEndpoints(string endpoint) =>
        AssertInvalid(ValidJson.Replace("https://project.supabase.co", endpoint, StringComparison.Ordinal));

    [Theory]
    [InlineData("[]")]
    [InlineData("{\"role\":null}")]
    [InlineData("{\"role\":123}")]
    [InlineData("{\"role\":\"service_role\"}")]
    public void MalformedLegacyKeysReturnContentFreeConfigurationErrors(string payload)
    {
        var key = "header." + Convert.ToBase64String(Encoding.UTF8.GetBytes(payload)).TrimEnd('=') + ".signature";
        AssertInvalid(ValidJson.Replace("sb_publishable_fixture", key, StringComparison.Ordinal));
    }

    [Fact]
    public void RejectsOversizedInput()
    {
        var error = Assert.Throws<ProductConfigurationException>(() =>
            WindowsProductConfiguration.Parse(new string(' ', WindowsProductConfiguration.MaximumBytes + 1)));
        Assert.Equal("public_configuration_too_large", error.Code);
    }

    [Fact]
    public async Task LoadsBoundedUtf8AndReportsMissingFilesWithoutPaths()
    {
        var directory = Directory.CreateTempSubdirectory("fo-config-fixture-");
        var path = Path.Combine(directory.FullName, "ProductAuth.local.json");
        try
        {
            var missing = await Assert.ThrowsAsync<ProductConfigurationException>(() =>
                WindowsProductConfiguration.LoadAsync(path));
            Assert.Equal("public_configuration_missing", missing.Message);
            Assert.Null(missing.InnerException);

            await File.WriteAllTextAsync(path, ValidJson, new UTF8Encoding(false));
            Assert.Equal(WindowsProductConfiguration.Parse(ValidJson), await WindowsProductConfiguration.LoadAsync(path));

            await File.WriteAllBytesAsync(path, [0xff, 0xfe]);
            var malformed = await Assert.ThrowsAsync<ProductConfigurationException>(() =>
                WindowsProductConfiguration.LoadAsync(path));
            Assert.Equal("public_configuration_invalid", malformed.Message);

            await File.WriteAllBytesAsync(path, new byte[WindowsProductConfiguration.MaximumBytes + 1]);
            var oversized = await Assert.ThrowsAsync<ProductConfigurationException>(() =>
                WindowsProductConfiguration.LoadAsync(path));
            Assert.Equal("public_configuration_too_large", oversized.Message);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    private static void AssertInvalid(string json)
    {
        var error = Assert.Throws<ProductConfigurationException>(() => WindowsProductConfiguration.Parse(json));
        Assert.Equal("public_configuration_invalid", error.Message);
        Assert.Null(error.InnerException);
    }
}
