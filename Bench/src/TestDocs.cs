using System.IO.Compression;
using System.Security;
using System.Text;

namespace AVDTune.Bench;

/// <summary>Test documents of the application starts (design 1.1), made by our own code from a fixed seed: a Word document of 20 pages and an Excel workbook of 10 sheets
/// with 50 000 formulas (with their values, so Excel does not recalculate on load and does not ask to save on close). Plain OOXML, no library, nothing downloaded.</summary>
public static class TestDocs
{
    public const int Pages = 20, LinesPerPage = 34, Sheets = 10, RowsPerSheet = 5000;
    private static readonly string[] Words = { "report", "server", "session", "profile", "budget", "meeting", "update", "network", "storage", "desktop", "office", "design", "review", "quarter", "customer", "the", "of", "and", "to", "in" };

    private static void Add(ZipArchive z, string name, string content)
    {
        var e = z.CreateEntry(name, CompressionLevel.Fastest);
        using var s = e.Open();
        var b = new UTF8Encoding(false).GetBytes(content);
        s.Write(b, 0, b.Length);
    }

    private static void Create(string path, Action<ZipArchive> fill)
    {
        // CreateNew: never over a file somebody prepared
        using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        using var z = new ZipArchive(fs, ZipArchiveMode.Create);
        fill(z);
    }

    public static void WriteDocx(string path, int pages = Pages)
    {
        var rng = new Rng(7001);
        Create(path, z =>
        {
            Add(z, "[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>");
            Add(z, "_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>");
            var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>");
            for (int p = 0; p < pages; p++)
            {
                for (int l = 0; l < LinesPerPage; l++)
                {
                    sb.Append("<w:p><w:r><w:t xml:space=\"preserve\">");
                    int words = 12 + rng.Next(14);
                    for (int w = 0; w < words; w++) { if (w > 0) sb.Append(' '); sb.Append(Words[rng.Next(Words.Length)]); }
                    sb.Append("</w:t></w:r></w:p>");
                }
                if (p < pages - 1) sb.Append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>");
            }
            sb.Append("</w:body></w:document>");
            Add(z, "word/document.xml", sb.ToString());
        });
    }

    public static void WriteXlsx(string path, int sheets = Sheets, int rows = RowsPerSheet)
    {
        Create(path, z =>
        {
            var ct = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>");
            var wb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>");
            var rels = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
            for (int s = 1; s <= sheets; s++)
            {
                ct.Append($"<Override PartName=\"/xl/worksheets/sheet{s}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
                wb.Append($"<sheet name=\"Sheet{s}\" sheetId=\"{s}\" r:id=\"rId{s}\"/>");
                rels.Append($"<Relationship Id=\"rId{s}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{s}.xml\"/>");
                var sh = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>");
                for (int r = 1; r <= rows; r++)
                {
                    long a = (r * 7L + s * 13L) % 1000, b = a * 2 + r;
                    sh.Append($"<row r=\"{r}\"><c r=\"A{r}\"><v>{a}</v></c><c r=\"B{r}\"><f>A{r}*2+{r}</f><v>{b}</v></c></row>");
                }
                sh.Append("</sheetData></worksheet>");
                Add(z, $"xl/worksheets/sheet{s}.xml", sh.ToString());
            }
            ct.Append("</Types>");
            wb.Append("</sheets><calcPr calcId=\"191029\"/></workbook>");
            rels.Append("</Relationships>");
            Add(z, "[Content_Types].xml", ct.ToString());
            Add(z, "_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
            Add(z, "xl/workbook.xml", wb.ToString());
            Add(z, "xl/_rels/workbook.xml.rels", rels.ToString());
        });
    }

    /// <summary>The folder of 500 small files for the File Explorer start. Returns its path.</summary>
    public static string WriteFolder500(string parent, string name, int files = 500)
    {
        if (name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) throw new ArgumentException("bad folder name");
        var dir = Path.Combine(parent, name);
        Directory.CreateDirectory(dir);
        var rng = new Rng(7003);
        for (int i = 0; i < files; i++)
        {
            using var fs = new FileStream(Path.Combine(dir, $"file{i:D3}.txt"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var b = Encoding.ASCII.GetBytes($"AVDTune benchmark file {i} {rng.NextU32()}\r\n");
            fs.Write(b, 0, b.Length);
        }
        return dir;
    }

    public static string XmlEscape(string s) => SecurityElement.Escape(s) ?? "";
}
