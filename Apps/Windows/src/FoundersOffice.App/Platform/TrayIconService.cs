using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace FoundersOffice.App.Platform;

/// <summary>
/// Minimal Win32 notification-area owner for the first beta shell. The callback
/// is attached with SetWindowSubclass so the WinUI window procedure remains
/// intact. No task or calendar content enters the tooltip or native messages.
/// </summary>
public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8000 + 44;
    private const uint LeftButtonUp = 0x0202;
    private const uint RightButtonUp = 0x0205;
    private const uint NotifyIconAdd = 0x00000000;
    private const uint NotifyIconDelete = 0x00000002;
    private const uint NotifyMessage = 0x00000001;
    private const uint NotifyIcon = 0x00000002;
    private const uint NotifyTip = 0x00000004;
    private static readonly UIntPtr SubclassId = new(0x464F);

    private readonly IntPtr _windowHandle;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly SubclassProc _subclassProc;
    private NotifyIconData _data;
    private bool _started;

    public TrayIconService(Window window)
    {
        _windowHandle = WindowNative.GetWindowHandle(window);
        _dispatcherQueue = window.DispatcherQueue;
        _subclassProc = WindowSubclassProc;
    }

    public event EventHandler? Activated;

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

        if (!ShellNotifyIcon(NotifyIconAdd, ref _data))
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

    private IntPtr WindowSubclassProc(
        IntPtr windowHandle,
        uint message,
        UIntPtr wordParameter,
        IntPtr longParameter,
        UIntPtr subclassId,
        UIntPtr referenceData)
    {
        if (message == CallbackMessage)
        {
            var mouseMessage = unchecked((uint)longParameter.ToInt64());
            if (mouseMessage is LeftButtonUp or RightButtonUp)
            {
                _dispatcherQueue.TryEnqueue(() => Activated?.Invoke(this, EventArgs.Empty));
                return IntPtr.Zero;
            }
        }

        return DefSubclassProc(windowHandle, message, wordParameter, longParameter);
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
}
