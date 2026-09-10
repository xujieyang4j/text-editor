using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Navigation;

public sealed record DocumentSymbol(string Path, string Name, string Kind, int Line, int Column)
{
    public string Display => $"{Name} — {Kind} · {Path}:{Line}:{Column}";
}

public static class SymbolExtractor
{
    public const int MaximumSymbols = 5_000;
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromMilliseconds(100);

    public static IReadOnlyList<DocumentSymbol> Extract(string path, string text, string languageId)
    {
        if (text.Length > 2_000_000) return [];
        var symbols = new List<DocumentSymbol>();
        var patterns = Patterns(languageId);
        var lines = TextFileCodec.NormalizeLineEndings(text).Split('\n');
        for (var index = 0; index < lines.Length && symbols.Count < MaximumSymbols; index++)
        {
            foreach (var (kind, pattern) in patterns)
            {
                Match match;
                try { match = pattern.Match(lines[index]); }
                catch (RegexMatchTimeoutException) { continue; }
                if (!match.Success || !match.Groups["name"].Success) continue;
                var name = match.Groups["name"].Value.Trim();
                if (name.Length == 0) continue;
                symbols.Add(new(path, name[..Math.Min(name.Length, 256)], kind, index + 1, match.Groups["name"].Index + 1));
                break;
            }
        }
        return symbols;
    }

    private static IReadOnlyList<(string Kind, Regex Pattern)> Patterns(string languageId)
    {
        Regex Make(string source) => new(source,
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, RegexTimeout);
        if (languageId == "markdown") return [("heading", Make(@"^\s{0,3}#{1,6}\s+(?<name>.+?)\s*#*\s*$"))];
        if (languageId == "python") return [
            ("class", Make(@"^\s*class\s+(?<name>[A-Za-z_]\w*)")),
            ("function", Make(@"^\s*(?:async\s+)?def\s+(?<name>[A-Za-z_]\w*)"))
        ];
        if (languageId == "go") return [
            ("function", Make(@"^\s*func\s+(?:\([^)]*\)\s*)?(?<name>[A-Za-z_]\w*)")),
            ("type", Make(@"^\s*type\s+(?<name>[A-Za-z_]\w*)"))
        ];
        if (languageId == "rust") return [
            ("function", Make(@"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(?<name>[A-Za-z_]\w*)")),
            ("type", Make(@"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait)\s+(?<name>[A-Za-z_]\w*)"))
        ];
        return [
            ("type", Make(@"^\s*(?:(?:public|private|protected|internal|export|default|abstract|sealed|static)\s+)*(?:class|interface|struct|enum|type)\s+(?<name>[A-Za-z_$][\w$]*)")),
            ("function", Make(@"^\s*(?:(?:public|private|protected|internal|export|default|static|async)\s+)*(?:function\s+)?(?<name>[A-Za-z_$][\w$]*)\s*\([^;]*\)\s*(?:\{|=>|:)"))
        ];
    }
}

public sealed class WorkspaceSymbolIndex
{
    public const int MaximumSymbols = 10_000;

    public async Task<IReadOnlyList<DocumentSymbol>> BuildAsync(
        IEnumerable<string> roots, WorkspaceTree tree, CancellationToken cancellationToken = default,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        var symbols = new List<DocumentSymbol>();
        foreach (var path in WorkspaceFileIndex.EnumerateFiles(roots, tree, exclusions))
        {
            cancellationToken.ThrowIfCancellationRequested();
            FileInfo info;
            try { info = new FileInfo(path); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            if (!info.Exists || info.Length > WorkspaceSearchRunner.MaximumFileBytes) continue;
            byte[] bytes;
            try { bytes = await File.ReadAllBytesAsync(path, cancellationToken); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            var encoding = TextFileCodec.DetectEncoding(bytes);
            var utf16 = encoding is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be
                or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom;
            if (TextFileCodec.LooksBinary(bytes, utf16)) continue;
            var decoded = TextFileCodec.DecodeAuto(bytes);
            if (decoded.EncodingIssue == TextEncodingIssue.InvalidBytes) continue;
            symbols.AddRange(SymbolExtractor.Extract(path, decoded.Content, LanguageDetector.Detect(path).Id)
                .Take(MaximumSymbols - symbols.Count));
            if (symbols.Count >= MaximumSymbols) break;
        }
        return symbols;
    }

    public static IReadOnlyList<DocumentSymbol> Search(IEnumerable<DocumentSymbol> symbols, string query) => symbols
        .Select(symbol => (Symbol: symbol, Score: WorkspaceFileIndex.Score(symbol.Name, query.Trim())))
        .Where(result => query.Trim().Length == 0 || result.Score >= 0)
        .OrderByDescending(result => result.Score)
        .ThenBy(result => result.Symbol.Name, StringComparer.OrdinalIgnoreCase)
        .Take(WorkspaceFileIndex.MaximumResults)
        .Select(result => result.Symbol)
        .ToList();
}
