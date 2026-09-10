using LumenEditor.Windows.Core.Parsing;

namespace LumenEditor.Windows.Core.Editing;

/// <summary>Atomic structural input shared by single and multiple UTF-16 selections.</summary>
public static class EditorInputPlanner
{
    public static bool InsertNewline(
        EditorBuffer buffer, int tabWidth, bool insertSpaces,
        IReadOnlyList<CodeMirrorNewlineIndentation>? parsed = null, string language = "plain")
    {
        tabWidth = Math.Clamp(tabWidth, 1, 16);
        var answers = (parsed ?? []).ToDictionary(value => value.Position);
        return Apply(buffer, selection =>
        {
            var lineStart = buffer.Text.LastIndexOf('\n', Math.Max(0, selection.Start - 1));
            lineStart = lineStart < 0 ? 0 : lineStart + 1;
            var indentEnd = lineStart;
            while (indentEnd < buffer.Text.Length && indentEnd < selection.Start
                && buffer.Text[indentEnd] is ' ' or '\t') indentEnd++;
            var baseIndent = buffer.Text[lineStart..indentEnd];
            var previous = PreviousNonWhitespace(buffer.Text, selection.Start);
            var next = selection.End < buffer.Text.Length ? buffer.Text[selection.End] : '\0';
            var paired = previous switch { '(' => ')', '[' => ']', '{' => '}', _ => '\0' };
            var lineBeforeCursor = buffer.Text[lineStart..selection.Start];
            var languageKey = language.Trim().ToLowerInvariant();
            var opensIndentedBlock = paired != '\0'
                || languageKey == "python" && lineBeforeCursor.TrimEnd().EndsWith(':')
                || languageKey == "ruby" && RubyBlockStart(lineBeforeCursor);
            var lexicalIndent = opensIndentedBlock
                ? baseIndent + Indentation(tabWidth, tabWidth, insertSpaces) : baseIndent;
            var answer = answers.GetValueOrDefault(selection.Start);
            var explode = selection.Length == 0
                && (answer?.Explode == true || paired != '\0' && paired == next);
            var innerColumns = explode ? answer?.DoubleColumns : answer?.Columns;
            var inner = innerColumns is { } columns
                ? Indentation(columns, tabWidth, insertSpaces) : lexicalIndent;
            if (!explode) return ("\n" + inner, 1 + inner.Length);
            var outer = answer?.Columns is { } outerColumns
                ? Indentation(outerColumns, tabWidth, insertSpaces) : baseIndent;
            return ("\n" + inner + "\n" + outer, 1 + inner.Length);
        });
    }

    public static bool InsertPair(EditorBuffer buffer, char opening)
    {
        var closing = opening switch
        {
            '(' => ')', '[' => ']', '{' => '}', '"' => '"', '\'' => '\'', '`' => '`', _ => '\0'
        };
        if (closing == '\0') return false;
        if (opening is '"' or '\'' or '`' && buffer.Selections.Ranges.Any(selection =>
            selection.Length == 0 && (selection.Start > 0 && buffer.Text[selection.Start - 1] == '\\'
                || selection.Start < buffer.Text.Length && !Char.IsWhiteSpace(buffer.Text[selection.Start])
                    && buffer.Text[selection.Start] is not ')' and not ']' and not '}' and not ',' and not ';')))
            return false;
        return Apply(buffer, selection =>
        {
            var selected = buffer.Text[selection.Start..selection.End];
            return ($"{opening}{selected}{closing}", 1 + selected.Length);
        });
    }

    public static bool SkipClosing(EditorBuffer buffer, char closing)
    {
        if (closing is not (')' or ']' or '}' or '"' or '\'' or '`')
            || buffer.Selections.Ranges.Any(selection => selection.Length != 0
                || selection.Head >= buffer.Text.Length || buffer.Text[selection.Head] != closing)) return false;
        return buffer.SetSelections(new MultiSelectionSet(buffer.Selections.Ranges
            .Select(selection => new TextSelection(selection.Head + 1, selection.Head + 1)),
            buffer.Selections.MainIndex));
    }

    public static bool DeleteEmptyPairs(EditorBuffer buffer)
    {
        var reversePairs = new Dictionary<char, char>
            { [')'] = '(', [']'] = '[', ['}'] = '{', ['"'] = '"', ['\''] = '\'', ['`'] = '`' };
        if (buffer.Selections.Ranges.Any(selection => selection.Length != 0 || selection.Head <= 0
            || selection.Head >= buffer.Text.Length || !reversePairs.TryGetValue(
                buffer.Text[selection.Head], out var opening) || buffer.Text[selection.Head - 1] != opening)) return false;
        return Apply(buffer, _ => (String.Empty, 0), expandEmptyPairs: true);
    }

    private static bool Apply(
        EditorBuffer buffer, Func<TextSelection, (string Text, int CursorOffset)> replacement,
        bool expandEmptyPairs = false)
    {
        var edits = buffer.Selections.Ranges.Select((range, index) =>
        {
            var planned = replacement(range);
            var target = expandEmptyPairs ? new TextSelection(range.Head - 1, range.Head + 1) : range;
            return (Range: target, Index: index, planned.Text, planned.CursorOffset);
        }).OrderBy(edit => edit.Range.Start).ToArray();
        var output = new System.Text.StringBuilder(buffer.Text);
        foreach (var edit in edits.Reverse())
        {
            output.Remove(edit.Range.Start, edit.Range.Length);
            output.Insert(edit.Range.Start, edit.Text);
        }
        var shift = 0;
        var selections = new TextSelection[edits.Length];
        foreach (var edit in edits)
        {
            var position = edit.Range.Start + shift + edit.CursorOffset;
            selections[edit.Index] = new(position, position);
            shift += edit.Text.Length - edit.Range.Length;
        }
        return buffer.Apply(output.ToString(), new MultiSelectionSet(selections, buffer.Selections.MainIndex));
    }

    private static char PreviousNonWhitespace(string text, int offset)
    {
        for (var index = Math.Min(offset, text.Length) - 1; index >= 0 && text[index] != '\n'; index--)
            if (!Char.IsWhiteSpace(text[index])) return text[index];
        return '\0';
    }

    private static bool RubyBlockStart(string line)
    {
        var value = line.Trim();
        return value.EndsWith(" do", StringComparison.Ordinal)
            || value.Split(' ', '\t').FirstOrDefault() is "class" or "module" or "def"
                or "if" or "unless" or "case" or "while" or "until" or "for" or "begin";
    }

    private static string Indentation(int columns, int tabWidth, bool insertSpaces)
    {
        columns = Math.Clamp(columns, 0, CodeMirrorParserProtocol.MaximumIndentationColumns);
        return insertSpaces ? new string(' ', columns)
            : new string('\t', columns / tabWidth) + new string(' ', columns % tabWidth);
    }
}
