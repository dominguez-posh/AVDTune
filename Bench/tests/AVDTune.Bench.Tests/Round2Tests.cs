using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AVDTune.Bench.Tests;

/// <summary>Checks of round 2 (issue #14): test documents, loopback server, program rules, Speedometer parsing, capacity maths and probe, GPU choice, share measures, job objects.</summary>
internal static class Round2
{
    private static int _failed;
    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) Console.WriteLine("PASS " + name);
        else { _failed++; Console.WriteLine("FAIL " + name + (detail != "" ? "  -> " + detail : "")); }
    }
    private static bool Near(double a, double b, double tol) => Math.Abs(a - b) <= tol;
    private static bool Throws(Action a) { try { a(); return false; } catch { return true; } }
    private static string Temp() { var d = Path.Combine(Path.GetTempPath(), "avdtune-bench-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(d); return d; }

    public static int Run()
    {
        Docs(); Site(); AppRules(); SpeedometerParsing(); LauncherChecks(); CapacityChecks(); GpuChecks(); ShareChecks(); JobChecks();
        return _failed;
    }

    private static string EntryHash(ZipArchive z)
    {
        using var sha = SHA256.Create();
        foreach (var e in z.Entries.OrderBy(e => e.FullName, StringComparer.Ordinal)) { using var s = e.Open(); var h = sha.ComputeHash(s); sha.TransformBlock(h, 0, h.Length, null, 0); }
        sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return Convert.ToHexString(sha.Hash!);
    }

    private static void Docs()
    {
        var dir = Temp();
        try
        {
            var docx = Path.Combine(dir, "a.docx"); var docx2 = Path.Combine(dir, "b.docx"); var xlsx = Path.Combine(dir, "a.xlsx"); var xlsx2 = Path.Combine(dir, "b.xlsx");
            TestDocs.WriteDocx(docx); TestDocs.WriteDocx(docx2); TestDocs.WriteXlsx(xlsx); TestDocs.WriteXlsx(xlsx2);
            using (var z = ZipFile.OpenRead(docx))
            {
                var names = z.Entries.Select(e => e.FullName).ToList();
                Check("docx: the three OOXML parts are there", names.Contains("[Content_Types].xml") && names.Contains("_rels/.rels") && names.Contains("word/document.xml"));
                using var s = z.GetEntry("word/document.xml")!.Open();
                var xml = System.Xml.Linq.XDocument.Load(s);
                System.Xml.Linq.XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
                int breaks = xml.Descendants(w + "br").Count(b => (string?)b.Attribute(w + "type") == "page");
                int paras = xml.Descendants(w + "p").Count();
                Check("docx: 20 pages (19 page breaks), well-formed XML", breaks == 19 && paras >= 20 * 34, $"{breaks} {paras}");
            }
            using (var z = ZipFile.OpenRead(xlsx))
            {
                int formulas = 0, sheets = 0;
                foreach (var e in z.Entries.Where(e => e.FullName.StartsWith("xl/worksheets/")))
                {
                    sheets++;
                    using var sr = new StreamReader(e.Open());
                    var text = sr.ReadToEnd();
                    System.Xml.Linq.XDocument.Parse(text);
                    formulas += text.Split("<f>").Length - 1;
                }
                Check("xlsx: 10 sheets with 50 000 formulas", sheets == 10 && formulas == 50000, $"{sheets} {formulas}");
            }
            using (var a = ZipFile.OpenRead(docx)) using (var b = ZipFile.OpenRead(docx2)) Check("docx: deterministic", EntryHash(a) == EntryHash(b));
            using (var a = ZipFile.OpenRead(xlsx)) using (var b = ZipFile.OpenRead(xlsx2)) Check("xlsx: deterministic", EntryHash(a) == EntryHash(b));
            Check("docx: an existing file is never overwritten (CreateNew)", Throws(() => TestDocs.WriteDocx(docx)));
            var folder = TestDocs.WriteFolder500(dir, "folder500");
            Check("explorer folder: 500 files", Directory.GetFiles(folder).Length == 500);
            Check("explorer folder: a bad folder name is refused", Throws(() => TestDocs.WriteFolder500(dir, "a\\..\\b")));
        }
        finally { Directory.Delete(dir, true); }
    }

    private static string Raw(int port, string request)
    {
        using var c = new System.Net.Sockets.TcpClient("127.0.0.1", port);
        c.ReceiveTimeout = 5000;
        var ns = c.GetStream();
        var b = Encoding.ASCII.GetBytes(request); ns.Write(b, 0, b.Length);
        var sb = new StringBuilder(); var buf = new byte[4096]; int n;
        while ((n = ns.Read(buf, 0, buf.Length)) > 0) sb.Append(Encoding.ASCII.GetString(buf, 0, n));
        return sb.ToString();
    }

    private static void Site()
    {
        Check("request: a good GET gives the path (query stripped)", SiteServer.ParseRequest("GET /a/b.js?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5000", 5000) is ("/a/b.js", 200));
        Check("request: POST is refused (405)", SiteServer.ParseRequest("POST /a HTTP/1.1\r\nHost: 127.0.0.1:5000", 5000).Status == 405);
        Check("request: a foreign Host or port is refused (DNS rebinding)", SiteServer.ParseRequest("GET /a HTTP/1.1\r\nHost: evil.example:5000", 5000).Status == 421 && SiteServer.ParseRequest("GET /a HTTP/1.1\r\nHost: 127.0.0.1:5001", 5000).Status == 421 && SiteServer.ParseRequest("GET /a HTTP/1.1", 5000).Status == 421);
        Check("request: garbage is refused (400)", SiteServer.ParseRequest("HELLO", 5000).Status == 400 && SiteServer.ParseRequest("GET a HTTP/1.1\r\nHost: 127.0.0.1:5000", 5000).Status == 400);
        var root = Temp();
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "sub"));
            File.WriteAllText(Path.Combine(root, "index.html"), "<html>idx</html>");
            File.WriteAllText(Path.Combine(root, "sub", "a.mjs"), "export {}");
            var outside = Path.Combine(Directory.GetParent(root)!.FullName, "avdtune-secret-" + Guid.NewGuid().ToString("N") + ".txt");
            File.WriteAllText(outside, "secret");
            try
            {
                Check("resolve: a file and the folder index are found", SiteServer.ResolveFile(root, "/sub/a.mjs") == Path.Combine(root, "sub", "a.mjs") && SiteServer.ResolveFile(root, "/") == Path.Combine(root, "index.html"));
                string name = Path.GetFileName(outside);
                var bad = new[] { "/../" + name, "/%2e%2e/" + name, "/%2E%2E/" + name, "/sub/../../" + name, "/%252e%252e/" + name, "/sub\\..\\..\\" + name, "/sub/..%5c" + name, "/C:/Windows/win.ini", "/a.mjs::$DATA", "/sub/%00", "/./index.html" };
                var leaked = bad.Where(p => SiteServer.ResolveFile(root, p) != null).ToList();
                Check("resolve: traversal, (doubly) encoded dots, backslash, drive letter, stream and NUL are refused", leaked.Count == 0, string.Join(" ", leaked));
                Check("resolve: a missing file is refused", SiteServer.ResolveFile(root, "/nope.js") == null);
                bool made = false;
                try { Directory.CreateSymbolicLink(Path.Combine(root, "linked"), Directory.GetParent(root)!.FullName); made = true; } catch { }
                if (made) Check("resolve: a link inside the folder is refused", SiteServer.ResolveFile(root, "/linked/" + name) == null);
                else Console.WriteLine("SKIP resolve: link (no right to make a symbolic link)");
            }
            finally { File.Delete(outside); }

            using var server = new SiteServer(root);
            Check("server: loopback address, random port", server.Origin.StartsWith("http://127.0.0.1:") && server.Port > 1024);
            string ok = Raw(server.Port, $"GET /sub/a.mjs HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n");
            Check("server: serves a file of the folder with its type", ok.StartsWith("HTTP/1.1 200") && ok.Contains("text/javascript") && ok.EndsWith("export {}"), ok);
            string G(string path) => Raw(server.Port, $"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n");
            Check("server: the token is 128 bits (32 hex characters), new for every server", server.Token.Length == 32 && server.Token.All(Uri.IsHexDigit) && server.Token != new SiteServer(null).Token);
            Check("server: the start page calls back to /ready/<token>", G("/start.html").Contains("/ready/" + server.Token) && !server.ReadyCalled);
            Check("server: /ready without the token or with a wrong one gets 404 and is not noticed", G("/ready").StartsWith("HTTP/1.1 404") && G("/ready/" + new string('0', 32)).StartsWith("HTTP/1.1 404") && G("/ready/" + server.Token.Substring(0, 31)).StartsWith("HTTP/1.1 404") && !server.ReadyCalled);
            G("/ready/" + server.Token);
            Check("server: /ready/<token> is noticed", server.WaitReady(2000));
            server.AddWrapper(3);
            string wrap = G("/w/" + server.Token);
            string secret = System.Text.RegularExpressions.Regex.Match(wrap, "&s=([0-9a-f]{32})").Groups[1].Value;
            Check("wrapper: same origin page with Speedometer in an iframe, reading #result-number and reporting to /result/<token> with a second secret", wrap.StartsWith("HTTP/1.1 200") && wrap.Contains("<iframe") && wrap.Contains("src=\"/index.html?startAutomatically&amp;iterationCount=3\"") && wrap.Contains("result-number") && wrap.Contains("/result/" + server.Token) && secret.Length == 32 && !wrap.Contains("http://") && !wrap.Contains("devtools", StringComparison.OrdinalIgnoreCase));
            Check("wrapper: the secret is not the token and not in the Edge command line (WrapperUrl), only in the page", secret != server.Token && !server.WrapperUrl.Contains(secret) && !server.Origin.Contains(secret));
            Check("wrapper: Referrer-Policy no-referrer, CSP default-src 'self' and frame-ancestors 'self', a nonce for the one script, no unsafe-eval", wrap.Contains("Referrer-Policy: no-referrer") && wrap.Contains("Content-Security-Policy: default-src 'self'") && wrap.Contains("frame-ancestors 'self'") && wrap.Contains("script-src 'nonce-") && !wrap.Contains("unsafe-eval") && wrap.Contains("<script nonce=\"") && G("/start.html").Contains("Referrer-Policy: no-referrer"));
            Check("wrapper: given out once (the secret is not handed to a second request), a wrong token gets 404", G("/w/" + server.Token).StartsWith("HTTP/1.1 404") && G("/w/" + new string('a', 32)).StartsWith("HTTP/1.1 404") && !G("/w/x").Contains("<iframe"));
            Check("result: nothing is reported before the page does", server.Result == null);
            Check("result: without the secret, with a wrong secret, a wrong token or a bad value it is refused and changes nothing", G("/result/" + server.Token + "?v=27.5").StartsWith("HTTP/1.1 400") && G("/result/" + server.Token + "?v=27.5&s=" + new string('0', 32)).StartsWith("HTTP/1.1 400") && G("/result/" + new string('b', 32) + "?v=99&s=" + secret).StartsWith("HTTP/1.1 404") && G("/result/" + server.Token + "?v=abc&s=" + secret).StartsWith("HTTP/1.1 400") && G("/result/" + server.Token + "?v=1e9&s=" + secret).StartsWith("HTTP/1.1 400") && G("/result/" + server.Token + "?v=-4&s=" + secret).StartsWith("HTTP/1.1 400") && G("/result/" + server.Token + "?v=0&s=" + secret).StartsWith("HTTP/1.1 400") && server.Result == null);
            Check("result: the first valid report with the secret is kept, a second one does not replace it", G("/result/" + server.Token + "?v=27.5&s=" + secret).StartsWith("HTTP/1.1 200") && server.Result == "27.5" && G("/result/" + server.Token + "?v=99&s=" + secret).StartsWith("HTTP/1.1 200") && server.Result == "27.5");
            Check("result: ParseResultQuery needs the secret of the run", SiteServer.ParseResultQuery("v=1.5&s=" + secret, secret) == "1.5" && SiteServer.ParseResultQuery("v=1.5&s=" + secret, new string('1', 32)) == null && SiteServer.ParseResultQuery("v=1.5", secret) == null);
            Check("speedometer: a score outside the plausible band (0.5 to 500 runs/min) is refused", Speedometer.Plausible(27.5) && Speedometer.Plausible(0.5) && !Speedometer.Plausible(0.01) && !Speedometer.Plausible(5000) && !Speedometer.Plausible(double.NaN));
            Check("request: the query is returned (and the fragment dropped)", SiteServer.ParseRequestFull("GET /result/x?v=1.5#f HTTP/1.1\r\nHost: 127.0.0.1:5000", 5000) is ("/result/x", "v=1.5", 200));
            string wrong = Raw(server.Port, "GET /index.html HTTP/1.1\r\nHost: attacker.example\r\n\r\n");
            Check("server: a wrong Host gets 421, no content", wrong.StartsWith("HTTP/1.1 421") && !wrong.Contains("idx"));
            Check("server: a traversal request gets 404", Raw(server.Port, $"GET /../x.txt HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n").StartsWith("HTTP/1.1 404"));
            Check("server: POST gets 405", Raw(server.Port, $"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n").StartsWith("HTTP/1.1 405"));
            Check("server: refused requests are counted", server.RefusedCount >= 3, server.RefusedCount.ToString());
            // slow clients: a connection that sends nothing is dropped after the time limit, and only a few are served at the same time
            using (var slow = new SiteServer(root, readTimeoutMs: 400, maxConnections: 3))
            {
                var held = new List<System.Net.Sockets.TcpClient>();
                for (int i2 = 0; i2 < 10; i2++) { var c = new System.Net.Sockets.TcpClient("127.0.0.1", slow.Port); held.Add(c); }
                Thread.Sleep(300);
                Check("server: more connections than the limit are closed at once (counted as refused, and as busy so the measure can say 'server busy')", slow.RefusedCount >= 5 && slow.BusyCount >= 5 && new SiteServer(null).BusyCount == 0, slow.RefusedCount.ToString());
                double t0 = Timing.Now(); bool closed = false;
                try { var ns = held[0].GetStream(); held[0].ReceiveTimeout = 4000; closed = ns.Read(new byte[16], 0, 16) == 0; } catch (IOException) { closed = true; }
                Check("server: a client that sends nothing is dropped after the read time limit (cancellation token)", closed && Timing.Now() - t0 < 3.0, (Timing.Now() - t0).ToString("0.0"));
                foreach (var c in held) c.Dispose();
                Thread.Sleep(600);
                string again = Raw(slow.Port, $"GET /index.html HTTP/1.1\r\nHost: 127.0.0.1:{slow.Port}\r\n\r\n");
                Check("server: it answers again after the slow clients are gone", again.StartsWith("HTTP/1.1 200"), again);
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void AppRules()
    {
        string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string ps = Path.Combine(sys, "WindowsPowerShell", "v1.0", "powershell.exe");
        var roots = Apps.DefaultRoots();
        if (File.Exists(ps)) Check("apps: the real powershell.exe is accepted", Apps.ValidateExe("powershell", ps, roots) == null, Apps.ValidateExe("powershell", ps, roots));
        Check("apps: a wrong file name is refused", Apps.ValidateExe("powershell", Path.Combine(sys, "cmd.exe"), roots) != null);
        Check("apps: an unknown key (outlook) is refused", Apps.ValidateExe("outlook", ps, roots) != null);
        Check("apps: relative, UNC and dot-segment paths are refused", Apps.ValidateExe("powershell", "powershell.exe", roots) != null && Apps.ValidateExe("powershell", @"\\host\share\powershell.exe", roots) != null && Apps.ValidateExe("powershell", sys + @"\..\system32\powershell.exe", roots) != null);
        var dir = Temp();
        try
        {
            string fake = Path.Combine(dir, "EXCEL.EXE"); File.WriteAllText(fake, "x");
            Check("apps: a program outside Windows and Program Files is refused", Apps.ValidateExe("excel", fake, roots) is { } why && why.Contains("not below"));
            Check("apps: the same file is accepted when its folder is a root", Apps.ValidateExe("excel", fake, new[] { dir }) == null);
            Check("apps: a missing file is refused", Apps.ValidateExe("excel", Path.Combine(dir, "x", "EXCEL.EXE"), new[] { dir }) != null);
        }
        finally { Directory.Delete(dir, true); }

        bool NoChild(IntPtr h, string c) => false;
        bool Child(IntPtr h, string c) => true;
        var vis = new Apps.WinInfo(IntPtr.Zero, "OpusApp", "Document1 - Word", true);
        Check("ready: Word = OpusApp, visible, with _WwG", Apps.IsReady("word", new[] { vis }, Child) && !Apps.IsReady("word", new[] { vis }, NoChild) && !Apps.IsReady("word", new[] { vis with { Visible = false } }, Child) && !Apps.IsReady("word", new[] { vis with { Class = "Other" } }, Child));
        var xl = new Apps.WinInfo(IntPtr.Zero, "XLMAIN", "Excel", true);
        Check("ready: Excel = XLMAIN with EXCEL7", Apps.IsReady("excel", new[] { xl }, Child) && !Apps.IsReady("excel", new[] { xl }, NoChild));
        var ed = new Apps.WinInfo(IntPtr.Zero, "Chrome_WidgetWin_1", "x", true);
        Check("ready: Edge needs its window and the page call back", Apps.IsReady("edge", new[] { ed }, NoChild, true) && !Apps.IsReady("edge", new[] { ed }, NoChild, false) && !Apps.IsReady("edge", Array.Empty<Apps.WinInfo>(), NoChild, true));
        var ex = new Apps.WinInfo(IntPtr.Zero, "CabinetWClass", "AVDTuneBench1234", true);
        Check("ready: Explorer = the new folder window by title only", Apps.IsReady("explorer", new[] { ex }, NoChild, false, "AVDTuneBench1234") && !Apps.IsReady("explorer", new[] { ex }, NoChild, false, "Documents") && !Apps.IsReady("explorer", new[] { ex }, NoChild, false, null));
        Check("ready: an unknown application is never ready", !Apps.IsReady("outlook", new[] { vis }, Child));

        var dir2 = Temp();
        try
        {
            var r = Apps.Run(new Options { Dir = dir2, NoCold = true });
            Check("apps: without program paths every start is skipped with a reason, nothing runs", r.Count >= 10 && r.All(m => m.Status == "skipped") && r.Any(m => m.Id == "host.app.word.cold") && r.Any(m => m.Id == "host.app.speedometer" && m.Reason!.Contains("--site")), string.Join(";", r.Select(m => m.Id + ":" + m.Status)));
            Check("apps: Outlook and Teams are skipped with their reason", r.First(m => m.Id == "host.app.outlook.warm").Reason!.Contains("not part") && r.First(m => m.Id == "host.app.teams.warm").Reason!.Contains("not verified"));
            Check("apps: the work folder is removed afterwards", Directory.GetFileSystemEntries(dir2).Length == 0);
            var bad = Apps.Run(new Options { Dir = dir2, NoCold = true, AppPaths = { ["word"] = @"C:\Users\Public\WINWORD.EXE" } });
            Check("apps: a refused path is named in the reason", bad.First(m => m.Id == "host.app.word.warm").Reason!.StartsWith("refused:"));
            Check("apps: a missing work folder is a failed measure", Apps.Run(new Options { Dir = Path.Combine(dir2, "nope") })[0].Status == "failed");
        }
        finally { Directory.Delete(dir2, true); }

        var p = Options.Parse(new[] { "apps", "--app", @"word=C:\Program Files\x\WINWORD.EXE", "--site", "S", "--no-cold", "--speed-iterations", "1", "--host", "acct.file.core.windows.net" });
        Check("options: --app, --site, --no-cold, --speed-iterations, --host", p.AppPaths["word"].EndsWith("WINWORD.EXE") && p.Site == "S" && p.NoCold && p.SpeedIterations == 1 && p.HostName == "acct.file.core.windows.net");
        Check("options: bad --app, host and ranges are refused", Throws(() => Options.Parse(new[] { "apps", "--app", "word" })) && Throws(() => Options.Parse(new[] { "apps", "--app", "calc=C:\\x.exe" })) && Throws(() => Options.Parse(new[] { "share", "--host", "a b" })) && Throws(() => Options.Parse(new[] { "share", "--host", "a;calc" })) && Throws(() => Options.Parse(new[] { "capacity", "--max-users", "0" })) && Throws(() => Options.Parse(new[] { "apps", "--speed-iterations", "99" })));
    }

    private static void SpeedometerParsing()
    {
        Check("speedometer: a score is a positive number", Speedometer.TryParseScore("27.5", out double s) && s == 27.5 && !Speedometer.TryParseScore("abc", out _) && !Speedometer.TryParseScore("-1", out _) && !Speedometer.TryParseScore("NaN", out _) && !Speedometer.TryParseScore(null, out _) && !Speedometer.TryParseScore("0", out _));
        string? srcDir = null;
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null && srcDir == null; d = d.Parent) if (File.Exists(Path.Combine(d.FullName, "src", "Speedometer.cs"))) srcDir = Path.Combine(d.FullName, "src");
        string all = srcDir == null ? "" : string.Concat(Directory.GetFiles(srcDir, "*.cs").Select(File.ReadAllText));
        Check("source: no remote-debugging-port, DevToolsActivePort, WebSocket client or Runtime.evaluate anywhere in the measure program (finding 1)", all.Length > 1000 && !all.Contains("remote-debugging-port") && !all.Contains("DevToolsActivePort") && !all.Contains("ClientWebSocket") && !all.Contains("Runtime.evaluate") && !all.Contains("System.Net.WebSockets"), srcDir ?? "src not found");
        var edge = Apps.EdgeArgs(@"C:\p", "http://127.0.0.1:1/w/x", "--window-size=1280,900");
        Check("edge: InPrivate, throw-away profile, no first run, no sync, no extensions, no debugging port, the page last", edge.Contains("--inprivate") && edge.Contains(@"--user-data-dir=C:\p") && edge.Contains("--no-first-run") && edge.Contains("--disable-sync") && edge.Contains("--disable-extensions") && !edge.Any(a => a.Contains("remote-debugging")) && edge[^1].StartsWith("http://127.0.0.1:"));
    }

    public static int NotRun;
    private static bool Wrap(Action a) { try { a(); return true; } catch { return false; } }
    private static string SrcText()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent) if (File.Exists(Path.Combine(d.FullName, "src", "Speedometer.cs"))) return string.Concat(Directory.GetFiles(Path.Combine(d.FullName, "src"), "*.cs").Select(File.ReadAllText));
        return "";
    }
    private static bool MakeJunction(string link, string target)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe")) { UseShellExecute = false, CreateNoWindow = true };
            psi.ArgumentList.Add("/c"); psi.ArgumentList.Add("mklink"); psi.ArgumentList.Add("/J"); psi.ArgumentList.Add(link); psi.ArgumentList.Add(target);
            using var p = System.Diagnostics.Process.Start(psi)!; p.WaitForExit(10000);
            return Directory.Exists(link) && (new DirectoryInfo(link).Attributes & FileAttributes.ReparsePoint) != 0;
        }
        catch { return false; }
    }

    private static void IsolatedUserChecks()
    {
        var n1 = IsolatedUser.NewName(); var n2 = IsolatedUser.NewName();
        Check("isolated user (#92): the name is the prefix and 12 random hex digits, at most 20 characters, different per run", System.Text.RegularExpressions.Regex.IsMatch(n1, "^avdtb-[0-9a-f]{12}$") && n1.Length <= 20 && n1 != n2, n1);
        Check("isolated user (#92): only an account with the exact name form AND the marker is a leftover to remove; a look-alike or another description is never touched",
            IsolatedUser.IsLeftover(n1, IsolatedUser.Marker) && !IsolatedUser.IsLeftover(n1, "made by someone else") && !IsolatedUser.IsLeftover(n1, null) && !IsolatedUser.IsLeftover("avdtb-ABCDEF123456", IsolatedUser.Marker)
            && !IsolatedUser.IsLeftover("avdtb-0123456789ab-x", IsolatedUser.Marker) && !IsolatedUser.IsLeftover("Administrator", IsolatedUser.Marker) && !IsolatedUser.IsLeftover("xavdtb-0123456789ab", IsolatedUser.Marker));
        var pw1 = IsolatedUser.NewPassword(); var pw2 = IsolatedUser.NewPassword();
        Check("isolated user (#92): the password is 40 random characters with upper, lower, digit and symbol, different per run, a char array (zeroed by the caller)", pw1.Length == IsolatedUser.PasswordLength && IsolatedUser.PasswordOk(pw1) && !pw1.SequenceEqual(pw2) && !IsolatedUser.PasswordOk("abcdefghijklmnopqrst".ToCharArray()) && Throws(() => IsolatedUser.NewPassword(8)));
        Array.Clear(pw1); Array.Clear(pw2);
        var env = IsolatedUser.ChildEnvironment(new[] { @"USERPROFILE=C:\Users\avdtb-0123456789ab", @"TEMP=C:\Users\avdtb-0123456789ab\AppData\Local\Temp", "Path=C:\\Windows" }, @"C:\w\tmp");
        Check("isolated user (#92): the programs get the user's own environment (its profile), TEMP and TMP in the work folder", env["USERPROFILE"] == @"C:\Users\avdtb-0123456789ab" && env["TEMP"] == @"C:\w\tmp" && env["TMP"] == @"C:\w\tmp" && env["PATH"] == "C:\\Windows");
        Check("isolated user (#92): the account must be in Users only (another group fails closed)", IsolatedUser.GroupProblem(new[] { "Users" }, "Users") == null && IsolatedUser.GroupProblem(new[] { "Users", "Administrators" }, "Users") != null && IsolatedUser.GroupProblem(Array.Empty<string>(), "Users") != null);
        Check("isolated user (#92): the default DACL of its token is the user, SYSTEM and Administrators (AVDTune can wait for and end the programs)", IsolatedUser.DefaultDaclSddl("S-1-5-21-1-2-3-1001") == "D:(A;;GA;;;S-1-5-21-1-2-3-1001)(A;;GA;;;SY)(A;;GA;;;BA)");
        Check("isolated user (#92): window station without clipboard, screen reading or exit; desktop without journal hooks or desktop switch", (IsolatedUser.WinstaRights & (0x4u | 0x200u | 0x40u | 0x10u | 0x8u)) == 0 && (IsolatedUser.DesktopRights & (0x10u | 0x20u | 0x100u)) == 0);
        Check("isolated user (#92): the default is the temporary user; --reduced-token is the explicit exception", !Options.Parse(new[] { "apps" }).ReducedToken && Options.Parse(new[] { "apps", "--reduced-token" }).ReducedToken);
        var src = SrcText();
        Check("isolated user (#92, source): leftovers are removed before a new account, the password is freed right after LogonUser, the domain-admin refusal (#84) stays, the child token is read back before it runs",
            src.Contains("var left = CleanupLeftovers();") && src.Contains("FreePassword(ref pw);") && src.Contains("if (RestrictedLauncher.DomainAdminRefusal(") && src.Contains("if (user != Sid.Value) throw") && src.Contains("if (RestrictedLauncher.TokenProblem(facts) is { } problem) throw")
            && src.Contains("private static IAppLauncher MakeLauncher(Options o) => o.ReducedToken ? new ReducedTokenLauncher() : IsolatedUser.Create();") && src.Contains("(launcher as IDisposable)?.Dispose();"));
    }

    private static void LauncherChecks()
    {
        IsolatedUserChecks();
        Check("launcher: arguments are quoted the way CommandLineToArgvW reads them back", RestrictedLauncher.QuoteArg("abc") == "abc" && RestrictedLauncher.QuoteArg("a b") == "\"a b\"" && RestrictedLauncher.QuoteArg("") == "\"\"" && RestrictedLauncher.QuoteArg("a\"b") == "\"a\\\"b\"" && RestrictedLauncher.QuoteArg(@"C:\x y\") == "\"C:\\x y\\\\\"" && RestrictedLauncher.BuildArguments(new[] { "/q", "a b" }) == "/q \"a b\"");
        Check("launcher: the environment block is sorted, NUL-ended, NUL at the end", RestrictedLauncher.EnvironmentBlock(new Dictionary<string, string> { ["b"] = "2", ["A"] = "1" }) == "A=1\0b=2\0\0");
        Check("launcher: only a token that is not elevated and Medium or lower is accepted", RestrictedLauncher.IntegrityAcceptable(0x2000, false) && RestrictedLauncher.IntegrityAcceptable(0x1000, false) && !RestrictedLauncher.IntegrityAcceptable(0x3000, false) && !RestrictedLauncher.IntegrityAcceptable(0x2000, true) && !RestrictedLauncher.IntegrityAcceptable(0x4000, true));
        Check("launcher: the token is made in one step from this process's token (a child, else CreateProcessAsUser fails with 1314) as a LUA token (LUA_TOKEN | DISABLE_MAX_PRIVILEGE, Administrators, admin-like groups and S-1-5-114 deny-only), else a RID 500 admin stays TokenIsElevated (#14 N1)", RestrictedLauncher.RestrictFlags == 0x5u && RestrictedLauncher.DenyOnlySids.Contains("S-1-5-32-544") && RestrictedLauncher.DenyOnlySids.Contains("S-1-5-32-547") && RestrictedLauncher.DenyOnlySids.Contains("S-1-5-114") && SrcText().Contains("CreateRestrictedToken(self, RestrictFlags,") && !SrcText().Contains("SaferComputeTokenFromLevel("));
        Check("launcher: owner and default DACL of the reduced token are the user and SYSTEM (not Administrators, which is deny-only there; else a console program ends with 0xC0000142, #14 N1)", RestrictedLauncher.DefaultDaclSddl("S-1-5-21-1-2-3-1001") == "D:(A;;GA;;;S-1-5-21-1-2-3-1001)(A;;GA;;;SY)" && SrcText().Contains("SetUserDefaults(token);") && SrcText().Contains("SetTokenInformation(token, 6, ref dacl,") && SrcText().Contains("SetTokenInformation(token, 4, ref user,"));
        const string da = "S-1-5-21-1111-2222-3333-512", ea = "S-1-5-21-1111-2222-3333-519", du = "S-1-5-21-1111-2222-3333-513";
        Check("domain groups: Domain Admins, Enterprise Admins and the other UAC-filtered or admin-like domain RIDs are found by RID in any domain, Domain Users and other forms are not (#84)", RestrictedLauncher.IsDomainPrivileged(da) && RestrictedLauncher.IsDomainPrivileged(ea) && new uint[] { 498, 512, 516, 517, 518, 519, 520, 521, 526, 527, 553 }.All(r => RestrictedLauncher.IsDomainPrivileged("S-1-5-21-9-8-7-" + r)) && !RestrictedLauncher.IsDomainPrivileged(du) && !RestrictedLauncher.IsDomainPrivileged("S-1-5-21-1111-2222-512") && !RestrictedLauncher.IsDomainPrivileged("S-1-5-32-512") && !RestrictedLauncher.IsDomainPrivileged("S-1-5-21-1111-2222-3333-x512") && RestrictedLauncher.IsAdminLike("S-1-5-32-554") && RestrictedLauncher.IsAdminLike("S-1-5-32-569"));
        Check("domain groups: the deny-only list is the fixed list plus every domain-privileged group of the token (dynamic, #84)", RestrictedLauncher.DenyOnlyFor(new[] { (da, 0x7u), (du, 0x7u), ("S-1-5-32-544", 0xFu) }) is var dl && dl.Contains(da) && !dl.Contains(du) && dl.Contains("S-1-5-32-544") && dl.Count == RestrictedLauncher.DenyOnlySids.Length + 1);
        Check("token facts: a reduced token with Domain Admins (512) enabled is a FAIL, deny-only is fine (#84)", RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x10u), (da, 0x7u) }) is { } p512 && p512.Contains(da) && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x10u), (da, 0x10u) }) == null && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-569", 0x7u) }) != null
            && RestrictedLauncher.TokenProblem(new RestrictedLauncher.TokenFacts(0x2000, false, new() { ("S-1-5-32-544", 0x10u), (da, 0x7u) }, new() { "SeChangeNotifyPrivilege" })) != null
            && RestrictedLauncher.TokenProblem(new RestrictedLauncher.TokenFacts(0x2000, false, new() { ("S-1-5-32-544", 0x10u), (da, 0x10u) }, new() { "SeChangeNotifyPrivilege" })) == null
            && RestrictedLauncher.TokenProblem(new RestrictedLauncher.TokenFacts(0x2000, false, new() { ("S-1-5-32-544", 0x10u) }, new() { "SeChangeNotifyPrivilege", "SeDebugPrivilege" })) is { } pp && pp.Contains("SeDebugPrivilege")
            && RestrictedLauncher.TokenProblem(new RestrictedLauncher.TokenFacts(0x3000, false, new(), new())) != null);
        Check("domain groups: an elevated token in Domain Admins refuses app starts with 'app starts only with a local admin'; a local admin and a deny-only group are fine; MakeToken checks it and reads the reduced token back (#84)", RestrictedLauncher.DomainAdminRefusal(new[] { ("S-1-5-32-544", 0xFu), (da, 0x7u) }) is { } rf && rf.StartsWith("app starts only with a local admin") && rf.Contains(da) && RestrictedLauncher.DomainAdminRefusal(new[] { ("S-1-5-32-544", 0xFu), (du, 0x7u) }) == null && RestrictedLauncher.DomainAdminRefusal(new[] { (da, 0x10u) }) == null
            && SrcText().Contains("if (DomainAdminRefusal(own) is { } refusal) throw new InvalidOperationException(refusal);") && SrcText().Contains("if (TokenProblem(Inspect(token)) is { } problem) throw") && SrcText().Contains("if (TokenProblem(InspectProcess(pi.Process)) is { } problem) throw"));
        Check("token facts: the Administrators group must be deny-only and not enabled; absent is fine", RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x10u) }) == null && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-545", 0x7u) }) == null && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x7u) }) != null && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x14u) }) != null && RestrictedLauncher.AdminGroupProblem(new[] { ("S-1-5-32-544", 0x0u) }) != null);
        Check("token facts: only standard-user privileges are accepted", RestrictedLauncher.ExtraPrivileges(new[] { "SeChangeNotifyPrivilege", "SeShutdownPrivilege" }).Count == 0 && RestrictedLauncher.ExtraPrivileges(new[] { "SeChangeNotifyPrivilege", "SeDebugPrivilege", "SeBackupPrivilege" }).SequenceEqual(new[] { "SeDebugPrivilege", "SeBackupPrivilege" }) && RestrictedLauncher.ExtraPrivileges(new[] { "SeIncreaseQuotaPrivilege" }).Count == 1);
        Check("selftest: a process that is not elevated gets NOT RUN (null), which is never a pass; error 1314 is a FAIL in the self test source", (RestrictedLauncher.IsElevated() || LauncherSelfTest.Execute() == null) && SrcText().Contains("e.NativeErrorCode == 1314 ?") && !SrcText().Contains("SKIP launcher"));
        Check("launcher (source): SeIncreaseQuotaPrivilege is switched off again after the start, UI limits are set on the application jobs", SrcText().Contains("EnablePrivilege(\"SeIncreaseQuotaPrivilege\", false)") && SrcText().Contains("JobGroup.ApplicationUiLimits") && JobGroup.ApplicationUiLimits == (0x40u | 0x10u | 0x80u | 0x8u));
        using (var ui = new JobGroup(0, JobGroup.ApplicationUiLimits)) Check("job: the UI limits (no desktop switch, display settings, ExitWindows, system parameters) are set on the job; the clipboard, atoms and handles are not limited because Office and Edge use them", ui.UiLimits == JobGroup.ApplicationUiLimits && (ui.UiLimits & 0x1) == 0 && (ui.UiLimits & 0x20) == 0 && (ui.UiLimits & 0x6) == 0);
        var env = Apps.ChildEnvironment(@"C:\tmp1");
        Check("apps: the child environment is ours with TEMP and TMP in the program's own folder", env["TEMP"] == @"C:\tmp1" && env["TMP"] == @"C:\tmp1" && env.ContainsKey("SystemRoot") == (Environment.GetEnvironmentVariable("SystemRoot") != null));

        var dir = Temp();
        try
        {
            string made = Path.Combine(dir, "user");
            Apps.CreateUserFolder(made);
            var sec = new DirectoryInfo(made).GetAccessControl();
            var rules = sec.GetAccessRules(true, false, typeof(System.Security.Principal.SecurityIdentifier)).Cast<System.Security.AccessControl.FileSystemAccessRule>().ToList();
            string me = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
            var sids = rules.Select(r => r.IdentityReference.Value).Distinct().OrderBy(x => x).ToList();
            var want = new[] { "S-1-5-18", "S-1-5-32-544", me }.Distinct().OrderBy(x => x).ToList();
            Check("user folder: protected, only Administrators, SYSTEM and the user of the process have a rule, none for Everyone or Users", sec.AreAccessRulesProtected && sids.SequenceEqual(want) && rules.All(r => r.AccessControlType == System.Security.AccessControl.AccessControlType.Allow), string.Join(",", sids));
            Check("user folder: the user gets Modify, not full control (no change of permissions)", rules.Where(r => r.IdentityReference.Value == me && me != "S-1-5-18" && me != "S-1-5-32-544").All(r => (r.FileSystemRights & System.Security.AccessControl.FileSystemRights.ChangePermissions) == 0 && (r.FileSystemRights & System.Security.AccessControl.FileSystemRights.Write) != 0));
            Check("user folder: an existing folder is refused (it could have been prepared by someone else)", Throws(() => Apps.CreateUserFolder(made)));

            // work layout (N2): the tool's files in data\\ are read-only for the user of the programs, tmp\\ and prof\\ may be written, nobody else; one atomic call each
            string work = Path.Combine(dir, "work");
            Apps.CreateWorkLayout(work);
            System.Security.AccessControl.FileSystemRights Rights(string p) { var rs = new DirectoryInfo(p).GetAccessControl().GetAccessRules(true, false, typeof(System.Security.Principal.SecurityIdentifier)).Cast<System.Security.AccessControl.FileSystemAccessRule>().Where(r => r.IdentityReference.Value == me && me != "S-1-5-18" && me != "S-1-5-32-544").ToList(); return rs.Count == 0 ? 0 : rs[0].FileSystemRights; }
            bool plainUser = me != "S-1-5-18" && me != "S-1-5-32-544";
            Check("work layout: data\\ and the root are read and execute only for the user, tmp\\ and prof\\ are modify", !plainUser || ((Rights(Apps.DataDir(work)) & System.Security.AccessControl.FileSystemRights.WriteData) == 0 && (Rights(work) & System.Security.AccessControl.FileSystemRights.WriteData) == 0 && (Rights(Apps.DataDir(work)) & System.Security.AccessControl.FileSystemRights.ReadAndExecute) == System.Security.AccessControl.FileSystemRights.ReadAndExecute && (Rights(Apps.TmpDir(work)) & System.Security.AccessControl.FileSystemRights.Write) != 0 && (Rights(Apps.ProfileDir(work)) & System.Security.AccessControl.FileSystemRights.Write) != 0), $"{Rights(work)} {Rights(Apps.DataDir(work))}");
            Check("work layout: each folder is protected (no inheritance), none has a rule for anyone but Administrators, SYSTEM and the user", new[] { work, Apps.DataDir(work), Apps.TmpDir(work), Apps.ProfileDir(work) }.All(p => { var s = new DirectoryInfo(p).GetAccessControl(); return s.AreAccessRulesProtected && s.GetAccessRules(true, false, typeof(System.Security.Principal.SecurityIdentifier)).Cast<System.Security.AccessControl.FileSystemAccessRule>().All(r => want.Contains(r.IdentityReference.Value)); }));
            Check("work layout: a second creation of any of them fails (atomic, no check-then-create)", Throws(() => Apps.CreateWorkLayout(work)) && Throws(() => Apps.CreateUserFolder(Apps.DataDir(work))) && Throws(() => Apps.CreateUserFolder(Apps.TmpDir(work))));
            string occupied = Path.Combine(dir, "occupied"); File.WriteAllText(occupied, "x");
            Check("work layout: a file of that name is also refused", Throws(() => Apps.CreateUserFolder(occupied)));

            // links (N2, N3): found after a run, and removed without following them
            string target = Path.Combine(dir, "target"); Directory.CreateDirectory(target); File.WriteAllText(Path.Combine(target, "keep.txt"), "keep");
            Check("links: a clean work folder has none", FolderTools.FindLink(work) == null);
            string junction = Path.Combine(Apps.TmpDir(work), "j");
            bool madeJunction = MakeJunction(junction, target);
            if (madeJunction)
            {
                Check("links: a junction made inside the work folder is found after the run", FolderTools.FindLink(work) == junction);
                File.WriteAllText(Path.Combine(Apps.ProfileDir(work), "f.txt"), "x");
                var ro = Path.Combine(Apps.TmpDir(work), "ro.txt"); File.WriteAllText(ro, "x"); File.SetAttributes(ro, FileAttributes.ReadOnly);
                Apps.RemoveFolder(work);
                Check("links: removing the work folder deletes the link itself, never the content of its target (no follow)", !Directory.Exists(work) && File.Exists(Path.Combine(target, "keep.txt")) && File.ReadAllText(Path.Combine(target, "keep.txt")) == "keep");
                Check("links: a link as the folder to remove is deleted itself, the target stays", MakeJunction(Path.Combine(dir, "j2"), target) && Wrap(() => Apps.RemoveFolder(Path.Combine(dir, "j2"))) && !Directory.Exists(Path.Combine(dir, "j2")) && File.Exists(Path.Combine(target, "keep.txt")));
            }
            else Console.WriteLine("SKIP links: a junction could not be made here");
            FolderTools.RemoveNoFollow(Path.Combine(dir, "nothing-here"));
            Check("links: removing a path that is not there is fine", true);

            // live launcher checks only count when this process is elevated (the case the restriction protects against); otherwise: NOT RUN, never a pass (N1)
            var live = LauncherSelfTest.Execute(dir);
            if (live == null) { NotRun++; Console.WriteLine("NOT RUN launcher live checks (not elevated): run  AVDTune.Bench.exe selftest-launcher  elevated on the test VM (issue #17); this is not a pass"); }
            else foreach (var x in live) Check("launcher (elevated): " + x.Name, x.Ok, x.Detail);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }

        // memory rules of the load workers
        Check("capacity guard: the job memory limit of a worker is its working set twice plus the runtime, more with the encoder", CapacityGuard.JobMemoryLimitBytes(100, false) == (long)((200 + 300) * 1048576.0) && CapacityGuard.JobMemoryLimitBytes(100, true) == (long)((200 + 300 + 700) * 1048576.0));
        Check("capacity guard: the sum of the working sets stays at 70 percent of the free memory", CapacityGuard.WhyNotStart(0, 100, false, 1000, 100000, 0) == null && CapacityGuard.WhyNotStart(6, 100, false, 1000, 100000, 0) == null && CapacityGuard.WhyNotStart(7, 100, false, 1000, 100000, 0) is { } w && w.Contains("70 percent"));
        Check("capacity guard: the measured working sets count when they are higher than planned", CapacityGuard.WhyNotStart(2, 100, false, 1000, 100000, 650) is { } w2 && w2.Contains("70 percent"));
        Check("capacity guard: not enough free commit stops the start with the reason", CapacityGuard.WhyNotStart(0, 100, false, 100000, 600, 0) is { } w3 && w3.Contains("commit") && CapacityGuard.WhyNotStart(0, 100, false, 100000, 1100, 0) == null);
        using (var limited = new JobGroup(CapacityGuard.JobMemoryLimitBytes(50, false)))
        using (var plain = new JobGroup())
            Check("job: the memory limit is set in the job object (read back), a plain job has none", limited.MemoryLimitBytes() == CapacityGuard.JobMemoryLimitBytes(50, false) && plain.MemoryLimitBytes() == 0);
    }

    private static void CapacityChecks()
    {
        Check("levels: 1, 2, 4, 6, 8, then +4 up to 4 x vCPU", string.Join(",", CapacityMath.LevelSequence(8)) == "1,2,4,6,8,12,16,20,24,28,32" && string.Join(",", CapacityMath.LevelSequence(2)) == "1,2,4,6,8" && string.Join(",", CapacityMath.LevelSequence(1)) == "1,2,4" && string.Join(",", CapacityMath.LevelSequence(8, 3)) == "1,2");
        var lv = new List<(int, double)> { (1, 100), (2, 110), (4, 140), (6, 170), (8, 240) };
        double? e = CapacityMath.Estimate(lv);
        Check("estimate: crossing of 150 percent of level 1, linear (4.67)", e != null && Near(e.Value, 4.0 + (150 - 140) / 30.0 * 2, 1e-9), e.ToString());
        Check("estimate: never reached gives no number", CapacityMath.Estimate(new List<(int, double)> { (1, 100), (2, 110), (4, 120) }) == null);
        Check("estimate: crossing at the first higher level interpolates from level 1", Near(CapacityMath.Estimate(new List<(int, double)> { (1, 100), (2, 200) })!.Value, 1.5, 1e-9));
        Check("estimate: no level 1 gives no number", CapacityMath.Estimate(new List<(int, double)> { (2, 100), (4, 200) }) == null);
        Check("stop rule: passed by two levels", CapacityMath.PassedTwice(new List<(int, double)> { (1, 100), (2, 160), (4, 170) }) && !CapacityMath.PassedTwice(new List<(int, double)> { (1, 100), (2, 110), (4, 170) }) && !CapacityMath.PassedTwice(new List<(int, double)> { (1, 100), (2, 160) }));
        Check("percentile: nearest rank", CapacityMath.Percentile(Enumerable.Range(1, 20).Select(x => (double)x).ToList(), 95) == 19 && CapacityMath.Percentile(new[] { 5.0 }, 95) == 5.0);
        var f = Footprint.FromDeltas(12, 100L << 20, 600, 60L << 20, 120);
        Check("footprint: per minute from the deltas", Near(f.CpuSecPerMin, 6, 1e-9) && f.WorkingSetMB == 100 && Near(f.IoOpsPerMin, 300, 1e-9) && Near(f.IoMBPerMin, 30, 1e-9));
        Check("footprint: CPU duty is a share of one core, never above 1", Near(f.CpuDuty, 0.1, 1e-9) && new Footprint(500, 1, 0, 0).CpuDuty == 1.0 && Throws(() => Footprint.FromDeltas(1, 1, 1, 1, 0)));

        var dir = Temp();
        try
        {
            using (var probe = new Probe(dir, null, 0.01))
            {
                var c = probe.RunCycle(() => false);
                Check("probe: one cycle times six actions (no process start without a path)", Probe.Actions.Where(a => a != "start").All(a => c.TryGetValue(a, out var ms) && ms > 0) && !c.ContainsKey("start"), string.Join(",", c.Keys));
                Check("probe: 200 small files are prepared", Directory.GetFiles(Path.Combine(dir, "src")).Length == 200);
            }
            var w = Options.Parse(new[] { "load", "--user", "2", "--dir", Path.Combine(dir, "u2"), "--quiet", "--cpu-sec-per-min", "6", "--ws-mb", "4", "--io-ops-per-min", "120", "--io-mb-per-min", "1", "--encode", "0", "--load-seconds", "2" });
            double t0 = Timing.Now();
            int rc = LoadWorker.Run(w);
            Check("load worker: runs for its time, writes in its own folder, ends cleanly", rc == 0 && Timing.Now() - t0 >= 1.5 && Timing.Now() - t0 < 8 && Directory.GetFiles(Path.Combine(dir, "u2")).Length > 0);
            Check("load worker: out-of-range values are refused", Throws(() => Options.Parse(new[] { "load", "--ws-mb", "999999" })) && Throws(() => Options.Parse(new[] { "load", "--load-seconds", "0" })));
        }
        finally { Directory.Delete(dir, true); }
        using var sampler = new SystemSampler();
        Thread.Sleep(200);
        double commit = sampler.Sample();
        Check("sampler: CPU and commit are read", sampler.Cpu.Count == 1 && sampler.Cpu[0] >= 0 && sampler.Cpu[0] <= 100 && commit > 0 && commit < 100 && sampler.MinAvailMB > 0, $"{commit}");
        var info = new Dictionary<string, object?> { ["capacity"] = new Dictionary<string, object?> { ["levels"] = new List<object?> { new Dictionary<string, object?> { ["users"] = 1, ["totalMedianMs"] = 12.5 } }, ["estimatedUsers"] = null } };
        using var doc = JsonDocument.Parse(Json.Result("capacity", new Options(), DateTime.UtcNow, 1, Array.Empty<Measure>(), info));
        var cap = doc.RootElement.GetProperty("info").GetProperty("capacity");
        Check("json: nested info (array of objects) is written", cap.GetProperty("levels")[0].GetProperty("users").GetInt32() == 1 && cap.GetProperty("levels")[0].GetProperty("totalMedianMs").GetDouble() == 12.5 && cap.GetProperty("estimatedUsers").ValueKind == JsonValueKind.Null);
    }

    private static void GpuChecks()
    {
        var basic = new Gpu.AdapterInfo(0, "Microsoft Basic Render Driver", 0x1414, 0x8c, 0, 0, "");
        var nv = new Gpu.AdapterInfo(1, "NVIDIA A10-8Q", 0x10DE, 1, 8L << 30, 0, "31.0.15.0");
        var intel = new Gpu.AdapterInfo(2, "Intel UHD", 0x8086, 2, 512L << 20, 0, "");
        var warp = new Gpu.AdapterInfo(3, "WARP", 0x10DE, 3, 16L << 30, 2, "");
        Check("gpu: hardware adapter with the most memory, never the Basic Render Driver", Gpu.Pick(new[] { basic, intel, nv })?.Name == "NVIDIA A10-8Q");
        Check("gpu: only the Basic Render Driver or nothing gives no GPU", Gpu.Pick(new[] { basic }) == null && Gpu.Pick(Array.Empty<Gpu.AdapterInfo>()) == null);
        Check("gpu: a software-flagged adapter is never picked", Gpu.Pick(new[] { basic, warp }) == null);
        Check("gpu: driver version as a.b.c.d", Gpu.DriverText(((long)31 << 48) | ((long)15 << 16) | 5161) == "31.0.15.5161");
        Check("gpu: FMA kernel is 17.18 GFLOP per dispatch", Near(Gpu.FmaFlopsPerDispatch, 17179869184.0, 1));
        var info = Gpu.Info();
        Check("gpu: gpuinfo lists the adapters and says whether there is hardware", info.ContainsKey("hardware") && info.ContainsKey("adapters"));
    }

    private static void ShareChecks()
    {
        var dir = Temp();
        try
        {
            var r = ShareBench.Run(new Options { Dir = dir, DataScale = 0.02, Scale = 0.01 });
            Check("share: metadata and open/close are measured", new[] { "fsl.meta.create", "fsl.meta.stat", "fsl.meta.delete", "fsl.openclose" }.All(id => r.Any(m => m.Id == id && m.Status == "ok" && m.Value > 0)), string.Join(";", r.Select(m => m.Id + ":" + m.Status + m.Reason)));
            Check("share: no storage host skips the round trip", r.First(m => m.Id == "fsl.rtt").Status == "skipped");
            Check("share: the test folder is empty afterwards", Directory.GetFileSystemEntries(dir).Length == 0);
            Check("share: a missing test folder is a failed measure", ShareBench.Run(new Options { Dir = Path.Combine(dir, "nope") })[0].Status == "failed");
        }
        finally { Directory.Delete(dir, true); }
    }

    private static void JobChecks()
    {
        string cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        System.Diagnostics.Process Start()
        {
            var psi = new System.Diagnostics.ProcessStartInfo(cmd) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "/c", "ping", "-n", "30", "127.0.0.1", ">nul" }) psi.ArgumentList.Add(a);
            return System.Diagnostics.Process.Start(psi)!;
        }
        System.Diagnostics.Process p;
        using (var job = new JobGroup())
        {
            p = Start(); job.Assign(p); Thread.Sleep(500);
            Check("job: the process is in the job", job.Pids().Contains(p.Id));
            job.Terminate();
            Check("job: Terminate ends the tree", p.WaitForExit(5000));
        }
        System.Diagnostics.Process q;
        using (var job = new JobGroup()) { q = Start(); job.Assign(q); }
        Check("job: closing the last handle ends the processes (kill on close)", q.WaitForExit(5000));
        Check("windows: an unknown process has no windows", WindowTools.TopLevel(new HashSet<int> { int.MaxValue }).Count == 0);
    }
}
