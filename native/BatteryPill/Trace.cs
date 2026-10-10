namespace BatteryPill;

/// <summary>
/// Opt-in diagnostics: set BATTERYPILL_TRACE to a file path and input events are
/// appended there. Off (and free) otherwise. Used by the CI UI smoke test.
/// </summary>
internal static class Trace
{
    private static readonly string? Path = Environment.GetEnvironmentVariable("BATTERYPILL_TRACE");
    private static readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();

    public static void Log(string message)
    {
        if (Path is null) return;
        try { File.AppendAllText(Path, $"{Clock.Elapsed.TotalMilliseconds,9:F1} {message}{Environment.NewLine}"); }
        catch (IOException) { }
    }
}
