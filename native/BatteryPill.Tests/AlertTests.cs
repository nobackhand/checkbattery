using BatteryPill.Core;

namespace BatteryPill.Tests;

public class AlertTests
{
    private static readonly DateTime T0 = new(2026, 10, 10, 12, 0, 0);

    private static BatteryInfo B(int pct, bool plugged = false, bool charging = false, bool full = false, int minutes = -1, string eta = "", bool noBattery = false) =>
        new() { Percent = pct, PercentExact = pct, IsPluggedIn = plugged, IsCharging = charging, IsFullyCharged = full, TimeMinutes = minutes, ETA = eta, NoBattery = noBattery };

    private static List<AlertKind> Run(AlertPlanner p, params (BatteryInfo B, int Sec)[] ticks) =>
        ticks.SelectMany(t => p.Next(t.B, T0.AddSeconds(t.Sec))).Select(a => a.Kind).ToList();

    [Fact]
    public void PluggingInAnnouncesChargingOnceTheEtaIsKnown()
    {
        var p = new AlertPlanner();
        var alerts = new List<Alert>();
        alerts.AddRange(p.Next(B(40), T0));
        alerts.AddRange(p.Next(B(40, plugged: true), T0.AddSeconds(3)));                           // plugged, no rate yet
        alerts.AddRange(p.Next(B(40, plugged: true, charging: true, minutes: 75, eta: "1:15 PM"), T0.AddSeconds(6)));
        alerts.AddRange(p.Next(B(41, plugged: true, charging: true, minutes: 74, eta: "1:15 PM"), T0.AddSeconds(9)));
        var a = Assert.Single(alerts);
        Assert.Equal(AlertKind.Charging, a.Kind);
        Assert.Equal("Full by 1:15 PM", a.Body);
    }

    [Fact]
    public void AChargingCardThatNeverGetsAnEtaIsDroppedAfter45Seconds() =>
        Assert.Empty(Run(new AlertPlanner(), (B(40), 0), (B(40, plugged: true), 3), (B(40, plugged: true, charging: true), 50),
            (B(40, plugged: true, charging: true, minutes: 75, eta: "1:15 PM"), 53)));

    [Fact]
    public void LaunchingWhilePluggedInIsNotAnnounced() =>
        Assert.Empty(Run(new AlertPlanner(), (B(40, plugged: true, charging: true, minutes: 75, eta: "1:15 PM"), 0)));

    [Fact]
    public void ReachingFullIsAnnouncedOncePerPlugIn() =>
        Assert.Equal(new[] { AlertKind.Full }, Run(new AlertPlanner(),
            (B(99, plugged: true, charging: true), 0), (B(100, plugged: true, full: true), 3), (B(100, plugged: true, full: true), 6),
            (B(99, plugged: true), 9), (B(100, plugged: true, full: true), 12)));

    [Fact]
    public void UnpluggingReArmsTheFullCard() =>
        Assert.Equal(new[] { AlertKind.Full, AlertKind.Full }, Run(new AlertPlanner(),
            (B(99, plugged: true, charging: true), 0), (B(100, plugged: true, full: true), 3),
            (B(99), 6), (B(99, plugged: true, charging: true), 9), (B(100, plugged: true, full: true), 12)));

    [Fact]
    public void LaunchingAlreadyFullIsNotNews() =>
        Assert.Empty(Run(new AlertPlanner(), (B(100, plugged: true, full: true), 0), (B(100, plugged: true, full: true), 3)));

    [Fact]
    public void LowAndCriticalFireOnceEachOnTheWayDown() =>
        Assert.Equal(new[] { AlertKind.Low, AlertKind.Critical }, Run(new AlertPlanner(),
            (B(12), 0), (B(10), 3), (B(9), 6), (B(6), 9), (B(5), 12), (B(4), 15), (B(3), 18)));

    [Fact]
    public void PluggingInReArmsTheLowWarnings() =>
        Assert.Equal(new[] { AlertKind.Low, AlertKind.Low }, Run(new AlertPlanner(),
            (B(10), 0), (B(10, plugged: true, charging: true), 3), (B(10), 6)));

    [Fact]
    public void AnUnreadablePercentNeverWarns() => Assert.Empty(Run(new AlertPlanner(), (B(-1), 0), (B(-1), 3)));

    [Fact]
    public void DroppingStraightToFiveGivesOnlyTheCriticalWarning()
    {
        var p = new AlertPlanner();
        p.Next(B(40), T0);
        var a = Assert.Single(p.Next(B(5, minutes: 9), T0.AddSeconds(3)));
        Assert.Equal(AlertKind.Critical, a.Kind);
        Assert.Equal("9 min remaining", a.Body);
    }

    [Fact]
    public void ADesktopNeverGetsBatteryAlerts() =>
        Assert.Empty(Run(new AlertPlanner(), (B(-1, plugged: true, noBattery: true), 0), (B(-1, plugged: true, noBattery: true), 3)));

    // ---- parity pins ----

    [Theory]
    [InlineData(15)]
    [InlineData(11)]
    public void NoLowAlertAbove10Percent(int pct) => Assert.Empty(Run(new AlertPlanner(), (B(pct), 0)));

    [Fact]
    public void TheLowAlertFiresAtExactly10Percent() => Assert.Equal(new[] { AlertKind.Low }, Run(new AlertPlanner(), (B(10), 0)));

    [Fact]
    public void TheCriticalAlertFiresAtExactly5Percent() => Assert.Equal(new[] { AlertKind.Critical }, Run(new AlertPlanner(), (B(5), 0)));

    [Fact]
    public void APlugInThatHoldsAtAChargeCapIsNotAnnouncedAsCharging() =>
        // On AC with an ETA-shaped reading but NOT charging: no "Charging" card
        Assert.Empty(Run(new AlertPlanner(), (B(80), 0), (B(80, plugged: true, minutes: 30, eta: "1:00 PM"), 3),
            (B(80, plugged: true, minutes: 30, eta: "1:00 PM"), 6)));
}
