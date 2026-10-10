using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace BatteryPill.Core;

/// <summary>
/// Reads and writes .lnk shortcuts through the shell's ShellLink object, with
/// source-generated COM interop. The runtime's built-in COM (ComImport) is OFF
/// in a trimmed app, where it threw NotSupportedException on the first shortcut
/// touched; generated wrappers need no runtime support and survive trimming.
/// </summary>
public static partial class ShellShortcut
{
    private const int MaxChars = 1024;
    private static readonly StrategyBasedComWrappers Wrappers = new();
    private static readonly Guid ClsidShellLink = new("00021401-0000-0000-C000-000000000046");

    /// <summary>The target path of the shortcut at <paramref name="path"/>, or null when there is none.</summary>
    /// <exception cref="COMException">The shell could not read it.</exception>
    /// <exception cref="IOException">The file vanished or is unreadable.</exception>
    public static string? ReadTarget(string path)
    {
        if (!File.Exists(path)) return null;
        return Use(link =>
        {
            ((IPersistFile)link).Load(path, 0 /* STGM_READ */);
            IntPtr buffer = Marshal.AllocHGlobal(MaxChars * 2);
            try
            {
                Marshal.WriteInt16(buffer, 0);
                link.GetPath(buffer, MaxChars, IntPtr.Zero, 0);
                string? target = Marshal.PtrToStringUni(buffer);
                return string.IsNullOrEmpty(target) ? null : target;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        });
    }

    /// <summary>Creates (or overwrites) a shortcut to <paramref name="target"/>.</summary>
    public static void Write(string path, string target, string workingDirectory, string description) =>
        Use(link =>
        {
            link.SetPath(target);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(description);
            ((IPersistFile)link).Save(path, true);
            return 0;
        });

    private static T Use<T>(Func<IShellLinkW, T> work)
    {
        Guid clsid = ClsidShellLink, iid = typeof(IShellLinkW).GUID;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 1 /* CLSCTX_INPROC_SERVER */, ref iid, out IntPtr unknown);
        Marshal.ThrowExceptionForHR(hr);
        object wrapper;
        try { wrapper = Wrappers.GetOrCreateObjectForComInstance(unknown, CreateObjectFlags.UniqueInstance); }
        finally { Marshal.Release(unknown); }
        // No FinalRelease(): on .NET 8 the wrapper's finalizer then releases a
        // second time and throws on the GC thread, which kills the process.
        // The finalizer's own single release is the one that frees it.
        return work((IShellLinkW)wrapper);
    }

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, out IntPtr instance);
}

// Vtable order matters: every method up to the last one used is declared.
[GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
[Guid("000214F9-0000-0000-C000-000000000046")]
internal partial interface IShellLinkW
{
    void GetPath(IntPtr file, int max, IntPtr findData, uint flags);
    void GetIDList(out IntPtr pidl);
    void SetIDList(IntPtr pidl);
    void GetDescription(IntPtr name, int max);
    void SetDescription(string name);
    void GetWorkingDirectory(IntPtr dir, int max);
    void SetWorkingDirectory(string dir);
    void GetArguments(IntPtr args, int max);
    void SetArguments(string args);
    void GetHotkey(out ushort hotkey);
    void SetHotkey(ushort hotkey);
    void GetShowCmd(out int cmd);
    void SetShowCmd(int cmd);
    void GetIconLocation(IntPtr path, int max, out int index);
    void SetIconLocation(string path, int index);
    void SetRelativePath(string path, uint reserved);
    void Resolve(IntPtr hwnd, uint flags);
    void SetPath(string file);
}

[GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
[Guid("0000010b-0000-0000-C000-000000000046")]
internal partial interface IPersistFile
{
    void GetClassID(out Guid clsid);
    [PreserveSig] int IsDirty();
    void Load(string file, uint mode);
    void Save(string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
    void SaveCompleted(string file);
    void GetCurFile(out IntPtr file);
}
