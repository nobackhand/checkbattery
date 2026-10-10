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
            var link = (IShellLinkW)new ShellLink();
            ((IPersistFile)link).Load(ShortcutPath, 0);
            var sb = new System.Text.StringBuilder(260);
            link.GetPath(sb, sb.Capacity, IntPtr.Zero, 0);
            return sb.ToString();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException or IOException)
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
            var link = (IShellLinkW)new ShellLink();
            link.SetPath(ExePath);
            link.SetWorkingDirectory(Path.GetDirectoryName(ExePath) ?? "");
            link.SetDescription("BatteryPill - Battery Widget");
            ((IPersistFile)link).Save(ShortcutPath, true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Trace.Log("autostart failed: " + e.Message);
            return false;
        }
    }
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("00021401-0000-0000-C000-000000000046")]
internal class ShellLink { }

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
[System.Runtime.InteropServices.Guid("000214F9-0000-0000-C000-000000000046")]
internal interface IShellLinkW
{
    void GetPath([System.Runtime.InteropServices.Out, System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder file, int max, IntPtr findData, int flags);
    void GetIDList(out IntPtr pidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([System.Runtime.InteropServices.Out, System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder name, int max);
    void SetDescription([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string name);
    void GetWorkingDirectory([System.Runtime.InteropServices.Out, System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int max);
    void SetWorkingDirectory([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string dir);
    void GetArguments([System.Runtime.InteropServices.Out, System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder args, int max);
    void SetArguments([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string args);
    void GetHotkey(out short hotkey);
    void SetHotkey(short hotkey);
    void GetShowCmd(out int cmd);
    void SetShowCmd(int cmd);
    void GetIconLocation([System.Runtime.InteropServices.Out, System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] System.Text.StringBuilder path, int max, out int index);
    void SetIconLocation([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string path, int index);
    void SetRelativePath([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string path, int reserved);
    void Resolve(IntPtr hwnd, int flags);
    void SetPath([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string file);
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
[System.Runtime.InteropServices.Guid("0000010b-0000-0000-C000-000000000046")]
internal interface IPersistFile
{
    void GetClassID(out Guid clsid);
    [System.Runtime.InteropServices.PreserveSig] int IsDirty();
    void Load([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string file, int mode);
    void Save([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string file, [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool remember);
    void SaveCompleted([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string file);
    void GetCurFile([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] out string file);
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
