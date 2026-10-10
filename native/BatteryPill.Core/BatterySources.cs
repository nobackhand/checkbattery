using System.Runtime.InteropServices;

namespace BatteryPill.Core;

/// <summary>The OS's power status (GetSystemPowerStatus). Cheap; safe on the UI thread.</summary>
public static class SystemPower
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    public static SystemPowerSnapshot? Read()
    {
        if (!GetSystemPowerStatus(out var s)) return null;
        return new SystemPowerSnapshot
        {
            AcLineStatus = s.ACLineStatus,
            BatteryFlag = (int)s.BatteryFlag,
            BatteryLifePercent = (int)s.BatteryLifePercent,
            BatteryLifeTime = s.BatteryLifeTime,
        };
    }
}

/// <summary>
/// WMI battery reads, OFF the UI thread (a query is 20-900 ms, worse under load).
/// <see cref="Poll"/> returns the latest finished reading at once and keeps one
/// query in flight. Port of the BatteryQuery C# class in src\010-init.ps1.
/// </summary>
public sealed class BatteryQuery
{
    private static readonly TimeSpan AbandonAfter = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(60);

    private readonly object _lock = new();
    private Task<BatterySnapshot?>? _task;
    private DateTime _taskStarted;
    private BatterySnapshot? _last;
    private bool _hasReading;
    private DateTime _lastAt;
    private bool _waited;

    /// <summary>
    /// The latest finished reading. Null result + <paramref name="fresh"/> false means
    /// there is none fresh enough to trust (a read can stall; past a minute the
    /// app answers from the OS power status alone).
    /// </summary>
    public BatterySnapshot? Poll(out bool fresh)
    {
        lock (_lock)
        {
            if (_task is { IsCompleted: true })
            {
                if (_task.Status == TaskStatus.RanToCompletion) { _last = _task.Result; _hasReading = true; _lastAt = DateTime.UtcNow; }
                _task = null;
            }
            // A query stuck for 30 s is abandoned; its result, if it ever comes, is never read
            if (_task is not null && DateTime.UtcNow - _taskStarted > AbandonAfter) _task = null;
            if (_task is null)
            {
                _taskStarted = DateTime.UtcNow;
                _task = Task.Run(Read);
            }
            fresh = _hasReading && DateTime.UtcNow - _lastAt <= StaleAfter;
            return fresh ? _last : null;
        }
    }

    /// <summary>Launch: wait (once, bounded) for the first reading rather than flip a tick later.</summary>
    public BatterySnapshot? WaitFirst(TimeSpan timeout, out bool fresh)
    {
        Task<BatterySnapshot?>? t;
        lock (_lock)
        {
            Poll(out _);
            t = _waited || _hasReading ? null : _task;
            _waited = true;
        }
        try { t?.Wait(timeout); } catch (AggregateException) { }
        return Poll(out fresh);
    }

    /// <summary>The tray's Refresh: a fresh reading now, but never more than 5 s of waiting.</summary>
    public BatterySnapshot? ReadNow(out bool fresh)
    {
        var t = Task.Run(Read);
        try
        {
            if (t.Wait(TimeSpan.FromSeconds(5)))
                lock (_lock) { _last = t.Result; _hasReading = true; _lastAt = DateTime.UtcNow; }
        }
        catch (AggregateException) { }
        return Poll(out fresh);
    }

    /// <summary>One complete reading (synchronous). Null when this machine has no battery.</summary>
    public BatterySnapshot? Read() => BatteryDevice.Read() is { } r ? BatteryDevice.ToSnapshot(r) : null;
}
