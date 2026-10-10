using System.Runtime.InteropServices;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace BatteryPill;

/// <summary>
/// Battery alerts as real Windows notifications: they land in the notification
/// center and respect Do Not Disturb and game mode on their own - nothing pops
/// over a fullscreen game. If Windows refuses the registration, alerts are
/// simply skipped (the pill still shows the state).
/// </summary>
internal static class Notifier
{
    private static bool _ready;

    public static void Init()
    {
        try
        {
            // Subscribe before registering, or clicking a notification would
            // start a second process instead of reaching this one
            AppNotificationManager.Default.NotificationInvoked += (_, _) => { };
            AppNotificationManager.Default.Register();
            _ready = true;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            Trace.Log("notifications unavailable: " + e.Message);
        }
    }

    /// <param name="urgent">
    /// The 5% warning: shown as Windows' "important" (urgent) notification where
    /// supported, so Do Not Disturb does not swallow the last chance to plug in.
    /// </param>
    public static void Show(string title, string body, bool urgent = false)
    {
        if (!_ready) return;
        try
        {
            var builder = new AppNotificationBuilder().AddText(title).AddText(body);
            if (urgent && AppNotificationBuilder.IsUrgentScenarioSupported()) builder.SetScenario(AppNotificationScenario.Urgent);
            AppNotificationManager.Default.Show(builder.BuildNotification());
            Trace.Log($"notified: {title} / {body}");
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            Trace.Log("notify failed: " + e.Message);
        }
    }

    public static void Shutdown()
    {
        if (!_ready) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch (Exception e) when (e is COMException or InvalidOperationException) { }
    }
}
