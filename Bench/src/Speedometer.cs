using System.Globalization;

namespace AVDTune.Bench;

/// <summary>host.app.speedometer (design 1.1): Speedometer 3.1 from the local copy, served from 127.0.0.1 on a random port. There is NO debugging port (finding 1 of the round 2 security
/// review: a DevTools port on Edge would be a remote-control door into a process of the administrator). Instead the loopback server serves a small wrapper page of the same origin: it
/// loads Speedometer in an iframe, reads #result-number once location.hash is #summary and reports the number to /result/&lt;token&gt; (a 128-bit token per run). Edge runs InPrivate with a
/// throw-away profile, no sign-in, no sync, no extensions, started with the reduced token (Medium integrity, not elevated). Files of the benchmark are not changed.</summary>
public static class Speedometer
{
    public const int TimeoutSec = 600;
    /// <summary>A Speedometer 3.1 score outside this band is not a measurement of a browser (runs per minute); it is refused as implausible.</summary>
    public static bool Plausible(double score) => score is >= 0.5 and <= 500;

    public static Measure Run(Options o, string edgeExe, string siteDir, string work)
    {
        const string Id = "host.app.speedometer";
        Log.Progress("apps: speedometer");
        if (!File.Exists(Path.Combine(siteDir, "index.html"))) return Measure.Not(Id, "runs/min", true, "skipped", "the Speedometer copy is not complete (index.html missing)");
        string profile = Path.Combine(Apps.ProfileDir(work), "edge-spd-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        using var job = new JobGroup(0, JobGroup.ApplicationUiLimits);
        SiteServer? server = null;
        try
        {
            server = new SiteServer(siteDir);
            server.AddWrapper(o.SpeedIterations);
            using var p = RestrictedLauncher.Start(edgeExe, RestrictedLauncher.BuildArguments(Apps.EdgeArgs(profile, server.WrapperUrl, "--window-size=1280,900")), Apps.TmpDir(work), Apps.ChildEnvironment(Apps.TmpDir(work)), job);
            double deadline = Timing.Now() + TimeoutSec;
            string? text = null;
            while (Timing.Now() < deadline)
            {
                text = server.Result;
                if (text != null) break;
                if (job.Pids().Count == 0) return server.BusyCount > 0 ? Busy(server) : Measure.Not(Id, "runs/min", true, "failed", "Edge ended before Speedometer gave a result");
                Thread.Sleep(300);
            }
            if (text == null) return server.BusyCount > 0 ? Busy(server) : Measure.Not(Id, "runs/min", true, "failed", $"Speedometer did not finish in {TimeoutSec} s");
            job.Terminate();
            if (FolderTools.FindLink(work) is { } link) return Measure.Not(Id, "runs/min", true, "failed", "a link was found in the work folder after the run: " + link);
            if (!TryParseScore(text, out double score)) return Measure.Not(Id, "runs/min", true, "failed", "Speedometer gave no usable result");
            if (!Plausible(score)) return Measure.Not(Id, "runs/min", true, "failed", $"Speedometer reported {score:0.##} runs/min, outside the plausible band 0.5 to 500");
            var m = Measure.Ok(Id, "runs/min", true, score);
            m.Detail["iterations"] = o.SpeedIterations;
            m.Detail["version"] = "3.1";
            return m;
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        { return Measure.Not(Id, "runs/min", true, "failed", e.Message); }
        finally { job.Terminate(); server?.Dispose(); Apps.RemoveFolder(profile); }
    }

    private static Measure Busy(SiteServer s) => Measure.Not("host.app.speedometer", "runs/min", true, "failed", $"server busy: {s.BusyCount} connections to the loopback server were refused (something else is using it, or too many at once)");

    public static bool TryParseScore(string? text, out double score)
    {
        score = 0;
        return text != null && double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out score) && score > 0 && double.IsFinite(score);
    }
}
