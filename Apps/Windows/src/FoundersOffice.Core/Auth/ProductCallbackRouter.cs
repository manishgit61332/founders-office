namespace FoundersOffice.Core.Auth;

public enum ProductCallbackOutcome
{
    Rejected,
    SignInUnavailable,
    NoPendingFlow,
    ProductSignedIn,
    Cancelled,
    Failed,
}

/// <summary>
/// Routes transient callbacks only to this process's session broker. It cannot
/// construct a flow, restore a verifier, provision a workspace, or access Calendar.
/// </summary>
public sealed class ProductCallbackRouter
{
    public const int MaximumCallbackCharacters = 16 * 1024;
    private readonly SupabaseAuthConfiguration _configuration;
    private readonly ProductSessionBroker? _sessionBroker;

    public ProductCallbackRouter(SupabaseAuthConfiguration configuration, ProductSessionBroker? sessionBroker = null)
    {
        _configuration = configuration.Validate();
        _sessionBroker = sessionBroker;
    }

    public async Task<ProductCallbackOutcome> RouteAsync(
        Uri? callback,
        CancellationToken cancellationToken = default)
    {
        if (callback is null || callback.OriginalString.Length > MaximumCallbackCharacters ||
            !_configuration.AcceptsCallbackResponse(callback))
        {
            return ProductCallbackOutcome.Rejected;
        }

        if (_sessionBroker is null)
        {
            return ProductCallbackOutcome.SignInUnavailable;
        }

        try
        {
            await _sessionBroker.CompleteSignInAsync(callback, cancellationToken).ConfigureAwait(false);
            return ProductCallbackOutcome.ProductSignedIn;
        }
        catch (OperationCanceledException)
        {
            return ProductCallbackOutcome.Cancelled;
        }
        catch (ProductAuthenticationException error)
        {
            return error.Code == "auth_flow_missing"
                ? ProductCallbackOutcome.NoPendingFlow
                : ProductCallbackOutcome.Rejected;
        }
        catch (Exception)
        {
            return ProductCallbackOutcome.Failed;
        }
    }
}
