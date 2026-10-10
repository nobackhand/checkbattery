namespace BatteryPill.Core;

/// <param name="Watts">System draw that tick, or -1 (charging, no reading, old files).</param>
public sealed record HistorySample(DateTime Time, int Percent, bool IsCharging, bool IsPluggedIn, double Watts);

/// <param name="Avg">-1 when there is nothing to say yet.</param>
public readonly record struct DrawStats(double Avg, double Peak, int Samples)
{
    public static readonly DrawStats None = new(-1, -1, 0);
}

/// <summary>
/// The sparkline's sample buffer, plus what is computed from it. Ports of
/// Add-BatteryHistorySample, Get-PowerDrawStats, Get-BatterySessionSummary and
/// Get-HistorySpanMinutes.
/// </summary>
public sealed class BatteryHistory
{
    /// <summary>~2 h at 3 s ticks.</summary>
    public const int Capacity = 2400;
    /// <summary>A gap longer than this means the app was not running (sleep, a restored file).</summary>
    public const int MaxGapMinutes = 15;

    private readonly List<HistorySample> _samples = new();

    public IReadOnlyList<HistorySample> Samples => _samples;

    /// <summary>
    /// Record one tick. Only a real 0-100 reading is recorded: an unreadable tick
    /// (-1) used to plot below the baseline and poison the session summary. Only
    /// "draw" watts are kept; a charge rate flows the other way.
    /// </summary>
    public void Add(BatteryInfo info, DateTime now)
    {
        if (info.NoBattery) return;
        if (info.Percent < 0 || info.Percent > 100) return;
        double watts = info.PowerDraw.Kind == PowerDrawKind.Draw && info.PowerDraw.Watts > 0 ? info.PowerDraw.Watts : -1;
        Append(new HistorySample(now, info.Percent, info.IsCharging, info.IsPluggedIn, watts));
    }

    /// <summary>Restore samples (from the config file), keeping the newest <see cref="Capacity"/>.</summary>
    public void Load(IEnumerable<HistorySample> samples)
    {
        _samples.Clear();
        foreach (var s in samples) Append(s);
    }

    private void Append(HistorySample s)
    {
        _samples.Add(s);
        if (_samples.Count > Capacity) _samples.RemoveRange(0, _samples.Count - Capacity);
    }

    /// <summary>
    /// Average and peak draw over the CURRENT run: back to the last charging
    /// sample, the last change of power source, or the last time gap. Samples
    /// without a reading are skipped; fewer than <paramref name="minSamples"/> says nothing.
    /// </summary>
    public static DrawStats PowerDrawStats(IReadOnlyList<HistorySample>? history, int maxGapMinutes = MaxGapMinutes, int minSamples = 3)
    {
        if (history is null || history.Count < 1) return DrawStats.None;
        double sum = 0, peak = 0;
        int n = 0;
        int idx = history.Count - 1;
        bool onAc = history[idx].IsPluggedIn;
        while (idx >= 0)
        {
            var s = history[idx];
            if (s.IsCharging) break;
            if (s.IsPluggedIn != onAc) break;
            if (idx < history.Count - 1 && (history[idx + 1].Time - s.Time).TotalMinutes > maxGapMinutes) break;
            if (s.Watts > 0)
            {
                sum += s.Watts;
                n++;
                if (s.Watts > peak) peak = s.Watts;
            }
            idx--;
        }
        if (n < minSamples) return DrawStats.None;
        return new DrawStats(Math.Round(sum / n, 1, MidpointRounding.ToEven), Math.Round(peak, 1, MidpointRounding.ToEven), n);
    }

    /// <summary>
    /// "On battery 2h 13m - used 34%" for the current discharge run; empty while
    /// charging or plugged in, or when the run is too short to mean anything.
    /// </summary>
    public static string SessionSummary(IReadOnlyList<HistorySample>? history)
    {
        if (history is null || history.Count < 2) return "";
        var last = history[^1];
        if (last.IsCharging || last.IsPluggedIn) return "";
        int start = history.Count - 1;
        while (start > 0)
        {
            var prev = history[start - 1];
            if (prev.IsCharging || prev.IsPluggedIn) break;
            if ((history[start].Time - prev.Time).TotalMinutes > MaxGapMinutes) break;
            start--;
        }
        var first = history[start];
        int span = BatteryInterpreter.RoundInt((last.Time - first.Time).TotalMinutes);
        int used = first.Percent - last.Percent;
        if (span < 10 || used < 1) return "";
        return $"On battery {Format.Duration(span)} - used {used}%";
    }

    /// <summary>
    /// How much RECORDED time the buffer covers: only contiguous stretches count,
    /// so a restored file from yesterday does not label the graph "23.2h".
    /// </summary>
    public static int SpanMinutes(IReadOnlyList<HistorySample>? history, int maxGapMinutes = MaxGapMinutes)
    {
        if (history is null || history.Count < 2) return 0;
        double total = 0;
        for (int i = 1; i < history.Count; i++)
        {
            double delta = (history[i].Time - history[i - 1].Time).TotalMinutes;
            if (delta > 0 && delta <= maxGapMinutes) total += delta;
        }
        return BatteryInterpreter.RoundInt(total);
    }
}

public static class Format
{
    /// <summary>The one way a duration is written anywhere in the app: "3h 8m" / "42m".</summary>
    public static string Duration(int minutes)
    {
        int h = minutes / 60, m = minutes % 60;
        return h > 0 ? $"{h}h {m}m" : $"{m}m";
    }
}
