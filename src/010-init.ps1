#Requires -Version 5.0

<#
.SYNOPSIS
    Battery Widget - System tray battery monitor with floating desktop bar.
.DESCRIPTION
    Displays a battery icon in the Windows notification area (system tray)
    and a floating draggable bar on the desktop showing time remaining and
    battery percentage. Hover over the pill (500ms) to see a detailed popup with
    capacity, discharge rate, ETA, elapsed time, and battery wear.
    Auto-refreshes every 3 seconds with EMA-smoothed estimates.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\BatteryWidget.Run.ps1
.NOTES
    File map (search for the ==== banner with the same name):
      P/INVOKE + SINGLE INSTANCE ... Win32Icon class, DPI awareness, mutex guard
      THEME ....................... $script:theme palette + Set-Theme (dark/light/auto)
      FULLSCREEN DETECTION ........ Test-FullscreenApp
      BATTERY DATA ................ Get-BatteryInfo (WMI + .NET), EMA smoothing, rates,
                                    Get-PowerDraw / Read-PowerMeterMilliwatts (system watts)
      POWER PLANS ................. tray submenu for switching plans
      STATUS COLOR & ACCENT ....... Get-StatusColor, accent presets, Get-AccentColor
      DYNAMIC TRAY ICON ........... New-BatteryIcon
      UPDATE CHECK ................ daily latest-release check: Start/Complete-UpdateCheck,
                                    the "is out" card, Set-UpdateCheckEnabled
      CONFIG ...................... Get-ConfigPath / Import-Config / Save-Config, autostart
      GDI HELPERS ................. Enable-DoubleBuffering, New-RoundedRectPath
      CACHED GDI+ BRUSHES/PENS .... Initialize-PillBrushes
      FLOATING PILL ............... Get-PillDimensions, Update-PillSize,
                                    Invoke-CycleDisplayMode, New-FloatingBar (paint+drag)
      SPARKLINE ................... New-SparklinePanel
      POPUP CONTENT ............... New-BatteryPopupContent (shared hover/tray builder)
      NOTIFICATIONS ............... Show-BatteryNotification (per-card closure state)
      HOVER POPUP ................. Show-HoverPopup / Close-HoverPopup, fade timers
      TRAY POPUP .................. Show-BatteryPopup (modal)
      SETTINGS / FIRST-RUN / ABOUT. Show-SettingsPanel, Show-FirstRunTooltip, Show-AboutDialog
      UPDATE FUNCTIONS ............ Update-TrayIcon, Update-FloatingBar, pulse timers
      MAIN APPLICATION SETUP ...... tray icon, menus, timers, message loop (bottom)
#>

# --- Load assemblies ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


# All native/C# helper types in ONE Add-Type call. This used to be four
# separate Add-Type invocations - four compiler runs at every launch; merging
# them into a single compilation measurably cuts startup time.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Management @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

// P/Invoke for icon handle cleanup, DPI awareness, fullscreen detection,
// and the DWM window affordances (dark title bar, native rounded corners)
public class Win32Icon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public extern static bool DestroyIcon(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    // CS_DROPSHADOW support for popup elevation
    [DllImport("user32.dll", EntryPoint = "GetClassLong")]
    private static extern int GetClassLong32(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetClassLongPtr")]
    private static extern IntPtr GetClassLong64(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetClassLong")]
    private static extern int SetClassLong32(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", EntryPoint = "SetClassLongPtr")]
    private static extern IntPtr SetClassLong64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static void EnableDropShadow(IntPtr hWnd) {
        const int GCL_STYLE = -26;
        const int CS_DROPSHADOW = 0x00020000;
        if (IntPtr.Size == 8) {
            long style = GetClassLong64(hWnd, GCL_STYLE).ToInt64();
            SetClassLong64(hWnd, GCL_STYLE, new IntPtr(style | CS_DROPSHADOW));
        } else {
            int style = GetClassLong32(hWnd, GCL_STYLE);
            SetClassLong32(hWnd, GCL_STYLE, style | CS_DROPSHADOW);
        }
    }

    // Respect the user's "Show animations in Windows" setting (SPI_GETCLIENTAREAANIMATION)
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref bool pvParam, uint fWinIni);

    public static bool AnimationsEnabled() {
        bool enabled = true;
        if (SystemParametersInfo(0x1042, 0, ref enabled, 0)) { return enabled; }
        return true;
    }

    // Dark title bar for standard (chromed) windows so they don't clash with a dark body
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void UseDarkTitleBar(IntPtr hWnd) {
        int useDark = 1;
        // DWMWA_USE_IMMERSIVE_DARK_MODE = 20 on Win10 2004+/Win11; older builds used 19
        if (DwmSetWindowAttribute(hWnd, 20, ref useDark, 4) != 0) {
            DwmSetWindowAttribute(hWnd, 19, ref useDark, 4);
        }
    }

    // Win11 native rounded corners (DWMWA_WINDOW_CORNER_PREFERENCE=33,
    // DWMWCP_ROUND=2): antialiased corners plus the system window shadow -
    // what native flyouts look like. Returns false on Win10, where callers
    // fall back to Region clipping.
    public static bool TryRoundCorners(IntPtr hWnd) {
        int pref = 2;
        return DwmSetWindowAttribute(hWnd, 33, ref pref, 4) == 0;
    }

    // Explicit title-bar theme (UseDarkTitleBar always forces dark; this one
    // follows the app theme so a Light-theme window gets a light title bar)
    public static void SetTitleBarTheme(IntPtr hWnd, bool dark) {
        int useDark = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hWnd, 20, ref useDark, 4) != 0) {
            DwmSetWindowAttribute(hWnd, 19, ref useDark, 4);
        }
    }
}

// Themed palette for the right-click menus - the stock light-gray Windows
// menu chrome clashes with the app, and the app has TWO themes, so the
// palette is instance-configurable: one class serves both dark and light.
public class AppMenuColorTable : ProfessionalColorTable {
    private readonly Color Bg;
    private readonly Color Sel;
    private readonly Color Sep;
    public AppMenuColorTable(Color bg, Color sel, Color sep) {
        this.UseSystemColors = false;
        Bg = bg; Sel = sel; Sep = sep;
    }
    public override Color ToolStripDropDownBackground   { get { return Bg;  } }
    public override Color ImageMarginGradientBegin      { get { return Bg;  } }
    public override Color ImageMarginGradientMiddle     { get { return Bg;  } }
    public override Color ImageMarginGradientEnd        { get { return Bg;  } }
    public override Color MenuBorder                    { get { return Sep; } }
    public override Color MenuItemBorder                { get { return Sel; } }
    public override Color MenuItemSelected              { get { return Sel; } }
    public override Color MenuItemSelectedGradientBegin { get { return Sel; } }
    public override Color MenuItemSelectedGradientEnd   { get { return Sel; } }
    public override Color MenuItemPressedGradientBegin  { get { return Bg;  } }
    public override Color MenuItemPressedGradientEnd    { get { return Bg;  } }
    public override Color SeparatorDark                 { get { return Sep; } }
    public override Color SeparatorLight                { get { return Sep; } }
}

// Custom dark checkbox - the stock WinForms CheckBox draws an OS-default light
// square with a system-blue check, the one control that still looked bolted-on
// against the themed Settings panel (same problem the opacity slider had). This
// owner-paints a rounded box with an accent fill + white check when on.
public class DarkCheckBox : CheckBox {
    public Color AccentColor = Color.FromArgb(45, 212, 100);
    // Themeable box colors (defaults = the dark panel palette)
    public Color BoxFill = Color.FromArgb(44, 44, 50);
    public Color BoxBorder = Color.FromArgb(92, 92, 102);
    public Color BoxBorderHot = Color.FromArgb(130, 130, 142);
    private Timer _anim;
    private float _checkScale = 1f;   // 0..1, animates the check on toggle-on
    public DarkCheckBox() {
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint
            | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
        this.BackColor = Color.Transparent;
        this.FlatStyle = FlatStyle.Flat;
        this.Cursor = Cursors.Hand;
        _anim = new Timer();
        _anim.Interval = 16;
        _anim.Tick += delegate {
            _checkScale += (1f - _checkScale) * 0.35f + 0.06f;   // ease-out, ~120ms
            if (_checkScale >= 1f) { _checkScale = 1f; _anim.Stop(); }
            this.Invalidate();
        };
    }
    protected override void OnCheckedChanged(EventArgs e) {
        base.OnCheckedChanged(e);
        // Animate ONLY a real user toggle. Show-SettingsPanel sets .Checked from
        // config while building the panel, before the handle exists - animating
        // that left _checkScale at 0 until the first timer tick, and the panel's
        // first paint happens before any tick. ScaleTransform(0,0) is singular,
        // GDI+ throws out of OnPaint, and the control renders as a red X.
        if (this.Checked && this.IsHandleCreated) { _checkScale = 0f; _anim.Start(); }
        else { _anim.Stop(); _checkScale = 1f; }
        this.Invalidate();
    }
    protected override void Dispose(bool disposing) {
        if (disposing && _anim != null) { _anim.Stop(); _anim.Dispose(); }
        base.Dispose(disposing);
    }
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); this.Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); this.Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int box = this.Font.Height;                 // scales with DPI/font
        if (box < 14) box = 14;
        int top = (this.Height - box) / 2;
        float u = box / 16f;
        Rectangle r = new Rectangle(0, top, box, box);
        bool hot = this.ClientRectangle.Contains(this.PointToClient(Control.MousePosition));
        using (GraphicsPath path = Rounded(r, (int)(4 * u))) {
            if (this.Checked) {
                using (SolidBrush b = new SolidBrush(AccentColor)) g.FillPath(b, path);
                // Scale the check about the box center so it pops in on toggle.
                // Skip it entirely at ~0 (mid-pop-in there is no check to draw
                // yet): a 0 scale is a singular matrix and GDI+ throws on it.
                if (_checkScale > 0.01f) {
                    GraphicsState gs = g.Save();
                    float cx = r.X + box / 2f, cy = r.Y + box / 2f;
                    g.TranslateTransform(cx, cy);
                    g.ScaleTransform(_checkScale, _checkScale);
                    g.TranslateTransform(-cx, -cy);
                    using (Pen p = new Pen(Color.FromArgb(22, 22, 26), Math.Max(2f, 2f * u))) {
                        p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                        g.DrawLines(p, new PointF[] {
                            new PointF(r.X + 4f * u,   r.Y + 8.5f * u),
                            new PointF(r.X + 6.8f * u, r.Y + 11.3f * u),
                            new PointF(r.X + 12f * u,  r.Y + 5f * u)
                        });
                    }
                    g.Restore(gs);
                }
            } else {
                using (SolidBrush b = new SolidBrush(BoxFill)) g.FillPath(b, path);
                Color bc = hot ? BoxBorderHot : BoxBorder;
                using (Pen p = new Pen(bc, 1.3f)) g.DrawPath(p, path);
            }
        }
        Rectangle textRect = new Rectangle(box + (int)(9 * u), 0, this.Width - box - (int)(9 * u), this.Height);
        TextRenderer.DrawText(g, this.Text, this.Font, textRect, this.ForeColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
    }
    static GraphicsPath Rounded(Rectangle b, int radius) {
        int d = radius * 2;
        GraphicsPath p = new GraphicsPath();
        if (d <= 0) { p.AddRectangle(b); p.CloseFigure(); return p; }
        p.AddArc(b.X, b.Y, d, d, 180, 90);
        p.AddArc(b.Right - d, b.Y, d, d, 270, 90);
        p.AddArc(b.Right - d, b.Bottom - d, d, d, 0, 90);
        p.AddArc(b.X, b.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

// A form that appears WITHOUT taking focus.
//
// Notification cards and the first-run tip are transient, unattended windows.
// Shown as ordinary Forms they took activation, which deactivated whatever
// the user was reading - and the tray detail popup, the Battery Health card
// and the About dialog all close themselves on Deactivate. So a low-battery
// or "Charging - full by ..." card fired by the 3-second tick slammed shut
// the dialog the user had deliberately opened, mid-read (and cut the health
// card's ring sweep off part-way).
public class NoActivateForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}

// Modern menu renderer - the stock ProfessionalRenderer highlight is a flat
// square block; this one draws a rounded, accent-tinted selection pill so the
// right-click menus feel like part of the app instead of Windows 95 chrome.
public class PillMenuRenderer : ToolStripProfessionalRenderer {
    private readonly Color _accent;
    public PillMenuRenderer(ProfessionalColorTable table, Color accent) : base(table) {
        _accent = accent;
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) { base.OnRenderMenuItemBackground(e); return; }
        Graphics g = e.Graphics;
        SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(2, 1, e.Item.Width - 5, e.Item.Height - 3);
        using (GraphicsPath p = Rounded(r, 5)) {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(38, _accent))) g.FillPath(b, p);
            using (Pen pen = new Pen(Color.FromArgb(110, _accent), 1f)) g.DrawPath(pen, p);
        }
        g.SmoothingMode = old;
    }
    static GraphicsPath Rounded(Rectangle b, int radius) {
        int d = radius * 2;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(b.X, b.Y, d, d, 180, 90);
        p.AddArc(b.Right - d, b.Y, d, d, 270, 90);
        p.AddArc(b.Right - d, b.Bottom - d, d, d, 0, 90);
        p.AddArc(b.X, b.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

// The platform power meter, probed OFF the UI thread. A process's first
// PerformanceCounterCategory query reads every perf provider on the machine
// (HKEY_PERFORMANCE_DATA): measured at 22.7s on a busy desktop, then 0ms.
// The widget made that query on the UI thread during startup, so the app sat
// frozen - no pill, a dead tray icon - until it returned. Pure C#, so no
// PowerShell ever runs on the pool thread; the widget polls State() from its
// refresh tick.
public static class PowerMeterProbe {
    private static System.Threading.Tasks.Task<System.Diagnostics.PerformanceCounter> _probe;
    private static System.Diagnostics.PerformanceCounter _counter;
    private static bool _closed;
    // 0 = probe still running, 1 = meter ready, -1 = no usable meter here
    public static int State() {
        if (_closed) return -1;
        if (_counter != null) return 1;
        if (_probe == null) {
            _probe = System.Threading.Tasks.Task.Run(new Func<System.Diagnostics.PerformanceCounter>(Open));
        }
        if (!_probe.IsCompleted) return 0;
        if (_probe.Status != System.Threading.Tasks.TaskStatus.RanToCompletion || _probe.Result == null) return -1;
        _counter = _probe.Result;
        return 1;
    }
    private static System.Diagnostics.PerformanceCounter Open() {
        if (!System.Diagnostics.PerformanceCounterCategory.Exists("Power Meter")) return null;
        System.Diagnostics.PerformanceCounterCategory cat = new System.Diagnostics.PerformanceCounterCategory("Power Meter");
        if (!cat.InstanceExists("_Total")) return null;
        return new System.Diagnostics.PerformanceCounter("Power Meter", "Power", "_Total", true);
    }
    // Instantaneous milliwatts; throws if the counter fails (the caller then
    // gives up on the meter for good).
    public static double Read() {
        if (_counter == null) return -1;
        return _counter.NextValue();
    }
    // Gives up on the meter for good: State() reports -1 from now on, rather
    // than handing back the counter the finished probe still holds.
    public static void Close() {
        _closed = true;
        if (_counter != null) {
            try { _counter.Dispose(); } catch { }
            _counter = null;
        }
    }
}

// The daily update check's download, entirely on a pool thread. WebClient's
// own *Async methods still resolve DNS and the proxy on the CALLING thread
// before returning - measured 1.1-2.2s of frozen UI per check. The widget
// polls the returned Task from a Forms.Timer; no PowerShell runs off the UI
// thread.
public static class UpdateFetch {
    public static System.Threading.Tasks.Task<string> Start(string uri, string userAgent) {
        return System.Threading.Tasks.Task.Run(new Func<string>(delegate {
            using (System.Net.WebClient wc = new System.Net.WebClient()) {
                wc.Headers.Add("User-Agent", userAgent);
                wc.Encoding = System.Text.Encoding.UTF8;
                return wc.DownloadString(uri);
            }
        }));
    }
}

// Battery readings, taken OFF the UI thread. A WMI query costs 20-900ms
// (measured, more under load) and used to run on the UI thread every refresh
// tick, stalling the pill's animations and drags each time. Poll() hands back
// the latest finished reading and keeps one fresh query in flight, so the UI
// does not wait - except for the very first reading (WaitFirst), so startup
// sees the same complete data it always did.
//
// It also reads the right classes. Win32_Battery has NO charge/discharge rate
// properties at all, and leaves the capacities empty on most modern laptops,
// so the watts line and the rate-based estimate never had real input. The
// battery class driver publishes those in root\WMI - each read separately, so
// one missing class (desktops, odd firmware) cannot cost the others.
public static class BatteryQuery {
    private static System.Threading.Tasks.Task<System.Collections.Hashtable> _task;
    private static DateTime _taskStarted;
    private static System.Collections.Hashtable _last;
    private static DateTime _lastAt;
    // Capacities change over months, not seconds: cached, not queried per tick
    private static System.Collections.Hashtable _caps;
    private static DateTime _capsAt;

    // The latest finished reading, or null when there is none fresh enough to
    // trust (a WMI call can hang - a reading older than a minute is stale,
    // and the widget falls back to .NET's PowerStatus).
    public static System.Collections.Hashtable Poll() {
        if (_task != null && _task.IsCompleted) {
            if (_task.Status == System.Threading.Tasks.TaskStatus.RanToCompletion) {
                _last = _task.Result;
                _lastAt = DateTime.UtcNow;
            }
            _task = null;
        }
        // A query stuck for 30s is abandoned (it cannot be cancelled; its
        // result, if it ever comes, is simply never read)
        if (_task != null && (DateTime.UtcNow - _taskStarted).TotalSeconds > 30) _task = null;
        if (_task == null) {
            _taskStarted = DateTime.UtcNow;
            _task = System.Threading.Tasks.Task.Run(new Func<System.Collections.Hashtable>(Read));
        }
        if (_last != null && (DateTime.UtcNow - _lastAt).TotalSeconds > 60) return null;
        return _last;
    }
    // Startup: wait (up to timeoutMs) for the first reading rather than
    // showing a partial .NET-only one first and flipping a tick later.
    // Only ever waits once: a WMI that hangs at startup must not stall every
    // later tick too.
    private static bool _waited;
    public static System.Collections.Hashtable WaitFirst(int timeoutMs) {
        Poll();
        System.Threading.Tasks.Task<System.Collections.Hashtable> t = _task;
        if (!_waited && _last == null && t != null) {
            _waited = true;
            try { t.Wait(timeoutMs); } catch { }
        }
        return Poll();
    }
    // The tray's Refresh: a fresh reading now, synchronously
    public static System.Collections.Hashtable ReadNow() {
        _last = Read();
        _lastAt = DateTime.UtcNow;
        return _last;
    }
    // One complete reading (synchronous)
    public static System.Collections.Hashtable Read() {
        System.Collections.Hashtable h = new System.Collections.Hashtable();
        h["Found"] = false;
        try {
            using (System.Management.ManagementObjectSearcher s = new System.Management.ManagementObjectSearcher("root\\CIMV2", "SELECT * FROM Win32_Battery"))
            using (System.Management.ManagementObjectCollection all = s.Get()) {
                foreach (System.Management.ManagementBaseObject o in all) {
                    h["Found"] = true;
                    foreach (string p in new string[] { "EstimatedChargeRemaining", "BatteryStatus", "DesignCapacity", "FullChargeCapacity", "EstimatedRunTime", "TimeToFullCharge" }) {
                        h[p] = o[p];
                    }
                    break;   // first pack, as before (dual-battery laptops)
                }
            }
        } catch {
            return h;
        }
        if (!(bool)h["Found"]) return h;
        System.Collections.Hashtable caps = Capacities();
        // A battery that reports RELATIVE units (BATTERY_CAPACITY_RELATIVE)
        // has no mW/mWh to offer - leave rates and capacities unfilled
        if ((bool)caps["Relative"]) return h;
        System.Collections.Hashtable rates = FirstInstance("BatteryStatus", "DischargeRate, ChargeRate");
        h["DischargeRate"] = rates["DischargeRate"];
        h["ChargeRate"] = rates["ChargeRate"];
        if (IsEmpty(h["FullChargeCapacity"])) h["FullChargeCapacity"] = caps["FullChargedCapacity"];
        if (IsEmpty(h["DesignCapacity"])) h["DesignCapacity"] = caps["DesignedCapacity"];
        return h;
    }
    static System.Collections.Hashtable Capacities() {
        System.Collections.Hashtable c = _caps;
        if (c != null && (DateTime.UtcNow - _capsAt).TotalMinutes < 10) return c;
        c = new System.Collections.Hashtable();
        c["FullChargedCapacity"] = FirstInstance("BatteryFullChargedCapacity", "FullChargedCapacity")["FullChargedCapacity"];
        System.Collections.Hashtable st = FirstInstance("BatteryStaticData", "DesignedCapacity, Capabilities");
        c["DesignedCapacity"] = st["DesignedCapacity"];
        bool relative = false;
        try { relative = st["Capabilities"] != null && (Convert.ToUInt32(st["Capabilities"]) & 0x40000000u) != 0; } catch { }
        c["Relative"] = relative;
        _caps = c;
        _capsAt = DateTime.UtcNow;
        return c;
    }
    static bool IsEmpty(object v) {
        if (v == null) return true;
        try { return Convert.ToDouble(v) <= 0; } catch { return true; }
    }
    static System.Collections.Hashtable FirstInstance(string cls, string props) {
        System.Collections.Hashtable r = new System.Collections.Hashtable();
        try {
            using (System.Management.ManagementObjectSearcher s = new System.Management.ManagementObjectSearcher("root\\WMI", "SELECT " + props + " FROM " + cls))
            using (System.Management.ManagementObjectCollection all = s.Get()) {
                foreach (System.Management.ManagementBaseObject o in all) {
                    foreach (string p in props.Split(',')) { r[p.Trim()] = o[p.Trim()]; }
                    break;
                }
            }
        } catch { }
        return r;
    }
}
"@

# Start the first battery reading now, so it runs while the forms are built
try { $null = [BatteryQuery]::Poll() } catch {}

# Declare DPI awareness before any forms are created
[Win32Icon]::SetProcessDPIAware() | Out-Null

# --- Themed modal dialog (matches the app instead of a stock gray MessageBox) ---
# Self-contained: uses only WinForms/Drawing (loaded above) so it works this early,
# before the theme table and notification system exist. Colors mirror $script:theme.
function Show-AppDialog {
    [OutputType([void])]
    param(
        [string]$Title,
        [string]$Message,
        [string]$Glyph = ([string][char]0x26A1),
        [System.Drawing.Color]$Accent = ([System.Drawing.Color]::FromArgb(45, 212, 100)),
        [string]$ButtonText = "Got it"
    )
    $bg = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $fg = [System.Drawing.Color]::FromArgb(245, 245, 250)
    $dim = [System.Drawing.Color]::FromArgb(170, 170, 180)
    $btnBg = [System.Drawing.Color]::FromArgb(44, 44, 50)

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.BackColor = $bg
    $f.TopMost = $true
    $f.ShowInTaskbar = $true
    $f.Text = "BatteryPill"
    $f.KeyPreview = $true
    $tmpG = $f.CreateGraphics(); $ds = $tmpG.DpiX / 96.0; $tmpG.Dispose()
    $f.ClientSize = New-Object System.Drawing.Size([int](360 * $ds), [int](172 * $ds))

    $f.Add_Paint({
            param($s, $e)
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(64, 64, 72), 1)
            $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1)
            $pen.Dispose()
        })

    # Accent strip along the top edge — the app's signature
    $strip = New-Object System.Windows.Forms.Panel
    $strip.BackColor = $Accent
    $strip.Location = New-Object System.Drawing.Point(0, 0)
    $strip.Size = New-Object System.Drawing.Size($f.ClientSize.Width, [int](4 * $ds))
    $f.Controls.Add($strip)

    $glyphFont = New-Object System.Drawing.Font("Segoe UI Symbol", 22, [System.Drawing.FontStyle]::Regular)
    $gl = New-Object System.Windows.Forms.Label
    $gl.Text = $Glyph; $gl.Font = $glyphFont; $gl.ForeColor = $Accent
    $gl.AutoSize = $false
    $gl.Size = New-Object System.Drawing.Size([int](48 * $ds), [int](48 * $ds))
    $gl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $gl.Location = New-Object System.Drawing.Point([int](22 * $ds), [int](30 * $ds))
    $f.Controls.Add($gl)

    $titleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 12, [System.Drawing.FontStyle]::Bold)
    $tl = New-Object System.Windows.Forms.Label
    $tl.Text = $Title; $tl.Font = $titleFont; $tl.ForeColor = $fg
    $tl.AutoSize = $false
    $tl.Location = New-Object System.Drawing.Point([int](84 * $ds), [int](30 * $ds))
    $tl.Size = New-Object System.Drawing.Size([int](256 * $ds), [int](26 * $ds))
    $f.Controls.Add($tl)

    $bodyFont = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $bl = New-Object System.Windows.Forms.Label
    $bl.Text = $Message; $bl.Font = $bodyFont; $bl.ForeColor = $dim
    $bl.AutoSize = $false
    $bl.Location = New-Object System.Drawing.Point([int](84 * $ds), [int](58 * $ds))
    $bl.Size = New-Object System.Drawing.Size([int](256 * $ds), [int](60 * $ds))
    $f.Controls.Add($bl)

    $btnFont = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Regular)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $ButtonText; $btn.Font = $btnFont
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.BackColor = $btnBg; $btn.ForeColor = $fg
    $btn.FlatAppearance.BorderColor = $Accent
    $btn.FlatAppearance.BorderSize = 1
    # Tactile feedback: lift on hover, sink on press
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(58, 58, 66)
    $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(38, 38, 44)
    $btn.Size = New-Object System.Drawing.Size([int](100 * $ds), [int](32 * $ds))
    $btn.Location = New-Object System.Drawing.Point(
        ($f.ClientSize.Width - [int](100 * $ds) - [int](20 * $ds)),
        ($f.ClientSize.Height - [int](32 * $ds) - [int](18 * $ds)))
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($btn)
    $f.AcceptButton = $btn

    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Close() } })

    $f.ShowDialog() | Out-Null
    $glyphFont.Dispose(); $titleFont.Dispose(); $bodyFont.Dispose(); $btnFont.Dispose()
    $f.Dispose()
}

# --- Single-instance guard ---
function New-SingleInstanceMutex {
    [OutputType([hashtable])]
    param([string]$Name = 'Local\BatteryWidgetSingleInstance')
    # Returns @{ Mutex; IsFirst; Failed }.
    #
    # Two deliberate choices here, both learned the hard way:
    #
    # 1. Local\, not Global\. Global\ is the machine-wide kernel namespace, so
    #    the guard spanned LOGON SESSIONS: on a shared PC, with fast user
    #    switching, or over RDP, user B was told BatteryPill was "already
    #    running" when there was no pill and no tray icon anywhere in B's
    #    session. Worse, the mutex user A created carries A's default DACL,
    #    which does not grant B - and the constructor THROWS
    #    UnauthorizedAccessException in that case (verified). That throw was
    #    unguarded at script scope, so the app simply died at startup with no
    #    window and no message. This widget is per-user: one pill per session
    #    is the correct meaning of "single instance".
    #
    # 2. Never let the guard itself kill the app. If the mutex cannot be
    #    created for any reason, report Failed and let the app RUN. A second
    #    pill is a visible annoyance; no app at all is a silent failure.
    $createdNew = $false
    try {
        $mutex = New-Object System.Threading.Mutex($true, $Name, [ref]$createdNew)
        return @{ Mutex = $mutex; IsFirst = $createdNew; Failed = $false }
    } catch {
        return @{ Mutex = $null; IsFirst = $true; Failed = $true }
    }
}

$script:mutexName = 'Local\BatteryWidgetSingleInstance'
$script:instanceGuard = New-SingleInstanceMutex -Name $script:mutexName
$script:mutex = $script:instanceGuard.Mutex
$script:createdNew = $script:instanceGuard.IsFirst

if (-not $script:createdNew) {
    Show-AppDialog -Title "Already running" `
        -Message "Look for the pill on your desktop, or the battery icon in your system tray (bottom-right)." `
        -Glyph ([string][char]0x26A1)
    exit
}

# --- Theme color references ---
$script:theme = @{
    PillBg      = [System.Drawing.Color]::FromArgb(24, 24, 28)
    PopupBg     = [System.Drawing.Color]::FromArgb(26, 26, 30)
    TextPrimary = [System.Drawing.Color]::FromArgb(245, 245, 250)
    TextDim     = [System.Drawing.Color]::FromArgb(145, 145, 155)
    TextLight   = [System.Drawing.Color]::FromArgb(220, 220, 225)
    TextMuted   = [System.Drawing.Color]::FromArgb(80, 80, 86)
    Border      = [System.Drawing.Color]::FromArgb(50, 50, 56)
    SparkBg     = [System.Drawing.Color]::FromArgb(20, 20, 24)
    SparkGuide  = [System.Drawing.Color]::FromArgb(255, 255, 255)
    # Menu palette (context menus follow the theme since the parity pass)
    MenuBg      = [System.Drawing.Color]::FromArgb(32, 32, 36)
    MenuSel     = [System.Drawing.Color]::FromArgb(52, 52, 60)
    MenuSep     = [System.Drawing.Color]::FromArgb(64, 64, 72)
    MenuText    = [System.Drawing.Color]::FromArgb(230, 230, 235)
    # Settings-panel palette (the panel follows the theme too)
    PanelBg     = [System.Drawing.Color]::FromArgb(32, 32, 36)
    PanelText   = [System.Drawing.Color]::FromArgb(230, 230, 235)
    PanelHead   = [System.Drawing.Color]::FromArgb(150, 150, 160)
    PanelCtrl   = [System.Drawing.Color]::FromArgb(50, 50, 56)
    PanelHover  = [System.Drawing.Color]::FromArgb(62, 62, 70)
    PanelDown   = [System.Drawing.Color]::FromArgb(42, 42, 50)
    PanelTrack  = [System.Drawing.Color]::FromArgb(64, 64, 72)
    IsDark      = $true
}

$script:appVersion = "1.4.0"

function Get-SystemTheme {
    [OutputType([bool])]
    param(
        # Test seam: the registry key to read the theme preference from.
        [string]$RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    )
    try {
        $val = Get-ItemPropertyValue -Path $RegPath -Name "AppsUseLightTheme" -ErrorAction Stop
        # The value is a DWORD, but the key is user-writable: a REG_SZ, a
        # REG_MULTI_SZ array, or a missing value must all mean "not light"
        # rather than returning a non-boolean out of a [bool] function.
        $num = Read-DeviceNumber -Raw $val -Min 0 -Max 4294967295
        return ($null -ne $num -and $num -eq 1)  # $true = light theme
    } catch {
        return $false  # default to dark
    }
}

function Test-AutoThemeStale {
    [OutputType([bool])]
    param(
        [string]$ThemeSetting,
        [bool]$IsDark,
        # Get-SystemTheme's answer: $true = Windows apps use the light theme
        [bool]$SystemLight
    )
    # "Auto (follow Windows)" means FOLLOW: true when the Windows app theme
    # no longer matches the palette on screen. Only 'auto' follows - an
    # explicit dark/light choice is the user's, not Windows'.
    if ($ThemeSetting -ne 'auto') { return $false }
    return ($IsDark -eq $SystemLight)
}

function Set-Theme {
    [OutputType([void])]
    param()
    # Remembered so a runtime theme switch can crossfade the pill's background
    # instead of snapping (the fade runs in the pulse timer).
    $oldPillBg = $script:theme.PillBg
    $useDark = $true
    $themeSetting = $script:config.Theme
    if ($themeSetting -eq "light") { $useDark = $false }
    elseif ($themeSetting -eq "auto") { $useDark = -not (Get-SystemTheme) }

    if ($useDark) {
        $script:theme.PillBg = [System.Drawing.Color]::FromArgb(24, 24, 28)
        $script:theme.PopupBg = [System.Drawing.Color]::FromArgb(26, 26, 30)
        $script:theme.TextPrimary = [System.Drawing.Color]::FromArgb(245, 245, 250)
        $script:theme.TextDim = [System.Drawing.Color]::FromArgb(145, 145, 155)
        $script:theme.TextLight = [System.Drawing.Color]::FromArgb(220, 220, 225)
        $script:theme.TextMuted = [System.Drawing.Color]::FromArgb(80, 80, 86)
        $script:theme.Border = [System.Drawing.Color]::FromArgb(50, 50, 56)
        $script:theme.SparkBg = [System.Drawing.Color]::FromArgb(20, 20, 24)
        $script:theme.SparkGuide = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $script:theme.MenuBg = [System.Drawing.Color]::FromArgb(32, 32, 36)
        $script:theme.MenuSel = [System.Drawing.Color]::FromArgb(52, 52, 60)
        $script:theme.MenuSep = [System.Drawing.Color]::FromArgb(64, 64, 72)
        $script:theme.MenuText = [System.Drawing.Color]::FromArgb(230, 230, 235)
        $script:theme.PanelBg = [System.Drawing.Color]::FromArgb(32, 32, 36)
        $script:theme.PanelText = [System.Drawing.Color]::FromArgb(230, 230, 235)
        $script:theme.PanelHead = [System.Drawing.Color]::FromArgb(150, 150, 160)
        $script:theme.PanelCtrl = [System.Drawing.Color]::FromArgb(50, 50, 56)
        $script:theme.PanelHover = [System.Drawing.Color]::FromArgb(62, 62, 70)
        $script:theme.PanelDown = [System.Drawing.Color]::FromArgb(42, 42, 50)
        $script:theme.PanelTrack = [System.Drawing.Color]::FromArgb(64, 64, 72)
        $script:theme.IsDark = $true
    } else {
        $script:theme.PillBg = [System.Drawing.Color]::FromArgb(242, 242, 247)
        $script:theme.PopupBg = [System.Drawing.Color]::FromArgb(248, 248, 252)
        $script:theme.TextPrimary = [System.Drawing.Color]::FromArgb(28, 28, 30)
        $script:theme.TextDim = [System.Drawing.Color]::FromArgb(100, 100, 110)
        $script:theme.TextLight = [System.Drawing.Color]::FromArgb(50, 50, 55)
        $script:theme.TextMuted = [System.Drawing.Color]::FromArgb(170, 170, 180)
        $script:theme.Border = [System.Drawing.Color]::FromArgb(200, 200, 210)
        $script:theme.SparkBg = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $script:theme.SparkGuide = [System.Drawing.Color]::FromArgb(60, 60, 68)
        $script:theme.MenuBg = [System.Drawing.Color]::FromArgb(248, 248, 252)
        $script:theme.MenuSel = [System.Drawing.Color]::FromArgb(228, 228, 235)
        $script:theme.MenuSep = [System.Drawing.Color]::FromArgb(210, 210, 218)
        $script:theme.MenuText = [System.Drawing.Color]::FromArgb(28, 28, 30)
        $script:theme.PanelBg = [System.Drawing.Color]::FromArgb(246, 246, 250)
        $script:theme.PanelText = [System.Drawing.Color]::FromArgb(28, 28, 30)
        $script:theme.PanelHead = [System.Drawing.Color]::FromArgb(110, 110, 120)
        $script:theme.PanelCtrl = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $script:theme.PanelHover = [System.Drawing.Color]::FromArgb(220, 220, 228)
        $script:theme.PanelDown = [System.Drawing.Color]::FromArgb(205, 205, 215)
        $script:theme.PanelTrack = [System.Drawing.Color]::FromArgb(200, 200, 210)
        $script:theme.IsDark = $false
    }

    # Refresh cached brushes for new theme
    Initialize-PillBrushes
    $script:cachedIconPercent = -999   # force tray icon rebuild in the new theme

    # Re-theme the persistent context menus (built once at startup; everything
    # else - popups, cards, panels - reads the theme at creation time)
    if ($null -ne $script:appMenus -and (Get-Command Set-MenuTheme -ErrorAction SilentlyContinue)) {
        foreach ($appMenu in $script:appMenus) { Set-MenuTheme -Menu $appMenu }
    }

    # Apply to floating bar immediately
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $script:floatingBar.BackColor = $script:theme.PillBg
        # Runtime theme switch: crossfade the pill background from the old
        # surface to the new one (~220ms in the pulse timer) rather than
        # snapping. Startup calls land here before the bar exists, so a fade
        # only ever starts from a real visible state.
        if ($script:animOK -and $oldPillBg -ne $script:theme.PillBg) {
            $script:themeFade = @{
                From  = $oldPillBg
                To    = $script:theme.PillBg
                Start = Get-Date
            }
            if (Get-Command Update-PulseTimerState -ErrorAction SilentlyContinue) { Update-PulseTimerState }
        }
        $script:floatingBar.Invalidate()
    }
}

# --- Fullscreen detection state ---
$script:isFullscreenHidden = $false

function Test-RectCoversScreen {
    [OutputType([bool])]
    param(
        [int]$RectLeft, [int]$RectTop, [int]$RectRight, [int]$RectBottom,
        [int]$ScreenLeft, [int]$ScreenTop, [int]$ScreenRight, [int]$ScreenBottom
    )
    # Does a window rectangle cover a screen's bounds entirely?
    return ($RectLeft -le $ScreenLeft -and $RectTop -le $ScreenTop -and
        $RectRight -ge $ScreenRight -and $RectBottom -ge $ScreenBottom)
}

function Test-FullscreenApp {
    [OutputType([bool])]
    param()
    try {
        $hwnd = [Win32Icon]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $rect = New-Object Win32Icon+RECT
        [Win32Icon]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        # Only THIS pill's screen matters. The old loop returned true if the
        # foreground window covered ANY screen, so a fullscreen game or video
        # on monitor 2 hid the pill on monitor 1 - the exact setup where a
        # second monitor exists so the widget can stay visible. Auto-hide is
        # about the pill being in the way; it cannot be in the way of a
        # window that is not on its screen.
        if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
            $scr = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location)
        } else {
            $scr = [System.Windows.Forms.Screen]::PrimaryScreen
        }
        $b = $scr.Bounds
        return (Test-RectCoversScreen -RectLeft $rect.Left -RectTop $rect.Top `
                -RectRight $rect.Right -RectBottom $rect.Bottom `
                -ScreenLeft $b.Left -ScreenTop $b.Top -ScreenRight $b.Right -ScreenBottom $b.Bottom)
    } catch {
        return $false
    }
}

# --- Elapsed time tracking state ---
$script:lastStateChange = @{
    Time    = Get-Date
    Percent = -1
    State   = ""
}

# --- EMA smoothing state for stable battery estimates ---
$script:emaRate = -1           # Smoothed rate (mW) using Exponential Moving Average
$script:lastValidRate = -1     # Last known good rate (for "hold" logic when rate unavailable)
$script:lastValidRateTime = $null  # Timestamp when lastValidRate was set (for stale expiry)
$script:rateHistory = New-Object System.Collections.ArrayList  # Last 10 raw rates (for adaptive alpha)
$script:lastCapacityCheck = $null  # @{ Time; Capacity } for capacity-derived rate cross-validation
$script:capacityRateMismatchCount = 0  # Consecutive divergence count for cross-validation

# --- Battery history for sparkline (last 2 hours) ---
$script:batteryHistory = New-Object System.Collections.ArrayList

# --- Hysteresis state for AC state transitions ---
$script:lastAcState = $null    # Previous AC plugged-in state
$script:stateChangeTime = $null # Timestamp of last AC state change
$script:hysteresisSeconds = 2  # Dead time after AC plug/unplug to ignore rate spikes

# --- Platform power meter (ACPI EMI via the "Power Meter" counter set) ---
# The counter itself lives in PowerMeterProbe (C#, above), probed off the UI thread
$script:powerMeterState = 'untried'  # 'untried' | 'ok' | 'unavailable' (never re-probed)

