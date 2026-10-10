using BatteryPill.Core;

namespace BatteryPill.Tests;

// The class driver's raw reading, mapped into the Win32_Battery shape the
// interpreter has always validated. Each case is a state a real pack reports.
public class BatteryDeviceTests
{
    private const uint Online = BatteryDriverReading.PowerOnLine;
    private const uint Draining = BatteryDriverReading.Discharging;
    private const uint Charging = BatteryDriverReading.Charging;

    private static BatteryDriverReading Pack(uint state, uint capacity = 30_000, int rate = 0,
        uint design = 60_000, uint full = 50_000, uint caps = 0x80000000, uint seconds = BatteryDriverReading.UnknownTime) =>
        new(state, capacity, rate, design, full, caps, seconds);

    private static BatteryInfo Interpret(BatteryDriverReading r, int acLine) =>
        new BatteryInterpreter().Interpret(BatteryDevice.ToSnapshot(r), new SystemPowerSnapshot { AcLineStatus = acLine, BatteryFlag = 0 }, -1, new DateTime(2026, 10, 10, 12, 0, 0));

    [Fact]
    public void DrainingReportsTheDrawAndTheRuntime()
    {
        var s = BatteryDevice.ToSnapshot(Pack(Draining, rate: -12_500, seconds: 3 * 3600 + 59));
        Assert.Equal(60, s.EstimatedChargeRemaining);
        Assert.Equal(1, s.BatteryStatus);
        Assert.Equal(12_500, s.DischargeRate);
        Assert.Null(s.ChargeRate);
        Assert.Equal(180u, s.EstimatedRunTime);
        Assert.Equal(60_000u, s.DesignCapacity);
        Assert.Equal(50_000u, s.FullChargeCapacity);

        var info = Interpret(Pack(Draining, rate: -12_500), acLine: 0);
        Assert.Equal("Discharging", info.StatusText);
        Assert.Equal(PowerDrawKind.Draw, info.PowerDraw.Kind);
        Assert.Equal(12.5, info.PowerDraw.Watts, 1);
    }

    [Fact]
    public void ChargingIsAnInflowNeverADraw()
    {
        var s = BatteryDevice.ToSnapshot(Pack(Online | Charging, rate: 45_000));
        Assert.Equal(6, s.BatteryStatus);
        Assert.Equal(45_000, s.ChargeRate);
        Assert.Null(s.DischargeRate);
        Assert.Equal((uint)BatteryInterpreter.UnknownRunTime, s.EstimatedRunTime);

        var info = Interpret(Pack(Online | Charging, rate: 45_000), acLine: 1);
        Assert.Equal("Charging", info.StatusText);
        Assert.Equal(PowerDrawKind.Charge, info.PowerDraw.Kind);
    }

    [Fact]
    public void AChargeCapHoldIsPluggedInNotCharging()
    {
        // ZBook at a charge cap: on AC, neither charging nor draining, rate 0
        var info = Interpret(Pack(Online, capacity: 40_000, rate: 0), acLine: 1);
        Assert.Equal("Plugged In", info.StatusText);
        Assert.False(info.IsCharging);
        Assert.Equal(PowerDrawKind.None, info.PowerDraw.Kind);
    }

    [Fact]
    public void AnUnderpoweredChargerThatStillDrainsStaysOnTheLowPath()
    {
        var info = Interpret(Pack(Online | Draining, capacity: 4_000, rate: -20_000), acLine: 1);
        Assert.Equal("Critical", info.StatusText);
        Assert.Equal(20_000, info.DischargeRate);
    }

    [Fact]
    public void UnknownSentinelsAreNoReadingNotNumbers()
    {
        var s = BatteryDevice.ToSnapshot(Pack(Draining, capacity: BatteryDriverReading.UnknownCapacity,
            rate: BatteryDriverReading.UnknownRate, design: 0, full: 0));
        Assert.Null(s.EstimatedChargeRemaining);
        Assert.Null(s.DischargeRate);
        Assert.Null(s.DesignCapacity);
        Assert.Null(s.FullChargeCapacity);
        Assert.Equal((uint)BatteryInterpreter.UnknownRunTime, s.EstimatedRunTime);
    }

    [Fact]
    public void RelativeUnitsKeepThePercentButDropWattsAndCapacities()
    {
        var s = BatteryDevice.ToSnapshot(Pack(Draining, capacity: 45, rate: -3, design: 100, full: 90,
            caps: 0x80000000 | BatteryDriverReading.CapacityRelative));
        Assert.Equal(50, s.EstimatedChargeRemaining);
        Assert.Null(s.DischargeRate);
        Assert.Null(s.DesignCapacity);
        Assert.Null(s.FullChargeCapacity);
    }

    [Fact]
    public void AnOverfullGaugeClampsTo100()
    {
        var s = BatteryDevice.ToSnapshot(Pack(Online, capacity: 51_000));
        Assert.Equal(100, s.EstimatedChargeRemaining);
    }
}
