namespace BatteryPill.Core;

public enum PowerDrawKind
{
    None,
    /// <summary>Power the machine is consuming.</summary>
    Draw,
    /// <summary>Power flowing INTO the pack while charging. Not consumption.</summary>
    Charge,
}

public enum PowerDrawSource { None, Meter, Battery }

/// <param name="Watts">The reading, or -1 when nothing reported one.</param>
public readonly record struct PowerDrawReading(double Watts, PowerDrawKind Kind, PowerDrawSource Source)
{
    public static readonly PowerDrawReading None = new(-1, PowerDrawKind.None, PowerDrawSource.None);

    /// <summary>
    /// The source ladder. The platform meter wins whenever it reports: it measures
    /// the whole machine, on AC or battery. Otherwise the pack: while draining,
    /// DischargeRate IS the system draw. Plugged in and not charging there is no
    /// number (the pack is idle, the wall is unmetered), and every caller treats
    /// None as "say nothing". A laptop pack does not move 300 W: anything above
    /// is a firmware glitch, dropped rather than displayed.
    /// </summary>
    public static PowerDrawReading From(double meterMilliwatts = -1, int dischargeRate = -1, int chargeRate = -1,
        bool isCharging = false, bool isFullyCharged = false, bool noBattery = false)
    {
        if (meterMilliwatts > 0 && meterMilliwatts <= 5_000_000)
            return new(Math.Round(meterMilliwatts / 1000.0, 1, MidpointRounding.ToEven), PowerDrawKind.Draw, PowerDrawSource.Meter);
        if (noBattery || isFullyCharged) return None;
        if (isCharging)
        {
            return chargeRate > 0 && chargeRate <= 300_000
                ? new(Math.Round(chargeRate / 1000.0, 1, MidpointRounding.ToEven), PowerDrawKind.Charge, PowerDrawSource.Battery)
                : None;
        }
        return dischargeRate > 0 && dischargeRate <= 300_000
            ? new(Math.Round(dischargeRate / 1000.0, 1, MidpointRounding.ToEven), PowerDrawKind.Draw, PowerDrawSource.Battery)
            : None;
    }
}
