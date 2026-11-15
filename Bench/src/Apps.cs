using System.Diagnostics;

namespace AVDTune.Bench;

/// <summary>Application starts (design 1.1, Applications): the time from CreateProcess until the window is ready, cold (standby list purged) and warm. The programs are given by
/// AVDTune with their full path after it has checked the Authenticode signature and holds the files open (checklist "Programs started"); this program only accepts a path
/// that is below a Windows or Program Files folder (from Known Folders, never from the environment) and has the expected file name. Every program that is started goes into
/// its own job object with a timeout; only windows of the job are closed (File Explorer: only the new folder window). Ready = the window class is there and visible (and
/// WaitForInputIdle returned). Not UI Automation: the self-contained runtime has no managed wrapper for it without a third-party library.</summary>
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
        Directory.CreateDirectory(work);
        try
        {
            var roots = DefaultRoots();
            string? Path_(string key)
            {
                if (!o.AppPaths.TryGetValue(key, out var p)) return null;
                return ValidateExe(key, p, roots) == null ? Path.GetFullPath(p) : null;
            }
            string Why(string key) => !o.AppPaths.TryGetValue(key, out var p) ? "not installed (AVDTune gave no path)" : "refused: " + ValidateExe(key, p, roots);
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
                    if (key == "word") { docx = Path.Combine(work, "bench.docx"); TestDocs.WriteDocx(docx); }
                    if (key == "excel") { xlsx = Path.Combine(work, "bench.xlsx"); TestDocs.WriteXlsx(xlsx); }
                    if (key == "explorer") folder = TestDocs.WriteFolder500(work, "AVDTuneBench" + Guid.NewGuid().ToString("N").Substring(0, 8));
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "failed", e.Message)); list.Add(Measure.Not($"host.app.{key}.warm", "ms", false, "failed", e.Message)); continue; }
                if (!o.NoCold)
                {
                    if (!cold) list.Add(Measure.Not($"host.app.{key}.cold", "ms", false, "skipped", coldWhy ?? "cold start not measured"));
                    else { if (!WindowTools.PurgeStandbyList(out _)) { } list.Add(MeasureStart(key, "cold", exe, work, docx, xlsx, folder, o)); }
                }
                list.Add(MeasureStart(key, "warm", exe, work, docx, xlsx, folder, o));
            }

            var ps = Path_("powershell");
            if (ps == null) list.Add(Measure.Not("host.app.powershell.warm", "ms", false, "skipped", Why("powershell")));
            else list.Add(MeasurePowerShell(ps, work));

            list.Add(Measure.Not("host.app.outlook.cold", "ms", false, "skipped", "classic Outlook with a test profile and mail file is not part of this version of the benchmark"));
            list.Add(Measure.Not("host.app.outlook.warm", "ms", false, "skipped", "classic Outlook with a test profile and mail file is not part of this version of the benchmark"));
            list.Add(Measure.Not("host.app.teams.cold", "ms", false, "skipped", "new Teams: activation and window class not verified yet"));
            list.Add(Measure.Not("host.app.teams.warm", "ms", false, "skipped", "new Teams: activation and window class not verified yet"));

            if (o.NoSpeedometer) { /* no measure at all in a warm-up run */ }
            else if (o.Site == null) list.Add(Measure.Not("host.app.speedometer", "runs/min", true, "skipped", "no Speedometer copy (--site)"));
            else if (Path_("edge") is not { } edge) list.Add(Measure.Not("host.app.speedometer", "runs/min", true, "skipped", Why("edge")));
            else list.Add(Speedometer.Run(o, edge, o.Site, work));
        }
        finally { try { Directory.Delete(work, true); } catch { } }
        return list;
    }

    private static Measure MeasureStart(string key, string phase, string exe, string work, string? docx, string? xlsx, string? folder, Options o)
    {
        string id = $"host.app.{key}.{phase}";
        Log.Progress($"apps: {key} {phase}");
        try
        {
            var r = key == "explorer" ? StartExplorer(exe, folder!) : StartInJob(key, exe, work, docx, xlsx);
            if (r.Ms == null) return Measure.Not(id, "ms", false, "failed", r.Reason);
            var m = Measure.Ok(id, "ms", false, r.Ms.Value);
            return m;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        { return Measure.Not(id, "ms", false, "failed", e.Message); }
    }

    private static (double? Ms, string Reason) StartInJob(string key, string exe, string work, string? docx, string? xlsx)
    {
        using var job = new JobGroup();
        string? profile = null;
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work };
        SiteServer? server = null;
        try
        {
            switch (key)
            {
                case "word": psi.ArgumentList.Add("/q"); psi.ArgumentList.Add("/n"); psi.ArgumentList.Add(docx!); break;
                case "excel": psi.ArgumentList.Add("/e"); psi.ArgumentList.Add(xlsx!); break;
                case "edge":
                    server = new SiteServer(null);
                    profile = Path.Combine(work, "edge-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                    psi.ArgumentList.Add("--user-data-dir=" + profile); psi.ArgumentList.Add("--no-first-run"); psi.ArgumentList.Add("--no-default-browser-check");
                    psi.ArgumentList.Add(server.Origin + "/start.html"); break;
            }
            double t0 = Timing.Now();
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("the program did not start");
            job.Assign(p);
            double deadline = t0 + TimeoutMs / 1000.0;
            bool ready = false;
            while (Timing.Now() < deadline)
            {
                var wins = WindowTools.TopLevel(job.Pids()).Select(w => new WinInfo(w.Handle, w.Class, w.Title, w.Visible)).ToList();
                if (IsReady(key, wins, WindowTools.HasChildClass, server?.ReadyCalled ?? false)) { ready = true; break; }
                Thread.Sleep(20);
            }
            if (!ready) return (null, $"{key} was not ready in {TimeoutMs / 1000} s");
            if (key != "edge") { try { p.WaitForInputIdle(Math.Max(100, (int)((deadline - Timing.Now()) * 1000))); } catch (InvalidOperationException) { } }
            double ms = (Timing.Now() - t0) * 1000.0;
            CloseJob(job);
            return (ms, "");
        }
        finally
        {
            job.Terminate();
            server?.Dispose();
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

    public static void RemoveFolder(string dir)
    {
        for (int i = 0; i < 20; i++)
        {
            try { if (Directory.Exists(dir)) Directory.Delete(dir, true); return; }
            catch (IOException) { Thread.Sleep(250); }
            catch (UnauthorizedAccessException) { Thread.Sleep(250); }
        }
    }

    private static (double? Ms, string Reason) StartExplorer(string exe, string folder)
    {
        string title = Path.GetFileName(folder);
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, Arguments = $"/n,\"{folder}\"" };
        double t0 = Timing.Now();
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("explorer.exe did not start");
        double deadline = t0 + TimeoutMs / 1000.0;
        IntPtr hwnd = IntPtr.Zero;
        while (Timing.Now() < deadline && hwnd == IntPtr.Zero)
        {
            var wins = WindowTools.TopLevel(null).Where(w => w.Class == "CabinetWClass").Select(w => new WinInfo(w.Handle, w.Class, w.Title, w.Visible)).ToList();
            if (IsReady("explorer", wins, (_, _) => false, false, title)) hwnd = wins.First(w => w.Visible && string.Equals(w.Title, title, StringComparison.OrdinalIgnoreCase)).Handle;
            else Thread.Sleep(20);
        }
        if (hwnd == IntPtr.Zero) return (null, $"the Explorer window was not there in {TimeoutMs / 1000} s");
        double ms = (Timing.Now() - t0) * 1000.0;
        WindowTools.Close(hwnd);   // only this window; explorer.exe itself is never ended
        return (ms, "");
    }

    private static Measure MeasurePowerShell(string exe, string work)
    {
        Log.Progress("apps: powershell warm");
        var times = new List<double>();
        for (int i = 0; i < 5; i++)
        {
            try
            {
                using var job = new JobGroup();
                var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work };
                foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-Command", "exit" }) psi.ArgumentList.Add(a);
                double t0 = Timing.Now();
                using var p = Process.Start(psi) ?? throw new InvalidOperationException("powershell.exe did not start");
                job.Assign(p);
                if (!p.WaitForExit(TimeoutMs)) return Measure.Not("host.app.powershell.warm", "ms", false, "failed", $"powershell.exe did not end in {TimeoutMs / 1000} s");
                times.Add((Timing.Now() - t0) * 1000.0);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            { return Measure.Not("host.app.powershell.warm", "ms", false, "failed", e.Message); }
        }
        var m = Measure.Ok("host.app.powershell.warm", "ms", false, Evaluation.Median(times));
        m.Detail["starts"] = times.Count;
        return m;
    }
}
