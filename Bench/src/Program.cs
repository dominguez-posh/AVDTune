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
  info    system facts (CPU model, cores, RAM)
  all     cpu + mem + disp
Options:
  --scale <f>       scale every duration (default 1; quick and warm-up runs use less)
  --data-scale <f>  scale data sizes (default 1; for tests)
  --threads <n>     threads for the multi-thread measures (default: logical processors)
  --sustained       also run the 60 s sustained CPU measure
  --quiet           no progress on stderr
Result: one JSON document on stdout, progress on stderr. Exit code 0 when it ran, 2 on a usage error, 1 on an error.";

    public static int Main(string[] args)
    {
        Options o;
        try { o = Options.Parse(args); }
        catch (Exception e) { Console.Error.WriteLine(e.Message); Console.Error.WriteLine(Usage); return 2; }
        if (o.Command is "" or "help") { Console.Out.WriteLine(Usage); return o.Command == "help" ? 0 : 2; }
        Log.Quiet = o.Quiet;
        Console.OutputEncoding = new UTF8Encoding(false);
        var started = DateTime.UtcNow;
        double t0 = Timing.Now();
        try
        {
            var measures = new List<Measure>();
            switch (o.Command)
            {
                case "cpu": measures.AddRange(Cpu.Run(o)); break;
                case "mem": measures.AddRange(MemoryBench.Run(o)); break;
                case "disp": measures.AddRange(Display.Run(o)); break;
                case "all": measures.AddRange(Cpu.Run(o)); measures.AddRange(MemoryBench.Run(o)); measures.AddRange(Display.Run(o)); break;
                case "info": break;
                default: Console.Error.WriteLine($"Unknown command '{o.Command}'."); Console.Error.WriteLine(Usage); return 2;
            }
            Console.Out.WriteLine(Json.Result(o.Command, o, started, Timing.Now() - t0, measures));
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("error: " + e.Message);
            return 1;
        }
    }
}
