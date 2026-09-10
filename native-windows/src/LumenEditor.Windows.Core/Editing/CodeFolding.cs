namespace LumenEditor.Windows.Core.Editing;

public sealed record FoldRegion(int StartLine, int EndLine, TextSelection FullRange, TextSelection HiddenRange)
{
    public string Id => $"{FullRange.Start}:{FullRange.Length}:{HiddenRange.Start}:{HiddenRange.Length}";
    public bool Contains(int offset) => offset >= FullRange.Start && offset < FullRange.End;
}

public static class CodeFoldAnalyzer
{
    public const int MaximumSourceLength = 2 * 1024 * 1024;
    public const int MaximumRegions = 10_000;
    public const int MaximumNestingDepth = 256;

    private sealed record Line(int Number, int Start, int ContentEnd, int End, string Text, int Indent, bool Blank);
    private sealed record OpenBracket(char Character, int Line);

    public static IReadOnlyList<FoldRegion> Analyze(string text, string languageId)
    {
        if (String.IsNullOrEmpty(text) || text.Length > MaximumSourceLength) return [];
        var lines = Lines(text);
        var normalized = languageId.Trim().ToLowerInvariant();
        IEnumerable<FoldRegion> candidates = normalized is "markdown"
            ? Markdown(lines)
            : Braces(lines).Concat(UsesIndentation(normalized) ? Indentation(lines) : []);
        return candidates.DistinctBy(region => region.Id)
            .OrderBy(region => region.FullRange.Start).ThenByDescending(region => region.FullRange.Length)
            .Take(MaximumRegions).ToList();
    }

    private static IReadOnlyList<Line> Lines(string text)
    {
        var result = new List<Line>();
        var start = 0;
        var number = 1;
        for (var offset = 0; offset <= text.Length; offset++)
        {
            if (offset < text.Length && text[offset] != '\n') continue;
            var contentEnd = offset > start && text[offset - 1] == '\r' ? offset - 1 : offset;
            var content = text[start..contentEnd];
            var indent = 0;
            foreach (var character in content)
            {
                if (character == ' ') indent++;
                else if (character == '\t') indent += 4;
                else break;
            }
            result.Add(new Line(number++, start, contentEnd, Math.Min(text.Length, offset + 1),
                content, indent, String.IsNullOrWhiteSpace(content)));
            start = offset + 1;
        }
        return result;
    }

    private static IEnumerable<FoldRegion> Braces(IReadOnlyList<Line> lines)
    {
        var stack = new Stack<OpenBracket>();
        var inBlockComment = false;
        char quote = '\0';
        var escaped = false;
        foreach (var line in lines)
        {
            for (var index = 0; index < line.Text.Length; index++)
            {
                var value = line.Text[index];
                var next = index + 1 < line.Text.Length ? line.Text[index + 1] : '\0';
                if (inBlockComment)
                {
                    if (value == '*' && next == '/') { inBlockComment = false; index++; }
                    continue;
                }
                if (quote != '\0')
                {
                    if (escaped) escaped = false;
                    else if (value == '\\') escaped = true;
                    else if (value == quote) quote = '\0';
                    continue;
                }
                if (value == '/' && next == '/') break;
                if (value == '/' && next == '*') { inBlockComment = true; index++; continue; }
                if (value == '"' || value == '\'') { quote = value; continue; }
                if (value is '{' or '[' or '(')
                {
                    if (stack.Count < MaximumNestingDepth) stack.Push(new OpenBracket(value, line.Number - 1));
                    continue;
                }
                var opening = value switch { '}' => '{', ']' => '[', ')' => '(', _ => '\0' };
                if (opening == '\0' || stack.Count == 0 || stack.Peek().Character != opening) continue;
                var entry = stack.Pop();
                if (line.Number - 1 > entry.Line && Region(lines, entry.Line, line.Number - 1) is { } region)
                {
                    yield return region;
                }
            }
            quote = '\0';
            escaped = false;
        }
    }

    private static IEnumerable<FoldRegion> Indentation(IReadOnlyList<Line> lines)
    {
        var stack = new Stack<int>();
        int? previous = null;
        foreach (var index in Enumerable.Range(0, lines.Count).Where(index => !lines[index].Blank))
        {
            while (stack.TryPeek(out var opening) && lines[index].Indent <= lines[opening].Indent)
            {
                stack.Pop();
                if (previous is { } end && Region(lines, opening, end) is { } region) yield return region;
            }
            if (previous is { } candidate && lines[index].Indent > lines[candidate].Indent
                && stack.Count < MaximumNestingDepth) stack.Push(candidate);
            previous = index;
        }
        if (previous is { } last) while (stack.TryPop(out var opening))
        {
            if (Region(lines, opening, last) is { } region) yield return region;
        }
    }

    private static IEnumerable<FoldRegion> Markdown(IReadOnlyList<Line> lines)
    {
        var headings = new List<(int Level, int Line)>();
        for (var index = 0; index < lines.Count; index++)
        {
            var trimmed = lines[index].Text.TrimStart();
            var level = trimmed.TakeWhile(character => character == '#').Count();
            if (level is >= 1 and <= 6 && trimmed.Length > level && Char.IsWhiteSpace(trimmed[level]))
            {
                headings.Add((level, index));
            }
        }
        for (var index = 0; index < headings.Count; index++)
        {
            var start = headings[index];
            var end = lines.Count - 1;
            for (var next = index + 1; next < headings.Count; next++)
            {
                if (headings[next].Level <= start.Level) { end = headings[next].Line - 1; break; }
            }
            while (end > start.Line && lines[end].Blank) end--;
            if (Region(lines, start.Line, end) is { } region) yield return region;
        }
    }

    private static FoldRegion? Region(IReadOnlyList<Line> lines, int start, int end)
    {
        if (start < 0 || end <= start || end >= lines.Count) return null;
        var hiddenStart = lines[start].End;
        var fullEnd = lines[end].End;
        return hiddenStart < fullEnd
            ? new FoldRegion(lines[start].Number, lines[end].Number,
                new TextSelection(lines[start].Start, fullEnd), new TextSelection(hiddenStart, fullEnd))
            : null;
    }

    private static bool UsesIndentation(string language) =>
        language is "python" or "yaml" or "sass" or "nim" or "haskell" or "coffee" or "stylus";
}

public sealed class CodeFoldingState
{
    private IReadOnlyList<FoldRegion> regions = [];
    private readonly HashSet<string> foldedIds = new(StringComparer.Ordinal);
    public IReadOnlyList<FoldRegion> Regions => regions;
    public IReadOnlyList<FoldRegion> FoldedRegions => regions.Where(region => foldedIds.Contains(region.Id)).ToList();
    public bool IsFolded(FoldRegion region) => foldedIds.Contains(region.Id);
    public IReadOnlyList<TextSelection> HiddenRanges
    {
        get
        {
            var result = new List<TextSelection>();
            foreach (var region in FoldedRegions.OrderBy(region => region.HiddenRange.Start)
                .ThenByDescending(region => region.HiddenRange.Length))
            {
                if (result.Count > 0 && region.HiddenRange.End <= result[^1].End) continue;
                result.Add(region.HiddenRange);
            }
            return result;
        }
    }

    public void Update(IEnumerable<FoldRegion> next)
    {
        regions = next.Take(CodeFoldAnalyzer.MaximumRegions).ToList();
        foldedIds.IntersectWith(regions.Select(region => region.Id));
    }

    public bool FoldCurrent(int offset)
    {
        var region = regions.Where(region => region.Contains(offset) && !foldedIds.Contains(region.Id))
            .OrderBy(region => region.FullRange.Length).FirstOrDefault();
        return region is not null && foldedIds.Add(region.Id);
    }

    public bool UnfoldCurrent(int offset)
    {
        var region = FoldedRegions.Where(region => region.Contains(offset))
            .OrderBy(region => region.FullRange.Length).FirstOrDefault();
        return region is not null && foldedIds.Remove(region.Id);
    }

    public bool FoldAll()
    {
        var before = foldedIds.Count;
        foreach (var region in regions) foldedIds.Add(region.Id);
        return foldedIds.Count != before;
    }

    public bool UnfoldAll()
    {
        if (foldedIds.Count == 0) return false;
        foldedIds.Clear();
        return true;
    }

    public bool ToggleAtStartLine(int line)
    {
        var region = regions.Where(candidate => candidate.StartLine == line)
            .OrderBy(candidate => candidate.FullRange.Length).FirstOrDefault();
        if (region is null) return false;
        return foldedIds.Contains(region.Id) ? foldedIds.Remove(region.Id) : foldedIds.Add(region.Id);
    }
}
