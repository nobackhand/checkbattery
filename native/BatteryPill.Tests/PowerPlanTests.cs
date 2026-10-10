using System.Diagnostics;
using BatteryPill.Core;

namespace BatteryPill.Tests;

// The plan ids that reach the power API are validated first (the port of the
// powercfg boundary cases in tests\Adversarial.Tests.ps1), and the live read
// answers fast enough for the tray menu to build the list as it opens.
public class PowerPlanTests
{
    [Theory]
    [InlineData("not-a-guid")]
    [InlineData("")]
    [InlineData("381b4222-f694-41f0-9685-ff5bb260df2e /delete")]
    [InlineData("381b4222-f694-41f0-9685-ff5bb260df2G")]
    [InlineData("381b4222f69441f09685ff5bb260df2e")]
    [InlineData("../../../evil")]
    [InlineData(null)]
    public void ActivateRefusesAnythingThatIsNotAGuid(string? bad) => Assert.False(PowerPlans.Activate(bad));

    [Fact]
    public void ThisMachinesPlansReadQuicklyWithNamesAndAtMostOneActive()
    {
        PowerPlans.Read();   // first call loads powrprof
        var sw = Stopwatch.StartNew();
        var plans = PowerPlans.Read();
        sw.Stop();
        Assert.True(sw.ElapsedMilliseconds < 250, $"reading the plans took {sw.ElapsedMilliseconds} ms");
        Assert.NotEmpty(plans);
        Assert.All(plans, p =>
        {
            Assert.True(PowerPlans.IsValidId(p.Guid));
            Assert.False(string.IsNullOrWhiteSpace(p.Name));
        });
        Assert.True(plans.Count(p => p.IsActive) <= 1);
    }

    [Fact]
    public void TheActivePlanMatchesPowercfg()
    {
        // powercfg is the reference the PowerShell app parsed; read-only here
        var psi = new ProcessStartInfo("powercfg", "/getactivescheme") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
        using var p = Process.Start(psi)!;
        string output = p.StandardOutput.ReadToEnd();
        p.WaitForExit(5000);
        var active = PowerPlans.Read().SingleOrDefault(x => x.IsActive);
        Assert.NotNull(active);
        Assert.Contains(active!.Guid, output, StringComparison.OrdinalIgnoreCase);
    }
}
