using Microsoft.UI.Xaml;

namespace FoundersOffice.App;

public partial class App : Application, IDisposable
{
    private MainWindow? _window;
    private bool _disposed;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Closed += MainWindow_Closed;
        _window.Activate();
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args) => Dispose();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _window?.Dispose();
        _window = null;
        GC.SuppressFinalize(this);
    }
}
