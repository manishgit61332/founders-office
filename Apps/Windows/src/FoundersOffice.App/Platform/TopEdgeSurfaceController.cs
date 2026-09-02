using FoundersOffice.Core.Presentation;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace FoundersOffice.App.Platform;

public sealed class SurfaceClosingEventArgs : EventArgs
{
    public bool Cancel { get; set; }
}

/// <summary>
/// Owns the Windows-native compact surface. It uses the current display work
/// area and an always-on-top overlapped presenter; it does not imitate a Mac
/// hardware notch.
/// </summary>
public sealed class TopEdgeSurfaceController
{
    private const int PreferredWidth = 760;
    private const int PreferredHeight = 620;
    private readonly AppWindow _appWindow;

    public TopEdgeSurfaceController(Window window)
    {
        var windowHandle = WindowNative.GetWindowHandle(window);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _appWindow.IsShownInSwitchers = false;
        _appWindow.Closing += AppWindow_Closing;

        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsResizable = true;
        }
    }

    public event EventHandler<SurfaceClosingEventArgs>? Closing;

    public void PlaceAtTopEdge()
    {
        var display = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Primary);
        var area = display.WorkArea;
        var placement = TopEdgePlacement.Calculate(
            new PixelRect(area.X, area.Y, area.Width, area.Height),
            new PixelSize(PreferredWidth, PreferredHeight));
        _appWindow.MoveAndResize(new RectInt32(placement.X, placement.Y, placement.Width, placement.Height));
    }

    public void Toggle()
    {
        if (_appWindow.IsVisible)
        {
            Hide();
            return;
        }

        PlaceAtTopEdge();
        _appWindow.Show(activateWindow: true);
    }

    public void Hide() => _appWindow.Hide();

    private void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        var forwarded = new SurfaceClosingEventArgs();
        Closing?.Invoke(this, forwarded);
        args.Cancel = forwarded.Cancel;
    }
}
