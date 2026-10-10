namespace BatteryPill.Core;

/// <summary>
/// Momentum after a fling: the pill keeps moving and decelerates with friction,
/// stopping dead at the work-area edges. Port of Start-PillGlide, stepped per
/// display frame by the app instead of a 16 ms timer.
/// </summary>
public sealed class Glide
{
    /// <summary>px/ms: a wild fling must not rocket across the desktop.</summary>
    public const double MaxSpeed = 3.0;
    /// <summary>Velocity multiplier per 16 ms of real time.</summary>
    public const double FrictionPer16Ms = 0.90;
    public const double StopSpeed = 0.05;
    /// <summary>A hitch (a busy frame) is capped so one late frame can't leap.</summary>
    public const double MaxStepMs = 40;

    public double X { get; private set; }
    public double Y { get; private set; }
    public double Vx { get; private set; }
    public double Vy { get; private set; }
    public bool Done => Math.Sqrt(Vx * Vx + Vy * Vy) < StopSpeed;

    public Glide(double x, double y, double vx, double vy)
    {
        X = x; Y = y;
        double speed = Math.Sqrt(vx * vx + vy * vy);
        if (speed > MaxSpeed) { vx = vx * MaxSpeed / speed; vy = vy * MaxSpeed / speed; }
        Vx = vx; Vy = vy;
    }

    /// <summary>Advance by <paramref name="dtMs"/> within the work area; returns the new position.</summary>
    public PxPoint Step(double dtMs, int width, int height, PxRect workArea)
    {
        dtMs = Math.Clamp(dtMs, 0, MaxStepMs);
        X += Vx * dtMs;
        Y += Vy * dtMs;
        double decay = Math.Pow(FrictionPer16Ms, dtMs / 16.0);
        Vx *= decay; Vy *= decay;
        if (X < workArea.Left) { X = workArea.Left; Vx = 0; }
        if (X > workArea.Right - width) { X = workArea.Right - width; Vx = 0; }
        if (Y < workArea.Top) { Y = workArea.Top; Vy = 0; }
        if (Y > workArea.Bottom - height) { Y = workArea.Bottom - height; Vy = 0; }
        return new((int)X, (int)Y);
    }
}

public static class Easing
{
    /// <summary>
    /// Ease-out-back: a whisper of overshoot past the target and a spring back,
    /// the landing of a settle (c1 = 1.2, as in Start-PillSettle).
    /// </summary>
    public static double OutBack(double t, double c1 = 1.2)
    {
        t = Math.Clamp(t, 0, 1);
        double c3 = c1 + 1.0;
        return 1.0 + c3 * Math.Pow(t - 1.0, 3) + c1 * Math.Pow(t - 1.0, 2);
    }

    /// <summary>Fluent "decelerate" (cubic-bezier 0.1, 0.9, 0.2, 1) sampled for UI-thread motion.</summary>
    public static double Decelerate(double t)
    {
        t = Math.Clamp(t, 0, 1);
        // Solve the bezier's x(s) = t for s, then return y(s)
        double s = t;
        for (int i = 0; i < 8; i++)
        {
            double x = Bezier(s, 0.1, 0.2) - t;
            double dx = BezierDerivative(s, 0.1, 0.2);
            if (Math.Abs(dx) < 1e-6) break;
            s = Math.Clamp(s - x / dx, 0, 1);
        }
        return Bezier(s, 0.9, 1.0);
    }

    private static double Bezier(double s, double p1, double p2) =>
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s;

    private static double BezierDerivative(double s, double p1, double p2) =>
        3 * (1 - s) * (1 - s) * p1 + 6 * (1 - s) * s * (p2 - p1) + 3 * s * s * (1 - p2);
}

/// <summary>
/// The release velocity of a drag, from the last few move samples (px/ms).
/// Samples older than <see cref="WindowMs"/> are ignored: a drag that paused
/// before release has no momentum.
/// </summary>
public sealed class VelocityTracker
{
    public const double WindowMs = 80;
    private readonly List<(double T, int X, int Y)> _samples = new();

    public void Reset() => _samples.Clear();

    public void Add(double tMs, int x, int y)
    {
        _samples.Add((tMs, x, y));
        while (_samples.Count > 0 && tMs - _samples[0].T > WindowMs * 2) _samples.RemoveAt(0);
    }

    public (double Vx, double Vy) Velocity(double nowMs)
    {
        var recent = _samples.Where(s => nowMs - s.T <= WindowMs).ToList();
        if (recent.Count < 2) return (0, 0);
        var a = recent[0];
        var b = recent[^1];
        double dt = b.T - a.T;
        if (dt <= 0) return (0, 0);
        return ((b.X - a.X) / dt, (b.Y - a.Y) / dt);
    }
}
