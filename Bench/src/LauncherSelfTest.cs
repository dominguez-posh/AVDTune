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
        }
        finally { try { FolderTools.RemoveNoFollow(dir); } catch { } }
        return r;

        void Check(string what, RestrictedLauncher.TokenFacts t)
        {
            Add($"{what}: not elevated (TokenElevation = 0)", !t.Elevated);
            Add($"{what}: integrity Medium or lower", t.IntegrityRid <= 0x2000, $"0x{t.IntegrityRid:X}");
            var g = RestrictedLauncher.AdminGroupProblem(t.Groups);
            var admin = t.Groups.FirstOrDefault(x => x.Sid == "S-1-5-32-544");
            Add($"{what}: the Administrators group is deny-only (TokenGroups, SE_GROUP_USE_FOR_DENY_ONLY)", g == null, g ?? (admin.Sid == null ? "not in the token" : $"S-1-5-32-544 attributes 0x{admin.Attributes:X}"));
            var extra = RestrictedLauncher.ExtraPrivileges(t.Privileges);
            Add($"{what}: only standard-user privileges (TokenPrivileges)", extra.Count == 0, extra.Count == 0 ? string.Join(", ", t.Privileges) : "extra: " + string.Join(", ", extra));
        }
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
