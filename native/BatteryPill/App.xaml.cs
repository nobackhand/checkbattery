using Microsoft.UI.Xaml;

namespace BatteryPill;

public partial class App : Application
{
    private PillWindow? _pill;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _pill = new PillWindow(Environment.GetCommandLineArgs());
        _pill.Activate();
    }
}
