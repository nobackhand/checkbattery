using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of tests\PowerDraw.Tests.ps1: the source ladder, draw stats, history
// recording and the end-to-end reading. (Its text/pill-wording cases move with
// the presentation code in M2.)
public class PowerDrawTests
{
    private static readonly DateTime T0 = new(2026, 9, 4, 10, 0, 0);

    // ---- the source ladder ----

    [Fact]
    public void OnBatteryTheDischargeRateIsTheSystemDraw()
    {
        var d = PowerDrawReading.From(dischargeRate: 8241);
        Assert.Equal(8.2, d.Watts);
        Assert.Equal(PowerDrawKind.Draw, d.Kind);
        Assert.Equal(PowerDrawSource.Battery, d.Source);
    }

    [Fact]
    public void ThePlatformMeterOutranksThePackRate()
    {
        var d = PowerDrawReading.From(meterMilliwatts: 14200, dischargeRate: 8241);
        Assert.Equal(14.2, d.Watts);
        Assert.Equal(PowerDrawSource.Meter, d.Source);
    }

    [Fact]
    public void AMeterReadingOfZeroIsNoReading()
    {
        var d = PowerDrawReading.From(meterMilliwatts: 0, dischargeRate: 8241);
        Assert.Equal(8.2, d.Watts);
        Assert.Equal(PowerDrawSource.Battery, d.Source);
    }

    [Fact]
    public void WhileChargingTheChargeRateIsChargeNeverDraw()
    {
        var d = PowerDrawReading.From(chargeRate: 24680, isCharging: true);
        Assert.Equal(24.7, d.Watts);
        Assert.Equal(PowerDrawKind.Charge, d.Kind);
    }

    [Fact]
    public void ChargingWithNoChargeRateIsNoReading()
    {
        var d = PowerDrawReading.From(chargeRate: -1, dischargeRate: 8241, isCharging: true);
        Assert.Equal(-1, d.Watts);
        Assert.Equal(PowerDrawKind.None, d.Kind);
    }

    [Fact]
    public void FullyChargedIsNoReadingEvenWithARate() =>
        Assert.Equal(PowerDrawKind.None, PowerDrawReading.From(dischargeRate: 500, isFullyCharged: true).Kind);

    [Fact]
    public void NoBatteryAndNoMeterIsNoReading() =>
        Assert.Equal(PowerDrawKind.None, PowerDrawReading.From(noBattery: true).Kind);

    [Fact]
    public void ADesktopWithAPlatformMeterStillReports()
    {
        var d = PowerDrawReading.From(meterMilliwatts: 65000, noBattery: true);
        Assert.Equal(65.0, d.Watts);
        Assert.Equal(PowerDrawSource.Meter, d.Source);
    }

    [Fact]
    public void A400WattDischargeIsAGlitch() =>
        Assert.Equal(PowerDrawKind.None, PowerDrawReading.From(dischargeRate: 400000).Kind);

    [Fact]
    public void PluggedInAndHoldingIsNoReading() =>
        Assert.Equal(PowerDrawKind.None, PowerDrawReading.From(dischargeRate: -1, chargeRate: -1).Kind);

    // ---- draw stats ----

    private static List<HistorySample> History(params (double Watts, bool Charging, bool Plugged)[] samples) =>
        samples.Select((s, i) => new HistorySample(T0.AddSeconds(3 * i), 70 - i, s.Charging, s.Plugged, s.Watts)).ToList();

    private static (double, bool, bool) W(double watts, bool charging = false, bool plugged = false) => (watts, charging, plugged);

    [Fact]
    public void StatsAvgAndPeakOverTheRun()
    {
        var s = BatteryHistory.PowerDrawStats(History(W(10), W(20), W(12), W(14)));
        Assert.Equal(4, s.Samples);
        Assert.Equal(14.0, s.Avg);
        Assert.Equal(20.0, s.Peak);
    }

    [Fact]
    public void StatsTooFewReadingsIsNothingToSay() =>
        Assert.Equal(0, BatteryHistory.PowerDrawStats(History(W(10), W(20))).Samples);

    [Fact]
    public void StatsOfNoHistoryIsNothing() => Assert.Equal(DrawStats.None, BatteryHistory.PowerDrawStats(null));

    [Fact]
    public void StatsSkipSamplesWithoutAReading()
    {
        var s = BatteryHistory.PowerDrawStats(History(W(-1), W(-1), W(10), W(20), W(30)));
        Assert.Equal(3, s.Samples);
        Assert.Equal(20.0, s.Avg);
    }

    [Fact]
    public void StatsAChargingSampleEndsTheRun()
    {
        var s = BatteryHistory.PowerDrawStats(History(W(90), W(-1, charging: true), W(10), W(10), W(10)));
        Assert.Equal(3, s.Samples);
        Assert.Equal(10.0, s.Peak);
    }

    [Fact]
    public void StatsATimeGapEndsTheRun()
    {
        var h = History(W(90), W(10), W(10), W(10));
        h[0] = h[0] with { Time = T0.AddHours(-9) };
        var s = BatteryHistory.PowerDrawStats(h);
        Assert.Equal(3, s.Samples);
        Assert.Equal(10.0, s.Peak);
    }

    [Fact]
    public void StatsAPluggedInStretchEndsTheRun()
    {
        var s = BatteryHistory.PowerDrawStats(History(W(90), W(90),
            W(-1, plugged: true), W(-1, plugged: true), W(-1, plugged: true), W(10), W(10), W(10)));
        Assert.Equal(3, s.Samples);
        Assert.Equal(10.0, s.Peak);
    }

    [Fact]
    public void StatsOnAcWithAMeterAreTheAcStretchOnly()
    {
        var s = BatteryHistory.PowerDrawStats(History(W(90), W(90), W(90),
            W(12, plugged: true), W(14, plugged: true), W(16, plugged: true)));
        Assert.Equal(3, s.Samples);
        Assert.Equal(14.0, s.Avg);
        Assert.Equal(16.0, s.Peak);
    }

    [Fact]
    public void StatsWhileChargingThereIsNoDrawSession() =>
        Assert.Equal(0, BatteryHistory.PowerDrawStats(History(W(10), W(10), W(10), W(-1, charging: true))).Samples);

    // ---- history recording ----

    private static BatteryInfo Reading(double watts, PowerDrawKind kind, bool charging = false, bool plugged = false, bool full = false) => new()
    {
        Percent = 72,
        PercentExact = 72,
        IsCharging = charging,
        IsPluggedIn = plugged,
        IsFullyCharged = full,
        PowerDraw = new PowerDrawReading(watts, kind, kind == PowerDrawKind.None ? PowerDrawSource.None : PowerDrawSource.Battery),
    };

    [Fact]
    public void HistoryRecordsADrawReadingAsWatts()
    {
        var h = new BatteryHistory();
        h.Add(Reading(8.2, PowerDrawKind.Draw), T0);
        Assert.Equal(8.2, h.Samples[0].Watts);
    }

    [Fact]
    public void HistoryDoesNotRecordAChargeRateAsDraw()
    {
        var h = new BatteryHistory();
        h.Add(Reading(24.7, PowerDrawKind.Charge, charging: true), T0);
        Assert.Equal(-1, h.Samples[0].Watts);
    }

    [Fact]
    public void HistoryRecordsThePluggedInState()
    {
        var h = new BatteryHistory();
        h.Add(Reading(-1, PowerDrawKind.None, plugged: true, full: true), T0);
        h.Add(Reading(8.2, PowerDrawKind.Draw), T0.AddSeconds(3));
        Assert.True(h.Samples[0].IsPluggedIn);
        Assert.False(h.Samples[1].IsPluggedIn);
    }

    [Fact]
    public void HistoryNoReadingRecordsMinusOne()
    {
        var h = new BatteryHistory();
        h.Add(Reading(-1, PowerDrawKind.None), T0);
        Assert.Equal(-1, h.Samples[0].Watts);
    }

    // ---- end to end ----

    private static WmiBatterySnapshot Wmi(int status = 1, int? discharge = null, int? charge = null) => new()
    {
        EstimatedChargeRemaining = 72,
        BatteryStatus = status,
        DischargeRate = discharge,
        ChargeRate = charge,
        DesignCapacity = 59970,
        FullChargeCapacity = 56270,
        EstimatedRunTime = 188,
        TimeToFullCharge = null,
    };

    private static SystemPowerSnapshot Power(bool online = false, int flags = 0) => new()
    {
        AcLineStatus = online ? 1 : 0,
        BatteryFlag = flags,
        BatteryLifePercent = 72,
        BatteryLifeTime = -1,
    };

    [Fact]
    public void InfoDischargingLaptopReportsThePackDraw()
    {
        var i = new BatteryInterpreter().Interpret(Wmi(1, discharge: 8241), Power(), -1, T0);
        Assert.Equal(8.2, i.PowerDraw.Watts);
        Assert.Equal(PowerDrawKind.Draw, i.PowerDraw.Kind);
        Assert.Equal(PowerDrawSource.Battery, i.PowerDraw.Source);
    }

    [Fact]
    public void InfoChargingLaptopReportsTheInflowAsCharge()
    {
        var i = new BatteryInterpreter().Interpret(Wmi(2, charge: 24680), Power(online: true, flags: 8), -1, T0);
        Assert.Equal(24.7, i.PowerDraw.Watts);
        Assert.Equal(PowerDrawKind.Charge, i.PowerDraw.Kind);
    }

    [Fact]
    public void InfoTheMeterOutranksThePack()
    {
        var i = new BatteryInterpreter().Interpret(Wmi(1, discharge: 8241), Power(), 14200, T0);
        Assert.Equal(14.2, i.PowerDraw.Watts);
        Assert.Equal(PowerDrawSource.Meter, i.PowerDraw.Source);
    }

    [Fact]
    public void InfoHoldingAtAChargeCapHasNoNumber()
    {
        var i = new BatteryInterpreter().Interpret(Wmi(11), Power(online: true), -1, T0);
        Assert.Equal(-1, i.PowerDraw.Watts);
        Assert.Equal(PowerDrawKind.None, i.PowerDraw.Kind);
    }

    [Fact]
    public void InfoADesktopWithAMeterReportsItOnTheNoBatteryPath()
    {
        var i = new BatteryInterpreter().Interpret(null, Power(online: true, flags: 128), 65000, T0);
        Assert.True(i.NoBattery);
        Assert.Equal(65.0, i.PowerDraw.Watts);
        Assert.Equal(PowerDrawSource.Meter, i.PowerDraw.Source);
    }

    [Fact]
    public void InfoADesktopWithoutAMeterStaysSilent() =>
        Assert.Equal(PowerDrawKind.None, new BatteryInterpreter().Interpret(null, Power(online: true, flags: 128), -1, T0).PowerDraw.Kind);
}
