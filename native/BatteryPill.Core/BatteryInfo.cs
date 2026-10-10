namespace BatteryPill.Core;

/// <summary>One interpreted battery reading: what every surface of the app shows.</summary>
public sealed class BatteryInfo
{
    /// <summary>Whole percent, or -1 when no source gave a reading.</summary>
    public int Percent { get; internal set; } = -1;
    public double PercentExact { get; internal set; } = -1;
    public bool IsCharging { get; internal set; }
    public bool IsPluggedIn { get; internal set; }
    public bool IsFullyCharged { get; internal set; }
    public bool NoBattery { get; internal set; }
    public string StatusText { get; internal set; } = "Unknown";
    /// <summary>Minutes remaining (to full while charging); -1 = no estimate.</summary>
    public int TimeMinutes { get; internal set; } = -1;
    public string TimeString { get; internal set; } = "Estimating...";
    public string TimeLabel { get; internal set; } = "Time Remaining:";
    public string PowerSource { get; internal set; } = "Unknown";
    public int DesignCapacity { get; internal set; } = -1;
    public int FullChargeCapacity { get; internal set; } = -1;
    public int DischargeRate { get; internal set; } = -1;
    public int ChargeRate { get; internal set; } = -1;
    public double BatteryWearPercent { get; internal set; } = -1;
    /// <summary>Local clock time the estimate lands at ("h:mm tt"), within 12 h; else empty.</summary>
    public string ETA { get; internal set; } = "";
    public int FullRuntimeMinutes { get; internal set; } = -1;
    public string ElapsedTime { get; internal set; } = "";
    /// <summary>Whole minutes in the current state (0 at a state change).</summary>
    public int ElapsedMinutes { get; internal set; }
    public string ElapsedSince { get; internal set; } = "";
    public PowerDrawReading PowerDraw { get; internal set; } = PowerDrawReading.None;
}
