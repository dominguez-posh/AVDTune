using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace AVDTune.Bench;

/// <summary>A tiny HTTP server on 127.0.0.1 and a random port, for the Edge start page, the local Speedometer copy and its wrapper page (design 6, "Loopback only"). GET only, the Host header must be
/// the loopback address with our port (no DNS rebinding), only one folder is served and path traversal, links, drive letters and encoded tricks are refused. Callbacks (/ready, /result and the wrapper
/// page) carry a 128-bit random token per run in the path; anything else gets 404. A request must arrive within a time limit (a CancellationToken, no slow reading) and at most
/// <c>maxConnections</c> connections are served at the same time (more are closed at once). It lives only during the test.</summary>
public sealed class SiteServer : IDisposable
{
    private readonly TcpListener _listener;
    private readonly string? _root;
    private readonly Dictionary<string, (string Type, byte[] Body)> _pages = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _loop;
    private readonly ManualResetEventSlim _ready = new(false);
    private readonly SemaphoreSlim _slots;
    private readonly int _readTimeoutMs;
    private string? _result;
    private int _wrapperServed, _busy;
    private readonly string _secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
    private readonly string _nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
    public int Port { get; }
    public string Origin => $"http://127.0.0.1:{Port}";
    /// <summary>128 random bits as 32 hex characters, new for every server (every run).</summary>
    public string Token { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
    public int RefusedCount;
    public bool ReadyCalled => _ready.IsSet;
    /// <summary>The score text reported by the wrapper page, or null (the first valid report wins).</summary>
    public string? Result => Volatile.Read(ref _result);
    public string WrapperUrl => Origin + "/w/" + Token;
    /// <summary>How many connections were closed at once because the limit was reached (something else is hitting the port, or the browser opened too many). The measure then says "server busy".</summary>
    public int BusyCount => Volatile.Read(ref _busy);

    public SiteServer(string? root, int readTimeoutMs = 5000, int maxConnections = 16)
    {
        _root = root == null ? null : Path.GetFullPath(root).TrimEnd('\\') + "\\";
        _readTimeoutMs = readTimeoutMs;
        _slots = new SemaphoreSlim(maxConnections, maxConnections);
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start(16);
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _pages["/start.html"] = ("text/html; charset=utf-8", Encoding.UTF8.GetBytes(StartPageFor(Token)));
        _loop = Task.Run(Loop);
    }

    /// <summary>The page Edge opens: it calls back to /ready/&lt;token&gt; after the load event and an idle callback (design 1.1: Edge is ready).</summary>
    public static string StartPageFor(string token) => "<!doctype html><html><head><meta charset=\"utf-8\"><title>AVDTune start</title></head><body><h1>AVDTune</h1><script>"
        + "function done(){fetch('/ready/" + token + "',{method:'GET',cache:'no-store'});}"
        + "window.addEventListener('load',function(){if(window.requestIdleCallback){requestIdleCallback(done);}else{setTimeout(done,0);}});"
        + "</script></body></html>";

    /// <summary>The wrapper page of the same origin: Speedometer in an iframe, the number read from #result-number once the hash is #summary and reported to /result/&lt;token&gt;. The page carries a second
    /// secret that is NOT in the command line of Edge (the token is): the server gives it out only inside this page, once; a result without it is refused (a process that read the command line cannot
    /// report a result).</summary>
    public static string WrapperPageFor(string token, int iterations, string secret, string nonce) => "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><title>AVDTune speedometer</title>"
        + "<style>html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%}</style></head><body>"
        + "<iframe id=\"f\" src=\"/index.html?startAutomatically&amp;iterationCount=" + iterations.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\"></iframe><script nonce=\"" + nonce + "\">"
        + "(function(){var f=document.getElementById('f');"
        + "function poll(){try{var w=f.contentWindow;if(w.location.hash==='#summary'){var n=w.document.getElementById('result-number').textContent;"
        + "fetch('/result/" + token + "?v='+encodeURIComponent(String(n).trim())+'&s=" + secret + "',{cache:'no-store',referrerPolicy:'no-referrer'}).catch(function(){setTimeout(poll,2000);});return;}}catch(e){}"
        + "setTimeout(poll,2000);}setTimeout(poll,2000);})();"
        + "</script></body></html>";

    /// <summary>Headers of the wrapper page: nothing but our own origin may load or frame it, only the one script with the nonce runs, no referrer is sent.</summary>
    public static string WrapperCsp(string nonce) => $"default-src 'self'; script-src 'nonce-{nonce}'; style-src 'unsafe-inline'; frame-ancestors 'self'";

    public void AddWrapper(int iterations)
    {
        if (iterations is < 1 or > 100) throw new ArgumentOutOfRangeException(nameof(iterations));
        _pages["/w/" + Token] = ("text/html; charset=utf-8", Encoding.UTF8.GetBytes(WrapperPageFor(Token, iterations, _secret, _nonce)));
    }

    public bool WaitReady(int milliseconds) => _ready.Wait(milliseconds);

    private bool TokenMatches(string given)
    {
        var a = Encoding.ASCII.GetBytes(given); var b = Encoding.ASCII.GetBytes(Token);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }

    /// <summary>What follows the prefix ("/ready/"), or null when the path does not start with it.</summary>
    private static string? After(string path, string prefix) => path.StartsWith(prefix, StringComparison.Ordinal) ? path.Substring(prefix.Length) : null;

    private async Task Loop()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch { break; }
            if (!_slots.Wait(0)) { Interlocked.Increment(ref RefusedCount); Interlocked.Increment(ref _busy); c.Dispose(); continue; }   // connection limit
            _ = Task.Run(async () => { try { await Handle(c); } finally { _slots.Release(); } });
        }
    }

    /// <summary>Parses the request head: returns the path or null (and the status the server sends).</summary>
    public static (string? Path, int Status) ParseRequest(string head, int port)
    {
        var r = ParseRequestFull(head, port);
        return (r.Path, r.Status);
    }

    /// <summary>As <see cref="ParseRequest"/>, with the query string (without the "?"; a fragment is dropped).</summary>
    public static (string? Path, string Query, int Status) ParseRequestFull(string head, int port)
    {
        var lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
        var parts = lines[0].Split(' ');
        if (parts.Length != 3 || !parts[2].StartsWith("HTTP/1.")) return (null, "", 400);
        if (parts[0] != "GET") return (null, "", 405);
        string? host = null;
        for (int i = 1; i < lines.Length; i++)
            if (lines[i].StartsWith("Host:", StringComparison.OrdinalIgnoreCase)) host = lines[i].Substring(5).Trim();
        if (host != $"127.0.0.1:{port}") return (null, "", 421);
        string target = parts[1];
        string query = "";
        int h = target.IndexOf('#');
        if (h >= 0) target = target.Substring(0, h);
        int q = target.IndexOf('?');
        if (q >= 0) { query = target.Substring(q + 1); target = target.Substring(0, q); }
        if (!target.StartsWith("/") || target.Length > 1024 || query.Length > 256) return (null, "", 400);
        return (target, query, 200);
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

    /// <summary>The value of a /result query ("v=27.5&amp;s=&lt;secret&gt;"): only digits and one decimal point, a positive score, and the secret of this run; otherwise null.</summary>
    public static string? ParseResultQuery(string query, string secret)
    {
        var m = Regex.Match(query, @"^v=([0-9]{1,6}(\.[0-9]{1,8})?)&s=([0-9a-f]{32})$", RegexOptions.None, TimeSpan.FromMilliseconds(100));
        if (!m.Success || !Speedometer.TryParseScore(m.Groups[1].Value, out _)) return null;
        return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(m.Groups[3].Value), Encoding.ASCII.GetBytes(secret)) ? m.Groups[1].Value : null;
    }

    private async Task Handle(TcpClient c)
    {
        using (c)
        {
            try
            {
                // one time limit for the whole request (head and answer): a client that is slow or sends nothing is dropped
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                limit.CancelAfter(_readTimeoutMs);
                var ct = limit.Token;
                var ns = c.GetStream();
                var buf = new byte[8192]; int used = 0;
                while (used < buf.Length)
                {
                    int n = await ns.ReadAsync(buf.AsMemory(used), ct);
                    if (n <= 0) return;
                    used += n;
                    if (Encoding.ASCII.GetString(buf, 0, used).Contains("\r\n\r\n")) break;
                }
                string head = Encoding.ASCII.GetString(buf, 0, used);
                head = head.Substring(0, Math.Max(0, head.IndexOf("\r\n\r\n", StringComparison.Ordinal)));
                var (path, query, status) = ParseRequestFull(head, Port);
                if (path == null) { Refuse(); await Send(ns, status, "text/plain", Encoding.ASCII.GetBytes("refused"), ct); return; }
                if (After(path, "/ready/") is { } rt)
                {
                    if (!TokenMatches(rt)) { Refuse(); await Send(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found"), ct); return; }
                    _ready.Set(); await Send(ns, 200, "text/plain", Encoding.ASCII.GetBytes("ok"), ct); return;
                }
                if (After(path, "/result/") is { } st)
                {
                    if (!TokenMatches(st)) { Refuse(); await Send(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found"), ct); return; }
                    var v = ParseResultQuery(query, _secret);
                    if (v == null) { Refuse(); await Send(ns, 400, "text/plain", Encoding.ASCII.GetBytes("refused"), ct); return; }
                    Interlocked.CompareExchange(ref _result, v, null);
                    await Send(ns, 200, "text/plain", Encoding.ASCII.GetBytes("ok"), ct); return;
                }
                if (After(path, "/w/") is { } wt)
                {
                    // the page (with the secret inside) is given out ONCE; a second request gets 404
                    if (!TokenMatches(wt) || !_pages.TryGetValue(path, out var wrap) || Interlocked.Exchange(ref _wrapperServed, 1) != 0) { Refuse(); await Send(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found"), ct); return; }
                    await Send(ns, 200, wrap.Type, wrap.Body, ct, "Content-Security-Policy: " + WrapperCsp(_nonce) + "\r\n"); return;
                }
                if (path == "/start.html" && _pages.TryGetValue(path, out var page)) { await Send(ns, 200, page.Type, page.Body, ct); return; }
                string? file = _root == null ? null : ResolveFile(_root, path);
                if (file == null) { Refuse(); await Send(ns, 404, "text/plain", Encoding.ASCII.GetBytes("not found"), ct); return; }
                await Send(ns, 200, ContentType(file), await File.ReadAllBytesAsync(file, ct), ct);
            }
            catch { }
        }
    }

    private void Refuse() => Interlocked.Increment(ref RefusedCount);

    private static async Task Send(NetworkStream ns, int status, string type, byte[] body, CancellationToken ct, string extraHeaders = "")
    {
        string text = status switch { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed", 421 => "Misdirected Request", _ => "Error" };
        var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {text}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n{extraHeaders}Connection: close\r\n\r\n");
        await ns.WriteAsync(head, ct);
        await ns.WriteAsync(body, ct);
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _listener.Stop(); } catch { }
        try { _loop.Wait(1000); } catch { }
    }
}
