using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AVDTune.Bench;

/// <summary>Starts the application programs (Word, Excel, Edge, Explorer, PowerShell) NOT elevated (security review of round 2, finding 3). Programs with extension points that a user can
/// write (Office add-ins, Normal.dotm, XLSTART, PowerShell profiles, Edge extensions) must never run with the rights of the elevated administrator. The token is made with
/// SaferComputeTokenFromLevel(SAFER_LEVELID_NORMALUSER) (the Administrators group becomes deny-only, the privileges are removed) and its integrity level is set to Medium; the process is made
/// with CreateProcessAsUser, suspended, and only put to work after it is in the job object (kill on close) and its real token was read back (Medium or lower, not elevated). When the token cannot
/// be made or checked nothing starts (fail closed): the measure is then reported as failed, never run elevated as a fallback.</summary>
public static class RestrictedLauncher
{
    private const uint SaferScopeUser = 2, SaferLevelNormalUser = 0x20000, SaferLevelOpen = 1;
    private const int TokenElevationClass = 20, TokenIntegrityLevelClass = 25;
    private const uint MediumRid = 0x2000;
    private const uint CreateSuspended = 0x4, CreateUnicodeEnvironment = 0x400, CreateNoWindow = 0x08000000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo { public int cb; public string? Reserved, Desktop, Title; public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public short ShowWindow, Reserved2Size; public IntPtr Reserved2, StdIn, StdOut, StdErr; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SaferCreateLevel(uint scope, uint level, uint flags, out IntPtr levelHandle, IntPtr reserved);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SaferComputeTokenFromLevel(IntPtr level, IntPtr inToken, out IntPtr outToken, uint flags, IntPtr reserved);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SaferCloseLevel(IntPtr level);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref SidAndAttributes info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool ConvertStringSidToSidW(string sid, out IntPtr sidPtr);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUserW(IntPtr token, string? application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo si, out ProcessInformation pi);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValueW(string? system, string name, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] private struct TokenPrivileges { public uint Count; public long Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr mem);

    /// <summary>The token is acceptable: not elevated and integrity Medium (0x2000) or lower. Pure, so the rule is checked without a token.</summary>
    public static bool IntegrityAcceptable(uint integrityRid, bool elevated) => !elevated && integrityRid <= MediumRid;

    /// <summary>One argument as CommandLineToArgvW reads it back (backslashes before a quote are doubled, the quote is escaped, blanks and quotes put the argument in quotes).</summary>
    public static string QuoteArg(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in a)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"') { sb.Append('\\', backslashes * 2 + 1).Append('"'); backslashes = 0; continue; }
            sb.Append('\\', backslashes); backslashes = 0; sb.Append(c);
        }
        sb.Append('\\', backslashes * 2).Append('"');
        return sb.ToString();
    }

    public static string BuildArguments(IEnumerable<string> args) => string.Join(" ", args.Select(QuoteArg));

    /// <summary>The environment block of a child: "name=value" strings, sorted by name (case-insensitive), each ended by NUL and one more NUL at the end.</summary>
    public static string EnvironmentBlock(IReadOnlyDictionary<string, string> env)
    {
        var sb = new StringBuilder();
        foreach (var kv in env.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase)) sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
        sb.Append('\0');
        return sb.ToString();
    }

    /// <summary>The token of this process, reduced to a standard user at Medium integrity. The caller closes it.</summary>
    public static IntPtr MakeToken()
    {
        IntPtr level = IntPtr.Zero, token = IntPtr.Zero, sid = IntPtr.Zero;
        try
        {
            if (!SaferCreateLevel(SaferScopeUser, SaferLevelNormalUser, SaferLevelOpen, out level, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SaferCreateLevel failed");
            if (!SaferComputeTokenFromLevel(level, IntPtr.Zero, out token, 0, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SaferComputeTokenFromLevel failed");
            if (!ConvertStringSidToSidW("S-1-16-8192", out sid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var label = new SidAndAttributes { Sid = sid, Attributes = 0x20 };   // SE_GROUP_INTEGRITY
            if (!SetTokenInformation(token, TokenIntegrityLevelClass, ref label, Marshal.SizeOf<SidAndAttributes>())) throw new Win32Exception(Marshal.GetLastWin32Error(), "the integrity level of the token could not be set");
            var (rid, elevated) = Query(token);
            if (!IntegrityAcceptable(rid, elevated)) throw new InvalidOperationException($"the reduced token is still too strong (integrity 0x{rid:X}, elevated {elevated})");
            IntPtr result = token; token = IntPtr.Zero;
            return result;
        }
        finally
        {
            if (sid != IntPtr.Zero) LocalFree(sid);
            if (level != IntPtr.Zero) SaferCloseLevel(level);
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    /// <summary>Integrity RID and elevation of a token (query access needed).</summary>
    public static (uint IntegrityRid, bool Elevated) Query(IntPtr token)
    {
        IntPtr buf = Marshal.AllocHGlobal(256);
        try
        {
            if (!GetTokenInformation(token, TokenIntegrityLevelClass, buf, 256, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the integrity level could not be read");
            IntPtr sidPtr = Marshal.ReadIntPtr(buf);
            int count = Marshal.ReadByte(sidPtr, 1);
            if (count < 1) throw new InvalidOperationException("the integrity SID is empty");
            uint rid = (uint)Marshal.ReadInt32(sidPtr, 8 + 4 * (count - 1));
            if (!GetTokenInformation(token, TokenElevationClass, buf, 4, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the elevation could not be read");
            return (rid, Marshal.ReadInt32(buf) != 0);
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    /// <summary>The integrity RID and elevation of a running process (to prove what a started program really got).</summary>
    public static (uint IntegrityRid, bool Elevated) QueryProcess(IntPtr process)
    {
        if (!OpenProcessToken(process, 0x8, out var token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token of the new process could not be opened");
        try { return Query(token); } finally { CloseHandle(token); }
    }

    /// <summary>Starts <paramref name="exe"/> with the reduced token inside <paramref name="job"/>. Returns the process (the caller disposes it). Fails closed: when the token cannot be made, the process cannot be
    /// put into the job or its token is not the reduced one, the process is ended and an exception says why.</summary>
    public static Process Start(string exe, string arguments, string? workDir, IReadOnlyDictionary<string, string> environment, JobGroup job)
    {
        EnablePrivilege("SeIncreaseQuotaPrivilege");
        IntPtr token = MakeToken();
        IntPtr env = Marshal.StringToHGlobalUni(EnvironmentBlock(environment));
        var pi = new ProcessInformation();
        bool created = false;
        try
        {
            var si = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>() };
            var cmd = new StringBuilder(QuoteArg(exe) + (arguments.Length > 0 ? " " + arguments : ""));
            if (!CreateProcessAsUserW(token, exe, cmd, IntPtr.Zero, IntPtr.Zero, false, CreateSuspended | CreateUnicodeEnvironment | CreateNoWindow, env, workDir, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser failed");
            created = true;
            job.AssignHandle(pi.Process);
            var (rid, elevated) = QueryProcess(pi.Process);
            if (!IntegrityAcceptable(rid, elevated)) throw new InvalidOperationException($"the started program is not reduced (integrity 0x{rid:X}, elevated {elevated}); it was ended");
            var p = Process.GetProcessById(pi.ProcessId);
            if (ResumeThread(pi.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(), "the new process could not be resumed");
            return p;
        }
        catch
        {
            if (created) TerminateProcess(pi.Process, 1);
            throw;
        }
        finally
        {
            if (pi.Thread != IntPtr.Zero) CloseHandle(pi.Thread);
            if (pi.Process != IntPtr.Zero) CloseHandle(pi.Process);
            Marshal.FreeHGlobal(env);
            CloseHandle(token);
        }
    }

    private static void EnablePrivilege(string name)
    {
        IntPtr token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x20 | 0x8, out token)) return;
            if (!LookupPrivilegeValueW(null, name, out long luid)) return;
            var tp = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }
}
