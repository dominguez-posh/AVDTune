namespace AVDTune.Bench;

/// <summary>Small-file test (design 1.1, host.disk.smallfiles): create 5000 files of 4 to 64 KB in 50 folders, read them all, delete them all,
/// through the normal Windows cache (so Defender and filter drivers are included). Files per second over the three phases.</summary>
public static class FilesBench
{
    public const int Files = 5000, Folders = 50;

    public static List<Measure> Run(Options o)
    {
        if (string.IsNullOrWhiteSpace(o.Dir)) return new() { Measure.Not("host.disk.smallfiles", "files/s", true, "failed", "--dir is needed") };
        if (!Directory.Exists(o.Dir)) return new() { Measure.Not("host.disk.smallfiles", "files/s", true, "failed", "the work folder does not exist") };
        int files = Math.Max(Folders, (int)(Files * o.DataScale));
        var root = Path.Combine(o.Dir, "files-" + Guid.NewGuid().ToString("N"));
        Log.Progress("files: small files");
        try
        {
            Directory.CreateDirectory(root);
            var (c, r, d) = Execute(root, files);
            double total = c + r + d;
            var m = Measure.Ok("host.disk.smallfiles", "files/s", true, 3.0 * files / total);
            m.Detail["files"] = files;
            m.Detail["createFilesPerSec"] = Math.Round(files / c, 1);
            m.Detail["readFilesPerSec"] = Math.Round(files / r, 1);
            m.Detail["deleteFilesPerSec"] = Math.Round(files / d, 1);
            return new() { m };
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new() { Measure.Not("host.disk.smallfiles", "files/s", true, "failed", e.Message) };
        }
        finally
        {
            try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { }
        }
    }

    /// <summary>Returns the seconds of the create, read and delete phase.</summary>
    public static (double Create, double Read, double Delete) Execute(string root, int files)
    {
        var rng = new Rng(4242);
        var sizes = new int[files];
        for (int i = 0; i < files; i++) sizes[i] = (4 + rng.Next(61)) * 1024;
        var payload = new byte[64 * 1024];
        for (int i = 0; i < payload.Length; i++) payload[i] = (byte)rng.NextU32();
        var paths = new string[files];
        for (int f = 0; f < Folders; f++) Directory.CreateDirectory(Path.Combine(root, "d" + f));
        for (int i = 0; i < files; i++) paths[i] = Path.Combine(root, "d" + (i % Folders), "f" + i + ".dat");

        double t0 = Timing.Now();
        for (int i = 0; i < files; i++)
        {
            using var fs = new FileStream(paths[i], FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096);
            fs.Write(payload, 0, sizes[i]);
        }
        double t1 = Timing.Now();
        var buf = new byte[64 * 1024];
        long read = 0;
        for (int i = 0; i < files; i++)
        {
            using var fs = new FileStream(paths[i], FileMode.Open, FileAccess.Read, FileShare.Read, 4096);
            int n; while ((n = fs.Read(buf, 0, buf.Length)) > 0) read += n;
        }
        double t2 = Timing.Now();
        for (int i = 0; i < files; i++) File.Delete(paths[i]);
        double t3 = Timing.Now();
        if (read != sizes.Sum(s => (long)s)) throw new IOException("A file was read with a wrong length.");
        return (t1 - t0, t2 - t1, t3 - t2);
    }
}
