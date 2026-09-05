using FoundersOffice.Core.Auth;
using FoundersOffice.Core.Repository;
using FoundersOffice.Core.Sync;
using Windows.Storage;
using Windows.System;

namespace FoundersOffice.App.Platform;

/// <summary>Native product identity only. This controller never accesses Calendar.</summary>
public sealed class WindowsProductAccountController(IWorkspaceRepository repository) : IAsyncDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly ProductCallbackRouter _unavailableRouter = new(
        new SupabaseAuthConfiguration(new Uri(WindowsProductConfiguration.DevelopmentCallback)));
    private WindowsProductConfiguration? _configuration;
    private SupabaseProductAuthClient? _authClient;
    private ProductSessionBroker? _broker;
    private ProductBrowserSignIn? _browser;
    private Task? _activeOperation;
    private bool _disposed;
    private bool _signInRunning;

    public event EventHandler? StateChanged;

    public string ProductStatus { get; private set; } = "Product account: Checking this device's setup.";
    public string SyncStatus { get; private set; } = "Move sync: Local-only until you explicitly choose a workspace.";
    public string WorkspaceStatus { get; private set; } = "Remote workspace: Not attached.";
    public bool IsBusy { get; private set; }
    public bool CanSignIn => !_disposed && !IsBusy && _broker is not null && _broker.Identity is null;
    public bool CanSignOut => !_disposed && !IsBusy && _broker is not null;
    public bool CanSync => !_disposed && !IsBusy && _broker?.Identity is not null;
    public bool CanCancelSignIn => !_disposed && _signInRunning;

    public Task InitializeAsync() => RunExclusiveAsync(async cancellationToken =>
    {
        await ReadWorkspaceBindingAsync(cancellationToken);
        if (_broker is not null)
        {
            return;
        }

        try
        {
            var path = Path.Combine(ApplicationData.Current.LocalFolder.Path, "ProductAuth.local.json");
            _configuration = await WindowsProductConfiguration.LoadAsync(path, cancellationToken);
        }
        catch (ProductConfigurationException)
        {
            ProductStatus = "Product account: Add the reviewed public configuration through Open setup folder, then reload.";
            return;
        }

        _broker = ReviewedProductAuthRegistration.CreateBrokerIfApproved(
            _configuration, WindowsProductAuthApproval.Current, configuration =>
            {
                _authClient?.Dispose();
                _authClient = SupabaseProductAuthClient.Create(configuration.Public, configuration.Auth);
                return new ProductSessionBroker(_authClient, new WindowsCredentialSessionStore(
                    ReviewedProductAuthRegistration.Fingerprint(configuration)));
            });
        if (_broker is null)
        {
            ProductStatus = "Product account: Google sign-in awaits exact Windows callback approval. No network access is enabled.";
            return;
        }

        _browser = new ProductBrowserSignIn(_broker, _configuration.Auth,
            (uri, token) => Launcher.LaunchUriAsync(uri).AsTask(token));
        ProductStatus = "Product account: Checking the stored product session.";
        Notify();
        try
        {
            var identity = await _broker.RestoreAsync(cancellationToken);
            ProductStatus = identity is null
                ? "Product account: Signed out. Google login does not connect Calendar."
                : "Product account: Signed in. Workspace and Calendar setup remain separate.";
        }
        catch (ProductAuthenticationException)
        {
            ProductStatus = "Product account: The stored session needs a new sign-in. Local Moves are unchanged.";
        }
    });

    public Task SignInAsync() => RunExclusiveAsync(async cancellationToken =>
    {
        if (_browser is null || _broker is null || _broker.Identity is not null)
        {
            return;
        }

        _signInRunning = true;
        ProductStatus = "Product account: Complete Google sign-in in your browser, or cancel here. This attempt expires in ten minutes.";
        Notify();
        try
        {
            var outcome = await _browser.StartAsync(cancellationToken);
            ProductStatus = _broker.Identity is not null
                ? "Product account: Signed in. Choose a workspace separately; Calendar is unchanged."
                : outcome switch
                {
                    ProductCallbackOutcome.Cancelled => "Product account: Sign-in cancelled. Calendar is unchanged.",
                    ProductCallbackOutcome.TimedOut => "Product account: Sign-in expired. Start a new attempt when ready.",
                    _ => "Product account: Sign-in did not complete. You can try again. Calendar is unchanged.",
                };
        }
        finally
        {
            _signInRunning = false;
        }
    });

    public void CancelSignIn() => _browser?.Cancel();

    public Task<ProductCallbackOutcome> HandleCallbackAsync(Uri? callback) =>
        _browser?.RouteAsync(callback) ?? _unavailableRouter.RouteAsync(callback);

    public Task SignOutAsync() => RunExclusiveAsync(async cancellationToken =>
    {
        if (_broker is null)
        {
            return;
        }

        await _broker.SignOutAsync(cancellationToken);
        ProductStatus = "Product account: Signed out. Local Moves and Calendar connections are unchanged.";
        SyncStatus = "Move sync: Sign in with the workspace's account to continue. Local Moves remain available.";
    });

    public Task SyncAsync(WorkspaceProvisioningChoice? choice, string? reviewedName) => RunExclusiveAsync(async cancellationToken =>
    {
        if (_configuration is null || _broker?.Identity is not { } identity ||
            WindowsProductAuthApproval.Current?.Matches(_configuration) != true)
        {
            SyncStatus = "Move sync: An approved product sign-in is required. Nothing was uploaded.";
            return;
        }

        var name = choice == WorkspaceProvisioningChoice.ClaimLocalWorkspace
            ? ReviewedDisplayName.Create(reviewedName ?? string.Empty)
            : null;
        using var transport = SupabaseV1SyncTransport.Create(_configuration.Public, _broker.GetAccessTokenAsync);
        using var coordinator = new WorkspaceSyncCoordinator(repository, transport);
        var result = await coordinator.RunAsync(identity, name, choice, cancellationToken);
        SyncStatus = result.Outcome switch
        {
            SyncRunOutcome.Synced => "Move sync: This attempt completed. Cross-device convergence still needs verification.",
            SyncRunOutcome.MoreWork => "Move sync: More changes remain. Run another bounded sync when ready.",
            SyncRunOutcome.ConflictNeedsReview => "Move sync: A conflict needs review. Sync remains paused across relaunches.",
            SyncRunOutcome.AccountMismatch => "Move sync: This local workspace belongs to another account. Nothing was uploaded.",
            SyncRunOutcome.AttachmentNeedsReview => "Move sync: Existing local data needs export-and-replace review. Nothing was replaced.",
            _ => "Move sync: Choose Claim this workspace or Attach existing workspace before syncing.",
        };
    }, isSync: true);

    public async Task OpenSetupFolderAsync()
    {
        try
        {
            await Launcher.LaunchFolderAsync(ApplicationData.Current.LocalFolder);
        }
        catch (Exception)
        {
            ProductStatus = "Product account: The setup folder could not be opened. Try again from this Windows device.";
            Notify();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetime.Cancel();
        if (_activeOperation is not null)
        {
            await _activeOperation.ConfigureAwait(false);
        }

        if (_browser is not null)
        {
            await _browser.DisposeAsync().ConfigureAwait(false);
        }

        _broker?.Dispose();
        _authClient?.Dispose();
        _lifetime.Dispose();
        GC.SuppressFinalize(this);
    }

    private Task RunExclusiveAsync(Func<CancellationToken, Task> operation, bool isSync = false)
    {
        if (_disposed || IsBusy)
        {
            return Task.CompletedTask;
        }

        IsBusy = true;
        Notify();
        _activeOperation = RunOperationAsync(operation, isSync);
        return _activeOperation;
    }

    private async Task RunOperationAsync(Func<CancellationToken, Task> operation, bool isSync)
    {
        await Task.Yield();
        try
        {
            await operation(_lifetime.Token);
        }
        catch (Exception)
        {
            if (isSync)
            {
                SyncStatus = "Move sync: This attempt stopped. Local data is retained; unsupported records or session issues need review.";
            }
            else
            {
                ProductStatus = "Product account: This action did not complete. Local Moves and Calendar settings are unchanged.";
            }
        }
        finally
        {
            if (isSync && !_disposed)
            {
                try
                {
                    await ReadWorkspaceBindingAsync(_lifetime.Token);
                }
                catch (Exception)
                {
                    WorkspaceStatus = "Remote workspace: The local binding could not be read.";
                }
            }

            IsBusy = false;
            Notify();
        }
    }

    private void Notify() => StateChanged?.Invoke(this, EventArgs.Empty);

    private async Task ReadWorkspaceBindingAsync(CancellationToken cancellationToken)
    {
        var state = await repository.SyncStateAsync(cancellationToken);
        WorkspaceStatus = state.RemoteWorkspaceId is { } workspaceId
            ? "Remote workspace: " + workspaceId.ToString("D")
            : "Remote workspace: Not attached.";
    }
}
