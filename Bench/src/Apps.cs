using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;

namespace AVDTune.Bench;

/// <summary>Application starts (design 1.1, Applications): the time from CreateProcess until the window is ready, cold (standby list purged) and warm. The programs are given by
/// AVDTune with their full path after it has checked the Authenticode signature and holds the files open (checklist "Programs started"); this program only accepts a path
/// that is below a Windows or Program Files folder (from Known Folders, never from the environment) and has the expected file name. Every program that is started goes into
/// its own job object with a timeout; only windows of the job are closed (File Explorer: only the new folder window). Ready = the window class is there and visible (and
/// WaitForInputIdle returned). Not UI Automation: the self-contained runtime has no managed wrapper for it without a third-party library.
/// The programs are NOT started elevated (round 2 security review, finding 3) and not as the admin (issue #92): <see cref="IsolatedUser"/> makes a throw-away local standard user per run and
/// starts them as that user, inside the job object (<c>--reduced-token</c> keeps the earlier reduced admin token of <see cref="RestrictedLauncher"/>). Only their own work folder
/// (<see cref="CreateUserFolder"/>) gets rights for that user, nothing else; TEMP and TMP of the children point into it. The new user's profile is fresh, so every program is started once
/// unmeasured before its cold and warm start (first-run work of the profile is not part of the measure).</summary>
public static class Apps
{
    public static readonly string[] Keys = { "word", "excel", "edge", "explorer", "powershell", "outlook", "teams" };
    public const int TimeoutMs = 60_000;

    private static readonly Dictionary<string, string> Leaf = new()
    { ["word"] = "WINWORD.EXE", ["excel"] = "EXCEL.EXE", ["edge"] = "msedge.exe", ["explorer"] = "explorer.exe", ["powershell"] = "powershell.exe" };

    public static string[] DefaultRoots() => new[]
    {
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        Environment.GetFolderPath(Environment.SpecialFolder.Windows), Environment.GetFolderPath(Environment.SpecialFolder.System),
    };

    /// <summary>Null when the path is acceptable, otherwise why not.</summary>
    public static string? ValidateExe(string key, string path, IEnumerable<string> roots)
    {
        if (!Leaf.TryGetValue(key, out var want)) return $"'{key}' is not a program of the application starts";
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") || path.Contains("..") || path.IndexOf('\0') >= 0) return "the path is not a local full path";
        string full;
        try { full = Path.GetFullPath(path); } catch { return "the path is not valid"; }
        if (!string.Equals(Path.GetFileName(full), want, StringComparison.OrdinalIgnoreCase)) return $"the file name must be {want}";
        bool under = roots.Any(r => !string.IsNullOrEmpty(r) && full.StartsWith(Path.GetFullPath(r).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
        if (!under) return "the program is not below a Windows or Program Files folder";
        if (!File.Exists(full)) return "the file is not there";
        return null;
    }

    /// <summary>Folder security for the folders of the started programs: protected (no inheritance), Administrators and SYSTEM full control, and the user of this process (the token of the programs is a
    /// reduced version of it) with exactly <paramref name="userRights"/>. Nobody else.</summary>
    public static DirectorySecurity UserFolderSecurity(SecurityIdentifier user, FileSystemRights userRights = FileSystemRights.Modify)
    {
        var s = new DirectorySecurity();
        s.SetAccessRuleProtection(true, false);
        foreach (var (sid, rights) in new[] { (new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl), (new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl), (user, userRights) })
            s.AddAccessRule(new FileSystemAccessRule(sid, rights, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return s;
    }

    /// <summary>Makes the folder in ONE atomic call with the protected ACL (<see cref="FolderTools.CreateExclusive"/>): an existing folder, file or link is an error, there is no check-then-create gap.</summary>
    public static string CreateUserFolder(string path, FileSystemRights userRights = FileSystemRights.Modify, SecurityIdentifier? user = null)
    {
        user ??= WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("the user of this process is unknown");
        FolderTools.CreateExclusive(path, UserFolderSecurity(user, userRights));
        return path;
    }

    // Layout of the work folder of the programs: the files the tool writes (documents, the 500 files) are in data\ where the user of the programs may only read and execute; the user may write only
    // in tmp\ (TEMP, working directory) and prof\ (Edge profiles).
    public static string DataDir(string work) => Path.Combine(work, "data");
    public static string TmpDir(string work) => Path.Combine(work, "tmp");
    public static string ProfileDir(string work) => Path.Combine(work, "prof");

    /// <summary>Makes the work folder: the root and data\ read and execute, tmp\ and prof\ modify for the user of the programs.</summary>
    public static void CreateWorkLayout(string work, SecurityIdentifier? user = null)
    {
        // every folder is made atomically; the root and data\ are made writable first and tightened to read and execute right after, still before any program has been started (a process that runs
        // without the Administrators group - a non-elevated check run - could not make the sub folders in a root that it may only read)
        user ??= WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("the user of this process is unknown");
        CreateUserFolder(work, FileSystemRights.Modify, user);
        CreateUserFolder(DataDir(work), FileSystemRights.Modify, user);
        CreateUserFolder(TmpDir(work), FileSystemRights.Modify, user);
        CreateUserFolder(ProfileDir(work), FileSystemRights.Modify, user);
        new DirectoryInfo(DataDir(work)).SetAccessControl(UserFolderSecurity(user, FileSystemRights.ReadAndExecute));
        new DirectoryInfo(work).SetAccessControl(UserFolderSecurity(user, FileSystemRights.ReadAndExecute));   // tmp\ and prof\ are protected and keep their own rules
    }

    /// <summary>Environment of a started program: the variables of this process (the allowlist AVDTune made) with TEMP and TMP in the program's own folder, which the reduced token can write.</summary>
    public static Dictionary<string, string> ChildEnvironment(string tempDir)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) env[(string)e.Key] = (string?)e.Value ?? "";
        env["TEMP"] = tempDir; env["TMP"] = tempDir;
        return env;
    }

    /// <summary>Edge command line: a throw-away profile folder, InPrivate, no first-run dialogs, no sync or sign-in, no extensions. NO debugging port (finding 1).</summary>
    public static string[] EdgeArgs(string profileDir, string url, string? extra = null)
    {
        var list = new List<string> { "--user-data-dir=" + profileDir, "--inprivate", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-extensions", "--disable-background-networking" };
        if (extra != null) list.Add(extra);
        list.Add(url);
        return list.ToArray();
    }

    public sealed record WinInfo(IntPtr Handle, string Class, string Title, bool Visible);

    /// <summary>Ready conditions (pure, so the rules are checked without Office): the window of the application is there and visible.</summary>
    public static bool IsReady(string app, IEnumerable<WinInfo> windows, Func<IntPtr, string, bool> hasChild, bool pageCalledBack = false, string? folderTitle = null)
    {
        foreach (var w in windows)
        {
            if (!w.Visible) continue;
            switch (app)
            {
                case "word": if (w.Class == "OpusApp" && hasChild(w.Handle, "_WwG")) return true; break;
                case "excel": if (w.Class == "XLMAIN" && hasChild(w.Handle, "EXCEL7")) return true; break;
                case "edge": if (pageCalledBack && w.Class == "Chrome_WidgetWin_1") return true; break;
                case "explorer": if (w.Class == "CabinetWClass" && folderTitle != null && string.Equals(w.Title, folderTitle, StringComparison.OrdinalIgnoreCase)) return true; break;
            }
        }
        return false;
    }

    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        if (string.IsNullOrWhiteSpace(o.Dir) || !Directory.Exists(o.Dir)) return new() { Measure.Not("host.app.word.warm", "ms", false, "failed", "--dir (an existing work folder) is needed") };
        var work = Path.Combine(o.Dir, "apps-" + Guid.NewGuid().ToString("N").Substring(0, 12));
        var roots = DefaultRoots();
        string? Path_(string key)
        {
            if (!o.AppPaths.TryGetValue(key, out var p)) return null;
            return ValidateExe(key, p, roots) == null ? Path.GetFullPath(p) : null;
        }
        string Why(string key) => !o.AppPaths.TryGetValue(key, out var p) ? "not installed (AVDTune gave no path)" : "refused: " + ValidateExe(key, p, roots);
        // the temporary user is made only when a program will be started (issue #92); a run without programs makes no account
        IAppLauncher? launcher = null;
        if (new[] { "word", "excel", "edge", "explorer", "powershell" }.Any(k => Path_(k) != null))
        {
            try { launcher = MakeLauncher(o); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or UnauthorizedAccessException or IdentityNotMappedException)
            { return FailedAll("the programs could not be started as a temporary standard user: " + e.Message); }
        }
        try { CreateWorkLayout(work, launcher?.Sid); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException)
        { RemoveFolder(work); (launcher as IDisposable)?.Dispose(); return new() { Measure.Not("host.app.word.warm", "ms", false, "failed", "the work folder of the programs could not be made: " + e.Message) }; }
        try
        {
            bool cold = !o.NoCold;
            string? coldWhy = null;
            if (cold && !WindowTools.PurgeStandbyList(out var why)) { cold = false; coldWhy = "cold start not measured: " + why; }
            if (!o.NoCold && cold == false) Log.Progress("apps: " + coldWhy);

            foreach (var key in new[] { "word", "excel", "edge", "explorer" })
            {
                var exe = Path_(key);
                if (exe == null) { list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "skipped", Why(key))); list.Add(Measure.Not($"host.app.{key}.warm", "ms", false, "skipped", Why(key))); continue; }
                string? docx = null, xlsx = null, folder = null;
                try
                {
                    if (key == "word") { docx = Path.Combine(DataDir(work), "bench.docx"); TestDocs.WriteDocx(docx); }
                    if (key == "excel") { xlsx = Path.Combine(DataDir(work), "bench.xlsx"); TestDocs.WriteXlsx(xlsx); }
                    if (key == "explorer") folder = TestDocs.WriteFolder500(DataDir(work), "AVDTuneBench" + Guid.NewGuid().ToString("N").Substring(0, 8));
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "failed", e.Message)); list.Add(Measure.Not($"host.app.{key}.warm", "ms", false, "failed", e.Message)); continue; }
                bool primed = false;
                if (launcher!.Isolated) primed = MeasureStart(key, "first", exe, work, docx, xlsx, folder, launcher).Status == "ok";   // first start of the new profile, not measured
                if (!o.NoCold)
                {
                    if (!cold) list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "skipped", coldWhy ?? "cold start not measured"));
                    else { if (!WindowTools.PurgeStandbyList(out _)) { } list.Add(Mark(MeasureStart(key, "cold", exe, work, docx, xlsx, folder, launcher), launcher, primed)); }
                }
                list.Add(Mark(MeasureStart(key, "warm", exe, work, docx, xlsx, folder, launcher), launcher, primed));
            }

            var ps = Path_("powershell");
            if (ps == null) list.Add(Measure.Not("host.app.powershell.warm", "ms", false, "skipped", Why("powershell")));
            else list.Add(Mark(MeasurePowerShell(ps, work, launcher!), launcher!, false));

            list.Add(Measure.Not("host.app.outlook.cold", "ms", false, "skipped", "classic Outlook with a test profile and mail file is not part of this version of the benchmark"));
            list.Add(Measure.Not("host.app.outlook.warm", "ms", false, "skipped", "classic Outlook with a test profile and mail file is not part of this version of the benchmark"));
            list.Add(Measure.Not("host.app.teams.cold", "ms", false, "skipped", "new Teams: activation and window class not verified yet"));
            list.Add(Measure.Not("host.app.teams.warm", "ms", false, "skipped", "new Teams: activation and window class not verified yet"));

            if (o.NoSpeedometer) { /* no measure at all in a warm-up run */ }
            else if (o.Site == null) list.Add(Measure.Not("host.app.speedometer", "runs/min", true, "skipped", "no Speedometer copy (--site)"));
            else if (Path_("edge") is not { } edge) list.Add(Measure.Not("host.app.speedometer", "runs/min", true, "skipped", Why("edge")));
            else list.Add(Mark(Speedometer.Run(o, edge, o.Site, work, launcher!), launcher!, false));
        }
        finally
        {
            (launcher as IDisposable)?.Dispose();   // ends the user's processes and removes profile and account before the work folder goes
            RemoveFolder(work);
        }
        return list;
    }

    /// <summary>The launcher of a run: a new temporary standard user (default, issue #92), or the reduced admin token with <c>--reduced-token</c>.</summary>
    private static IAppLauncher MakeLauncher(Options o) => o.ReducedToken ? new ReducedTokenLauncher() : IsolatedUser.Create();

    /// <summary>Every application measure failed with one reason (nothing was started).</summary>
    public static List<Measure> FailedAll(string reason)
    {
        var list = new List<Measure>();
        foreach (var key in new[] { "word", "excel", "edge", "explorer" }) { list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "failed", reason)); list.Add(Measure.Not($"host.app.{key}.warm", "ms", false, "failed", reason)); }
        list.Add(Measure.Not("host.app.powershell.warm", "ms", false, "failed", reason));
        list.Add(Measure.Not("host.app.speedometer", "runs/min", true, "failed", reason));
        return list;
    }

    /// <summary>Notes on a measure how the program ran: as the temporary user (isolatedUser) and whether the profile had its unmeasured first start (primed).</summary>
    public static Measure Mark(Measure m, IAppLauncher launcher, bool primed)
    {
        if (m.Status != "ok") return m;
        m.Detail["isolatedUser"] = launcher.Isolated;
        if (launcher.Isolated && primed) m.Detail["primed"] = true;
        return m;
    }

    private static Measure MeasureStart(string key, string phase, string exe, string work, string? docx, string? xlsx, string? folder, IAppLauncher launcher)
    {
        string id = $"host.app.{key}.{phase}";
        Log.Progress($"apps: {key} {phase}");
        try
        {
            LastLink = null;
            var r = key == "explorer" ? StartExplorer(exe, folder!, work, launcher) : StartInJob(key, exe, work, docx, xlsx, launcher);
            LastLink ??= FolderTools.FindLink(work);
            if (LastLink != null) return Measure.Not(id, "ms", false, "failed", "a link was found in the work folder after the run (not trusted): " + LastLink);
            if (r.Ms == null) return Measure.Not(id, "ms", false, "failed", r.Reason);
            var m = Measure.Ok(id, "ms", false, r.Ms.Value);
            if (key == "explorer") m.Detail["viaRunningShell"] = r.ViaShell;
            return m;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        { return Measure.Not(id, "ms", false, "failed", e.Message); }
    }

    /// <summary>The first link found in the work folder right after a program has ended (before the profile is removed); the measure then fails.</summary>
    private static string? LastLink;

    private static (double? Ms, string Reason, bool ViaShell) StartInJob(string key, string exe, string work, string? docx, string? xlsx, IAppLauncher launcher)
    {
        using var job = new JobGroup(0, JobGroup.ApplicationUiLimits);
        string? profile = null;
        var args = new List<string>();
        SiteServer? server = null;
        try
        {
            switch (key)
            {
                case "word": args.Add("/q"); args.Add("/n"); args.Add(docx!); break;
                case "excel": args.Add("/e"); args.Add(xlsx!); break;
                case "edge":
                    server = new SiteServer(null);
                    profile = Path.Combine(ProfileDir(work), "edge-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                    args.AddRange(EdgeArgs(profile, server.Origin + "/start.html")); break;
            }
            double t0 = Timing.Now();
            using var p = launcher.Start(exe, RestrictedLauncher.BuildArguments(args), TmpDir(work), TmpDir(work), job);
            double deadline = t0 + TimeoutMs / 1000.0;
            bool ready = false;
            while (Timing.Now() < deadline)
            {
                var wins = WindowTools.TopLevel(job.Pids()).Select(w => new WinInfo(w.Handle, w.Class, w.Title, w.Visible)).ToList();
                if (IsReady(key, wins, WindowTools.HasChildClass, server?.ReadyCalled ?? false)) { ready = true; break; }
                Thread.Sleep(20);
            }
            if (!ready) return (null, server != null && server.BusyCount > 0 ? $"server busy: {server.BusyCount} connections to the loopback server were refused" : $"{key} was not ready in {TimeoutMs / 1000} s", false);
            if (key != "edge") { try { p.WaitForInputIdle(Math.Max(100, (int)((deadline - Timing.Now()) * 1000))); } catch (InvalidOperationException) { } }
            double ms = (Timing.Now() - t0) * 1000.0;
            CloseJob(job);
            return (ms, "", false);
        }
        finally
        {
            job.Terminate();
            server?.Dispose();
            LastLink = FolderTools.FindLink(work);   // before the profile is removed: a link the program made must be seen, not silently deleted
            if (profile != null) RemoveFolder(profile);
        }
    }

    /// <summary>WM_CLOSE to every window of the job, wait up to 15 s, then the job is ended (Dispose).</summary>
    public static void CloseJob(JobGroup job)
    {
        foreach (var w in WindowTools.TopLevel(job.Pids())) WindowTools.Close(w.Handle);
        double end = Timing.Now() + 15;
        while (Timing.Now() < end && job.Pids().Count > 0) Thread.Sleep(100);
        job.Terminate();
    }

    /// <summary>Removes a folder the programs could write to, never following a link (<see cref="FolderTools.RemoveNoFollow"/>); retries for files that are still held for a moment.</summary>
    public static void RemoveFolder(string dir)
    {
        for (int i = 0; i < 20; i++)
        {
            try { FolderTools.RemoveNoFollow(dir); return; }
            catch (IOException) { Thread.Sleep(250); }
            catch (UnauthorizedAccessException) { Thread.Sleep(250); }
        }
    }

    /// <summary>File Explorer: with the reduced token explorer.exe hands the new folder window to the running shell of the session (Explorer opens "in the running process" and the one we started
    /// may end at once). The window is found by its unique folder title (the folder is ours), so the time is from the start to the window of the shell. The detail "viaRunningShell" says whether
    /// that happened. NOT verified on a real session yet (issue #17); when the started program cannot be made the measure fails with the reason, it never runs elevated.</summary>
    private static (double? Ms, string Reason, bool ViaShell) StartExplorer(string exe, string folder, string work, IAppLauncher launcher)
    {
        string title = Path.GetFileName(folder);
        using var job = new JobGroup(0, JobGroup.ApplicationUiLimits);
        double t0 = Timing.Now();
        using var p = launcher.Start(exe, $"/n,\"{folder}\"", TmpDir(work), TmpDir(work), job);
        double deadline = t0 + TimeoutMs / 1000.0;
        IntPtr hwnd = IntPtr.Zero; int pid = 0;
        while (Timing.Now() < deadline && hwnd == IntPtr.Zero)
        {
            var wins = WindowTools.TopLevel(null).Where(w => w.Class == "CabinetWClass").ToList();
            var infos = wins.Select(w => new WinInfo(w.Handle, w.Class, w.Title, w.Visible)).ToList();
            if (IsReady("explorer", infos, (_, _) => false, false, title)) { var w = wins.First(x => x.Visible && string.Equals(x.Title, title, StringComparison.OrdinalIgnoreCase)); hwnd = w.Handle; pid = w.Pid; }
            else Thread.Sleep(20);
        }
        try
        {
            if (hwnd == IntPtr.Zero) return (null, $"the Explorer window was not there in {TimeoutMs / 1000} s", false);
            double ms = (Timing.Now() - t0) * 1000.0;
            bool viaShell = !job.Pids().Contains(pid);
            WindowTools.Close(hwnd);   // only this window; the explorer.exe of the session is never ended (the job holds only the process we started)
            return (ms, "", viaShell);
        }
        finally { job.Terminate(); }
    }

    private static Measure MeasurePowerShell(string exe, string work, IAppLauncher launcher)
    {
        Log.Progress("apps: powershell warm");
        var times = new List<double>();
        for (int i = 0; i < 5; i++)
        {
            try
            {
                using var job = new JobGroup(0, JobGroup.ApplicationUiLimits);
                double t0 = Timing.Now();
                using var p = launcher.Start(exe, RestrictedLauncher.BuildArguments(new[] { "-NoProfile", "-NonInteractive", "-Command", "exit" }), TmpDir(work), TmpDir(work), job);
                if (!p.WaitForExit(TimeoutMs)) return Measure.Not("host.app.powershell.warm", "ms", false, "failed", $"powershell.exe did not end in {TimeoutMs / 1000} s");
                times.Add((Timing.Now() - t0) * 1000.0);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            { return Measure.Not("host.app.powershell.warm", "ms", false, "failed", e.Message); }
        }
        if (FolderTools.FindLink(work) is { } link) return Measure.Not("host.app.powershell.warm", "ms", false, "failed", "a link was found in the work folder after the run (not trusted): " + link);
        var m = Measure.Ok("host.app.powershell.warm", "ms", false, Evaluation.Median(times));
        m.Detail["starts"] = times.Count;
        return m;
    }
}
