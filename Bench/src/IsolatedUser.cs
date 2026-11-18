using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

namespace AVDTune.Bench;

/// <summary>Starts a program of the application starts for the benchmark: inside the job, not elevated, with its own folders granted to <see cref="Sid"/> only.</summary>
public interface IAppLauncher
{
    /// <summary>The account the started programs run as (the work folders grant it their rights).</summary>
    SecurityIdentifier Sid { get; }
    /// <summary>True when the programs run as a throw-away standard user (issue #92).</summary>
    bool Isolated { get; }
    Process Start(string exe, string arguments, string workDir, string tempDir, JobGroup job);
}

/// <summary>The earlier way (issues #14 N1, #84): a reduced token of AVDTune's own account. Only with <c>--reduced-token</c>; AVDTune never passes it.</summary>
public sealed class ReducedTokenLauncher : IAppLauncher
{
    public SecurityIdentifier Sid { get; } = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("the user of this process is unknown");
    public bool Isolated => false;
    public Process Start(string exe, string arguments, string workDir, string tempDir, JobGroup job) => RestrictedLauncher.Start(exe, arguments, workDir, Apps.ChildEnvironment(tempDir), job);
}

/// <summary>A throw-away local standard user for one benchmark run (issue #92). The reduced admin token kept the admin's user SID, so the started programs could write the admin's HKCU and profile
/// (Run keys, Startup, PowerShell profile, Office add-ins); for the built-in Administrator (RID 500) that runs with full rights at the next sign-in. Now the programs run as their own account:
/// name <see cref="Prefix"/> plus 12 random hex digits, description <see cref="Marker"/>, a random 40-character password that exists only in unmanaged memory until LogonUser returned (then it is
/// zeroed; it is never written anywhere), member of Users only (checked, fail closed), interactive logon with its own profile. The programs start with CreateProcessWithTokenW (CreateProcessAsUser
/// would need SeAssignPrimaryTokenPrivilege and SeTcbPrivilege for a token of another logon, which an administrator does not hold), suspended, in the job, and only run after the token of the RUNNING
/// child was read back (this user, not elevated, Medium or lower, no admin-like group, standard-user privileges only). The window station and desktop of this process get an allow entry for the
/// user without clipboard, screen reading or journal hooks; it is removed again at the end. Dispose ends every process of the user, unloads and deletes the profile and deletes the account. A run
/// that crashed leaves the account behind: <see cref="CleanupLeftovers"/> (called before every new user) removes every account with the prefix AND the marker. The domain-admin refusal (#84) stays.</summary>
public sealed class IsolatedUser : IAppLauncher, IDisposable
{
    public const string Prefix = "avdtb-";
    public const string Marker = "AVDTune benchmark: temporary standard user, removed after the run";
    public const int PasswordLength = 40;
    /// <summary>Window station: ENUMDESKTOPS, READATTRIBUTES, ACCESSGLOBALATOMS, ENUMERATE. Not ACCESSCLIPBOARD (the admin's clipboard), READSCREEN, WRITEATTRIBUTES, EXITWINDOWS, CREATEDESKTOP.</summary>
    public const uint WinstaRights = 0x1 | 0x2 | 0x20 | 0x100;
    /// <summary>Desktop: READOBJECTS, CREATEWINDOW, CREATEMENU, HOOKCONTROL (Office sets thread hooks), ENUMERATE, WRITEOBJECTS. Not JOURNALRECORD, JOURNALPLAYBACK, SWITCHDESKTOP.</summary>
    public const uint DesktopRights = 0x1 | 0x2 | 0x4 | 0x8 | 0x40 | 0x80;
    private const string UsersSid = "S-1-5-32-545";
    private static readonly Regex NamePattern = new("^avdtb-[0-9a-f]{12}$", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private const string Upper = "ABCDEFGHJKLMNPQRSTUVWXYZ", Lower = "abcdefghijkmnopqrstuvwxyz", Digits = "23456789", Symbols = "!#$%&()*+,-.:;<=>?@[]^_{}~";

    public string Name { get; }
    public SecurityIdentifier Sid { get; }
    public bool Isolated => true;
    /// <summary>The profile folder of the user (for the checks that it is gone afterwards).</summary>
    public string? ProfilePath { get; private set; }
    /// <summary>Why the account could not be removed completely (it is then disabled and removed at the next start); null when everything is gone.</summary>
    public string? CleanupProblem { get; private set; }
    /// <summary>What <see cref="CleanupLeftovers"/> removed before this user was made.</summary>
    public List<string> Leftovers { get; } = new();
    private IntPtr _token, _profile;
    private string _desktop = "";
    private bool _uiGranted, _disposed;

    private IsolatedUser(string name, SecurityIdentifier sid) { Name = name; Sid = sid; }

    // ---- pure rules (unit tests without an account) ----

    /// <summary>A new account name: the prefix and 12 random hex digits (18 characters, below the SAM limit of 20).</summary>
    public static string NewName() => Prefix + Convert.ToHexString(RandomNumberGenerator.GetBytes(6)).ToLowerInvariant();

    /// <summary>An account that a crashed run left behind: the exact name form AND the marker as its description. A look-alike someone made with another description is never touched.</summary>
    public static bool IsLeftover(string name, string? description) => name.Length <= 20 && NamePattern.IsMatch(name) && description == Marker;

    /// <summary>A random password with upper and lower case letters, digits and symbols (complexity rules), from the system random generator. A char array, so the caller can zero it.</summary>
    public static char[] NewPassword(int length = PasswordLength)
    {
        if (length < 16) throw new ArgumentOutOfRangeException(nameof(length));
        string all = Upper + Lower + Digits + Symbols;
        var pw = new char[length];
        do { for (int i = 0; i < length; i++) pw[i] = all[RandomNumberGenerator.GetInt32(all.Length)]; } while (!PasswordOk(pw));
        return pw;
    }

    public static bool PasswordOk(char[] pw) => pw.Length >= 16 && pw.Any(c => Upper.Contains(c)) && pw.Any(c => Lower.Contains(c)) && pw.Any(c => Digits.Contains(c)) && pw.Any(c => Symbols.Contains(c));

    /// <summary>The environment of the user's programs: the user's own block (CreateEnvironmentBlock, not inherited from AVDTune) with TEMP and TMP in the work folder.</summary>
    public static Dictionary<string, string> ChildEnvironment(IEnumerable<string> userBlock, string tempDir)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in userBlock) { int eq = s.IndexOf('=', 1); if (eq > 0) env[s.Substring(0, eq)] = s.Substring(eq + 1); }
        env["TEMP"] = tempDir; env["TMP"] = tempDir;
        return env;
    }

    /// <summary>Null when the local groups of the account are exactly the Users group.</summary>
    public static string? GroupProblem(IReadOnlyCollection<string> groups, string usersName) =>
        groups.Count == 1 && string.Equals(groups.First(), usersName, StringComparison.OrdinalIgnoreCase) ? null : "the temporary user is not only in " + usersName + " (" + string.Join(", ", groups) + ")";

    // ---- the account ----

    /// <summary>Makes the account, logs it on and loads its profile. Needs an elevated process that is not in a domain-privileged group (#84). Everything made so far is removed again on an error.</summary>
    public static IsolatedUser Create()
    {
        if (!RestrictedLauncher.IsElevated()) throw new InvalidOperationException("the temporary standard user needs an elevated process");
        if (RestrictedLauncher.DomainAdminRefusal(RestrictedLauncher.InspectProcess(Process.GetCurrentProcess().Handle).Groups) is { } refusal) throw new InvalidOperationException(refusal);
        var left = CleanupLeftovers();
        string name = NewName();
        AddUser(name, Marker, out IntPtr pw);
        IsolatedUser? u = null;
        try
        {
            u = new IsolatedUser(name, (SecurityIdentifier)new NTAccount(Environment.MachineName, name).Translate(typeof(SecurityIdentifier)));
            u.Leftovers.AddRange(left);
            AddToUsers(name);
            if (GroupProblem(LocalGroups(name), UsersName()) is { } gp) throw new InvalidOperationException(gp);
            if (!LogonUserW(name, ".", pw, 2, 0, out u._token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the temporary user could not log on (LogonUser, interactive)");
            FreePassword(ref pw);
            if (TokenUser(u._token) != u.Sid.Value) throw new InvalidOperationException("the logon token is not the temporary user");
            if (RestrictedLauncher.TokenProblem(RestrictedLauncher.Inspect(u._token)) is { } problem) throw new InvalidOperationException("the token of the temporary user is too strong: " + problem);
            SetDefaultDacl(u._token, u.Sid.Value);
            u.LoadProfile();
            u.GrantUi();
            return u;
        }
        catch
        {
            FreePassword(ref pw);
            if (u != null) u.Dispose(); else NetUserDel(null, name);
            throw;
        }
    }

    /// <summary>Starts the program as this user, suspended, in the job; it runs only after the token of the running child was read back. Fails closed: the child is ended and an exception says why.</summary>
    public Process Start(string exe, string arguments, string workDir, string tempDir, JobGroup job)
    {
        if (_disposed || _token == IntPtr.Zero) throw new ObjectDisposedException(nameof(IsolatedUser));
        IntPtr env = Marshal.StringToHGlobalUni(RestrictedLauncher.EnvironmentBlock(ChildEnvironment(UserEnvironment(), tempDir)));
        var pi = new ProcessInformation();
        bool created = false;
        try
        {
            var si = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>(), Desktop = _desktop };
            var cmd = new StringBuilder(RestrictedLauncher.QuoteArg(exe) + (arguments.Length > 0 ? " " + arguments : ""));
            if (!CreateProcessWithTokenW(_token, 0, exe, cmd, CreateSuspended | CreateUnicodeEnvironment | CreateNoWindow, env, workDir, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessWithTokenW failed");
            created = true;
            job.AssignHandle(pi.Process);
            var (facts, user) = InspectChild(pi.Process);
            if (user != Sid.Value) throw new InvalidOperationException($"the started program does not run as the temporary user ({user}); it was ended");
            if (RestrictedLauncher.TokenProblem(facts) is { } problem) throw new InvalidOperationException($"the started program is not a standard user ({problem}); it was ended");
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
        }
    }

    /// <summary>The token facts and user of a child. The token of another user's process may not be open to the administrator; then it is read while impersonating the temporary user.</summary>
    internal (RestrictedLauncher.TokenFacts Facts, string User) ChildFacts(IntPtr process) => InspectChild(process);

    private (RestrictedLauncher.TokenFacts Facts, string User) InspectChild(IntPtr process)
    {
        if (!OpenProcessToken(process, 0x8, out var t))
        {
            int err = Marshal.GetLastWin32Error();
            if (err != 5) throw new Win32Exception(err, "the token of the started program could not be opened");
            if (!ImpersonateLoggedOnUser(_token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the temporary user could not be impersonated to read the token of its program");
            try { if (!OpenProcessToken(process, 0x8, out t)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the token of the started program could not be opened"); }
            finally { RevertToSelf(); }
        }
        try { return (RestrictedLauncher.Inspect(t), TokenUser(t)); } finally { CloseHandle(t); }
    }

    private List<string> UserEnvironment()
    {
        if (!CreateEnvironmentBlock(out IntPtr block, _token, false)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the environment of the temporary user could not be made");
        var list = new List<string>();
        try
        {
            IntPtr p = block;
            for (int i = 0; i < 4096; i++)
            {
                string s = Marshal.PtrToStringUni(p) ?? "";
                if (s.Length == 0) break;
                list.Add(s);
                p += (s.Length + 1) * 2;
            }
        }
        finally { DestroyEnvironmentBlock(block); }
        return list;
    }

    private void LoadProfile()
    {
        RestrictedLauncher.EnablePrivilege("SeBackupPrivilege", true); RestrictedLauncher.EnablePrivilege("SeRestorePrivilege", true);
        try
        {
            var pi = new ProfileInfo { Size = Marshal.SizeOf<ProfileInfo>(), Flags = 1, UserName = Name };   // PI_NOUI
            if (!LoadUserProfileW(_token, ref pi)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the profile of the temporary user could not be loaded");
            _profile = pi.Profile;
        }
        finally { RestrictedLauncher.EnablePrivilege("SeBackupPrivilege", false); RestrictedLauncher.EnablePrivilege("SeRestorePrivilege", false); }
        int size = 512; var sb = new StringBuilder(size);
        if (GetUserProfileDirectoryW(_token, sb, ref size)) ProfilePath = sb.ToString();
    }

    /// <summary>Ends every process of the user, removes the UI entries, unloads and deletes the profile, deletes the account. When the profile cannot be deleted the account stays, disabled, for
    /// <see cref="CleanupLeftovers"/> at the next start (deleting the account first would leave a profile nobody can map back).</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        var problems = new List<string>();
        if (_uiGranted) { try { UiEntries(Sid, false); } catch (Exception e) { problems.Add("window station entry: " + e.Message); } }
        KillProcessesOf(Sid);
        if (_profile != IntPtr.Zero) { UnloadUserProfile(_token, _profile); _profile = IntPtr.Zero; }
        if (_token != IntPtr.Zero) { CloseHandle(_token); _token = IntPtr.Zero; }
        if (RemoveAccount(Name, Sid) is { } p) problems.Add(p);
        if (ProfilePath != null && Directory.Exists(ProfilePath)) problems.Add("the profile folder is still there: " + ProfilePath);
        CleanupProblem = problems.Count == 0 ? null : string.Join("; ", problems);
        if (CleanupProblem != null) Log.Progress("apps: the temporary user was not removed completely (" + CleanupProblem + "); it is removed at the next start");
    }

    /// <summary>For the self test only: forget the account as a crash would (handles closed, account and profile left behind).</summary>
    internal void Abandon()
    {
        _disposed = true;
        if (_uiGranted) { try { UiEntries(Sid, false); } catch { } }
        KillProcessesOf(Sid);
        if (_profile != IntPtr.Zero) { UnloadUserProfile(_token, _profile); _profile = IntPtr.Zero; }
        if (_token != IntPtr.Zero) { CloseHandle(_token); _token = IntPtr.Zero; }
    }

    /// <summary>Removes every account a crashed run left behind (<see cref="IsLeftover"/>): its processes, its profile, the account. Returns what was done.</summary>
    public static List<string> CleanupLeftovers()
    {
        var done = new List<string>();
        foreach (var (name, description) in LocalUsers())
        {
            if (!IsLeftover(name, description)) continue;
            SecurityIdentifier sid;
            try { sid = (SecurityIdentifier)new NTAccount(Environment.MachineName, name).Translate(typeof(SecurityIdentifier)); }
            catch (IdentityNotMappedException) { continue; }
            KillProcessesOf(sid);
            done.Add(name + ": " + (RemoveAccount(name, sid) ?? "removed"));
        }
        return done;
    }

    private static string? RemoveAccount(string name, SecurityIdentifier sid)
    {
        int err = 0;
        for (int i = 0; i < 20; i++)
        {
            if (DeleteProfileW(sid.Value, null, null)) { err = 0; break; }
            err = Marshal.GetLastWin32Error();
            if (err == 2) { err = 0; break; }   // no profile
            Thread.Sleep(500);
        }
        if (err != 0)
        {
            uint flags = 0x1 | 0x2 | 0x40 | 0x10000;   // UF_SCRIPT | UF_ACCOUNTDISABLE | UF_PASSWD_CANT_CHANGE | UF_DONT_EXPIRE_PASSWD
            NetUserSetInfo(null, name, 1008, ref flags, out _);
            return $"the profile could not be deleted (error {err}); the account is disabled and stays until the next start";
        }
        int rc = NetUserDel(null, name);
        return rc is 0 or 2221 ? null : $"the account could not be deleted (error {rc})";
    }

    internal static void AddUser(string name, string description, out IntPtr password)
    {
        var chars = NewPassword();
        password = Marshal.AllocHGlobal((chars.Length + 1) * 2);
        for (int i = 0; i < chars.Length; i++) Marshal.WriteInt16(password, i * 2, chars[i]);
        Marshal.WriteInt16(password, chars.Length * 2, 0);
        Array.Clear(chars);
        var ui = new UserInfo1 { Name = name, Password = password, Priv = 1, Comment = description, Flags = 0x1 | 0x40 | 0x10000 };   // USER_PRIV_USER; UF_SCRIPT | UF_PASSWD_CANT_CHANGE | UF_DONT_EXPIRE_PASSWD
        int rc = NetUserAdd(null, 1, ref ui, out _);
        if (rc != 0) { FreePassword(ref password); throw new Win32Exception(rc, "the temporary user could not be made (NetUserAdd)"); }
    }

    internal static void FreePassword(ref IntPtr pw)
    {
        if (pw == IntPtr.Zero) return;
        for (int i = 0; i < PasswordLength + 1; i++) Marshal.WriteInt16(pw, i * 2, 0);
        Marshal.FreeHGlobal(pw);
        pw = IntPtr.Zero;
    }

    internal static int DeleteAccount(string name) => NetUserDel(null, name);
    internal static bool AccountExists(string name) { int rc = NetUserGetInfo(null, name, 0, out IntPtr b); if (b != IntPtr.Zero) NetApiBufferFree(b); return rc == 0; }

    private static string UsersName() { var n = new SecurityIdentifier(UsersSid).Translate(typeof(NTAccount)).Value; return n.Substring(n.IndexOf('\\') + 1); }

    private static void AddToUsers(string name)
    {
        IntPtr member = Marshal.StringToHGlobalUni(Environment.MachineName + "\\" + name);
        try
        {
            int rc = NetLocalGroupAddMembers(null, UsersName(), 3, ref member, 1);
            if (rc != 0 && rc != 1378) throw new Win32Exception(rc, "the temporary user could not be put into the Users group");   // 1378: already a member
        }
        finally { Marshal.FreeHGlobal(member); }
    }

    internal static List<string> LocalGroups(string name)
    {
        var list = new List<string>();
        int rc = NetUserGetLocalGroups(null, name, 0, 1, out IntPtr buf, -1, out int read, out _);   // LG_INCLUDE_INDIRECT
        try
        {
            if (rc != 0) throw new Win32Exception(rc, "the groups of the temporary user could not be read");
            for (int i = 0; i < read; i++) list.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(buf, i * IntPtr.Size)) ?? "");
        }
        finally { if (buf != IntPtr.Zero) NetApiBufferFree(buf); }
        return list;
    }

    private static List<(string Name, string? Description)> LocalUsers()
    {
        var list = new List<(string, string?)>();
        int resume = 0, rc;
        do
        {
            rc = NetUserEnum(null, 10, 2, out IntPtr buf, -1, out int read, out _, ref resume);   // USER_INFO_10, FILTER_NORMAL_ACCOUNT
            try
            {
                if (rc != 0 && rc != 234) throw new Win32Exception(rc, "the local accounts could not be read");
                for (int i = 0; i < read; i++)
                {
                    IntPtr e = buf + i * 4 * IntPtr.Size;
                    list.Add((Marshal.PtrToStringUni(Marshal.ReadIntPtr(e)) ?? "", Marshal.PtrToStringUni(Marshal.ReadIntPtr(e, IntPtr.Size))));
                }
            }
            finally { if (buf != IntPtr.Zero) NetApiBufferFree(buf); }
        } while (rc == 234);
        return list;
    }

    /// <summary>Ends every process that runs as <paramref name="sid"/> (found with WTSEnumerateProcesses, which names the user without opening its token). These are processes of the temporary
    /// user only: the programs of the run and what Windows started for that user (COM servers), which would keep the profile loaded.</summary>
    internal static int KillProcessesOf(SecurityIdentifier sid)
    {
        int killed = 0;
        var first = PidsOf(sid);
        if (first.Count == 0) return 0;
        var handles = new Dictionary<int, IntPtr>();
        RestrictedLauncher.EnablePrivilege("SeDebugPrivilege", true);
        try
        {
            foreach (int pid in first) { IntPtr h = OpenProcess(0x1 | 0x100000, false, pid); if (h != IntPtr.Zero) handles[pid] = h; }   // TERMINATE | SYNCHRONIZE
            // read again while the handles are held: a PID that is still this user's cannot have been reused in between
            var second = PidsOf(sid);
            foreach (var (pid, h) in handles) if (second.Contains(pid) && TerminateProcess(h, 1)) { WaitForSingleObject(h, 5000); killed++; }
        }
        finally
        {
            foreach (var h in handles.Values) CloseHandle(h);
            RestrictedLauncher.EnablePrivilege("SeDebugPrivilege", false);
        }
        return killed;
    }

    private static HashSet<int> PidsOf(SecurityIdentifier sid)
    {
        var pids = new HashSet<int>();
        if (!WTSEnumerateProcessesW(IntPtr.Zero, 0, 1, out IntPtr info, out int count)) return pids;
        try
        {
            int size = Marshal.SizeOf<WtsProcessInfo>();
            for (int i = 0; i < count; i++)
            {
                var w = Marshal.PtrToStructure<WtsProcessInfo>(info + i * size);
                if (w.UserSid == IntPtr.Zero) continue;
                try { if (new SecurityIdentifier(w.UserSid) == sid) pids.Add(w.ProcessId); } catch (ArgumentException) { }
            }
        }
        finally { WTSFreeMemory(info); }
        return pids;
    }

    /// <summary>Default DACL of the user's token: the user, SYSTEM and Administrators. Without Administrators AVDTune (elevated, another account) could not open the processes it starts to wait
    /// for them, read their token or end them; the files of the programs get their rights from the work folder (inherited), not from this.</summary>
    public static string DefaultDaclSddl(string userSid) => $"D:(A;;GA;;;{userSid})(A;;GA;;;SY)(A;;GA;;;BA)";

    private static void SetDefaultDacl(IntPtr token, string userSid)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(DefaultDaclSddl(userSid), 1, out IntPtr sd, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            if (!GetSecurityDescriptorDacl(sd, out bool present, out IntPtr dacl, out _) || !present || dacl == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "the default DACL could not be built");
            if (!SetTokenInformation(token, 6, ref dacl, IntPtr.Size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the default DACL of the temporary user's token could not be set");   // TokenDefaultDacl
        }
        finally { LocalFree(sd); }
    }

    internal static string TokenUser(IntPtr token)
    {
        IntPtr buf = Marshal.AllocHGlobal(256);
        try
        {
            if (!GetTokenInformation(token, 1, buf, 256, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the user of the token could not be read");
            return new SecurityIdentifier(Marshal.ReadIntPtr(buf)).Value;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    // ---- window station and desktop ----

    private void GrantUi()
    {
        _desktop = UiEntries(Sid, true);
        _uiGranted = true;
    }

    /// <summary>Adds (or only removes) the allow entries of <paramref name="sid"/> on the window station and desktop of this process. Existing entries of that SID are removed first, so a second
    /// call never stacks and the removal leaves nothing behind. Returns "station\desktop" for STARTUPINFO.</summary>
    internal static string UiEntries(SecurityIdentifier sid, bool add)
    {
        string station = ObjectName(GetProcessWindowStation()), desktop = ObjectName(GetThreadDesktop(GetCurrentThreadId()));
        IntPtr ws = OpenWindowStationW(station, false, 0x20000 | 0x40000);   // READ_CONTROL | WRITE_DAC
        if (ws == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "the window station could not be opened");
        try { EditDacl(ws, sid, add ? WinstaRights : null); } finally { CloseWindowStation(ws); }
        IntPtr dt = OpenDesktopW(desktop, 0, false, 0x20000 | 0x40000);
        if (dt == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "the desktop could not be opened");
        try { EditDacl(dt, sid, add ? DesktopRights : null); } finally { CloseDesktop(dt); }
        return station + "\\" + desktop;
    }

    /// <summary>True when the window station or desktop of this process still has an entry for <paramref name="sid"/>.</summary>
    internal static bool UiHasEntry(SecurityIdentifier sid)
    {
        string station = ObjectName(GetProcessWindowStation()), desktop = ObjectName(GetThreadDesktop(GetCurrentThreadId()));
        IntPtr ws = OpenWindowStationW(station, false, 0x20000), dt = OpenDesktopW(desktop, 0, false, 0x20000);
        try { return HasEntry(ReadDacl(ws), sid) || HasEntry(ReadDacl(dt), sid); }
        finally { if (ws != IntPtr.Zero) CloseWindowStation(ws); if (dt != IntPtr.Zero) CloseDesktop(dt); }
    }

    private static bool HasEntry(RawAcl acl, SecurityIdentifier sid) { for (int i = 0; i < acl.Count; i++) if (acl[i] is KnownAce a && a.SecurityIdentifier == sid) return true; return false; }

    private static string ObjectName(IntPtr h)
    {
        var sb = new StringBuilder(256);
        if (!GetUserObjectInformationW(h, 2, sb, 512, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "the name of the window station or desktop could not be read");   // UOI_NAME
        return sb.ToString();
    }

    private static RawAcl ReadDacl(IntPtr h)
    {
        uint rc = GetSecurityInfo(h, 7, 4, IntPtr.Zero, IntPtr.Zero, out _, IntPtr.Zero, out IntPtr sd);   // SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION
        if (rc != 0) throw new Win32Exception((int)rc, "the security of the window station or desktop could not be read");
        try
        {
            var bytes = new byte[GetSecurityDescriptorLength(sd)];
            Marshal.Copy(sd, bytes, 0, bytes.Length);
            return new RawSecurityDescriptor(bytes, 0).DiscretionaryAcl ?? throw new InvalidOperationException("the window station or desktop has no DACL (not changed)");
        }
        finally { LocalFree(sd); }
    }

    private static void EditDacl(IntPtr h, SecurityIdentifier sid, uint? mask)
    {
        var acl = ReadDacl(h);
        for (int i = acl.Count - 1; i >= 0; i--) if (acl[i] is KnownAce a && a.SecurityIdentifier == sid) acl.RemoveAce(i);
        if (mask is uint m) acl.InsertAce(acl.Count, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, unchecked((int)m), sid, false, null));
        var bin = new byte[acl.BinaryLength];
        acl.GetBinaryForm(bin, 0);
        var pin = GCHandle.Alloc(bin, GCHandleType.Pinned);
        try
        {
            uint rc = SetSecurityInfo(h, 7, 4, IntPtr.Zero, IntPtr.Zero, pin.AddrOfPinnedObject(), IntPtr.Zero);
            if (rc != 0) throw new Win32Exception((int)rc, "the security of the window station or desktop could not be changed");
        }
        finally { pin.Free(); }
    }

    // ---- native ----
    private const uint CreateSuspended = 0x4, CreateUnicodeEnvironment = 0x400, CreateNoWindow = 0x08000000;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo { public int cb; public string? Reserved, Desktop, Title; public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public short ShowWindow, Reserved2Size; public IntPtr Reserved2, StdIn, StdOut, StdErr; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct UserInfo1 { public string Name; public IntPtr Password; public uint PasswordAge, Priv; public string? HomeDir, Comment; public uint Flags; public string? ScriptPath; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ProfileInfo { public int Size, Flags; public string UserName; public string? ProfilePath, DefaultPath, ServerName, PolicyPath; public IntPtr Profile; }
    [StructLayout(LayoutKind.Sequential)] private struct WtsProcessInfo { public int SessionId, ProcessId; public IntPtr ProcessName, UserSid; }

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserAdd(string? server, int level, ref UserInfo1 buf, out int parmErr);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserDel(string? server, string name);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserGetInfo(string? server, string name, int level, out IntPtr buf);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserSetInfo(string? server, string name, int level, ref uint flags, out int parmErr);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserEnum(string? server, int level, int filter, out IntPtr buf, int prefMax, out int read, out int total, ref int resume);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetUserGetLocalGroups(string? server, string name, int level, int flags, out IntPtr buf, int prefMax, out int read, out int total);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] private static extern int NetLocalGroupAddMembers(string? server, string group, int level, ref IntPtr members, int count);
    [DllImport("netapi32.dll")] private static extern int NetApiBufferFree(IntPtr buf);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool LogonUserW(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string? application, StringBuilder commandLine, uint flags, IntPtr environment, string? directory, ref StartupInfo si, out ProcessInformation pi);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool ImpersonateLoggedOnUser(IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool RevertToSelf();
    [DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(IntPtr handle, int objectType, uint info, IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll")] private static extern uint SetSecurityInfo(IntPtr handle, int objectType, uint info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("advapi32.dll")] private static extern int GetSecurityDescriptorLength(IntPtr sd);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr sd, IntPtr size);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref IntPtr info, int length);
    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool LoadUserProfileW(IntPtr token, ref ProfileInfo info);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool UnloadUserProfile(IntPtr token, IntPtr profile);
    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool DeleteProfileW(string sid, string? path, string? computer);
    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool GetUserProfileDirectoryW(IntPtr token, StringBuilder dir, ref int size);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("wtsapi32.dll", SetLastError = true)] private static extern bool WTSEnumerateProcessesW(IntPtr server, int reserved, int version, out IntPtr info, out int count);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr mem);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int length, out int needed);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern IntPtr OpenWindowStationW(string name, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool CloseWindowStation(IntPtr h);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr mem);
}
