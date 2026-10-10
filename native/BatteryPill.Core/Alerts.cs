namespace BatteryPill.Core;

public enum AlertKind { Charging, Full, Low, Critical }

public sealed record Alert(AlertKind Kind, string Title, string Body);

/// <summary>
/// When to tell the user something about the battery: once each, never nagging.
/// Port of the card logic in Update-FloatingBar (src\110-floating-bar.ps1):
/// a "Charging - full by" card once a fresh plug-in is confirmed charging with an
/// ETA (given up after 45 s), "Fully charged" once per plug-in, and low (10%) and
/// critical (5%) warnings once each per discharge, re-armed by plugging in.
/// </summary>
public sealed class AlertPlanner
{
    public static readonly TimeSpan PlugCardPatience = TimeSpan.FromSeconds(45);

    private bool? _lastPlugged;
    private DateTime? _plugCardPending;
    private bool _wasFull;
    private bool _fullShown;
    private bool _hadReading;
    private bool _low10Shown;
    private bool _low5Shown;

    /// <param name="now">Local time.</param>
    public IReadOnlyList<Alert> Next(BatteryInfo b, DateTime now)
    {
        var alerts = new List<Alert>();

        if (_lastPlugged is bool was && was != b.IsPluggedIn && b.IsPluggedIn && !b.NoBattery && !b.IsFullyCharged)
            _plugCardPending = now;
        _lastPlugged = b.IsPluggedIn;

        if (_plugCardPending is DateTime since)
        {
            if (!b.IsPluggedIn || b.IsFullyCharged) _plugCardPending = null;
            else if (b.IsCharging && b.TimeMinutes > 0 && b.ETA.Length > 0)
            {
                _plugCardPending = null;
                alerts.Add(new Alert(AlertKind.Charging, "Charging", $"Full by {b.ETA}"));
            }
            else if (now - since > PlugCardPatience) _plugCardPending = null;
        }

        // A launch already full is not news: only a transition into full is
        if (b.IsFullyCharged && b.IsPluggedIn && !_wasFull && _hadReading && !_fullShown)
        {
            _fullShown = true;
            alerts.Add(new Alert(AlertKind.Full, "Fully charged", "Battery at 100% - free to unplug"));
        }
        _wasFull = b.IsFullyCharged;
        if (!b.IsPluggedIn) _fullShown = false;
        _hadReading = true;

        if (b.IsPluggedIn || b.IsCharging)
        {
            _low10Shown = false;
            _low5Shown = false;
        }
        else if (b.Percent >= 0)
        {
            int pct = b.Percent;
            if (pct <= 10 && pct > 5 && !_low10Shown)
            {
                _low10Shown = true;
                alerts.Add(new Alert(AlertKind.Low, $"Low Battery - {pct}%", "Connect charger soon"));
            }
            if (pct <= 5 && !_low5Shown)
            {
                _low5Shown = true;
                alerts.Add(new Alert(AlertKind.Critical, $"Critical Battery - {pct}%",
                    b.TimeMinutes > 0 ? $"{b.TimeMinutes} min remaining" : "Very low battery"));
            }
        }
        return alerts;
    }
}
