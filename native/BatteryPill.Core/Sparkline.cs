namespace BatteryPill.Core;

public readonly record struct SparkPoint(double X, double Y);

/// <summary>
/// The flyout's history graph. Ports of Get-SparklinePoints and Get-ChargingRuns:
/// the x-axis is index-linear (every sample the same width), thinned to about one
/// point per pixel column, 100% at the top and 0% at the bottom with a 2 px inset.
/// </summary>
public static class Sparkline
{
    public static IReadOnlyList<SparkPoint> Points(IReadOnlyList<HistorySample>? history, double width, double height)
    {
        int count = history?.Count ?? 0;
        if (count < 2) return Array.Empty<SparkPoint>();
        double denom = count - 1;
        int step = Math.Max(1, (int)Math.Floor(count / Math.Max(1.0, width)));
        var idx = new List<int>();
        for (int i = 0; i < count; i += step) idx.Add(i);
        if (idx[^1] != count - 1) idx.Add(count - 1);
        return idx.Select(i => new SparkPoint(i / denom * width, height - history![i].Percent / 100.0 * (height - 4) - 2)).ToList();
    }

    /// <summary>Contiguous charging stretches as (first, last) sample indexes.</summary>
    public static IReadOnlyList<(int Start, int End)> ChargingRuns(IReadOnlyList<HistorySample>? history)
    {
        var runs = new List<(int, int)>();
        if (history is null) return runs;
        int start = -1;
        for (int i = 0; i < history.Count; i++)
        {
            if (history[i].IsCharging) { if (start < 0) start = i; }
            else if (start >= 0) { runs.Add((start, i - 1)); start = -1; }
        }
        if (start >= 0) runs.Add((start, history.Count - 1));
        return runs;
    }
}
