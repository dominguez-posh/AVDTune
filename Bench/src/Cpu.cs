using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AVDTune.Bench;

/// <summary>Workloads of the CPU mix (design 1.1): Deflate, JSON, regex, sort. Each factory builds its own data and returns one iteration.</summary>
public static class Workloads
{
    public sealed record Workload(string Name, Func<Options, ulong, Func<long>> Factory);

    public const int CorpusBytes = 32 * 1024 * 1024;
    public const int JsonBytes = 10 * 1024 * 1024;
    public const int LogChars = 20 * 1024 * 1024;
    public const int SortStrings = 2_000_000;

    public static readonly Workload[] Mix =
    {
        new("deflate", (o, seed) => Deflate(DataGen.TextCorpus(seed, o.Size(CorpusBytes)))),
        new("json", (o, seed) => Json(DataGen.JsonDocument(seed, o.Size(JsonBytes)))),
        new("regex", (o, seed) => RegexSearch(DataGen.LogLines(seed, o.Size(LogChars)))),
        new("sort", (o, seed) => Sort(DataGen.Strings(seed, Math.Max(1000, (int)(SortStrings * o.DataScale))))),
    };

    /// <summary>Compress and decompress; the checksum is the length of the decompressed data (always the input length).</summary>
    public static Func<long> Deflate(byte[] data)
    {
        var compressed = new MemoryStream(data.Length / 2);
        var restored = new byte[data.Length];
        return () =>
        {
            compressed.SetLength(0);
            using (var z = new DeflateStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data, 0, data.Length);
            compressed.Position = 0;
            int total = 0;
            using (var d = new DeflateStream(compressed, CompressionMode.Decompress, leaveOpen: true))
            {
                int n;
                while ((n = d.Read(restored, total, restored.Length - total)) > 0) total += n;
            }
            return total;
        };
    }

    /// <summary>Parse the document and write it again; the checksum is the number of top-level items.</summary>
    public static Func<long> Json(byte[] document)
    {
        var output = new MemoryStream(document.Length + 4096);
        return () =>
        {
            using var doc = JsonDocument.Parse(document);
            output.SetLength(0);
            using (var w = new Utf8JsonWriter(output)) doc.WriteTo(w);
            return doc.RootElement.GetArrayLength();
        };
    }

    private static readonly Regex LogPattern = new(@"(?<lvl>ERROR|WARN)\s+\[(?<comp>\w+)\]\s+user=(?<user>\d+)\s+session=(?<sess>\d+)", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>Regex search over the log; the checksum is the number of matches.</summary>
    public static Func<long> RegexSearch(string log) => () => LogPattern.Count(log);

    /// <summary>Ordinal sort of a copy; the checksum is a hash of a few sorted elements and the length.</summary>
    public static Func<long> Sort(string[] source)
    {
        var work = new string[source.Length];
        return () =>
        {
            Array.Copy(source, work, source.Length);
            Array.Sort(work, StringComparer.Ordinal);
            return SortChecksum(work);
        };
    }

    public static long SortChecksum(string[] sorted)
    {
        long h = sorted.Length;
        for (int i = 0; i < sorted.Length; i += Math.Max(1, sorted.Length / 7)) { long c = 17; foreach (char ch in sorted[i]) c = (c * 131 + ch) % 1000003; h = (h * 31 + c) & 0x7FFFFFFFFFFFL; }
        return h;
    }
}

public static class Cpu
{
    /// <summary>Runs <paramref name="factory"/> on <paramref name="threads"/> threads (own data each, built before the timer): warm-up, then a timed window.
    /// A window ends after the iteration that reaches the time, so the rate is whole iterations over the exact time (no rounding error).
    /// Returns total iterations per second.</summary>
    public static double MeasureRate(Func<ulong, Func<long>> factory, int threads, double warmSeconds, double windowSeconds)
    {
        var actions = new Func<long>[threads];
        var prepared = new Barrier(threads + 1);
        var rates = new double[threads];
        var errors = new Exception?[threads];
        var ts = new List<Thread>();
        for (int t = 0; t < threads; t++)
        {
            int idx = t;
            var th = new Thread(() =>
            {
                try
                {
                    actions[idx] = factory(1000UL + (ulong)idx);
                    prepared.SignalAndWait();
                    var action = actions[idx];
                    double end = Timing.Now() + warmSeconds;
                    do { action(); } while (Timing.Now() < end);
                    double start = Timing.Now(), now = start;
                    long n = 0;
                    do { action(); n++; now = Timing.Now(); } while (now - start < windowSeconds);
                    rates[idx] = n / (now - start);
                }
                catch (Exception e) { errors[idx] = e; try { prepared.RemoveParticipant(); } catch { } }
            }, 16 * 1024 * 1024);
            th.IsBackground = true;
            ts.Add(th); th.Start();
        }
        prepared.SignalAndWait();
        foreach (var th in ts) th.Join();
        foreach (var e in errors) if (e != null) throw e;
        for (int t = 0; t < threads; t++) actions[t] = null!;
        GC.Collect(); GC.WaitForPendingFinalizers();
        return rates.Sum();
    }

    /// <summary>Mix iterations per second: one iteration is all four workloads, so its time is the sum of the four times.</summary>
    public static double MixRate(IReadOnlyList<double> rates) => 1.0 / rates.Sum(r => 1.0 / r);

    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        double warm = o.Seconds(1.0), window = o.Seconds(3.0);
        int threads = Math.Max(1, o.Threads);

        double[] RatesFor(int n)
        {
            var rates = new double[Workloads.Mix.Length];
            for (int i = 0; i < rates.Length; i++)
            {
                var w = Workloads.Mix[i];
                Log.Progress($"cpu: {w.Name} on {n} thread(s)");
                rates[i] = MeasureRate(seed => w.Factory(o, seed), n, warm, window);
            }
            return rates;
        }

        var single = RatesFor(1);
        var m1 = Measure.Ok("host.cpu.single", "iterations/s", true, MixRate(single));
        AddWorkloadDetail(m1, single);
        list.Add(m1);

        double[]? multi = null;
        if (threads > 1)
        {
            multi = RatesFor(threads);
            var mm = Measure.Ok("host.cpu.multi", "iterations/s", true, MixRate(multi));
            AddWorkloadDetail(mm, multi);
            mm.Detail["threads"] = threads;
            list.Add(mm);
        }
        else list.Add(Measure.Not("host.cpu.multi", "iterations/s", true, "skipped", "one logical processor"));

        if (o.Sustained)
        {
            if (multi == null) list.Add(Measure.Not("host.cpu.sustained", "ratio", true, "skipped", "one logical processor"));
            else list.Add(Sustained(o, threads, multi));
        }

        Log.Progress("cpu: aes");
        list.Add(Measure.Ok("host.cpu.aes", "GB/s", true, Aes(o.Seconds(3.0))));
        Log.Progress("cpu: sha");
        list.Add(Measure.Ok("host.cpu.sha", "GB/s", true, Sha(o.Seconds(3.0))));
        return list;
    }

    private static void AddWorkloadDetail(Measure m, double[] rates)
    {
        for (int i = 0; i < rates.Length; i++) m.Detail[Workloads.Mix[i].Name + "PerSec"] = Math.Round(rates[i], 4);
    }

    /// <summary>Multi mix for 60 s (scaled); throughput of the last 10 s over the first 10 s (design: throttling, noisy neighbour, credits).</summary>
    public static Measure Sustained(Options o, int threads, double[] multiRates)
    {
        Log.Progress("cpu: sustained");
        double total = o.Seconds(60.0), part = o.Seconds(10.0);
        // work units: one completed workload iteration is its share of one mix iteration (time share from the multi rates)
        double sumInv = multiRates.Sum(r => 1.0 / r);
        var unit = multiRates.Select(r => (1.0 / r) / sumInv).ToArray();
        int buckets = (int)Math.Ceiling(total / part * 4) + 4;     // quarter-"part" buckets
        double bucketLen = part / 4;
        var sums = new double[threads][];
        double t0 = 0;
        var prepared = new Barrier(threads + 1, _ => t0 = Timing.Now());
        var ts = new List<Thread>();
        var errors = new Exception?[threads];
        for (int t = 0; t < threads; t++)
        {
            int idx = t;
            sums[idx] = new double[buckets];
            var th = new Thread(() =>
            {
                try
                {
                    var actions = Workloads.Mix.Select(w => w.Factory(o, 2000UL + (ulong)idx)).ToArray();
                    prepared.SignalAndWait();
                    double end = t0 + total;
                    int w = 0;
                    while (true)
                    {
                        actions[w]();
                        double now = Timing.Now();
                        if (now >= end) break;
                        int b = (int)((now - t0) / bucketLen);
                        if (b < buckets) sums[idx][b] += unit[w];
                        w = (w + 1) % actions.Length;
                    }
                }
                catch (Exception e) { errors[idx] = e; try { prepared.RemoveParticipant(); } catch { } }
            }, 16 * 1024 * 1024) { IsBackground = true };
            ts.Add(th); th.Start();
        }
        prepared.SignalAndWait();
        foreach (var th in ts) th.Join();
        foreach (var e in errors) if (e != null) throw e;
        var perBucket = new double[buckets];
        for (int b = 0; b < buckets; b++) perBucket[b] = sums.Sum(s => s[b]);
        int partBuckets = 4;
        int lastStart = (int)Math.Floor(total / bucketLen) - partBuckets;
        double first = perBucket.Take(partBuckets).Sum(), last = perBucket.Skip(Math.Max(partBuckets, lastStart)).Take(partBuckets).Sum();
        GC.Collect();
        if (first <= 0) return Measure.Not("host.cpu.sustained", "ratio", true, "failed", "no work completed in the first window");
        var m = Measure.Ok("host.cpu.sustained", "ratio", true, last / first);
        m.Detail["firstWindowUnits"] = Math.Round(first, 3);
        m.Detail["lastWindowUnits"] = Math.Round(last, 3);
        m.Detail["threads"] = threads;
        return m;
    }

    /// <summary>AES-256-GCM encrypt, 64 KB blocks, 1 thread, GB/s.</summary>
    public static double Aes(double seconds)
    {
        var key = new byte[32];
        var rng = new Rng(11);
        for (int i = 0; i < key.Length; i++) key[i] = (byte)rng.NextU32();
        var plain = new byte[65536]; for (int i = 0; i < plain.Length; i++) plain[i] = (byte)rng.NextU32();
        var cipher = new byte[65536];
        var tag = new byte[16];
        var nonce = new byte[12];
        using var gcm = new AesGcm(key, 16);
        for (int i = 0; i < 50; i++) gcm.Encrypt(nonce, plain, cipher, tag);
        long blocks = 0; ulong counter = 0;
        double start = Timing.Now(), now = start;
        do
        {
            for (int i = 0; i < 64; i++)
            {
                BitConverter.TryWriteBytes(nonce, counter++);
                gcm.Encrypt(nonce, plain, cipher, tag);
            }
            blocks += 64; now = Timing.Now();
        } while (now - start < seconds);
        return blocks * 65536.0 / (now - start) / 1e9;
    }

    /// <summary>SHA-256, 64 KB blocks, 1 thread, GB/s.</summary>
    public static double Sha(double seconds)
    {
        var data = new byte[65536]; var rng = new Rng(12); for (int i = 0; i < data.Length; i++) data[i] = (byte)rng.NextU32();
        var hash = new byte[32];
        for (int i = 0; i < 50; i++) SHA256.HashData(data, hash);
        long blocks = 0;
        double start = Timing.Now(), now = start;
        do
        {
            for (int i = 0; i < 64; i++) SHA256.HashData(data, hash);
            blocks += 64; now = Timing.Now();
        } while (now - start < seconds);
        return blocks * 65536.0 / (now - start) / 1e9;
    }
}
