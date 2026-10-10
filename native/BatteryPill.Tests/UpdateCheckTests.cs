using System.Text.Json;
using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of tests\UpdateCheck.Tests.ps1.
public class UpdateCheckTests
{
    private static string ReleaseJson(string tag = "v1.5.0", string url = "https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0",
        bool draft = false, bool prerelease = false) =>
        JsonSerializer.Serialize(new { tag_name = tag, html_url = url, draft, prerelease, name = $"BatteryPill {tag}" });

    [Fact] public void AVPrefixedTagParses() => Assert.Equal("1.4.1", UpdateCheck.ParseVersion("v1.4.1")!.ToString(3));

    [Fact]
    public void TwoPartsArePadded()
    {
        Assert.False(UpdateCheck.IsNewer("1.4", "v1.4.0"));
        Assert.False(UpdateCheck.IsNewer("1.4.0", "v1.4"));
    }

    [Fact]
    public void ComparedAsNumbersNotText()
    {
        Assert.True(UpdateCheck.IsNewer("1.9.0", "v1.10.0"));
        Assert.False(UpdateCheck.IsNewer("1.10.0", "v1.9.9"));
    }

    [Fact]
    public void OnlyAStrictlyNewerReleaseCounts()
    {
        Assert.True(UpdateCheck.IsNewer("1.4.0", "v1.4.1"));
        Assert.False(UpdateCheck.IsNewer("1.4.0", "v1.4.0"));
        Assert.False(UpdateCheck.IsNewer("1.4.0", "v1.3.3"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("latest")]
    [InlineData("v1.5.0-beta")]
    [InlineData("1.5.0.1.2")]
    [InlineData("v")]
    [InlineData("1..2")]
    [InlineData("99999999999.0.0")]
    public void ATagThatIsNotAVersionIsNeverAnUpdate(string junk)
    {
        Assert.Null(UpdateCheck.ParseVersion(junk));
        Assert.False(UpdateCheck.IsNewer("1.4.0", junk));
    }

    [Fact]
    public void NonAsciiDigitsAreNotAVersionAndDoNotThrow()
    {
        Assert.Null(UpdateCheck.ParseVersion("\u0661.\u0662.\u0663"));
        Assert.Null(UpdateCheck.ParseRelease(ReleaseJson(tag: "v\u0661.\u0662.\u0663")));
        Assert.Null(UpdateCheck.RestoreAvailability("1.4.0", "\u0661.\u0662.\u0663"));
    }

    [Fact]
    public void ANormalResponseYieldsVersionAndPage()
    {
        var r = UpdateCheck.ParseRelease(ReleaseJson())!;
        Assert.Equal("1.5.0", r.Version);
        Assert.Equal("https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0", r.Url);
    }

    [Fact]
    public void DraftsAndPrereleasesAreNotOffered()
    {
        Assert.Null(UpdateCheck.ParseRelease(ReleaseJson(draft: true)));
        Assert.Null(UpdateCheck.ParseRelease(ReleaseJson(prerelease: true)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("<html>502</html>")]
    [InlineData("{\"message\":\"API rate limit exceeded\"}")]
    [InlineData("[1,2]")]
    [InlineData("null")]
    [InlineData("{")]
    public void MalformedResponsesMeanNoAnswer(string bad) => Assert.Null(UpdateCheck.ParseRelease(bad));

    [Fact]
    public void ALinkOutsideThisRepoFallsBackToTheWebsite()
    {
        Assert.Equal("https://batterypill.com", UpdateCheck.ParseRelease(ReleaseJson(url: "https://example.com/totally-batterypill.exe"))!.Url);
        Assert.Equal("https://batterypill.com", UpdateCheck.ParseRelease(ReleaseJson(url: "http://github.com/nobackhand/checkbattery/releases/tag/v1.5.0"))!.Url);
    }

    private static readonly DateTime Now = new(2026, 10, 9, 9, 0, 0);

    [Fact] public void NeverCheckedMeansCheckNow() => Assert.True(UpdateCheck.IsDue(null, Now));

    [Fact]
    public void OnceADay()
    {
        Assert.False(UpdateCheck.IsDue(Now.AddHours(-23), Now));
        Assert.True(UpdateCheck.IsDue(Now.AddHours(-24), Now));
    }

    [Fact] public void AStampInTheFutureChecksNow() => Assert.True(UpdateCheck.IsDue(Now.AddDays(3), Now));

    private static readonly ReleaseInfo V150 = new("1.5.0", "u");

    [Fact]
    public void ANewerReleaseIsAnnouncedOnce()
    {
        var first = UpdateCheck.Resolve(V150, "1.4.0", null);
        Assert.Equal(UpdateState.Available, first.State);
        Assert.True(first.Notify);
        var again = UpdateCheck.Resolve(V150, "1.4.0", "1.5.0");
        Assert.Equal(UpdateState.Available, again.State);
        Assert.False(again.Notify);
    }

    [Fact] public void AReleaseNewerThanTheAnnouncedOneIsAnnounced() => Assert.True(UpdateCheck.Resolve(new("1.6.0", "u"), "1.4.0", "1.5.0").Notify);

    [Fact]
    public void UpToDateAndFailedBothStayQuiet()
    {
        var cur = UpdateCheck.Resolve(new("1.4.0", "u"), "1.4.0", null);
        Assert.Equal(UpdateState.Current, cur.State);
        Assert.False(cur.Notify);
        var fail = UpdateCheck.Resolve(null, "1.4.0", null);
        Assert.Equal(UpdateState.Failed, fail.State);
        Assert.False(fail.Notify);
    }

    [Fact]
    public void AnUpToDateAnswerWithdrawsAnEarlierAnnouncement()
    {
        Assert.Null(UpdateCheck.Resolve(new("1.4.0", "u"), "1.4.0", "1.5.0").Announced);
        Assert.Equal("1.5.0", UpdateCheck.Resolve(V150, "1.4.0", null).Announced);
    }

    [Fact]
    public void NoResponseRetriesSoonAnUnusableOneCountsAsChecked()
    {
        var off = UpdateCheck.Resolve(null, "1.4.0", "1.5.0", received: false);
        Assert.False(off.Stamp);
        Assert.Equal("1.5.0", off.Announced);
        var junk = UpdateCheck.Resolve(null, "1.4.0", null, received: true);
        Assert.Equal(UpdateState.Failed, junk.State);
        Assert.True(junk.Stamp);
    }

    [Fact] public void ADevBuildAheadOfTheLatestIsUpToDate() => Assert.Equal(UpdateState.Current, UpdateCheck.Resolve(new("1.4.0", "u"), "1.4.1", null).State);

    [Fact]
    public void TheAboutLineSaysWhatTheLastCheckFound()
    {
        Assert.Equal("Version 1.4.0", UpdateCheck.AboutVersionText("1.4.0", UpdateState.Idle, null));
        Assert.Equal("Version 1.4.0", UpdateCheck.AboutVersionText("1.4.0", UpdateState.Failed, null));
        Assert.Equal("Version 1.4.0 - up to date", UpdateCheck.AboutVersionText("1.4.0", UpdateState.Current, null));
        Assert.Equal("Version 1.4.0 - 1.5.0 is available", UpdateCheck.AboutVersionText("1.4.0", UpdateState.Available, V150));
    }

    [Fact]
    public void AnOfflineCheckDoesNotHideAnOffer() =>
        Assert.Equal("Version 1.4.0 - 1.5.0 is available", UpdateCheck.AboutVersionText("1.4.0", UpdateState.Failed, V150));

    [Fact]
    public void AnAnnouncedReleaseStillNewerStaysOnOfferAfterRestart()
    {
        var r = UpdateCheck.RestoreAvailability("1.4.0", "1.5.0")!;
        Assert.Equal("1.5.0", r.Version);
        Assert.StartsWith("https://github.com/nobackhand/checkbattery/releases/", r.Url);
    }

    [Fact]
    public void OnceUpgradedNothingIsOffered()
    {
        Assert.Null(UpdateCheck.RestoreAvailability("1.5.0", "1.5.0"));
        Assert.Null(UpdateCheck.RestoreAvailability("1.4.0", null));
        Assert.Null(UpdateCheck.RestoreAvailability("1.4.0", "garbage"));
    }
}
