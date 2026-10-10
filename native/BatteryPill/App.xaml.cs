using Microsoft.UI.Xaml;

namespace BatteryPill;

public partial class App : Application
{
    private PillWindow? _pill;
    private Mutex? _singleInstance;

    internal AppState State { get; } = new();

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        string[] argv = Environment.GetCommandLineArgs();
        bool measuring = Array.IndexOf(argv, "--measure") >= 0;
        // One pill per signed-in user (a measurement run is allowed alongside)
        if (!measuring)
        {
            _singleInstance = new Mutex(true, @"Local\BatteryPillNativeSingleInstance", out bool first);
            if (!first)
            {
                Exit();
                return;
            }
        }
        if (Environment.GetEnvironmentVariable("BATTERYPILL_ICON_DUMP") is { Length: > 0 } iconDir) TrayIcon.DumpIcons(iconDir);
        State.Load();
        Notifier.Init();
        _pill = new PillWindow(State, argv);
        // Shown without activation: launching must not take focus (Activate() would)
        _pill.ShowWithoutActivating();
    }
}
