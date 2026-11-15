using System.Runtime.InteropServices;

namespace AVDTune.Bench;

/// <summary>Memory measures (design 1.1): copy bandwidth, random-access latency, allocation churn.</summary>
public static unsafe class MemoryBench
{
    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        list.Add(Bandwidth(o));
        list.Add(Latency(o));
        list.Add(Alloc(o));
        return list;
    }

    /// <summary>Buffer.MemoryCopy of 256 MB buffers, threads = physical cores, GB/s copied.</summary>
    public static Measure Bandwidth(Options o)
    {
        Log.Progress("mem: bandwidth");
        int threads = Math.Min(o.Threads, SystemInfo.PhysicalCores());
        long size = Math.Max(1 << 20, (long)(256L * 1024 * 1024 * o.DataScale)) & ~63L;
        var (_, avail) = SystemInfo.Memory();
        // never ask for more than half of the free memory (src + dst per thread)
        while (threads > 1 && threads * 2.0 * size / 1073741824.0 > avail * 0.5) threads--;
        if (2.0 * size / 1073741824.0 > avail * 0.5) return Measure.Not("host.mem.bandwidth", "GB/s", true, "skipped", "not enough free memory");
        double seconds = o.Seconds(3.0);
        var bytes = new double[threads];
        var prepared = new Barrier(threads + 1);
        var ts = new List<Thread>();
        for (int t = 0; t < threads; t++)
        {
            int idx = t;
            var th = new Thread(() =>
            {
                byte* src = (byte*)NativeMemory.AlignedAlloc((nuint)size, 4096);
                byte* dst = (byte*)NativeMemory.AlignedAlloc((nuint)size, 4096);
                try
                {
                    var rng = new Rng(100UL + (ulong)idx);
                    for (long i = 0; i < size; i += 4096) { *(ulong*)(src + i) = rng.NextU64(); *(ulong*)(dst + i) = 0; }   // touch every page
                    Buffer.MemoryCopy(src, dst, size, size);   // warm-up
                    prepared.SignalAndWait();
                    long copies = 0;
                    double start = Timing.Now(), now = start;
                    do { Buffer.MemoryCopy(src, dst, size, size); copies++; now = Timing.Now(); } while (now - start < seconds);
                    bytes[idx] = copies * (double)size / (now - start);
                }
                finally { NativeMemory.AlignedFree(src); NativeMemory.AlignedFree(dst); }
            }, 1024 * 1024) { IsBackground = true };
            ts.Add(th); th.Start();
        }
        prepared.SignalAndWait();
        foreach (var th in ts) th.Join();
        var m = Measure.Ok("host.mem.bandwidth", "GB/s", true, bytes.Sum() / 1e9);
        m.Detail["threads"] = threads;
        m.Detail["bufferMB"] = size / 1048576;
        return m;
    }

    /// <summary>Pointer chase through a 512 MB array, one random cyclic permutation (Sattolo), 64-byte stride: ns per dependent load.</summary>
    public static Measure Latency(Options o)
    {
        Log.Progress("mem: latency");
        long bytes = Math.Max(1 << 20, (long)(512L * 1024 * 1024 * o.DataScale)) & ~63L;
        var (_, avail) = SystemInfo.Memory();
        if (bytes / 1073741824.0 * 1.1 > avail * 0.5) return Measure.Not("host.mem.latency", "ns", false, "skipped", "not enough free memory");
        int nodes = (int)(bytes / 64);
        int* next = (int*)NativeMemory.AlignedAlloc((nuint)bytes, 4096);
        try
        {
            var perm = new int[nodes];
            for (int i = 0; i < nodes; i++) perm[i] = i;
            var rng = new Rng(777);
            for (int i = nodes - 1; i > 0; i--) { int j = rng.Next(i); (perm[i], perm[j]) = (perm[j], perm[i]); }   // Sattolo: j in [0, i)
            // perm is one cycle; link node perm[k] to perm[k+1]; the node's 64-byte slot starts at int index node*16
            for (int k = 0; k < nodes; k++) next[(long)perm[k] * 16] = perm[(k + 1) % nodes];
            perm = Array.Empty<int>();
            int p = 0;
            for (int i = 0; i < 1_000_000; i++) p = next[(long)p * 16];   // warm-up, page in
            double seconds = o.Seconds(3.0);
            long loads = 0;
            double start = Timing.Now(), now = start;
            do
            {
                for (int i = 0; i < 1_000_000; i++) p = next[(long)p * 16];
                loads += 1_000_000; now = Timing.Now();
            } while (now - start < seconds);
            GC.KeepAlive(p.ToString());
            var m = Measure.Ok("host.mem.latency", "ns", false, (now - start) * 1e9 / loads);
            m.Detail["arrayMB"] = bytes / 1048576;
            return m;
        }
        finally { NativeMemory.AlignedFree(next); }
    }

    /// <summary>.NET allocation churn: objects of 64 B to 8 KB, a ring of live objects so some survive; MB/s allocated (workstation concurrent GC).</summary>
    public static Measure Alloc(Options o)
    {
        Log.Progress("mem: alloc");
        var rng = new Rng(555);
        var ring = new byte[2048][];
        double seconds = o.Seconds(3.0);
        for (int i = 0; i < 200_000; i++) { var b = new byte[64 + rng.Next(8128)]; b[0] = 1; ring[i & 2047] = b; }   // warm-up
        long total = 0, sink = 0;
        double start = Timing.Now(), now = start;
        do
        {
            for (int i = 0; i < 20_000; i++)
            {
                int size = 64 + rng.Next(8128);
                var b = new byte[size]; b[size - 1] = (byte)i;
                ring[i & 2047] = b; total += size; sink += b[0];
            }
            now = Timing.Now();
        } while (now - start < seconds);
        GC.KeepAlive(ring); GC.KeepAlive(sink.ToString());
        var m = Measure.Ok("host.mem.alloc", "MB/s", true, total / 1048576.0 / (now - start));
        m.Detail["gcMode"] = System.Runtime.GCSettings.IsServerGC ? "server" : "workstation";
        return m;
    }
}
