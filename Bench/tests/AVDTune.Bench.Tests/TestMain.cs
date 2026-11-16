using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AVDTune.Bench.Tests;

public static class TestMain
{
    private static int _failed;
    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) Console.WriteLine("PASS " + name);
        else { _failed++; Console.WriteLine("FAIL " + name + (detail != "" ? "  -> " + detail : "")); }
    }
    private static bool Near(double a, double b, double tol) => Math.Abs(a - b) <= tol;
    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).Substring(0, 16);
    private static bool Throws(Action a) { try { a(); return false; } catch { return true; } }

    public static int Main(string[] args)
    {
        bool print = args.Contains("--print");
        Evaluation();
        Determinism(print);
        Workloads(print);
        Clips(print);
        Files();
        OptionsAndJson();
        _failed += Round2.Run();
        Console.WriteLine(_failed == 0 ? "ALL OK" + (Round2.NotRun > 0 ? $" ({Round2.NotRun} group of live launcher checks NOT RUN: not elevated)" : "") : $"{_failed} FAILED");
        return _failed == 0 ? 0 : 1;
    }

    private static void Evaluation()
    {
        Check("median: odd count", AVDTune.Bench.Evaluation.Median(new[] { 3.0, 1.0, 2.0 }) == 2.0);
        Check("median: even count is the mean of the middle two", AVDTune.Bench.Evaluation.Median(new[] { 4.0, 1.0, 3.0, 2.0 }) == 2.5);
        Check("median of one value", AVDTune.Bench.Evaluation.Median(new[] { 7.0 }) == 7.0);
        Check("median of nothing throws", Throws(() => AVDTune.Bench.Evaluation.Median(Array.Empty<double>())));
        var runs = new[] { 1180.0, 1175.0, 1210.0 };
        Check("CV of the design example (1180, 1175, 1210) is 1.6 percent", Near(AVDTune.Bench.Evaluation.CvPercent(runs), 1.6, 0.05), AVDTune.Bench.Evaluation.CvPercent(runs).ToString());
        Check("CV 1.6 percent is stable", !AVDTune.Bench.Evaluation.IsUnstable(runs));
        Check("CV above 10 percent is unstable", AVDTune.Bench.Evaluation.IsUnstable(new[] { 100.0, 130.0, 80.0 }));
        Check("CV of a single value is 0", AVDTune.Bench.Evaluation.CvPercent(new[] { 5.0 }) == 0);
        Check("index: higher is better", Near(AVDTune.Bench.Evaluation.Index(18500, 12000, true), 1541.67, 0.01));
        Check("index: lower is better", Near(AVDTune.Bench.Evaluation.Index(0.080, 0.105, false), 1312.5, 0.001));
        Check("index: the reference itself is 1000", AVDTune.Bench.Evaluation.Index(42, 42, true) == 1000 && AVDTune.Bench.Evaluation.Index(42, 42, false) == 1000);
        Check("index: zero or negative values are refused", Throws(() => AVDTune.Bench.Evaluation.Index(0, 1, true)) && Throws(() => AVDTune.Bench.Evaluation.Index(1, -1, false)));
        // design 2.2, OS disk category
        var disk = new[]
        {
            AVDTune.Bench.Evaluation.RoundIndex(AVDTune.Bench.Evaluation.Index(0.080, 0.105, false)),
            AVDTune.Bench.Evaluation.RoundIndex(AVDTune.Bench.Evaluation.Index(18500, 12000, true)),
            AVDTune.Bench.Evaluation.RoundIndex(AVDTune.Bench.Evaluation.Index(250, 200, true)),
            AVDTune.Bench.Evaluation.RoundIndex(AVDTune.Bench.Evaluation.Index(2400, 1900, true)),
        };
        Check("design example: the four indexes are 1313, 1542, 1250, 1263", disk.SequenceEqual(new[] { 1313.0, 1542.0, 1250.0, 1263.0 }), string.Join(",", disk));
        double category = AVDTune.Bench.Evaluation.GeometricMean(disk);
        Check("design example: OS disk category is 1337", AVDTune.Bench.Evaluation.RoundIndex(category) == 1337, category.ToString());
        // design 2.2, Host score
        var cat = new[] { 1180.0, 960, 1420, 1050, 1000, 880 };
        var weights = new[] { 25.0, 10, 20, 30, 10, 5 };
        double host = AVDTune.Bench.Evaluation.WeightedGeometricMean(cat, weights);
        Check("design example: Host score is 1123", AVDTune.Bench.Evaluation.RoundIndex(host) == 1123, host.ToString());
        Check("design example: the arithmetic mean would be 1134", AVDTune.Bench.Evaluation.RoundIndex(cat.Zip(weights, (c, w) => c * w).Sum() / weights.Sum()) == 1134);
        Check("weighted geometric mean: equal weights equal the geometric mean", Near(AVDTune.Bench.Evaluation.WeightedGeometricMean(new[] { 100.0, 400 }, new[] { 1.0, 1 }), 200, 1e-9));
        Check("weighted geometric mean: weights are relative (any scale)", Near(AVDTune.Bench.Evaluation.WeightedGeometricMean(cat, weights.Select(w => w * 7).ToArray()), host, 1e-9));
        Check("weighted geometric mean: a missing category is left out of the sum", Near(AVDTune.Bench.Evaluation.WeightedGeometricMean(new[] { 1000.0, 2000 }, new[] { 25.0, 25 }), Math.Sqrt(2_000_000), 1e-9));
        Check("weighted geometric mean: mismatched lengths are refused", Throws(() => AVDTune.Bench.Evaluation.WeightedGeometricMean(new[] { 1.0 }, new[] { 1.0, 2 })));
    }

    private static void Determinism(bool print)
    {
        var rng = new Rng(42);
        var first = new[] { rng.NextU64(), rng.NextU64(), rng.NextU64() };
        var again = new Rng(42);
        Check("Rng: same seed, same sequence", first[0] == again.NextU64() && first[1] == again.NextU64() && first[2] == again.NextU64());
        Check("Rng: Next(n) stays in range", Enumerable.Range(0, 10000).All(_ => { int v = rng.Next(7); return v >= 0 && v < 7; }));
        Check("Rng: a different seed gives a different sequence", new Rng(43).NextU64() != first[0]);
        var shown = new Dictionary<string, string>
        {
            ["rng42"] = first[0].ToString("X16"),
            ["text"] = Sha(DataGen.TextCorpus(1, 100_000)),
            ["json"] = Sha(DataGen.JsonDocument(2, 100_000)),
            ["log"] = Sha(Encoding.UTF8.GetBytes(DataGen.LogLines(3, 100_000))),
            ["strings"] = Sha(Encoding.UTF8.GetBytes(string.Join("|", DataGen.Strings(4, 1000)))),
        };
        if (print) foreach (var kv in shown) Console.WriteLine($"PIN {kv.Key} {kv.Value}");
        // pinned on the first run: a change of any generator changes every reference value, so it needs a new benchmark major version
        var pins = Pins.Data;
        foreach (var kv in shown) Check($"data is deterministic: {kv.Key} matches its pinned hash", pins.TryGetValue(kv.Key, out var p) && p == kv.Value, $"{kv.Value}");
        Check("text corpus has the exact size", DataGen.TextCorpus(1, 12345).Length == 12345);
        Check("json document parses and is an array", JsonDocument.Parse(DataGen.JsonDocument(2, 50_000)).RootElement.ValueKind == JsonValueKind.Array);
    }

    private static void Workloads(bool print)
    {
        var o = new Options { DataScale = 0.01 };
        var deflate = AVDTune.Bench.Workloads.Deflate(DataGen.TextCorpus(1, 200_000));
        Check("deflate: the data survives the round trip (length)", deflate() == 200_000 && deflate() == 200_000);
        var json = AVDTune.Bench.Workloads.Json(DataGen.JsonDocument(2, 100_000));
        long items = json();
        Check("json: item count is stable between iterations", items > 50 && json() == items, items.ToString());
        var rx = AVDTune.Bench.Workloads.RegexSearch(DataGen.LogLines(3, 200_000));
        long matches = rx();
        Check("regex: match count is stable and plausible", matches > 100 && rx() == matches, matches.ToString());
        var strings = DataGen.Strings(4, 5000);
        var sorted = (string[])strings.Clone(); Array.Sort(sorted, StringComparer.Ordinal);
        var sort = AVDTune.Bench.Workloads.Sort(strings);
        Check("sort: checksum equals that of an ordinal sort, stable between iterations", sort() == AVDTune.Bench.Workloads.SortChecksum(sorted) && sort() == sort());
        Check("sort: the source array is not changed", strings.SequenceEqual(DataGen.Strings(4, 5000)));
        if (print) Console.WriteLine($"PIN regexMatches {matches} jsonItems {items}");
        Check("regex matches and json items are pinned", Pins.Data["regexMatches"] == matches.ToString() && Pins.Data["jsonItems"] == items.ToString(), $"{matches} {items}");
        // every workload of the mix builds and runs at a tiny size
        foreach (var w in AVDTune.Bench.Workloads.Mix) Check($"mix workload {w.Name} runs at a small data scale", w.Factory(o, 5)() > 0);
        double rate = Cpu.MeasureRate(seed => deflate, 1, 0.05, 0.2);
        Check("MeasureRate returns a positive rate", rate > 0);
        Check("MixRate is the harmonic combination (one iteration is all workloads)", Near(Cpu.MixRate(new[] { 2.0, 2.0 }), 1.0, 1e-12) && Near(Cpu.MixRate(new[] { 1.0, 4.0 }), 0.8, 1e-12));
        Check("AES and SHA give a positive rate", Cpu.Aes(0.1) > 0 && Cpu.Sha(0.1) > 0);
    }

    private static void Clips(bool print)
    {
        var d = Display.DesktopClip(320, 180, 6);
        var v = Display.VideoClip(320, 180, 6);
        Check("clip frames are NV12 sized (w x h x 3/2)", d.All(f => f.Length == 320 * 180 * 3 / 2) && v.All(f => f.Length == 320 * 180 * 3 / 2));
        Check("desktop clip: consecutive frames differ (scroll, window, cursor)", !d[0].AsSpan().SequenceEqual(d[1]));
        Check("video clip: consecutive frames differ", !v[0].AsSpan().SequenceEqual(v[1]));
        Check("clips are deterministic (generated twice, same hash)", Display.ClipHash(d) == Display.ClipHash(Display.DesktopClip(320, 180, 6)) && Display.ClipHash(v) == Display.ClipHash(Display.VideoClip(320, 180, 6)));
        if (print) Console.WriteLine($"PIN desktopClip {Display.ClipHash(d).Substring(0, 16)} videoClip {Display.ClipHash(v).Substring(0, 16)}");
        Check("clips match their pinned hashes", Display.ClipHash(d).Substring(0, 16) == Pins.Data["desktopClip"] && Display.ClipHash(v).Substring(0, 16) == Pins.Data["videoClip"]);
    }

    private static void Files()
    {
        var dir = Path.Combine(Path.GetTempPath(), "avdtune-bench-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var o = new Options { Dir = dir, DataScale = 0.02 };
            var r = FilesBench.Run(o);
            Check("files: a measure host.disk.smallfiles with a positive rate", r.Count == 1 && r[0].Id == "host.disk.smallfiles" && r[0].Status == "ok" && r[0].Value > 0, r.Count > 0 ? r[0].Reason : "");
            Check("files: the work sub folder is removed afterwards", Directory.GetFileSystemEntries(dir).Length == 0);
            Check("files: a missing work folder is a failed measure, not a crash", FilesBench.Run(new Options { Dir = Path.Combine(dir, "nope") })[0].Status == "failed");
            Check("files: no work folder given is a failed measure", FilesBench.Run(new Options())[0].Status == "failed");
        }
        finally { Directory.Delete(dir, true); }
    }

    private static void OptionsAndJson()
    {
        var o = Options.Parse(new[] { "cpu", "--scale", "0.5", "--threads", "4", "--sustained", "--quiet" });
        Check("options: command, scale, threads, sustained, quiet", o.Command == "cpu" && o.Scale == 0.5 && o.Threads == 4 && o.Sustained && o.Quiet);
        Check("options: unknown option, bad scale and a second command are refused", Throws(() => Options.Parse(new[] { "cpu", "--nope" })) && Throws(() => Options.Parse(new[] { "cpu", "--scale", "0" })) && Throws(() => Options.Parse(new[] { "cpu", "mem" })));
        Check("options: a missing value is refused", Throws(() => Options.Parse(new[] { "cpu", "--scale" })));
        var m = Measure.Ok("host.cpu.aes", "GB/s", true, 5.5);
        m.Detail["threads"] = 4;
        var skipped = Measure.Not("host.disp.h264.video", "frames/s", true, "skipped", "no encoder");
        var text = Json.Result("cpu", o, DateTime.UtcNow, 1.234, new[] { m, skipped }, new Dictionary<string, object?> { ["note"] = "x" });
        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        Check("json: schema version, benchmark version, command, system block", root.GetProperty("schemaVersion").GetInt32() == 1 && root.GetProperty("benchmarkVersion").GetString() == Program.BenchmarkVersion && root.GetProperty("command").GetString() == "cpu" && root.GetProperty("system").GetProperty("logicalProcessors").GetInt32() > 0);
        var ms = root.GetProperty("measures");
        Check("json: a measure carries id, unit, better, value, status", ms[0].GetProperty("id").GetString() == "host.cpu.aes" && ms[0].GetProperty("better").GetString() == "higher" && ms[0].GetProperty("value").GetDouble() == 5.5 && ms[0].GetProperty("status").GetString() == "ok" && ms[0].GetProperty("detail").GetProperty("threads").GetInt32() == 4);
        Check("json: a skipped measure has a null value and its reason", ms[1].GetProperty("value").ValueKind == JsonValueKind.Null && ms[1].GetProperty("status").GetString() == "skipped" && ms[1].GetProperty("reason").GetString() == "no encoder");
        var nan = Json.Result("cpu", o, DateTime.UtcNow, 1, new[] { new Measure { Id = "x", Value = double.NaN } });
        Check("json: NaN never reaches the output (null)", JsonDocument.Parse(nan).RootElement.GetProperty("measures")[0].GetProperty("value").ValueKind == JsonValueKind.Null);
        Check("system facts: CPU model, physical cores and memory are read", SystemInfo.CpuModel().Length > 0 && SystemInfo.PhysicalCores() >= 1 && SystemInfo.Memory().TotalGiB > 0.5);
    }
}

internal static class Pins
{
    public static readonly Dictionary<string, string> Data = new()
    {
        ["rng42"] = "56CE4AB7719BA3A0", ["text"] = "0EB91F51B056161B", ["json"] = "E34E2E1840CFE2C5", ["log"] = "05C40804D7E619D7", ["strings"] = "E558F8994B1A3DA8",
        ["regexMatches"] = "664", ["jsonItems"] = "723", ["desktopClip"] = "415CA4B35FB53871", ["videoClip"] = "044ACD8804933782",
    };
}
