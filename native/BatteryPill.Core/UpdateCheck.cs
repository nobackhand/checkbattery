using System.Text.Json;
using System.Text.RegularExpressions;

namespace BatteryPill.Core;

public sealed record ReleaseInfo(string Version, string Url);

public enum UpdateState { Idle, Checking, Current, Available, Failed }

/// <param name="Notify">True only the FIRST time a version is seen: the card says it once.</param>
/// <param name="Announced">What AnnouncedVersion should hold afterwards.</param>
/// <param name="Stamp">Whether this counts as today's check.</param>
public sealed record UpdateResult(UpdateState State, bool Notify, string? Announced, bool Stamp);

/// <summary>
/// The decision logic of the once-a-day release check (src\075-update-check.ps1).
/// The request itself lives in the app; everything here is pure.
/// </summary>
public static partial class UpdateCheck
{
    public const string LatestReleaseApi = "https://api.github.com/repos/nobackhand/checkbattery/releases/latest";
    public const string LatestReleasePage = "https://github.com/nobackhand/checkbattery/releases/latest";
    public const string Website = "https://batterypill.com";

    [GeneratedRegex(@"^\d{1,9}(\.\d{1,9}){0,2}$")]
    private static partial Regex DottedVersion();

    [GeneratedRegex(@"^https://github\.com/nobackhand/checkbattery/releases/")]
    private static partial Regex OwnReleasePage();

    /// <summary>
    /// "v1.4.1", "1.4.1", "1.4" become a three-part version; null for anything else.
    /// Always three parts: Version("1.4") is LESS than Version("1.4.0"), so
    /// comparing raw forms would call 1.4.0 an update to 1.4.
    /// </summary>
    public static Version? ParseVersion(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        string t = text.Trim();
        if (t.StartsWith('v') || t.StartsWith('V')) t = t[1..];
        if (!DottedVersion().IsMatch(t)) return null;
        var parts = t.Split('.').Select(int.Parse).ToList();
        while (parts.Count < 3) parts.Add(0);
        return new Version(parts[0], parts[1], parts[2]);
    }

    /// <summary>Strictly newer, and both parse: a tag we cannot read is never an update.</summary>
    public static bool IsNewer(string? current, string? candidate)
    {
        var c = ParseVersion(current);
        var n = ParseVersion(candidate);
        return c is not null && n is not null && n > c;
    }

    /// <summary>
    /// The latest-release response, reduced to what the app acts on; null when it
    /// is not a usable stable release. The URL is only ever this repo's release
    /// page or the website, never an arbitrary link from the response.
    /// </summary>
    public static ReleaseInfo? ParseRelease(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            if (IsTrue(r, "draft") || IsTrue(r, "prerelease")) return null;
            string? tag = r.TryGetProperty("tag_name", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
            var v = ParseVersion(tag);
            if (v is null) return null;
            string? url = r.TryGetProperty("html_url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
            if (url is null || !OwnReleasePage().IsMatch(url)) url = Website;
            return new ReleaseInfo(v.ToString(3), url);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsTrue(JsonElement o, string name) =>
        o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    /// <summary>
    /// Once a day. A failed download is not stamped, so a laptop that boots before
    /// its Wi-Fi is up retries soon. A stamp in the future means the clock moved
    /// backwards (or the stamp is junk): check rather than wait it out.
    /// </summary>
    public static bool IsDue(DateTime? lastCheck, DateTime now, double intervalHours = 24)
    {
        if (lastCheck is null) return true;
        double age = (now - lastCheck.Value).TotalHours;
        return age < 0 || age >= intervalHours;
    }

    /// <param name="received">Whether a response arrived at all (vs offline, timeout, HTTP error).</param>
    public static UpdateResult Resolve(ReleaseInfo? release, string currentVersion, string? announcedVersion, bool received = true)
    {
        // A response with no usable release is stamped too: retrying it every 30
        // minutes forever would not change the answer. Only no-response retries soon.
        if (release is null) return new UpdateResult(UpdateState.Failed, false, announcedVersion, received);
        // 'current' clears the announcement: a release that was announced and then
        // pulled must stop being offered after a restart
        if (!IsNewer(currentVersion, release.Version)) return new UpdateResult(UpdateState.Current, false, null, true);
        return new UpdateResult(UpdateState.Available, announcedVersion != release.Version, release.Version, true);
    }

    /// <summary>
    /// After a restart: a release the card already announced that is still newer
    /// than this build IS the answer. Keep offering it until the user upgrades.
    /// </summary>
    public static ReleaseInfo? RestoreAvailability(string currentVersion, string? announcedVersion) =>
        IsNewer(currentVersion, announcedVersion)
            ? new ReleaseInfo(ParseVersion(announcedVersion)!.ToString(3), LatestReleasePage)
            : null;

    /// <summary>The About dialog's version line. An offer on hand wins over the last check's state.</summary>
    public static string AboutVersionText(string version, UpdateState state, ReleaseInfo? available) =>
        available is not null ? $"Version {version} - {available.Version} is available"
        : state == UpdateState.Current ? $"Version {version} - up to date"
        : $"Version {version}";
}
