using BatteryPill.Core;
using Microsoft.Win32;

namespace BatteryPill;

/// <summary>
/// Everything the windows share: the settings, the battery engine, the history,
/// and their persistence. One instance per app.
/// </summary>
internal sealed class AppState
{
    public static string ConfigPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BatteryPill", "BatteryWidget.config.json");

    public AppConfig Config { get; private set; } = new();
    public BatteryHistory History { get; } = new();
    public BatteryInterpreter Interpreter { get; } = new();
    public BatteryQuery Query { get; } = new();
    public BatteryInfo Latest { get; private set; } = new();
    public string? LastIoError { get; private set; }

    public event Action<BatteryInfo>? Updated;
    public event Action? SettingsChanged;

    private bool _firstTick = true;

    public void Load()
    {
        // Start the first WMI read now, so it runs while the window is built
        Query.Poll(out _);
        var result = ConfigStore.Load(ConfigPath, DateTime.Now);
        Config = result.Config;
        LastIoError = result.Error;
        History.Load(Config.BatteryHistory);
        Interpreter.Estimator.Restore(Config.EmaRate, Config.LastValidRate, Config.EmaWasPluggedIn, DateTime.Now);
    }

    public void Save()
    {
        try
        {
            ConfigStore.Save(ConfigPath, Config, History.Samples, Interpreter.Estimator, DateTime.Now);
            LastIoError = null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            LastIoError = e.Message;
        }
    }

    /// <summary>One refresh. Never blocks for long: the WMI read runs on a pool thread.</summary>
    public BatteryInfo Tick()
    {
        WmiBatterySnapshot? snap;
        if (_firstTick)
        {
            // Launch: wait briefly (once) for the first full reading rather than
            // show a partial OS-only one and flip a tick later
            snap = Query.WaitFirst(TimeSpan.FromMilliseconds(400), out _);
            _firstTick = false;
        }
        else
        {
            snap = Query.Poll(out _);
        }
        var now = DateTime.Now;
        Latest = Interpreter.Interpret(snap, SystemPower.Read(), -1, now);
        History.Add(Latest, now);
        Updated?.Invoke(Latest);
        return Latest;
    }

    public void OnResume() => Interpreter.Estimator.OnResume(DateTime.Now);

    public void ChangeSettings(Action<AppConfig> change)
    {
        change(Config);
        Save();
        SettingsChanged?.Invoke();
    }

    /// <summary>Windows' "apps use light theme" switch.</summary>
    public static bool SystemUsesLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 1;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;   // default to dark
        }
    }

    public bool IsDark => Config.Theme switch
    {
        "light" => false,
        "auto" => !SystemUsesLightTheme(),
        _ => true,
    };
}
