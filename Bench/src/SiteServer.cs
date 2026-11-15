using System.Net;
using System.Net.Sockets;
using System.Text;

namespace AVDTune.Bench;

/// <summary>A tiny HTTP server on 127.0.0.1 and a random port, for the Edge start page and the local Speedometer copy (design 6, "Loopback only"). GET only, the Host header must be
/// the loopback address with our port (no DNS rebinding), only one folder is served and path traversal, links, drive letters and encoded tricks are refused. It lives only during the test.</summary>
public sealed class SiteServer : IDisposable
{
    private readonly TcpListener _listener;
    private readonly string? _root;
    private readonly Dictionary<string, (string Type, byte[] Body)> _pages = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _loop;
    private readonly ManualResetEventSlim _ready = new(false);
    public int Port { get; }
    public string Origin => $"http://127.0.0.1:{Port}";
    public int RefusedCount;
    public bool ReadyCalled => _ready.IsSet;

    public SiteServer(string? root)
    {
        _root = root == null ? null : Path.GetFullPath(root).TrimEnd('\\') + "\\";
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start(16);
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _pages["/start.html"] = ("text/html; charset=utf-8", Encoding.UTF8.GetBytes(StartPage));
        _loop = Task.Run(Loop);
    }

    /// <summary>The page Edge opens: it calls back to /ready after the load event and an idle callback (design 1.1: Edge is ready).</summary>
    public const string StartPage = "<!doctype html><html><head><meta charset=\"utf-8\"><title>AVDTune start</title></head><body><h1>AVDTune</h1><script>"
        + "function done(){fetch('/ready',{method:'GET',cache:'no-store'});}"
        + "window.addEventListener('load',function(){if(window.requestIdleCallback){requestIdleCallback(done);}else{setTimeout(done,0);}});"
        + "</script></body></html>";

    public bool WaitReady(int milliseconds) => _ready.Wait(milliseconds);

    private async Task Loop()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch { break; }
            _ = Task.Run(() => Handle(c));
        }
    }

    /// <summary>Parses the request head: returns the path or null (and the status the server sends).</summary>
    public static (string? Path, int Status) ParseRequest(string head, int port)
    {
        var lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
        var parts = lines[0].Split(' ');
        if (parts.Length != 3 || !parts[2].StartsWith("HTTP/1.")) return (null, 400);
        if (parts[0] != "GET") return (null, 405);
        string? host = null;
        for (int i = 1; i < lines.Length; i++)
            if (lines[i].StartsWith("Host:", StringComparison.OrdinalIgnoreCase)) host = lines[i].Substring(5).Trim();
        if (host != $"127.0.0.1:{port}") return (null, 421);
        string target = parts[1];
        int q = target.IndexOfAny(new[] { '?', '#' });
        if (q >= 0) target = target.Substring(0, q);
        if (!target.StartsWith("/") || target.Length > 1024) return (null, 400);
        return (target, 200);
    }

    /// <summary>Maps a URL path to a file below the root, or null. Refused: dot segments (also encoded, also doubly), backslash, colon (drive, stream), NUL, links, anything outside the root.</summary>
    public static string? ResolveFile(string root, string urlPath)
    {
        string p = urlPath;
        for (int round = 0; round < 2; round++)
        {
            try { p = Uri.UnescapeDataString(p); } catch { return null; }
            if (p.Contains('\0') || p.Contains('\\') || p.Contains(':')) return null;
        }
        // a doubly encoded dot or slash is refused (the first decode must be final)
        if (urlPath.Contains("%25", StringComparison.OrdinalIgnoreCase)) return null;
        string once = Uri.UnescapeDataString(urlPath);
        foreach (var seg in once.Split('/')) if (seg == ".." || seg == ".") return null;
        string rel = once.TrimStart('/');
        if (rel.Length == 0 || rel.EndsWith("/")) rel += "index.html";
        string full;
        try { full = Path.GetFullPath(Path.Combine(root, rel.Replace('/', '\\'))); } catch { return null; }
        string r = Path.GetFullPath(root).TrimEnd('\\') + "\\";
        if (!full.StartsWith(r, StringComparison.OrdinalIgnoreCase)) return null;
        // no link anywhere between the root and the file
        string cur = full;
        while (cur.Length > r.Length)
        {
            FileSystemInfo i = Directory.Exists(cur) ? new DirectoryInfo(cur) : new FileInfo(cur);
            if (i.Exists && (i.Attributes & FileAttributes.ReparsePoint) != 0) return null;
            cur = Path.GetDirectoryName(cur) ?? "";
            if (cur.Length < r.Length - 1) break;
        }
        return File.Exists(full) ? full : null;
    }

    public static string ContentType(string file) => Path.GetExtension(file).ToLowerInvariant() switch
    {
        ".html" or ".htm" => "text/html; charset=utf-8", ".js" or ".mjs" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8", ".json" => "application/json",
        ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".svg" => "image/svg+xml", ".ico" => "image/x-icon", ".woff2" => "font/woff2", ".woff" => "font/woff",
        ".txt" => "text/plain; charset=utf-8", ".map" => "application/json", ".webp" => "image/webp", ".mp4" => "video/mp4", _ => "application/octet-stream",
    };

    private async Task Handle(TcpClient c)
    {
        using (c)
        {
            try
            {
                c.ReceiveTimeout = 5000; c.SendTimeout = 15000;
                var ns = c.GetStream();
                var buf = new byte[8192]; int used = 0;
                while (used < buf.Length)
                {
                    int n = await ns.ReadAsync(buf.AsMemory(used), _cts.Token);
                    if (n <= 0) return;
                    used += n;
                    if (Encoding.ASCII.GetString(buf, 0, used).Contains("\r\n\r\n")) break;
                }
                string head = Encoding.ASCII.GetString(buf, 0, used);
                head = head.Substring(0, Math.Max(0, head.IndexOf("\r\n\r\n", StringComparison.Ordinal)));
                var (path, status) = ParseRequest(head, Port);
                if (path == null) { Interlocked.Increment(ref RefusedCount); await Send(ns, status, "text/plain", Encoding.ASCII.GetBytes("refused")); return; }
                if (path == "/ready") { _ready.Set(); await Send(ns, 200, "text/plain", Encoding.ASCII.GetBytes("ok")); return; }
                if (_pages.TryGetValue(path, out var page)) { await Send(ns, 200, page.Type, page.Body); return; }
                string? file = _root == null ? null : ResolveFile(_root, path);
                if (file == null) { Interlocked.Increment(ref RefusedCount); await Send(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                await Send(ns, 200, ContentType(file), await File.ReadAllBytesAsync(file, _cts.Token));
            }
            catch { }
        }
    }

    private static async Task Send(NetworkStream ns, int status, string type, byte[] body)
    {
        string text = status switch { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed", 421 => "Misdirected Request", _ => "Error" };
        var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {text}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n");
        await ns.WriteAsync(head);
        await ns.WriteAsync(body);
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _listener.Stop(); } catch { }
        try { _loop.Wait(1000); } catch { }
    }
}
