using FoundersOffice.Core.Auth;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace FoundersOffice.App;

public partial class App : Application, IDisposable
{
    private MainWindow? _window;
    private AppInstance? _currentInstance;
    private DispatcherQueue? _dispatcher;
    private int _activationScheduled;
    private bool _disposed;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        try
        {
            _dispatcher = DispatcherQueue.GetForCurrentThread();
            _currentInstance = AppInstance.GetCurrent();
            _currentInstance.Activated += Instance_Activated;
            var activation = _currentInstance.GetActivatedEventArgs();
            var owner = AppInstance.FindOrRegisterForKey("FounderOffice.Windows.Development");
            if (!owner.IsCurrent)
            {
                try
                {
                    await owner.RedirectActivationToAsync(activation).AsTask()
                        .WaitAsync(TimeSpan.FromSeconds(10));
                }
                finally
                {
                    // A failed handoff must never open a second workspace writer.
                    Dispose();
                    Exit();
                }

                return;
            }

            _window = new MainWindow();
            _window.Closed += MainWindow_Closed;
            _window.Activate();
            if (activation.Kind == ExtendedActivationKind.Protocol)
            {
                await HandleActivationAsync(activation);
            }
        }
        catch (Exception)
        {
            // Activation data and exception text can contain authorization codes.
            Dispose();
            Exit();
        }
    }

    private void Instance_Activated(object? sender, AppActivationArguments args)
    {
        // Coalesce launch storms. Retain at most one transient redirected request.
        if (Interlocked.CompareExchange(ref _activationScheduled, 1, 0) != 0)
        {
            return;
        }

        if (_dispatcher?.TryEnqueue(async () =>
            {
                try
                {
                    if (!_disposed)
                    {
                        await HandleActivationAsync(args);
                    }
                }
                catch (Exception)
                {
                    _window?.ShowProductCallbackOutcome(ProductCallbackOutcome.Failed);
                }
                finally
                {
                    Interlocked.Exchange(ref _activationScheduled, 0);
                }
            }) != true)
        {
            Interlocked.Exchange(ref _activationScheduled, 0);
        }
    }

    private async Task HandleActivationAsync(AppActivationArguments activation)
    {
        if (activation.Kind == ExtendedActivationKind.Protocol)
        {
            var callback = (activation.Data as IProtocolActivatedEventArgs)?.Uri;
            if (_window is not null)
            {
                var outcome = await _window.HandleProductCallbackAsync(callback);
                _window.ShowProductCallbackOutcome(outcome);
            }
        }
        else if (activation.Kind is ExtendedActivationKind.Launch or ExtendedActivationKind.StartupTask)
        {
            _window?.ShowForActivation();
        }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args) => Dispose();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_currentInstance is not null)
        {
            _currentInstance.Activated -= Instance_Activated;
            _currentInstance = null;
        }

        _window?.Dispose();
        _window = null;
        GC.SuppressFinalize(this);
    }
}
