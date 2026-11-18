using System.ComponentModel;
using System.Diagnostics;

namespace AVDTune.Bench;

/// <summary>`AVDTune.Bench.exe selftest-launcher`: proves on the machine itself that the restricted launcher does what the security review expects. It has to run ELEVATED (the case it protects against):
/// from a non-elevated process it prints "NOT RUN" and exits with 3, which is never a pass. It makes the reduced token, reads its TokenGroups (the Administrators group must be deny-only), its
/// TokenPrivileges (standard-user privileges only), TokenElevation and the Medium integrity level, starts a program with it inside a job object and reads the same facts from the RUNNING child.
/// Error 1314 (a missing privilege) is a FAIL. The answer is readable text, one line per check; the exit code is 0 only when every check passed.</summary>
public static class LauncherSelfTest
{
    public const int ExitPass = 0, ExitFail = 1, ExitNotRun = 3;

    public sealed record Result(string Name, bool Ok, string Detail);

    /// <summary>Runs the checks (elevated only) and returns them; null when this process is not elevated.</summary>
    public static List<Result>? Execute(string? baseDir = null)
    {
        if (!RestrictedLauncher.IsElevated()) return null;
        var r = new List<Result>();
        void Add(string name, bool ok, string detail = "") => r.Add(new Result(name, ok, detail));
        string cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        string dir = Path.Combine(baseDir ?? Path.GetTempPath(), "avdtune-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 12));
        try
        {
            Apps.CreateWorkLayout(dir);
            Add("this process runs elevated", true);
            var refusal = RestrictedLauncher.DomainAdminRefusal(RestrictedLauncher.InspectProcess(Process.GetCurrentProcess().Handle).Groups);
            Add("this account is in no domain-privileged group (app starts only with a local admin, #84)", refusal == null, refusal ?? "");
            IntPtr token = IntPtr.Zero;
            try
            {
                token = RestrictedLauncher.MakeToken();
                var t = RestrictedLauncher.Inspect(token);
                Check("token", t);
            }
            catch (Win32Exception e) { Add("the reduced token could be made", false, $"error {e.NativeErrorCode}: {e.Message}"); }
            catch (InvalidOperationException e) { Add("the reduced token could be made", false, e.Message); }
            finally { if (token != IntPtr.Zero) CloseHandle(token); }

            try
            {
                using var job = new JobGroup(0, JobGroup.ApplicationUiLimits);
                using var p = RestrictedLauncher.Start(cmd, "/c ping -n 20 127.0.0.1 >nul", Apps.TmpDir(dir), Apps.ChildEnvironment(Apps.TmpDir(dir)), job);
                _ = p.Handle;   // hold a handle at once, so an early end still has its exit code
                Thread.Sleep(500);
                if (p.HasExited) Add("the started program keeps running", false, $"it ended right after the start with exit code 0x{p.ExitCode:X8}");
                else
                {
                    Add("the started program is in the job object (kill on close, UI limits)", job.Pids().Contains(p.Id) && job.UiLimits == JobGroup.ApplicationUiLimits, $"pid {p.Id}");
                    var c = RestrictedLauncher.InspectProcess(p.Handle);
                    Check("running child", c);
                    job.Terminate();
                    Add("ending the job ends the child", p.WaitForExit(5000));
                }
            }
            catch (Win32Exception e) { Add("a program could be started with the reduced token", false, e.NativeErrorCode == 1314 ? $"error 1314 (a required privilege is not held): {e.Message}" : $"error {e.NativeErrorCode}: {e.Message}"); }
            catch (InvalidOperationException e) { Add("a program could be started with the reduced token", false, e.Message); }

            try { Apps.CreateUserFolder(Path.Combine(dir, "tmp")); Add("a folder that exists is refused when it is made again", false); }
            catch (IOException) { Add("a folder that exists is refused when it is made again", true); }

            IsolatedChecks(cmd, dir + "-iso", Add);
        }
        finally { try { FolderTools.RemoveNoFollow(dir); } catch { } try { FolderTools.RemoveNoFollow(dir + "-iso"); } catch { } }
        return r;

        void Check(string what, RestrictedLauncher.TokenFacts t)
        {
            Add($"{what}: not elevated (TokenElevation = 0)", !t.Elevated);
            Add($"{what}: integrity Medium or lower", t.IntegrityRid <= 0x2000, $"0x{t.IntegrityRid:X}");
            var g = RestrictedLauncher.AdminGroupProblem(t.Groups);
            var admin = t.Groups.FirstOrDefault(x => x.Sid == "S-1-5-32-544");
            Add($"{what}: the Administrators group and every other admin-like group (built-in, S-1-5-114, domain-privileged) is deny-only (TokenGroups, SE_GROUP_USE_FOR_DENY_ONLY)", g == null, g ?? (admin.Sid == null ? "not in the token" : $"S-1-5-32-544 attributes 0x{admin.Attributes:X}"));
            var extra = RestrictedLauncher.ExtraPrivileges(t.Privileges);
            Add($"{what}: only standard-user privileges (TokenPrivileges)", extra.Count == 0, extra.Count == 0 ? string.Join(", ", t.Privileges) : "extra: " + string.Join(", ", extra));
        }
    }

    /// <summary>The temporary standard user of the application starts (issue #92): made with the prefix and the marker, only in Users, a program started as it in the job with a token that is
    /// this user, not elevated, Medium; afterwards account, profile and the window station entries are gone. A crash (account left behind) is cleaned up by the next start; a look-alike account
    /// without the marker is never touched.</summary>
    private static void IsolatedChecks(string cmd, string dir, Action<string, bool, string> add)
    {
        IsolatedUser? u = null;
        try
        {
            u = IsolatedUser.Create();
            add("isolated user: made with the prefix and the marker", u.Name.StartsWith(IsolatedUser.Prefix, StringComparison.Ordinal) && IsolatedUser.AccountExists(u.Name), u.Name);
            var groups = IsolatedUser.LocalGroups(u.Name);
            add("isolated user: member of Users only", groups.Count == 1 && new System.Security.Principal.NTAccount(groups[0]).Translate(typeof(System.Security.Principal.SecurityIdentifier)).Value == "S-1-5-32-545", string.Join(", ", groups));
            add("isolated user: its profile is loaded (own folder)", u.ProfilePath != null && Directory.Exists(u.ProfilePath), u.ProfilePath ?? "no profile path");
            add("isolated user: the window station and desktop have an entry for it while it runs", IsolatedUser.UiHasEntry(u.Sid), "");
            Apps.CreateWorkLayout(dir, u.Sid);
            using (var job = new JobGroup(0, JobGroup.ApplicationUiLimits))
            {
                using var p = u.Start(cmd, "/c ping -n 20 127.0.0.1 >nul", Apps.TmpDir(dir), Apps.TmpDir(dir), job);
                _ = p.Handle;
                Thread.Sleep(500);
                bool running = !p.HasExited;
                add("isolated user: the started program keeps running", running, running ? "" : $"it ended right after the start with exit code 0x{p.ExitCode:X8}");
                if (running)
                {
                    add("isolated user: the started program is in the job object", job.Pids().Contains(p.Id), $"pid {p.Id}");
                    var (facts, user) = u.ChildFacts(p.Handle);
                    add("isolated user: the running child runs as the temporary user", user == u.Sid.Value, user);
                    add("isolated user: the running child is not elevated, Medium or lower, no admin-like group, standard-user privileges only", RestrictedLauncher.TokenProblem(facts) == null, RestrictedLauncher.TokenProblem(facts) ?? string.Join(", ", facts.Privileges));
                    job.Terminate();
                    add("isolated user: ending the job ends the child", p.WaitForExit(5000), "");
                }
            }
            string name = u.Name; var sid = u.Sid; string? profile = u.ProfilePath;
            u.Dispose();
            add("isolated user: after the run the account is deleted", !IsolatedUser.AccountExists(name), u.CleanupProblem ?? "");
            add("isolated user: after the run the profile folder is deleted", profile == null || !Directory.Exists(profile), profile ?? "");
            add("isolated user: after the run the window station and desktop have no entry for it", !IsolatedUser.UiHasEntry(sid), "");
            u = null;

            // crash: the account stays behind; the next start removes it
            var crashed = IsolatedUser.Create();
            string crashedName = crashed.Name; string? crashedProfile = crashed.ProfilePath;
            crashed.Abandon();
            add("leftover: an account of a crashed run is still there before the next start", IsolatedUser.AccountExists(crashedName), crashedName);
            var done = IsolatedUser.CleanupLeftovers();
            add("leftover: the next start removes the account and its profile", !IsolatedUser.AccountExists(crashedName) && (crashedProfile == null || !Directory.Exists(crashedProfile)), string.Join("; ", done));

            // a look-alike with the prefix but without the marker is not ours
            string other = IsolatedUser.NewName();
            IsolatedUser.AddUser(other, "made by someone else", out IntPtr pw);
            IsolatedUser.FreePassword(ref pw);
            try
            {
                IsolatedUser.CleanupLeftovers();
                add("leftover: an account with the prefix but another description is never touched", IsolatedUser.AccountExists(other), other);
            }
            finally { IsolatedUser.DeleteAccount(other); }
        }
        catch (System.ComponentModel.Win32Exception e) { add("isolated user: made, used and removed", false, $"error {e.NativeErrorCode}: {e.Message}"); }
        catch (InvalidOperationException e) { add("isolated user: made, used and removed", false, e.Message); }
        finally { u?.Dispose(); }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);

    public static int Run(Options o)
    {
        var results = Execute(string.IsNullOrWhiteSpace(o.Dir) ? null : o.Dir);
        if (results == null)
        {
            Console.Out.WriteLine("selftest-launcher: NOT RUN (this process is not elevated). Start it from an elevated prompt (Run as administrator); this is not a pass.");
            return ExitNotRun;
        }
        Console.Out.WriteLine("selftest-launcher: restricted launcher of AVDTune.Bench");
        foreach (var x in results) Console.Out.WriteLine((x.Ok ? "PASS " : "FAIL ") + x.Name + (x.Detail != "" ? "  [" + x.Detail + "]" : ""));
        int failed = results.Count(x => !x.Ok);
        Console.Out.WriteLine(failed == 0 ? $"selftest-launcher: ALL {results.Count} CHECKS PASSED" : $"selftest-launcher: {failed} OF {results.Count} CHECKS FAILED");
        return failed == 0 ? ExitPass : ExitFail;
    }
}
