using System.Globalization;

namespace BatteryPill.Core;

/// <summary>A UI-free color (the app converts it to a XAML/composition color).</summary>
public readonly record struct Rgb(byte R, byte G, byte B, byte A = 255)
{
    /// <summary>Darken/lighten, rounding like PowerShell's [int] cast.</summary>
    public Rgb Scale(double f) => new(Ch(R * f), Ch(G * f), Ch(B * f), A);

    private static byte Ch(double v) => (byte)Math.Clamp(Math.Round(v, MidpointRounding.ToEven), 0, 255);
    /// <summary>Perceived brightness 0-1 (System.Drawing's GetBrightness: (max+min)/2).</summary>
    public double Brightness => (Math.Max(R, Math.Max(G, B)) + Math.Min(R, Math.Min(G, B))) / 510.0;
}

/// <param name="Secondary">Second line ("both" mode); empty otherwise.</param>
public readonly record struct PillText(string Primary, string Secondary);

/// <summary>
/// The app's voice: every string and status color a surface shows. Ports of
/// Get-PillText, Get-PowerText, Get-PowerSentence, Get-TimeSentence,
/// Get-BatteryStateTitle, Get-FunStatusLine and the color helpers.
/// </summary>
public static class Presentation
{
    public const char EmDash = '—';

    public static readonly Rgb[] AccentPresets =
    {
        new(45, 212, 100),   // 0 green (default)
        new(60, 140, 255),   // 1 blue
        new(160, 100, 255),  // 2 purple
        new(0, 210, 210),    // 3 cyan
        new(255, 105, 180),  // 4 pink
        new(0, 180, 160),    // 5 teal
        new(255, 160, 40),   // 6 orange
        new(220, 220, 230),  // 7 white
    };

    public static PillText PillText(BatteryInfo b, string displayMode)
    {
        string pct = b.Percent >= 0 ? $"{b.Percent}%" : "--";
        string time;
        if (b.NoBattery) { time = "AC"; pct = "AC"; }
        else if (b.IsFullyCharged) time = "Full";
        else if (b.TimeMinutes > 0) time = Format.Duration(b.TimeMinutes);
        else time = pct;

        switch (displayMode)
        {
            case "percent":
                return new(pct, "");
            case "power":
                string power = PowerText(b.PowerDraw, decimals: 0);
                if (power.Length == 0) power = b.NoBattery || b.IsPluggedIn ? "AC" : pct;
                return new(power, "");
            case "both":
                return new(pct, b.NoBattery ? "" : time);
            default:
                return new(time, "");
        }
    }

    /// <summary>"8.2 W", "+24.7 W" (charge); "" when there is no reading.</summary>
    public static string PowerText(PowerDrawReading d, int decimals = 1)
    {
        if (d.Watts <= 0 || d.Kind == PowerDrawKind.None) return "";
        string num = decimals <= 0
            ? ((int)Math.Round(d.Watts, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)
            : d.Watts.ToString("F" + decimals, CultureInfo.InvariantCulture);
        return (d.Kind == PowerDrawKind.Charge ? "+" : "") + num + " W";
    }

    public static string PowerDrawWord(double watts) => watts switch
    {
        <= 0 => "",
        < 6 => "sipping",
        < 13 => "cruising",
        < 25 => "working",
        < 45 => "pushing it",
        _ => "full send",
    };

    public static string PowerSentence(BatteryInfo b, bool fun = false)
    {
        string text = PowerText(b.PowerDraw, 1);
        if (text.Length == 0) return "";
        if (b.PowerDraw.Kind == PowerDrawKind.Charge) return "Charging at " + text.TrimStart('+');
        string line = (b.PowerDraw.Source == PowerDrawSource.Meter ? "Using " : "Drawing ") + text;
        if (fun && PowerDrawWord(b.PowerDraw.Watts) is { Length: > 0 } word) line += $" {EmDash} {word}";
        return line;
    }

    public static string TimeSentence(BatteryInfo b)
    {
        if (b.IsFullyCharged) return "Fully charged";
        if (b.TimeMinutes > 0)
        {
            string s = Format.Duration(b.TimeMinutes) + (b.IsCharging ? " to full" : " left");
            return b.ETA.Length > 0 ? $"{s} {EmDash} {b.ETA}" : s;
        }
        return "Estimating...";
    }

    public static string StateTitle(BatteryInfo b)
    {
        if (b.IsFullyCharged) return "Fully Charged";
        if (b.IsCharging) return "Charging";
        if (b.NoBattery) return "No Battery";
        if (b.StatusText == "Plugged In") return "Plugged In";
        return "Discharging";
    }

    public static string FunStatusLine(BatteryInfo b)
    {
        if (b.NoBattery) return "Mains-powered and unbothered.";
        if (b.IsFullyCharged) return "Topped off. Free to roam.";
        if (b.IsCharging)
        {
            if (b.Percent >= 90) return "Almost there.";
            if (b.Percent >= 0 && b.Percent < 30) return "Inhaling electrons.";
            return "Refueling.";
        }
        if (b.StatusText == "Plugged In") return "Plugged in, holding steady.";
        int pct = b.Percent;
        if (pct >= 0 && pct <= 10) return "Critically low. Plug in.";
        if (pct >= 0 && pct <= 20) return "Running on fumes.";
        int m = b.TimeMinutes;
        if (m > 0)
        {
            if (m <= 20) return "Find an outlet. Now-ish.";
            if (m <= 45) return "Wrapping-up territory.";
            if (m >= 480) return "All-day battery. Go do things.";
            if (m >= 300) return "Hours of runway left.";
            if (m >= 120) return "Plenty in the tank.";
            return "Cruising. Keep an eye out.";
        }
        return "";
    }

    public static Rgb StatusColor(string status) => status switch
    {
        "Fully Charged" => new(0, 200, 0),
        "Charging" => new(255, 200, 0),
        "Critical" => new(255, 0, 0),
        "Low" => new(255, 165, 0),
        "No Battery" => new(128, 128, 128),
        _ => new(0, 180, 255),
    };

    /// <summary>The pill's fill color: level bands first, the user's accent above 50%.</summary>
    public static Rgb AccentColor(int percent, bool isCharging, int accentIndex, bool lightPill)
    {
        if (percent < 0) return new(120, 130, 140);
        if (isCharging) return new(255, 200, 0);
        if (percent <= 10) return new(255, 70, 70);
        if (percent <= 20) return new(255, 140, 0);
        if (percent <= 50) return new(255, 200, 0);
        int idx = Math.Clamp(accentIndex, 0, 7);
        // White on a light pill would vanish: a graphite instead
        if (idx == 7 && lightPill) return new(90, 95, 105);
        return AccentPresets[idx];
    }

    public static Rgb PowerBandColor(double watts) => watts switch
    {
        < 13 => new(45, 212, 100),
        < 25 => new(255, 200, 0),
        < 45 => new(255, 140, 0),
        _ => new(255, 70, 70),
    };

    /// <summary>The flyout's big percent: the status color, darkened on a light card.</summary>
    public static Rgb HeroPercentColor(string status, bool lightCard) =>
        lightCard ? StatusColor(status).Scale(0.62) : StatusColor(status);
}
