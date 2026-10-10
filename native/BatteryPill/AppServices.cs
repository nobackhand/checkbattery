using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using BatteryPill.Core;

namespace BatteryPill;

internal static class AppInfo
{
    /// <summary>Three-part version from the assembly (set in the csproj).</summary>
    public static string Version { get; } =
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    public static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
    }
}

/// <summary>
/// Start with Windows through the same Startup-folder shortcut the PowerShell app
/// uses (BatteryPill.lnk): turning it on here retargets an existing shortcut, so
/// the old and new app never both start.
/// </summary>
internal static class AutoStart
{
    public static string ShortcutPath { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "BatteryPill.lnk");

    private static string ExePath => Environment.ProcessPath ?? "";

    public static string? Target()
    {
        if (!File.Exists(ShortcutPath)) return null;
        try
        {
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
            dynamic link = shell.CreateShortcut(ShortcutPath);
            return (string)link.TargetPath;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
            return null;
        }
    }

    public static bool IsEnabledForThisApp() => string.Equals(Target(), ExePath, StringComparison.OrdinalIgnoreCase);

    public static string Describe()
    {
        string? target = Target();
        if (target is null) return "Open BatteryPill when you sign in";
        if (string.Equals(target, ExePath, StringComparison.OrdinalIgnoreCase)) return "Opens when you sign in";
        return "Currently starts another copy: " + Path.GetFileName(target);
    }

    public static bool Set(bool enable)
    {
        try
        {
            if (!enable)
            {
                if (File.Exists(ShortcutPath)) File.Delete(ShortcutPath);
                return true;
            }
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
            dynamic link = shell.CreateShortcut(ShortcutPath);
            link.TargetPath = ExePath;
            link.WorkingDirectory = Path.GetDirectoryName(ExePath);
            link.Description = "BatteryPill - Battery Widget";
            link.Save();
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
            Trace.Log("autostart failed: " + e.Message);
            return false;
        }
    }
}

/// <summary>
/// The once-a-day release check (decisions in Core's UpdateCheck). The request
/// itself is all that happens here: GitHub sees it like any web visit.
/// </summary>
internal sealed class UpdateService
{
    private static readonly HttpClient Http = CreateClient();
    private readonly AppState _app;

    public UpdateState State { get; private set; } = UpdateState.Idle;
    public ReleaseInfo? Available { get; private set; }
    public event Action? StateChanged;

    public UpdateService(AppState app)
    {
        _app = app;
        Available = UpdateCheck.RestoreAvailability(AppInfo.Version, app.Config.AnnouncedVersion);
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd($"BatteryPill/{AppInfo.Version}");
        c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return c;
    }

    public async Task CheckAsync(bool force = false)
    {
        if (State == UpdateState.Checking) return;
        if (!force && (!_app.Config.CheckForUpdates || !UpdateCheck.IsDue(_app.Config.LastUpdateCheck, DateTime.Now))) return;
        State = UpdateState.Checking;
        StateChanged?.Invoke();

        string? json = null;
        bool received = false;
        try
        {
            using var response = await Http.GetAsync(UpdateCheck.LatestReleaseApi);
            if (response.IsSuccessStatusCode)
            {
                json = await response.Content.ReadAsStringAsync();
                received = true;
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            Trace.Log("update check: " + e.Message);
        }

        var release = UpdateCheck.ParseRelease(json);
        var result = UpdateCheck.Resolve(release, AppInfo.Version, _app.Config.AnnouncedVersion, received);
        State = result.State;
        if (result.State == UpdateState.Available) Available = release;
        else if (result.State == UpdateState.Current) Available = null;
        if (result.Stamp) _app.Config.LastUpdateCheck = DateTime.Now;
        _app.Config.AnnouncedVersion = result.Announced;
        _app.Save();
        if (result.Notify && release is not null) Notifier.Show($"BatteryPill {release.Version} is out", "Open Settings to get it");
        StateChanged?.Invoke();
    }

    public void OpenAvailable() => AppInfo.Open(Available?.Url ?? UpdateCheck.Website);
}
