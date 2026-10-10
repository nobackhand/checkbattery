using BatteryPill.Core;

namespace BatteryPill.Tests;

// Ports of tests\PillPosition.Tests.ps1 and the size cases of
// tests\PillGeometry.Tests.ps1, plus the glide/settle physics.
public class GeometryTests
{
    private static readonly PxRect Area = new(0, 0, 1920, 1040);

    // ---- sizes ----

    [Fact]
    public void TheShippedSizesAreUnchanged()
    {
        Assert.Equal((108.0, 34.0), (PillGeometry.Dimensions("normal", "time").Width, PillGeometry.Dimensions("normal", "time").Height));
        Assert.Equal((80.0, 28.0), (PillGeometry.Dimensions("compact", "time").Width, PillGeometry.Dimensions("compact", "time").Height));
        Assert.Equal((140.0, 42.0), (PillGeometry.Dimensions("expanded", "time").Width, PillGeometry.Dimensions("expanded", "time").Height));
    }

    [Fact]
    public void BothModeIsTallerForItsTwoLines()
    {
        var both = PillGeometry.Dimensions("normal", "both");
        Assert.True(both.Height > PillGeometry.Dimensions("normal", "time").Height);
        Assert.True(both.TwoLines);
    }

    // ---- display changes ----

    [Fact] public void NothingToDoAtTheSavedSpot() => Assert.Equal(DisplayChangeAction.None, PillGeometry.OnDisplayChange(true, true, true));
    [Fact] public void TheSavedSpotBecomingValidRestoresIt() => Assert.Equal(DisplayChangeAction.Restore, PillGeometry.OnDisplayChange(true, true, false));
    [Fact] public void AStrandedPillWithNoSavedSpotIsParked() => Assert.Equal(DisplayChangeAction.Park, PillGeometry.OnDisplayChange(false, false, false));
    [Fact] public void AVisiblePillIsLeftAlone() => Assert.Equal(DisplayChangeAction.None, PillGeometry.OnDisplayChange(false, true, false));

    [Fact]
    public void TheSavedSpotAlwaysWins()
    {
        Assert.Equal(DisplayChangeAction.Restore, PillGeometry.OnDisplayChange(true, true, false));
        Assert.Equal(DisplayChangeAction.Restore, PillGeometry.OnDisplayChange(true, false, false));
    }

    // ---- clamp ----

    [Fact] public void ClampAFittingPositionIsUntouched() => Assert.Equal(new PxPoint(900, 500), PillGeometry.Clamped(new(900, 500), 216, 68, Area));
    [Fact] public void ClampAGrownPillIsPulledInsideTheRightEdge() => Assert.Equal(new PxPoint(1920 - 216, 500), PillGeometry.Clamped(new(1802, 500), 216, 68, Area));
    [Fact] public void ClampTheBottomEdge() => Assert.Equal(1040 - 68, PillGeometry.Clamped(new(100, 1000), 216, 68, Area).Y);
    [Fact] public void ClampANegativePositionIsPulledIn() => Assert.Equal(new PxPoint(0, 0), PillGeometry.Clamped(new(-50, -20), 216, 68, Area));
    [Fact] public void ClampAPillWiderThanTheScreenIsLeftAlone() => Assert.Equal(40, PillGeometry.Clamped(new(40, 500), 3000, 68, Area).X);

    // ---- snap and on-screen ----

    [Fact]
    public void SnapsToAnEdgeWithinTheThresholdLeavingTheMargin()
    {
        var p = PillGeometry.Snapped(new(1920 - 216 - 10, 1040 - 68 - 12), 216, 68, 20, Area);
        Assert.Equal(new PxPoint(1920 - 216 - PillGeometry.EdgeMargin, 1040 - 68 - PillGeometry.EdgeMargin), p);
    }

    [Fact] public void DoesNotSnapFromFarAway() => Assert.Equal(new PxPoint(800, 400), PillGeometry.Snapped(new(800, 400), 216, 68, 20, Area));

    [Fact]
    public void OnScreenMeansTheCentreIsInSomeWorkArea()
    {
        var second = new PxRect(1920, 0, 3840, 1040);
        Assert.True(PillGeometry.IsOnScreen(new(2000, 500), 216, 68, new[] { Area, second }));
        Assert.False(PillGeometry.IsOnScreen(new(2000, 500), 216, 68, new[] { Area }));
        Assert.False(PillGeometry.IsOnScreen(new(-500, -500), 216, 68, new[] { Area, second }));
    }

    // ---- glide ----

    [Fact]
    public void AWildFlingIsCappedAtMaxSpeed()
    {
        var g = new Glide(500, 500, 30, 40);
        Assert.Equal(Glide.MaxSpeed, Math.Sqrt(g.Vx * g.Vx + g.Vy * g.Vy), 6);
    }

    [Fact]
    public void AGlideDeceleratesAndStops()
    {
        var g = new Glide(500, 500, 2, 0);
        double lastX = 500;
        int frames = 0;
        while (!g.Done && frames < 1000)
        {
            var p = g.Step(16, 216, 68, Area);
            Assert.True(p.X >= lastX);
            lastX = p.X;
            frames++;
        }
        Assert.True(g.Done);
        Assert.InRange(lastX, 700, 900);   // 2 px/ms with x0.90 per 16 ms coasts ~300 px
    }

    [Fact]
    public void FrictionIsScaledToRealTimeNotFrames()
    {
        // The same 160 ms of glide lands in the same place at 60 Hz and at 240 Hz
        var at60 = new Glide(500, 500, 1, 0);
        var at240 = new Glide(500, 500, 1, 0);
        for (int i = 0; i < 10; i++) at60.Step(16, 216, 68, Area);
        for (int i = 0; i < 40; i++) at240.Step(4, 216, 68, Area);
        // Within the discretisation error (~4 px); per-FRAME friction would leave
        // the 240 Hz glide ~60 px short
        Assert.InRange(Math.Abs(at60.X - at240.X), 0, 8);
    }

    [Fact]
    public void AGlideStopsDeadAtTheEdge()
    {
        var g = new Glide(1600, 500, 3, 0);
        for (int i = 0; i < 200 && !g.Done; i++) g.Step(16, 216, 68, Area);
        Assert.Equal(1920 - 216, g.X);
        Assert.Equal(0, g.Vx);
    }

    [Fact]
    public void AHitchIsCappedSoOneLateFrameCannotLeap()
    {
        var g = new Glide(500, 500, 1, 0);
        var p = g.Step(5000, 216, 68, Area);
        Assert.Equal(500 + (int)Glide.MaxStepMs, p.X);
    }

    [Fact]
    public void VelocityComesFromTheLastFewSamplesOnly()
    {
        var v = new VelocityTracker();
        v.Add(0, 0, 0);
        v.Add(500, 10, 0);    // a slow drag...
        v.Add(540, 50, 0);    // ...then a flick
        v.Add(560, 90, 0);
        var (vx, _) = v.Velocity(560);
        // 80 px over the last 60 ms; the slow half-second before it is outside the window
        Assert.Equal(80 / 60.0, vx, 3);
    }

    [Fact]
    public void ADragThatPausedBeforeReleaseHasNoMomentum()
    {
        var v = new VelocityTracker();
        v.Add(0, 0, 0);
        v.Add(16, 30, 0);
        Assert.Equal((0.0, 0.0), v.Velocity(400));
    }

    // ---- easing ----

    [Fact]
    public void OutBackStartsAndEndsOnTargetAndOvershootsBetween()
    {
        Assert.Equal(0, Easing.OutBack(0), 6);
        Assert.Equal(1, Easing.OutBack(1), 6);
        Assert.True(Enumerable.Range(1, 99).Select(i => Easing.OutBack(i / 100.0)).Max() > 1.0);
    }

    [Fact]
    public void DecelerateIsMonotonicAndFrontLoaded()
    {
        Assert.Equal(0, Easing.Decelerate(0), 4);
        Assert.Equal(1, Easing.Decelerate(1), 4);
        Assert.True(Easing.Decelerate(0.25) > 0.6);
        double last = 0;
        for (int i = 1; i <= 100; i++)
        {
            double v = Easing.Decelerate(i / 100.0);
            Assert.True(v >= last - 1e-9);
            last = v;
        }
    }
}
