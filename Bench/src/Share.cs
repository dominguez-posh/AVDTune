using System.Net.Sockets;

namespace AVDTune.Bench;

/// <summary>FSLogix share measures that need no diskspd (design 1.2): SMB open/close per second, round-trip time to the storage host (TCP 445) and the metadata test (create, stat,
/// delete of 2000 files of 4 KB in 20 folders). Everything happens in the test folder AVDTune made on the share (--dir, a GUID folder); this program only works below it.</summary>
public static class ShareBench
{
    public const int MetaFiles = 2000, MetaFolders = 20, RttConnects = 50;

    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        if (string.IsNullOrWhiteSpace(o.Dir) || !Directory.Exists(o.Dir)) return new() { Measure.Not("fsl.meta.create", "files/s", true, "failed", "--dir (the test folder on the share) does not exist") };
        if ((new DirectoryInfo(o.Dir).Attributes & FileAttributes.ReparsePoint) != 0) return new() { Measure.Not("fsl.meta.create", "files/s", true, "failed", "the test folder is a link") };
        list.Add(Rtt(o));
        list.Add(OpenClose(o));
        list.AddRange(Metadata(o));
        return list;
    }

    private static Measure Rtt(Options o)
    {
        if (string.IsNullOrWhiteSpace(o.HostName)) return Measure.Not("fsl.rtt", "ms", false, "skipped", "no storage host given");
        Log.Progress("share: rtt");
        var times = new List<double>();
        for (int i = 0; i < RttConnects; i++)
        {
            using var c = new TcpClient();
            double t0 = Timing.Now();
            try
            {
                var task = c.ConnectAsync(o.HostName, 445);
                if (!task.Wait(3000)) continue;
                times.Add((Timing.Now() - t0) * 1000.0);
            }
            catch (Exception e) when (e is AggregateException or SocketException) { }
            Thread.Sleep(20);
        }
        if (times.Count < RttConnects / 2) return Measure.Not("fsl.rtt", "ms", false, "failed", $"only {times.Count} of {RttConnects} connects to port 445 worked");
        return Measure.Ok("fsl.rtt", "ms", false, Evaluation.Median(times));
    }

    private static Measure OpenClose(Options o)
    {
        Log.Progress("share: open and close");
        string file = Path.Combine(o.Dir!, "openclose.dat");
        try
        {
            using (var fs = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None)) fs.Write(new byte[4096]);
            double seconds = o.Seconds(10.0), t0 = Timing.Now(), now = t0;
            long ops = 0;
            do { using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1)) { } ops++; now = Timing.Now(); } while (now - t0 < seconds);
            var m = Measure.Ok("fsl.openclose", "ops/s", true, ops / (now - t0));
            m.Detail["ops"] = ops;
            return m;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return Measure.Not("fsl.openclose", "ops/s", true, "failed", e.Message); }
        finally { try { File.Delete(file); } catch { } }
    }

    private static List<Measure> Metadata(Options o)
    {
        Log.Progress("share: metadata");
        string root = Path.Combine(o.Dir!, "meta");
        int files = Math.Max(MetaFolders, (int)(MetaFiles * o.DataScale));
        try
        {
            Directory.CreateDirectory(root);
            for (int f = 0; f < MetaFolders; f++) Directory.CreateDirectory(Path.Combine(root, "d" + f));
            var paths = new string[files];
            for (int i = 0; i < files; i++) paths[i] = Path.Combine(root, "d" + (i % MetaFolders), "f" + i + ".dat");
            var payload = new byte[4096];
            new Rng(5151).NextU64();
            double t0 = Timing.Now();
            foreach (var p in paths) { using var fs = new FileStream(p, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096); fs.Write(payload); }
            double t1 = Timing.Now();
            long total = 0;
            foreach (var p in paths) total += new FileInfo(p).Length;
            double t2 = Timing.Now();
            foreach (var p in paths) File.Delete(p);
            double t3 = Timing.Now();
            if (total != 4096L * files) return new() { Measure.Not("fsl.meta.create", "files/s", true, "failed", "a file had a wrong length") };
            return new()
            {
                Measure.Ok("fsl.meta.create", "files/s", true, files / (t1 - t0)),
                Measure.Ok("fsl.meta.stat", "files/s", true, files / (t2 - t1)),
                Measure.Ok("fsl.meta.delete", "files/s", true, files / (t3 - t2)),
            };
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new[] { "fsl.meta.create", "fsl.meta.stat", "fsl.meta.delete" }.Select(id => Measure.Not(id, "files/s", true, "failed", e.Message)).ToList();
        }
        finally { try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { } }
    }
}
