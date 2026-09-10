namespace LumenEditor.Windows.Core.Editing;

public sealed record IndexedLine(int Number, int StartOffset);
public sealed record IndexedWhitespace(int Offset, bool IsTab);
public sealed record MinimapLine(int Number, int IndentColumns, int VisibleColumns);
public sealed record IndexedLineDetail(
    int Number, int StartOffset, int ContentEndOffset, int EndOffset,
    int IndentColumns, int TrailingWhitespaceStart);

/// <summary>
/// Maps UTF-16 offsets to logical lines without retaining one integer per line.
/// Only every 256th line is indexed; any lookup scans at most one block.
/// </summary>
public sealed class SparseLineIndex
{
    public const int LinesPerAnchor = 256;
    private readonly string text;
    private readonly List<int> anchors = [0];

    public SparseLineIndex(string text)
    {
        this.text = text ?? throw new ArgumentNullException(nameof(text));
        var line = 0;
        for (var offset = 0; offset < text.Length; offset++)
        {
            if (text[offset] != '\n') continue;
            line++;
            if (line % LinesPerAnchor == 0) anchors.Add(offset + 1);
        }
        LineCount = line + 1;
    }

    public int LineCount { get; }

    public int LineAtOffset(int offset)
    {
        offset = Math.Clamp(offset, 0, text.Length);
        var low = 0;
        var high = anchors.Count - 1;
        while (low < high)
        {
            var middle = (low + high + 1) / 2;
            if (anchors[middle] <= offset) low = middle;
            else high = middle - 1;
        }
        var line = low * LinesPerAnchor;
        for (var index = anchors[low]; index < offset; index++)
        {
            if (text[index] == '\n') line++;
        }
        return Math.Min(line, LineCount - 1);
    }

    public int StartOffset(int zeroBasedLine)
    {
        zeroBasedLine = Math.Clamp(zeroBasedLine, 0, LineCount - 1);
        var block = zeroBasedLine / LinesPerAnchor;
        var line = block * LinesPerAnchor;
        var offset = anchors[block];
        while (line < zeroBasedLine && offset < text.Length)
        {
            if (text[offset++] == '\n') line++;
        }
        return offset;
    }

    public IReadOnlyList<IndexedLine> LinesFrom(int zeroBasedLine, int maximum)
    {
        if (maximum <= 0) return [];
        zeroBasedLine = Math.Clamp(zeroBasedLine, 0, LineCount - 1);
        var lines = new List<IndexedLine>(Math.Min(maximum, LineCount - zeroBasedLine));
        var offset = StartOffset(zeroBasedLine);
        for (var line = zeroBasedLine; line < LineCount && lines.Count < maximum; line++)
        {
            lines.Add(new IndexedLine(line + 1, offset));
            while (offset < text.Length && text[offset++] != '\n') { }
        }
        return lines;
    }

    public IReadOnlyList<IndexedWhitespace> WhitespaceFrom(
        int zeroBasedLine, int maximumLines = 500, int maximumCharacters = 50_000, int maximumMarkers = 2_000)
    {
        if (maximumLines <= 0 || maximumCharacters <= 0 || maximumMarkers <= 0) return [];
        var lines = LinesFrom(zeroBasedLine, maximumLines + 1);
        if (lines.Count == 0) return [];
        var end = lines.Count > maximumLines ? lines[^1].StartOffset : text.Length;
        end = Math.Min(end, lines[0].StartOffset + maximumCharacters);
        var markers = new List<IndexedWhitespace>(Math.Min(maximumMarkers, 128));
        for (var offset = lines[0].StartOffset; offset < end && markers.Count < maximumMarkers; offset++)
        {
            if (text[offset] == ' ') markers.Add(new IndexedWhitespace(offset, false));
            else if (text[offset] == '\t') markers.Add(new IndexedWhitespace(offset, true));
        }
        return markers;
    }

    public IReadOnlyList<IndexedLineDetail> LineDetailsFrom(
        int zeroBasedLine, int maximumLines = 500, int maximumCharacters = 50_000, int tabWidth = 4)
    {
        if (maximumLines <= 0 || maximumCharacters <= 0) return [];
        tabWidth = Math.Clamp(tabWidth, 1, 16);
        var starts = LinesFrom(zeroBasedLine, maximumLines);
        var result = new List<IndexedLineDetail>(starts.Count);
        var budgetEnd = starts.Count == 0 ? 0 : Math.Min(text.Length, starts[0].StartOffset + maximumCharacters);
        foreach (var line in starts)
        {
            if (line.StartOffset >= budgetEnd && result.Count > 0) break;
            var end = line.StartOffset;
            while (end < text.Length && text[end] != '\n' && end < budgetEnd) end++;
            var contentEnd = end > line.StartOffset && text[end - 1] == '\r' ? end - 1 : end;
            var cursor = line.StartOffset;
            var indent = 0;
            while (cursor < contentEnd && text[cursor] is ' ' or '\t')
            {
                indent += text[cursor] == '\t' ? tabWidth - indent % tabWidth : 1;
                cursor++;
            }
            var trailing = contentEnd;
            while (trailing > cursor && text[trailing - 1] is ' ' or '\t') trailing--;
            result.Add(new(line.Number, line.StartOffset, contentEnd,
                end < text.Length && text[end] == '\n' ? end + 1 : end, indent, trailing));
            if (end >= budgetEnd) break;
        }
        return result;
    }

    public IReadOnlyList<MinimapLine> MinimapSamples(int maximumSamples = 600)
    {
        if (maximumSamples <= 0) return [];
        var count = Math.Min(LineCount, maximumSamples);
        var samples = new List<MinimapLine>(count);
        var previousLine = -1;
        for (var sample = 0; sample < count; sample++)
        {
            var line = count == 1 ? 0 : (int)((long)sample * (LineCount - 1) / (count - 1));
            if (line == previousLine) continue;
            previousLine = line;
            var start = StartOffset(line);
            var end = start;
            while (end < text.Length && text[end] != '\n' && end - start < 512) end++;
            if (end > start && text[end - 1] == '\r') end--;
            var indentation = 0;
            var firstContent = start;
            while (firstContent < end && text[firstContent] is ' ' or '\t')
            {
                indentation += text[firstContent] == '\t' ? 4 : 1;
                firstContent++;
            }
            var lastContent = end;
            while (lastContent > firstContent && Char.IsWhiteSpace(text[lastContent - 1])) lastContent--;
            samples.Add(new MinimapLine(line + 1, Math.Min(indentation, 120),
                Math.Min(lastContent - firstContent, 200)));
        }
        return samples;
    }
}
