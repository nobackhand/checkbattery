using System.Runtime.InteropServices;

namespace BatteryPill.Core;

/// <summary>
/// The platform power meter (\Power Meter(_Total)\Power, ACPI EMI): what the
/// whole system draws, on machines whose firmware exposes it. Port of
/// PowerMeterProbe in src\010-init.ps1, through PDH directly (trim-safe).
/// Everything runs on a pool thread: a process's FIRST perf-counter query reads
/// every perf provider on the machine, measured at 9-56 s on a busy desktop.
/// </summary>
public sealed class PowerMeter : IDisposable
{
    private readonly object _lock = new();
    private Task? _task;
    private IntPtr _query, _counter;
    private bool _opened, _unavailable, _disposed;
    private double _lastMilliwatts = -1;

    /// <summary>True once the meter is known to be missing or unreadable here. Never re-probed.</summary>
    public bool Unavailable { get { lock (_lock) return _unavailable; } }

    /// <summary>
    /// The latest reading in milliwatts, or -1 while there is none (probing,
    /// unavailable, or not read yet). Never blocks: it starts at most one
    /// background read and returns what the previous one found.
    /// </summary>
    public double Poll()
    {
        lock (_lock)
        {
            if (_unavailable || _disposed) return -1;
            if (_task is null || _task.IsCompleted) _task = Task.Run(ReadOnce);
            return _lastMilliwatts;
        }
    }

    private void ReadOnce()
    {
        double mw = -1;
        bool fail = false;
        try
        {
            if (!_opened && !Open()) fail = true;
            else if (PdhCollectQueryData(_query) != 0) fail = true;
            else
            {
                uint status = PdhGetFormattedCounterValue(_counter, PDH_FMT_DOUBLE, out _, out PDH_FMT_COUNTERVALUE v);
                if (status != 0 || v.CStatus != 0) fail = true;
                else mw = v.DoubleValue;
            }
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { fail = true; }

        lock (_lock)
        {
            if (fail)
            {
                // A meter that cannot answer once is given up on for good, as the PowerShell app does
                _unavailable = true;
                _lastMilliwatts = -1;
                Close();
            }
            else _lastMilliwatts = mw;
        }
    }

    private bool Open()
    {
        if (PdhOpenQuery(null, IntPtr.Zero, out _query) != 0) return false;
        if (PdhAddEnglishCounter(_query, @"\Power Meter(_Total)\Power", IntPtr.Zero, out _counter) != 0) return false;
        _opened = true;
        return true;
    }

    private void Close()
    {
        if (_query != IntPtr.Zero) PdhCloseQuery(_query);
        _query = _counter = IntPtr.Zero;
        _opened = false;
    }

    public void Dispose()
    {
        Task? t;
        lock (_lock) { _disposed = true; t = _task; }
        // A probe still stuck in its first query is left to finish; it closes nothing it never opened
        if (t is null || t.Wait(TimeSpan.FromSeconds(1))) lock (_lock) Close();
    }

    // ---- interop ----

    private const uint PDH_FMT_DOUBLE = 0x00000200;

    [StructLayout(LayoutKind.Explicit)]
    private struct PDH_FMT_COUNTERVALUE
    {
        [FieldOffset(0)] public uint CStatus;
        [FieldOffset(8)] public double DoubleValue;
    }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhOpenQuery(string? dataSource, IntPtr userData, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);
    [DllImport("pdh.dll")]
    private static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")]
    private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out PDH_FMT_COUNTERVALUE value);
    [DllImport("pdh.dll")]
    private static extern uint PdhCloseQuery(IntPtr query);
}
