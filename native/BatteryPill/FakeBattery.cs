using BatteryPill.Core;

namespace BatteryPill;

/// <summary>
/// BATTERYPILL_FAKE=&lt;scenario&gt; feeds the real interpreter synthetic firmware
/// readings and two hours of history, so every battery state can be rendered and
/// checked on a machine without a battery (the CI runner, a desktop). Unset in
/// normal use, and the real sources answer.
/// </summary>
internal static class FakeBattery
{
    public static readonly string? Scenario = Environment.GetEnvironmentVariable("BATTERYPILL_FAKE");

    public static bool Active => !string.IsNullOrEmpty(Scenario);

    // Laptop-like pack: 60 Wh design, 56 Wh now
    private const int Design = 60000, Full = 56000;

    public static (BatterySnapshot Wmi, SystemPowerSnapshot Power) Reading() => Scenario switch
    {
        "charging" => (Wmi(47, status: 2, charge: 38000), Power(online: true, flags: 9)),
        "low" => (Wmi(9, status: 1, discharge: 9400), Power(online: false, flags: 2)),
        "full" => (Wmi(100, status: 2), Power(online: true, flags: 1)),
        "capped" => (Wmi(80, status: 2), Power(online: true, flags: 1)),
        _ => (Wmi(64, status: 1, discharge: 11200), Power(online: false, flags: 1)),
    };

    private static BatterySnapshot Wmi(int pct, int status, int? discharge = null, int? charge = null) => new()
    {
        EstimatedChargeRemaining = (ushort)pct,
        BatteryStatus = (ushort)status,
        DesignCapacity = (uint)Design,
        FullChargeCapacity = (uint)Full,
        EstimatedRunTime = 71582788u,
        DischargeRate = discharge,
        ChargeRate = charge,
    };

    private static SystemPowerSnapshot Power(bool online, int flags) =>
        new() { AcLineStatus = online ? 1 : 0, BatteryFlag = flags, BatteryLifePercent = -1, BatteryLifeTime = -1 };

    /// <summary>Two hours at 3 s: a gentle discharge with a varying draw, shaped per scenario.</summary>
    public static IEnumerable<HistorySample> History(DateTime now)
    {
        const int n = 2400;
        var rnd = new Random(7);
        for (int i = 0; i < n; i++)
        {
            var t = now.AddSeconds(-3 * (n - i));
            double f = i / (double)n;
            (int pct, bool charging, bool plugged) = Scenario switch
            {
                // Discharged for 90 minutes, then on the charger
                "charging" => f < 0.75 ? ((int)(70 - 30 * f / 0.75), false, false) : ((int)(40 + 7 * (f - 0.75) / 0.25), true, true),
                "low" => ((int)(38 - 29 * f), false, false),
                "full" or "capped" => f < 0.6 ? ((int)(60 + 40 * f / 0.6), true, true) : (Scenario == "full" ? 100 : 80, false, true),
                _ => ((int)(95 - 31 * f), false, false),
            };
            double watts = charging || plugged ? -1 : 8 + 6 * Math.Sin(i / 90.0) + rnd.NextDouble() * 3;
            yield return new HistorySample(t, Math.Clamp(pct, 0, 100), charging, plugged, Math.Round(watts, 1));
        }
    }
}
