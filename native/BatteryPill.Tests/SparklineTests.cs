using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of tests\Sparkline.Tests.ps1.
public class SparklineTests
{
    private static List<HistorySample> History(int count, params (int From, int To)[] charging)
    {
        var t0 = new DateTime(2026, 10, 9, 1, 0, 0);
        return Enumerable.Range(0, count).Select(i => new HistorySample(
            t0.AddSeconds(i * 3),
            (int)Math.Round(95 - i * 60.0 / Math.Max(1, count), MidpointRounding.ToEven),
            charging.Any(r => i >= r.From && i <= r.To), false, -1)).ToList();
    }

    [Fact]
    public void AFullTwoHourHistoryIsThinnedToAboutOnePointPerColumn() =>
        Assert.InRange(Sparkline.Points(History(2400), 380, 40).Count, 380, 402);

    [Fact]
    public void TheFirstAndLastSamplesAreAlwaysOnTheLine()
    {
        var h = History(2399);
        var pts = Sparkline.Points(h, 380, 40);
        Assert.Equal(0.0, pts[0].X);
        Assert.Equal(380.0, pts[^1].X);
        Assert.Equal(40 - h[2398].Percent / 100.0 * 36 - 2, pts[^1].Y, 6);
    }

    [Fact] public void AShortHistoryKeepsEverySample() => Assert.Equal(120, Sparkline.Points(History(120), 380, 40).Count);

    [Fact]
    public void PercentMapsToHeight()
    {
        var t = DateTime.Now;
        var pts = Sparkline.Points(new List<HistorySample> { new(t, 100, false, false, -1), new(t, 0, false, false, -1) }, 380, 40);
        Assert.Equal(2.0, pts[0].Y);
        Assert.Equal(38.0, pts[1].Y);
    }

    [Fact]
    public void UnderTwoSamplesThereIsNoLine()
    {
        Assert.Empty(Sparkline.Points(History(1), 380, 40));
        Assert.Empty(Sparkline.Points(null, 380, 40));
    }

    [Fact]
    public void ChargingRunsIncludingOneStillRunning() =>
        Assert.Equal(new[] { (10, 19), (90, 99) }, Sparkline.ChargingRuns(History(100, (10, 19), (90, 99))));

    [Fact] public void ASingleRunIsStillAList() => Assert.Equal(new[] { (5, 9) }, Sparkline.ChargingRuns(History(50, (5, 9))));

    [Fact]
    public void NoRunsWhenNeverCharged()
    {
        Assert.Empty(Sparkline.ChargingRuns(History(50)));
        Assert.Empty(Sparkline.ChargingRuns(null));
    }
}
