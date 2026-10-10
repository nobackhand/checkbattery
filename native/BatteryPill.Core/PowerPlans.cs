using System.Diagnostics;
using System.Text.RegularExpressions;

namespace BatteryPill.Core;

public sealed record PowerPlan(string Name, string Guid, bool IsActive);

/// <summary>
/// Windows power plans via powercfg. Port of src\040-power-plans.ps1. powercfg's
/// output is localized and version-dependent, so a row is only trusted when its
/// id is a real GUID (it goes back to powercfg) and it has a name (a menu row).
/// </summary>
public static partial class PowerPlans
{
    [GeneratedRegex(@"GUID:\s+(\S+)\s+\((.+?)\)(\s+\*)?")]
    private static partial Regex Row();

    [GeneratedRegex(@"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")]
    private static partial Regex GuidPattern();

    public static IReadOnlyList<PowerPlan> Parse(IEnumerable<string?> lines)
    {
        var plans = new List<PowerPlan>();
        foreach (var line in lines)
        {
            if (line is null) continue;
            var m = Row().Match(line);
            if (!m.Success) continue;
            string guid = m.Groups[1].Value, name = m.Groups[2].Value.Trim();
            if (!GuidPattern().IsMatch(guid) || name.Length == 0) continue;
            plans.Add(new PowerPlan(name, guid, m.Groups[3].Success));
        }
        return plans;
    }

    public static bool IsValidId(string? id) => id is not null && GuidPattern().IsMatch(id);

    /// <summary>Reads the plans (a child process: call it off the UI thread, or only on demand).</summary>
    public static IReadOnlyList<PowerPlan> Read()
    {
        try
        {
            var psi = new ProcessStartInfo("powercfg", "/list") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            if (p is null) return Array.Empty<PowerPlan>();
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return p.ExitCode == 0 ? Parse(output.Split('\n')) : Array.Empty<PowerPlan>();
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return Array.Empty<PowerPlan>();
        }
    }

    /// <summary>Activates a plan. The id is validated BEFORE anything runs.</summary>
    public static bool Activate(string? id)
    {
        if (!IsValidId(id)) return false;
        try
        {
            var psi = new ProcessStartInfo("powercfg", $"/setactive {id}") { UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            if (p is null) return false;
            p.WaitForExit(5000);
            return p.ExitCode == 0;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }
}
