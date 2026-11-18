using System.Diagnostics;
using BatteryPill.Core;

namespace BatteryPill.Tests;

// The real sources on whatever machine runs the suite (a desktop, a laptop, a
// CI VM). They must answer, agree with each other about whether there is a
// battery, and never block the caller.
public class LiveSourceTests
{
    private static bool OsSaysNoBattery(SystemPowerSnapshot os) =>
        DeviceNumber.Read(os.BatteryFlag, 0, 255) is double f && ((int)f & 128) == 128;

    [Fact]
    public void TheOsPowerStatusAnswers() => Assert.NotNull(SystemPower.Read());

    [Fact]
    public void ADriverReadIsFastAndAgreesWithTheOsAboutTheBattery()
    {
        new BatteryQuery().Read();   // first call loads setupapi
        var sw = Stopwatch.StartNew();
        var snap = new BatteryQuery().Read();
        sw.Stop();
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(1), $"battery read took {sw.Elapsed.TotalMilliseconds:F0} ms");
        var os = SystemPower.Read()!;
        Assert.Equal(OsSaysNoBattery(os), snap is null);
    }

    [Fact]
    public void PollNeverBlocksAndTheFirstReadingArrives()
    {
        var q = new BatteryQuery();
        var sw = Stopwatch.StartNew();
        q.Poll(out _);
        Assert.True(sw.ElapsedMilliseconds < 200, $"Poll blocked for {sw.ElapsedMilliseconds} ms");
        var snap = q.WaitFirst(TimeSpan.FromSeconds(20), out bool fresh);
        var os = SystemPower.Read()!;
        if (!OsSaysNoBattery(os))
        {
            Assert.True(fresh);
            Assert.NotNull(snap);
        }
    }

    [Fact]
    public void TheInterpreterReadsThisMachine()
    {
        var q = new BatteryQuery();
        var snap = q.WaitFirst(TimeSpan.FromSeconds(20), out _);
        var os = SystemPower.Read();
        var info = new BatteryInterpreter().Interpret(snap, os, -1, DateTime.Now);
        Assert.Equal(OsSaysNoBattery(os!), info.NoBattery);
        if (!info.NoBattery) Assert.InRange(info.Percent, 0, 100);
    }

    [Fact]
    public void ThePowerMeterNeverBlocksAndSettles()
    {
        using var meter = new PowerMeter();
        var sw = Stopwatch.StartNew();
        double first = meter.Poll();
        Assert.True(sw.ElapsedMilliseconds < 200, $"Poll blocked for {sw.ElapsedMilliseconds} ms");
        Assert.Equal(-1, first);
        // A machine either has a meter that answers or is told it has none; the
        // first perf query can be slow, so allow it a minute
        double mw = -1;
        while (sw.Elapsed < TimeSpan.FromSeconds(60) && !meter.Unavailable && mw < 0)
        {
            Thread.Sleep(100);
            mw = meter.Poll();
        }
        Assert.True(meter.Unavailable || mw >= 0, $"meter undecided after {sw.Elapsed.TotalSeconds:F0}s");
        if (meter.Unavailable) Assert.Equal(-1, meter.Poll());
    }
}
