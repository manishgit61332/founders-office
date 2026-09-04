using System.Globalization;
using FoundersOffice.App.Platform;
using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FoundersOffice.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private readonly SqliteWorkspaceRepository _repository;
    private readonly TopEdgeSurfaceController _surfaceController;
    private readonly TrayIconService _trayIcon;
    private IReadOnlyDictionary<Guid, Move> _movesById = new Dictionary<Guid, Move>();
    private Guid? _editingMoveId;
    private bool _disposed;
    private bool _exitRequested;
    private bool _isConfirmingDelete;
    private bool _isBusy;

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
        _trayIcon.ToggleRequested += TrayIcon_ToggleRequested;
        _trayIcon.ExitRequested += TrayIcon_ExitRequested;

        _surfaceController.Closing += SurfaceController_Closing;
        Closed += MainWindow_Closed;
        RootGrid.Loaded += RootGrid_Loaded;
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        RootGrid.Loaded -= RootGrid_Loaded;
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
            ShowOperationError("Couldn’t open your workspace");
        }
    }

    private async void SaveMoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy)
        {
            return;
        }

        var title = MoveTitleInput.Text.Trim();
        if (title.Length == 0)
        {
            MoveTitleInput.Focus(FocusState.Programmatic);
            return;
        }

        var details = MoveDetailsInput.Text.Trim();
        var priority = ReadSelectedPriority();
        var dueOn = ReadSelectedDeadline();
        var editingMoveId = _editingMoveId;
        var success = await TryMutationAsync(
            editingMoveId is { } moveId
                ? () => _repository.UpdateMoveAsync(moveId, title, details, priority, dueOn)
                : () => _repository.UpsertMoveAsync(Move.Create(title, details, priority, dueOn)),
            editingMoveId is null ? "Couldn’t add this Move" : "Couldn’t save your changes");
        if (success)
        {
            ResetEditor();
        }
    }

    private void CancelEditButton_Click(object sender, RoutedEventArgs e) => ResetEditor();

    private void EditMoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy || !TryResolveMove(sender, out var move))
        {
            return;
        }

        _editingMoveId = move.Id;
        EditorHeadingText.Text = "Edit Move";
        SaveMoveButton.Content = "Save changes";
        CancelEditButton.Visibility = Visibility.Visible;
        MoveTitleInput.Text = move.Title;
        MoveDetailsInput.Text = move.Details;
        MovePriorityInput.SelectedIndex = (int)move.Priority;
        MoveDeadlineInput.Date = move.DueOn is { } dueOn
            ? new DateTimeOffset(dueOn.ToDateTime(TimeOnly.MinValue))
            : null;
        OperationInfoBar.IsOpen = false;
        EditorCard.StartBringIntoView();
        MoveTitleInput.Focus(FocusState.Programmatic);
    }

    private async void CompleteMoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy || !TryResolveMove(sender, out var move))
        {
            return;
        }

        var success = await TryMutationAsync(
            () => _repository.CompleteMoveAsync(move.Id),
            "Couldn’t complete this Move");
        if (success && _editingMoveId == move.Id)
        {
            ResetEditor();
        }
    }

    private async void ReopenMoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy || !TryResolveMove(sender, out var move))
        {
            return;
        }

        await TryMutationAsync(
            () => _repository.ReopenMoveAsync(move.Id),
            "Couldn’t reopen this Move");
    }

    private async void DeleteMoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy || _isConfirmingDelete || !TryResolveMove(sender, out var move))
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "Delete this Move?",
            Content = "This removes it from the local workspace. This development build does not include recovery yet.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Keep Move",
            DefaultButton = ContentDialogButton.Close,
        };
        ContentDialogResult result;
        _isConfirmingDelete = true;
        try
        {
            result = await dialog.ShowAsync();
        }
        finally
        {
            _isConfirmingDelete = false;
        }

        if (result != ContentDialogResult.Primary)
        {
            return;
        }

        var success = await TryMutationAsync(
            () => _repository.SoftDeleteMoveAsync(move.Id),
            "Couldn’t delete this Move");
        if (success && _editingMoveId == move.Id)
        {
            ResetEditor();
        }
    }

    private void HideButton_Click(object sender, RoutedEventArgs e) => _surfaceController.Hide();

    private void ExitButton_Click(object sender, RoutedEventArgs e) => RequestExit();

    private void TrayIcon_ToggleRequested(object? sender, EventArgs e) => _surfaceController.Toggle();

    private void TrayIcon_ExitRequested(object? sender, EventArgs e) => RequestExit();

    private void RequestExit()
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
        _trayIcon.ToggleRequested -= TrayIcon_ToggleRequested;
        _trayIcon.ExitRequested -= TrayIcon_ExitRequested;
        _surfaceController.Closing -= SurfaceController_Closing;
        _trayIcon.Dispose();
        _repository.Dispose();
        GC.SuppressFinalize(this);
    }

    private async Task<bool> TryMutationAsync(Func<Task> mutation, string errorTitle)
    {
        SetBusy(true);
        try
        {
            await mutation();
            OperationInfoBar.IsOpen = false;
            await RefreshAsync();
            return true;
        }
        catch (Exception)
        {
            ShowOperationError(errorTitle);
            return false;
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task RefreshAsync()
    {
        var snapshot = await _repository.SnapshotAsync();
        _movesById = snapshot.Moves.ToDictionary(move => move.Id);

        var active = snapshot.Moves
            .Where(move => move.Status != MoveStatus.Done)
            .Select(MoveListItem.From)
            .ToArray();
        var completed = snapshot.Moves
            .Where(move => move.Status == MoveStatus.Done)
            .OrderByDescending(move => move.CompletedAt)
            .Select(MoveListItem.From)
            .ToArray();

        ActiveMovesItems.ItemsSource = active;
        CompletedMovesItems.ItemsSource = completed;
        ActiveMoveCountText.Text = active.Length.ToString(CultureInfo.CurrentCulture);
        CompletedMoveCountText.Text = completed.Length.ToString(CultureInfo.CurrentCulture);
        ActiveEmptyText.Visibility = active.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        HistoryEmptyText.Visibility = completed.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        WorkspaceStatusText.Text = snapshot.PendingOperationCount == 0
            ? "Private on this device · ready"
            : $"Private on this device · {snapshot.PendingOperationCount.ToString(CultureInfo.CurrentCulture)} waiting to sync";

        var next = snapshot.Moves.FirstOrDefault(move => move.Status != MoveStatus.Done);
        if (next is null)
        {
            NextMoveTitleText.Text = "Nothing queued yet";
            NextMoveDetailsText.Text = "Add one clear Move below.";
            NextMoveMetaText.Text = "No deadline";
            return;
        }

        NextMoveTitleText.Text = next.Title;
        NextMoveDetailsText.Text = string.IsNullOrWhiteSpace(next.Details)
            ? "No description"
            : next.Details;
        NextMoveMetaText.Text = $"{MoveListItem.PriorityName(next.Priority)} · {MoveListItem.FormatDeadline(next.DueOn)}";
    }

    private void ResetEditor()
    {
        _editingMoveId = null;
        EditorHeadingText.Text = "Add a Move";
        SaveMoveButton.Content = "Add Move";
        CancelEditButton.Visibility = Visibility.Collapsed;
        MoveTitleInput.Text = string.Empty;
        MoveDetailsInput.Text = string.Empty;
        MovePriorityInput.SelectedIndex = 1;
        MoveDeadlineInput.Date = null;
        OperationInfoBar.IsOpen = false;
    }

    private MovePriority ReadSelectedPriority()
    {
        if (MovePriorityInput.SelectedItem is ComboBoxItem item
            && Enum.TryParse<MovePriority>(item.Tag?.ToString(), out var priority))
        {
            return priority;
        }

        return MovePriority.P1;
    }

    private DateOnly? ReadSelectedDeadline() => MoveDeadlineInput.Date is { } deadline
        ? DateOnly.FromDateTime(deadline.DateTime)
        : null;

    private bool TryResolveMove(object sender, out Move move)
    {
        if (sender is FrameworkElement element
            && Guid.TryParse(element.Tag?.ToString(), out var moveId)
            && _movesById.TryGetValue(moveId, out var resolvedMove))
        {
            move = resolvedMove;
            return true;
        }

        move = null!;
        return false;
    }

    private void SetBusy(bool isBusy)
    {
        _isBusy = isBusy;
        BusyIndicator.IsActive = isBusy;
        SaveMoveButton.IsEnabled = !isBusy;
        CancelEditButton.IsEnabled = !isBusy;
        MoveTitleInput.IsEnabled = !isBusy;
        MoveDetailsInput.IsEnabled = !isBusy;
        MovePriorityInput.IsEnabled = !isBusy;
        MoveDeadlineInput.IsEnabled = !isBusy;
        ActiveMovesItems.IsHitTestVisible = !isBusy;
        CompletedMovesItems.IsHitTestVisible = !isBusy;
    }

    private void ShowOperationError(string title)
    {
        OperationInfoBar.Title = title;
        OperationInfoBar.IsOpen = true;
    }
}

internal sealed class MoveListItem
{
    private MoveListItem(Move move)
    {
        Id = move.Id.ToString("D", CultureInfo.InvariantCulture);
        Title = move.Title;
        Details = move.Details;
        PriorityLabel = PriorityName(move.Priority);
        StatusLabel = move.Status == MoveStatus.Done ? "Completed" : move.Status.ToString();
        TimelineLabel = move.Status == MoveStatus.Done && move.CompletedAt is { } completedAt
            ? $"Completed {completedAt.ToLocalTime().ToString("d MMM yyyy · h:mm tt", CultureInfo.CurrentCulture)}"
            : FormatDeadline(move.DueOn);
        DetailsVisibility = string.IsNullOrWhiteSpace(move.Details) ? Visibility.Collapsed : Visibility.Visible;
        EditVisibility = move.Status == MoveStatus.Done ? Visibility.Collapsed : Visibility.Visible;
        CompleteVisibility = move.Status == MoveStatus.Done ? Visibility.Collapsed : Visibility.Visible;
        ReopenVisibility = move.Status == MoveStatus.Done ? Visibility.Visible : Visibility.Collapsed;
    }

    public string Id { get; }

    public string Title { get; }

    public string Details { get; }

    public string PriorityLabel { get; }

    public string StatusLabel { get; }

    public string TimelineLabel { get; }

    public Visibility DetailsVisibility { get; }

    public Visibility EditVisibility { get; }

    public Visibility CompleteVisibility { get; }

    public Visibility ReopenVisibility { get; }

    public static MoveListItem From(Move move) => new(move);

    public static string PriorityName(MovePriority priority) => priority switch
    {
        MovePriority.P0 => "Critical · P0",
        MovePriority.P1 => "High · P1",
        MovePriority.P2 => "Medium · P2",
        MovePriority.P3 => "Low · P3",
        _ => throw new ArgumentOutOfRangeException(nameof(priority)),
    };

    public static string FormatDeadline(DateOnly? dueOn)
    {
        if (dueOn is null)
        {
            return "No deadline";
        }

        var label = dueOn.Value.ToDateTime(TimeOnly.MinValue).ToString("d MMM yyyy", CultureInfo.CurrentCulture);
        return dueOn.Value < DateOnly.FromDateTime(DateTime.Today)
            ? $"Overdue · {label}"
            : $"Due {label}";
    }
}
