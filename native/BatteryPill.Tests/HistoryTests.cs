using BatteryPill.Core;

namespace BatteryPill.Tests;

// Ports of tests\History.Tests.ps1 and the session/span cases of
// tests\Presentation.Tests.ps1.
public class HistoryTests
{
    private static readonly DateTime T0 = new(2026, 8, 31, 9, 0, 0);

    private static BatteryInfo Sample(int percent = 55, bool charging = false, bool noBattery = false) =>
        new() { Percent = percent, PercentExact = percent, IsCharging = charging, NoBattery = noBattery };

    [Fact]
    public void RecordsAnOrdinaryReading()
    {
        var h = new BatteryHistory();
        h.Add(Sample(55), T0);
        Assert.Single(h.Samples);
        Assert.Equal(55, h.Samples[0].Percent);
        Assert.False(h.Samples[0].IsCharging);
        Assert.Equal(T0, h.Samples[0].Time);
    }

    [Fact]
    public void RecordsTheChargingFlagAsGiven()
    {
        var h = new BatteryHistory();
        h.Add(Sample(40, charging: true), T0);
        Assert.True(h.Samples[0].IsCharging);
    }

    [Fact]
    public void ADesktopWithNoBatteryRecordsNothing()
    {
        var h = new BatteryHistory();
        h.Add(Sample(-1, noBattery: true), T0);
        Assert.Empty(h.Samples);
    }

    [Fact]
    public void TheNoBatteryGuardStandsOnItsOwn()
    {
        var h = new BatteryHistory();
        h.Add(Sample(55, noBattery: true), T0);
        Assert.Empty(h.Samples);
    }

    [Fact]
    public void AnUnreadablePercentIsRefused()
    {
        var h = new BatteryHistory();
        h.Add(Sample(-1), T0);
        Assert.Empty(h.Samples);
    }

    [Fact]
    public void AnOutOfRangePercentIsRefused()
    {
        var h = new BatteryHistory();
        h.Add(Sample(255), T0);
        h.Add(Sample(101), T0);
        Assert.Empty(h.Samples);
    }

    [Fact]
    public void TheBoundariesAreKept()
    {
        var h = new BatteryHistory();
        h.Add(Sample(0), T0);
        h.Add(Sample(100), T0);
        Assert.Equal(2, h.Samples.Count);
    }

    [Fact]
    public void ADropoutDoesNotCorruptTheRunAroundIt()
    {
        var h = new BatteryHistory();
        h.Add(Sample(50), T0);
        h.Add(Sample(-1), T0.AddSeconds(3));
        h.Add(Sample(49), T0.AddSeconds(6));
        Assert.Equal(2, h.Samples.Count);
        Assert.All(h.Samples, s => Assert.True(s.Percent >= 0));
    }

    [Fact]
    public void TheBufferIsCappedAndKeepsTheNewest()
    {
        var h = new BatteryHistory();
        for (int i = 0; i < 2450; i++) h.Add(Sample(i % 101), T0.AddSeconds(i * 3));
        Assert.Equal(2400, h.Samples.Count);
        Assert.Equal(2449 % 101, h.Samples[^1].Percent);
        Assert.Equal(T0.AddSeconds(2449 * 3), h.Samples[^1].Time);
    }

    // ---- session summary and span (1-minute samples, contiguous runs) ----

    private static readonly DateTime S0 = new(2026, 8, 30, 22, 0, 0);

    private sealed class Runs
    {
        public readonly List<HistorySample> Samples = new();

        public Runs Add(int startMin, int minutes, int fromPct, int toPct, bool charging = false, bool plugged = false)
        {
            for (int i = 0; i <= minutes; i++)
            {
                int pct = (int)Math.Round(fromPct + (toPct - fromPct) * (i / (double)minutes), MidpointRounding.ToEven);
                Samples.Add(new HistorySample(S0.AddMinutes(startMin + i), pct, charging, plugged, -1));
            }
            return this;
        }
    }

    [Fact]
    public void SessionAPlainDischargeRun() =>
        Assert.Equal("On battery 1h 30m - used 21%", BatteryHistory.SessionSummary(new Runs().Add(0, 90, 95, 74).Samples));

    [Fact]
    public void SessionSilentWhileCharging() =>
        Assert.Equal("", BatteryHistory.SessionSummary(new Runs().Add(0, 30, 60, 58).Add(31, 60, 58, 88, charging: true).Samples));

    [Fact]
    public void SessionSilentTheInstantTheChargerGoesIn() =>
        Assert.Equal("", BatteryHistory.SessionSummary(new Runs().Add(0, 120, 95, 60).Add(121, 1, 60, 60, charging: true).Samples));

    [Fact]
    public void SessionTheRunStartsAfterTheLastCharge() =>
        Assert.Equal("On battery 1h 0m - used 15%", BatteryHistory.SessionSummary(
            new Runs().Add(0, 40, 55, 40).Add(41, 30, 40, 99, charging: true).Add(72, 60, 95, 80).Samples));

    [Fact]
    public void SessionTooShortStaysQuiet() =>
        Assert.Equal("", BatteryHistory.SessionSummary(new Runs().Add(0, 5, 95, 94).Samples));

    [Fact]
    public void SessionASleepGapIsNotTimeOnBattery() =>
        Assert.Equal("On battery 1h 0m - used 6%", BatteryHistory.SessionSummary(new Runs().Add(0, 30, 95, 90).Add(510, 60, 88, 82).Samples));

    [Fact]
    public void SessionAnOldRestoredRunIsNotResurrected() =>
        Assert.Equal("On battery 1h 0m - used 6%", BatteryHistory.SessionSummary(new Runs().Add(0, 30, 80, 72).Add(4350, 60, 99, 93).Samples));

    [Fact]
    public void SessionSilentWhileParkedAtAChargeCap() =>
        Assert.Equal("", BatteryHistory.SessionSummary(new Runs().Add(0, 60, 95, 80).Add(61, 60, 80, 80, plugged: true).Samples));

    [Fact]
    public void SessionAnUnplugAfterSittingFullStartsANewRun() =>
        Assert.Equal("On battery 1h 0m - used 10%", BatteryHistory.SessionSummary(new Runs().Add(0, 60, 100, 100, plugged: true).Add(61, 60, 100, 90).Samples));

    [Fact]
    public void SpanAContinuousRunIsItsOwnLength() =>
        Assert.Equal(120, BatteryHistory.SpanMinutes(new Runs().Add(0, 120, 95, 60).Samples));

    [Fact]
    public void SpanAGapTheGraphDoesNotDrawIsNotCounted() =>
        Assert.Equal(90, BatteryHistory.SpanMinutes(new Runs().Add(0, 30, 95, 90).Add(510, 60, 88, 82).Samples));

    [Fact]
    public void SpanTooLittleHistory()
    {
        Assert.Equal(0, BatteryHistory.SpanMinutes(new List<HistorySample>()));
        Assert.Equal(0, BatteryHistory.SpanMinutes(null));
    }

    [Theory]
    [InlineData(0, "0m")]
    [InlineData(42, "42m")]
    [InlineData(60, "1h 0m")]
    [InlineData(188, "3h 8m")]
    public void DurationFormat(int minutes, string expected) => Assert.Equal(expected, Format.Duration(minutes));
}
