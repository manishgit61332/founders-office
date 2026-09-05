using FoundersOffice.Core.Auth;

if (args.Length != 2 || args[0] != "--configuration")
{
    await Console.Error.WriteLineAsync("acceptance_arguments_invalid");
    return 2;
}

try
{
    var configuration = await WindowsProductConfiguration.LoadAsync(args[1]);
    using var client = new HttpClient(new RefuseNetworkHandler());
    using var auth = new SupabaseProductAuthClient(client, configuration.Public, configuration.Auth);
    var flow = auth.BeginGoogleSignIn();
    if (flow.CallbackUri.AbsoluteUri != WindowsProductConfiguration.DevelopmentCallback ||
        flow.CodeVerifier.Length != 43)
    {
        await Console.Error.WriteLineAsync("acceptance_pkce_preparation_invalid");
        return 1;
    }

    await Console.Out.WriteLineAsync("public_configuration_valid");
    await Console.Out.WriteLineAsync("google_pkce_preparation_valid");
    await Console.Out.WriteLineAsync("network_access_disabled");
    await Console.Out.WriteLineAsync("callback_registration_unverified");
    await Console.Out.WriteLineAsync("live_sign_in_and_workspace_convergence_unverified");
    return 0;
}
catch (ProductConfigurationException error)
{
    await Console.Error.WriteLineAsync(error.Code);
    return 1;
}
catch (Exception)
{
    // Do not expose exception text, paths, configuration, or transient PKCE values.
    await Console.Error.WriteLineAsync("acceptance_preparation_failed");
    return 1;
}

internal sealed class RefuseNetworkHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken) =>
        throw new InvalidOperationException("acceptance_network_access_refused");
}
