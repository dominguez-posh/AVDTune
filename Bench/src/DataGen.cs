using System.Globalization;
using System.Text;

namespace AVDTune.Bench;

/// <summary>Test data, all generated from a fixed seed in memory (design 1.1).</summary>
public static class DataGen
{
    private static readonly string[] Words =
    {
        "the","of","and","to","in","is","that","for","it","as","was","with","be","by","on","not","he","this","are","or",
        "his","from","at","which","but","have","an","had","they","you","were","their","one","all","we","can","her","has",
        "there","been","if","more","when","will","would","who","so","no","report","server","session","profile","user",
        "document","budget","meeting","update","network","storage","desktop","office","design","review","quarter","customer"
    };

    /// <summary>Text-like corpus (ASCII), exactly <paramref name="bytes"/> long.</summary>
    public static byte[] TextCorpus(ulong seed, int bytes)
    {
        var rng = new Rng(seed);
        var buf = new byte[bytes];
        int pos = 0, lineLen = 0;
        while (pos < bytes)
        {
            var w = Words[rng.Next(Words.Length)];
            for (int i = 0; i < w.Length && pos < bytes; i++) buf[pos++] = (byte)w[i];
            if (pos >= bytes) break;
            lineLen += w.Length + 1;
            uint r = rng.NextU32();
            if (lineLen > 60 + (int)(r % 20)) { buf[pos++] = (byte)'\n'; lineLen = 0; }
            else if ((r & 0xF00) == 0) { buf[pos++] = (byte)','; if (pos < bytes) buf[pos++] = (byte)' '; }
            else buf[pos++] = (byte)' ';
        }
        return buf;
    }

    /// <summary>JSON document (UTF-8), an array of objects, about <paramref name="bytes"/> long.</summary>
    public static byte[] JsonDocument(ulong seed, int bytes)
    {
        var rng = new Rng(seed);
        var sb = new StringBuilder(bytes + 1024);
        sb.Append('[');
        int id = 0;
        while (sb.Length < bytes - 600)
        {
            if (id > 0) sb.Append(',');
            sb.Append("{\"id\":").Append(id++)
              .Append(",\"name\":\"").Append(Words[rng.Next(Words.Length)]).Append('-').Append(Words[rng.Next(Words.Length)]).Append("\",\"tags\":[");
            int tags = 1 + rng.Next(4);
            for (int t = 0; t < tags; t++) { if (t > 0) sb.Append(','); sb.Append('"').Append(Words[rng.Next(Words.Length)]).Append('"'); }
            sb.Append("],\"score\":").Append((rng.NextU32() % 100000 / 100.0).ToString("0.00", CultureInfo.InvariantCulture))
              .Append(",\"active\":").Append((rng.NextU32() & 1) == 0 ? "true" : "false")
              .Append(",\"nested\":{\"a\":").Append(rng.Next(1000000)).Append(",\"b\":\"").Append(Words[rng.Next(Words.Length)]).Append(' ').Append(Words[rng.Next(Words.Length)]).Append("\",\"c\":[")
              .Append(rng.Next(100)).Append(',').Append(rng.Next(100)).Append(',').Append(rng.Next(100)).Append("]}}");
        }
        sb.Append(']');
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    private static readonly string[] Levels = { "INFO", "INFO", "INFO", "DEBUG", "WARN", "ERROR" };
    private static readonly string[] Components = { "auth", "profile", "storage", "net", "render", "sync", "policy" };

    /// <summary>Log lines, about <paramref name="chars"/> characters long.</summary>
    public static string LogLines(ulong seed, int chars)
    {
        var rng = new Rng(seed);
        var sb = new StringBuilder(chars + 256);
        int n = 0;
        var inv = CultureInfo.InvariantCulture;
        while (sb.Length < chars)
        {
            sb.Append("2026-11-").Append((1 + n % 28).ToString("00", inv)).Append('T').Append((n % 24).ToString("00", inv)).Append(':').Append(rng.Next(60).ToString("00", inv)).Append(':').Append(rng.Next(60).ToString("00", inv)).Append('.').Append(rng.Next(1000).ToString("000", inv)).Append("Z ")
              .Append(Levels[rng.Next(Levels.Length)]).Append("  [").Append(Components[rng.Next(Components.Length)]).Append("] user=").Append(rng.Next(100000))
              .Append(" session=").Append(rng.Next(5000)).Append(' ');
            int words = 4 + rng.Next(8);
            for (int i = 0; i < words; i++) { sb.Append(Words[rng.Next(Words.Length)]); sb.Append(i + 1 < words ? ' ' : '\n'); }
            n++;
        }
        return sb.ToString();
    }

    /// <summary>Random strings, length 8 to 24, base-36 characters.</summary>
    public static string[] Strings(ulong seed, int count)
    {
        var rng = new Rng(seed);
        var result = new string[count];
        const string alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
        Span<char> tmp = stackalloc char[24];
        for (int i = 0; i < count; i++)
        {
            int len = 8 + rng.Next(17);
            for (int c = 0; c < len; c++) tmp[c] = alphabet[rng.Next(36)];
            result[i] = new string(tmp.Slice(0, len));
        }
        return result;
    }
}
