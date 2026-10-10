using System.Runtime.InteropServices;
using System.Text;
using BatteryPill.Core;

namespace BatteryPill;

internal static class Native
{
    public const int WM_NCLBUTTONDOWN = 0x00A1;
    public const int HTCAPTION = 2;
    public const int WM_MOVING = 0x0216;
    public const int WM_ENTERSIZEMOVE = 0x0231;
    public const int WM_EXITSIZEMOVE = 0x0232;
    public const int WM_DISPLAYCHANGE = 0x007E;
    public const int WM_DPICHANGED = 0x02E0;
    public const int WM_SETTINGCHANGE = 0x001A;
    public const int WM_POWERBROADCAST = 0x0218;
    public const int PBT_APMRESUMEAUTOMATIC = 0x0012;

    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWCP_DONOTROUND = 1;
    private const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
    private const int ENUM_CURRENT_SETTINGS = -1;

    private const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    private const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_SYSMENU = 0x00080000,
        WS_BORDER = 0x00800000, WS_DLGFRAME = 0x00400000, WS_POPUP = 0x80000000;
    private const long WS_EX_DLGMODALFRAME = 0x1, WS_EX_TRANSPARENT = 0x20, WS_EX_WINDOWEDGE = 0x100,
        WS_EX_CLIENTEDGE = 0x200, WS_EX_STATICEDGE = 0x20000, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    private const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10,
        SWP_FRAMECHANGED = 0x20;
    private const uint LWA_ALPHA = 0x2;
    private const uint MONITOR_DEFAULTTONEAREST = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public delegate IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr refData);
    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumDisplaySettings(string? deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("comctl32.dll")] public static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, UIntPtr refData);
    [DllImport("comctl32.dll")] public static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id);
    [DllImport("comctl32.dll")] public static extern IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    /// <summary>
    /// The pill draws its own capsule edge and shadow. A borderless presenter
    /// still left a 1px white frame around the transparent window, so strip every
    /// frame style; then no DWM rounding or accent border either.
    /// </summary>
    public static void RemoveWindowFrame(IntPtr hwnd)
    {
        long style = (long)GetWindowLongPtr(hwnd, GWL_STYLE);
        style &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_BORDER | WS_DLGFRAME);
        style |= WS_POPUP;
        SetWindowLongPtr(hwnd, GWL_STYLE, (IntPtr)style);
        long ex = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        ex &= ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, (IntPtr)ex);
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);

        int round = DWMWCP_DONOTROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        int border = DWMWA_COLOR_NONE;
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
    }

    /// <summary>
    /// The pill never takes focus: clicking or launching it must not pull the
    /// keyboard away from what the user is doing (a fullscreen game above all).
    /// </summary>
    public static void SetNoActivate(IntPtr hwnd)
    {
        long ex = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, (IntPtr)(ex | WS_EX_NOACTIVATE));
    }

    /// <summary>
    /// Click-through for the transparent shadow margin: a layered + transparent
    /// window passes the mouse to whatever is underneath. Toggled on while the
    /// cursor is outside the capsule, off while it is over it.
    /// </summary>
    public static void SetClickThrough(IntPtr hwnd, bool through)
    {
        long ex = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        long want = through ? ex | WS_EX_LAYERED | WS_EX_TRANSPARENT : ex & ~WS_EX_TRANSPARENT;
        if (want == ex) return;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, (IntPtr)want);
        if ((want & WS_EX_LAYERED) != 0) SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    }

    public static PxPoint CursorPos() => GetCursorPos(out var p) ? new PxPoint(p.X, p.Y) : new PxPoint(int.MinValue, int.MinValue);

    public static PxRect WorkAreaFor(PxPoint p)
    {
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        IntPtr mon = MonitorFromPoint(new POINT { X = p.X, Y = p.Y }, MONITOR_DEFAULTTONEAREST);
        return GetMonitorInfo(mon, ref info) ? ToPx(info.rcWork) : new PxRect(0, 0, 1920, 1080);
    }

    public static List<PxRect> AllWorkAreas()
    {
        var list = new List<PxRect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(m, ref info)) list.Add(ToPx(info.rcWork));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// <summary>
    /// Is the foreground window covering the whole monitor the pill is on (a game,
    /// a video)? The desktop itself does not count: clicking it makes the shell's
    /// full-screen window the foreground one.
    /// </summary>
    public static bool IsFullscreenAppOver(PxPoint pillCenter)
    {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero || fg == GetShellWindow()) return false;
        var sb = new StringBuilder(64);
        GetClassName(fg, sb, sb.Capacity);
        string cls = sb.ToString();
        if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
        if (!GetWindowRect(fg, out var r)) return false;
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        IntPtr mon = MonitorFromPoint(new POINT { X = pillCenter.X, Y = pillCenter.Y }, MONITOR_DEFAULTTONEAREST);
        if (!GetMonitorInfo(mon, ref info)) return false;
        return PillGeometry.CoversScreen(ToPx(r), ToPx(info.rcMonitor));
    }

    private static PxRect ToPx(RECT r) => new(r.Left, r.Top, r.Right, r.Bottom);

    public static int GetRefreshRate()
    {
        var mode = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        return EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref mode) ? mode.dmDisplayFrequency : 0;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
}
