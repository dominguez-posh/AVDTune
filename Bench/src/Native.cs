using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AVDTune.Bench;

/// <summary>A Windows job object whose processes all end when the last handle is closed (kill on close). Every program this measure program starts on its own
/// (Office, Edge, load workers) goes into its own job, so a timeout or an error ends the whole tree and nothing else (never a process of the user).</summary>
public sealed class JobGroup : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinWs, MaxWs; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong A, B, C, D, E, F; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int length);
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetInformationJobObject")] private static extern bool SetJobUiLimits(IntPtr job, int infoClass, ref uint info, int length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private IntPtr _job;
    private uint _uiLimits;
    /// <summary>The UI limits that were set on this job.</summary>
    public uint UiLimits => _uiLimits;

    /// <param name="jobMemoryBytes">Hard limit of the committed memory of the whole job (JOB_OBJECT_LIMIT_JOB_MEMORY); 0 = none. A process that would go over it fails its allocation instead of eating the machine.</param>
    /// <summary>UI restrictions that Office, Edge and Explorer survive (JOB_OBJECT_UILIMIT_*): no switching of the desktop (0x40), no change of the display settings (0x10), no ExitWindows (0x80), no change of
    /// system parameters (0x8). NOT set, because those programs use them: HANDLES (0x1, windows outside the job such as the shell), GLOBALATOMS (0x20, Office), READ/WRITECLIPBOARD (0x2/0x4, copy and paste).
    /// Not verified on a real Office yet (issue #17); when a program does not start with them the measure fails with the reason, the limits are never silently dropped.</summary>
    public const uint ApplicationUiLimits = 0x40 | 0x10 | 0x80 | 0x8;

    public JobGroup(long jobMemoryBytes = 0, uint uiLimits = 0)
    {
        _job = CreateJobObjectW(IntPtr.Zero, null);
        if (_job == IntPtr.Zero) throw new Win32Exception();
        var l = new ExtendedLimit();
        l.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (jobMemoryBytes > 0) { l.Basic.LimitFlags |= 0x200; l.JobMemory = (UIntPtr)(ulong)jobMemoryBytes; }   // JOB_OBJECT_LIMIT_JOB_MEMORY
        if (!SetInformationJobObject(_job, 9, ref l, Marshal.SizeOf<ExtendedLimit>())) { int e = Marshal.GetLastWin32Error(); CloseHandle(_job); _job = IntPtr.Zero; throw new Win32Exception(e); }
        if (uiLimits != 0 && !SetJobUiLimits(_job, 4, ref uiLimits, 4)) { int e = Marshal.GetLastWin32Error(); CloseHandle(_job); _job = IntPtr.Zero; throw new Win32Exception(e, "the UI limits of the job could not be set"); }   // JobObjectBasicUIRestrictions
        _uiLimits = uiLimits;
    }

    /// <summary>Puts a process into the job. When that fails the process is ended: nothing runs outside the job.</summary>
    public void Assign(Process p)
    {
        if (!AssignProcessToJobObject(_job, p.Handle))
        {
            int e = Marshal.GetLastWin32Error();
            try { p.Kill(true); } catch { }
            throw new Win32Exception(e);
        }
    }

    /// <summary>The same for a process handle (a process that was made suspended, so it has run no code outside the job). The caller ends the process when this throws.</summary>
    public void AssignHandle(IntPtr process)
    {
        if (!AssignProcessToJobObject(_job, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    /// <summary>Process ids that are in the job now (the start process and everything it started).</summary>
    public HashSet<int> Pids()
    {
        var set = new HashSet<int>();
        if (_job == IntPtr.Zero) return set;
        int size = 16 + 8 * 512;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!QueryInformationJobObject(_job, 3, buf, size, out _)) return set;   // JobObjectBasicProcessIdList
            int n = Marshal.ReadInt32(buf, 4);
            for (int i = 0; i < n && i < 512; i++) set.Add((int)Marshal.ReadInt64(buf, 8 + i * 8));
        }
        finally { Marshal.FreeHGlobal(buf); }
        return set;
    }

    /// <summary>The job memory limit that is set now (0 = none), read back from the job object.</summary>
    public long MemoryLimitBytes()
    {
        if (_job == IntPtr.Zero) return 0;
        IntPtr buf = Marshal.AllocHGlobal(Marshal.SizeOf<ExtendedLimit>());
        try
        {
            if (!QueryInformationJobObject(_job, 9, buf, Marshal.SizeOf<ExtendedLimit>(), out _)) return 0;
            var l = Marshal.PtrToStructure<ExtendedLimit>(buf);
            return (l.Basic.LimitFlags & 0x200) != 0 ? (long)(ulong)l.JobMemory : 0;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    public void Terminate() { if (_job != IntPtr.Zero) TerminateJobObject(_job, 0xFFFFFFFF); }

    public void Dispose()
    {
        if (_job == IntPtr.Zero) return;
        Terminate();
        CloseHandle(_job);
        _job = IntPtr.Zero;
    }
}

/// <summary>Top-level windows of given processes and the standby list purge. Windows are only looked at and closed (WM_CLOSE) when their process is in our job.</summary>
public static class WindowTools
{
    private delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    public sealed record Win(IntPtr Handle, int Pid, string Class, string Title, bool Visible);

    private static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
    private static string TitleOf(IntPtr h) { var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); return sb.ToString(); }

    /// <summary>Top-level windows; with a set of process ids only those of these processes.</summary>
    public static List<Win> TopLevel(HashSet<int>? pids)
    {
        var list = new List<Win>();
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out uint pid);
            if (pids == null || pids.Contains((int)pid)) list.Add(new Win(h, (int)pid, ClassOf(h), TitleOf(h), IsWindowVisible(h)));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool HasChildClass(IntPtr parent, string className)
    {
        bool found = false;
        EnumChildWindows(parent, (h, _) => { if (ClassOf(h) == className) { found = true; return false; } return true; }, IntPtr.Zero);
        return found;
    }

    public static void Close(IntPtr hwnd) => PostMessageW(hwnd, 0x0010 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero);

    // ---- cold start: purge the standby list (design 1.1, decision D6). Undocumented use of NtSetSystemInformation; needs SeProfileSingleProcessPrivilege (administrator)
    [DllImport("ntdll.dll")] private static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValueW(string? system, string name, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] private struct TokenPrivileges { public uint Count; public long Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    /// <summary>Empties the standby list so files come from disk as after a reboot. Returns false (with the reason) when that is not possible: the cold start is then not measured.</summary>
    public static bool PurgeStandbyList(out string reason)
    {
        reason = "";
        IntPtr token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x20 | 0x8, out token)) { reason = "cannot open the process token"; return false; }
            if (!LookupPrivilegeValueW(null, "SeProfileSingleProcessPrivilege", out long luid)) { reason = "privilege not found"; return false; }
            var tp = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            if (Marshal.GetLastWin32Error() != 0) { reason = "the privilege to purge the standby list is not held (not an administrator?)"; return false; }
            int command = 4;   // MemoryPurgeStandbyList
            int status = NtSetSystemInformation(80, ref command, 4);   // SystemMemoryListInformation
            if (status != 0) { reason = $"NtSetSystemInformation returned 0x{status:X8}"; return false; }
            return true;
        }
        catch (Exception e) { reason = e.Message; return false; }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }
}
