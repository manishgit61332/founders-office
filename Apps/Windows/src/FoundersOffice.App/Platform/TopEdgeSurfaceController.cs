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

public enum SurfaceMode
{
    Compact,
    Expanded,
    Normal,
}

/// <summary>
/// Owns the Windows-native compact surface. It uses the current display work
/// area and an always-on-top overlapped presenter; it does not imitate a Mac
/// hardware notch.
/// </summary>
public sealed class TopEdgeSurfaceController
{
    private static readonly PixelSize CompactSize = new(380, 64);
    private static readonly PixelSize ExpandedSize = new(760, 620);
    private static readonly PixelSize NormalSize = new(920, 720);
    private readonly AppWindow _appWindow;
    private readonly Window _window;
    private readonly Func<double> _rasterizationScale;

    public TopEdgeSurfaceController(Window window, Func<double> rasterizationScale)
    {
        _window = window;
        _rasterizationScale = rasterizationScale;
        var windowHandle = WindowNative.GetWindowHandle(window);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _appWindow.Closing += AppWindow_Closing;
    }

    public event EventHandler<SurfaceClosingEventArgs>? Closing;

    public event EventHandler? ModeChanged;

    public SurfaceMode Mode { get; private set; } = SurfaceMode.Compact;

    public void ShowCompact() => Show(SurfaceMode.Compact);

    public void Expand() => Show(SurfaceMode.Expanded);

    public void ShowNormal() => Show(SurfaceMode.Normal);

    public void Collapse()
    {
        if (Mode == SurfaceMode.Expanded)
        {
            ShowCompact();
        }
    }

    public void PlaceAtTopEdge() => Expand();

    public void Show(SurfaceMode mode)
    {
        ConfigurePresenter(mode);
        var display = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Primary);
        var area = display.WorkArea;
        var requestedSize = Scale(mode switch
        {
            SurfaceMode.Compact => CompactSize,
            SurfaceMode.Expanded => ExpandedSize,
            SurfaceMode.Normal => NormalSize,
            _ => throw new ArgumentOutOfRangeException(nameof(mode)),
        });
        var placement = TopEdgePlacement.Calculate(
            new PixelRect(area.X, area.Y, area.Width, area.Height),
            requestedSize,
            mode == SurfaceMode.Normal ? 24 : 12);
        _appWindow.MoveAndResize(new RectInt32(placement.X, placement.Y, placement.Width, placement.Height));
        Mode = mode;
        ModeChanged?.Invoke(this, EventArgs.Empty);
        _appWindow.Show(activateWindow: true);
    }

    public void Toggle()
    {
        if (_appWindow.IsVisible)
        {
            Hide();
            return;
        }

        ShowCompact();
    }

    public void Hide() => _appWindow.Hide();

    private PixelSize Scale(PixelSize logicalSize)
    {
        var scale = Math.Clamp(_rasterizationScale(), 0.5, 4.0);
        return new PixelSize(
            Math.Max(1, checked((int)Math.Round(logicalSize.Width * scale))),
            Math.Max(1, checked((int)Math.Round(logicalSize.Height * scale))));
    }

    private void ConfigurePresenter(SurfaceMode mode)
    {
        var normal = mode == SurfaceMode.Normal;
        _appWindow.IsShownInSwitchers = normal;
        _window.ExtendsContentIntoTitleBar = !normal;
        if (_appWindow.Presenter is not OverlappedPresenter presenter)
        {
            return;
        }

        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: normal);
        presenter.IsAlwaysOnTop = !normal;
        presenter.IsMaximizable = normal;
        presenter.IsMinimizable = normal;
        presenter.IsResizable = mode != SurfaceMode.Compact;
    }

    private void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        var forwarded = new SurfaceClosingEventArgs();
        Closing?.Invoke(this, forwarded);
        args.Cancel = forwarded.Cancel;
    }
}
