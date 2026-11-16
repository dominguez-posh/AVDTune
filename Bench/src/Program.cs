using System.Text;

namespace AVDTune.Bench;

public static class Program
{
    public const string ToolVersion = "1.0.0";
    public const string BenchmarkVersion = "B1.0";

    private const string Usage = @"AVDTune.Bench - measure program of AVDTune (benchmark " + BenchmarkVersion + @")
Usage: AVDTune.Bench <command> [options]
Commands:
  cpu     CPU mix single/multi thread, sustained (with --sustained), AES, SHA
  mem     memory bandwidth, latency, allocation
  disp    remote display: software H.264 (two clips), WARP 3D, WARP 2D
  files   small-file test (create, read, delete 5000 files) in --dir, through the normal Windows cache
  apps    application starts cold and warm (Word, Excel, Edge, File Explorer, PowerShell) and Speedometer; --dir, --app key=path (paths checked by AVDTune), --site, --no-cold
  share   FSLogix share: open/close, round trip (--host), metadata in --dir (the test folder on the share)
  gpu     GPU: 3D scene 1080p/2160p, DirectCompute; gpuinfo lists the adapters
  capacity  capacity simulation (about 30 min): probe plus load workers per level; --dir, --max-users, --app powershell=path
  selftest-launcher  proves the restricted launcher on this machine; run ELEVATED (exit 0 pass, 1 fail, 3 not run); optional --dir
  load    one load worker of the capacity simulation (started by capacity only)
  info    system facts (CPU model, cores, RAM)
  all     cpu + mem + disp
Options:
  --scale <f>       scale every duration (default 1; quick and warm-up runs use less)
  --data-scale <f>  scale data sizes (default 1; for tests)
  --threads <n>     threads for the multi-thread measures (default: logical processors)
  --sustained       also run the 60 s sustained CPU measure
  --dir <folder>    work folder for files (must exist; own sub folder is made and removed)
  --quiet           no progress on stderr
Result: one JSON document on stdout, progress on stderr. Exit code 0 when it ran, 2 on a usage error, 1 on an error.";

    public static int Main(string[] args)
    {
        Options o;
        try { o = Options.Parse(args); }
        catch (Exception e) { Console.Error.WriteLine(e.Message); Console.Error.WriteLine(Usage); return 2; }
        if (o.Command == "selftest-launcher") { Console.OutputEncoding = new UTF8Encoding(false); return LauncherSelfTest.Run(o); }
        if (o.Command is "" or "help") { Console.Out.WriteLine(Usage); return o.Command == "help" ? 0 : 2; }
        Log.Quiet = o.Quiet;
        Console.OutputEncoding = new UTF8Encoding(false);
        var started = DateTime.UtcNow;
        double t0 = Timing.Now();
        try
        {
            var measures = new List<Measure>();
            Dictionary<string, object?>? extra = null;
            switch (o.Command)
            {
                case "cpu": measures.AddRange(Cpu.Run(o)); break;
                case "mem": measures.AddRange(MemoryBench.Run(o)); break;
                case "disp": measures.AddRange(Display.Run(o)); break;
                case "all": measures.AddRange(Cpu.Run(o)); measures.AddRange(MemoryBench.Run(o)); measures.AddRange(Display.Run(o)); break;
                case "files": measures.AddRange(FilesBench.Run(o)); break;
                case "apps": measures.AddRange(Apps.Run(o)); break;
                case "share": measures.AddRange(ShareBench.Run(o)); break;
                case "gpu": measures.AddRange(Gpu.Run(o)); break;
                case "gpuinfo": extra = Gpu.Info(); break;
                case "capacity": measures.AddRange(Capacity.Run(o, out var capInfo)); extra = capInfo; break;
                case "load": return LoadWorker.Run(o);
                case "info": break;
                default: Console.Error.WriteLine($"Unknown command '{o.Command}'."); Console.Error.WriteLine(Usage); return 2;
            }
            Console.Out.WriteLine(Json.Result(o.Command, o, started, Timing.Now() - t0, measures, extra));
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("error: " + e.Message);
            return 1;
        }
    }
}
