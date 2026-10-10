using System.Text;
using BatteryPill.Core;

namespace BatteryPill.Tests;

// Ports of tests\ConfigRoundTrip.Tests.ps1 and the config boundaries of
// tests\Adversarial.Tests.ps1, plus cross-compatibility with the file the
// PowerShell app writes.
public sealed class ConfigTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "batterypill-cfgtest-" + Guid.NewGuid().ToString("N"));
    private readonly string _path;
    private static readonly DateTime Now = new DateTime(2026, 10, 10, 12, 0, 0, DateTimeKind.Local);

    public ConfigTests()
    {
        Directory.CreateDirectory(_dir);
        _path = Path.Combine(_dir, "BatteryWidget.config.json");
    }

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private ConfigLoadResult LoadText(string text)
    {
        File.WriteAllText(_path, text, new UTF8Encoding(false));
        return ConfigStore.Load(_path, Now);
    }

    private static AppConfig FullConfig() => new()
    {
        X = 1234, Y = 567, Opacity = 0.42, RefreshInterval = 5000, PositionLocked = true, DisplayMode = "percent",
        PillSize = "expanded", Theme = "light", AccentColorIndex = 5, AutoHideFullscreen = true, FirstRunShown = true,
        FunLines = false, Animations = false, CheckForUpdates = false,
        LastUpdateCheck = new DateTime(2026, 10, 9, 9, 15, 30), AnnouncedVersion = "1.5.0",
    };

    private static void AssertSameSettings(AppConfig a, AppConfig b)
    {
        Assert.Equal(a.X, b.X);
        Assert.Equal(a.Y, b.Y);
        Assert.Equal(a.Opacity, b.Opacity);
        Assert.Equal(a.RefreshInterval, b.RefreshInterval);
        Assert.Equal(a.PositionLocked, b.PositionLocked);
        Assert.Equal(a.DisplayMode, b.DisplayMode);
        Assert.Equal(a.PillSize, b.PillSize);
        Assert.Equal(a.Theme, b.Theme);
        Assert.Equal(a.AccentColorIndex, b.AccentColorIndex);
        Assert.Equal(a.AutoHideFullscreen, b.AutoHideFullscreen);
        Assert.Equal(a.FirstRunShown, b.FirstRunShown);
        Assert.Equal(a.FunLines, b.FunLines);
        Assert.Equal(a.Animations, b.Animations);
        Assert.Equal(a.CheckForUpdates, b.CheckForUpdates);
        Assert.Equal(a.LastUpdateCheck, b.LastUpdateCheck);
        Assert.Equal(a.AnnouncedVersion, b.AnnouncedVersion);
    }

    private void Save(AppConfig c, TimeEstimator? e = null, IReadOnlyList<HistorySample>? h = null) =>
        ConfigStore.Save(_path, c, h ?? Array.Empty<HistorySample>(), e ?? new TimeEstimator(), Now);

    // ---- round trip ----

    [Fact]
    public void EveryPersistedFieldSurvivesSaveThenLoad()
    {
        var c = FullConfig();
        Save(c);
        var r = ConfigStore.Load(_path, Now);
        Assert.Null(r.Error);
        AssertSameSettings(c, r.Config);
    }

    [Fact]
    public void AFalseBooleanStaysFalse()
    {
        Save(FullConfig());
        var c = ConfigStore.Load(_path, Now).Config;
        Assert.False(c.FunLines);
        Assert.False(c.Animations);
    }

    [Fact]
    public void TwoConsecutiveSavesAreStable()
    {
        Save(FullConfig());
        var first = ConfigStore.Load(_path, Now).Config;
        Save(first);
        AssertSameSettings(first, ConfigStore.Load(_path, Now).Config);
    }

    [Fact]
    public void TheEstimatorStateSurvivesIncludingItsPowerState()
    {
        var e = new TimeEstimator { EmaRate = 13500, LastValidRate = 13000, LastAcState = true };
        Save(FullConfig(), e);
        var c = ConfigStore.Load(_path, Now.AddMinutes(2)).Config;
        Assert.Equal(13500, c.EmaRate);
        Assert.Equal(13000, c.LastValidRate);
        Assert.True(c.EmaWasPluggedIn);
    }

    [Fact]
    public void AFalsePowerStateSurvives()
    {
        Save(FullConfig(), new TimeEstimator { EmaRate = 9000, LastValidRate = 9000, LastAcState = false });
        Assert.False(ConfigStore.Load(_path, Now).Config.EmaWasPluggedIn);
    }

    [Fact]
    public void EstimatorStateOlderThanTenMinutesIsNotRestored()
    {
        Save(FullConfig(), new TimeEstimator { EmaRate = 9000, LastValidRate = 9000, LastAcState = false });
        Assert.Equal(-1, ConfigStore.Load(_path, Now.AddMinutes(11)).Config.EmaRate);
    }

    [Fact]
    public void HistorySurvivesCappedAtThePersisted200()
    {
        var t0 = new DateTime(2026, 8, 30, 12, 0, 0);
        var h = Enumerable.Range(0, 260).Select(i => new HistorySample(t0.AddSeconds(i * 3), 50 + i % 40, i % 7 == 0, false, -1)).ToList();
        Save(FullConfig(), h: h);
        var loaded = ConfigStore.Load(_path, Now).Config.BatteryHistory;
        Assert.Equal(200, loaded.Count);
        Assert.Equal(h[^1].Percent, loaded[^1].Percent);
        Assert.Equal(h[^1].Time, loaded[^1].Time);
    }

    // ---- compatibility ----

    [Fact]
    public void AConfigFromAnOlderBuildLoadsWithDefaults()
    {
        var c = LoadText("{\"X\":100,\"Y\":200,\"Opacity\":0.9,\"RefreshInterval\":3000,\"DisplayMode\":\"both\",\"PillSize\":\"compact\",\"Theme\":\"auto\"}").Config;
        Assert.Equal(100, c.X);
        Assert.Equal("both", c.DisplayMode);
        Assert.Equal("compact", c.PillSize);
        Assert.Equal("auto", c.Theme);
        Assert.True(c.FunLines);
        Assert.True(c.Animations);
        Assert.True(c.CheckForUpdates);
        Assert.Null(c.LastUpdateCheck);
        Assert.Null(c.AnnouncedVersion);
    }

    [Fact]
    public void ANewerBuildsUnknownFieldsStayOutOfTheWay()
    {
        var c = LoadText("{\"X\":300,\"Y\":400,\"DisplayMode\":\"time\",\"FunLines\":false,\"Animations\":true,\"SomeFutureSetting\":\"quantum\",\"AnotherOne\":{\"nested\":true}}").Config;
        Assert.Equal(300, c.X);
        Assert.False(c.FunLines);
        Assert.True(c.Animations);
    }

    [Fact]
    public void ReadsTheFileThePowerShellAppWrites()
    {
        // Shaped exactly like Windows PowerShell 5.1's ConvertTo-Json of Save-Config's hashtable
        const string psFile = """
            {
                "DisplayMode":  "both",
                "AnnouncedVersion":  null,
                "BatteryHistory":  [
                                       {
                                           "IsPluggedIn":  false,
                                           "Watts":  8.2,
                                           "Percent":  71,
                                           "IsCharging":  false,
                                           "Time":  "2026-10-10T11:55:00.1234567-05:00"
                                       },
                                       {
                                           "IsPluggedIn":  true,
                                           "Watts":  -1,
                                           "Percent":  71,
                                           "IsCharging":  true,
                                           "Time":  "2026-10-10T11:58:00.1234567-05:00"
                                       }
                                   ],
                "EmaWasPluggedIn":  false,
                "Opacity":  0.85,
                "X":  3412,
                "Theme":  "auto",
                "FirstRunShown":  true,
                "ConfigSavedAt":  "2026-10-10T11:58:30.0000000-05:00",
                "PillSize":  "normal",
                "LastValidRate":  9000,
                "CheckForUpdates":  true,
                "AccentColorIndex":  2,
                "Animations":  true,
                "LastUpdateCheck":  "2026-10-10T09:00:00.0000000",
                "Y":  1934,
                "PositionLocked":  false,
                "AutoHideFullscreen":  true,
                "RefreshInterval":  3000,
                "EmaRate":  9123.4,
                "FunLines":  true
            }
            """;
        var r = LoadText(psFile);
        Assert.Null(r.Error);
        var c = r.Config;
        Assert.Equal((3412, 1934), (c.X, c.Y));
        Assert.Equal("both", c.DisplayMode);
        Assert.Equal("auto", c.Theme);
        Assert.Equal(2, c.AccentColorIndex);
        Assert.True(c.AutoHideFullscreen);
        Assert.Equal(new DateTime(2026, 10, 10, 9, 0, 0), c.LastUpdateCheck);
        Assert.Equal(2, c.BatteryHistory.Count);
        Assert.Equal(8.2, c.BatteryHistory[0].Watts);
        Assert.True(c.BatteryHistory[1].IsCharging);
        Assert.True(c.BatteryHistory[1].IsPluggedIn);
        Assert.Equal(-1, c.BatteryHistory[1].Watts);
    }

    // ---- boundaries ----

    [Fact]
    public void AWellFormedConfigLoadsEveryField()
    {
        var r = LoadText("{\"X\":10,\"Y\":20,\"Opacity\":0.5,\"RefreshInterval\":5000,\"Theme\":\"light\",\"PillSize\":\"compact\",\"DisplayMode\":\"percent\",\"AccentColorIndex\":3}");
        Assert.Null(r.Error);
        Assert.Equal(10, r.Config.X);
        Assert.Equal(0.5, r.Config.Opacity);
        Assert.Equal("light", r.Config.Theme);
        Assert.Equal("compact", r.Config.PillSize);
        Assert.Equal(3, r.Config.AccentColorIndex);
    }

    [Fact]
    public void EveryWrongTypedFieldFallsBackFieldByField()
    {
        var c = LoadText("{\"X\":\"left\",\"Y\":{\"a\":1},\"Opacity\":\"opaque\",\"RefreshInterval\":[1,2],\"PositionLocked\":\"maybe\",\"DisplayMode\":42,\"PillSize\":true,\"Theme\":[\"dark\"],\"AccentColorIndex\":\"blue\",\"AutoHideFullscreen\":\"sometimes\"}").Config;
        Assert.Equal(-1, c.X);
        Assert.Equal(0.85, c.Opacity);
        Assert.Equal(3000, c.RefreshInterval);
        Assert.Equal("time", c.DisplayMode);
        Assert.Equal("normal", c.PillSize);
        Assert.Equal("dark", c.Theme);
        Assert.Equal(0, c.AccentColorIndex);
        Assert.False(c.PositionLocked);
        Assert.False(c.AutoHideFullscreen);
    }

    [Fact]
    public void UnlistedEnumValuesFallBack()
    {
        var c = LoadText("{\"Theme\":\"neon\",\"PillSize\":\"gigantic\",\"DisplayMode\":\"morse\"}").Config;
        Assert.Equal("dark", c.Theme);
        Assert.Equal("normal", c.PillSize);
        Assert.Equal("time", c.DisplayMode);
    }

    [Fact]
    public void OutOfRangeNumbersAreClamped()
    {
        var c = LoadText("{\"Opacity\":99,\"RefreshInterval\":1,\"AccentColorIndex\":9999}").Config;
        Assert.Equal(1.0, c.Opacity);
        Assert.Equal(1000, c.RefreshInterval);
        Assert.Equal(7, c.AccentColorIndex);
    }

    [Fact]
    public void NegativeIntervalsCannotBecomeAWmiStorm()
    {
        var c = LoadText("{\"RefreshInterval\":-5,\"Opacity\":-3}").Config;
        Assert.Equal(1000, c.RefreshInterval);
        Assert.Equal(0.3, c.Opacity);
    }

    [Fact]
    public void AnOpacityOfNaNNeverReachesTheWindow()
    {
        var c = LoadText("{\"Opacity\":\"NaN\"}").Config;
        Assert.False(double.IsNaN(c.Opacity));
        Assert.InRange(c.Opacity, 0.3, 1.0);
    }

    [Fact] public void AnOpacityOfInfinityIsClamped() => Assert.InRange(LoadText("{\"Opacity\":\"Infinity\"}").Config.Opacity, 0.3, 1.0);

    [Fact]
    public void ANumberTooLargeForAnIntFallsBack()
    {
        var c = LoadText("{\"X\":1e100,\"Y\":1e100,\"RefreshInterval\":1e100,\"AccentColorIndex\":1e100}").Config;
        Assert.Equal(-1, c.X);
        Assert.Equal(3000, c.RefreshInterval);
        Assert.Equal(0, c.AccentColorIndex);
    }

    [Fact]
    public void AHalfWrittenPositionIsIgnored()
    {
        var c = LoadText("{\"X\":400}").Config;
        Assert.Equal((-1, -1), (c.X, c.Y));
    }

    [Fact]
    public void TruncatedJsonDegradesToDefaultsReportsAndKeepsACopy()
    {
        var r = LoadText("{\"Theme\":\"light\",\"X\":");
        Assert.Equal("dark", r.Config.Theme);
        Assert.NotNull(r.Error);
        Assert.NotNull(r.BackupPath);
        Assert.Equal("{\"Theme\":\"light\",\"X\":", File.ReadAllText(r.BackupPath!));
    }

    [Theory]
    [InlineData("[1,2,3]")]
    [InlineData("\"just a string\"")]
    [InlineData("")]
    [InlineData("{}")]
    public void OddButHarmlessFilesYieldDefaults(string text)
    {
        var c = LoadText(text).Config;
        Assert.Equal("dark", c.Theme);
        Assert.Equal(3000, c.RefreshInterval);
        Assert.Equal(0.85, c.Opacity);
        Assert.Empty(c.BatteryHistory);
    }

    [Fact] public void HistoryHoldingAScalarDoesNotCrash() => Assert.Empty(LoadText("{\"BatteryHistory\":5}").Config.BatteryHistory);

    [Fact]
    public void JunkHistoryEntriesAreDroppedGoodOnesKept()
    {
        var c = LoadText("{\"BatteryHistory\":[" +
            "{\"Time\":\"2026-07-29T08:00:00\",\"Percent\":50,\"IsCharging\":false}," +
            "{\"Time\":\"not a date\",\"Percent\":50,\"IsCharging\":false}," +
            "{\"Time\":\"2026-07-29T08:01:00\",\"Percent\":900,\"IsCharging\":false}," +
            "{\"Time\":\"2026-07-29T08:02:00\",\"Percent\":-5,\"IsCharging\":false}," +
            "{\"Time\":\"2026-07-29T08:03:00\",\"Percent\":\"half\",\"IsCharging\":false}," +
            "{\"Time\":\"2026-07-29T08:04:00\",\"Percent\":70,\"IsCharging\":true}]}").Config;
        Assert.Equal(2, c.BatteryHistory.Count);
        Assert.Equal(50, c.BatteryHistory[0].Percent);
        Assert.Equal(70, c.BatteryHistory[1].Percent);
    }

    [Fact]
    public void AnOversizedHistoryIsCapped()
    {
        string entries = string.Join(",", Enumerable.Repeat("{\"Time\":\"2026-07-29T08:00:00\",\"Percent\":50,\"IsCharging\":false}", 3000));
        Assert.Equal(2400, LoadText("{\"BatteryHistory\":[" + entries + "]}").Config.BatteryHistory.Count);
    }

    [Fact]
    public void EstimatorStateWithAJunkTimestampIsDiscarded()
    {
        var c = LoadText("{\"EmaRate\":12000,\"LastValidRate\":12000,\"ConfigSavedAt\":\"whenever\"}").Config;
        Assert.Equal(-1, c.EmaRate);
        Assert.Equal(-1, c.LastValidRate);
    }

    [Fact]
    public void UpdateFieldJunkFallsBackWithoutCostingOtherSettings()
    {
        var c = LoadText("{\"X\":100,\"Y\":200,\"LastUpdateCheck\":\"not a date\",\"AnnouncedVersion\":\"v1.5.0-beta\",\"CheckForUpdates\":\"maybe\"}").Config;
        Assert.Null(c.LastUpdateCheck);
        Assert.Null(c.AnnouncedVersion);
        Assert.True(c.CheckForUpdates);
        Assert.Equal(100, c.X);
    }

    [Theory]
    [InlineData("\"false\"", false)]
    [InlineData("\"FALSE\"", false)]
    [InlineData("\"no\"", false)]
    [InlineData("0", false)]
    [InlineData("\"true\"", true)]
    [InlineData("\"yes\"", true)]
    [InlineData("1", true)]
    public void BooleanSpellingsAreReadForWhatTheySay(string raw, bool expected)
    {
        // One field defaults true, the other false: whichever the spelling means,
        // one of them has to move, so a parser that ignored the value would fail
        var c = LoadText("{\"FunLines\":" + raw + ",\"AutoHideFullscreen\":" + raw + "}").Config;
        Assert.Equal(expected, c.FunLines);
        Assert.Equal(expected, c.AutoHideFullscreen);
    }

    [Fact]
    public void AMissingFileIsFirstRunNotAnError()
    {
        var r = ConfigStore.Load(Path.Combine(_dir, "nope.json"), Now);
        Assert.Null(r.Error);
        Assert.Equal(-1, r.Config.X);
    }

    [Fact]
    public void TheSaveLeavesNoTempFilesBehind()
    {
        Save(FullConfig());
        Save(FullConfig());
        Assert.Equal(new[] { "BatteryWidget.config.json" }, Directory.GetFiles(_dir).Select(Path.GetFileName).ToArray());
    }
}
