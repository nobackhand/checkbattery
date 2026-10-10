using System.Diagnostics;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace BatteryPill;

public sealed partial class PillWindow : Window
{
    private const float PillW = 108, PillH = 34, ShadowMargin = 18;

    private readonly IntPtr _hwnd;
    private readonly Compositor _compositor;
    private readonly CompositionEasingFunction _decelerate;
    private readonly string? _measurePath;
    private readonly List<double> _frameTimes = new();

    public PillWindow(string[] args)
    {
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);
        _compositor = ElementCompositionPreview.GetElementVisual(Root).Compositor;
        // Fluent "decelerate" curve: fast out of the gate, gentle landing
        _decelerate = _compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        _measurePath = ArgValue(args, "--measure");

        SystemBackdrop = new WinUIEx.TransparentTintBackdrop();
        ConfigureChrome();
        PlaceBottomRight();

        Pill.Loaded += (_, _) =>
        {
            AttachShadow();
            ClipFillToCapsule();
            PlayIntro();
        };
        Pill.PointerPressed += OnPillPressed;
        Pill.PointerEntered += (_, _) => AnimateScale(1.04f);
        Pill.PointerExited += (_, _) => AnimateScale(1.0f);

        if (_measurePath != null) StartFrameMeter();
    }

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
        Native.RemoveDwmFrame(_hwnd);
    }

    private void PlaceBottomRight()
    {
        double scale = Native.GetDpiForWindow(_hwnd) / 96.0;
        int w = (int)Math.Round((PillW + 2 * ShadowMargin) * scale);
        int h = (int)Math.Round((PillH + 2 * ShadowMargin) * scale);
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            area.X + area.Width - w - (int)(8 * scale),
            area.Y + area.Height - h - (int)(8 * scale),
            w, h));
    }

    // A real composition drop shadow, shaped by the capsule's own alpha
    private void AttachShadow()
    {
        var shadow = _compositor.CreateDropShadow();
        shadow.Mask = PillShape.GetAlphaMask();
        shadow.BlurRadius = 14f;
        shadow.Color = Windows.UI.Color.FromArgb(255, 0, 0, 0);
        shadow.Opacity = 0.42f;
        shadow.Offset = new Vector3(0, 3, 0);
        var sprite = _compositor.CreateSpriteVisual();
        sprite.Size = new Vector2(PillW, PillH);
        sprite.Shadow = shadow;
        ElementCompositionPreview.SetElementChildVisual(ShadowHost, sprite);
    }

    private void ClipFillToCapsule()
    {
        var capsule = _compositor.CreateRoundedRectangleGeometry();
        capsule.Size = new Vector2(PillW, PillH);
        capsule.CornerRadius = new Vector2(PillH / 2);
        ElementCompositionPreview.GetElementVisual(FillHost).Clip = _compositor.CreateGeometricClip(capsule);
        ElementCompositionPreview.GetElementVisual(FillBar).Scale = new Vector3(0, 1, 1);
    }

    // Everything below runs on the compositor at the display's refresh rate,
    // not on a UI-thread timer
    private void PlayIntro()
    {
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

        var sweep = _compositor.CreateVector3KeyFrameAnimation();
        sweep.InsertKeyFrame(0f, new Vector3(0, 1, 1));
        sweep.InsertKeyFrame(1f, new Vector3(0.68f, 1, 1), _decelerate);
        sweep.DelayTime = TimeSpan.FromMilliseconds(250);
        sweep.Duration = TimeSpan.FromMilliseconds(900);
        ElementCompositionPreview.GetElementVisual(FillBar).StartAnimation("Scale", sweep);
    }

    private void AnimateScale(float to)
    {
        var pill = ElementCompositionPreview.GetElementVisual(Pill);
        pill.CenterPoint = new Vector3(PillW / 2, PillH / 2, 0);
        var a = _compositor.CreateVector3KeyFrameAnimation();
        a.InsertKeyFrame(1f, new Vector3(to, to, 1), _decelerate);
        a.Duration = TimeSpan.FromMilliseconds(167);
        pill.StartAnimation("Scale", a);
    }

    // Hand the drag to Windows' own move loop: it tracks the cursor at full rate
    private void OnPillPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(Pill).Properties.IsLeftButtonPressed) return;
        Native.ReleaseCapture();
        Native.SendMessage(_hwnd, Native.WM_NCLBUTTONDOWN, (IntPtr)Native.HTCAPTION, IntPtr.Zero);
    }

    // --measure <file>: record 4s of frame times, write a summary, exit
    private void StartFrameMeter()
    {
        CompositionTarget.Rendering += OnRendering;
        var stop = DispatcherQueue.CreateTimer();
        stop.Interval = TimeSpan.FromSeconds(4);
        stop.IsRepeating = false;
        stop.Tick += (_, _) =>
        {
            CompositionTarget.Rendering -= OnRendering;
            WriteFrameSummary();
            Application.Current.Exit();
        };
        stop.Start();
    }

    private void OnRendering(object? sender, object e)
    {
        if (e is RenderingEventArgs r) _frameTimes.Add(r.RenderingTime.TotalMilliseconds);
    }

    private void WriteFrameSummary()
    {
        var gaps = new List<double>();
        for (int i = 1; i < _frameTimes.Count; i++) gaps.Add(_frameTimes[i] - _frameTimes[i - 1]);
        gaps.Sort();
        string text = gaps.Count == 0
            ? "no frames recorded"
            : string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "frames={0} median_ms={1:F2} p90_ms={2:F2} worst_ms={3:F2} fps={4:F0} display_hz={5}",
                gaps.Count + 1, gaps[gaps.Count / 2], gaps[(int)(gaps.Count * 0.9)], gaps[^1],
                1000.0 / gaps[gaps.Count / 2], Native.GetRefreshRate());
        File.WriteAllText(_measurePath!, text);
    }

    private static string? ArgValue(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }
}
