using System.Runtime.InteropServices;

namespace AVDTune.Bench;

/// <summary>GPU measures (design 1.3): the hardware adapter is found with DXGI (not the Microsoft Basic Render Driver, vendor 0x1414), Direct3D 11 3D scene at 1920x1080 and 3840x2160
/// on that adapter, DirectCompute (FMA kernel, copy kernel). Raw COM calls like Warp.cs (slot numbers from d3d11.h and dxgi.h). Hardware video encode and decode are NOT built
/// in this round: they are reported as unsupported with that reason, so the GPU score is a partial score and says so.</summary>
internal static unsafe class Gpu
{
    [DllImport("dxgi.dll")] private static extern int CreateDXGIFactory1(Guid* iid, IntPtr* factory);
    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, uint* levels, uint levelCount, uint sdk, IntPtr* device, uint* level, IntPtr* context);

    public sealed record AdapterInfo(int Index, string Name, uint VendorId, uint DeviceId, long DedicatedBytes, uint Flags, string Driver);

    [StructLayout(LayoutKind.Sequential)]
    private struct AdapterDesc1
    {
        public fixed char Description[128];
        public uint VendorId, DeviceId, SubSysId, Revision;
        public nuint Dedicated, DedicatedSystem, Shared;
        public long Luid;
        public uint Flags;
    }

    public const int FmaIterations = 1024, FmaChains = 8, FmaGroups = 4096, FmaGroupSize = 256;
    /// <summary>Floating point operations of one FMA dispatch (a multiply-add counts as two).</summary>
    public static double FmaFlopsPerDispatch => (double)FmaGroups * FmaGroupSize * FmaIterations * FmaChains * 2.0;

    /// <summary>The hardware adapter that is used, or null: no software adapter (Basic Render Driver, WARP), the one with the most dedicated memory.</summary>
    public static AdapterInfo? Pick(IEnumerable<AdapterInfo> adapters) =>
        adapters.Where(a => a.VendorId != 0x1414 && (a.Flags & 2) == 0).OrderByDescending(a => a.DedicatedBytes).ThenBy(a => a.Index).FirstOrDefault();

    public static string DriverText(long v) => $"{(v >> 48) & 0xFFFF}.{(v >> 32) & 0xFFFF}.{(v >> 16) & 0xFFFF}.{v & 0xFFFF}";

    public static List<AdapterInfo> Enumerate() => Walk(null, out _);

    private static List<AdapterInfo> Walk(int? takeIndex, out IntPtr taken)
    {
        taken = IntPtr.Zero;
        var list = new List<AdapterInfo>();
        Guid iid = new("770aae78-f26f-4dba-a829-253c83d1b387");   // IDXGIFactory1
        IntPtr factory;
        Warp.Check(CreateDXGIFactory1(&iid, &factory), "CreateDXGIFactory1");
        try
        {
            for (uint i = 0; ; i++)
            {
                IntPtr ad;
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr*, int>)Warp.Slot(factory, 12))(factory, i, &ad);   // EnumAdapters1
                if (hr < 0) break;
                AdapterDesc1 d;
                Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, AdapterDesc1*, int>)Warp.Slot(ad, 10))(ad, &d), "GetDesc1");
                string driver = "";
                try
                {
                    Guid dxgiDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
                    long umd;
                    if (((delegate* unmanaged[Stdcall]<IntPtr, Guid*, long*, int>)Warp.Slot(ad, 9))(ad, &dxgiDevice, &umd) >= 0) driver = DriverText(umd);
                }
                catch { }
                list.Add(new AdapterInfo((int)i, new string(d.Description), d.VendorId, d.DeviceId, (long)d.Dedicated, d.Flags, driver));
                if (takeIndex == i && taken == IntPtr.Zero) taken = ad; else Warp.Release(ad);
            }
        }
        finally { Warp.Release(factory); }
        return list;
    }

    public static Dictionary<string, object?> Info()
    {
        var all = Enumerate();
        var pick = Pick(all);
        var info = new Dictionary<string, object?> { ["adapterCount"] = all.Count, ["hardware"] = pick != null };
        if (pick != null)
        {
            info["adapter"] = pick.Name; info["vendorId"] = "0x" + pick.VendorId.ToString("X4"); info["vramMiB"] = pick.DedicatedBytes / 1048576; info["driver"] = pick.Driver;
        }
        info["adapters"] = all.Select(a => (object?)new Dictionary<string, object?> { ["name"] = a.Name, ["vendorId"] = "0x" + a.VendorId.ToString("X4"), ["vramMiB"] = a.DedicatedBytes / 1048576, ["software"] = a.VendorId == 0x1414 || (a.Flags & 2) != 0 }).ToList();
        return info;
    }

    private static readonly string[] Unbuilt = { "gpu.enc.h264", "gpu.enc.hevc", "gpu.enc.av1", "gpu.dec.h264", "gpu.dec.hevc", "gpu.dec.av1" };

    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        var all = Enumerate();
        var pick = Pick(all);
        if (pick == null) return new() { Measure.Not("gpu.d3d11.1080", "frames/s", true, "unsupported", "nicht vorhanden: no hardware GPU") };
        Walk(pick.Index, out IntPtr adapter);
        try
        {
            list.Add(Guard("gpu.d3d11.1080", "frames/s", () => { var r = Warp.Render3D(o.Seconds(10.0), 1_000_000, 1920, 1080, adapter); return (r.Fps, r.Note); }));
            list.Add(Guard("gpu.d3d11.2160", "frames/s", () => { var r = Warp.Render3D(o.Seconds(10.0), 1_000_000, 3840, 2160, adapter); return (r.Fps, r.Note); }));
            list.Add(Guard("gpu.cs.gflops", "GFLOPS", () => Fma(adapter, o.Seconds(5.0))));
            list.Add(Guard("gpu.cs.bandwidth", "GB/s", () => Copy(adapter, o.Seconds(5.0), Math.Min(512L << 20, Math.Max(64L << 20, pick.DedicatedBytes / 4)))));
        }
        finally { Warp.Release(adapter); }
        foreach (var id in Unbuilt) list.Add(Measure.Not(id, "frames/s", true, "unsupported", "hardware video encode and decode are not part of this version of the benchmark"));
        return list;
    }

    private static Measure Guard(string id, string unit, Func<(double Value, string Note)> run)
    {
        Log.Progress("gpu: " + id);
        try { var r = run(); var m = Measure.Ok(id, unit, true, r.Value); m.Detail["note"] = r.Note; return m; }
        catch (Exception e) when (e is InvalidOperationException or DllNotFoundException or EntryPointNotFoundException or COMException)
        { return Measure.Not(id, unit, true, "unsupported", e.Message); }
    }

    // ------------------------------------------------------------------ DirectCompute

    private const string FmaShader = @"
RWStructuredBuffer<float> o : register(u0);
[numthreads(256,1,1)] void main(uint3 id : SV_DispatchThreadID)
{
    float b = 1.0000001, c = 1e-7, a = id.x * 1e-6 + 1;
    float x0 = a, x1 = a + 1, x2 = a + 2, x3 = a + 3, x4 = a + 4, x5 = a + 5, x6 = a + 6, x7 = a + 7;
    [loop] for (int i = 0; i < 1024; i++) { x0 = mad(x0, b, c); x1 = mad(x1, b, c); x2 = mad(x2, b, c); x3 = mad(x3, b, c); x4 = mad(x4, b, c); x5 = mad(x5, b, c); x6 = mad(x6, b, c); x7 = mad(x7, b, c); }
    o[id.x] = x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7;
}";
    private const string CopyShader = @"
RWStructuredBuffer<uint4> src : register(u0);
RWStructuredBuffer<uint4> dst : register(u1);
[numthreads(256,1,1)] void main(uint3 id : SV_DispatchThreadID) { uint i = id.y * (1024 * 256) + id.x; dst[i] = src[i]; }";

    [StructLayout(LayoutKind.Sequential)] private struct BufferDesc { public uint ByteWidth, Usage, BindFlags, CpuAccess, Misc, Stride; }
    [StructLayout(LayoutKind.Sequential)] private struct UavDesc { public uint Format, Dimension, FirstElement, NumElements, Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct Box { public uint Left, Top, Front, Right, Bottom, Back; }
    [StructLayout(LayoutKind.Sequential)] private struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }

    private sealed class Compute : IDisposable
    {
        public IntPtr Dev, Ctx, Staging, Shader;
        private readonly List<IntPtr> _owned = new();
        public static Compute Create(IntPtr adapter, string hlsl)
        {
            var c = new Compute();
            uint* levels = stackalloc uint[2]; levels[0] = 0xB100; levels[1] = 0xB000;
            IntPtr dev, ctx; uint got;
            Warp.Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, levels, 2, 7, &dev, &got, &ctx), "D3D11CreateDevice(GPU)");
            c.Dev = dev; c.Ctx = ctx;
            var sd = new BufferDesc { ByteWidth = 16, Usage = 3, CpuAccess = 0x20000 };
            IntPtr st;
            Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, BufferDesc*, IntPtr, IntPtr*, int>)Warp.Slot(dev, 3))(dev, &sd, IntPtr.Zero, &st), "CreateBuffer(staging)");
            c.Staging = st;
            IntPtr blob = Warp.Compile(hlsl, "cs_5_0");
            try
            {
                IntPtr code = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)Warp.Slot(blob, 3))(blob); nuint n = ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)Warp.Slot(blob, 4))(blob);
                IntPtr sh;
                Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, nuint, IntPtr, IntPtr*, int>)Warp.Slot(dev, 18))(dev, code, n, IntPtr.Zero, &sh), "CreateComputeShader");
                c.Shader = sh;
            }
            finally { Warp.Release(blob); }
            return c;
        }

        /// <summary>A structured buffer with an unordered access view. Returns (buffer, view).</summary>
        public (IntPtr Buf, IntPtr Uav) Buffer(long bytes, uint stride)
        {
            var d = new BufferDesc { ByteWidth = (uint)bytes, Usage = 0, BindFlags = 0x80, Misc = 0x40, Stride = stride };
            IntPtr b, u;
            Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, BufferDesc*, IntPtr, IntPtr*, int>)Warp.Slot(Dev, 3))(Dev, &d, IntPtr.Zero, &b), "CreateBuffer(" + (bytes >> 20) + " MiB)");
            _owned.Add(b);
            var v = new UavDesc { Format = 0, Dimension = 1, FirstElement = 0, NumElements = (uint)(bytes / stride), Flags = 0 };
            Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, UavDesc*, IntPtr*, int>)Warp.Slot(Dev, 8))(Dev, b, &v, &u), "CreateUnorderedAccessView");
            _owned.Add(u);
            return (b, u);
        }

        public void Bind(params IntPtr[] uavs)
        {
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, uint, void>)Warp.Slot(Ctx, 69))(Ctx, Shader, IntPtr.Zero, 0);   // CSSetShader
            fixed (IntPtr* p = uavs) ((delegate* unmanaged[Stdcall]<IntPtr, uint, uint, IntPtr*, IntPtr, void>)Warp.Slot(Ctx, 68))(Ctx, 0, (uint)uavs.Length, p, IntPtr.Zero);   // CSSetUnorderedAccessViews
        }

        public void Dispatch(uint x, uint y) => ((delegate* unmanaged[Stdcall]<IntPtr, uint, uint, uint, void>)Warp.Slot(Ctx, 41))(Ctx, x, y, 1);

        /// <summary>Waits until the GPU has finished: copy 16 bytes of a buffer to the staging buffer and map it.</summary>
        public void Sync(IntPtr buffer)
        {
            var box = new Box { Left = 0, Top = 0, Front = 0, Right = 16, Bottom = 1, Back = 1 };
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, uint, IntPtr, uint, Box*, void>)Warp.Slot(Ctx, 46))(Ctx, Staging, 0, 0, 0, 0, buffer, 0, &box);
            Mapped m;
            Warp.Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, Mapped*, int>)Warp.Slot(Ctx, 14))(Ctx, Staging, 0, 1, 0, &m), "Map");
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)Warp.Slot(Ctx, 15))(Ctx, Staging, 0);
        }

        public void Dispose()
        {
            foreach (var o in _owned) Warp.Release(o);
            Warp.Release(Shader); Warp.Release(Staging); Warp.Release(Ctx); Warp.Release(Dev);
        }
    }

    private static (double, string) Fma(IntPtr adapter, double seconds)
    {
        using var c = Compute.Create(adapter, FmaShader);
        var (buf, uav) = c.Buffer(4L * FmaGroups * FmaGroupSize, 4);
        c.Bind(uav);
        c.Dispatch(FmaGroups, 1); c.Sync(buf);   // warm-up (driver shader compile)
        long dispatches = 0;
        double start = Timing.Now(), now = start;
        do { for (int i = 0; i < 8; i++) c.Dispatch(FmaGroups, 1); c.Sync(buf); dispatches += 8; now = Timing.Now(); } while (now - start < seconds);
        return (dispatches * FmaFlopsPerDispatch / (now - start) / 1e9, $"{dispatches} dispatches");
    }

    private static (double, string) Copy(IntPtr adapter, double seconds, long bytesEach)
    {
        bytesEach = bytesEach / (4L << 20) * (4L << 20);   // a whole number of 1024 x 256 x 16 byte rows
        if (bytesEach < (4L << 20)) throw new InvalidOperationException("not enough GPU memory for the copy kernel");
        using var c = Compute.Create(adapter, CopyShader);
        var (sb, su) = c.Buffer(bytesEach, 16);
        var (db, du) = c.Buffer(bytesEach, 16);
        c.Bind(su, du);
        uint rows = (uint)(bytesEach / 16 / (1024 * 256));
        c.Dispatch(1024, rows); c.Sync(db);
        long dispatches = 0;
        double start = Timing.Now(), now = start;
        do { for (int i = 0; i < 4; i++) c.Dispatch(1024, rows); c.Sync(db); dispatches += 4; now = Timing.Now(); } while (now - start < seconds);
        double bytes = dispatches * 2.0 * bytesEach;   // read and write
        return (bytes / (now - start) / 1e9, $"{bytesEach >> 20} MiB buffers, read plus write");
    }
}
