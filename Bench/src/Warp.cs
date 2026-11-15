using System.Runtime.InteropServices;
using System.Text;

namespace AVDTune.Bench;

/// <summary>Direct3D 11 and Direct2D on the WARP software rasterizer, through raw COM vtable calls (no third-party library, no generated interop).
/// Slot numbers follow d3d11.h, d2d1.h and dwrite.h (IUnknown = 0 to 2).</summary>
internal static unsafe class Warp
{
    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, uint* levels, uint levelCount, uint sdk, IntPtr* device, uint* level, IntPtr* context);
    [DllImport("d3dcompiler_47.dll")] private static extern int D3DCompile(IntPtr src, UIntPtr size, IntPtr name, IntPtr defines, IntPtr include, IntPtr entry, IntPtr target, uint f1, uint f2, IntPtr* code, IntPtr* errors);
    [DllImport("d2d1.dll")] private static extern int D2D1CreateFactory(int type, Guid* iid, IntPtr options, IntPtr* factory);
    [DllImport("dwrite.dll")] private static extern int DWriteCreateFactory(int type, Guid* iid, IntPtr* factory);

    private static IntPtr Slot(IntPtr obj, int index) => (*(IntPtr**)obj)[index];
    public static void Release(IntPtr obj) { if (obj != IntPtr.Zero) ((delegate* unmanaged[Stdcall]<IntPtr, uint>)Slot(obj, 2))(obj); }
    private static int QueryInterface(IntPtr obj, Guid iid, out IntPtr result)
    {
        IntPtr r; int hr = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)Slot(obj, 0))(obj, &iid, &r); result = r; return hr;
    }
    private static void Check(int hr, string what) { if (hr < 0) throw new InvalidOperationException($"{what} failed (0x{hr:X8})."); }

    [StructLayout(LayoutKind.Sequential)]
    private struct Tex2DDesc { public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CpuAccessFlags, MiscFlags; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Viewport { public float X, Y, W, H, MinDepth, MaxDepth; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Box { public uint Left, Top, Front, Right, Bottom, Back; }

    private sealed class Device : IDisposable
    {
        public IntPtr Dev, Ctx, Target, Staging;
        public int Width, Height;
        public static Device Create(int width, int height, uint format, uint bind)
        {
            var d = new Device { Width = width, Height = height };
            uint* levels = stackalloc uint[2]; levels[0] = 0xB100; levels[1] = 0xB000;   // 11_1, 11_0
            IntPtr dev, ctx; uint got;
            // driver type 5 = WARP; flag 0x20 = BGRA support (needed by Direct2D)
            Check(D3D11CreateDevice(IntPtr.Zero, 5, IntPtr.Zero, 0x20, levels, 2, 7, &dev, &got, &ctx), "D3D11CreateDevice(WARP)");
            d.Dev = dev; d.Ctx = ctx;
            var desc = new Tex2DDesc { Width = (uint)width, Height = (uint)height, MipLevels = 1, ArraySize = 1, Format = format, SampleCount = 1, Usage = 0, BindFlags = bind };
            IntPtr tex;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, Tex2DDesc*, IntPtr, IntPtr*, int>)Slot(dev, 5))(dev, &desc, IntPtr.Zero, &tex), "CreateTexture2D");
            d.Target = tex;
            var sd = new Tex2DDesc { Width = 1, Height = 1, MipLevels = 1, ArraySize = 1, Format = format, SampleCount = 1, Usage = 3 /*STAGING*/, CpuAccessFlags = 0x20000 /*READ*/ };
            IntPtr st;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, Tex2DDesc*, IntPtr, IntPtr*, int>)Slot(dev, 5))(dev, &sd, IntPtr.Zero, &st), "CreateTexture2D(staging)");
            d.Staging = st;
            return d;
        }

        /// <summary>Waits until the GPU (here: WARP) has finished the queued work: copy one pixel to a staging texture and map it.</summary>
        public uint Sync()
        {
            var box = new Box { Left = 0, Top = 0, Front = 0, Right = 1, Bottom = 1, Back = 1 };
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, uint, IntPtr, uint, Box*, void>)Slot(Ctx, 46))(Ctx, Staging, 0, 0, 0, 0, Target, 0, &box);
            Mapped m;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, Mapped*, int>)Slot(Ctx, 14))(Ctx, Staging, 0, 1 /*READ*/, 0, &m), "Map");
            uint pixel = *(uint*)m.Data;
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)Slot(Ctx, 15))(Ctx, Staging, 0);
            return pixel;
        }

        /// <summary>Reads the whole target (for checks): fraction of pixels that differ from the first pixel.</summary>
        public void Dispose() { Release(Staging); Release(Target); Release(Ctx); Release(Dev); }
    }

    private const string SceneVs = @"
struct O { float4 p : SV_Position; float3 n : TEXCOORD0; float2 uv : TEXCOORD1; };
static const uint IX[6] = { 0, 1, 0, 0, 1, 1 };
static const uint IY[6] = { 0, 0, 1, 1, 0, 1 };
O main(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    const uint GX = 1000;
    uint gx = iid % GX, gy = iid / GX;
    float2 c = float2(gx, gy) / (GX - 1.0) * 2 - 1;
    float2 q = c + float2(IX[vid], IY[vid]) * (3.0 / GX);
    float h = 0.18 * sin(q.x * 9) * cos(q.y * 7) + 0.05 * sin(q.x * 40 + q.y * 30);
    float3 n = normalize(float3(-0.18 * 9 * cos(q.x * 9) * cos(q.y * 7) - 2.0 * cos(q.x * 40 + q.y * 30), 1.0, 0.18 * 7 * sin(q.x * 9) * sin(q.y * 7) - 1.5 * cos(q.x * 40 + q.y * 30)));
    O o; o.p = float4(q.x * 0.95, (q.y * 0.6 + h) * 0.9, 0.5, 1); o.n = n; o.uv = q * 40; return o;
}";

    private const string ScenePs = @"
struct O { float4 p : SV_Position; float3 n : TEXCOORD0; float2 uv : TEXCOORD1; };
float4 main(O i) : SV_Target
{
    float3 L = normalize(float3(0.4, 0.8, 0.3));
    float3 n = normalize(i.n);
    float d = saturate(dot(n, L));
    float2 u = i.uv; float t = 0; float a = 1;
    [unroll] for (int k = 0; k < 4; k++) { t += a * (0.5 + 0.5 * sin(u.x * 1.7 + sin(u.y * 2.3 + k)) * cos(u.y * 1.3 + k * 1.7)); u = u * 1.9 + float2(0.3, 0.7); a *= 0.5; }
    float3 col = lerp(float3(0.2, 0.35, 0.15), float3(0.8, 0.7, 0.5), t * 0.6) * (0.2 + 0.8 * d);
    float spec = pow(saturate(dot(reflect(-L, n), float3(0, 0, -1))), 16);
    return float4(col + spec * 0.2, 1);
}";

    private static IntPtr Compile(string source, string target)
    {
        IntPtr src = Marshal.StringToHGlobalAnsi(source), entry = Marshal.StringToHGlobalAnsi("main"), tgt = Marshal.StringToHGlobalAnsi(target);
        try
        {
            IntPtr code, err = IntPtr.Zero;
            int hr = D3DCompile(src, (UIntPtr)source.Length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, entry, tgt, 0, 0, &code, &err);
            if (hr < 0)
            {
                string msg = "";
                if (err != IntPtr.Zero)
                {
                    var p = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)Slot(err, 3))(err);
                    var n = ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)Slot(err, 4))(err);
                    msg = Marshal.PtrToStringAnsi(p, (int)n);
                }
                throw new InvalidOperationException($"HLSL compile failed (0x{hr:X8}): {msg}");
            }
            return code;
        }
        finally { Marshal.FreeHGlobal(src); Marshal.FreeHGlobal(entry); Marshal.FreeHGlobal(tgt); }
    }

    /// <summary>Direct3D 11 on WARP: fixed scene of about 2 million instanced triangles with per-pixel lighting and a procedural texture, 1280x720 off screen. Frames per second.</summary>
    public static (double Fps, int Frames, string Note) Render3D(double seconds, int instances = 1_000_000)
    {
        using var d = Device.Create(1280, 720, 28 /*R8G8B8A8_UNORM*/, 0x20 /*RENDER_TARGET*/);
        IntPtr vsBlob = Compile(SceneVs, "vs_5_0"), psBlob = Compile(ScenePs, "ps_5_0");
        IntPtr rtv = IntPtr.Zero, vs = IntPtr.Zero, ps = IntPtr.Zero, vsNew = IntPtr.Zero, psNew = IntPtr.Zero, rtvNew = IntPtr.Zero;
        try
        {
            var dev = d.Dev; var ctx = d.Ctx;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, IntPtr*, int>)Slot(dev, 9))(dev, d.Target, IntPtr.Zero, &rtvNew), "CreateRenderTargetView"); rtv = rtvNew;
            IntPtr vsp = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)Slot(vsBlob, 3))(vsBlob); nuint vsn = ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)Slot(vsBlob, 4))(vsBlob);
            IntPtr psp = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)Slot(psBlob, 3))(psBlob); nuint psn = ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)Slot(psBlob, 4))(psBlob);
            Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, nuint, IntPtr, IntPtr*, int>)Slot(dev, 12))(dev, vsp, vsn, IntPtr.Zero, &vsNew), "CreateVertexShader"); vs = vsNew;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, nuint, IntPtr, IntPtr*, int>)Slot(dev, 15))(dev, psp, psn, IntPtr.Zero, &psNew), "CreatePixelShader"); ps = psNew;
            void Frame()
            {
                var vp = new Viewport { W = 1280, H = 720, MaxDepth = 1 };
                float* clear = stackalloc float[4]; clear[0] = 0.05f; clear[1] = 0.05f; clear[2] = 0.08f; clear[3] = 1f;
                IntPtr rt = rtv;
                ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr*, IntPtr, void>)Slot(ctx, 33))(ctx, 1, &rt, IntPtr.Zero);
                ((delegate* unmanaged[Stdcall]<IntPtr, uint, Viewport*, void>)Slot(ctx, 44))(ctx, 1, &vp);
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, float*, void>)Slot(ctx, 50))(ctx, rt, clear);
                ((delegate* unmanaged[Stdcall]<IntPtr, uint, void>)Slot(ctx, 24))(ctx, 4);   // triangle list
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, uint, void>)Slot(ctx, 11))(ctx, vs, IntPtr.Zero, 0);
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, uint, void>)Slot(ctx, 9))(ctx, ps, IntPtr.Zero, 0);
                ((delegate* unmanaged[Stdcall]<IntPtr, uint, uint, uint, uint, void>)Slot(ctx, 21))(ctx, 6, (uint)instances, 0, 0);
                d.Sync();
            }
            Frame();   // warm-up, shader JIT of WARP
            int frames = 0;
            double start = Timing.Now(), now = start;
            do { Frame(); frames++; now = Timing.Now(); } while (now - start < seconds);
            // the picture must not be empty: something other than the clear colour was drawn
            return (frames / (now - start), frames, $"{(long)instances * 2} triangles");
        }
        finally { Release(rtv); Release(vs); Release(ps); Release(vsBlob); Release(psBlob); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct ColorF { public float R, G, B, A; public ColorF(float r, float g, float b, float a = 1) { R = r; G = g; B = b; A = a; } }
    [StructLayout(LayoutKind.Sequential)] private struct RectF { public float L, T, R, B; public RectF(float l, float t, float r, float b) { L = l; T = t; R = r; B = b; } }
    [StructLayout(LayoutKind.Sequential)] private struct GradientStop { public float Position; public ColorF Color; }
    [StructLayout(LayoutKind.Sequential)] private struct LinearGradientProps { public float X0, Y0, X1, Y1; }
    [StructLayout(LayoutKind.Sequential)] private struct RenderTargetProps { public uint Type, Format, AlphaMode; public float DpiX, DpiY; public uint Usage, MinLevel; }

    private static readonly string[] UiLines =
    {
        "Quarterly report - Budget review.xlsx", "Meeting with the customer about the new storage design", "Inbox (12) - Re: profile container size and policy update",
        "Document1 - Word   File  Home  Insert  Layout  References  Review  View", "Remote session on host pool desktop, 4 users connected, latency 28 ms",
        "The quick brown fox jumps over the lazy dog 0123456789", "Server report: update installed, restart required, review next quarter",
    };

    /// <summary>Direct2D on a WARP device: an office-like UI (rectangles, gradients, text) at 1280x720, frames per second.</summary>
    public static (double Fps, int Frames, string Note) Render2D(double seconds)
    {
        using var d = Device.Create(1280, 720, 87 /*B8G8R8A8_UNORM*/, 0x20);
        IntPtr surface = IntPtr.Zero, factory = IntPtr.Zero, rt = IntPtr.Zero, dw = IntPtr.Zero, format = IntPtr.Zero;
        IntPtr bgBrush = IntPtr.Zero, barBrush = IntPtr.Zero, textBrush = IntPtr.Zero, panelBrush = IntPtr.Zero, gradBrush = IntPtr.Zero, stops = IntPtr.Zero;
        try
        {
            Guid idSurface = new("cafcb56c-6ac3-4889-bf47-9e23bbd260ec");
            Check(QueryInterface(d.Target, idSurface, out surface), "QueryInterface(IDXGISurface)");
            Guid idFactory = new("06152247-6f50-465a-9245-118bfd3b6007");
            Check(D2D1CreateFactory(0, &idFactory, IntPtr.Zero, &factory), "D2D1CreateFactory");
            var props = new RenderTargetProps { Type = 0, Format = 0, AlphaMode = 1, DpiX = 96, DpiY = 96 };
            IntPtr rtp;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, RenderTargetProps*, IntPtr*, int>)Slot(factory, 15))(factory, surface, &props, &rtp), "CreateDxgiSurfaceRenderTarget");
            rt = rtp;
            Guid idDw = new("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
            Check(DWriteCreateFactory(0, &idDw, &dw), "DWriteCreateFactory");
            IntPtr fam = Marshal.StringToHGlobalUni("Segoe UI"), loc = Marshal.StringToHGlobalUni("en-us");
            IntPtr fmt;
            try { Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, int, int, int, float, IntPtr, IntPtr*, int>)Slot(dw, 15))(dw, fam, IntPtr.Zero, 400, 0, 5, 14f, loc, &fmt), "CreateTextFormat"); }
            finally { Marshal.FreeHGlobal(fam); Marshal.FreeHGlobal(loc); }
            format = fmt;

            IntPtr Solid(ColorF c)
            {
                IntPtr b;
                Check(((delegate* unmanaged[Stdcall]<IntPtr, ColorF*, IntPtr, IntPtr*, int>)Slot(rt, 8))(rt, &c, IntPtr.Zero, &b), "CreateSolidColorBrush");
                return b;
            }
            bgBrush = Solid(new ColorF(0.97f, 0.97f, 0.98f)); barBrush = Solid(new ColorF(0.10f, 0.35f, 0.65f)); textBrush = Solid(new ColorF(0.1f, 0.1f, 0.12f)); panelBrush = Solid(new ColorF(0.86f, 0.89f, 0.93f));
            var gs = stackalloc GradientStop[2];
            gs[0] = new GradientStop { Position = 0, Color = new ColorF(0.2f, 0.5f, 0.9f) }; gs[1] = new GradientStop { Position = 1, Color = new ColorF(0.9f, 0.95f, 1f) };
            IntPtr sc;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, GradientStop*, uint, uint, uint, IntPtr*, int>)Slot(rt, 9))(rt, gs, 2, 0, 0, &sc), "CreateGradientStopCollection");
            stops = sc;
            var lp = new LinearGradientProps { X0 = 0, Y0 = 0, X1 = 0, Y1 = 700 };
            IntPtr gb;
            Check(((delegate* unmanaged[Stdcall]<IntPtr, LinearGradientProps*, IntPtr, IntPtr, IntPtr*, int>)Slot(rt, 10))(rt, &lp, IntPtr.Zero, stops, &gb), "CreateLinearGradientBrush");
            gradBrush = gb;

            var text = UiLines.Select(Marshal.StringToHGlobalUni).ToArray();
            var lens = UiLines.Select(s => (uint)s.Length).ToArray();
            void Fill(RectF r, IntPtr brush) => ((delegate* unmanaged[Stdcall]<IntPtr, RectF*, IntPtr, void>)Slot(rt, 17))(rt, &r, brush);
            void Frame(int n)
            {
                var white = new ColorF(1, 1, 1);
                ((delegate* unmanaged[Stdcall]<IntPtr, void>)Slot(rt, 48))(rt);
                ((delegate* unmanaged[Stdcall]<IntPtr, ColorF*, void>)Slot(rt, 47))(rt, &white);
                Fill(new RectF(0, 0, 1280, 720), bgBrush);
                Fill(new RectF(0, 0, 1280, 40), barBrush);
                Fill(new RectF(0, 40, 200, 720), gradBrush);
                for (int i = 0; i < 12; i++) Fill(new RectF(220 + (i % 4) * 260 + (n % 5), 60 + (i / 4) * 150, 220 + (i % 4) * 260 + 240, 60 + (i / 4) * 150 + 130), panelBrush);
                for (int line = 0; line < 30; line++)
                {
                    int k = (line + n) % text.Length;
                    var r = new RectF(230, 70 + line * 21, 1250, 91 + line * 21);
                    ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, IntPtr, RectF*, IntPtr, uint, uint, void>)Slot(rt, 27))(rt, text[k], lens[k], format, &r, textBrush, 0, 0);
                }
                Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, int>)Slot(rt, 49))(rt, IntPtr.Zero, IntPtr.Zero), "EndDraw");
                d.Sync();
            }
            try
            {
                Frame(0);
                uint pixel = d.Sync();
                int frames = 0;
                double start = Timing.Now(), now = start;
                do { Frame(frames); frames++; now = Timing.Now(); } while (now - start < seconds);
                return (frames / (now - start), frames, $"first pixel 0x{pixel:X8}");
            }
            finally { foreach (var t in text) Marshal.FreeHGlobal(t); }
        }
        finally { Release(gradBrush); Release(stops); Release(panelBrush); Release(textBrush); Release(barBrush); Release(bgBrush); Release(format); Release(dw); Release(rt); Release(factory); Release(surface); }
    }
}
