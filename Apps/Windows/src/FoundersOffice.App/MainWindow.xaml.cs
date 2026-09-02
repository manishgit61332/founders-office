using FoundersOffice.App.Platform;
using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace FoundersOffice.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private readonly SqliteWorkspaceRepository _repository;
    private readonly TopEdgeSurfaceController _surfaceController;
    private readonly TrayIconService _trayIcon;
    private bool _disposed;
    private bool _exitRequested;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragRegion);
        SystemBackdrop = new MicaBackdrop();

        var databasePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FounderOffice",
            "founders-office.sqlite3");
        _repository = new SqliteWorkspaceRepository(databasePath);
        _surfaceController = new TopEdgeSurfaceController(this);
        _trayIcon = new TrayIconService(this);
        _trayIcon.Activated += (_, _) => _surfaceController.Toggle();

        _surfaceController.Closing += SurfaceController_Closing;
        Closed += MainWindow_Closed;
        RootGrid.Loaded += RootGrid_Loaded;
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await _repository.InitializeAsync();
            _trayIcon.Start();
            _surfaceController.PlaceAtTopEdge();
            await RefreshAsync();
        }
        catch (Exception)
        {
            WorkspaceStatusText.Text = "Local workspace unavailable";
            OperationInfoBar.IsOpen = true;
        }
    }

    private async void AddMoveButton_Click(object sender, RoutedEventArgs e)
    {
        var title = MoveTitleInput.Text.Trim();
        if (title.Length == 0)
        {
            MoveTitleInput.Focus(FocusState.Programmatic);
            return;
        }

        SetBusy(true);
        try
        {
            var move = Move.Create(title, MoveDetailsInput.Text);
            await _repository.UpsertMoveAsync(move);
            MoveTitleInput.Text = string.Empty;
            MoveDetailsInput.Text = string.Empty;
            OperationInfoBar.IsOpen = false;
            await RefreshAsync();
        }
        catch (Exception)
        {
            OperationInfoBar.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void HideButton_Click(object sender, RoutedEventArgs e) => _surfaceController.Hide();

    private void ExitButton_Click(object sender, RoutedEventArgs e)
    {
        _exitRequested = true;
        Close();
    }

    private void SurfaceController_Closing(object? sender, SurfaceClosingEventArgs e)
    {
        if (_exitRequested)
        {
            return;
        }

        e.Cancel = true;
        _surfaceController.Hide();
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args) => Dispose();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _trayIcon.Dispose();
        _repository.Dispose();
        GC.SuppressFinalize(this);
    }

    private async Task RefreshAsync()
    {
        var snapshot = await _repository.SnapshotAsync();
        var next = snapshot.Moves.FirstOrDefault(move => move.Status is MoveStatus.Doing or MoveStatus.Next);
        if (next is null)
        {
            WorkspaceStatusText.Text = "Private on this device · ready";
            NextMoveTitleText.Text = "Nothing queued yet";
            NextMoveDetailsText.Text = "Add one clear Move below.";
            return;
        }

        WorkspaceStatusText.Text = snapshot.PendingOperationCount == 0
            ? "Private on this device · ready"
            : $"Private on this device · {snapshot.PendingOperationCount} waiting to sync";
        NextMoveTitleText.Text = next.Title;
        NextMoveDetailsText.Text = string.IsNullOrWhiteSpace(next.Details)
            ? "No description"
            : next.Details;
    }

    private void SetBusy(bool isBusy)
    {
        BusyIndicator.IsActive = isBusy;
        AddMoveButton.IsEnabled = !isBusy;
        MoveTitleInput.IsEnabled = !isBusy;
        MoveDetailsInput.IsEnabled = !isBusy;
    }
}
