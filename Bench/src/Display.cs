using System.Security.Cryptography;

namespace AVDTune.Bench;

/// <summary>Remote display measures (design 1.1): software H.264 encode of two synthetic clips, WARP 3D and 2D.</summary>
public static class Display
{
    public const int Width = 1920, Height = 1080, Frames = 300, Fps = 30;

    /// <summary>"desktop" clip: light background, title bar, scrolling lines of text blocks, a moving window and a cursor. NV12, one array per frame.</summary>
    public static byte[][] DesktopClip(int width, int height, int frames)
    {
        var clip = new byte[frames][];
        Parallel.For(0, frames, f => clip[f] = DesktopFrame(width, height, f));
        return clip;
    }

    private static uint Hash(uint a, uint b)
    {
        uint h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA6Bu;
        h ^= h >> 15; h *= 0xC2B2AE35u; h ^= h >> 13;
        return h;
    }

    public static byte[] DesktopFrame(int w, int h, int f)
    {
        var buf = new byte[w * h * 3 / 2];
        var y = buf.AsSpan(0, w * h);
        var uv = buf.AsSpan(w * h);
        y.Fill(235);
        for (int i = 0; i < uv.Length; i += 2) { uv[i] = 128; uv[i + 1] = 128; }
        int scroll = f * 3;
        // title bar: dark blue (low luma, U high, V low)
        int bar = Math.Min(h, 48);
        y.Slice(0, bar * w).Fill(60);
        for (int row = 0; row < bar / 2; row++) for (int col = 0; col < w / 2; col++) { uv[row * w + col * 2] = 170; uv[row * w + col * 2 + 1] = 100; }
        // lines of text blocks, scrolling
        for (int row = bar; row < h; row++)
        {
            int line = (row + scroll) / 18, r = (row + scroll) % 18;
            if (r < 4 || r >= 14) continue;
            int x = 40, k = 0;
            var span = y.Slice(row * w, w);
            while (x < w - 60)
            {
                uint hv = Hash((uint)line, (uint)k++);
                int bw = 20 + (int)(hv % 120);
                if ((hv >> 20 & 7) != 0) { int end = Math.Min(x + bw - 2, w - 40); if (end > x) span.Slice(x, end - x).Fill(40); }
                x += bw + 8;
            }
        }
        // moving window with its own text lines
        int wx = 200 + (int)(Math.Sin(f / 40.0) * 160) + 200, wy = 150 + (int)(Math.Cos(f / 55.0) * 100) + 100, ww = 640, wh = 380;
        FillRect(y, w, h, wx, wy, ww, wh, 205);
        FillRect(y, w, h, wx, wy, ww, 28, 90);
        for (int l = 0; l < 12; l++) FillRect(y, w, h, wx + 20, wy + 50 + l * 26, 80 + (int)(Hash((uint)l, 7) % 440), 8, 50);
        // cursor
        int cx = (f * 11) % (w - 20), cy = 300 + (f * 5) % 500;
        FillRect(y, w, h, cx, cy, 10, 18, 0); FillRect(y, w, h, cx + 2, cy + 2, 6, 14, 255);
        return buf;
    }

    private static void FillRect(Span<byte> y, int w, int h, int x, int top, int rw, int rh, byte v)
    {
        for (int row = Math.Max(0, top); row < Math.Min(h, top + rh); row++)
        {
            int x0 = Math.Max(0, x), x1 = Math.Min(w, x + rw);
            if (x1 > x0) y.Slice(row * w + x0, x1 - x0).Fill(v);
        }
    }

    /// <summary>"video" clip: full motion, a drifting gradient with moving noise, so every frame differs everywhere.</summary>
    public static byte[][] VideoClip(int width, int height, int frames)
    {
        var clip = new byte[frames][];
        Parallel.For(0, frames, f => clip[f] = VideoFrame(width, height, f));
        return clip;
    }

    public static byte[] VideoFrame(int w, int h, int f)
    {
        var buf = new byte[w * h * 3 / 2];
        for (int row = 0; row < h; row++)
        {
            int baseOff = row * w;
            for (int col = 0; col < w; col++)
            {
                uint n = Hash((uint)((col >> 1) + f * 1031), (uint)((row >> 1) + 17)) >> 26;   // 0..63 noise
                int v = ((col * 3 + row * 2 + f * 11) & 255) / 2 + (int)n + 40;
                buf[baseOff + col] = (byte)Math.Min(235, v);
            }
        }
        int uvOff = w * h;
        for (int row = 0; row < h / 2; row++)
            for (int col = 0; col < w / 2; col++)
            {
                buf[uvOff + row * w + col * 2] = (byte)(64 + ((col + f * 4) & 127));
                buf[uvOff + row * w + col * 2 + 1] = (byte)(64 + ((row * 2 + f * 3) & 127));
            }
        return buf;
    }

    /// <summary>SHA-256 over all frames, for the deterministic-data tests.</summary>
    public static string ClipHash(byte[][] clip)
    {
        using var sha = SHA256.Create();
        foreach (var f in clip) sha.TransformBlock(f, 0, f.Length, null, 0);
        sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return Convert.ToHexString(sha.Hash!);
    }

    public static List<Measure> Run(Options o)
    {
        var list = new List<Measure>();
        int frames = Math.Max(10, (int)Math.Round(Frames * Math.Min(1.0, o.Scale < 1 ? Math.Max(o.Scale, 0.1) : 1.0)));
        list.Add(Encode("host.disp.h264.desktop", frames, 4_000_000, () => DesktopClip(Width, Height, frames)));
        list.Add(Encode("host.disp.h264.video", frames, 10_000_000, () => VideoClip(Width, Height, frames)));
        list.Add(Gpu("host.disp.warp.3d", () => { var r = Warp.Render3D(o.Seconds(10.0)); return r; }));
        list.Add(Gpu("host.disp.warp.2d", () => Warp.Render2D(o.Seconds(10.0))));
        return list;
    }

    private static Measure Encode(string id, int frames, int bitrate, Func<byte[][]> clip)
    {
        Log.Progress($"disp: {id}");
        try
        {
            var data = clip();
            var r = H264Soft.Encode(data, Width, Height, Fps, bitrate);
            var m = Measure.Ok(id, "frames/s", true, r.Frames / r.Seconds);
            m.Detail["frames"] = r.Frames;
            m.Detail["outputBytes"] = r.OutputBytes;
            m.Detail["achievedMbit"] = Math.Round(r.OutputBytes * 8.0 / (r.Frames / (double)Fps) / 1e6, 2);
            if (r.OutputBytes == 0) return Measure.Not(id, "frames/s", true, "failed", "the encoder produced no output");
            if (r.Note != "") m.Detail["note"] = r.Note;
            return m;
        }
        catch (InvalidOperationException e) { return Measure.Not(id, "frames/s", true, "skipped", e.Message); }
        catch (System.Runtime.InteropServices.COMException e) { if (Environment.GetEnvironmentVariable("AVDTUNE_BENCH_DEBUG") == "1") Console.Error.WriteLine(e.ToString()); return Measure.Not(id, "frames/s", true, "skipped", $"Media Foundation error 0x{e.HResult:X8} (is the Media Foundation feature installed?)"); }
        catch (DllNotFoundException e) { return Measure.Not(id, "frames/s", true, "skipped", "Media Foundation is not available: " + e.Message); }
    }

    private static Measure Gpu(string id, Func<(double Fps, int Frames, string Note)> run)
    {
        Log.Progress($"disp: {id}");
        try
        {
            var r = run();
            var m = Measure.Ok(id, "frames/s", true, r.Fps);
            m.Detail["frames"] = r.Frames;
            m.Detail["note"] = r.Note;
            return m;
        }
        catch (Exception e) when (e is InvalidOperationException or DllNotFoundException or EntryPointNotFoundException or System.Runtime.InteropServices.COMException)
        { return Measure.Not(id, "frames/s", true, "unsupported", e.Message); }
    }
}
