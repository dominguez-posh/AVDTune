using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace AVDTune.Bench;

/// <summary>host.app.speedometer (design 1.1): Speedometer 3.1 from the local copy, served from 127.0.0.1 on a random port; Edge with a temporary profile and its DevTools port on a
/// random loopback port (--remote-debugging-port=0, the port is read from the DevToolsActivePort file of our own profile). The page list and the WebSocket address are only
/// accepted when they point to 127.0.0.1 and the port of the file. The result is read with Runtime.evaluate once location.hash is #summary. Files of the benchmark are not changed.</summary>
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
            var psi = new ProcessStartInfo(edgeExe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work };
            foreach (var a in new[] { "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", "--window-size=1280,900",
                $"{server.Origin}/index.html?startAutomatically&iterationCount={o.SpeedIterations}" }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("Edge did not start");
            job.Assign(p);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSec));
            string? text = ReadResult(profile, server, cts.Token).GetAwaiter().GetResult();
            if (!TryParseScore(text, out double score)) return Measure.Not(Id, "runs/min", true, "failed", "Speedometer gave no usable result");
            var m = Measure.Ok(Id, "runs/min", true, score);
            m.Detail["iterations"] = o.SpeedIterations;
            m.Detail["version"] = "3.1";
            return m;
        }
        catch (OperationCanceledException) { return Measure.Not(Id, "runs/min", true, "failed", $"Speedometer did not finish in {TimeoutSec} s"); }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or HttpRequestException or WebSocketException or IOException)
        { return Measure.Not(Id, "runs/min", true, "failed", e.Message); }
        finally { job.Terminate(); server?.Dispose(); Apps.RemoveFolder(profile); }
    }

    public static bool TryParseScore(string? text, out double score)
    {
        score = 0;
        return text != null && double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out score) && score > 0 && double.IsFinite(score);
    }

    /// <summary>First line of DevToolsActivePort is the port.</summary>
    public static int ParseActivePort(string content)
    {
        var first = content.Split('\n')[0].Trim();
        return int.TryParse(first, NumberStyles.None, CultureInfo.InvariantCulture, out int port) && port is > 0 and <= 65535 ? port : throw new InvalidOperationException("DevToolsActivePort has no valid port");
    }

    /// <summary>From the /json page list: the WebSocket URL of the page that shows our origin; only ws://127.0.0.1:port/devtools/page/... is accepted.</summary>
    public static string? PickPageSocket(string json, string origin, int port)
    {
        using var doc = JsonDocument.Parse(json);
        foreach (var e in doc.RootElement.EnumerateArray())
        {
            if (!e.TryGetProperty("type", out var t) || t.GetString() != "page") continue;
            if (!e.TryGetProperty("url", out var u) || u.GetString() is not { } url || !url.StartsWith(origin + "/", StringComparison.Ordinal)) continue;
            if (!e.TryGetProperty("webSocketDebuggerUrl", out var w) || w.GetString() is not { } ws) continue;
            if (ws.StartsWith($"ws://127.0.0.1:{port}/devtools/page/", StringComparison.Ordinal) && ws.IndexOfAny(new[] { ' ', '"', '\\' }) < 0) return ws;
        }
        return null;
    }

    /// <summary>The string value of an evaluate answer with the given id, or null.</summary>
    public static string? ParseEvaluate(string message, int id)
    {
        using var doc = JsonDocument.Parse(message);
        var r = doc.RootElement;
        if (!r.TryGetProperty("id", out var i) || i.GetInt32() != id) return null;
        if (r.TryGetProperty("result", out var res) && res.TryGetProperty("result", out var inner) && inner.TryGetProperty("value", out var v) && v.ValueKind == JsonValueKind.String) return v.GetString();
        return "";
    }

    private static async Task<string?> ReadResult(string profile, SiteServer server, CancellationToken ct)
    {
        string portFile = Path.Combine(profile, "DevToolsActivePort");
        while (!File.Exists(portFile)) { await Task.Delay(200, ct); }
        await Task.Delay(300, ct);
        int port = ParseActivePort(await File.ReadAllTextAsync(portFile, ct));
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        string? wsUrl = null;
        while (wsUrl == null)
        {
            try { wsUrl = PickPageSocket(await http.GetStringAsync($"http://127.0.0.1:{port}/json", ct), server.Origin, port); } catch (HttpRequestException) { }
            if (wsUrl == null) await Task.Delay(300, ct);
        }
        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri(wsUrl), ct);
        int id = 0;
        async Task<string?> Eval(string expr)
        {
            int mine = ++id;
            var body = JsonSerializer.Serialize(new { id = mine, method = "Runtime.evaluate", @params = new { expression = expr, returnByValue = true } });
            await ws.SendAsync(Encoding.UTF8.GetBytes(body), WebSocketMessageType.Text, true, ct);
            var buf = new byte[65536];
            while (true)
            {
                var sb = new StringBuilder();
                WebSocketReceiveResult r;
                do { r = await ws.ReceiveAsync(buf, ct); if (r.MessageType == WebSocketMessageType.Close) return null; sb.Append(Encoding.UTF8.GetString(buf, 0, r.Count)); } while (!r.EndOfMessage);
                var v = ParseEvaluate(sb.ToString(), mine);
                if (v != null) return v;
            }
        }
        while (true)
        {
            await Task.Delay(2000, ct);
            if (await Eval("location.hash") == "#summary") return await Eval("document.getElementById('result-number').textContent");
        }
    }
}
