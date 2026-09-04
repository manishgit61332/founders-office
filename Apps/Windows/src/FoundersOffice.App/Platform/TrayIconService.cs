using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace FoundersOffice.App.Platform;

/// <summary>
/// Owns the notification-area icon and its content-free native menu. The icon
/// is restored after Explorer restarts, and all callbacks return to the WinUI
/// dispatcher before changing window lifetime.
/// </summary>
public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8000 + 44;
    private const uint LeftButtonUp = 0x0202;
    private const uint RightButtonUp = 0x0205;
    private const uint ContextMenu = 0x007B;
    private const uint NotifyIconSelect = 0x0400;
    private const uint NotifyIconKeySelect = 0x0401;
    private const uint NotifyIconAdd = 0x00000000;
    private const uint NotifyIconDelete = 0x00000002;
    private const uint NotifyIconSetVersion = 0x00000004;
    private const uint NotifyIconVersion4 = 4;
    private const uint NotifyMessage = 0x00000001;
    private const uint NotifyIcon = 0x00000002;
    private const uint NotifyTip = 0x00000004;
    private const uint MenuString = 0x00000000;
    private const uint MenuSeparator = 0x00000800;
    private const uint TrackRightButton = 0x00000002;
    private const uint TrackReturnCommand = 0x00000100;
    private const uint TrackNoNotify = 0x00000080;
    private const uint WindowNull = 0x0000;
    private const nuint ToggleCommand = 1;
    private const nuint ExitCommand = 2;
    private static readonly UIntPtr SubclassId = new(0x464F);

    private readonly IntPtr _windowHandle;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly SubclassProc _subclassProc;
    private readonly uint _taskbarCreatedMessage;
    private NotifyIconData _data;
    private bool _started;

    public TrayIconService(Window window)
    {
        _windowHandle = WindowNative.GetWindowHandle(window);
        _dispatcherQueue = window.DispatcherQueue;
        _subclassProc = WindowSubclassProc;
        _taskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");
    }

    public event EventHandler? ToggleRequested;

    public event EventHandler? ExitRequested;

    public void Start()
    {
        if (_started)
        {
            return;
        }

        if (!SetWindowSubclass(_windowHandle, _subclassProc, SubclassId, UIntPtr.Zero))
        {
            throw new InvalidOperationException("tray_subclass_failed");
        }

        _data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            WindowHandle = _windowHandle,
            Id = 1,
            Flags = NotifyMessage | NotifyIcon | NotifyTip,
            CallbackMessage = CallbackMessage,
            IconHandle = LoadIcon(IntPtr.Zero, new IntPtr(32512)),
            Tip = "Founder's Office",
            Info = string.Empty,
            InfoTitle = string.Empty,
        };

        if (!TryAddIcon())
        {
            RemoveWindowSubclass(_windowHandle, _subclassProc, SubclassId);
            throw new InvalidOperationException("tray_icon_add_failed");
        }

        _started = true;
    }

    public void Dispose()
    {
        if (!_started)
        {
            return;
        }

        ShellNotifyIcon(NotifyIconDelete, ref _data);
        RemoveWindowSubclass(_windowHandle, _subclassProc, SubclassId);
        _started = false;
    }

    private bool TryAddIcon()
    {
        if (!ShellNotifyIcon(NotifyIconAdd, ref _data))
        {
            return false;
        }

        _data.TimeoutOrVersion = NotifyIconVersion4;
        if (ShellNotifyIcon(NotifyIconSetVersion, ref _data))
        {
            return true;
        }

        ShellNotifyIcon(NotifyIconDelete, ref _data);
        return false;
    }

    private IntPtr WindowSubclassProc(
        IntPtr windowHandle,
        uint message,
        UIntPtr wordParameter,
        IntPtr longParameter,
        UIntPtr subclassId,
        UIntPtr referenceData)
    {
        if (_started && _taskbarCreatedMessage != 0 && message == _taskbarCreatedMessage)
        {
            _dispatcherQueue.TryEnqueue(() => TryAddIcon());
            return IntPtr.Zero;
        }

        if (message == CallbackMessage)
        {
            var notification = unchecked((uint)(longParameter.ToInt64() & 0xFFFF));
            if (notification is LeftButtonUp or NotifyIconSelect or NotifyIconKeySelect)
            {
                _dispatcherQueue.TryEnqueue(() => ToggleRequested?.Invoke(this, EventArgs.Empty));
                return IntPtr.Zero;
            }

            if (notification is RightButtonUp or ContextMenu)
            {
                _dispatcherQueue.TryEnqueue(ShowContextMenu);
                return IntPtr.Zero;
            }
        }

        return DefSubclassProc(windowHandle, message, wordParameter, longParameter);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        try
        {
            var toggleLabel = IsWindowVisible(_windowHandle)
                ? "Hide Founder's Office"
                : "Open Founder's Office";
            if (!AppendMenu(menu, MenuString, ToggleCommand, toggleLabel)
                || !AppendMenu(menu, MenuSeparator, 0, null)
                || !AppendMenu(menu, MenuString, ExitCommand, "Exit"))
            {
                return;
            }

            if (!GetCursorPos(out var point))
            {
                return;
            }

            SetForegroundWindow(_windowHandle);
            var selected = TrackPopupMenu(
                menu,
                TrackRightButton | TrackReturnCommand | TrackNoNotify,
                point.X,
                point.Y,
                0,
                _windowHandle,
                IntPtr.Zero);
            PostMessage(_windowHandle, WindowNull, UIntPtr.Zero, IntPtr.Zero);

            if (selected == ToggleCommand)
            {
                ToggleRequested?.Invoke(this, EventArgs.Empty);
            }
            else if (selected == ExitCommand)
            {
                ExitRequested?.Invoke(this, EventArgs.Empty);
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr WindowHandle;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr IconHandle;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;

        public uint State;
        public uint StateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;

        public uint TimeoutOrVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;

        public uint InfoFlags;
        public Guid ItemGuid;
        public IntPtr BalloonIconHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    private delegate IntPtr SubclassProc(
        IntPtr windowHandle,
        uint message,
        UIntPtr wordParameter,
        IntPtr longParameter,
        UIntPtr subclassId,
        UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        IntPtr windowHandle,
        SubclassProc subclassProcedure,
        UIntPtr subclassId,
        UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(
        IntPtr windowHandle,
        SubclassProc subclassProcedure,
        UIntPtr subclassId);

    [DllImport("comctl32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr DefSubclassProc(
        IntPtr windowHandle,
        uint message,
        UIntPtr wordParameter,
        IntPtr longParameter);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadIconW")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr LoadIcon(IntPtr instanceHandle, IntPtr iconName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterWindowMessageW")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint RegisterWindowMessage(string message);

    [DllImport("user32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "AppendMenuW", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(IntPtr menu, uint flags, nuint menuItemIdentifier, string? text);

    [DllImport("user32.dll", EntryPoint = "TrackPopupMenu", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern nuint TrackPopupMenu(
        IntPtr menu,
        uint flags,
        int x,
        int y,
        int reserved,
        IntPtr windowHandle,
        IntPtr excludedRectangle);

    [DllImport("user32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "PostMessageW")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(
        IntPtr windowHandle,
        uint message,
        UIntPtr wordParameter,
        IntPtr longParameter);
}
