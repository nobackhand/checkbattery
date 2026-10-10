using BatteryPill.Core;

namespace BatteryPill.Tests;

// Port of the powercfg boundary cases in tests\Adversarial.Tests.ps1.
public class PowerPlanTests
{
    [Fact]
    public void ANormalListingParses()
    {
        var plans = PowerPlans.Parse(new[]
        {
            "",
            "Existing Power Schemes (* Active)",
            "-----------------------------------",
            "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *",
            "Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)",
        });
        Assert.Equal(2, plans.Count);
        Assert.Equal(new PowerPlan("Balanced", "381b4222-f694-41f0-9685-ff5bb260df2e", true), plans[0]);
        Assert.False(plans[1].IsActive);
    }

    [Fact] public void ANonGuidIdIsDropped() => Assert.Empty(PowerPlans.Parse(new[] { "Power Scheme GUID: ../../../evil  (Pwned)" }));
    [Fact] public void AnEmptyNameIsDropped() => Assert.Empty(PowerPlans.Parse(new[] { "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  ( )" }));

    [Fact]
    public void EmptyNullAndJunkYieldNothing()
    {
        Assert.Empty(PowerPlans.Parse(Array.Empty<string>()));
        Assert.Empty(PowerPlans.Parse(new string?[] { null, "", "ERROR: access denied" }));
    }

    [Fact]
    public void ALocalizedNameWithBracketsParses()
    {
        var plan = Assert.Single(PowerPlans.Parse(new[] { "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert [Standard])" }));
        Assert.Equal("Ausbalanciert [Standard]", plan.Name);
    }

    [Theory]
    [InlineData("not-a-guid")]
    [InlineData("")]
    [InlineData("381b4222-f694-41f0-9685-ff5bb260df2e /delete")]
    [InlineData("381b4222-f694-41f0-9685-ff5bb260df2G")]
    [InlineData("381b4222f69441f09685ff5bb260df2e")]
    [InlineData(null)]
    public void ActivateRefusesAnythingThatIsNotAGuidWithoutRunningPowercfg(string? bad) => Assert.False(PowerPlans.Activate(bad));

    [Fact]
    public void ThisMachinesPlansRead()
    {
        var plans = PowerPlans.Read();
        Assert.All(plans, p => Assert.True(PowerPlans.IsValidId(p.Guid)));
        Assert.True(plans.Count(p => p.IsActive) <= 1);
    }
}
