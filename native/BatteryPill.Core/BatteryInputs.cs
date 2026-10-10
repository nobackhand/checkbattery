namespace BatteryPill.Core;

/// <summary>
/// One raw WMI battery reading: Win32_Battery's first pack, with the rates and
/// any missing capacities filled from root\WMI (BatteryStatus,
/// BatteryFullChargedCapacity, BatteryStaticData). Values stay raw (object) on
/// purpose: firmware sends sentinels and nulls, and DeviceNumber validates them.
/// </summary>
public sealed record WmiBatterySnapshot
{
    public object? EstimatedChargeRemaining { get; init; }
    public object? BatteryStatus { get; init; }
    public object? DesignCapacity { get; init; }
    public object? FullChargeCapacity { get; init; }
    public object? EstimatedRunTime { get; init; }
    public object? TimeToFullCharge { get; init; }
    public object? DischargeRate { get; init; }
    public object? ChargeRate { get; init; }
}

/// <summary>
/// The OS's own view (GetSystemPowerStatus / SYSTEM_POWER_STATUS), raw.
/// </summary>
public sealed record SystemPowerSnapshot
{
    /// <summary>0 offline, 1 online, 255 unknown.</summary>
    public int AcLineStatus { get; init; } = 255;
    /// <summary>BatteryFlag bits: 1 high, 2 low, 4 critical, 8 charging, 128 no battery; 255 unknown.</summary>
    public object? BatteryFlag { get; init; }
    /// <summary>0-100, or 255 when unknown.</summary>
    public object? BatteryLifePercent { get; init; }
    /// <summary>Seconds remaining, or -1 when unknown (and always on AC).</summary>
    public object? BatteryLifeTime { get; init; }

    public bool IsOnline => AcLineStatus == 1;
}
