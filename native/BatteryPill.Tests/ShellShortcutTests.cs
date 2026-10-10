using BatteryPill.Core;

namespace BatteryPill.Tests;

// The Startup-folder shortcut, round-tripped through the real shell object in
// a temp folder (never the user's Startup folder).
public class ShellShortcutTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "bp-lnk-" + Guid.NewGuid().ToString("N"));

    public ShellShortcutTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void AWrittenShortcutReadsBackItsTarget()
    {
        string lnk = Path.Combine(_dir, "BatteryPill.lnk");
        string target = Path.Combine(_dir, "Some Folder", "BatteryPill.exe");
        ShellShortcut.Write(lnk, target, Path.GetDirectoryName(target)!, "BatteryPill - Battery Widget");
        Assert.True(File.Exists(lnk));
        Assert.Equal(target, ShellShortcut.ReadTarget(lnk), ignoreCase: true);
    }

    [Fact]
    public void RewritingRetargetsTheSameFile()
    {
        string lnk = Path.Combine(_dir, "BatteryPill.lnk");
        ShellShortcut.Write(lnk, @"C:\old\BatteryPill-1.4.0.exe", @"C:\old", "old");
        ShellShortcut.Write(lnk, @"C:\new\BatteryPill.exe", @"C:\new", "new");
        Assert.Equal(@"C:\new\BatteryPill.exe", ShellShortcut.ReadTarget(lnk), ignoreCase: true);
    }

    [Fact]
    public void NoFileMeansNoTarget() => Assert.Null(ShellShortcut.ReadTarget(Path.Combine(_dir, "missing.lnk")));

    [Fact]
    public void AFileThatIsNotAShortcutFailsAsAComOrIoError()
    {
        string junk = Path.Combine(_dir, "junk.lnk");
        File.WriteAllText(junk, "not a shortcut");
        var e = Record.Exception(() => ShellShortcut.ReadTarget(junk));
        Assert.True(e is null or System.Runtime.InteropServices.COMException or IOException or UnauthorizedAccessException,
            $"unexpected {e?.GetType().Name}");
    }

    [Fact]
    public void WorksFromAnStaThreadLikeTheUiThread()
    {
        string lnk = Path.Combine(_dir, "sta.lnk");
        string? read = null;
        Exception? error = null;
        var t = new Thread(() =>
        {
            try
            {
                ShellShortcut.Write(lnk, @"C:\sta\BatteryPill.exe", @"C:\sta", "sta");
                read = ShellShortcut.ReadTarget(lnk);
            }
            catch (Exception e) { error = e; }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
        Assert.Null(error);
        Assert.Equal(@"C:\sta\BatteryPill.exe", read, ignoreCase: true);
    }
}
