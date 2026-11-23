using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of tests\Estimation.Tests.ps1. Each case there was confirmed to fail
// against a deliberate mutation of the code it covers.
public class EstimationTests
{
    private static readonly DateTime T0 = new(2026, 7, 29, 9, 0, 0);

    private static int Est(TimeEstimator e, int rate, double pct, bool charging, bool plugged, DateTime now, int full = 50000) =>
        e.SmoothedTimeRemaining(rate, full, pct, charging, plugged, now);

    // ---- charging stops while plugged in ----

    [Fact]
    public void ChargingStoppingAtACapDropsTheChargeRate()
    {
        var e = new TimeEstimator();
        for (int k = 0; k < 5; k++) Est(e, 25000, 79, true, true, T0.AddSeconds(3 * k), 60000);
        Assert.Equal(-1, Est(e, 0, 80, false, true, T0.AddSeconds(15), 60000));
    }

    [Fact]
    public void ChargingResumingAtTheCapDoesNotUseAnOldDrainRate()
    {
        var e = new TimeEstimator();
        Est(e, 9000, 78, false, true, T0, 60000);
        Assert.Equal(-1, Est(e, 0, 78, true, true, T0.AddSeconds(3), 60000));
    }

    // ---- EMA ----

    [Fact]
    public void EmaSeedsFromTheFirstReading() => Assert.Equal(12000, new TimeEstimator().UpdateEma(12000));

    [Fact]
    public void EmaSmoothsAJump()
    {
        var e = new TimeEstimator();
        e.UpdateEma(10000);
        Assert.Equal(11500, e.UpdateEma(20000));   // 0.15*20000 + 0.85*10000
    }

    [Fact]
    public void EmaKeepsOnlyTheLastTenRawRates()
    {
        var e = new TimeEstimator();
        for (int i = 1; i <= 12; i++) e.UpdateEma(i * 1000);
        Assert.Equal(10, e.RateHistory.Count);
        Assert.Equal(3000, e.RateHistory[0]);
        Assert.Equal(12000, e.RateHistory[9]);
    }

    [Fact]
    public void EmaSpeedsUpWhenTheRateIsStable()
    {
        var e = new TimeEstimator();
        for (int i = 0; i < 5; i++) e.UpdateEma(10000);
        Assert.Equal(10150, e.UpdateEma(10500));   // alpha 0.30
    }

    [Fact]
    public void EmaDampensHarderWhenTheRateIsVolatile()
    {
        var e = new TimeEstimator();
        for (int i = 0; i < 5; i++) e.UpdateEma(10000);
        Assert.Equal(10800, e.UpdateEma(20000));   // alpha 0.08
    }

    [Fact]
    public void EmaDoesNotReadANonsensicalWindowAsSteady()
    {
        var e = new TimeEstimator();
        for (int i = 0; i < 4; i++) e.UpdateEma(0);
        Assert.Equal(0, e.UpdateEma(0));

        e = new TimeEstimator();
        for (int i = 0; i < 4; i++) e.UpdateEma(100000);
        // Default alpha: an unguarded cv (negative) would pass as "stable" and give -110000
        Assert.Equal(-5000, e.UpdateEma(-600000));
    }

    [Fact]
    public void EmaReturnsWholeMilliwattsButKeepsFullPrecision()
    {
        var e = new TimeEstimator();
        e.UpdateEma(10000);
        Assert.Equal(10001, e.UpdateEma(10005));
        Assert.Equal(10000.75, e.EmaRate, 6);
    }

    // ---- capacity-derived rate ----

    [Fact]
    public void CapacityRateHasNothingOnTheFirstSample() =>
        Assert.Equal(-1, new TimeEstimator().CapacityDerivedRate(50000, 50, T0));

    [Fact]
    public void CapacityRateRefusesUnderThirtySeconds()
    {
        var e = new TimeEstimator();
        e.CapacityDerivedRate(50000, 50, T0);
        Assert.Equal(-1, e.CapacityDerivedRate(50000, 49, T0.AddSeconds(20)));
    }

    [Fact]
    public void CapacityRateResyncsWhenTheClockJumpsBackward()
    {
        var e = new TimeEstimator();
        e.CapacityDerivedRate(50000, 50, T0);
        var back = T0.AddSeconds(-60);
        Assert.Equal(-1, e.CapacityDerivedRate(50000, 50, back));
        Assert.Equal(back, e.LastCapacityCheck!.Value.Time);
    }

    [Fact]
    public void CapacityRateMeasuresMilliwattsFromTheDrop()
    {
        var e = new TimeEstimator();
        e.CapacityDerivedRate(50000, 50, T0);
        Assert.Equal(10000, e.CapacityDerivedRate(50000, 30, T0.AddHours(1)));
    }

    [Fact]
    public void CapacityRateAdvancesItsSample()
    {
        var e = new TimeEstimator();
        e.CapacityDerivedRate(50000, 50, T0);
        e.CapacityDerivedRate(50000, 30, T0.AddHours(1));
        Assert.Equal(5000, e.CapacityDerivedRate(50000, 20, T0.AddHours(2)));
    }

    [Fact]
    public void CapacityRateReportsNothingWhileCapacityRises()
    {
        var e = new TimeEstimator();
        e.CapacityDerivedRate(50000, 30, T0);
        Assert.Equal(-1, e.CapacityDerivedRate(50000, 50, T0.AddHours(1)));
    }

    [Fact]
    public void ASteadyRealDrainWithWholePercentReadingsGivesASteadyEstimate()
    {
        var e = new TimeEstimator();
        const double full = 60000, rate = 10000, start = 0.80 * full;
        int bad = 0;
        double worst = 0;
        for (int i = 0; i < 1200; i++)
        {
            var now = T0.AddSeconds(3 * i);
            double left = start - rate * (3 * i / 3600.0);
            double pct = Math.Floor(left / full * 100);
            int est = e.SmoothedTimeRemaining((int)rate, (int)full, pct, false, false, now);
            if (i < 20) continue;   // first minute: settling
            double truth = left / rate * 60.0;
            double err = Math.Abs(est - truth);
            if (err > Math.Max(0.10 * truth, 5)) bad++;
            worst = Math.Max(worst, err / truth);
        }
        Assert.True(bad == 0, $"{bad} of 1180 ticks off by more than 10% (worst {worst:P0})");
    }

    // ---- smoothed time remaining ----

    [Fact]
    public void ComputesTimeRemainingFromTheSmoothedRate() =>
        Assert.Equal(150, Est(new TimeEstimator(), 10000, 50, false, false, T0));

    [Fact]
    public void HoldsTheLastValidRateThroughADropout()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Assert.Equal(150, Est(e, 0, 50, false, false, T0.AddSeconds(3)));
    }

    [Fact]
    public void SuppressesTheEstimateDuringPostPlugHysteresis()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Assert.Equal(-1, Est(e, 0, 50, true, true, T0.AddSeconds(1)));
    }

    [Fact]
    public void RestartOnAChargerDoesNotInheritTheDischargeRate()
    {
        var e = new TimeEstimator();
        e.Restore(15000, 15000, wasPluggedIn: false, T0);
        Est(e, 0, 50, true, true, T0);
        Assert.Equal(-1, Est(e, 0, 50, true, true, T0.AddSeconds(5)));
    }

    [Fact]
    public void AConfigWithNoSavedPowerStateIsNotRestored()
    {
        var e = new TimeEstimator();
        Assert.False(e.Restore(15000, 15000, wasPluggedIn: null, T0));
        Assert.Equal(-1, e.EmaRate);
        Assert.Null(e.LastAcState);
    }

    [Fact]
    public void ASavedStateWithNoRateRestoresNothing()
    {
        var e = new TimeEstimator();
        Assert.False(e.Restore(-1, -1, wasPluggedIn: false, T0));
        Assert.Equal(-1, e.EmaRate);
    }

    [Fact]
    public void AValidSavedStateIsRestoredFieldByField()
    {
        var e = new TimeEstimator();
        Assert.True(e.Restore(12345, 12000, wasPluggedIn: true, T0));
        Assert.Equal(12345, e.EmaRate);
        Assert.Equal(12000, e.LastValidRate);
        Assert.True(e.LastAcState);
        Assert.Equal(T0, e.LastValidRateTime);
    }

    [Fact]
    public void TheRestoredRateProducesARealEstimate()
    {
        var e = new TimeEstimator();
        Assert.True(e.Restore(15000, 15000, wasPluggedIn: false, T0));
        Assert.Equal(100, Est(e, 0, 50, false, false, T0));
    }

    [Fact]
    public void ARestoredRateIsNotReusedAcrossAPowerStateChange()
    {
        var e = new TimeEstimator { EmaRate = 15000, LastValidRate = 15000, LastValidRateTime = T0, LastAcState = false };
        Est(e, 0, 50, true, true, T0);
        Assert.Equal(-1, Est(e, 0, 50, true, true, T0.AddSeconds(5)));
    }

    [Fact]
    public void ARestoredRateIsReusedWhenThePowerStateMatches()
    {
        var e = new TimeEstimator { EmaRate = 15000, LastValidRate = 15000, LastValidRateTime = T0, LastAcState = false };
        Assert.True(Est(e, 0, 50, false, false, T0) > 0);
    }

    [Fact]
    public void DoesNotReuseThePreUnplugDischargeRateAsAChargeRate()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Est(e, 0, 50, true, true, T0.AddSeconds(1));
        Assert.Equal(-1, Est(e, 0, 50, true, true, T0.AddSeconds(6)));
    }

    [Fact]
    public void UsesTheRealChargeRateOnceTheChargerReportsOne()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Est(e, 0, 50, true, true, T0.AddSeconds(1));
        Assert.Equal(60, Est(e, 25000, 50, true, true, T0.AddSeconds(6)));
    }

    [Fact]
    public void UnpluggingDoesNotReuseTheChargeRate()
    {
        var e = new TimeEstimator();
        Est(e, 25000, 50, true, true, T0);
        Est(e, 0, 50, false, false, T0.AddSeconds(1));
        Assert.Equal(-1, Est(e, 0, 50, false, false, T0.AddSeconds(6)));
    }

    [Fact]
    public void DropsAHeldRateOlderThanSixtySeconds()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Assert.Equal(-1, Est(e, 0, 50, false, false, T0.AddSeconds(120)));
    }

    [Fact]
    public void StillHoldsARateJustInsideTheFreshnessWindow()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Assert.Equal(150, Est(e, 0, 50, false, false, T0.AddSeconds(59)));
    }

    [Fact]
    public void InventsNothingOnAColdStart() => Assert.Equal(-1, Est(new TimeEstimator(), 0, 50, false, false, T0));

    [Fact]
    public void NoEstimateWhenThePackCapacityIsUnknown() =>
        Assert.Equal(-1, Est(new TimeEstimator(), 10000, 50, false, false, T0, full: 0));

    [Fact]
    public void NoEstimateAtZeroPercent() => Assert.Equal(-1, Est(new TimeEstimator(), 10000, 0, false, false, T0));

    [Fact]
    public void ChargingAtFullIsZeroMinutesToFull() => Assert.Equal(0, Est(new TimeEstimator(), 20000, 100, true, true, T0));

    [Fact]
    public void PrefersTheCapacityDerivedRateAfterThreeDivergentSamples()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Est(e, 10000, 40, false, false, T0.AddHours(1));
        Est(e, 10000, 30, false, false, T0.AddHours(2));
        Assert.Equal(2, e.CapacityRateMismatchCount);
        Assert.Equal(65, Est(e, 10000, 20, false, false, T0.AddHours(3)));
    }

    [Fact]
    public void ASingleDivergentSampleDoesNotStick()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        Est(e, 10000, 40, false, false, T0.AddHours(1));
        Assert.Equal(1, e.CapacityRateMismatchCount);
        Assert.Equal(60, Est(e, 10000, 20, false, false, T0.AddHours(2)));
        Assert.Equal(0, e.CapacityRateMismatchCount);
    }

    [Fact]
    public void ResumeFromSleepClearsRatesAndOpensHysteresis()
    {
        var e = new TimeEstimator();
        Est(e, 10000, 50, false, false, T0);
        e.OnResume(T0.AddMinutes(30));
        Assert.Equal(-1, e.EmaRate);
        Assert.Empty(e.RateHistory);
        Assert.Equal(-1, Est(e, 10000, 49, false, false, T0.AddMinutes(30).AddSeconds(1)));
        Assert.Equal(147, Est(e, 10000, 49, false, false, T0.AddMinutes(30).AddSeconds(3)));
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void ADamagedSavedRateIsNotRestored(double rate)
    {
        var e = new TimeEstimator();
        Assert.False(e.Restore(rate, 15000, wasPluggedIn: false, T0));
        Assert.True(e.EmaRate <= 0);
    }
}
