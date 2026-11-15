using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;

namespace AVDTune.Bench;

/// <summary>The pure parts of the capacity simulation (design 4): level sequence, the threshold and the interpolated number of users, percentiles.</summary>
public static class CapacityMath
{
    public const double ThresholdFactor = 1.5;   // the median total response time of a probe cycle 50 % above the level-1 value

    /// <summary>1, 2, 4, 6, 8, then +4 per level, up to 4 x vCPU (and at most <paramref name="max"/> when given).</summary>
    public static List<int> LevelSequence(int vCpu, int? max = null)
    {
        int cap = Math.Min(4 * Math.Max(1, vCpu), max ?? int.MaxValue);
        var list = new List<int>();
        foreach (int u in new[] { 1, 2, 4, 6, 8 }) if (u <= cap) list.Add(u);
        for (int u = 12; u <= cap; u += 4) list.Add(u);
        if (list.Count == 0) list.Add(1);
        return list;
    }

    /// <summary>Capacity = users at the crossing, interpolated linearly between the two levels around it. Null when the threshold was not reached (then the capacity is "at least the last level").</summary>
    public static double? Estimate(IReadOnlyList<(int Users, double Median)> levels, double factor = ThresholdFactor)
    {
        var first = levels.FirstOrDefault(l => l.Users == 1);
        if (first.Users != 1 || first.Median <= 0) return null;
        double limit = first.Median * factor;
        for (int i = 0; i < levels.Count; i++)
        {
            if (levels[i].Users <= 1 || levels[i].Median < limit) continue;
            var prev = levels[i - 1]; var cur = levels[i];
            if (cur.Median <= prev.Median) return cur.Users;
            return prev.Users + (limit - prev.Median) / (cur.Median - prev.Median) * (cur.Users - prev.Users);
        }
        return null;
    }

    /// <summary>The last two levels are both above the limit (the stop rule: passed by two levels).</summary>
    public static bool PassedTwice(IReadOnlyList<(int Users, double Median)> levels, double factor = ThresholdFactor)
    {
        var first = levels.FirstOrDefault(l => l.Users == 1);
        if (first.Users != 1 || levels.Count < 3) return false;
        double limit = first.Median * factor;
        return levels[^1].Median >= limit && levels[^2].Median >= limit && levels[^1].Users > 1 && levels[^2].Users > 1;
    }

    public static double Percentile(IReadOnlyList<double> values, double percent)
    {
        if (values.Count == 0) throw new ArgumentException("No values.");
        var s = values.OrderBy(v => v).ToArray();
        int rank = (int)Math.Ceiling(percent / 100.0 * s.Length);
        return s[Math.Clamp(rank - 1, 0, s.Length - 1)];
    }
}

/// <summary>What one probe user costs per minute (measured while the probe runs alone). The load workers replay it.</summary>
public sealed record Footprint(double CpuSecPerMin, double WorkingSetMB, double IoOpsPerMin, double IoMBPerMin)
{
    public static Footprint FromDeltas(double cpuSeconds, long peakWorkingSetBytes, long ioOps, long ioBytes, double elapsedSeconds)
    {
        if (elapsedSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(elapsedSeconds));
        double perMin = 60.0 / elapsedSeconds;
        return new Footprint(Math.Round(cpuSeconds * perMin, 2), Math.Round(peakWorkingSetBytes / 1048576.0, 1), Math.Round(ioOps * perMin, 1), Math.Round(ioBytes / 1048576.0 * perMin, 2));
    }
    /// <summary>Share of one core a worker keeps busy (0 to 1).</summary>
    public double CpuDuty => Math.Clamp(CpuSecPerMin / 60.0, 0, 1);
}

/// <summary>The probe: one simulated knowledge worker, in the session of the administrator who runs AVDTune. 12 timed steps of the actions below, with idle pauses of 2 to 5 s in between.
/// Not UI Automation (the self-contained runtime has no managed wrapper without a third-party library): each action is a reproducible piece of work with the cost pattern of its
/// application (CPU burst, memory, small files, a process start), timed from start to end. It touches no window and sends no input.</summary>
public sealed class Probe : IDisposable
{
    public static readonly string[] Actions = { "document", "spreadsheet", "mail", "web", "pdf", "files", "start" };
    private readonly Func<long> _doc, _sheet, _mail, _web;
    private readonly string _dir;
    private readonly string? _powershell;
    private readonly Rng _rng = new(9001);
    private readonly double _idleScale;
    private byte[]? _pdf;

    public Probe(string dir, string? powershell, double idleScale)
    {
        _dir = dir; _powershell = powershell; _idleScale = idleScale;
        Directory.CreateDirectory(Path.Combine(dir, "src"));
        _doc = Workloads.Deflate(DataGen.TextCorpus(11, 2 << 20));
        _sheet = Workloads.Sort(DataGen.Strings(12, 80_000));
        _mail = Workloads.RegexSearch(DataGen.LogLines(13, 1 << 20));
        _web = Workloads.Json(DataGen.JsonDocument(14, 1 << 20));
        var payload = new byte[16 * 1024]; new Random(1).NextBytes(payload);
        for (int i = 0; i < 200; i++) File.WriteAllBytes(Path.Combine(dir, "src", $"f{i:D3}.dat"), payload);
    }

    private static double Time(Action a) { double t0 = Timing.Now(); a(); return (Timing.Now() - t0) * 1000.0; }

    /// <summary>One cycle: the response time in milliseconds of every action (an action that cannot run is left out).</summary>
    public Dictionary<string, double> RunCycle(Func<bool> stop)
    {
        var r = new Dictionary<string, double>();
        void Idle() { int ms = (int)((2000 + _rng.Next(3000)) * _idleScale); for (int t = 0; t < ms && !stop(); t += 50) Thread.Sleep(50); }
        r["document"] = Time(() => { _doc(); _mail(); }); Idle();
        r["spreadsheet"] = Time(() => { _sheet(); _web(); }); Idle();
        r["mail"] = Time(() => { _mail(); _mail(); }); Idle();
        r["web"] = Time(() => { _web(); _doc(); }); Idle();
        r["pdf"] = Time(() =>
        {
            _pdf ??= new byte[48 << 20];
            for (int i = 0; i < _pdf.Length; i += 4096) _pdf[i] = (byte)i;   // pages touched (open, scroll)
            var zoom = new byte[16 << 20]; Buffer.BlockCopy(_pdf, 0, zoom, 0, zoom.Length);
        }); Idle();
        r["files"] = Time(() => CopyAndZip()); Idle();
        if (_powershell != null) { double? ms = StartShell(); if (ms != null) r["start"] = ms.Value; Idle(); }
        return r;
    }

    private void CopyAndZip()
    {
        string dst = Path.Combine(_dir, "dst"), zip = Path.Combine(_dir, "out.zip");
        try
        {
            if (Directory.Exists(dst)) Directory.Delete(dst, true);
            if (File.Exists(zip)) File.Delete(zip);
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(Path.Combine(_dir, "src"))) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)));
            ZipFile.CreateFromDirectory(dst, zip, CompressionLevel.Fastest, false);
        }
        finally { try { Directory.Delete(dst, true); } catch { } try { File.Delete(zip); } catch { } }
    }

    private double? StartShell()
    {
        try
        {
            using var job = new JobGroup();
            var psi = new ProcessStartInfo(_powershell!) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = _dir };
            foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-Command", "exit" }) psi.ArgumentList.Add(a);
            double t0 = Timing.Now();
            using var p = Process.Start(psi);
            if (p == null) return null;
            job.Assign(p);
            if (!p.WaitForExit(30000)) return null;
            return (Timing.Now() - t0) * 1000.0;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
    }

    public void Dispose() { _pdf = null; }
}

/// <summary>Counters of this machine: CPU percent (GetSystemTimes), memory and commit (GlobalMemoryStatusEx), disk queue (PDH, the English counter name).</summary>
public sealed class SystemSampler : IDisposable
{
    [DllImport("kernel32.dll")] private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern int PdhOpenQueryW(string? source, IntPtr user, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern int PdhAddEnglishCounterW(IntPtr query, string path, IntPtr user, out IntPtr counter);
    [DllImport("pdh.dll")] private static extern int PdhCollectQueryData(IntPtr query);
    [StructLayout(LayoutKind.Explicit)] private struct FmtValue { [FieldOffset(0)] public uint Status; [FieldOffset(8)] public double Value; }
    [DllImport("pdh.dll")] private static extern int PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out FmtValue value);
    [DllImport("pdh.dll")] private static extern int PdhCloseQuery(IntPtr query);
    [StructLayout(LayoutKind.Sequential)] private struct MemStatus { public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExt; }
    [DllImport("kernel32.dll")] private static extern bool GlobalMemoryStatusEx(ref MemStatus s);
    [DllImport("kernel32.dll")] private static extern bool GetProcessIoCounters(IntPtr process, out IoCounters c);
    [StructLayout(LayoutKind.Sequential)] public struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

    private IntPtr _query, _queue;
    private long _i0, _k0, _u0;
    public readonly List<double> Cpu = new(), Queue = new();
    public double MinAvailMB = double.MaxValue, MaxCommitPercent;

    public SystemSampler()
    {
        GetSystemTimes(out _i0, out _k0, out _u0);
        try { if (PdhOpenQueryW(null, IntPtr.Zero, out _query) == 0 && PdhAddEnglishCounterW(_query, @"\PhysicalDisk(_Total)\Current Disk Queue Length", IntPtr.Zero, out _queue) == 0) PdhCollectQueryData(_query); else _query = IntPtr.Zero; }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { _query = IntPtr.Zero; }
    }

    public static (double CommitPercent, double AvailMB) Memory()
    {
        var m = new MemStatus { Length = (uint)Marshal.SizeOf<MemStatus>() };
        GlobalMemoryStatusEx(ref m);
        return (m.TotalPage == 0 ? 0 : (m.TotalPage - m.AvailPage) * 100.0 / m.TotalPage, m.AvailPhys / 1048576.0);
    }

    public static IoCounters Io() { GetProcessIoCounters(Process.GetCurrentProcess().Handle, out var c); return c; }

    /// <summary>One sample: adds to the lists, returns the commit percent.</summary>
    public double Sample()
    {
        if (GetSystemTimes(out long i, out long k, out long u))
        {
            long di = i - _i0, dk = k - _k0, du = u - _u0;
            long total = dk + du;   // kernel time includes idle
            if (total > 0) Cpu.Add(Math.Clamp((total - di) * 100.0 / total, 0, 100));
            _i0 = i; _k0 = k; _u0 = u;
        }
        var (commit, avail) = Memory();
        MinAvailMB = Math.Min(MinAvailMB, avail); MaxCommitPercent = Math.Max(MaxCommitPercent, commit);
        if (_query != IntPtr.Zero && PdhCollectQueryData(_query) == 0 && PdhGetFormattedCounterValue(_queue, 0x200, out _, out var v) == 0 && v.Status == 0) Queue.Add(v.Value);
        return commit;
    }

    public void Reset() { Cpu.Clear(); Queue.Clear(); MinAvailMB = double.MaxValue; MaxCommitPercent = 0; }
    public void Dispose() { if (_query != IntPtr.Zero) { PdhCloseQuery(_query); _query = IntPtr.Zero; } }
}

/// <summary>`load --user n`: one simulated user in the background. Replays the footprint of the probe: CPU work for the measured CPU seconds, a touched working set, small-file I/O, and on
/// VMs without GPU a software H.264 encode of the desktop clip at 1920x1080 and 10 frames/s (the RDP cost of a session, decision D10). Ends after --load-seconds (the capacity run ends the job earlier).</summary>
public static class LoadWorker
{
    public static int Run(Options o)
    {
        if (string.IsNullOrWhiteSpace(o.Dir)) throw new ArgumentException("--dir is needed.");
        Directory.CreateDirectory(o.Dir);
        var fp = new Footprint(o.CpuSecPerMin, o.WorkingSetMB, o.IoOpsPerMin, o.IoMBPerMin);
        var ws = new byte[(long)Math.Clamp(fp.WorkingSetMB, 1, 1024) << 20];
        for (long i = 0; i < ws.LongLength; i += 4096) ws[i] = 1;
        var work = Workloads.Deflate(DataGen.TextCorpus((ulong)(100 + o.UserIndex), 256 * 1024));
        byte[][]? clip = null; bool encode = o.Encode;
        var me = Process.GetCurrentProcess();
        double deadline = Timing.Now() + o.LoadSeconds;
        var payload = new byte[16 * 1024];
        int fileNo = 0;
        while (Timing.Now() < deadline)
        {
            double tick = Timing.Now();
            me.Refresh(); double cpu0 = me.TotalProcessorTime.TotalSeconds;
            double budget = fp.CpuDuty * 1.0;
            while (budget > 0.0005)
            {
                work();
                me.Refresh();
                if (me.TotalProcessorTime.TotalSeconds - cpu0 >= budget || Timing.Now() - tick > 1.0) break;
            }
            int ops = (int)Math.Round(fp.IoOpsPerMin / 60.0);
            for (int i = 0; i < ops; i++)
            {
                string f = Path.Combine(o.Dir, $"w{fileNo++ % 64}.dat");
                File.WriteAllBytes(f, payload); File.ReadAllBytes(f);
            }
            if (encode)
            {
                try { clip ??= Display.DesktopClip(1920, 1080, 10); H264Soft.Encode(clip, 1920, 1080, 10, 4_000_000); }
                catch (Exception e) when (e is InvalidOperationException or COMException or DllNotFoundException) { encode = false; }
            }
            double rest = 1.0 - (Timing.Now() - tick);
            if (rest > 0) Thread.Sleep((int)(rest * 1000));
        }
        GC.KeepAlive(ws);
        return 0;
    }
}

public static class Capacity
{
    public static List<Measure> Run(Options o, out Dictionary<string, object?> info)
    {
        var infoDict = new Dictionary<string, object?>(); info = infoDict;
        if (string.IsNullOrWhiteSpace(o.Dir) || !Directory.Exists(o.Dir)) throw new ArgumentException("--dir (an existing work folder) is needed.");
        string stopFile = Path.Combine(o.Dir, "stop");
        string work = Path.Combine(o.Dir, "cap-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(work);
        int vCpu = Environment.ProcessorCount;
        double idleScale = Math.Max(0.05, o.Scale);
        var workers = new List<(Process P, JobGroup J)>();
        string stopReason = "";
        var levels = new List<Dictionary<string, object?>>();
        var medians = new List<(int Users, double Median)>();
        Footprint? fp = null;
        double started = Timing.Now(), limit = o.Seconds(1800);
        string? shell = o.AppPaths.TryGetValue("powershell", out var sp) && Apps.ValidateExe("powershell", sp, Apps.DefaultRoots()) == null ? Path.GetFullPath(sp) : null;
        using var sampler = new SystemSampler();
        using var probe = new Probe(Path.Combine(work, "probe"), shell, idleScale);
        bool Stop() => File.Exists(stopFile);
        try
        {
            // probe alone: three cycles, they also measure the footprint of one user
            Log.Progress("capacity: probe alone");
            var me = Process.GetCurrentProcess(); me.Refresh();
            double cpu0 = me.TotalProcessorTime.TotalSeconds; var io0 = SystemSampler.Io(); double t0 = Timing.Now();
            var alone = new List<Dictionary<string, double>>();
            for (int i = 0; i < 3 && !Stop(); i++) alone.Add(probe.RunCycle(Stop));
            me.Refresh(); var io1 = SystemSampler.Io();
            fp = Footprint.FromDeltas(me.TotalProcessorTime.TotalSeconds - cpu0, me.PeakWorkingSet64, (long)(io1.ReadOps + io1.WriteOps - io0.ReadOps - io0.WriteOps), (long)(io1.ReadBytes + io1.WriteBytes - io0.ReadBytes - io0.WriteBytes), Timing.Now() - t0);
            if (alone.Count == 0) { stopReason = "stopped before the first cycle"; return Done(); }
            levels.Add(LevelEntry(0, alone, null));
            bool encode = true;   // CPU-only (no hardware GPU): the RDP stream is encoded in software
            try { encode = Gpu.Pick(Gpu.Enumerate()) == null; } catch (Exception e) when (e is InvalidOperationException or DllNotFoundException or COMException) { }

            foreach (int users in CapacityMath.LevelSequence(vCpu, o.MaxUsers))
            {
                if (Stop()) { stopReason = "stopped by the stop file"; break; }
                if (Timing.Now() - started > limit) { stopReason = "time limit"; break; }
                Log.Progress($"capacity: {users} users");
                while (workers.Count < users) workers.Add(StartWorker(work, workers.Count, fp, encode, (int)(limit + 120)));
                double rampEnd = Timing.Now() + o.Seconds(60), measureEnd = rampEnd + o.Seconds(120);
                var counted = new List<Dictionary<string, double>>();
                sampler.Reset();
                bool aborted = false;
                while (!aborted)
                {
                    double cs = Timing.Now();
                    var cycle = probe.RunCycle(() => Stop());
                    double ce = Timing.Now();
                    sampler.Sample();
                    if (cs >= rampEnd && ce <= measureEnd + 60) counted.Add(cycle);
                    if (SystemSampler.Memory().CommitPercent > 90) { stopReason = "memory commit above 90 percent"; aborted = true; }
                    if (Stop()) { stopReason = "stopped by the stop file"; aborted = true; }
                    if (Timing.Now() >= measureEnd && counted.Count >= 2) break;
                    if (Timing.Now() > measureEnd + 2 * 120) break;   // the cycles are slow under load: at most two more minutes
                }
                if (counted.Count > 0)
                {
                    levels.Add(LevelEntry(users, counted, sampler));
                    medians.Add((users, TotalMedian(counted)));
                }
                if (aborted) break;
                if (CapacityMath.PassedTwice(Merge(medians))) { stopReason = "the threshold was passed by two levels"; break; }
                if (SystemSampler.Memory().CommitPercent > 90) { stopReason = "memory commit above 90 percent"; break; }
            }
            if (stopReason == "") stopReason = "last level reached (4 x vCPU)";
        }
        finally
        {
            foreach (var w in workers) { try { w.J.Dispose(); } catch { } try { w.P.Dispose(); } catch { } }
            Apps.RemoveFolder(work);
        }
        return Done();

        List<Measure> Done()
        {
            var baseline = medians.FirstOrDefault(m => m.Users == 1);
            var all = Merge(medians);
            double? est = CapacityMath.Estimate(all);
            infoDict["capacity"] = new Dictionary<string, object?>
            {
                ["levels"] = levels.Select(l => (object?)l).ToList(), ["estimatedUsers"] = est == null ? null : Math.Round(est.Value, 1), ["thresholdReached"] = est != null,
                ["atLeastUsers"] = est == null && all.Count > 0 ? all[^1].Users : null, ["stopReason"] = stopReason, ["thresholdFactor"] = CapacityMath.ThresholdFactor,
                ["levelOneMedianMs"] = baseline.Users == 1 ? Math.Round(baseline.Median, 1) : null, ["vCpu"] = vCpu,
                ["footprint"] = fp == null ? null : new Dictionary<string, object?> { ["cpuSecPerMin"] = fp.CpuSecPerMin, ["workingSetMB"] = fp.WorkingSetMB, ["ioOpsPerMin"] = fp.IoOpsPerMin, ["ioMBPerMin"] = fp.IoMBPerMin },
                ["method"] = "own method, similar to the VSImax idea, not a Login VSI result; the probe has no UI Automation (reproducible work steps)",
            };
            return new List<Measure>();
        }
    }

    private static List<(int Users, double Median)> Merge(List<(int Users, double Median)> l) => l.OrderBy(x => x.Users).ToList();

    private static double TotalMedian(List<Dictionary<string, double>> cycles) => Evaluation.Median(cycles.Select(c => c.Values.Sum()).ToList());

    private static Dictionary<string, object?> LevelEntry(int users, List<Dictionary<string, double>> cycles, SystemSampler? s)
    {
        var totals = cycles.Select(c => c.Values.Sum()).ToList();
        var actions = new Dictionary<string, object?>();
        foreach (var a in Probe.Actions)
        {
            var v = cycles.Where(c => c.ContainsKey(a)).Select(c => c[a]).ToList();
            if (v.Count > 0) actions[a] = new Dictionary<string, object?> { ["medianMs"] = Math.Round(Evaluation.Median(v), 1), ["p95Ms"] = Math.Round(CapacityMath.Percentile(v, 95), 1) };
        }
        var e = new Dictionary<string, object?>
        {
            ["users"] = users, ["cycles"] = cycles.Count, ["totalMedianMs"] = Math.Round(Evaluation.Median(totals), 1), ["totalP95Ms"] = Math.Round(CapacityMath.Percentile(totals, 95), 1), ["actions"] = actions,
        };
        if (s != null)
        {
            e["cpuPercent"] = s.Cpu.Count > 0 ? Math.Round(s.Cpu.Average(), 1) : null;
            e["availableMemoryMB"] = s.MinAvailMB == double.MaxValue ? null : Math.Round(s.MinAvailMB, 0);
            e["commitPercent"] = Math.Round(s.MaxCommitPercent, 1);
            e["diskQueue"] = s.Queue.Count > 0 ? Math.Round(s.Queue.Average(), 2) : null;
        }
        return e;
    }

    private static (Process, JobGroup) StartWorker(string work, int index, Footprint fp, bool encode, int seconds)
    {
        var job = new JobGroup();
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var psi = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in new[] { "load", "--user", (index + 1).ToString(inv), "--dir", Path.Combine(work, "u" + (index + 1)), "--quiet",
            "--cpu-sec-per-min", fp.CpuSecPerMin.ToString(inv), "--ws-mb", fp.WorkingSetMB.ToString(inv), "--io-ops-per-min", fp.IoOpsPerMin.ToString(inv), "--io-mb-per-min", fp.IoMBPerMin.ToString(inv),
            "--encode", encode ? "1" : "0", "--load-seconds", seconds.ToString(inv) }) psi.ArgumentList.Add(a);
        var p = Process.Start(psi) ?? throw new InvalidOperationException("a load worker did not start");
        try { job.Assign(p); } catch { job.Dispose(); throw; }
        return (p, job);
    }
}
