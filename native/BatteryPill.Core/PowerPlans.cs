using System.Runtime.InteropServices;

namespace BatteryPill.Core;

public sealed record PowerPlan(string Name, string Guid, bool IsActive);

/// <summary>
/// Windows power plans, through the power-management API powercfg itself uses
/// (powrprof). Port of src\040-power-plans.ps1, minus its child process and its
/// localized-text parsing: a read takes about a millisecond, so the tray menu
/// can build the list as it opens.
/// </summary>
public static class PowerPlans
{
    public static bool IsValidId(string? id) => id is not null && System.Guid.TryParseExact(id, "D", out _);

    /// <summary>Every plan, the active one marked. Empty when Windows will not say.</summary>
    public static IReadOnlyList<PowerPlan> Read()
    {
        var plans = new List<PowerPlan>();
        Guid? active = null;
        if (PowerGetActiveScheme(IntPtr.Zero, out IntPtr activePtr) == 0 && activePtr != IntPtr.Zero)
        {
            active = Marshal.PtrToStructure<Guid>(activePtr);
            LocalFree(activePtr);
        }

        var buffer = new byte[16];
        for (uint i = 0; i < 64; i++)
        {
            uint size = 16;
            if (PowerEnumerate(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ACCESS_SCHEME, i, buffer, ref size) != 0) break;
            var id = new Guid(buffer);
            string? name = FriendlyName(id);
            if (string.IsNullOrWhiteSpace(name)) continue;   // a plan with no name is no menu row
            plans.Add(new PowerPlan(name.Trim(), id.ToString("D"), id == active));
        }
        return plans;
    }

    /// <summary>Activates a plan. The id is validated BEFORE anything is called.</summary>
    public static bool Activate(string? id)
    {
        if (!IsValidId(id)) return false;
        var g = System.Guid.ParseExact(id!, "D");
        return PowerSetActiveScheme(IntPtr.Zero, ref g) == 0;
    }

    private static string? FriendlyName(Guid id)
    {
        uint size = 0;
        if (PowerReadFriendlyName(IntPtr.Zero, ref id, IntPtr.Zero, IntPtr.Zero, null, ref size) != 0 || size == 0) return null;
        var bytes = new byte[size];
        if (PowerReadFriendlyName(IntPtr.Zero, ref id, IntPtr.Zero, IntPtr.Zero, bytes, ref size) != 0) return null;
        return System.Text.Encoding.Unicode.GetString(bytes, 0, (int)size).TrimEnd('\0');
    }

    // ---- interop ----

    private const uint ACCESS_SCHEME = 16;

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActiveScheme(IntPtr rootKey, out IntPtr activeScheme);
    [DllImport("powrprof.dll")]
    private static extern uint PowerSetActiveScheme(IntPtr rootKey, ref Guid scheme);
    [DllImport("powrprof.dll")]
    private static extern uint PowerEnumerate(IntPtr rootKey, IntPtr scheme, IntPtr subGroup, uint accessFlags, uint index, byte[] buffer, ref uint bufferSize);
    [DllImport("powrprof.dll")]
    private static extern uint PowerReadFriendlyName(IntPtr rootKey, ref Guid scheme, IntPtr subGroup, IntPtr setting, byte[]? buffer, ref uint bufferSize);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr mem);
}
