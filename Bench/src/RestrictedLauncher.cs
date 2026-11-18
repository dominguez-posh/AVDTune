using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AVDTune.Bench;

/// <summary>Starts the application programs (Word, Excel, Edge, Explorer, PowerShell) NOT elevated (security review of round 2, finding 3). Programs with extension points that a user can
/// write (Office add-ins, Normal.dotm, XLSTART, PowerShell profiles, Edge extensions) must never run with the rights of the elevated administrator. The token is made in ONE step from the token of
/// this process with CreateRestrictedToken(LUA_TOKEN | DISABLE_MAX_PRIVILEGE): only SeChangeNotifyPrivilege stays, Administrators, the other built-in admin-like groups and "local account and member
/// of Administrators" become deny-only, the LUA mark makes TokenElevation 0, and the integrity level is set to Medium. One step matters: CreateProcessAsUser accepts a token without
/// SeAssignPrimaryTokenPrivilege only when it is a restricted version of the caller's own token (a child); a token made from a Safer token is a grandchild and fails with 1314. The LUA mark matters
/// on a full token without a linked token (the built-in Administrator RID 500, which Admin Approval Mode does not filter by default; the account an Azure VM is provisioned with): a Safer
/// NORMALUSER token there still reported TokenIsElevated = 1 although it had no admin rights left (issue #14 N1, measured on the GitHub runner). The process is made
/// with CreateProcessAsUser, suspended, and only put to work after it is in the job object (kill on close) and its real token was read back (Medium or lower, not elevated). When the token cannot
/// be made or checked nothing starts (fail closed): the measure is then reported as failed, never run elevated as a fallback.</summary>
public static class RestrictedLauncher
{
    private const int TokenElevationClass = 20, TokenIntegrityLevelClass = 25;
    private const uint MediumRid = 0x2000;
    /// <summary>Flags: LUA_TOKEN (0x4) marks the token as a filtered user token, DISABLE_MAX_PRIVILEGE (0x1) leaves only SeChangeNotifyPrivilege.</summary>
    public const uint RestrictFlags = 0x4 | 0x1;
    /// <summary>SIDs made deny-only (ignored when the token does not have them): Administrators, Power Users, Account, Server, Print and Backup Operators, Replicator, Network Configuration
    /// Operators, Hyper-V Administrators and "local account and member of Administrators group".</summary>
    public static readonly string[] DenyOnlySids = { "S-1-5-32-544", "S-1-5-32-547", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-550", "S-1-5-32-551", "S-1-5-32-552", "S-1-5-32-554", "S-1-5-32-556", "S-1-5-32-569", "S-1-5-32-578", "S-1-5-114" };
    /// <summary>Domain group RIDs that UAC filters or that are admin-like (issue #84): Enterprise Read-only DCs 498, Domain Admins 512, Domain Controllers 516, Cert Publishers 517, Schema Admins 518,
    /// Enterprise Admins 519, Group Policy Creator Owners 520, Read-only DCs 521, Key Admins 526, Enterprise Key Admins 527, RAS and IAS Servers 553. Their SIDs differ per domain, so they are found
    /// in the TokenGroups of this process and made deny-only there.</summary>
    public static readonly uint[] DomainPrivilegedRids = { 498, 512, 516, 517, 518, 519, 520, 521, 526, 527, 553 };

    /// <summary>A domain SID (S-1-5-21-a-b-c-RID) with one of <see cref="DomainPrivilegedRids"/>.</summary>
    public static bool IsDomainPrivileged(string sid)
    {
        var parts = sid.Split('-');
        return parts.Length == 8 && sid.StartsWith("S-1-5-21-", StringComparison.Ordinal) && uint.TryParse(parts[7], out uint rid) && DomainPrivilegedRids.Contains(rid);
    }

    /// <summary>A group that must not be usable for access in the reduced token: the fixed list or a domain-privileged group.</summary>
    public static bool IsAdminLike(string sid) => DenyOnlySids.Contains(sid, StringComparer.OrdinalIgnoreCase) || IsDomainPrivileged(sid);

    /// <summary>The SIDs to make deny-only for a token with these groups: the fixed list plus every domain-privileged group the token has.</summary>
    public static List<string> DenyOnlyFor(IEnumerable<(string Sid, uint Attributes)> groups) => DenyOnlySids.Concat(groups.Select(g => g.Sid).Where(IsDomainPrivileged)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    /// <summary>Null when app starts are allowed for this elevated token. A domain-privileged group that is usable for access (not deny-only) refuses them: the reduced token shares the logon
    /// session, so Kerberos and NTLM single sign-on keep the admin's network identity even with the groups deny-only (issue #84, point 2). App starts only with a local admin.</summary>
    public static string? DomainAdminRefusal(IEnumerable<(string Sid, uint Attributes)> groups)
    {
        var found = groups.Where(g => IsDomainPrivileged(g.Sid) && (g.Attributes & 0x10) == 0).Select(g => g.Sid).ToList();
        return found.Count == 0 ? null : "app starts only with a local admin: this account is in a domain-privileged group (" + string.Join(", ", found) + "), and a program started with user rights would keep its network identity (single sign-on)";
    }
    private const uint CreateSuspended = 0x4, CreateUnicodeEnvironment = 0x400, CreateNoWindow = 0x08000000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo { public int cb; public string? Reserved, Desktop, Title; public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public short ShowWindow, Reserved2Size; public IntPtr Reserved2, StdIn, StdOut, StdErr; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool CreateRestrictedToken(IntPtr existing, uint flags, uint disableCount, SidAndAttributes[] sidsToDisable, uint deleteCount, IntPtr privilegesToDelete, uint restrictCount, IntPtr sidsToRestrict, out IntPtr newToken);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref SidAndAttributes info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref IntPtr info, int length);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr sd, IntPtr size);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr dacl, out bool defaulted);
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

    /// <summary>The default DACL of the reduced token: the user and SYSTEM, full access. The default DACL of an elevated admin token grants Administrators and SYSTEM only; with Administrators
    /// deny-only the child could not open what it creates itself, and a console program ended at once with 0xC0000142 (its console host could not attach; measured on the GitHub runner, #14 N1).
    /// SaferComputeTokenFromLevel did the same replacement, which is why the Safer token started programs.</summary>
    public static string DefaultDaclSddl(string userSid) => $"D:(A;;GA;;;{userSid})(A;;GA;;;SY)";

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

    /// <summary>The token of this process, reduced to a standard user at Medium integrity. The caller closes it. Refused (InvalidOperationException) when this account is in a domain-privileged
    /// group (<see cref="DomainAdminRefusal"/>), and when the reduced token still has a usable admin-like group or a privilege outside the standard-user set (read back, fail closed).</summary>
    public static IntPtr MakeToken()
    {
        IntPtr self = IntPtr.Zero, token = IntPtr.Zero, sid = IntPtr.Zero;
        var deny = Array.Empty<SidAndAttributes>();
        try
        {
            // TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT: the new token gets the same access as this handle (it is queried, labelled and assigned)
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x2 | 0x8 | 0x1 | 0x80, out self)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token of this process could not be opened");
            var own = Inspect(self).Groups;
            if (DomainAdminRefusal(own) is { } refusal) throw new InvalidOperationException(refusal);
            var denySids = DenyOnlyFor(own);   // the fixed list plus the domain-privileged groups found in TokenGroups (their SIDs differ per domain)
            deny = new SidAndAttributes[denySids.Count];
            for (int i = 0; i < deny.Length; i++)
                if (!ConvertStringSidToSidW(denySids[i], out deny[i].Sid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!CreateRestrictedToken(self, RestrictFlags, (uint)deny.Length, deny, 0, IntPtr.Zero, 0, IntPtr.Zero, out token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateRestrictedToken (LUA token) failed");
            if (!ConvertStringSidToSidW("S-1-16-8192", out sid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            SetUserDefaults(token);
            var label = new SidAndAttributes { Sid = sid, Attributes = 0x20 };   // SE_GROUP_INTEGRITY
            if (!SetTokenInformation(token, TokenIntegrityLevelClass, ref label, Marshal.SizeOf<SidAndAttributes>())) throw new Win32Exception(Marshal.GetLastWin32Error(), "the integrity level of the token could not be set");
            if (TokenProblem(Inspect(token)) is { } problem) throw new InvalidOperationException("the reduced token is still too strong: " + problem);
            IntPtr result = token; token = IntPtr.Zero;
            return result;
        }
        finally
        {
            if (sid != IntPtr.Zero) LocalFree(sid);
            foreach (var d in deny) if (d.Sid != IntPtr.Zero) LocalFree(d.Sid);
            if (self != IntPtr.Zero) CloseHandle(self);
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    /// <summary>Owner of new objects and default DACL of the token become the user (TokenOwner, TokenDefaultDacl), as SaferComputeTokenFromLevel does; see <see cref="DefaultDaclSddl"/>.</summary>
    private static void SetUserDefaults(IntPtr token)
    {
        IntPtr buf = Marshal.AllocHGlobal(256), sd = IntPtr.Zero;
        try
        {
            if (!GetTokenInformation(token, 1, buf, 256, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the user of the token could not be read");   // TokenUser
            IntPtr user = Marshal.ReadIntPtr(buf);
            if (!ConvertSidToStringSidW(user, out var text)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string userSid = Marshal.PtrToStringUni(text)!; LocalFree(text);
            if (!SetTokenInformation(token, 4, ref user, IntPtr.Size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the owner of the token could not be set");   // TokenOwner
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(DefaultDaclSddl(userSid), 1, out sd, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!GetSecurityDescriptorDacl(sd, out bool present, out IntPtr dacl, out _) || !present || dacl == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "the default DACL could not be built");
            if (!SetTokenInformation(token, 6, ref dacl, IntPtr.Size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the default DACL of the token could not be set");   // TokenDefaultDacl
        }
        finally { Marshal.FreeHGlobal(buf); if (sd != IntPtr.Zero) LocalFree(sd); }
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
        EnablePrivilege("SeIncreaseQuotaPrivilege", true);   // CreateProcessAsUser needs it; switched off again in finally (N5)
        IntPtr token;
        try { token = MakeToken(); }
        catch { EnablePrivilege("SeIncreaseQuotaPrivilege", false); throw; }
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
            if (TokenProblem(InspectProcess(pi.Process)) is { } problem) throw new InvalidOperationException($"the started program is not reduced ({problem}); it was ended");
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
            EnablePrivilege("SeIncreaseQuotaPrivilege", false);
        }
    }

    /// <summary>True when this process runs elevated (full administrator token).</summary>
    public static bool IsElevated()
    {
        if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x8, out var token)) return false;
        try { return Query(token).Elevated; } finally { CloseHandle(token); }
    }

    /// <summary>The privileges a standard user token may keep (DISABLE_MAX_PRIVILEGE leaves SeChangeNotify; the others appear on some builds). Everything else is a finding.</summary>
    public static readonly string[] StandardPrivileges = { "SeChangeNotifyPrivilege", "SeIncreaseWorkingSetPrivilege", "SeShutdownPrivilege", "SeUndockPrivilege", "SeTimeZonePrivilege" };

    /// <summary>Privileges outside the standard-user set (empty = fine).</summary>
    public static List<string> ExtraPrivileges(IEnumerable<string> held) => held.Where(p => !StandardPrivileges.Contains(p, StringComparer.OrdinalIgnoreCase)).ToList();

    /// <summary>Null when the group list is fine: every admin-like group (<see cref="IsAdminLike"/>: Administrators, the other built-in admin-like groups, S-1-5-114 and the domain-privileged
    /// groups such as Domain Admins) is either not there or has SE_GROUP_USE_FOR_DENY_ONLY (0x10) and is not enabled for access.</summary>
    public static string? AdminGroupProblem(IEnumerable<(string Sid, uint Attributes)> groups)
    {
        foreach (var (sid, attr) in groups)
        {
            if (!IsAdminLike(sid)) continue;
            string name = sid == "S-1-5-32-544" ? "the Administrators group" : "the admin-like group " + sid;
            if ((attr & 0x10) == 0) return $"{name} is not deny-only (attributes 0x{attr:X})";
            if ((attr & 0x4) != 0) return $"{name} is deny-only but also enabled (attributes 0x{attr:X})";
        }
        return null;
    }

    /// <summary>Null when the facts of a reduced token are acceptable: not elevated, Medium or lower, no usable admin-like group, only standard-user privileges. Pure, so it is checked with fakes.</summary>
    public static string? TokenProblem(TokenFacts t)
    {
        if (!IntegrityAcceptable(t.IntegrityRid, t.Elevated)) return $"integrity 0x{t.IntegrityRid:X}, elevated {t.Elevated}";
        if (AdminGroupProblem(t.Groups) is { } g) return g;
        var extra = ExtraPrivileges(t.Privileges);
        return extra.Count == 0 ? null : "privileges outside the standard-user set: " + string.Join(", ", extra);
    }

    public sealed record TokenFacts(uint IntegrityRid, bool Elevated, List<(string Sid, uint Attributes)> Groups, List<string> Privileges);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool LookupPrivilegeNameW(string? system, ref long luid, StringBuilder name, ref int length);

    /// <summary>Everything the review asks for about a token: integrity, elevation, TokenGroups (SID and attributes) and TokenPrivileges (names). The handle needs TOKEN_QUERY.</summary>
    public static TokenFacts Inspect(IntPtr token)
    {
        var (rid, elevated) = Query(token);
        var groups = new List<(string, uint)>();
        var privs = new List<string>();
        GetTokenInformation(token, 2, IntPtr.Zero, 0, out int need);   // TokenGroups
        IntPtr buf = Marshal.AllocHGlobal(Math.Max(need, 16));
        try
        {
            if (!GetTokenInformation(token, 2, buf, need, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token groups could not be read");
            int n = Marshal.ReadInt32(buf);
            for (int i = 0; i < n; i++)
            {
                IntPtr sidPtr = Marshal.ReadIntPtr(buf, 8 + i * 16);
                uint attr = (uint)Marshal.ReadInt32(buf, 8 + i * 16 + 8);
                if (ConvertSidToStringSidW(sidPtr, out var text)) { groups.Add((Marshal.PtrToStringUni(text)!, attr)); LocalFree(text); }
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        GetTokenInformation(token, 3, IntPtr.Zero, 0, out need);   // TokenPrivileges
        buf = Marshal.AllocHGlobal(Math.Max(need, 16));
        try
        {
            if (!GetTokenInformation(token, 3, buf, need, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token privileges could not be read");
            int n = Marshal.ReadInt32(buf);
            for (int i = 0; i < n; i++)
            {
                long luid = Marshal.ReadInt64(buf, 4 + i * 12);
                var sb = new StringBuilder(128); int len = 128;
                privs.Add(LookupPrivilegeNameW(null, ref luid, sb, ref len) ? sb.ToString() : "LUID " + luid);
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        return new TokenFacts(rid, elevated, groups, privs);
    }

    public static TokenFacts InspectProcess(IntPtr process)
    {
        if (!OpenProcessToken(process, 0x8, out var token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token of the process could not be opened");
        try { return Inspect(token); } finally { CloseHandle(token); }
    }

    internal static void EnablePrivilege(string name, bool enable)
    {
        IntPtr token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x20 | 0x8, out token)) return;
            if (!LookupPrivilegeValueW(null, name, out long luid)) return;
            var tp = new TokenPrivileges { Count = 1, Luid = luid, Attributes = enable ? 2u : 0u };
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }
}
