using System.Numerics;
using BatteryPill.Core;
using Microsoft.UI.Composition;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.Graphics;
using WinRT.Interop;
using Color = Windows.UI.Color;

namespace BatteryPill;

/// <summary>
/// The hover card: Fluent acrylic, rounded, never takes focus. Everything the
/// PowerShell popup showed, with the motion on the compositor.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    public const double CardWidth = 340;
    private const double SparkWidth = CardWidth - 40;
    private const double SparkHeight = 56;
    private const int Gap = 10;

    private readonly AppState _app;
    private readonly IntPtr _hwnd;
    private readonly Compositor _compositor;
    private readonly CompositionEasingFunction _decelerate;
    private bool _visible;
    private bool _above;

    internal FlyoutWindow(AppState app)
    {
        _app = app;
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);
        _compositor = ElementCompositionPreview.GetElementVisual(Root).Compositor;
        _decelerate = _compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        SystemBackdrop = new DesktopAcrylicBackdrop();
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            // Border on, title bar off: Windows 11's own rounded corners and shadow
            p.SetBorderAndTitleBar(true, false);
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
            p.IsAlwaysOnTop = true;
        }
        Native.SetNoActivate(_hwnd);
        ElementCompositionPreview.SetIsTranslationEnabled(Root, true);
        Root.SizeChanged += (_, _) => RefitHeight();
    }

    public bool IsShowing => _visible;

    private double Scale => Native.GetDpiForWindow(_hwnd) / 96.0;

    /// <summary>The card's screen rectangle (physical pixels).</summary>
    public PxRect ScreenBounds => PxRect.FromSize(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);

    public void Update(BatteryInfo b)
    {
        bool dark = _app.IsDark;
        Root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        if (b.NoBattery)
        {
            NoBatteryPanel.Visibility = Visibility.Visible;
            BatteryPanel.Visibility = Visibility.Collapsed;
            return;
        }
        NoBatteryPanel.Visibility = Visibility.Collapsed;
        BatteryPanel.Visibility = Visibility.Visible;

        TitleText.Text = Presentation.StateTitle(b).ToUpperInvariant();
        ElapsedText.Text = Presentation.ElapsedPhrase(b);
        HeroText.Text = b.PercentExact >= 0 ? $"{BatteryInterpreter.RoundInt(b.PercentExact)}%" : "--";
        HeroText.Foreground = Brush(Presentation.HeroPercentColor(b.StatusText, lightCard: !dark));
        TimeText.Text = Presentation.TimeSentence(b);

        string power = Presentation.PowerSentence(b, _app.Config.FunLines);
        PowerPanel.Visibility = power.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PowerText.Text = power;
        if (power.Length > 0) UpdateMeter(b, dark);

        string fun = _app.Config.FunLines ? Presentation.FunStatusLine(b) : "";
        FunText.Text = fun;
        FunText.Visibility = fun.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        DrawSparkline(b, dark);
    }

    private void UpdateMeter(BatteryInfo b, bool dark)
    {
        var stats = BatteryHistory.PowerDrawStats(_app.History.Samples);
        double watts = b.PowerDraw.Watts;
        double max = Math.Max(45, Math.Max(stats.Peak, watts) * 1.25);
        double width = SparkWidth;
        MeterTrack.Background = new SolidColorBrush(dark ? Color.FromArgb(40, 255, 255, 255) : Color.FromArgb(28, 0, 0, 0));
        var color = b.PowerDraw.Kind == PowerDrawKind.Charge ? new Rgb(255, 200, 0) : Presentation.PowerBandColor(watts);
        MeterFill.Background = Brush(color);
        MeterFill.Width = Math.Clamp(watts / max, 0.03, 1) * width;
        bool haveStats = stats.Samples > 0 && b.PowerDraw.Kind == PowerDrawKind.Draw;
        MeterAvgTick.Visibility = haveStats ? Visibility.Visible : Visibility.Collapsed;
        MeterAvgTick.Fill = new SolidColorBrush(dark ? Color.FromArgb(255, 245, 245, 250) : Color.FromArgb(255, 28, 28, 30));
        MeterAvgTick.Margin = new Thickness(Math.Clamp(stats.Avg / max, 0, 1) * width - 1, -2, 0, -2);
        MeterCaption.Text = haveStats ? $"avg {Math.Round(stats.Avg):0} W  ·  peak {Math.Round(stats.Peak):0} W" : "";
        MeterCaption.Visibility = haveStats ? Visibility.Visible : Visibility.Collapsed;
    }

    private void DrawSparkline(BatteryInfo b, bool dark)
    {
        var history = _app.History.Samples;
        SparkCanvas.Children.Clear();
        SparkArea.Background = new SolidColorBrush(dark ? Color.FromArgb(22, 255, 255, 255) : Color.FromArgb(14, 0, 0, 0));
        var accent = Presentation.AccentColor(b.Percent, b.IsCharging, _app.Config.AccentColorIndex, lightPill: !dark);
        var pts = Sparkline.Points(history, SparkWidth, SparkHeight);
        if (pts.Count < 2)
        {
            SparkLeft.Text = "Collecting history...";
            return;
        }

        // Charging stretches, shaded behind the line
        double denom = history.Count - 1;
        foreach (var (start, end) in Sparkline.ChargingRuns(history))
        {
            double x0 = start / denom * SparkWidth, x1 = end / denom * SparkWidth;
            var band = new Rectangle { Width = Math.Max(2, x1 - x0), Height = SparkHeight, Fill = new SolidColorBrush(Color.FromArgb(34, 255, 200, 0)) };
            Microsoft.UI.Xaml.Controls.Canvas.SetLeft(band, x0);
            SparkCanvas.Children.Add(band);
        }

        // Soft area under the line, then the line itself
        var area = new Polygon
        {
            Fill = new LinearGradientBrush(new GradientStopCollection
            {
                new GradientStop { Color = Color.FromArgb(70, accent.R, accent.G, accent.B), Offset = 0 },
                new GradientStop { Color = Color.FromArgb(0, accent.R, accent.G, accent.B), Offset = 1 },
            }, 90),
        };
        area.Points.Add(new Point(pts[0].X, SparkHeight));
        foreach (var p in pts) area.Points.Add(new Point(p.X, p.Y));
        area.Points.Add(new Point(pts[^1].X, SparkHeight));
        SparkCanvas.Children.Add(area);

        var line = new Polyline
        {
            Stroke = Brush(accent),
            StrokeThickness = 2,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        foreach (var p in pts) line.Points.Add(new Point(p.X, p.Y));
        SparkCanvas.Children.Add(line);

        // "Now" dot
        var dot = new Ellipse { Width = 7, Height = 7, Fill = Brush(accent) };
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(dot, pts[^1].X - 3.5);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(dot, pts[^1].Y - 3.5);
        SparkCanvas.Children.Add(dot);

        int span = BatteryHistory.SpanMinutes(history);
        SparkLeft.Text = span > 0 ? Format.Duration(span) + " ago" : "";
    }

    private static SolidColorBrush Brush(Rgb c) => new(Color.FromArgb(c.A, c.R, c.G, c.B));

    /// <summary>Size to the content, place it beside the pill, and slide it in.</summary>
    public void ShowNear(PxRect pill)
    {
        // On a monitor with another scale, step onto it FIRST: the DPI switch
        // (and WinUI's own resize for it) happens during that move, so the size
        // below is computed once, at the scale the card will actually show at
        var pillCenter = new PxPoint((pill.Left + pill.Right) / 2, (pill.Top + pill.Bottom) / 2);
        if (Native.DpiAt(pillCenter) != Native.GetDpiForWindow(_hwnd)) AppWindow.Move(new PointInt32(pillCenter.X, pillCenter.Y));
        double scale = Scale;
        // Lay the content out first: measuring before layout under-reported the
        // height and clipped the graph's labels
        Root.UpdateLayout();
        Root.Measure(new Size(CardWidth, double.PositiveInfinity));
        int w = (int)Math.Round(CardWidth * scale);
        int h = (int)Math.Ceiling((Root.DesiredSize.Height + 6) * scale);
        var area = Native.WorkAreaFor(new PxPoint((pill.Left + pill.Right) / 2, (pill.Top + pill.Bottom) / 2));
        int gap = (int)(Gap * scale);
        bool above = pill.Top - gap - h >= area.Top;
        int y = above ? pill.Top - gap - h : pill.Bottom + gap;
        int x = pill.Right - w;
        _above = above;
        var p = PillGeometry.Clamped(new PxPoint(x, y), w, h, area);
        AppWindow.MoveAndResize(new RectInt32(p.X, p.Y, w, h));

        if (!_visible)
        {
            AppWindow.Show(false);
            _visible = true;
            if (_app.Config.Animations)
            {
                var root = ElementCompositionPreview.GetElementVisual(Root);
                var slide = _compositor.CreateVector3KeyFrameAnimation();
                slide.InsertKeyFrame(0f, new Vector3(0, above ? 8 : -8, 0));
                slide.InsertKeyFrame(1f, Vector3.Zero, _decelerate);
                slide.Duration = TimeSpan.FromMilliseconds(220);
                var fade = _compositor.CreateScalarKeyFrameAnimation();
                fade.InsertKeyFrame(0f, 0f);
                fade.InsertKeyFrame(1f, 1f, _decelerate);
                fade.Duration = TimeSpan.FromMilliseconds(180);
                root.StartAnimation("Translation", slide);
                root.StartAnimation("Opacity", fade);
            }
        }
    }

    /// <summary>Re-fit the height when the content changes size after showing.</summary>
    private void RefitHeight()
    {
        if (!_visible) return;
        double scale = Scale;
        Root.Measure(new Size(CardWidth, double.PositiveInfinity));
        int h = (int)Math.Ceiling((Root.DesiredSize.Height + 6) * scale);
        if (Math.Abs(h - AppWindow.Size.Height) > 1)
        {
            // Keep the edge nearest the pill fixed: a card above the pill grows upward
            int bottom = AppWindow.Position.Y + AppWindow.Size.Height;
            bool above = _above;
            AppWindow.MoveAndResize(new RectInt32(AppWindow.Position.X, above ? bottom - h : AppWindow.Position.Y, AppWindow.Size.Width, h));
        }
    }

    public void HideCard()
    {
        if (!_visible) return;
        _visible = false;
        AppWindow.Hide();
    }
}
