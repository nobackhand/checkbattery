namespace BatteryPill.Core;

/// <summary>
/// Turns volatile battery rates into a steady "time remaining" / "time to full".
/// Port of src\030-estimation.ps1: adaptive EMA over the raw rate, a held rate
/// for brief dropouts, a capacity-derived cross-check while discharging, and
/// resets on every power-state change.
/// </summary>
public sealed class TimeEstimator
{
    public const double DefaultHysteresisSeconds = 2;

    /// <summary>Smoothed rate in mW; -1 = none yet.</summary>
    public double EmaRate { get; internal set; } = -1;
    public int LastValidRate { get; internal set; } = -1;
    public DateTime? LastValidRateTime { get; internal set; }
    public bool? LastAcState { get; internal set; }
    public bool? LastChargingState { get; internal set; }
    public DateTime? StateChangeTime { get; internal set; }
    public int CapacityRateMismatchCount { get; internal set; }
    public double HysteresisSeconds { get; set; } = DefaultHysteresisSeconds;

    internal readonly List<int> RateHistory = new();
    internal (DateTime Time, double Capacity)? LastCapacityCheck;

    /// <summary>
    /// Re-seed from a recently saved config so estimates are smooth right after a
    /// restart. The power state the rate was measured in is REQUIRED: a discharge
    /// rate is not a charge rate, and seeding LastAcState is what lets the AC
    /// transition reset fire on the first tick. Returns true if state was restored.
    /// </summary>
    public bool Restore(double emaRate, int lastValidRate, bool? wasPluggedIn, DateTime now)
    {
        if (emaRate <= 0) return false;
        // Unknown power state (a config written by an older build): refuse rather
        // than guess. One tick of "Estimating..." beats a confident wrong number.
        if (wasPluggedIn is null) return false;
        EmaRate = emaRate;
        LastValidRate = lastValidRate;
        LastValidRateTime = now;   // config is recent (< 10 min) by construction
        LastAcState = wasPluggedIn;
        return true;
    }

    /// <summary>
    /// Resume from sleep/hibernate: the pre-sleep rate means nothing now. Clear
    /// all rate state and open a hysteresis window for the post-wake spike.
    /// </summary>
    public void OnResume(DateTime now)
    {
        EmaRate = -1;
        LastValidRate = -1;
        LastValidRateTime = null;
        RateHistory.Clear();
        LastCapacityCheck = null;
        CapacityRateMismatchCount = 0;
        StateChangeTime = now;
    }

    internal int UpdateEma(int rawRate)
    {
        RateHistory.Add(rawRate);
        if (RateHistory.Count > 10) RateHistory.RemoveAt(0);

        // Adaptive alpha from the rate's coefficient of variation
        double alpha = 0.15;
        int count = RateHistory.Count;
        if (count >= 5)
        {
            double mean = 0;
            foreach (int r in RateHistory) mean += r;
            mean /= count;
            if (mean > 0)
            {
                double varSum = 0;
                foreach (int r in RateHistory) { double d = r - mean; varSum += d * d; }
                double cv = Math.Sqrt(varSum / count) / mean;
                if (cv < 0.10) alpha = 0.30;        // stable: respond faster
                else if (cv > 0.30) alpha = 0.08;   // volatile: dampen more
            }
        }

        EmaRate = EmaRate < 0 ? rawRate : (alpha * rawRate) + ((1 - alpha) * EmaRate);
        return (int)Math.Round(EmaRate, MidpointRounding.ToEven);
    }

    internal int CapacityDerivedRate(int fullChargeCapacity, double percentExact, DateTime now)
    {
        double currentCapacity = fullChargeCapacity * (percentExact / 100);
        if (LastCapacityCheck is null)
        {
            LastCapacityCheck = (now, currentCapacity);
            return -1;
        }

        double elapsedHours = (now - LastCapacityCheck.Value.Time).TotalHours;
        if (elapsedHours < 0)
        {
            // Wall clock jumped backward (DST/NTP): resync, or sampling deadlocks
            // until real time re-passes the old stamp
            LastCapacityCheck = (now, currentCapacity);
            return -1;
        }
        if (elapsedHours < 0.0083) return -1;   // need at least 30 seconds

        double capDelta = LastCapacityCheck.Value.Capacity - currentCapacity;   // mWh consumed
        // Measure across at least 5% of the pack: WMI reports a WHOLE percent, so
        // one 1% step over a short window reads as a huge rate (1% of 60 Wh in 30 s
        // = 72 W against a real 10 W). Across >= 5% the error is at most 20%,
        // under the 40% divergence the cross-check acts on. Below that, wait.
        if (capDelta > 0 && capDelta < fullChargeCapacity * 0.05) return -1;
        int derivedRate = (int)Math.Round(capDelta / elapsedHours, MidpointRounding.ToEven);   // mW

        LastCapacityCheck = (now, currentCapacity);
        return derivedRate > 0 ? derivedRate : -1;
    }

    /// <returns>Minutes remaining (or to full while charging); -1 = no estimate.</returns>
    public int SmoothedTimeRemaining(int rawRate, int fullChargeCapacity, double percentExact,
        bool isCharging, bool isPluggedIn, DateTime now)
    {
        // AC transition: start the hysteresis window and drop the held rate - a
        // discharge rate is not a charge rate
        if (LastAcState is bool ac && ac != isPluggedIn)
        {
            StateChangeTime = now;
            EmaRate = -1;
            LastValidRate = -1;
            LastValidRateTime = null;
        }
        LastAcState = isPluggedIn;

        // Charging can also stop with the cable still in (a firmware charge cap,
        // a full pack): the held CHARGE rate must not be read as the drain
        if (LastChargingState is bool wasCharging && wasCharging != isCharging)
        {
            EmaRate = -1;
            LastValidRate = -1;
            LastValidRateTime = null;
        }
        LastChargingState = isCharging;

        if (StateChangeTime is DateTime changed)
        {
            if ((now - changed).TotalSeconds < HysteresisSeconds) return -1;
            StateChangeTime = null;
        }

        int effectiveRate = -1;
        if (rawRate > 0)
        {
            effectiveRate = UpdateEma(rawRate);
            LastValidRate = rawRate;
            LastValidRateTime = now;
        }
        else if (LastValidRate > 0)
        {
            // Brief dropout: reuse the last valid rate while it is fresh (< 60 s)
            double age = LastValidRateTime is DateTime t ? (now - t).TotalSeconds : 999;
            if (age < 60) effectiveRate = UpdateEma(LastValidRate);
        }

        // Cross-validate with the capacity-derived rate (discharging only)
        if (effectiveRate > 0 && !isCharging && fullChargeCapacity > 0)
        {
            int derived = CapacityDerivedRate(fullChargeCapacity, percentExact, now);
            if (derived > 0)
            {
                double divergence = Math.Abs(effectiveRate - derived) / (double)Math.Max(effectiveRate, derived);
                if (divergence > 0.40)
                {
                    CapacityRateMismatchCount++;
                    // The reported rate consistently disagrees: prefer the measured one
                    if (CapacityRateMismatchCount >= 3) effectiveRate = UpdateEma(derived);
                }
                else
                {
                    CapacityRateMismatchCount = 0;
                }
            }
        }

        if (effectiveRate > 0 && fullChargeCapacity > 0 && percentExact > 0)
        {
            double remaining = isCharging
                ? fullChargeCapacity * ((100 - percentExact) / 100)
                : fullChargeCapacity * (percentExact / 100);
            // mWh / mW = hours
            return (int)Math.Round(remaining / effectiveRate * 60, MidpointRounding.ToEven);
        }
        return -1;
    }
}
