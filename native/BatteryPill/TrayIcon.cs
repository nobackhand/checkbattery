using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using BatteryPill.Core;

namespace BatteryPill;

/// <summary>
/// The notification-area icon: a live battery glyph, a tooltip, a Windows 11
/// menu on right-click and the details card on left-click. Owns a hidden
/// top-level window for the tray callbacks (a menu needs a foreground-capable
/// owner, which the no-activate pill is not).
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    public enum Command { None = 0, TogglePill = 1, ModeTime, ModePercent, ModeBoth, ModePower, Refresh, Exit, Settings, GetUpdate, PlanBase = 1000 }

    private const int WM_APP_TRAY = 0x8000 + 1;
    private const int WM_CONTEXTMENU = 0x007B, WM_LBUTTONUP = 0x0202, WM_INITMENUPOPUP = 0x0117, NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401;
    private const int NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    private const int NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    private const uint MF_STRING = 0, MF_SEPARATOR = 0x800, MF_POPUP = 0x10, MF_CHECKED = 8, MF_GRAYED = 1;
    private const uint TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 2, TPM_BOTTOMALIGN = 0x20;

    private readonly WndProc _proc;   // kept alive for the native callback
    private readonly IntPtr _hwnd;
    private readonly uint _taskbarCreated;
    private IntPtr _icon;
    private string _iconKey = "";
    private string _tip = "BatteryPill";
    private IntPtr _planMenu;
    private IReadOnlyList<PowerPlan> _plans = Array.Empty<PowerPlan>();

    public Action<PxRect>? LeftClick;
    public Func<(bool PillVisible, string Mode, bool Dark, string? Update)>? MenuState;
    public Action<Command, string?>? Invoked;

    public TrayIcon()
    {
        _proc = Proc;
        var wc = new WNDCLASSEX { cbSize = Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = _proc, hInstance = GetModuleHandle(null), lpszClassName = "BatteryPillTray" };
        RegisterClassEx(ref wc);
        _hwnd = CreateWindowEx(0x80 /* WS_EX_TOOLWINDOW */, "BatteryPillTray", "BatteryPill tray", 0x80000000 /* WS_POPUP */, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        Add();
    }

    private NOTIFYICONDATA Data(int flags) => new()
    {
        cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd = _hwnd,
        uID = 1,
        uFlags = flags,
        uCallbackMessage = WM_APP_TRAY,
        hIcon = _icon,
        szTip = _tip,
        uVersion = 4,
    };

    private void Add()
    {
        var d = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        bool added = Shell_NotifyIcon(NIM_ADD, ref d);
        Shell_NotifyIcon(NIM_SETVERSION, ref d);
        Trace.Log($"tray added={added}");
    }

    /// <summary>Redraw only when what the glyph shows actually changed.</summary>
    public void Update(BatteryInfo b, int accentIndex, bool dark)
    {
        string tip = b.NoBattery ? "BatteryPill - on AC power" : $"{(b.Percent >= 0 ? b.Percent + "%" : "--")} - {Presentation.StateTitle(b)}";
        if (b.TimeMinutes > 0 && !b.IsFullyCharged) tip += $" - {Format.Duration(b.TimeMinutes)}{(b.IsCharging ? " to full" : " left")}";
        _tip = tip.Length > 120 ? tip[..120] : tip;

        int size = Math.Max(16, GetSystemMetricsForDpi(49 /* SM_CXSMICON */, GetDpiForSystem()));
        string key = $"{b.Percent}|{b.IsCharging}|{b.NoBattery}|{accentIndex}|{dark}|{size}";
        if (key != _iconKey)
        {
            var old = _icon;
            _icon = Render(b, accentIndex, dark, size);
            _iconKey = key;
            if (old != IntPtr.Zero) DestroyIcon(old);
        }
        var d = Data(NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIcon(NIM_MODIFY, ref d);
    }

    /// <summary>Port of New-BatteryIcon: a capsule with the charge fill, a bolt while charging.</summary>
    internal static IntPtr Render(BatteryInfo b, int accentIndex, bool dark, int size)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);
            g.ScaleTransform(size / 16f, size / 16f);
            const float x = 1, y = 4, w = 14, h = 8, r = 4;
            using var path = new GraphicsPath();
            path.AddArc(x, y, 2 * r, h, 90, 180);
            path.AddArc(x + w - 2 * r, y, 2 * r, h, 270, 180);
            path.CloseFigure();
            bool critical = b.Percent >= 0 && b.Percent <= 10 && !b.IsCharging;
            using (var body = new SolidBrush(critical ? System.Drawing.Color.FromArgb(72, 26, 28) : dark ? System.Drawing.Color.FromArgb(44, 44, 50) : System.Drawing.Color.FromArgb(225, 225, 232)))
                g.FillPath(body, path);
            int pct = b.NoBattery ? 100 : Math.Clamp(b.Percent, 0, 100);
            float fill = pct / 100f * w;
            if (fill > 0)
            {
                var state = g.Save();
                g.SetClip(path);
                var a = b.NoBattery ? new Rgb(128, 128, 128) : Presentation.AccentColor(b.Percent, b.IsCharging, accentIndex, lightPill: !dark);
                using (var brush = new SolidBrush(System.Drawing.Color.FromArgb(a.R, a.G, a.B))) g.FillRectangle(brush, x, y, fill, h);
                g.Restore(state);
            }
            if (b.IsCharging)
            {
                PointF[] bolt = { new(9.7f, 3.8f), new(5.2f, 8.9f), new(7.8f, 8.9f), new(6.5f, 12.2f), new(10.8f, 6.8f), new(8.4f, 6.8f) };
                using (var edge = new Pen(System.Drawing.Color.FromArgb(170, 0, 0, 0), 1.6f) { LineJoin = LineJoin.Round }) g.DrawPolygon(edge, bolt);
                g.FillPolygon(Brushes.White, bolt);
            }
            using var outline = new Pen(critical ? System.Drawing.Color.FromArgb(255, 80, 80) : dark ? System.Drawing.Color.FromArgb(150, 150, 160) : System.Drawing.Color.FromArgb(110, 110, 120), 1f) { LineJoin = LineJoin.Round };
            g.DrawPath(outline, path);
        }
        return bmp.GetHicon();
    }

    /// <summary>
    /// BATTERYPILL_ICON_DUMP=&lt;dir&gt;: write the glyph for each state as a PNG (for review).
    /// </summary>
    public static void DumpIcons(string dir)
    {
        Directory.CreateDirectory(dir);
        var states = new (string Name, BatteryInfo Info)[]
        {
            ("discharging-64", new BatteryInfo { Percent = 64 }),
            ("charging-47", new BatteryInfo { Percent = 47, IsCharging = true, IsPluggedIn = true }),
            ("low-18", new BatteryInfo { Percent = 18 }),
            ("critical-8", new BatteryInfo { Percent = 8 }),
            ("no-battery", new BatteryInfo { NoBattery = true }),
        };
        foreach (bool dark in new[] { true, false })
            foreach (var (name, info) in states)
                foreach (int size in new[] { 16, 24, 32 })
                {
                    IntPtr h = Render(info, 0, dark, size);
                    using (var icon = Icon.FromHandle(h))
                    using (var bmp = icon.ToBitmap())
                        bmp.Save(Path.Combine(dir, $"tray-{(dark ? "dark" : "light")}-{name}-{size}.png"));
                    DestroyIcon(h);
                }
    }

    private IntPtr Proc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == _taskbarCreated)
        {
            Add();   // Explorer restarted: the icon must be added again
            return IntPtr.Zero;
        }
        if (msg == WM_APP_TRAY)
        {
            int ev = (int)lParam & 0xFFFF;
            if (ev == WM_CONTEXTMENU) ShowMenu();
            else if (ev is NIN_SELECT or NIN_KEYSELECT or WM_LBUTTONUP) LeftClick?.Invoke(IconRect());
            return IntPtr.Zero;
        }
        if (msg == WM_INITMENUPOPUP && wParam == _planMenu && _planMenu != IntPtr.Zero)
        {
            // Read the plans only when that submenu opens: powercfg is a child process
            while (GetMenuItemCount(_planMenu) > 0) RemoveMenu(_planMenu, 0, 0x400 /* MF_BYPOSITION */);
            _plans = PowerPlans.Read();
            if (_plans.Count == 0) AppendMenu(_planMenu, MF_STRING | MF_GRAYED, 0, "Not available");
            for (int i = 0; i < _plans.Count; i++)
                AppendMenu(_planMenu, MF_STRING | (_plans[i].IsActive ? MF_CHECKED : 0), (UIntPtr)((int)Command.PlanBase + i), _plans[i].Name);
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private void ShowMenu()
    {
        var (pillVisible, mode, dark, update) = MenuState?.Invoke() ?? (true, "time", true, null);
        SetMenuTheme(dark);
        IntPtr menu = CreatePopupMenu();
        IntPtr modes = CreatePopupMenu();
        _planMenu = CreatePopupMenu();
        AppendMenu(menu, MF_STRING | (pillVisible ? MF_CHECKED : 0), (UIntPtr)(int)Command.TogglePill, "Show pill");
        AppendMenu(menu, MF_SEPARATOR, 0, null);
        foreach (var (cmd, label, value) in new[] { (Command.ModeTime, "Time left", "time"), (Command.ModePercent, "Percent", "percent"), (Command.ModeBoth, "Both", "both"), (Command.ModePower, "Power (watts)", "power") })
            AppendMenu(modes, MF_STRING | (mode == value ? MF_CHECKED : 0), (UIntPtr)(int)cmd, label);
        AppendMenu(menu, MF_POPUP, (UIntPtr)(ulong)modes, "Show");
        AppendMenu(_planMenu, MF_STRING | MF_GRAYED, 0, "Loading...");
        AppendMenu(menu, MF_POPUP, (UIntPtr)(ulong)_planMenu, "Power plan");
        AppendMenu(menu, MF_STRING, (UIntPtr)(int)Command.Refresh, "Refresh now");
        AppendMenu(menu, MF_STRING, (UIntPtr)(int)Command.Settings, "Settings...");
        if (update is not null) AppendMenu(menu, MF_STRING, (UIntPtr)(int)Command.GetUpdate, $"Get BatteryPill {update}");
        AppendMenu(menu, MF_SEPARATOR, 0, null);
        AppendMenu(menu, MF_STRING, (UIntPtr)(int)Command.Exit, "Exit");

        GetCursorPos(out var pt);
        SetForegroundWindow(_hwnd);   // so the menu closes when the user clicks elsewhere
        int chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.X, pt.Y, _hwnd, IntPtr.Zero);
        DestroyMenu(menu);   // destroys the submenus too
        _planMenu = IntPtr.Zero;
        if (chosen >= (int)Command.PlanBase && chosen - (int)Command.PlanBase < _plans.Count)
            Invoked?.Invoke(Command.PlanBase, _plans[chosen - (int)Command.PlanBase].Guid);
        else if (chosen != 0)
            Invoked?.Invoke((Command)chosen, null);
    }

    /// <summary>Dark Win32 menus follow the app theme (uxtheme's documented-by-use ordinals; best effort).</summary>
    private static void SetMenuTheme(bool dark)
    {
        try
        {
            SetPreferredAppMode(dark ? 2 : 3);
            FlushMenuThemes();
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException) { }
    }

    private PxRect IconRect()
    {
        var id = new NOTIFYICONIDENTIFIER { cbSize = Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = _hwnd, uID = 1 };
        if (Shell_NotifyIconGetRect(ref id, out var r) == 0) return new PxRect(r.Left, r.Top, r.Right, r.Bottom);
        GetCursorPos(out var p);
        return new PxRect(p.X - 8, p.Y - 8, p.X + 8, p.Y + 8);
    }

    public void Dispose()
    {
        var d = Data(0);
        Shell_NotifyIcon(NIM_DELETE, ref d);
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        DestroyWindow(_hwnd);
    }

    // ---- interop ----

    private delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize; public uint style; public WndProc lpfnWndProc; public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public int cbSize; public IntPtr hWnd; public int uID; public int uFlags; public int uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER { public int cbSize; public IntPtr hWnd; public int uID; public Guid guidItem; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(int msg, ref NOTIFYICONDATA data);
    [DllImport("shell32.dll")] private static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out Native.RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWindowEx(int ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool RemoveMenu(IntPtr menu, uint pos, uint flags);
    [DllImport("user32.dll")] private static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Native.POINT p);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    [DllImport("uxtheme.dll", EntryPoint = "#135")] private static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#136")] private static extern void FlushMenuThemes();
}
