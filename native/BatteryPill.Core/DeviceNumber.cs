using System.Globalization;

namespace BatteryPill.Core;

/// <summary>
/// Validated read of ONE numeric value that came from outside the app (WMI,
/// battery firmware, the OS). Everything on Win32_Battery is whatever the OEM's
/// firmware chose to report: the UInt32 "unknown" pattern 4294967295, nulls,
/// 255 sentinels. Validate once here instead of guessing at each call site.
/// </summary>
public static class DeviceNumber
{
    /// <returns>The value, or null ("no reading") for anything that is not a
    /// finite number inside [min, max].</returns>
    public static double? Read(object? raw, double min = 0, double max = int.MaxValue)
    {
        double value;
        switch (raw)
        {
            case null:
                return null;
            case string s:
                if (!double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value)) return null;
                break;
            case bool:
                return null;
            case System.Collections.IEnumerable:
                // A dual-battery array or a multi-value property is not one reading
                return null;
            case IConvertible c:
                try { value = c.ToDouble(CultureInfo.InvariantCulture); }
                catch (Exception e) when (e is FormatException or InvalidCastException or OverflowException) { return null; }
                break;
            default:
                return null;
        }
        if (double.IsNaN(value) || double.IsInfinity(value)) return null;
        if (value < min || value > max) return null;
        return value;
    }
}
