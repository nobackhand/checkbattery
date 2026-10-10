using BatteryPill.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Color = Windows.UI.Color;

namespace BatteryPill;

/// <summary>
/// Settings, Windows 11 style: Mica, grouped cards, changes apply at once. A
/// normal window (taskbar, Alt+Tab) - unlike the pill, this one is meant to
/// take focus.
/// </summary>
public sealed partial class SettingsWindow : Window
{
    private readonly AppState _app;
    private readonly UpdateService _updates;
    private bool _loading;

    internal SettingsWindow(AppState app, UpdateService updates)
    {
        _app = app;
        _updates = updates;
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "BatteryPill.ico"));

        double scale = Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        int w = (int)(760 * scale), h = (int)(860 * scale);
        var area = DisplayArea.Primary.WorkArea;
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - w) / 2, area.Y + Math.Max(0, (area.Height - h) / 2), w, Math.Min(h, area.Height)));

        BuildSwatches();
        Load();
        Hook();
        _app.SettingsChanged += OnExternalChange;
        _updates.StateChanged += ShowUpdateState;
        Closed += (_, _) =>
        {
            _app.SettingsChanged -= OnExternalChange;
            _updates.StateChanged -= ShowUpdateState;
        };
        ShowUpdateState();
    }

    private void OnExternalChange() => DispatcherQueue.TryEnqueue(Load);

    private static void Select(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
            if ((string)item.Tag == tag) { box.SelectedItem = item; return; }
    }

    private static string? Tag(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag as string;

    private void Load()
    {
        _loading = true;
        var c = _app.Config;
        Root.RequestedTheme = _app.IsDark ? ElementTheme.Dark : ElementTheme.Light;
        Select(ThemeBox, c.Theme);
        Select(ModeBox, c.DisplayMode);
        Select(SizeBox, c.PillSize);
        Select(RefreshBox, c.RefreshInterval.ToString());
        OpacitySlider.Value = Math.Round(c.Opacity * 100);
        LockToggle.IsOn = c.PositionLocked;
        FullscreenToggle.IsOn = c.AutoHideFullscreen;
        AnimationsToggle.IsOn = c.Animations;
        FunToggle.IsOn = c.FunLines;
        UpdatesToggle.IsOn = c.CheckForUpdates;
        AutoStartToggle.IsOn = AutoStart.IsEnabledForThisApp();
        AutoStartText.Text = AutoStart.Describe();
        UpdateSwatchRings();
        _loading = false;
    }

    private void Hook()
    {
        ThemeBox.SelectionChanged += (_, _) => Change(c => c.Theme = Tag(ThemeBox) ?? c.Theme);
        ModeBox.SelectionChanged += (_, _) => Change(c => c.DisplayMode = Tag(ModeBox) ?? c.DisplayMode);
        SizeBox.SelectionChanged += (_, _) => Change(c => c.PillSize = Tag(SizeBox) ?? c.PillSize);
        RefreshBox.SelectionChanged += (_, _) => Change(c => c.RefreshInterval = int.TryParse(Tag(RefreshBox), out int ms) ? ms : c.RefreshInterval);
        OpacitySlider.ValueChanged += (_, e) => Change(c => c.Opacity = Math.Clamp(e.NewValue / 100.0, 0.3, 1.0));
        LockToggle.Toggled += (_, _) => Change(c => c.PositionLocked = LockToggle.IsOn);
        FullscreenToggle.Toggled += (_, _) => Change(c => c.AutoHideFullscreen = FullscreenToggle.IsOn);
        AnimationsToggle.Toggled += (_, _) => Change(c => c.Animations = AnimationsToggle.IsOn);
        FunToggle.Toggled += (_, _) => Change(c => c.FunLines = FunToggle.IsOn);
        UpdatesToggle.Toggled += (_, _) => Change(c => c.CheckForUpdates = UpdatesToggle.IsOn);
        AutoStartToggle.Toggled += (_, _) =>
        {
            if (_loading) return;
            if (!AutoStart.Set(AutoStartToggle.IsOn))
            {
                _loading = true;
                AutoStartToggle.IsOn = AutoStart.IsEnabledForThisApp();
                _loading = false;
                Notifier.Show("Couldn't change start with Windows", "Windows blocked the Startup shortcut");
            }
            AutoStartText.Text = AutoStart.Describe();
        };
        CheckNowButton.Click += async (_, _) => await _updates.CheckAsync(force: true);
        GetUpdateButton.Click += (_, _) => _updates.OpenAvailable();
    }

    private void Change(Action<AppConfig> change)
    {
        if (_loading) return;
        _app.ChangeSettings(change);
        Root.RequestedTheme = _app.IsDark ? ElementTheme.Dark : ElementTheme.Light;
    }

    private void BuildSwatches()
    {
        string[] names = { "Green", "Blue", "Purple", "Cyan", "Pink", "Teal", "Orange", "White" };
        for (int i = 0; i < Presentation.AccentPresets.Length; i++)
        {
            var c = Presentation.AccentPresets[i];
            int index = i;
            var swatch = new Button
            {
                Width = 30,
                Height = 30,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(15),
                Background = new SolidColorBrush(Color.FromArgb(255, c.R, c.G, c.B)),
                BorderThickness = new Thickness(2),
                Tag = i,
            };
            ToolTipService.SetToolTip(swatch, names[i]);
            swatch.Click += (_, _) => { Change(cfg => cfg.AccentColorIndex = index); UpdateSwatchRings(); };
            Swatches.Children.Add(swatch);
        }
    }

    private void UpdateSwatchRings()
    {
        foreach (var b in Swatches.Children.OfType<Button>())
        {
            bool selected = (int)b.Tag == _app.Config.AccentColorIndex;
            b.BorderBrush = selected
                ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"]
                : new SolidColorBrush(Colors.Transparent);
        }
    }

    private void ShowUpdateState()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            VersionText.Text = UpdateCheck.AboutVersionText(AppInfo.Version, _updates.State, _updates.Available)
                + (_updates.State == UpdateState.Checking ? " - checking..." : "");
            GetUpdateButton.Visibility = _updates.Available is null ? Visibility.Collapsed : Visibility.Visible;
            CheckNowButton.IsEnabled = _updates.State != UpdateState.Checking;
        });
    }
}
