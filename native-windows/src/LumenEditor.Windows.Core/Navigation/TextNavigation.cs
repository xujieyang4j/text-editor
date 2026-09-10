namespace LumenEditor.Windows.Core.Navigation;

public static class TextNavigation
{
    public static int LineColumnToOffset(string text, int line, int column)
    {
        var requestedLine = Math.Max(1, line);
        var offset = 0;
        for (var currentLine = 1; currentLine < requestedLine && offset < text.Length; currentLine++)
        {
            var next = text.IndexOf('\n', offset);
            if (next < 0) return text.Length;
            offset = next + 1;
        }
        var lineEnd = text.IndexOf('\n', offset);
        if (lineEnd < 0) lineEnd = text.Length;
        var candidate = Math.Clamp(offset + Math.Max(0, column - 1), offset, lineEnd);
        if (candidate > 0 && candidate < text.Length
            && Char.IsHighSurrogate(text[candidate - 1]) && Char.IsLowSurrogate(text[candidate]))
        {
            candidate--;
        }
        return candidate;
    }

    public static (int Line, int Column) OffsetToLineColumn(string text, int offset)
    {
        var safeOffset = Math.Clamp(offset, 0, text.Length);
        if (safeOffset > 0 && safeOffset < text.Length
            && Char.IsHighSurrogate(text[safeOffset - 1]) && Char.IsLowSurrogate(text[safeOffset]))
        {
            safeOffset--;
        }
        var line = 1;
        var lineStart = 0;
        for (var index = 0; index < safeOffset; index++)
        {
            if (text[index] != '\n') continue;
            line++;
            lineStart = index + 1;
        }
        return (line, safeOffset - lineStart + 1);
    }
}
