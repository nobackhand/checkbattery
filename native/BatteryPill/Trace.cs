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
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>
/// Every unhandled exception, appended to %LOCALAPPDATA%\BatteryPill\crash.log
/// (always on, never sent anywhere): a pill that vanishes leaves a reason
/// behind. Kept under 256 KB.
/// </summary>
internal static class CrashLog
{
    public static string FilePath { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BatteryPill", "crash.log");

    public static void Write(string where, Exception? e)
    {
        Trace.Log($"UNHANDLED ({where}): {e?.GetType().Name}: {e?.Message}");
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
            if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 256 * 1024) File.Delete(FilePath);
            File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} BatteryPill {AppInfo.Version} ({where}){Environment.NewLine}{e}{Environment.NewLine}{Environment.NewLine}");
        }
        catch (Exception io) when (io is IOException or UnauthorizedAccessException) { }
    }

    public static void Hook(Microsoft.UI.Xaml.Application app)
    {
        app.UnhandledException += (_, e) => Write("ui", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Write("process", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Write("task", e.Exception);
            e.SetObserved();
        };
    }
}
