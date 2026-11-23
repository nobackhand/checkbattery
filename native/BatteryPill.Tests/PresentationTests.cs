using BatteryPill.Core;

namespace BatteryPill.Tests;

// Ports of tests\Presentation.Tests.ps1 (titles, sentences, fun lines, pill
// text) and the text/pill cases of tests\PowerDraw.Tests.ps1.
public class PresentationTests
{
    private static readonly string Dash = Presentation.EmDash.ToString();

    private static BatteryInfo Reading(int percent = 72, bool charging = false, bool full = false, bool noBattery = false,
        int minutes = 188, string eta = "6:42 PM", bool holding = false, double watts = 8.2,
        PowerDrawKind kind = PowerDrawKind.Draw, PowerDrawSource source = PowerDrawSource.Battery, bool? plugged = null) => new()
    {
        Percent = percent,
        PercentExact = percent,
        IsCharging = charging,
        IsPluggedIn = plugged ?? (charging || full || holding),
        IsFullyCharged = full,
        NoBattery = noBattery,
        StatusText = noBattery ? "No Battery" : full ? "Fully Charged" : charging ? "Charging" : holding ? "Plugged In" : "Discharging",
        TimeMinutes = minutes,
        ETA = eta,
        PowerDraw = new PowerDrawReading(watts, kind, source),
    };

    // ---- titles ----

    [Fact] public void TitleDischargingIsTheDefault() => Assert.Equal("Discharging", Presentation.StateTitle(Reading()));
    [Fact] public void TitleCharging() => Assert.Equal("Charging", Presentation.StateTitle(Reading(charging: true)));
    [Fact] public void TitleFullyChargedOutranksCharging() => Assert.Equal("Fully Charged", Presentation.StateTitle(Reading(charging: true, full: true)));
    [Fact] public void TitleNoBattery() => Assert.Equal("No Battery", Presentation.StateTitle(Reading(noBattery: true)));
    [Fact] public void TitleHoldingIsNotDischarging() => Assert.Equal("Plugged In", Presentation.StateTitle(Reading(60, holding: true, minutes: -1, eta: "")));

    [Fact]
    public void TitleADrainingBatteryOnAWeakChargerIsNotPluggedIn()
    {
        var i = Reading(30, minutes: 40, plugged: true);
        Assert.Equal("Discharging", Presentation.StateTitle(i));
    }

    // ---- time sentence ----

    [Fact] public void TimeSentenceDischarging() => Assert.Equal($"3h 8m left {Dash} 6:42 PM", Presentation.TimeSentence(Reading()));
    [Fact] public void TimeSentenceCharging() => Assert.Equal($"1h 3m to full {Dash} 5:10 PM", Presentation.TimeSentence(Reading(charging: true, minutes: 63, eta: "5:10 PM")));
    [Fact] public void TimeSentenceNoEtaDropsTheDash() => Assert.Equal("3h 8m left", Presentation.TimeSentence(Reading(eta: "")));
    [Fact] public void TimeSentenceFullyCharged() => Assert.Equal("Fully charged", Presentation.TimeSentence(Reading(full: true, minutes: 0, eta: "")));
    [Fact] public void TimeSentenceEstimating() => Assert.Equal("Estimating...", Presentation.TimeSentence(Reading(minutes: -1)));

    // ---- fun lines ----

    private static readonly int[] Bands = { 15, 30, 90, 200, 330, 600 };

    [Fact]
    public void EveryDischargeBandHasALineAndTheyDiffer()
    {
        var lines = Bands.Select(m => Presentation.FunStatusLine(Reading(60, minutes: m))).ToList();
        Assert.All(lines, l => Assert.False(string.IsNullOrWhiteSpace(l)));
        Assert.Equal(6, lines.Distinct().Count());
    }

    [Fact]
    public void TheCriticalBandEndsAtTenPercentExactly()
    {
        Assert.Equal("Critically low. Plug in.", Presentation.FunStatusLine(Reading(10, minutes: 600)));
        Assert.Equal("Running on fumes.", Presentation.FunStatusLine(Reading(11, minutes: 600)));
        Assert.Equal("Running on fumes.", Presentation.FunStatusLine(Reading(20, minutes: 600)));
        Assert.NotEqual("Running on fumes.", Presentation.FunStatusLine(Reading(21, minutes: 600)));
    }

    [Fact]
    public void ChargingAndFullSpeakToo()
    {
        Assert.False(string.IsNullOrWhiteSpace(Presentation.FunStatusLine(Reading(charging: true, minutes: 63))));
        Assert.False(string.IsNullOrWhiteSpace(Presentation.FunStatusLine(Reading(full: true, minutes: 0))));
    }

    [Fact]
    public void UrgencyIsForActuallyLowEstimates() =>
        Assert.NotEqual(Presentation.FunStatusLine(Reading(8, minutes: 12)), Presentation.FunStatusLine(Reading(95, minutes: 600)));

    [Fact]
    public void ALowChargeOutranksALongEstimate() =>
        Assert.DoesNotMatch("All-day|runway|Plenty", Presentation.FunStatusLine(Reading(6, minutes: 600)));

    [Fact]
    public void ADrainingBatteryOnAWeakChargerKeepsItsWarning()
    {
        var i = Reading(8, minutes: 25, plugged: true);
        i.StatusText = "Critical";
        Assert.Equal("Critically low. Plug in.", Presentation.FunStatusLine(i));
    }

    [Fact]
    public void HoldingHasNoRuntimeAnxiety()
    {
        string line = Presentation.FunStatusLine(Reading(18, holding: true, minutes: -1, eta: ""));
        Assert.False(string.IsNullOrWhiteSpace(line));
        Assert.DoesNotMatch("outlet|fumes|Critically", line);
    }

    [Fact]
    public void NoBatteryDoesNotClaimRuntime()
    {
        string line = Presentation.FunStatusLine(Reading(noBattery: true, minutes: -1));
        Assert.False(string.IsNullOrWhiteSpace(line));
        Assert.DoesNotMatch("outlet|fumes", line);
    }

    // ---- pill text ----

    [Fact]
    public void TimeModeShowsTheDurationPercentModeThePercent()
    {
        Assert.Equal("3h 8m", Presentation.PillText(Reading(), "time").Primary);
        Assert.Equal("72%", Presentation.PillText(Reading(), "percent").Primary);
    }

    [Fact] public void BothModeStacksPercentOverTime() => Assert.Equal(new PillText("72%", "3h 8m"), Presentation.PillText(Reading(), "both"));
    [Fact] public void AnUnknownModeFallsBackToTime() => Assert.Equal("3h 8m", Presentation.PillText(Reading(), "nonsense").Primary);

    [Fact]
    public void ADesktopReadsACOnce()
    {
        var i = Reading(noBattery: true, minutes: -1);
        Assert.Equal("AC", Presentation.PillText(i, "time").Primary);
        Assert.Equal(new PillText("AC", ""), Presentation.PillText(i, "both"));
    }

    [Fact]
    public void ARealZeroIsANumber()
    {
        Assert.Equal("0%", Presentation.PillText(Reading(0, minutes: 3), "percent").Primary);
        Assert.Equal("0%", Presentation.PillText(Reading(0, minutes: 3), "both").Primary);
    }

    [Fact]
    public void AnUnreadablePercentShowsDashes()
    {
        Assert.Equal("--", Presentation.PillText(Reading(-1, minutes: -1), "percent").Primary);
        Assert.Equal("--", Presentation.PillText(Reading(-1, minutes: -1), "time").Primary);
    }

    [Fact]
    public void AChargeCappedFullShowsItsRealPercent()
    {
        var i = Reading(60, full: true, minutes: -1, eta: "");
        Assert.Equal("60%", Presentation.PillText(i, "percent").Primary);
        Assert.Equal("Full", Presentation.PillText(i, "time").Primary);
        Assert.Equal(new PillText("60%", "Full"), Presentation.PillText(i, "both"));
    }

    [Fact] public void FullWithNoPercentShowsDashes() => Assert.Equal("--", Presentation.PillText(Reading(-1, full: true, minutes: -1, eta: ""), "percent").Primary);

    [Fact]
    public void AGenuinelyFullBatteryReads100()
    {
        var i = Reading(100, full: true, minutes: -1, eta: "");
        Assert.Equal("100%", Presentation.PillText(i, "percent").Primary);
        Assert.Equal("Full", Presentation.PillText(i, "time").Primary);
    }

    // ---- power text, words and sentences ----

    [Fact] public void PowerTextOneDecimalByDefault() => Assert.Equal("8.2 W", Presentation.PowerText(new(8.2, PowerDrawKind.Draw, PowerDrawSource.Battery)));

    [Fact]
    public void PowerTextZeroDecimalsRoundsHalfAwayFromZero()
    {
        Assert.Equal("15 W", Presentation.PowerText(new(14.5, PowerDrawKind.Draw, PowerDrawSource.Battery), 0));
        Assert.Equal("8 W", Presentation.PowerText(new(8.2, PowerDrawKind.Draw, PowerDrawSource.Battery), 0));
    }

    [Fact] public void PowerTextChargeCarriesAPlus() => Assert.Equal("+24.7 W", Presentation.PowerText(new(24.7, PowerDrawKind.Charge, PowerDrawSource.Battery)));

    [Fact]
    public void PowerTextNoReadingIsEmpty()
    {
        Assert.Equal("", Presentation.PowerText(new(-1, PowerDrawKind.Draw, PowerDrawSource.Battery)));
        Assert.Equal("", Presentation.PowerText(new(8.2, PowerDrawKind.None, PowerDrawSource.None)));
    }

    [Theory]
    [InlineData(3, "sipping")]
    [InlineData(8.2, "cruising")]
    [InlineData(20, "working")]
    [InlineData(30, "pushing it")]
    [InlineData(60, "full send")]
    [InlineData(0, "")]
    public void PowerWordBands(double watts, string word) => Assert.Equal(word, Presentation.PowerDrawWord(watts));

    [Fact] public void SentenceFromThePack() => Assert.Equal("Drawing 8.2 W", Presentation.PowerSentence(Reading()));
    [Fact] public void SentenceFromTheMeter() => Assert.Equal("Using 14.2 W", Presentation.PowerSentence(Reading(watts: 14.2, source: PowerDrawSource.Meter)));
    [Fact] public void SentenceChargingWithoutThePlus() => Assert.Equal("Charging at 24.7 W", Presentation.PowerSentence(Reading(charging: true, watts: 24.7, kind: PowerDrawKind.Charge)));

    [Fact]
    public void SentenceFunModeAppendsTheWordChargingGetsNone()
    {
        Assert.Equal($"Drawing 8.2 W {Dash} cruising", Presentation.PowerSentence(Reading(), fun: true));
        Assert.Equal("Charging at 24.7 W", Presentation.PowerSentence(Reading(watts: 24.7, kind: PowerDrawKind.Charge), fun: true));
    }

    [Fact] public void SentenceNoReadingIsNoLine() => Assert.Equal("", Presentation.PowerSentence(Reading(watts: -1, kind: PowerDrawKind.None, source: PowerDrawSource.None)));

    [Fact] public void PillPowerWholeWattsOnBattery() => Assert.Equal(new PillText("8 W", ""), Presentation.PillText(Reading(), "power"));
    [Fact] public void PillPowerChargingShowsTheInflow() => Assert.Equal("+25 W", Presentation.PillText(Reading(charging: true, watts: 24.7, kind: PowerDrawKind.Charge), "power").Primary);
    [Fact] public void PillPowerPluggedInWithNothingToMeasureReadsAC() => Assert.Equal("AC", Presentation.PillText(Reading(watts: -1, kind: PowerDrawKind.None, plugged: true), "power").Primary);
    [Fact] public void PillPowerNoBatteryReadsAC() => Assert.Equal("AC", Presentation.PillText(Reading(-1, noBattery: true, watts: -1, kind: PowerDrawKind.None), "power").Primary);
    [Fact] public void PillPowerBeforeTheFirstReadingFallsBackToPercent() => Assert.Equal("72%", Presentation.PillText(Reading(watts: -1, kind: PowerDrawKind.None), "power").Primary);
    [Fact] public void PillPowerUnknownPercentShowsDashes() => Assert.Equal("--", Presentation.PillText(Reading(-1, watts: -1, kind: PowerDrawKind.None), "power").Primary);

    // ---- elapsed ----

    [Fact]
    public void ElapsedPhraseReadsLikeASentence()
    {
        var i = Reading(); i.ElapsedMinutes = 84;
        Assert.Equal("1h 24m on battery", Presentation.ElapsedPhrase(i));
        var c = Reading(charging: true); c.ElapsedMinutes = 12;
        Assert.Equal("12m charging", Presentation.ElapsedPhrase(c));
        var h = Reading(holding: true); h.ElapsedMinutes = 30;
        Assert.Equal("30m plugged in", Presentation.ElapsedPhrase(h));
    }

    [Fact]
    public void ElapsedPhraseIsQuietUnderAMinuteAndOnADesktop()
    {
        var i = Reading(); i.ElapsedMinutes = 0;
        Assert.Equal("", Presentation.ElapsedPhrase(i));
        var d = Reading(noBattery: true); d.ElapsedMinutes = 90;
        Assert.Equal("", Presentation.ElapsedPhrase(d));
    }

    // ---- colors ----

    [Fact]
    public void AccentBandsBeforeTheUsersAccent()
    {
        Assert.Equal(new Rgb(120, 130, 140), Presentation.AccentColor(-1, false, 0, false));
        Assert.Equal(new Rgb(255, 200, 0), Presentation.AccentColor(80, true, 0, false));
        Assert.Equal(new Rgb(255, 70, 70), Presentation.AccentColor(10, false, 0, false));
        Assert.Equal(new Rgb(255, 140, 0), Presentation.AccentColor(20, false, 0, false));
        Assert.Equal(new Rgb(255, 200, 0), Presentation.AccentColor(50, false, 0, false));
        Assert.Equal(Presentation.AccentPresets[2], Presentation.AccentColor(51, false, 2, false));
    }

    [Fact]
    public void WhiteAccentOnALightPillIsGraphite()
    {
        Assert.Equal(new Rgb(90, 95, 105), Presentation.AccentColor(80, false, 7, lightPill: true));
        Assert.Equal(Presentation.AccentPresets[7], Presentation.AccentColor(80, false, 7, lightPill: false));
    }

    [Fact]
    public void AnOutOfRangeAccentIndexIsClamped() => Assert.Equal(Presentation.AccentPresets[7], Presentation.AccentColor(80, false, 99, false));

    [Fact]
    public void HeroPercentIsDarkenedOnALightCard()
    {
        Assert.Equal(new Rgb(0, 180, 255), Presentation.HeroPercentColor("Discharging", false));
        Assert.Equal(new Rgb(0, 112, 158), Presentation.HeroPercentColor("Discharging", true));   // [int](180*0.62) = 112
    }
}
