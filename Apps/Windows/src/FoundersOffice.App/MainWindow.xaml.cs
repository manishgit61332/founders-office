using System.Globalization;
using FoundersOffice.App.Platform;
using FoundersOffice.Core.Auth;
using FoundersOffice.Core.Domain;
using FoundersOffice.Core.Repository;
using FoundersOffice.Core.Sync;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace FoundersOffice.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private readonly SqliteWorkspaceRepository _repository;
    private readonly TopEdgeSurfaceController _surfaceController;
    private readonly TrayIconService _trayIcon;
    private readonly WindowsProductAccountController _productAccount;
    private Dictionary<Guid, Move> _movesById = new();
    private Guid? _editingMoveId;
    private bool _disposed;
    private bool _exitRequested;
    private bool _isConfirmingDelete;
    private bool _isBusy;
    private bool _workspaceReady;

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
        _productAccount = new WindowsProductAccountController(_repository);
        _productAccount.StateChanged += ProductAccount_StateChanged;
        _surfaceController = new TopEdgeSurfaceController(
            this,
            () => RootGrid.XamlRoot?.RasterizationScale ?? 1.0);
        _trayIcon = new TrayIconService(this);
        _trayIcon.ToggleRequested += TrayIcon_ToggleRequested;
        _trayIcon.ExitRequested += TrayIcon_ExitRequested;

        _surfaceController.Closing += SurfaceController_Closing;
        _surfaceController.ModeChanged += SurfaceController_ModeChanged;
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
            await RefreshAsync();
            _workspaceReady = true;
            ShowForActivation();
            await _productAccount.InitializeAsync();
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

    public Task<ProductCallbackOutcome> HandleProductCallbackAsync(Uri? callback) => _productAccount.HandleCallbackAsync(callback);

    private async void ProductSignInButton_Click(object sender, RoutedEventArgs e) => await _productAccount.SignInAsync();

    private void ProductCancelSignInButton_Click(object sender, RoutedEventArgs e) => _productAccount.CancelSignIn();

    private async void ProductSignOutButton_Click(object sender, RoutedEventArgs e) => await _productAccount.SignOutAsync();

    private async void ProductSetupFolderButton_Click(object sender, RoutedEventArgs e) => await _productAccount.OpenSetupFolderAsync();

    private async void ProductReloadSetupButton_Click(object sender, RoutedEventArgs e) => await _productAccount.InitializeAsync();

    private async void ProductSyncButton_Click(object sender, RoutedEventArgs e)
    {
        await _productAccount.SyncAsync(choice: null, reviewedName: null);
        await RefreshAfterProductSyncAsync();
    }

    private async void ProductClaimButton_Click(object sender, RoutedEventArgs e) =>
        await ConfirmProvisioningAsync(WorkspaceProvisioningChoice.ClaimLocalWorkspace);

    private async void ProductAttachButton_Click(object sender, RoutedEventArgs e) =>
        await ConfirmProvisioningAsync(WorkspaceProvisioningChoice.AttachExistingWorkspace);

    private async Task ConfirmProvisioningAsync(WorkspaceProvisioningChoice choice)
    {
        if (!_productAccount.CanSync || _isConfirmingDelete)
        {
            return;
        }

        var claim = choice == WorkspaceProvisioningChoice.ClaimLocalWorkspace;
        if (claim && string.IsNullOrWhiteSpace(ProductReviewedNameInput.Text))
        {
            ProductReviewedNameInput.Focus(FocusState.Programmatic);
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = claim ? "Claim this local workspace?" : "Attach your existing workspace?",
            Content = claim
                ? "This uploads this device's Moves to the beta project under your product account. Use synthetic test data only. Calendar stays separate."
                : "This attaches the workspace owned by your product account. Existing local data stops for export-and-replace review. Calendar stays separate.",
            PrimaryButtonText = claim ? "Claim and sync" : "Attach and sync",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        _isConfirmingDelete = true;
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await _productAccount.SyncAsync(choice, claim ? ProductReviewedNameInput.Text : null);
                await RefreshAfterProductSyncAsync();
            }
        }
        finally
        {
            _isConfirmingDelete = false;
        }
    }

    private async Task RefreshAfterProductSyncAsync()
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            await RefreshAsync();
        }
        catch (Exception)
        {
            ShowOperationError("Could not refresh the local Move view");
        }
    }

    private void ProductAccount_StateChanged(object? sender, EventArgs e)
    {
        if (_disposed)
        {
            return;
        }

        ProductAccountStatusText.Text = _productAccount.ProductStatus;
        ProductSyncStatusText.Text = _productAccount.SyncStatus;
        ProductWorkspaceStatusText.Text = _productAccount.WorkspaceStatus;
        ProductSignInButton.IsEnabled = _productAccount.CanSignIn;
        ProductSignOutButton.IsEnabled = _productAccount.CanSignOut;
        ProductCancelSignInButton.IsEnabled = _productAccount.CanCancelSignIn;
        ProductClaimButton.IsEnabled = _productAccount.CanSync;
        ProductAttachButton.IsEnabled = _productAccount.CanSync;
        ProductSyncButton.IsEnabled = _productAccount.CanSync;
        ProductReloadSetupButton.IsEnabled = !_productAccount.IsBusy;
    }

    public void ShowForActivation()
    {
        if (!_workspaceReady || _disposed)
        {
            return;
        }

        if (ActivationInfoBar.IsOpen)
        {
            _surfaceController.ShowNormal();
        }
        else
        {
            _surfaceController.ShowCompact();
        }
    }

    public void ShowProductCallbackOutcome(ProductCallbackOutcome outcome)
    {
        if (_disposed)
        {
            return;
        }

        ActivationInfoBar.Title = outcome == ProductCallbackOutcome.ProductSignedIn
            ? "Product sign-in completed"
            : "Sign-in link not used";
        ActivationInfoBar.Message = outcome switch
        {
            ProductCallbackOutcome.SignInUnavailable =>
                "Product sign-in is not available in this Windows build. Local Moves and Calendar settings are unchanged.",
            ProductCallbackOutcome.NoPendingFlow =>
                "No product sign-in is waiting in this app. Local Moves and Calendar settings are unchanged.",
            ProductCallbackOutcome.ProductSignedIn =>
                "Your product account is signed in. Workspace sync and Calendar connections need separate setup.",
            ProductCallbackOutcome.Cancelled =>
                "Product sign-in was cancelled. Calendar settings are unchanged.",
            _ => "This sign-in link was not accepted. Calendar settings are unchanged.",
        };
        ActivationInfoBar.IsOpen = true;
        ShowForActivation();
    }

    private void CompactExpandButton_Click(object sender, RoutedEventArgs e) => _surfaceController.Expand();

    private void CompactModeButton_Click(object sender, RoutedEventArgs e) => _surfaceController.ShowCompact();

    private void NormalModeButton_Click(object sender, RoutedEventArgs e) => _surfaceController.ShowNormal();

    private void RootGrid_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape && _surfaceController.Mode == SurfaceMode.Expanded)
        {
            _surfaceController.Collapse();
            e.Handled = true;
        }
    }

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
        _surfaceController.ModeChanged -= SurfaceController_ModeChanged;
        _trayIcon.Dispose();
        _productAccount.StateChanged -= ProductAccount_StateChanged;
        _ = DisposeProductAccountAndRepositoryAsync();
        GC.SuppressFinalize(this);
    }

    private async Task DisposeProductAccountAndRepositoryAsync()
    {
        try
        {
            await _productAccount.DisposeAsync();
        }
        catch (Exception)
        {
            // Shutdown diagnostics must not expose session or path information.
        }
        finally
        {
            _repository.Dispose();
        }
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
            CompactNextMoveText.Text = "Nothing queued yet";
            return;
        }

        NextMoveTitleText.Text = next.Title;
        NextMoveDetailsText.Text = string.IsNullOrWhiteSpace(next.Details)
            ? "No description"
            : next.Details;
        NextMoveMetaText.Text = $"{MoveListItem.PriorityName(next.Priority)} · {MoveListItem.FormatDeadline(next.DueOn)}";
        CompactNextMoveText.Text = next.Title;
    }

    private void SurfaceController_ModeChanged(object? sender, EventArgs e)
    {
        var compact = _surfaceController.Mode == SurfaceMode.Compact;
        CompactSurface.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        ExpandedTitleBar.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        WorkspaceScrollViewer.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        if (_surfaceController.Mode == SurfaceMode.Normal)
        {
            return;
        }

        SetTitleBar(compact ? CompactDragRegion : TitleBarDragRegion);
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
