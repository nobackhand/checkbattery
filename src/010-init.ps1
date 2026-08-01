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
      BATTERY DATA ................ Get-BatteryInfo (WMI + .NET), EMA smoothing, rates
      POWER PLANS ................. tray submenu for switching plans
      STATUS COLOR & ACCENT ....... Get-StatusColor, accent presets, Get-AccentColor
      DYNAMIC TRAY ICON ........... New-BatteryIcon
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


# P/Invoke for proper icon handle cleanup, DPI awareness, and fullscreen detection
Add-Type @"
using System;
using System.Runtime.InteropServices;
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
}
"@

# Dark palette for the right-click menus - without this they render as the
# stock light-gray Windows menu, which clashes hard with the otherwise-dark app.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System.Drawing;
using System.Windows.Forms;
public class DarkMenuColorTable : ProfessionalColorTable {
    static readonly Color Bg  = Color.FromArgb(32, 32, 36);
    static readonly Color Sel = Color.FromArgb(52, 52, 60);
    static readonly Color Sep = Color.FromArgb(64, 64, 72);
    public DarkMenuColorTable() { this.UseSystemColors = false; }
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
"@

# Custom dark checkbox — the stock WinForms CheckBox draws an OS-default light
# square with a system-blue check, the one control that still looked bolted-on
# against the themed Settings panel (same problem the opacity slider had). This
# owner-paints a rounded box with an accent fill + white check when on.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
public class DarkCheckBox : CheckBox {
    public Color AccentColor = Color.FromArgb(45, 212, 100);
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
                using (SolidBrush b = new SolidBrush(Color.FromArgb(44, 44, 50))) g.FillPath(b, path);
                Color bc = hot ? Color.FromArgb(130, 130, 142) : Color.FromArgb(92, 92, 102);
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
"@

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
$script:mutexName = "Global\BatteryWidgetSingleInstance"
$script:createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, $script:mutexName, [ref]$script:createdNew)

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
}

$script:appVersion = "1.1.9"

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

function Set-Theme {
    [OutputType([void])]
    param()
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
    }

    # Refresh cached brushes for new theme
    Initialize-PillBrushes
    $script:cachedIconPercent = -999   # force tray icon rebuild in the new theme

    # Apply to floating bar immediately
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $script:floatingBar.BackColor = $script:theme.PillBg
        $script:floatingBar.Invalidate()
    }
}

# --- Fullscreen detection state ---
$script:isFullscreenHidden = $false

function Test-FullscreenApp {
    [OutputType([bool])]
    param()
    try {
        $hwnd = [Win32Icon]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $rect = New-Object Win32Icon+RECT
        [Win32Icon]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        # Check if foreground window covers any screen entirely
        foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
            $b = $scr.Bounds
            if ($rect.Left -le $b.Left -and $rect.Top -le $b.Top -and
                $rect.Right -ge $b.Right -and $rect.Bottom -ge $b.Bottom) {
                return $true
            }
        }
        return $false
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

