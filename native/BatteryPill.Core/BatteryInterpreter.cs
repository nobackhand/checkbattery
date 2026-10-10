using System.Globalization;

namespace BatteryPill.Core;

/// <summary>
/// Turns one raw reading (WMI + the OS power status + the platform meter) into a
/// <see cref="BatteryInfo"/>. Port of Get-BatteryInfo (src\020-battery-info.ps1).
/// Pure apart from the estimator and elapsed-time state it carries between
/// ticks, so every firmware oddity is testable without a laptop.
/// </summary>
public sealed class BatteryInterpreter
{
    /// <summary>EstimatedRunTime's documented "unknown" value (0xFFFFFFFF / 60).</summary>
    public const int UnknownRunTime = 71582788;

    private (DateTime Time, double Percent, string State)? _lastStateChange;

    public TimeEstimator Estimator { get; } = new();

    /// <summary>Culture for the ETA clock time. Defaults to the user's.</summary>
    public CultureInfo Culture { get; set; } = CultureInfo.CurrentCulture;

    /// <param name="now">LOCAL time: the ETA is shown as a wall-clock time.</param>
    public BatteryInfo Interpret(BatterySnapshot? wmi, SystemPowerSnapshot? power, double meterMilliwatts, DateTime now)
    {
        var info = new BatteryInfo();
        double? chargeFlags = power is null ? null : DeviceNumber.Read(power.BatteryFlag, 0, 255);

        // No battery: WMI has no pack and the OS has nothing or says "no system battery"
        if (wmi is null && (power is null || (chargeFlags is double f && ((int)f & 128) == 128)))
        {
            info.NoBattery = true;
            info.StatusText = "No Battery";
            info.TimeString = "N/A";
            info.PowerSource = "AC Power";
            // A desktop with a platform meter can still say what it is using
            info.PowerDraw = PowerDrawReading.From(meterMilliwatts, noBattery: true);
            return info;
        }

        // Charge percentage. A null or 255 is "no reading", never a false 0%
        // that paints the pill red and fires the 5% alarm.
        double? wmiPct = wmi is null ? null : DeviceNumber.Read(wmi.EstimatedChargeRemaining, 0, 100);
        if (wmiPct is double p)
        {
            info.PercentExact = p;
            info.Percent = RoundInt(p);
        }
        else if (power is not null && DeviceNumber.Read(power.BatteryLifePercent, 0, 100) is double osPct)
        {
            info.PercentExact = Math.Round(osPct, 1);
            info.Percent = RoundInt(osPct);
        }

        // Charging state from WMI. 2 is only "on AC" - Microsoft: "the battery is
        // not necessarily charging". A firmware charge cap holds there for hours.
        if (wmi is not null)
        {
            double? status = DeviceNumber.Read(wmi.BatteryStatus, 1, 11);
            int s = status is double v ? (int)v : 0;
            info.IsCharging = s is 6 or 7 or 8 or 9;
            info.IsPluggedIn = s is 2 or 3 or 6 or 7 or 8 or 9 or 11;
            info.IsFullyCharged = s == 3;
        }

        // The OS cross-check. 255 is BatteryFlag "unknown": every bit set,
        // Charging included, so it must not count as charging.
        if (power is not null)
        {
            if (power.IsOnline) info.IsPluggedIn = true;
            if (chargeFlags is double cf && (int)cf != 255 && ((int)cf & 8) == 8) info.IsCharging = true;
        }

        if (info.Percent >= 100 && info.IsPluggedIn)
        {
            info.IsFullyCharged = true;
            info.IsCharging = false;
        }

        // Extended data. Min 1: a zero capacity or rate is "no reading".
        if (wmi is not null)
        {
            if (DeviceNumber.Read(wmi.DesignCapacity, 1) is double dc) info.DesignCapacity = RoundInt(dc);
            if (DeviceNumber.Read(wmi.FullChargeCapacity, 1) is double fc) info.FullChargeCapacity = RoundInt(fc);
            if (DeviceNumber.Read(wmi.DischargeRate, 1) is double dr) info.DischargeRate = RoundInt(dr);
            if (DeviceNumber.Read(wmi.ChargeRate, 1) is double cr) info.ChargeRate = RoundInt(cr);
            if (DeviceNumber.Read(wmi.EstimatedRunTime, 1) is double rt && rt != UnknownRunTime) info.FullRuntimeMinutes = RoundInt(rt);
        }

        if (info.DesignCapacity > 0 && info.FullChargeCapacity > 0)
        {
            double wear = Math.Round((info.DesignCapacity - info.FullChargeCapacity) / (double)info.DesignCapacity * 100, 1, MidpointRounding.ToEven);
            info.BatteryWearPercent = Math.Max(0, wear);
        }

        info.PowerDraw = PowerDrawReading.From(meterMilliwatts, info.DischargeRate, info.ChargeRate,
            info.IsCharging, info.IsFullyCharged, noBattery: false);

        // Time remaining: smoothed estimate first, then the firmware's own figures
        int minutes = -1;
        if (!info.IsFullyCharged)
        {
            int rawRate = info.IsCharging ? info.ChargeRate : info.DischargeRate;
            minutes = Estimator.SmoothedTimeRemaining(rawRate, info.FullChargeCapacity, info.PercentExact,
                info.IsCharging, info.IsPluggedIn, now);
            if (minutes <= 0)
            {
                if (!info.IsCharging)
                {
                    double? run = wmi is null ? null : DeviceNumber.Read(wmi.EstimatedRunTime, 1);
                    double? osSeconds = power is null ? null : DeviceNumber.Read(power.BatteryLifeTime, 1);
                    if (run is double r && r != UnknownRunTime) minutes = RoundInt(r);
                    else if (osSeconds is double secs) minutes = RoundInt(secs / 60);
                }
                else if (wmi is not null && DeviceNumber.Read(wmi.TimeToFullCharge, 1) is double toFull)
                {
                    minutes = RoundInt(toFull);
                }
            }
        }
        // A tiny or glitchy rate can compute absurd estimates (562 h). Nothing
        // with a battery runs 100 h+: treat it as "no estimate yet".
        if (minutes > 5999) minutes = -1;
        info.TimeMinutes = minutes;
        info.TimeString = minutes > 0 ? LongDuration(minutes) : "Estimating...";

        // ETA only within 12 h: "ETA 2:56 PM" on a 27 h estimate reads as today
        if (minutes > 0 && minutes <= 720) info.ETA = now.AddMinutes(minutes).ToString("h:mm tt", Culture);

        // Status. The >= 0 guards matter: -1 means NO reading, and "-1 <= 10"
        // would report an unreadable battery as Critical.
        if (info.IsFullyCharged) info.StatusText = "Fully Charged";
        else if (info.IsCharging) info.StatusText = "Charging";
        // Plugged in and HOLDING (a charge cap). The DischargeRate test keeps an
        // underpowered charger that is still draining on the Low/Critical path.
        else if (info.IsPluggedIn && info.DischargeRate <= 0) info.StatusText = "Plugged In";
        else if (info.Percent >= 0 && info.Percent <= 10) info.StatusText = "Critical";
        else if (info.Percent >= 0 && info.Percent <= 20) info.StatusText = "Low";
        else info.StatusText = "Discharging";

        info.PowerSource = info.IsPluggedIn ? "AC Power (plugged in)" : "Battery (unplugged)";
        info.TimeLabel = info.IsCharging ? "Time to Full:" : "Time Remaining:";
        if (info.IsFullyCharged) info.TimeString = "N/A (plugged in)";

        // Elapsed time in the current state. A backward clock jump resyncs the
        // anchor instead of rendering "-1:-24".
        if (_lastStateChange is null || _lastStateChange.Value.State != info.StatusText || now < _lastStateChange.Value.Time)
            _lastStateChange = (now, info.PercentExact, info.StatusText);
        TimeSpan elapsed = now - _lastStateChange.Value.Time;
        info.ElapsedTime = string.Format(CultureInfo.InvariantCulture, "{0}:{1:D2}", (int)Math.Floor(elapsed.TotalHours), elapsed.Minutes);
        info.ElapsedSince = _lastStateChange.Value.Percent.ToString(CultureInfo.InvariantCulture) + "%";
        info.ElapsedMinutes = (int)Math.Floor(elapsed.TotalMinutes);

        return info;
    }

    /// <summary>"3 hours 8 minutes", "1 hour", "42 minutes".</summary>
    public static string LongDuration(int minutes)
    {
        int h = minutes / 60, m = minutes % 60;
        string hours = h != 1 ? "hours" : "hour", mins = m != 1 ? "minutes" : "minute";
        if (h > 0 && m > 0) return $"{h} {hours} {m} {mins}";
        if (h > 0) return $"{h} {hours}";
        return $"{m} {mins}";
    }

    /// <summary>PowerShell's [int] cast: banker's rounding.</summary>
    public static int RoundInt(double v) => (int)Math.Round(v, MidpointRounding.ToEven);
}
