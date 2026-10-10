using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace BatteryPill.Core;

/// <param name="Error">Null on success (including "no file yet").</param>
public sealed record ConfigLoadResult(AppConfig Config, string? Error = null, string? BackupPath = null);

/// <summary>
/// Reads and writes BatteryWidget.config.json in the exact format the PowerShell
/// app uses, so an existing user's position, theme and history carry over.
/// Port of src\080-config.ps1. One bad field costs only that field; a file that
/// cannot be read at all is kept as .corrupt rather than silently overwritten.
/// </summary>
public static partial class ConfigStore
{
    public const int SavedHistoryCount = 200;
    private static readonly TimeSpan EstimatorStateMaxAge = TimeSpan.FromMinutes(10);

    [GeneratedRegex(@"^\d{1,9}\.\d{1,9}\.\d{1,9}$")]
    private static partial Regex VersionPattern();

    public static ConfigLoadResult Load(string path, DateTime now)
    {
        var config = new AppConfig();
        if (!File.Exists(path)) return new ConfigLoadResult(config);
        try
        {
            string raw = ReadTextShared(path);
            // An empty file is "no settings", not corruption
            if (string.IsNullOrWhiteSpace(raw)) return new ConfigLoadResult(config);
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("the settings file is not a JSON object");
            Apply(doc.RootElement, config, now);
            return new ConfigLoadResult(config);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        {
            // This file IS the user's setup. Keep a copy of what could not be read
            // before the next save overwrites the only one.
            string backup = path + ".corrupt";
            try { File.Copy(path, backup, overwrite: true); }
            catch (Exception copyErr) when (copyErr is IOException or UnauthorizedAccessException) { backup = ""; }
            return new ConfigLoadResult(new AppConfig(), e.Message, backup.Length > 0 ? backup : null);
        }
    }

    private static void Apply(JsonElement root, AppConfig c, DateTime now)
    {
        object? Field(string name) => root.TryGetProperty(name, out var e) ? ToRaw(e) : null;

        // Position is a pair: take it only if BOTH coordinates parse
        int? x = ParseInt(Field("X")), y = ParseInt(Field("Y"));
        if (x is int xv && y is int yv) { c.X = xv; c.Y = yv; }

        // NaN survives a clamp (every comparison against NaN is false): reject it first
        if (ParseDouble(Field("Opacity")) is double o && !double.IsNaN(o)) c.Opacity = Math.Clamp(o, 0.3, 1.0);
        // 0/negative would mean a WMI query 10x a second
        if (ParseInt(Field("RefreshInterval")) is int ri) c.RefreshInterval = Math.Clamp(ri, 1000, 60000);
        c.PositionLocked = ParseBool(Field("PositionLocked")) ?? c.PositionLocked;
        c.DisplayMode = OneOf(Field("DisplayMode"), AppConfig.DisplayModes) ?? c.DisplayMode;
        c.PillSize = OneOf(Field("PillSize"), AppConfig.PillSizes) ?? c.PillSize;
        c.Theme = OneOf(Field("Theme"), AppConfig.Themes) ?? c.Theme;
        if (ParseInt(Field("AccentColorIndex")) is int ai) c.AccentColorIndex = Math.Clamp(ai, 0, 7);
        c.AutoHideFullscreen = ParseBool(Field("AutoHideFullscreen")) ?? c.AutoHideFullscreen;
        c.FirstRunShown = ParseBool(Field("FirstRunShown")) ?? c.FirstRunShown;
        c.FunLines = ParseBool(Field("FunLines")) ?? c.FunLines;
        c.Animations = ParseBool(Field("Animations")) ?? c.Animations;
        c.CheckForUpdates = ParseBool(Field("CheckForUpdates")) ?? c.CheckForUpdates;
        // Unparseable just means "check soon"
        c.LastUpdateCheck = ParseRoundTripDate(Field("LastUpdateCheck"));
        c.AnnouncedVersion = Field("AnnouncedVersion") is string av && VersionPattern().IsMatch(av) ? av : null;

        if (root.TryGetProperty("BatteryHistory", out var hist) && hist.ValueKind == JsonValueKind.Array)
        {
            var loaded = new List<HistorySample>();
            foreach (var entry in hist.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object) continue;
                object? E(string name) => entry.TryGetProperty(name, out var v) ? ToRaw(v) : null;
                if (ParseInt(E("Percent")) is not int pct || pct < 0 || pct > 100) continue;
                if (E("Time") is not string ts || !DateTime.TryParse(ts, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time)) continue;
                // Watts arrived with v1.4.0: a missing or bad value costs the number, not the entry
                double watts = ParseDouble(E("Watts")) is double w && !double.IsNaN(w) && w > 0 ? w : -1;
                loaded.Add(new HistorySample(time, pct, Truthy(E("IsCharging")), Truthy(E("IsPluggedIn")), watts));
            }
            if (loaded.Count > BatteryHistory.Capacity) loaded = loaded.GetRange(loaded.Count - BatteryHistory.Capacity, BatteryHistory.Capacity);
            c.BatteryHistory = loaded;
        }

        // Estimator state: only from a file saved in the last 10 minutes
        if (ParseDouble(Field("EmaRate")) is double ema && ParseRoundTripDate(Field("ConfigSavedAt")) is DateTime savedAt)
        {
            // A stamp with no offset is local time (never shifted as if it were UTC)
            DateTime savedLocal = savedAt.Kind == DateTimeKind.Utc ? savedAt.ToLocalTime() : savedAt;
            if (now - savedLocal < EstimatorStateMaxAge)
            {
                c.EmaRate = ema;
                c.LastValidRate = ParseInt(Field("LastValidRate")) ?? -1;
                c.EmaWasPluggedIn = ParseBool(Field("EmaWasPluggedIn"));
            }
        }
    }

    /// <summary>
    /// Write the config atomically: readers only ever see the complete old file or
    /// the complete new one (a launching instance reads while the running one saves).
    /// </summary>
    public static void Save(string path, AppConfig c, IReadOnlyList<HistorySample> history, TimeEstimator estimator, DateTime now)
    {
        var o = new Dictionary<string, object?>
        {
            ["X"] = c.X,
            ["Y"] = c.Y,
            ["Opacity"] = c.Opacity,
            ["RefreshInterval"] = c.RefreshInterval,
            ["PositionLocked"] = c.PositionLocked,
            ["DisplayMode"] = c.DisplayMode,
            ["PillSize"] = c.PillSize,
            ["Theme"] = c.Theme,
            ["AccentColorIndex"] = c.AccentColorIndex,
            ["AutoHideFullscreen"] = c.AutoHideFullscreen,
            ["FirstRunShown"] = c.FirstRunShown,
            ["FunLines"] = c.FunLines,
            ["Animations"] = c.Animations,
            ["CheckForUpdates"] = c.CheckForUpdates,
            ["LastUpdateCheck"] = c.LastUpdateCheck?.ToString("o", CultureInfo.InvariantCulture),
            ["AnnouncedVersion"] = c.AnnouncedVersion,
            ["BatteryHistory"] = history.Skip(Math.Max(0, history.Count - SavedHistoryCount)).Select(h => new Dictionary<string, object?>
            {
                ["Time"] = h.Time.ToString("o", CultureInfo.InvariantCulture),
                ["Percent"] = h.Percent,
                ["IsCharging"] = h.IsCharging,
                ["IsPluggedIn"] = h.IsPluggedIn,
                ["Watts"] = h.Watts,
            }).ToList(),
            ["EmaRate"] = estimator.EmaRate,
            ["LastValidRate"] = estimator.LastValidRate,
            ["EmaWasPluggedIn"] = estimator.LastAcState,
            ["ConfigSavedAt"] = now.ToString("o", CultureInfo.InvariantCulture),
        };
        WriteTextAtomic(path, JsonSerializer.Serialize(o, new JsonSerializerOptions { WriteIndented = true }));
    }

    // ---- field parsing (PowerShell-compatible tolerance) ----

    private static object? ToRaw(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Number => e.GetDouble(),
        JsonValueKind.String => e.GetString(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    };

    internal static double? ParseDouble(object? raw) => raw switch
    {
        double d => d,
        string s when double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) => v,
        _ => null,
    };

    internal static int? ParseInt(object? raw)
    {
        if (ParseDouble(raw) is not double d || double.IsNaN(d) || d < int.MinValue || d > int.MaxValue) return null;
        return (int)Math.Round(d, MidpointRounding.ToEven);
    }

    /// <summary>
    /// Real booleans, numbers, and the obvious string spellings; null ("no
    /// reading", so the default stands) for anything else. A hand-edited "false"
    /// must not turn a setting ON.
    /// </summary>
    internal static bool? ParseBool(object? raw) => raw switch
    {
        bool b => b,
        double d when !double.IsNaN(d) => d != 0,
        string s => s.Trim().ToLowerInvariant() switch
        {
            "true" or "yes" or "1" => true,
            "false" or "no" or "0" => false,
            _ => null,
        },
        _ => null,
    };

    private static bool Truthy(object? raw) => ParseBool(raw) ?? false;

    private static string? OneOf(object? raw, string[] allowed)
    {
        if (raw is not string s) return null;
        string v = s.Trim().ToLowerInvariant();
        return Array.IndexOf(allowed, v) >= 0 ? v : null;
    }

    private static DateTime? ParseRoundTripDate(object? raw) =>
        raw is string s && DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var d) ? d : null;

    // ---- file I/O ----

    /// <summary>
    /// Read the whole file, tolerating a writer mid-swap: open with
    /// FileShare.Delete so a pending rename is not blocked by this read, and retry
    /// a locked file briefly before calling it a failure.
    /// </summary>
    internal static string ReadTextShared(string path, int attempts = 12)
    {
        IOException? last = null;
        for (int attempt = 1; attempt <= attempts; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream, detectEncodingFromByteOrderMarks: true);
                return reader.ReadToEnd();
            }
            catch (IOException e) when (e is not FileNotFoundException and not DirectoryNotFoundException)
            {
                last = e;
                Thread.Sleep(5 * attempt);
            }
        }
        throw last!;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool MoveFileEx(string existing, string replacement, uint flags);

    /// <summary>
    /// Sibling temp file, then ONE MoveFileEx(MOVEFILE_REPLACE_EXISTING): the
    /// directory entry always points at a complete file. (File.Replace detaches
    /// the old file before attaching the new one: a concurrent reader can see no
    /// file at all and treat it as first run.) A transient sharing violation from
    /// a reader or a scanner is retried.
    /// </summary>
    internal static void WriteTextAtomic(string path, string content, int attempts = 12)
    {
        string dir = Path.GetDirectoryName(Path.GetFullPath(path)) ?? ".";
        Directory.CreateDirectory(dir);
        // Same directory as the target: a rename is only atomic within one volume
        string tmp = Path.Combine(dir, $".{Path.GetFileName(path)}.{Guid.NewGuid().ToString("N")[..8]}.tmp");
        // No BOM: byte-compatible with what the PowerShell app writes
        File.WriteAllText(tmp, content, new UTF8Encoding(false));
        try
        {
            Win32Exception? last = null;
            for (int attempt = 1; attempt <= attempts; attempt++)
            {
                if (MoveFileEx(tmp, path, 0x1)) return;
                last = new Win32Exception(Marshal.GetLastWin32Error());
                Thread.Sleep(5 * attempt);
            }
            throw new IOException(last!.Message, last);
        }
        finally
        {
            // Never leave debris next to the user's config
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
