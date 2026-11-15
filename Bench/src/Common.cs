using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace AVDTune.Bench;

public sealed class Measure
{
    public string Id = "";
    public string Unit = "";
    public bool HigherIsBetter = true;
    public double? Value;
    public string Status = "ok";          // ok | skipped | unsupported | failed
    public string? Reason;
    public Dictionary<string, object?> Detail = new();

    public static Measure Ok(string id, string unit, bool higher, double value) => new() { Id = id, Unit = unit, HigherIsBetter = higher, Value = value };
    public static Measure Not(string id, string unit, bool higher, string status, string reason) => new() { Id = id, Unit = unit, HigherIsBetter = higher, Status = status, Reason = reason };
}

public sealed class Options
{
    public string Command = "";
    /// <summary>Scales every duration (quick mode, warm-up run, tests). 1 = design values.</summary>
    public double Scale = 1.0;
    /// <summary>Scales data sizes (tests). 1 = design values.</summary>
    public double DataScale = 1.0;
    public int Threads = Environment.ProcessorCount;
    public bool Sustained;
    public bool Quiet;
    /// <summary>Work folder for the file measure (an existing folder; the program creates and removes its own sub folder).</summary>
    public string? Dir;
    /// <summary>Programs of the application starts: key (word, excel, edge, explorer, powershell) to the full path AVDTune checked (Authenticode) and holds open. Validated by Apps.ValidateExe.</summary>
    public Dictionary<string, string> AppPaths = new(StringComparer.Ordinal);
    public bool NoCold, NoSpeedometer, Encode;
    /// <summary>Folder of the local Speedometer copy (below the release of AVDTune).</summary>
    public string? Site;
    public int SpeedIterations = 2;
    /// <summary>Storage host of the FSLogix share (TCP 445 round trip).</summary>
    public string? HostName;
    public int? MaxUsers;
    public int UserIndex = 1;
    public double CpuSecPerMin, WorkingSetMB = 64, IoOpsPerMin, IoMBPerMin, LoadSeconds = 120;

    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{a} needs a value.");
            switch (a)
            {
                case "--scale": o.Scale = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--data-scale": o.DataScale = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--threads": o.Threads = int.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--sustained": o.Sustained = true; break;
                case "--quiet": o.Quiet = true; break;
                case "--dir": o.Dir = Next(); break;
                case "--app":
                    {
                        var kv = Next(); int eq = kv.IndexOf('=');
                        if (eq <= 0 || !Apps.Keys.Contains(kv.Substring(0, eq))) throw new ArgumentException("--app needs key=path with a known key.");
                        o.AppPaths[kv.Substring(0, eq)] = kv.Substring(eq + 1); break;
                    }
                case "--no-cold": o.NoCold = true; break;
                case "--no-speedometer": o.NoSpeedometer = true; break;
                case "--site": o.Site = Next(); break;
                case "--speed-iterations": o.SpeedIterations = int.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--host":
                    o.HostName = Next();
                    if (!System.Text.RegularExpressions.Regex.IsMatch(o.HostName, "^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1))) throw new ArgumentException("--host is not a host name.");
                    break;
                case "--max-users": o.MaxUsers = int.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--user": o.UserIndex = int.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--cpu-sec-per-min": o.CpuSecPerMin = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--ws-mb": o.WorkingSetMB = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--io-ops-per-min": o.IoOpsPerMin = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--io-mb-per-min": o.IoMBPerMin = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--encode": o.Encode = Next() == "1"; break;
                case "--load-seconds": o.LoadSeconds = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                default:
                    if (a.StartsWith("--")) throw new ArgumentException($"Unknown option {a}.");
                    if (o.Command != "") throw new ArgumentException($"Unexpected argument {a}.");
                    o.Command = a; break;
            }
        }
        if (o.Scale <= 0 || o.Scale > 10) throw new ArgumentException("--scale must be above 0 and at most 10.");
        if (o.DataScale <= 0 || o.DataScale > 4) throw new ArgumentException("--data-scale must be above 0 and at most 4.");
        if (o.Threads < 1 || o.Threads > 1024) throw new ArgumentException("--threads must be 1 to 1024.");
        if (o.SpeedIterations < 1 || o.SpeedIterations > 10) throw new ArgumentException("--speed-iterations must be 1 to 10.");
        if (o.MaxUsers is < 1 or > 512) throw new ArgumentException("--max-users must be 1 to 512.");
        if (o.UserIndex < 1 || o.UserIndex > 512) throw new ArgumentException("--user must be 1 to 512.");
        if (o.LoadSeconds < 1 || o.LoadSeconds > 7200 || o.CpuSecPerMin < 0 || o.CpuSecPerMin > 6000 || o.WorkingSetMB < 1 || o.WorkingSetMB > 4096 || o.IoOpsPerMin < 0 || o.IoOpsPerMin > 600000 || o.IoMBPerMin < 0) throw new ArgumentException("a load value is out of range.");
        return o;
    }

    public int Size(int designValue) => Math.Max(1024, (int)(designValue * DataScale));
    public double Seconds(double designValue) => Math.Max(0.05, designValue * Scale);
}

public static class Log
{
    public static bool Quiet;
    public static void Progress(string text) { if (!Quiet) Console.Error.WriteLine(text); }
}

public static class SystemInfo
{
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint length);

    public static (double TotalGiB, double AvailableGiB) Memory()
    {
        var m = new MemoryStatusEx { dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        if (!GlobalMemoryStatusEx(ref m)) return (0, 0);
        return (m.ullTotalPhys / 1073741824.0, m.ullAvailPhys / 1073741824.0);
    }

    /// <summary>Physical cores (RelationProcessorCore); falls back to logical processors / 2 rounded up on failure.</summary>
    public static int PhysicalCores()
    {
        try
        {
            uint len = 0;
            GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref len);   // RelationProcessorCore = 0
            if (len == 0) return Environment.ProcessorCount;
            IntPtr buf = Marshal.AllocHGlobal((int)len);
            try
            {
                if (!GetLogicalProcessorInformationEx(0, buf, ref len)) return Environment.ProcessorCount;
                int count = 0; uint offset = 0;
                while (offset < len)
                {
                    uint size = (uint)Marshal.ReadInt32(buf, (int)offset + 4);   // SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX.Size
                    if (size == 0) break;
                    count++; offset += size;
                }
                return Math.Max(1, count);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        catch { return Environment.ProcessorCount; }
    }

    public static string CpuModel()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
            var name = key?.GetValue("ProcessorNameString") as string;
            if (!string.IsNullOrWhiteSpace(name)) return System.Text.RegularExpressions.Regex.Replace(name.Trim(), @"\s+", " ");
        }
        catch { }
        return "unknown";
    }
}

public static class Json
{
    /// <summary>Writes the result of one command (design 5: JSON on stdout).</summary>
    public static string Result(string command, Options o, DateTime startedUtc, double durationSec, IEnumerable<Measure> measures, Dictionary<string, object?>? info = null)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteNumber("schemaVersion", 1);
            w.WriteString("tool", "AVDTune.Bench");
            w.WriteString("toolVersion", Program.ToolVersion);
            w.WriteString("benchmarkVersion", Program.BenchmarkVersion);
            w.WriteString("command", command);
            w.WriteString("startedUtc", startedUtc.ToString("o", System.Globalization.CultureInfo.InvariantCulture));
            w.WriteNumber("durationSec", Math.Round(durationSec, 2));
            w.WriteNumber("scale", o.Scale);
            w.WriteNumber("dataScale", o.DataScale);
            w.WriteStartObject("system");
            w.WriteString("cpuModel", SystemInfo.CpuModel());
            w.WriteNumber("logicalProcessors", Environment.ProcessorCount);
            w.WriteNumber("physicalCores", SystemInfo.PhysicalCores());
            w.WriteNumber("ramGiB", Math.Round(SystemInfo.Memory().TotalGiB, 2));
            w.WriteString("os", Environment.OSVersion.VersionString);
            w.WriteEndObject();
            w.WriteStartArray("measures");
            foreach (var m in measures)
            {
                w.WriteStartObject();
                w.WriteString("id", m.Id);
                w.WriteString("unit", m.Unit);
                w.WriteString("better", m.HigherIsBetter ? "higher" : "lower");
                if (m.Value.HasValue && double.IsFinite(m.Value.Value)) w.WriteNumber("value", m.Value.Value); else w.WriteNull("value");
                w.WriteString("status", m.Status);
                if (m.Reason != null) w.WriteString("reason", m.Reason);
                if (m.Detail.Count > 0)
                {
                    w.WriteStartObject("detail");
                    foreach (var kv in m.Detail) WriteValue(w, kv.Key, kv.Value);
                    w.WriteEndObject();
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();
            if (info != null)
            {
                w.WriteStartObject("info");
                foreach (var kv in info) WriteValue(w, kv.Key, kv.Value);
                w.WriteEndObject();
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private static void WriteItem(Utf8JsonWriter w, object? v)
    {
        switch (v)
        {
            case null: w.WriteNullValue(); break;
            case string s: w.WriteStringValue(s); break;
            case bool b: w.WriteBooleanValue(b); break;
            case int i: w.WriteNumberValue(i); break;
            case long l: w.WriteNumberValue(l); break;
            case double d: if (double.IsFinite(d)) w.WriteNumberValue(d); else w.WriteNullValue(); break;
            case System.Collections.Generic.IDictionary<string, object?> dict:
                w.WriteStartObject();
                foreach (var kv in dict) WriteValue(w, kv.Key, kv.Value);
                w.WriteEndObject(); break;
            case System.Collections.IEnumerable list:
                w.WriteStartArray();
                foreach (var item in list) WriteItem(w, item);
                w.WriteEndArray(); break;
            default: w.WriteStringValue(Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture)); break;
        }
    }

    private static void WriteValue(Utf8JsonWriter w, string name, object? v)
    {
        switch (v)
        {
            case null: w.WriteNull(name); break;
            case string s: w.WriteString(name, s); break;
            case bool b: w.WriteBoolean(name, b); break;
            case int i: w.WriteNumber(name, i); break;
            case long l: w.WriteNumber(name, l); break;
            case double d: if (double.IsFinite(d)) w.WriteNumber(name, d); else w.WriteNull(name); break;
            case System.Collections.Generic.IDictionary<string, object?> dict:
                w.WriteStartObject(name);
                foreach (var kv in dict) WriteValue(w, kv.Key, kv.Value);
                w.WriteEndObject(); break;
            case System.Collections.IEnumerable list:
                w.WriteStartArray(name);
                foreach (var item in list) WriteItem(w, item);
                w.WriteEndArray(); break;
            default: w.WriteString(name, Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture)); break;
        }
    }
}

public static class Timing
{
    public static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}
