namespace BatteryPill.Core;

/// <summary>The user's settings. Field names match BatteryWidget.config.json.</summary>
public sealed class AppConfig
{
    public static readonly string[] DisplayModes = { "time", "percent", "both", "power" };
    public static readonly string[] PillSizes = { "compact", "normal", "expanded" };
    public static readonly string[] Themes = { "dark", "light", "auto" };

    /// <summary>Pill position in physical pixels; -1/-1 = not placed yet.</summary>
    public int X { get; set; } = -1;
    public int Y { get; set; } = -1;
    public double Opacity { get; set; } = 0.85;
    public int RefreshInterval { get; set; } = 3000;
    public bool PositionLocked { get; set; }
    public string DisplayMode { get; set; } = "time";
    public string PillSize { get; set; } = "normal";
    public string Theme { get; set; } = "dark";
    public int AccentColorIndex { get; set; }
    public bool AutoHideFullscreen { get; set; }
    public bool FirstRunShown { get; set; }
    public bool FunLines { get; set; } = true;
    public bool Animations { get; set; } = true;
    public bool CheckForUpdates { get; set; } = true;
    /// <summary>The last SUCCESSFUL update check.</summary>
    public DateTime? LastUpdateCheck { get; set; }
    /// <summary>The release the "is out" card already announced (said once, not daily).</summary>
    public string? AnnouncedVersion { get; set; }

    /// <summary>Loaded only when the file was saved under 10 minutes ago; -1 otherwise.</summary>
    public double EmaRate { get; set; } = -1;
    public int LastValidRate { get; set; } = -1;
    /// <summary>Which power state the saved rate was measured in; null = unknown.</summary>
    public bool? EmaWasPluggedIn { get; set; }
    public List<HistorySample> BatteryHistory { get; set; } = new();
}
