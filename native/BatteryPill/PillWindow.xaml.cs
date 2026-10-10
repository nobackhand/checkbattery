using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using BatteryPill.Core;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;
using Color = Windows.UI.Color;

namespace BatteryPill;

/// <summary>
/// The floating pill. Every motion runs on the compositor (intro, fill level,
/// pulses, hover) or is stepped once per display frame (glide, settle): nothing
/// moves on a fixed timer.
/// </summary>
public sealed partial class PillWindow : Window
{
    private const float ShadowMargin = 18;
    private const double SettleMs = 180;
    private const double FlingSpeed = 0.3;   // px/ms below which a release just settles

    private readonly AppState _app;
    private readonly IntPtr _hwnd;
    private readonly Compositor _compositor;
    private readonly CompositionEasingFunction _decelerate;
    private readonly CompositionEasingFunction _standard;
    private readonly Native.SubclassProc _subclass;   // kept alive for the native callback
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly VelocityTracker _velocity = new();
    private readonly string? _measurePath;
    private readonly List<double> _frameTimes = new();

    private SpriteVisual? _fill;
    private CompositionColorGradientStop? _fillStart, _fillEnd;
    private SpriteVisual? _shadowSprite;
    private CompositionRoundedRectangleGeometry? _capsule;
    private PillSize _size;
    private double _scale = 1;
    private bool _dark = true;
    private string _pulse = "";
    private string _lastText = "";
    private float _level = -1;

    private PxPoint _dragStart;
    private double _dragStartMs;
    private bool _pressed;
    private bool _dragging;
    private PxPoint _pressAt;
    private bool _built;
    private FlyoutWindow? _flyout;
    private bool _cardPinned;
    private bool _pillVisible = true;
    private readonly TrayIcon _tray;
    private double _hoverSince = -1;
    private double _outsideSince = -1;
    private Glide? _glide;
    private (PxPoint From, PxPoint To, double StartMs)? _settle;
    private double _lastFrameMs;
    private bool _framesHooked;
    private bool _hiddenForFullscreen;
    private bool _clickThrough;

    private readonly DispatcherQueueTimer _tick;
    private readonly DispatcherQueueTimer _watch;

    internal PillWindow(AppState app, string[] args)
    {
        _app = app;
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);
        _compositor = ElementCompositionPreview.GetElementVisual(Root).Compositor;
        _decelerate = _compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        _standard = _compositor.CreateCubicBezierEasingFunction(new Vector2(0.8f, 0f), new Vector2(0.2f, 1f));
        _measurePath = ArgValue(args, "--measure");

        SystemBackdrop = new WinUIEx.TransparentTintBackdrop();
        ConfigureChrome();
        _subclass = WindowProc;
        Native.SetWindowSubclass(_hwnd, _subclass, (UIntPtr)1, UIntPtr.Zero);

        _scale = Native.GetDpiForWindow(_hwnd) / 96.0;
        _dark = _app.IsDark;
        ApplySize(keepPillAt: null);
        PlaceAtSavedOrHome();

        Pill.Loaded += (_, _) =>
        {
            if (_built) return;   // Loaded can fire again; visuals attach once
            _built = true;
            BuildVisuals();
            ApplyTheme();
            ApplyInfo(_app.Tick(), animate: false);
            PlayIntro();
        };
        Pill.PointerPressed += OnPillPressed;
        Pill.PointerMoved += OnPillMoved;
        Pill.PointerReleased += OnPillReleased;
        Pill.PointerEntered += (_, _) => AnimateScale(1.04f);
        Pill.PointerExited += (_, _) => AnimateScale(1.0f);
        Pill.PointerCaptureLost += (_, _) => { Trace.Log($"capture lost dragging={_dragging}"); if (_dragging) EndDrag(); _pressed = false; };
        Pill.ContextRequested += (_, _) => _flyout?.HideCard();
        Pill.ContextFlyout = BuildMenu();

        _app.SettingsChanged += OnSettingsChanged;

        _tick = DispatcherQueue.CreateTimer();
        _tick.Interval = TimeSpan.FromMilliseconds(_app.Config.RefreshInterval);
        _tick.Tick += (_, _) => OnReading(_app.Tick());
        _tick.Start();

        // Cheap housekeeping: click-through of the shadow margin, fullscreen hide
        _watch = DispatcherQueue.CreateTimer();
        _watch.Interval = TimeSpan.FromMilliseconds(50);
        _watch.Tick += (_, _) => Watch();
        _watch.Start();

        _tray = new TrayIcon
        {
            LeftClick = ToggleCardAt,
            MenuState = () => (_pillVisible, _app.Config.DisplayMode, _dark),
            Invoked = OnTrayCommand,
        };
        _tray.Update(_app.Latest, _app.Config.AccentColorIndex, _dark);

        Closed += (_, _) =>
        {
            _tray.Dispose();
            Notifier.Shutdown();
            _tick.Stop();
            _watch.Stop();
            UnhookFrames();
            _flyout?.Close();
            Native.RemoveWindowSubclass(_hwnd, _subclass, (UIntPtr)1);
            _app.Save();
        };

        if (_measurePath != null) StartFrameMeter();
    }

    // ---------------------------------------------------------------- window

    private void ConfigureChrome()
    {
        // Never in the taskbar or Alt+Tab; no title bar, border or resize
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.SetBorderAndTitleBar(false, false);
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
            p.IsAlwaysOnTop = true;
        }
        Native.RemoveWindowFrame(_hwnd);
        Native.SetNoActivate(_hwnd);
    }

    internal void ShowWithoutActivating() => AppWindow.Show(false);

    private int Margin => (int)Math.Round(ShadowMargin * _scale);
    private int PillPxW => (int)Math.Round(_size.Width * _scale);
    private int PillPxH => (int)Math.Round(_size.Height * _scale);

    /// <summary>The pill's top-left on screen, in physical pixels (what the config stores).</summary>
    private PxPoint PillPosition => new(AppWindow.Position.X + Margin, AppWindow.Position.Y + Margin);

    private PxPoint PillCenter => new(PillPosition.X + PillPxW / 2, PillPosition.Y + PillPxH / 2);

    private void MovePill(PxPoint topLeft) => AppWindow.Move(new PointInt32(topLeft.X - Margin, topLeft.Y - Margin));

    private void ApplySize(PxPoint? keepPillAt)
    {
        PxPoint anchor = keepPillAt ?? PillPosition;
        _size = PillGeometry.Dimensions(_app.Config.PillSize, _app.Config.DisplayMode);
        Pill.Width = _size.Width;
        Pill.Height = _size.Height;
        PillShape.RadiusX = PillShape.RadiusY = _size.Height / 2;
        PillStroke.RadiusX = PillStroke.RadiusY = _size.Height / 2;
        PrimaryText.FontSize = _size.FontSize;
        SecondaryText.FontSize = _size.FontSize2 > 0 ? _size.FontSize2 : 10;
        SecondaryText.Visibility = _size.TwoLines ? Visibility.Visible : Visibility.Collapsed;
        int w = (int)Math.Round((_size.Width + 2 * ShadowMargin) * _scale);
        int h = (int)Math.Round((_size.Height + 2 * ShadowMargin) * _scale);
        AppWindow.Resize(new SizeInt32(w, h));
        if (keepPillAt is not null || AppWindow.Position.X != 0 || AppWindow.Position.Y != 0) MovePill(anchor);
        ResizeVisuals();
    }

    private void PlaceAtSavedOrHome()
    {
        var saved = new PxPoint(_app.Config.X, _app.Config.Y);
        bool valid = _app.Config.X != -1 && PillGeometry.IsOnScreen(saved, PillPxW, PillPxH, Native.AllWorkAreas());
        MovePill(valid ? saved : Home());
    }

    private PxPoint Home()
    {
        var area = Native.WorkAreaFor(Native.CursorPos());
        var primary = DisplayArea.Primary?.WorkArea;
        if (primary is RectInt32 r) area = new PxRect(r.X, r.Y, r.X + r.Width, r.Y + r.Height);
        return PillGeometry.DefaultPosition(PillPxW, PillPxH, area);
    }

    // ---------------------------------------------------------------- visuals

    private void BuildVisuals()
    {
        // A real composition drop shadow, shaped by the capsule's own alpha
        var shadow = _compositor.CreateDropShadow();
        shadow.Mask = PillShape.GetAlphaMask();
        shadow.BlurRadius = 14f;
        shadow.Color = Color.FromArgb(255, 0, 0, 0);
        shadow.Offset = new Vector3(0, 3, 0);
        _shadowSprite = _compositor.CreateSpriteVisual();
        _shadowSprite.Shadow = shadow;
        ElementCompositionPreview.SetElementChildVisual(ShadowHost, _shadowSprite);

        // The charge fill: a gradient sprite clipped to the capsule, scaled from the left
        _capsule = _compositor.CreateRoundedRectangleGeometry();
        ElementCompositionPreview.GetElementVisual(FillHost).Clip = _compositor.CreateGeometricClip(_capsule);
        var brush = _compositor.CreateLinearGradientBrush();
        brush.StartPoint = new Vector2(0, 0);
        brush.EndPoint = new Vector2(1, 0);
        _fillStart = _compositor.CreateColorGradientStop(0f, Colors.Transparent);
        _fillEnd = _compositor.CreateColorGradientStop(1f, Colors.Transparent);
        brush.ColorStops.Add(_fillStart);
        brush.ColorStops.Add(_fillEnd);
        _fill = _compositor.CreateSpriteVisual();
        _fill.Brush = brush;
        _fill.Scale = new Vector3(0, 1, 1);
        ElementCompositionPreview.SetElementChildVisual(FillHost, _fill);
        ResizeVisuals();
    }

    private void ResizeVisuals()
    {
        var size = new Vector2((float)_size.Width, (float)_size.Height);
        if (_shadowSprite != null) _shadowSprite.Size = size;
        if (_fill != null) _fill.Size = size;
        if (_capsule != null)
        {
            _capsule.Size = size;
            _capsule.CornerRadius = new Vector2(size.Y / 2);
        }
    }

    private void ApplyTheme()
    {
        _dark = _app.IsDark;
        PillShape.Fill = new SolidColorBrush(_dark ? Color.FromArgb(242, 24, 24, 28) : Color.FromArgb(246, 242, 242, 247));
        PillStroke.Stroke = new SolidColorBrush(_dark ? Color.FromArgb(38, 255, 255, 255) : Color.FromArgb(26, 0, 0, 0));
        var text = new SolidColorBrush(_dark ? Color.FromArgb(255, 245, 245, 250) : Color.FromArgb(255, 28, 28, 30));
        PrimaryText.Foreground = text;
        SecondaryText.Foreground = text;
        if (_shadowSprite?.Shadow is DropShadow s) s.Opacity = _dark ? 0.45f : 0.22f;
        ElementCompositionPreview.GetElementVisual(Root).Opacity = (float)_app.Config.Opacity;
        _level = -1;   // recolor the fill on the next reading
    }

    private void ApplyInfo(BatteryInfo info, bool animate)
    {
        var text = Presentation.PillText(info, _app.Config.DisplayMode);
        string joined = text.Primary + "|" + text.Secondary;
        if (joined != _lastText)
        {
            PrimaryText.Text = text.Primary;
            SecondaryText.Text = text.Secondary;
            if (animate && _lastText.Length > 0 && _app.Config.Animations) FlashText();
            _lastText = joined;
        }

        float level = info.NoBattery ? 0f : Math.Clamp(info.Percent, 0, 100) / 100f;
        var accent = Presentation.AccentColor(info.Percent, info.IsCharging, _app.Config.AccentColorIndex, lightPill: !_dark);
        if (_fill != null && level != _level)
        {
            SetFill(level, accent, animate && _level >= 0 && _app.Config.Animations);
            _level = level;
        }
        else if (_fill != null)
        {
            SetFillColor(accent, animate);
        }

        string pulse = !_app.Config.Animations ? ""
            : info.IsCharging ? "charging"
            : !info.IsPluggedIn && info.Percent >= 0 && info.Percent <= 10 ? "critical"
            : "";
        if (pulse != _pulse) SetPulse(pulse);

        ToolTipService.SetToolTip(Pill, $"{Presentation.StateTitle(info)} - {Presentation.TimeSentence(info)}");
    }

    private Color FillColor(Rgb c, bool end) =>
        Color.FromArgb((byte)(_dark ? (end ? 120 : 52) : (end ? 105 : 40)), c.R, c.G, c.B);

    private void SetFill(float level, Rgb accent, bool animate)
    {
        if (_fill == null) return;
        if (!animate)
        {
            _fill.Scale = new Vector3(level, 1, 1);
            SetFillColor(accent, false);
            return;
        }
        var a = _compositor.CreateVector3KeyFrameAnimation();
        a.InsertKeyFrame(1f, new Vector3(level, 1, 1), _decelerate);
        a.Duration = TimeSpan.FromMilliseconds(600);
        _fill.StartAnimation("Scale", a);
        SetFillColor(accent, true);
    }

    private void SetFillColor(Rgb accent, bool animate)
    {
        if (_fillStart == null || _fillEnd == null) return;
        Color start = FillColor(accent, false), end = FillColor(accent, true);
        if (!animate || !_app.Config.Animations)
        {
            _fillStart.Color = start;
            _fillEnd.Color = end;
            return;
        }
        foreach (var (stop, target) in new[] { (_fillStart, start), (_fillEnd, end) })
        {
            var c = _compositor.CreateColorKeyFrameAnimation();
            c.InsertKeyFrame(1f, target, _decelerate);
            c.Duration = TimeSpan.FromMilliseconds(400);
            stop.StartAnimation("Color", c);
        }
    }

    /// <summary>A soft breathing fill while charging; a quicker one when critically low.</summary>
    private void SetPulse(string pulse)
    {
        _pulse = pulse;
        if (_fill == null) return;
        _fill.StopAnimation("Opacity");
        if (pulse.Length == 0)
        {
            _fill.Opacity = 1f;
            return;
        }
        var easeInOut = _compositor.CreateCubicBezierEasingFunction(new Vector2(0.45f, 0f), new Vector2(0.55f, 1f));
        var a = _compositor.CreateScalarKeyFrameAnimation();
        a.InsertKeyFrame(0f, 1f);
        a.InsertKeyFrame(0.5f, pulse == "charging" ? 0.55f : 0.35f, easeInOut);
        a.InsertKeyFrame(1f, 1f, easeInOut);
        a.Duration = TimeSpan.FromMilliseconds(pulse == "charging" ? 2400 : 1300);
        a.IterationBehavior = AnimationIterationBehavior.Forever;
        _fill.StartAnimation("Opacity", a);
    }

    private void FlashText()
    {
        var v = ElementCompositionPreview.GetElementVisual(TextStack);
        var a = _compositor.CreateScalarKeyFrameAnimation();
        a.InsertKeyFrame(0f, 0.35f);
        a.InsertKeyFrame(1f, 1f, _decelerate);
        a.Duration = TimeSpan.FromMilliseconds(260);
        v.StartAnimation("Opacity", a);
    }

    private void PlayIntro()
    {
        if (!_app.Config.Animations)
        {
            if (_fill != null) _fill.Scale = new Vector3(Math.Max(0, _level), 1, 1);
            return;
        }
        ElementCompositionPreview.SetIsTranslationEnabled(Pill, true);
        var pill = ElementCompositionPreview.GetElementVisual(Pill);

        var rise = _compositor.CreateVector3KeyFrameAnimation();
        rise.InsertKeyFrame(0f, new Vector3(0, 14, 0));
        rise.InsertKeyFrame(1f, Vector3.Zero, _decelerate);
        rise.Duration = TimeSpan.FromMilliseconds(500);
        var fade = _compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0f, 0f);
        fade.InsertKeyFrame(1f, 1f, _decelerate);
        fade.Duration = TimeSpan.FromMilliseconds(400);
        pill.StartAnimation("Translation", rise);
        pill.StartAnimation("Opacity", fade);

        if (_fill != null && _level >= 0)
        {
            var sweep = _compositor.CreateVector3KeyFrameAnimation();
            sweep.InsertKeyFrame(0f, new Vector3(0, 1, 1));
            sweep.InsertKeyFrame(1f, new Vector3(_level, 1, 1), _decelerate);
            sweep.DelayTime = TimeSpan.FromMilliseconds(250);
            sweep.Duration = TimeSpan.FromMilliseconds(900);
            _fill.StartAnimation("Scale", sweep);
        }
    }

    private void AnimateScale(float to)
    {
        if (!_app.Config.Animations) return;
        var pill = ElementCompositionPreview.GetElementVisual(Pill);
        pill.CenterPoint = new Vector3((float)_size.Width / 2, (float)_size.Height / 2, 0);
        var a = _compositor.CreateVector3KeyFrameAnimation();
        a.InsertKeyFrame(1f, new Vector3(to, to, 1), _decelerate);
        a.Duration = TimeSpan.FromMilliseconds(167);
        pill.StartAnimation("Scale", a);
    }

    // ---------------------------------------------------------------- drag, glide, settle

    // A press is a click until the pointer moves 4 px; past that it is a drag,
    // driven here from pointer capture: every pointer move positions the pill
    // directly, and the same samples give the release velocity for the fling.
    private void OnPillPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(Pill).Properties.IsLeftButtonPressed) return;
        StopMotion();
        _pressed = true;
        _dragging = false;
        _pressAt = Native.CursorPos();
        _dragStart = PillPosition;
        _dragStartMs = _clock.Elapsed.TotalMilliseconds;
        _velocity.Reset();
        bool captured = Pill.CapturePointer(e.Pointer);
        Trace.Log($"pressed at {_pressAt.X},{_pressAt.Y} captured={captured}");
        e.Handled = true;
    }

    private void OnPillMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_pressed) return;
        var c = Native.CursorPos();
        Trace.Log($"moved to {c.X},{c.Y} dragging={_dragging}");
        if (!_dragging)
        {
            double dist = Math.Sqrt(Math.Pow(c.X - _pressAt.X, 2) + Math.Pow(c.Y - _pressAt.Y, 2));
            if (dist < 4 * _scale || _app.Config.PositionLocked) return;
            _dragging = true;
            _flyout?.HideCard();
            SetClickThrough(false);
        }
        var to = new PxPoint(_dragStart.X + c.X - _pressAt.X, _dragStart.Y + c.Y - _pressAt.Y);
        MovePill(to);
        _velocity.Add(_clock.Elapsed.TotalMilliseconds, to.X, to.Y);
    }

    private void OnPillReleased(object sender, PointerRoutedEventArgs e)
    {
        Trace.Log($"released pressed={_pressed} dragging={_dragging}");
        if (!_pressed) return;
        _pressed = false;
        bool wasDragging = _dragging;
        Pill.ReleasePointerCaptures();
        if (wasDragging) EndDrag();
        else if (_clock.Elapsed.TotalMilliseconds - _dragStartMs < 500) CycleDisplayMode();
    }

    private void EndDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        OnDragEnded();
    }

    private IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr refData)
    {
        switch ((int)msg)
        {
            case Native.WM_DPICHANGED:
                double newScale = ((int)wParam & 0xFFFF) / 96.0;
                var suggested = Marshal.PtrToStructure<Native.RECT>(lParam);
                DispatcherQueue.TryEnqueue(() =>
                {
                    _scale = newScale;
                    ApplySize(new PxPoint(suggested.Left + (int)Math.Round(ShadowMargin * newScale), suggested.Top + (int)Math.Round(ShadowMargin * newScale)));
                });
                return IntPtr.Zero;
            case Native.WM_DISPLAYCHANGE:
                DispatcherQueue.TryEnqueue(OnDisplayChanged);
                break;
            case Native.WM_POWERBROADCAST when (int)wParam == Native.PBT_APMRESUMEAUTOMATIC:
                DispatcherQueue.TryEnqueue(_app.OnResume);
                break;
            case Native.WM_SETTINGCHANGE:
                if (_app.Config.Theme == "auto") DispatcherQueue.TryEnqueue(() => { if (_app.IsDark != _dark) ApplyTheme(); });
                break;
        }
        return Native.DefSubclassProc(hwnd, msg, wParam, lParam);
    }

    private void OnDragEnded()
    {
        var end = PillPosition;
        var (vx, vy) = _velocity.Velocity(_clock.Elapsed.TotalMilliseconds);
        if (_app.Config.Animations && Math.Sqrt(vx * vx + vy * vy) > FlingSpeed)
        {
            _glide = new Glide(end.X, end.Y, vx, vy);
            HookFrames();
        }
        else
        {
            StartSettle();
        }
    }

    private void StartSettle()
    {
        var at = PillPosition;
        var area = Native.WorkAreaFor(PillCenter);
        var to = PillGeometry.Clamped(PillGeometry.Snapped(at, PillPxW, PillPxH, (int)(24 * _scale), area), PillPxW, PillPxH, area);
        if (!_app.Config.Animations || to == at)
        {
            MovePill(to);
            SavePosition();
            return;
        }
        _settle = (at, to, _clock.Elapsed.TotalMilliseconds);
        HookFrames();
    }

    private void HookFrames()
    {
        if (_framesHooked) return;
        _lastFrameMs = _clock.Elapsed.TotalMilliseconds;
        CompositionTarget.Rendering += OnFrame;
        _framesHooked = true;
    }

    private void UnhookFrames()
    {
        if (!_framesHooked) return;
        CompositionTarget.Rendering -= OnFrame;
        _framesHooked = false;
    }

    private void StopMotion()
    {
        _glide = null;
        _settle = null;
        UnhookFrames();
    }

    // One step per display frame
    private void OnFrame(object? sender, object e)
    {
        double now = _clock.Elapsed.TotalMilliseconds;
        double dt = now - _lastFrameMs;
        _lastFrameMs = now;
        if (_glide != null)
        {
            MovePill(_glide.Step(dt, PillPxW, PillPxH, Native.WorkAreaFor(PillCenter)));
            if (_glide.Done)
            {
                _glide = null;
                UnhookFrames();
                StartSettle();
            }
            return;
        }
        if (_settle is { } s)
        {
            double t = (now - s.StartMs) / SettleMs;
            double k = Easing.OutBack(t);
            MovePill(new PxPoint((int)(s.From.X + (s.To.X - s.From.X) * k), (int)(s.From.Y + (s.To.Y - s.From.Y) * k)));
            if (t >= 1)
            {
                MovePill(s.To);
                _settle = null;
                UnhookFrames();
                SavePosition();
            }
            return;
        }
        UnhookFrames();
    }

    private void SavePosition()
    {
        var p = PillPosition;
        _app.Config.X = p.X;
        _app.Config.Y = p.Y;
        _app.Save();
    }

    private void OnDisplayChanged()
    {
        var areas = Native.AllWorkAreas();
        var saved = new PxPoint(_app.Config.X, _app.Config.Y);
        bool savedValid = _app.Config.X != -1 && PillGeometry.IsOnScreen(saved, PillPxW, PillPxH, areas);
        bool currentValid = PillGeometry.IsOnScreen(PillPosition, PillPxW, PillPxH, areas);
        switch (PillGeometry.OnDisplayChange(savedValid, currentValid, PillPosition == saved))
        {
            case DisplayChangeAction.Restore: MovePill(saved); break;
            case DisplayChangeAction.Park: MovePill(Home()); break;
        }
    }

    // ---------------------------------------------------------------- housekeeping

    private void Watch()
    {
        if (_dragging || _glide != null || _settle != null) return;

        var cursor = Native.CursorPos();
        var pillRect = PxRect.FromSize(PillPosition.X, PillPosition.Y, PillPxW, PillPxH);
        double now = _clock.Elapsed.TotalMilliseconds;

        // Hover, from where the cursor actually is (pointer enter/exit can be
        // missed, and a missed exit re-showed the card the moment it hid):
        // the details card after a 350 ms rest on the pill
        if (!InCapsule(cursor.X - pillRect.Left, cursor.Y - pillRect.Top, PillPxW, PillPxH)) _hoverSince = -1;
        else if (_hoverSince < 0) _hoverSince = now;
        if (_hoverSince >= 0 && !_pressed && now - _hoverSince >= 350 && _flyout?.IsShowing != true && !_hiddenForFullscreen)
        {
            _flyout ??= new FlyoutWindow(_app);
            _flyout.Update(_app.Latest);
            _flyout.ShowNear(pillRect);
        }
        // A card opened from the tray stays until a click lands outside it
        if (_flyout?.IsShowing == true && _cardPinned)
        {
            bool buttonDown = (Native.GetAsyncKeyState(0x01) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x02) & 0x8000) != 0;
            if (buttonDown && !_flyout.ScreenBounds.Contains(cursor.X, cursor.Y)) { _flyout.HideCard(); _cardPinned = false; }
            return;
        }
        // ...which stays while the cursor is on the pill or the card, and goes
        // 150 ms after it has left both
        if (_flyout?.IsShowing == true)
        {
            bool inside = pillRect.Contains(cursor.X, cursor.Y) || _flyout.ScreenBounds.Contains(cursor.X, cursor.Y);
            if (inside) _outsideSince = -1;
            else if (_outsideSince < 0) _outsideSince = now;
            else if (now - _outsideSince >= 150) { _flyout.HideCard(); _outsideSince = -1; }
        }

        // The transparent shadow margin must not eat clicks meant for what is underneath
        var p = PillPosition;
        bool overCapsule = InCapsule(cursor.X - p.X, cursor.Y - p.Y, PillPxW, PillPxH);
        SetClickThrough(!overCapsule);

        // Fullscreen apps (a game, a video) hide the pill
        bool hide = _app.Config.AutoHideFullscreen && Native.IsFullscreenAppOver(PillCenter);
        if (hide != _hiddenForFullscreen)
        {
            _hiddenForFullscreen = hide;
            if (hide) { AppWindow.Hide(); _flyout?.HideCard(); }
            else if (_pillVisible) AppWindow.Show(false);
        }
    }

    private static bool InCapsule(int x, int y, int w, int h)
    {
        if (x < 0 || y < 0 || x >= w || y >= h) return false;
        double r = h / 2.0;
        double cx = Math.Clamp(x, r, w - r);
        double dx = x - cx, dy = y - r;
        return dx * dx + dy * dy <= r * r;
    }

    private void SetClickThrough(bool through)
    {
        if (through == _clickThrough) return;
        _clickThrough = through;
        Native.SetClickThrough(_hwnd, through);
    }

    // ---------------------------------------------------------------- readings, tray

    private void OnReading(BatteryInfo info)
    {
        ApplyInfo(info, animate: true);
        if (_flyout?.IsShowing == true) _flyout.Update(info);
        _tray.Update(info, _app.Config.AccentColorIndex, _dark);
        foreach (var alert in _app.Alerts.Next(info, DateTime.Now)) Notifier.Show(alert.Title, alert.Body);
    }

    private void ToggleCardAt(PxRect anchor)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            _flyout ??= new FlyoutWindow(_app);
            if (_flyout.IsShowing && _cardPinned)
            {
                _flyout.HideCard();
                _cardPinned = false;
                return;
            }
            _flyout.Update(_app.Latest);
            _flyout.ShowNear(anchor);
            _cardPinned = true;
        });
    }

    private void OnTrayCommand(TrayIcon.Command command, string? arg)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            switch (command)
            {
                case TrayIcon.Command.TogglePill:
                    _pillVisible = !_pillVisible;
                    if (_pillVisible && !_hiddenForFullscreen) AppWindow.Show(false);
                    else if (!_pillVisible) { AppWindow.Hide(); _flyout?.HideCard(); }
                    break;
                case TrayIcon.Command.ModeTime: _app.ChangeSettings(c => c.DisplayMode = "time"); break;
                case TrayIcon.Command.ModePercent: _app.ChangeSettings(c => c.DisplayMode = "percent"); break;
                case TrayIcon.Command.ModeBoth: _app.ChangeSettings(c => c.DisplayMode = "both"); break;
                case TrayIcon.Command.ModePower: _app.ChangeSettings(c => c.DisplayMode = "power"); break;
                case TrayIcon.Command.Refresh: OnReading(_app.RefreshNow()); break;
                case TrayIcon.Command.Exit: Close(); break;
                case TrayIcon.Command.PlanBase when arg is not null:
                    _ = Task.Run(() =>
                    {
                        if (!PowerPlans.Activate(arg))
                            DispatcherQueue.TryEnqueue(() => Notifier.Show("Admin rights needed", "Cannot switch power plan without elevation"));
                    });
                    break;
            }
        });
    }

    // ---------------------------------------------------------------- settings

    private void CycleDisplayMode()
    {
        string[] order = { "time", "percent", "both", "power" };
        int i = Array.IndexOf(order, _app.Config.DisplayMode);
        _app.ChangeSettings(c => c.DisplayMode = order[(i + 1) % order.Length]);
    }

    private void OnSettingsChanged()
    {
        _tick.Interval = TimeSpan.FromMilliseconds(_app.Config.RefreshInterval);
        ApplySize(PillPosition);
        ApplyTheme();
        _lastText = "";
        ApplyInfo(_app.Latest, animate: true);
        _tray.Update(_app.Latest, _app.Config.AccentColorIndex, _dark);
        Pill.ContextFlyout = BuildMenu();
    }

    private MenuFlyout BuildMenu()
    {
        var c = _app.Config;
        var menu = new MenuFlyout();

        MenuFlyoutSubItem Radio(string title, string group, (string Label, string Value)[] options, string current, Action<string> set)
        {
            var sub = new MenuFlyoutSubItem { Text = title };
            foreach (var (label, value) in options)
            {
                var item = new RadioMenuFlyoutItem { Text = label, GroupName = group, IsChecked = value == current };
                item.Click += (_, _) => set(value);
                sub.Items.Add(item);
            }
            return sub;
        }

        menu.Items.Add(Radio("Show", "mode", new[] { ("Time left", "time"), ("Percent", "percent"), ("Both", "both"), ("Power (watts)", "power") },
            c.DisplayMode, v => _app.ChangeSettings(x => x.DisplayMode = v)));
        menu.Items.Add(Radio("Size", "size", new[] { ("Compact", "compact"), ("Normal", "normal"), ("Expanded", "expanded") },
            c.PillSize, v => _app.ChangeSettings(x => x.PillSize = v)));
        menu.Items.Add(Radio("Theme", "theme", new[] { ("Dark", "dark"), ("Light", "light"), ("Match Windows", "auto") },
            c.Theme, v => _app.ChangeSettings(x => x.Theme = v)));
        string[] accents = { "Green", "Blue", "Purple", "Cyan", "Pink", "Teal", "Orange", "White" };
        menu.Items.Add(Radio("Accent", "accent", accents.Select((n, i) => (n, i.ToString())).ToArray(),
            c.AccentColorIndex.ToString(), v => _app.ChangeSettings(x => x.AccentColorIndex = int.Parse(v))));
        menu.Items.Add(new MenuFlyoutSeparator());
        var lockItem = new ToggleMenuFlyoutItem { Text = "Lock position", IsChecked = c.PositionLocked };
        lockItem.Click += (_, _) => _app.ChangeSettings(x => x.PositionLocked = lockItem.IsChecked);
        menu.Items.Add(lockItem);
        var hideItem = new ToggleMenuFlyoutItem { Text = "Hide over fullscreen apps", IsChecked = c.AutoHideFullscreen };
        hideItem.Click += (_, _) => _app.ChangeSettings(x => x.AutoHideFullscreen = hideItem.IsChecked);
        menu.Items.Add(hideItem);
        var animItem = new ToggleMenuFlyoutItem { Text = "Animations", IsChecked = c.Animations };
        animItem.Click += (_, _) => _app.ChangeSettings(x => x.Animations = animItem.IsChecked);
        menu.Items.Add(animItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        var exit = new MenuFlyoutItem { Text = "Exit" };
        exit.Click += (_, _) => Close();
        menu.Items.Add(exit);
        return menu;
    }

    // ---------------------------------------------------------------- measurement

    // --measure <file>: record 4 s of frame times, write a summary, exit
    private void StartFrameMeter()
    {
        CompositionTarget.Rendering += OnMeasureFrame;
        var stop = DispatcherQueue.CreateTimer();
        stop.Interval = TimeSpan.FromSeconds(4);
        stop.IsRepeating = false;
        stop.Tick += (_, _) =>
        {
            CompositionTarget.Rendering -= OnMeasureFrame;
            WriteFrameSummary();
            Close();
        };
        stop.Start();
    }

    private void OnMeasureFrame(object? sender, object e)
    {
        if (e is RenderingEventArgs r) _frameTimes.Add(r.RenderingTime.TotalMilliseconds);
    }

    private void WriteFrameSummary()
    {
        var gaps = new List<double>();
        for (int i = 1; i < _frameTimes.Count; i++) gaps.Add(_frameTimes[i] - _frameTimes[i - 1]);
        gaps.Sort();
        var info = _app.Latest;
        string text = gaps.Count == 0
            ? "no frames recorded"
            : string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "frames={0} median_ms={1:F2} p90_ms={2:F2} worst_ms={3:F2} display_hz={4} pill_text={5} no_battery={6} pill_px={7}x{8} at={9},{10}",
                gaps.Count + 1, gaps[gaps.Count / 2], gaps[(int)(gaps.Count * 0.9)], gaps[^1], Native.GetRefreshRate(),
                PrimaryText.Text, info.NoBattery, PillPxW, PillPxH, PillPosition.X, PillPosition.Y);
        File.WriteAllText(_measurePath!, text);
    }

    private static string? ArgValue(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }
}
