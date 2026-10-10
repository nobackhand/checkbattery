using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace BatteryPill.Core;

/// <summary>What the battery class driver reports (IOCTL_BATTERY_QUERY_*), raw.</summary>
public readonly record struct BatteryDriverReading(
    uint PowerState,
    uint Capacity,
    int Rate,
    uint DesignedCapacity,
    uint FullChargedCapacity,
    uint Capabilities,
    uint EstimatedSeconds)
{
    public const uint PowerOnLine = 0x1, Discharging = 0x2, Charging = 0x4, Critical = 0x8;
    public const uint CapacityRelative = 0x40000000;
    public const int UnknownRate = unchecked((int)0x80000000);
    public const uint UnknownCapacity = 0xFFFFFFFF;
    public const uint UnknownTime = 0xFFFFFFFF;
}

/// <summary>
/// Reads the first battery straight from its class driver: the source Windows'
/// own battery flyout and WMI's battery classes sit on. No COM, no WMI service,
/// so it cannot hang the way a WMI query can, and it survives trimming and
/// single-file publishing (System.Management did not).
/// </summary>
public static class BatteryDevice
{
    /// <summary>
    /// The driver reading in the shape the interpreter already validates. The
    /// WMI-style status code is derived from the driver's power-state flags:
    /// 6 charging, 2 on AC and not charging, 1 discharging.
    /// </summary>
    public static BatterySnapshot ToSnapshot(BatteryDriverReading r)
    {
        bool relative = (r.Capabilities & BatteryDriverReading.CapacityRelative) != 0;
        bool charging = (r.PowerState & BatteryDriverReading.Charging) != 0;
        bool online = (r.PowerState & BatteryDriverReading.PowerOnLine) != 0;
        int status = charging ? 6 : online ? 2 : 1;

        object? pct = null;
        if (r.FullChargedCapacity > 0 && r.Capacity != BatteryDriverReading.UnknownCapacity)
        {
            // Relative units still give a valid ratio; only the mW/mWh meaning is lost
            pct = (int)Math.Round(Math.Clamp(r.Capacity * 100.0 / r.FullChargedCapacity, 0, 100), MidpointRounding.ToEven);
        }

        object? discharge = null, chargeRate = null;
        if (!relative && r.Rate != BatteryDriverReading.UnknownRate)
        {
            // The driver's rate is signed: negative while draining, positive while charging
            if (r.Rate < 0) discharge = -r.Rate;
            else if (r.Rate > 0 && charging) chargeRate = r.Rate;
        }

        return new BatterySnapshot
        {
            EstimatedChargeRemaining = pct,
            BatteryStatus = status,
            DesignCapacity = relative || r.DesignedCapacity == 0 ? null : r.DesignedCapacity,
            FullChargeCapacity = relative || r.FullChargedCapacity == 0 ? null : r.FullChargedCapacity,
            EstimatedRunTime = !online && r.EstimatedSeconds != BatteryDriverReading.UnknownTime ? (uint)(r.EstimatedSeconds / 60) : BatteryInterpreter.UnknownRunTime,
            TimeToFullCharge = null,
            DischargeRate = discharge,
            ChargeRate = chargeRate,
        };
    }

    /// <summary>The first battery's reading, or null when this machine has none (or it cannot be read).</summary>
    public static BatteryDriverReading? Read()
    {
        IntPtr set = SetupDiGetClassDevs(ref BatteryClass, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return null;
        try
        {
            var iface = new SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
            if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref BatteryClass, 0, ref iface)) return null;   // no battery
            SetupDiGetDeviceInterfaceDetail(set, ref iface, IntPtr.Zero, 0, out int needed, IntPtr.Zero);
            IntPtr detail = Marshal.AllocHGlobal(needed);
            try
            {
                // SP_DEVICE_INTERFACE_DETAIL_DATA_W: cbSize is 8 on x64, 6 on x86
                Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                if (!SetupDiGetDeviceInterfaceDetail(set, ref iface, detail, needed, out _, IntPtr.Zero)) return null;
                string path = Marshal.PtrToStringUni(detail + 4) ?? "";
                return Query(path);
            }
            finally { Marshal.FreeHGlobal(detail); }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
    }

    private static BatteryDriverReading? Query(string path)
    {
        using SafeFileHandle h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h.IsInvalid) return null;

        uint wait = 0, tag = 0;
        if (!DeviceIoControl(h, IOCTL_BATTERY_QUERY_TAG, ref wait, 4, out tag, 4, out _, IntPtr.Zero) || tag == 0) return null;

        var q = new BATTERY_QUERY_INFORMATION { BatteryTag = tag, InformationLevel = BatteryInformation };
        if (!DeviceIoControl(h, IOCTL_BATTERY_QUERY_INFORMATION, ref q, Marshal.SizeOf<BATTERY_QUERY_INFORMATION>(),
                out BATTERY_INFORMATION info, Marshal.SizeOf<BATTERY_INFORMATION>(), out _, IntPtr.Zero)) return null;

        var ws = new BATTERY_WAIT_STATUS { BatteryTag = tag };
        if (!DeviceIoControl(h, IOCTL_BATTERY_QUERY_STATUS, ref ws, Marshal.SizeOf<BATTERY_WAIT_STATUS>(),
                out BATTERY_STATUS status, Marshal.SizeOf<BATTERY_STATUS>(), out _, IntPtr.Zero)) return null;

        uint seconds = BatteryDriverReading.UnknownTime;
        q.InformationLevel = BatteryEstimatedTime;
        if (DeviceIoControl(h, IOCTL_BATTERY_QUERY_INFORMATION, ref q, Marshal.SizeOf<BATTERY_QUERY_INFORMATION>(),
                out uint est, 4, out _, IntPtr.Zero)) seconds = est;

        return new BatteryDriverReading(status.PowerState, status.Capacity, status.Rate,
            info.DesignedCapacity, info.FullChargedCapacity, info.Capabilities, seconds);
    }

    // ---- interop ----

    private static Guid BatteryClass = new("72631e54-78a4-11d0-bcf7-00aa00b7b33a");
    private const int DIGCF_PRESENT = 0x2, DIGCF_DEVICEINTERFACE = 0x10;
    private const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
    private const uint IOCTL_BATTERY_QUERY_TAG = 0x294040, IOCTL_BATTERY_QUERY_INFORMATION = 0x294044, IOCTL_BATTERY_QUERY_STATUS = 0x29404C;
    private const int BatteryInformation = 0, BatteryEstimatedTime = 3;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BATTERY_QUERY_INFORMATION { public uint BatteryTag; public int InformationLevel; public int AtRate; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BATTERY_INFORMATION
    {
        public uint Capabilities; public byte Technology; public byte Reserved1, Reserved2, Reserved3;
        public uint Chemistry; public uint DesignedCapacity; public uint FullChargedCapacity; public uint DefaultAlert1;
        public uint DefaultAlert2; public uint CriticalBias; public uint CycleCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BATTERY_WAIT_STATUS { public uint BatteryTag; public uint Timeout; public uint PowerState; public uint LowCapacity; public uint HighCapacity; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BATTERY_STATUS { public uint PowerState; public uint Capacity; public uint Voltage; public int Rate; }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid cls, IntPtr enumerator, IntPtr parent, int flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid cls, int index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, out int required, IntPtr devInfo);
    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref uint inBuf, int inSize, out uint outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref BATTERY_QUERY_INFORMATION inBuf, int inSize, out BATTERY_INFORMATION outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref BATTERY_QUERY_INFORMATION inBuf, int inSize, out uint outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref BATTERY_WAIT_STATUS inBuf, int inSize, out BATTERY_STATUS outBuf, int outSize, out int returned, IntPtr overlapped);
}
