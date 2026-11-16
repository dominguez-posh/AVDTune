using System.Globalization;

namespace AVDTune.Bench;

/// <summary>host.app.speedometer (design 1.1): Speedometer 3.1 from the local copy, served from 127.0.0.1 on a random port. There is NO debugging port (finding 1 of the round 2 security
/// review: a DevTools port on Edge would be a remote-control door into a process of the administrator). Instead the loopback server serves a small wrapper page of the same origin: it
/// loads Speedometer in an iframe, reads #result-number once location.hash is #summary and reports the number to /result/&lt;token&gt; (a 128-bit token per run). Edge runs InPrivate with a
/// throw-away profile, no sign-in, no sync, no extensions, started with the reduced token (Medium integrity, not elevated). Files of the benchmark are not changed.</summary>
public static class Speedometer
{
    public const int TimeoutSec = 600;

    public static Measure Run(Options o, string edgeExe, string siteDir, string work)
    {
        const string Id = "host.app.speedometer";
        Log.Progress("apps: speedometer");
        if (!File.Exists(Path.Combine(siteDir, "index.html"))) return Measure.Not(Id, "runs/min", true, "skipped", "the Speedometer copy is not complete (index.html missing)");
        string profile = Path.Combine(work, "edge-spd-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        using var job = new JobGroup();
        SiteServer? server = null;
        try
        {
            server = new SiteServer(siteDir);
            server.AddWrapper(o.SpeedIterations);
            using var p = RestrictedLauncher.Start(edgeExe, RestrictedLauncher.BuildArguments(Apps.EdgeArgs(profile, server.WrapperUrl, "--window-size=1280,900")), work, Apps.ChildEnvironment(Path.Combine(work, "tmp")), job);
            double deadline = Timing.Now() + TimeoutSec;
            string? text = null;
            while (Timing.Now() < deadline)
            {
                text = server.Result;
                if (text != null) break;
                if (job.Pids().Count == 0) return Measure.Not(Id, "runs/min", true, "failed", "Edge ended before Speedometer gave a result");
                Thread.Sleep(300);
            }
            if (text == null) return Measure.Not(Id, "runs/min", true, "failed", $"Speedometer did not finish in {TimeoutSec} s");
            if (!TryParseScore(text, out double score)) return Measure.Not(Id, "runs/min", true, "failed", "Speedometer gave no usable result");
            var m = Measure.Ok(Id, "runs/min", true, score);
            m.Detail["iterations"] = o.SpeedIterations;
            m.Detail["version"] = "3.1";
            return m;
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        { return Measure.Not(Id, "runs/min", true, "failed", e.Message); }
        finally { job.Terminate(); server?.Dispose(); Apps.RemoveFolder(profile); }
    }

    public static bool TryParseScore(string? text, out double score)
    {
        score = 0;
        return text != null && double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out score) && score > 0 && double.IsFinite(score);
    }
}
