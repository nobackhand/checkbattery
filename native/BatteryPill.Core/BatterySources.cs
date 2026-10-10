using System.Management;
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
    private static readonly TimeSpan CapacityCacheFor = TimeSpan.FromMinutes(10);

    private readonly object _lock = new();
    private Task<WmiBatterySnapshot?>? _task;
    private DateTime _taskStarted;
    private WmiBatterySnapshot? _last;
    private bool _hasReading;
    private DateTime _lastAt;
    private bool _waited;
    private (object? Full, object? Design, bool Relative)? _caps;
    private DateTime _capsAt;

    /// <summary>
    /// The latest finished reading. Null result + <paramref name="fresh"/> false means
    /// there is none fresh enough to trust (a WMI call can hang; past a minute the
    /// app answers from the OS power status alone).
    /// </summary>
    public WmiBatterySnapshot? Poll(out bool fresh)
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
    public WmiBatterySnapshot? WaitFirst(TimeSpan timeout, out bool fresh)
    {
        Task<WmiBatterySnapshot?>? t;
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
    public WmiBatterySnapshot? ReadNow(out bool fresh)
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

    private static System.Management.EnumerationOptions Opts() => new() { Timeout = TimeSpan.FromSeconds(20) };

    /// <summary>One complete reading (synchronous). Null when this machine has no battery.</summary>
    public WmiBatterySnapshot? Read()
    {
        WmiBatterySnapshot? snap = null;
        try
        {
            using var searcher = new ManagementObjectSearcher("root\\CIMV2", "SELECT * FROM Win32_Battery", Opts());
            using var all = searcher.Get();
            foreach (ManagementBaseObject o in all)
            {
                // First pack (dual-battery laptops), as the PowerShell app does
                snap = new WmiBatterySnapshot
                {
                    EstimatedChargeRemaining = o["EstimatedChargeRemaining"],
                    BatteryStatus = o["BatteryStatus"],
                    DesignCapacity = o["DesignCapacity"],
                    FullChargeCapacity = o["FullChargeCapacity"],
                    EstimatedRunTime = o["EstimatedRunTime"],
                    TimeToFullCharge = o["TimeToFullCharge"],
                };
                break;
            }
        }
        catch (Exception e) when (e is ManagementException or COMException or UnauthorizedAccessException)
        {
            return null;
        }
        if (snap is null) return null;

        // Win32_Battery has NO rate properties and often no capacities: the battery
        // class driver publishes the real numbers in root\WMI. Each class is read on
        // its own, so a missing one costs nothing.
        var caps = Capacities();
        // A battery reporting RELATIVE units has no mW/mWh to offer
        if (caps.Relative) return snap;
        var rates = FirstInstance("BatteryStatus", "DischargeRate", "ChargeRate");
        return snap with
        {
            DischargeRate = rates.GetValueOrDefault("DischargeRate"),
            ChargeRate = rates.GetValueOrDefault("ChargeRate"),
            FullChargeCapacity = IsEmpty(snap.FullChargeCapacity) ? caps.Full : snap.FullChargeCapacity,
            DesignCapacity = IsEmpty(snap.DesignCapacity) ? caps.Design : snap.DesignCapacity,
        };
    }

    private (object? Full, object? Design, bool Relative) Capacities()
    {
        lock (_lock)
        {
            if (_caps is { } c && DateTime.UtcNow - _capsAt < CapacityCacheFor) return c;
        }
        var full = FirstInstance("BatteryFullChargedCapacity", "FullChargedCapacity");
        var st = FirstInstance("BatteryStaticData", "DesignedCapacity", "Capabilities");
        bool relative = false;
        try
        {
            relative = st.GetValueOrDefault("Capabilities") is object cap && (Convert.ToUInt32(cap) & 0x40000000u) != 0;
        }
        catch (Exception e) when (e is FormatException or InvalidCastException or OverflowException) { }
        var result = (full.GetValueOrDefault("FullChargedCapacity"), st.GetValueOrDefault("DesignedCapacity"), relative);
        lock (_lock) { _caps = result; _capsAt = DateTime.UtcNow; }
        return result;
    }

    private static bool IsEmpty(object? v) => DeviceNumber.Read(v) is not double d || d <= 0;

    private static Dictionary<string, object?> FirstInstance(string cls, params string[] props)
    {
        var r = new Dictionary<string, object?>();
        try
        {
            using var s = new ManagementObjectSearcher("root\\WMI", $"SELECT {string.Join(", ", props)} FROM {cls}", Opts());
            using var all = s.Get();
            foreach (ManagementBaseObject o in all)
            {
                foreach (var p in props) r[p] = o[p];
                break;
            }
        }
        catch (Exception e) when (e is ManagementException or COMException or UnauthorizedAccessException) { }
        return r;
    }
}
