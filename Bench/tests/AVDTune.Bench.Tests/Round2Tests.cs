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
        Docs(); Site(); AppRules(); SpeedometerParsing(); CapacityChecks(); GpuChecks(); ShareChecks(); JobChecks();
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
            Check("server: the start page calls back to /ready", Raw(server.Port, $"GET /start.html HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n").Contains("/ready") && !server.ReadyCalled);
            Raw(server.Port, $"GET /ready HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n");
            Check("server: /ready is noticed", server.WaitReady(2000));
            string wrong = Raw(server.Port, "GET /index.html HTTP/1.1\r\nHost: attacker.example\r\n\r\n");
            Check("server: a wrong Host gets 421, no content", wrong.StartsWith("HTTP/1.1 421") && !wrong.Contains("idx"));
            Check("server: a traversal request gets 404", Raw(server.Port, $"GET /../x.txt HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n").StartsWith("HTTP/1.1 404"));
            Check("server: POST gets 405", Raw(server.Port, $"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\n\r\n").StartsWith("HTTP/1.1 405"));
            Check("server: refused requests are counted", server.RefusedCount >= 3, server.RefusedCount.ToString());
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
        Check("devtools: first line of DevToolsActivePort is the port", Speedometer.ParseActivePort("9222\n/devtools/browser/abc") == 9222 && Throws(() => Speedometer.ParseActivePort("0\nx")) && Throws(() => Speedometer.ParseActivePort("abc")) && Throws(() => Speedometer.ParseActivePort("70000")));
        string json = "[{\"type\":\"page\",\"url\":\"http://127.0.0.1:8000/index.html?x\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/page/AB12\"},{\"type\":\"service_worker\",\"url\":\"http://127.0.0.1:8000/x\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/page/CD\"}]";
        Check("devtools: the page of our origin is picked", Speedometer.PickPageSocket(json, "http://127.0.0.1:8000", 9222) == "ws://127.0.0.1:9222/devtools/page/AB12");
        Check("devtools: another origin, port or host in the socket address is refused", Speedometer.PickPageSocket(json, "http://127.0.0.1:9000", 9222) == null && Speedometer.PickPageSocket(json, "http://127.0.0.1:8000", 9223) == null && Speedometer.PickPageSocket(json.Replace("ws://127.0.0.1", "ws://evil.example"), "http://127.0.0.1:8000", 9222) == null);
        Check("devtools: an evaluate answer is matched by id", Speedometer.ParseEvaluate("{\"id\":3,\"result\":{\"result\":{\"type\":\"string\",\"value\":\"#summary\"}}}", 3) == "#summary" && Speedometer.ParseEvaluate("{\"id\":2,\"result\":{}}", 3) == null && Speedometer.ParseEvaluate("{\"method\":\"event\"}", 3) == null);
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
