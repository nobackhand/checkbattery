using System.Collections;
using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of the battery and config boundaries of tests\Adversarial.Tests.ps1:
// firmware and files hand the app values no well-behaved source would, and
// none of them may crash a tick or turn into a confident wrong number.
public class AdversarialTests
{
    private static readonly DateTime T0 = new(2026, 7, 29, 9, 0, 0);

    // ---- DeviceNumber, the validator ----

    [Fact] public void AcceptsAnInRangeNumber() => Assert.Equal(60, DeviceNumber.Read(60, 0, 100));
    [Fact] public void AcceptsANumericString() => Assert.Equal(60, DeviceNumber.Read("60", 0, 100));
    [Fact] public void RejectsTheUInt32Sentinel() => Assert.Null(DeviceNumber.Read(4294967295u, 1));
    [Fact] public void RejectsNull() => Assert.Null(DeviceNumber.Read(null, 0, 100));
    [Fact] public void RejectsANonNumericString() => Assert.Null(DeviceNumber.Read("unknown", 0, 100));
    [Fact] public void RejectsAnArray() => Assert.Null(DeviceNumber.Read(new[] { 60, 80 }, 0, 100));

    [Fact]
    public void RejectsAOneElementArrayToo()
    {
        Assert.Null(DeviceNumber.Read(new[] { 60 }, 0, 100));
        Assert.Null(DeviceNumber.Read(new ArrayList(), 0, 100));
    }

    [Fact] public void RejectsADictionary() => Assert.Null(DeviceNumber.Read(new Hashtable { ["Value"] = 60 }, 0, 100));
    [Fact] public void RejectsABoolean() => Assert.Null(DeviceNumber.Read(true, 0, 100));

    [Fact]
    public void RejectsNaNAndInfinity()
    {
        Assert.Null(DeviceNumber.Read(double.NaN, 0, 100));
        Assert.Null(DeviceNumber.Read(double.PositiveInfinity, 0, 100));
        Assert.Null(DeviceNumber.Read(double.NegativeInfinity, 0, 100));
    }

    [Fact]
    public void RejectsOutOfRangeOnBothSides()
    {
        Assert.Null(DeviceNumber.Read(255, 0, 100));
        Assert.Null(DeviceNumber.Read(-5, 0, 100));
    }

    [Fact]
    public void KeepsTheBoundaries()
    {
        Assert.Equal(0, DeviceNumber.Read(0, 0, 100));
        Assert.Equal(100, DeviceNumber.Read(100, 0, 100));
    }

    [Fact] public void ReadsTheTypesWmiActuallySends() => Assert.Equal(12000, DeviceNumber.Read((uint)12000, 1));

    // ---- the battery reading ----

    private static WmiBatterySnapshot Battery(object? pct = null, object? status = null, object? design = null, object? full = null,
        object? discharge = null, object? charge = null, object? runTime = null, object? toFull = null) => new()
    {
        EstimatedChargeRemaining = pct ?? 60,
        BatteryStatus = status ?? 1,
        DesignCapacity = design ?? 74496,
        FullChargeCapacity = full ?? 70100,
        DischargeRate = discharge ?? 12000,
        ChargeRate = charge ?? 0,
        EstimatedRunTime = runTime ?? 210,
        TimeToFullCharge = toFull ?? 0,
    };

    private static readonly object Null = new NullMarker();
    private sealed class NullMarker { }

    private static WmiBatterySnapshot WithNulls(WmiBatterySnapshot b) => b with
    {
        EstimatedChargeRemaining = b.EstimatedChargeRemaining is NullMarker ? null : b.EstimatedChargeRemaining,
        BatteryStatus = b.BatteryStatus is NullMarker ? null : b.BatteryStatus,
        DesignCapacity = b.DesignCapacity is NullMarker ? null : b.DesignCapacity,
        FullChargeCapacity = b.FullChargeCapacity is NullMarker ? null : b.FullChargeCapacity,
        DischargeRate = b.DischargeRate is NullMarker ? null : b.DischargeRate,
        ChargeRate = b.ChargeRate is NullMarker ? null : b.ChargeRate,
        EstimatedRunTime = b.EstimatedRunTime is NullMarker ? null : b.EstimatedRunTime,
        TimeToFullCharge = b.TimeToFullCharge is NullMarker ? null : b.TimeToFullCharge,
    };

    // "The .NET source knows nothing": every field null, line offline
    private static SystemPowerSnapshot Power(object? flags = null, object? pct = null, object? seconds = null, bool online = false) =>
        new() { AcLineStatus = online ? 1 : 0, BatteryFlag = flags, BatteryLifePercent = pct, BatteryLifeTime = seconds };

    private static BatteryInfo Read(WmiBatterySnapshot? wmi, SystemPowerSnapshot? power = null) =>
        new BatteryInterpreter().Interpret(wmi is null ? null : WithNulls(wmi), power ?? Power(), -1, T0);

    [Fact]
    public void AHealthyReadingParses()
    {
        var i = Read(Battery());
        Assert.Equal(60, i.Percent);
        Assert.Equal(74496, i.DesignCapacity);
        Assert.Equal(12000, i.DischargeRate);
        Assert.Equal("Discharging", i.StatusText);
    }

    [Fact]
    public void RunTimeSentinelDoesNotCrashTheTick()
    {
        var i = Read(Battery(runTime: 4294967295u, discharge: 0, full: 0));
        Assert.Equal(-1, i.TimeMinutes);
        Assert.Equal(-1, i.FullRuntimeMinutes);
        Assert.Equal("Estimating...", i.TimeString);
    }

    [Fact]
    public void TimeToFullSentinelWhileChargingDoesNotCrash()
    {
        var i = Read(Battery(status: 6, charge: 0, full: 0, toFull: 4294967295u));
        Assert.True(i.IsCharging);
        Assert.Equal(-1, i.TimeMinutes);
    }

    [Fact] public void RunTimeAsAStringDoesNotCrash() => Assert.Equal(-1, Read(Battery(runTime: "unknown", discharge: 0, full: 0)).TimeMinutes);
    [Fact] public void Percent255IsNotShownAs255() => Assert.Equal(-1, Read(Battery(pct: 255)).Percent);
    [Fact] public void PercentNullIsNotAFalseZero() => Assert.Equal(-1, Read(Battery(pct: Null)).Percent);

    [Fact]
    public void AnUnreadablePercentIsNotCriticalOrLow()
    {
        var i = Read(Battery(pct: Null));
        Assert.NotEqual("Critical", i.StatusText);
        Assert.NotEqual("Low", i.StatusText);
    }

    [Fact] public void ARealEightPercentStillReportsCritical() => Assert.Equal("Critical", Read(Battery(pct: 8)).StatusText);
    [Fact] public void NegativePercentIsRejected() => Assert.Equal(-1, Read(Battery(pct: -20)).Percent);

    [Fact]
    public void EveryPropertyAsGarbageAtOnceDoesNotCrash()
    {
        var i = Read(Battery("x", "y", "z", "w", "v", "u", "t", "s"));
        Assert.Equal(-1, i.Percent);
        Assert.Equal(-1, i.DesignCapacity);
        Assert.Equal(-1, i.FullChargeCapacity);
        Assert.Equal(-1, i.DischargeRate);
        Assert.Equal(-1, i.TimeMinutes);
        Assert.Equal(-1, i.BatteryWearPercent);
        Assert.False(i.IsCharging);
    }

    [Fact]
    public void EveryPropertyAsNullDoesNotCrash()
    {
        var i = Read(Battery(Null, Null, Null, Null, Null, Null, Null, Null));
        Assert.Equal(-1, i.Percent);
        Assert.Equal(-1, i.TimeMinutes);
    }

    [Fact]
    public void ArrayValuedPropertiesDoNotCrash()
    {
        var i = Read(Battery(pct: new[] { 41, 77 }, design: new[] { 1, 2 }, runTime: new[] { 10, 20 }));
        Assert.Equal(-1, i.Percent);
        Assert.Equal(-1, i.DesignCapacity);
    }

    [Fact] public void ZeroCapacityGivesNoWearFigure() => Assert.Equal(-1, Read(Battery(design: 0, full: 0)).BatteryWearPercent);
    [Fact] public void FullAboveDesignClampsWearAtZero() => Assert.Equal(0, Read(Battery(design: 70000, full: 74000)).BatteryWearPercent);

    [Fact]
    public void Status2AtAChargeCapIsPluggedInNotCharging()
    {
        var i = Read(Battery(pct: 80, status: 2, discharge: 0), Power(flags: 1, online: true));
        Assert.False(i.IsCharging);
        Assert.True(i.IsPluggedIn);
        Assert.Equal("Plugged In", i.StatusText);
    }

    [Fact]
    public void Status2WithTheOsChargingFlagIsCharging()
    {
        var i = Read(Battery(pct: 55, status: 2, discharge: 0), Power(flags: 8, online: true));
        Assert.True(i.IsCharging);
        Assert.Equal("Charging", i.StatusText);
    }

    [Fact] public void Status6IsChargingOnItsOwn() => Assert.True(Read(Battery(pct: 55, status: 6, discharge: 0)).IsCharging);
    [Fact] public void OsUnknown255DoesNotReadAsCharging() => Assert.False(Read(Battery(status: 1), Power(flags: 255)).IsCharging);

    [Fact]
    public void OutOfRangeStatusIsUnknownNotAState()
    {
        var i = Read(Battery(status: 99));
        Assert.False(i.IsCharging);
        Assert.False(i.IsPluggedIn);
        Assert.False(i.IsFullyCharged);
    }

    [Fact]
    public void AnArrayValuedStatusIsUnknown()
    {
        var i = Read(Battery(status: new[] { 3, 1 }));
        Assert.False(i.IsFullyCharged);
        Assert.NotEqual("Fully Charged", i.StatusText);
    }

    [Fact] public void ANumericStringStatusReadsAsItsState() => Assert.True(Read(Battery(status: "6")).IsCharging);

    [Fact] public void NoWmiFallsBackToTheOs() => Assert.Equal(42, Read(null, Power(pct: 42)).Percent);
    [Fact] public void OsPercent255IsNotShown() => Assert.Equal(-1, Read(null, Power(pct: 255)).Percent);

    [Fact]
    public void AGarbageOsFlagDoesNotCrashTheNoBatteryProbe()
    {
        var i = Read(null, Power(flags: "nonsense"));
        Assert.False(i.NoBattery);
        Assert.Equal(-1, i.Percent);
    }

    [Fact]
    public void TheRealNoBatteryFlagIsHonoured()
    {
        var i = Read(null, Power(flags: 128));
        Assert.True(i.NoBattery);
        Assert.Equal("No Battery", i.StatusText);
    }

    [Fact]
    public void AGarbageOsLifetimeDoesNotCrashTheFallback() =>
        Assert.Equal(-1, Read(Battery(discharge: 0, full: 0, runTime: 0), Power(seconds: "soon")).TimeMinutes);

    [Fact]
    public void AnAbsurdRuntimeIsSuppressed()
    {
        var i = Read(Battery(discharge: 0, full: 0, runTime: 999999));
        Assert.Equal(-1, i.TimeMinutes);
        Assert.Equal("", i.ETA);
    }

    [Fact]
    public void AReadingWithNoPropertiesAtAllDoesNotCrash()
    {
        var i = new BatteryInterpreter().Interpret(new WmiBatterySnapshot(), Power(), -1, T0);
        Assert.Equal(-1, i.Percent);
        Assert.Equal(-1, i.TimeMinutes);
    }

    [Fact]
    public void NoBatteryAndNoOsStatusIsNoBattery() =>
        Assert.True(new BatteryInterpreter().Interpret(null, null, -1, T0).NoBattery);

    [Fact]
    public void FullOnTheCableReadsFullyChargedNotCharging()
    {
        var i = Read(Battery(pct: 100, status: 2, discharge: 0), Power(flags: 9, online: true));
        Assert.True(i.IsFullyCharged);
        Assert.False(i.IsCharging);
        Assert.Equal("Fully Charged", i.StatusText);
        Assert.Equal("N/A (plugged in)", i.TimeString);
    }

    [Fact]
    public void AWeakChargerThatStillDrainsKeepsItsLowWarning() =>
        Assert.Equal("Low", Read(Battery(pct: 15, status: 11, discharge: 8000), Power(online: true)).StatusText);

    [Fact]
    public void TheEtaIsTheLocalClockTimeWithinTwelveHours()
    {
        var interp = new BatteryInterpreter { Culture = System.Globalization.CultureInfo.GetCultureInfo("en-US") };
        var i = interp.Interpret(Battery(discharge: 0, full: 0, runTime: 90), Power(), -1, T0);
        Assert.Equal(90, i.TimeMinutes);
        Assert.Equal("1 hour 30 minutes", i.TimeString);
        Assert.Equal("10:30 AM", i.ETA);
    }

    [Theory]
    [InlineData(720, "9:00 PM")]
    [InlineData(721, "")]
    public void TheEtaIsShownUpToTwelveHoursAndNotBeyond(int runTime, string eta)
    {
        var interp = new BatteryInterpreter { Culture = System.Globalization.CultureInfo.GetCultureInfo("en-US") };
        Assert.Equal(eta, interp.Interpret(Battery(discharge: 0, full: 0, runTime: runTime), Power(), -1, T0).ETA);
    }

    [Fact]
    public void ElapsedTimeResyncsWhenTheClockJumpsBackward()
    {
        var interp = new BatteryInterpreter();
        interp.Interpret(WithNulls(Battery()), Power(), -1, T0);
        var later = interp.Interpret(WithNulls(Battery()), Power(), -1, T0.AddMinutes(84));
        Assert.Equal("1:24", later.ElapsedTime);
        // Behind the anchor itself (DST/NTP): resync to 0:00, never "-1:-24"
        var back = interp.Interpret(WithNulls(Battery()), Power(), -1, T0.AddMinutes(-10));
        Assert.Equal("0:00", back.ElapsedTime);
    }
}
