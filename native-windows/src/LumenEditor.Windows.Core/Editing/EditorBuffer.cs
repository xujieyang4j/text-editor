using System.Globalization;
using System.Text;

namespace LumenEditor.Windows.Core.Editing;

public sealed record TextSelection(int Anchor, int Head)
{
    public int Start => Math.Min(Anchor, Head);
    public int End => Math.Max(Anchor, Head);
    public int Length => End - Start;

    public bool IsValidFor(string text) => Start >= 0 && End <= text.Length
        && !SplitsSurrogatePair(text, Start) && !SplitsSurrogatePair(text, End);

    private static bool SplitsSurrogatePair(string text, int offset) =>
        offset > 0 && offset < text.Length
        && char.IsHighSurrogate(text[offset - 1]) && char.IsLowSurrogate(text[offset]);
}

public sealed record BufferChange(string Before, string After, MultiSelectionSet BeforeSelections, MultiSelectionSet AfterSelections);

/// <summary>Revisioned UTF-16 text buffer with bounded application-level undo/redo.</summary>
public sealed class EditorBuffer
{
    public const int MaximumUndoEntries = 10_000;
    private readonly LinkedList<BufferChange> undo = [];
    private readonly LinkedList<BufferChange> redo = [];

    public EditorBuffer(string text = "", TextSelection? selection = null)
    {
        Text = text;
        var initial = selection ?? new TextSelection(0, 0);
        if (!initial.IsValidFor(Text)) initial = new TextSelection(0, 0);
        Selections = MultiSelectionSet.Single(initial);
    }

    public string Text { get; private set; }
    public MultiSelectionSet Selections { get; private set; }
    public TextSelection Selection => Selections.Main;
    public ulong Revision { get; private set; }
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public bool SetSelection(TextSelection selection)
    {
        return SetSelections(MultiSelectionSet.Single(selection));
    }

    public bool SetSelections(MultiSelectionSet selections)
    {
        ArgumentNullException.ThrowIfNull(selections);
        if (!selections.IsValidFor(Text) || selections.Equals(Selections)) return false;
        Selections = selections;
        return true;
    }

    public bool Replace(TextSelection selection, string replacement, TextSelection? nextSelection = null)
    {
        if (!selection.IsValidFor(Text)) return false;
        replacement ??= string.Empty;
        var after = Text[..selection.Start] + replacement + Text[selection.End..];
        var cursor = selection.Start + replacement.Length;
        return Apply(after, nextSelection ?? new TextSelection(cursor, cursor));
    }

    public bool Apply(string after, TextSelection selection)
        => Apply(after, MultiSelectionSet.Single(selection));

    public bool Apply(string after, MultiSelectionSet selections)
    {
        if (after is null || !selections.IsValidFor(after) || StringComparer.Ordinal.Equals(Text, after)) return false;
        undo.AddLast(new BufferChange(Text, after, Selections, selections));
        while (undo.Count > MaximumUndoEntries) undo.RemoveFirst();
        redo.Clear();
        Text = after;
        Selections = selections;
        Revision++;
        return true;
    }

    public bool Undo()
    {
        if (undo.Last is null) return false;
        var change = undo.Last.Value;
        undo.RemoveLast();
        redo.AddLast(change);
        Text = change.Before;
        Selections = change.BeforeSelections;
        Revision++;
        return true;
    }

    public bool Redo()
    {
        if (redo.Last is null) return false;
        var change = redo.Last.Value;
        redo.RemoveLast();
        undo.AddLast(change);
        Text = change.After;
        Selections = change.AfterSelections;
        Revision++;
        return true;
    }

    public bool TransformSelection(Func<string, string> transform)
    {
        var selected = Text[Selection.Start..Selection.End];
        return Replace(Selection, transform(selected));
    }

    public bool TransformSelectionOrDocument(Func<string, string> transform)
    {
        var target = Selection.Length == 0 ? new TextSelection(0, Text.Length) : Selection;
        var replacement = transform(Text[target.Start..target.End]);
        return Replace(target, replacement,
            new TextSelection(target.Start, target.Start + replacement.Length));
    }

    public bool TrimTrailingWhitespace()
    {
        var normalized = Text.Replace("\r\n", "\n").Replace('\r', '\n');
        var result = string.Join("\n", normalized.Split('\n').Select(line => line.TrimEnd(' ', '\t')));
        return Apply(result, ClampSelection(Selection, result));
    }

    public bool EnsureSingleFinalNewline()
    {
        var result = Text.Replace("\r\n", "\n").Replace('\r', '\n').TrimEnd('\n') + "\n";
        return Apply(result, ClampSelection(Selection, result));
    }

    public bool DeleteSelectedLines()
    {
        var lineRange = SelectedLineRange();
        return Replace(lineRange, String.Empty, new TextSelection(lineRange.Start, lineRange.Start));
    }

    public bool InsertBlankLine(bool above)
    {
        var start = Text.LastIndexOf('\n', Math.Max(0, Selection.Start - 1));
        start = start < 0 ? 0 : start + 1;
        var insertAt = above ? start : Text.IndexOf('\n', Selection.End);
        var appendAfterLastLine = !above && insertAt < 0;
        if (insertAt < 0) insertAt = Text.Length;
        else if (!above) insertAt++;
        var cursor = appendAfterLastLine ? insertAt + 1 : insertAt;
        return Replace(new TextSelection(insertAt, insertAt), "\n", new TextSelection(cursor, cursor));
    }

    public bool TransformSelectedLines(Func<IReadOnlyList<string>, IReadOnlyList<string>> transform)
    {
        var lineRange = SelectedLineRange();
        var selected = Text[lineRange.Start..lineRange.End];
        var hadFinalNewline = selected.EndsWith('\n');
        var lines = selected.TrimEnd('\n').Split('\n').ToList();
        var transformed = transform(lines);
        var result = String.Join("\n", transformed) + (hadFinalNewline ? "\n" : String.Empty);
        var selectionEnd = lineRange.Start + result.Length - (hadFinalNewline ? 1 : 0);
        return Replace(lineRange, result, new TextSelection(lineRange.Start, selectionEnd));
    }

    public bool IndentSelectedLines(string indentation, bool outdent = false)
    {
        indentation ??= String.Empty;
        if (indentation.Length == 0) return false;
        return TransformSelectedLines(lines => lines.Select(line =>
        {
            if (!outdent) return indentation + line;
            if (line.StartsWith(indentation, StringComparison.Ordinal)) return line[indentation.Length..];
            var count = line.TakeWhile(character => character is ' ' or '\t').Take(indentation.Length).Count();
            return line[count..];
        }).ToList());
    }

    public bool ToggleLineComment(string prefix = "//")
    {
        if (String.IsNullOrEmpty(prefix)) return false;
        return TransformSelectedLines(lines =>
        {
            var nonBlank = lines.Where(line => !String.IsNullOrWhiteSpace(line)).ToList();
            var uncomment = nonBlank.Count > 0 && nonBlank.All(line =>
                line.AsSpan(line.Length - line.TrimStart(' ', '\t').Length).StartsWith(prefix, StringComparison.Ordinal));
            return lines.Select(line =>
            {
                if (String.IsNullOrWhiteSpace(line)) return line;
                var indentationLength = line.Length - line.TrimStart(' ', '\t').Length;
                if (!uncomment) return line.Insert(indentationLength, prefix + " ");
                var remove = prefix.Length;
                if (indentationLength + remove < line.Length && line[indentationLength + remove] == ' ') remove++;
                return line.Remove(indentationLength, remove);
            }).ToList();
        });
    }

    public bool ToggleBlockComment(string opening = "/*", string closing = "*/")
    {
        if (String.IsNullOrEmpty(opening) || String.IsNullOrEmpty(closing)) return false;
        var target = Selection.Length == 0 ? new TextSelection(0, Text.Length) : Selection;
        var selected = Text[target.Start..target.End];
        if (target.Start >= opening.Length && target.End + closing.Length <= Text.Length
            && Text.AsSpan(target.Start - opening.Length, opening.Length).SequenceEqual(opening)
            && Text.AsSpan(target.End, closing.Length).SequenceEqual(closing))
        {
            var encompassing = new TextSelection(target.Start - opening.Length, target.End + closing.Length);
            return Replace(encompassing, selected, new TextSelection(encompassing.Start, encompassing.Start + selected.Length));
        }
        if (selected.StartsWith(opening, StringComparison.Ordinal)
            && selected.EndsWith(closing, StringComparison.Ordinal)
            && selected.Length >= opening.Length + closing.Length)
        {
            var replacement = selected[opening.Length..^closing.Length];
            return Replace(target, replacement, new TextSelection(target.Start, target.Start + replacement.Length));
        }
        var wrapped = opening + selected + closing;
        return Replace(target, wrapped, new TextSelection(target.Start + opening.Length, target.Start + opening.Length + selected.Length));
    }

    public bool MoveSelectedLines(bool down)
    {
        var block = SelectedLineRange();
        if (!down)
        {
            if (block.Start == 0) return false;
            var previousStart = block.Start > 1 ? Text.LastIndexOf('\n', block.Start - 2) + 1 : 0;
            var previous = Text[previousStart..block.Start];
            var selected = Text[block.Start..block.End];
            var result = Text[..previousStart] + selected + previous + Text[block.End..];
            var shift = previous.Length;
            return Apply(result, new TextSelection(block.Start - shift, block.End - shift));
        }
        if (block.End >= Text.Length) return false;
        var nextEnd = Text.IndexOf('\n', block.End);
        nextEnd = nextEnd < 0 ? Text.Length : nextEnd + 1;
        var current = Text[block.Start..block.End];
        var next = Text[block.End..nextEnd];
        var after = Text[..block.Start] + next + current + Text[nextEnd..];
        return Apply(after, new TextSelection(block.Start + next.Length, block.End + next.Length));
    }

    public bool CopySelectedLines(bool down)
    {
        var block = SelectedLineRange();
        var selected = Text[block.Start..block.End];
        if (!down)
        {
            var insertion = selected.EndsWith('\n') ? selected : selected + "\n";
            return Replace(new TextSelection(block.Start, block.Start), insertion,
                new TextSelection(block.Start, block.Start + selected.Length));
        }
        if (selected.EndsWith('\n'))
        {
            return Replace(new TextSelection(block.End, block.End), selected,
                new TextSelection(block.End, block.End + selected.Length - 1));
        }
        var added = "\n" + selected;
        return Replace(new TextSelection(block.End, block.End), added,
            new TextSelection(block.End + 1, block.End + 1 + selected.Length));
    }

    public bool DuplicateSelectionOrLine()
    {
        if (Selection.Length == 0) return CopySelectedLines(down: true);
        var selected = Text[Selection.Start..Selection.End];
        return Replace(new TextSelection(Selection.End, Selection.End), selected,
            new TextSelection(Selection.End, Selection.End + selected.Length));
    }

    public bool DeleteWord(bool backward)
    {
        if (Selection.Length > 0) return Replace(Selection, String.Empty);
        var cursor = Selection.Start;
        if (backward)
        {
            if (cursor == 0) return false;
            var start = cursor;
            while (start > 0 && Rune.IsWhiteSpace(RuneBefore(Text, start, out var previous))) start = previous;
            if (start == 0) return Replace(new TextSelection(0, cursor), String.Empty);
            var category = RuneCategory(RuneBefore(Text, start, out _));
            while (start > 0)
            {
                var rune = RuneBefore(Text, start, out var previous);
                if (RuneCategory(rune) != category) break;
                start = previous;
            }
            return Replace(new TextSelection(start, cursor), String.Empty);
        }
        if (cursor >= Text.Length) return false;
        var end = cursor;
        while (end < Text.Length && Rune.IsWhiteSpace(RuneAt(Text, end, out var next))) end = next;
        if (end >= Text.Length) return Replace(new TextSelection(cursor, Text.Length), String.Empty);
        var forwardCategory = RuneCategory(RuneAt(Text, end, out _));
        while (end < Text.Length)
        {
            var rune = RuneAt(Text, end, out var next);
            if (RuneCategory(rune) != forwardCategory) break;
            end = next;
        }
        return Replace(new TextSelection(cursor, end), String.Empty);
    }

    public bool DeleteToLineBoundary(bool start)
    {
        if (Selection.Length > 0) return Replace(Selection, String.Empty);
        var cursor = Selection.Start;
        if (start)
        {
            var boundary = cursor == 0 ? 0 : Text.LastIndexOf('\n', cursor - 1) + 1;
            if (boundary == cursor && cursor > 0) boundary--;
            return boundary < cursor && Replace(new TextSelection(boundary, cursor), String.Empty);
        }
        var end = Text.IndexOf('\n', cursor);
        if (end < 0) end = Text.Length;
        if (end == cursor && end < Text.Length) end++;
        return end > cursor && Replace(new TextSelection(cursor, end), String.Empty);
    }

    public bool TransposeCharacters()
    {
        if (Selection.Length > 0 || Text.Length < 2) return false;
        var cursor = Selection.Start;
        if (cursor == 0) return false;
        if (cursor == Text.Length)
        {
            var rightStart = PreviousRuneOffset(Text, cursor);
            var leftStart = PreviousRuneOffset(Text, rightStart);
            if (leftStart == rightStart) return false;
            var left = Text[leftStart..rightStart];
            var right = Text[rightStart..cursor];
            var result = Text[..leftStart] + right + left;
            return Apply(result, new TextSelection(cursor, cursor));
        }
        var before = PreviousRuneOffset(Text, cursor);
        var after = NextRuneOffset(Text, cursor);
        if (Text[before..cursor].Contains('\n') || Text[cursor..after].Contains('\n')) return false;
        var swapped = Text[..before] + Text[cursor..after] + Text[before..cursor] + Text[after..];
        return Apply(swapped, new TextSelection(after, after));
    }

    public bool JoinSelectedLines()
    {
        var block = SelectedLineRange();
        var selected = Text[block.Start..block.End];
        if (!selected.Contains('\n'))
        {
            var next = Text.IndexOf('\n', block.End);
            if (next < 0) return false;
        }
        var hadFinalNewline = selected.EndsWith('\n');
        var joined = String.Join(" ", selected.TrimEnd('\n').Split('\n').Select(line => line.Trim()))
            + (hadFinalNewline ? "\n" : String.Empty);
        return Replace(block, joined, new TextSelection(block.Start, block.Start + joined.Length - (hadFinalNewline ? 1 : 0)));
    }

    public bool WrapParagraph(int column = 80, int tabSize = 8) =>
        TransformParagraphs(wrap: true, Math.Clamp(column, 20, 500), Math.Clamp(tabSize, 1, 16));

    public bool UnwrapParagraph() => TransformParagraphs(wrap: false, 80, 8);

    private bool TransformParagraphs(bool wrap, int column, int tabSize)
    {
        var lines = Text.Split('\n');
        var starts = new int[lines.Length];
        for (var index = 1; index < starts.Length; index++) starts[index] = starts[index - 1] + lines[index - 1].Length + 1;
        var effectiveEnd = Selection.Length > 0 && Selection.End > 0 && Selection.End < Text.Length
            && Text[Selection.End - 1] == '\n' ? Selection.End - 1 : Selection.End;
        var firstLine = LineIndexAt(starts, Selection.Start);
        var lastLine = LineIndexAt(starts, effectiveEnd);
        var output = new StringBuilder(Text.Length);
        var changed = false;
        var transformedStart = -1;
        var transformedEnd = -1;

        for (var index = 0; index < lines.Length;)
        {
            var first = ParagraphParts(lines[index]);
            if (first.Boundary)
            {
                AppendLine(output, lines[index], index < lines.Length - 1);
                index++;
                continue;
            }
            var end = index + 1;
            while (end < lines.Length)
            {
                var next = ParagraphParts(lines[end]);
                if (next.Boundary || next.Indent != first.Indent || next.Marker != first.Marker) break;
                end++;
            }
            var targeted = end - 1 >= firstLine && index <= lastLine;
            if (!targeted)
            {
                for (var line = index; line < end; line++) AppendLine(output, lines[line], line < lines.Length - 1);
                index = end;
                continue;
            }

            var tokens = lines[index..end].SelectMany(line => ParagraphParts(line).Content
                .Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries)).ToList();
            var transformed = wrap ? WrapTokens(first.Prefix, tokens, column, tabSize)
                : first.Prefix + String.Join(' ', tokens);
            var original = String.Join('\n', lines[index..end]);
            if (!StringComparer.Ordinal.Equals(original, transformed)) changed = true;
            if (transformedStart < 0) transformedStart = output.Length;
            output.Append(transformed);
            transformedEnd = output.Length;
            if (end < lines.Length) output.Append('\n');
            index = end;
        }

        if (!changed) return false;
        var result = output.ToString();
        return Apply(result, new TextSelection(
            Math.Clamp(transformedStart, 0, result.Length),
            Math.Clamp(transformedEnd, 0, result.Length)));
    }

    public bool ReindentSelectedLines(int tabSize, bool insertSpaces)
    {
        tabSize = Math.Clamp(tabSize, 1, 16);
        var lines = Text.Split('\n');
        var probeBlockComment = false;
        if (!lines.Any(line => BraceDelta(line, ref probeBlockComment) != 0)) return false;
        var starts = new int[lines.Length];
        for (var index = 1; index < starts.Length; index++) starts[index] = starts[index - 1] + lines[index - 1].Length + 1;
        var effectiveEnd = Selection.Length > 0 && Selection.End > 0 && Selection.End < Text.Length
            && Text[Selection.End - 1] == '\n' ? Selection.End - 1 : Selection.End;
        var firstLine = LineIndexAt(starts, Selection.Start);
        var lastLine = LineIndexAt(starts, effectiveEnd);
        var depth = 0;
        var inBlockComment = false;
        for (var index = 0; index < firstLine; index++)
        {
            depth = Math.Max(0, depth + BraceDelta(lines[index], ref inBlockComment));
        }
        var indentation = insertSpaces ? new string(' ', tabSize) : "\t";
        for (var index = firstLine; index <= lastLine; index++)
        {
            var trimmed = lines[index].TrimStart(' ', '\t');
            if (trimmed.Length == 0)
            {
                lines[index] = String.Empty;
                continue;
            }
            var lineDepth = trimmed.StartsWith('}') ? Math.Max(0, depth - 1) : depth;
            lines[index] = String.Concat(Enumerable.Repeat(indentation, lineDepth)) + trimmed;
            depth = Math.Max(0, depth + BraceDelta(trimmed, ref inBlockComment));
        }
        var result = String.Join('\n', lines);
        var start = starts[firstLine];
        var end = start + String.Join('\n', lines[firstLine..(lastLine + 1)]).Length;
        return Apply(result, new TextSelection(start, end));
    }

    public bool ConvertIndentation(int tabSize, bool toSpaces)
    {
        tabSize = Math.Clamp(tabSize, 1, 16);
        return TransformSelectedLines(lines => lines.Select(line =>
        {
            var whitespace = line.TakeWhile(character => character is ' ' or '\t').ToArray();
            var columns = 0;
            foreach (var character in whitespace)
            {
                columns = character == '\t' ? columns + tabSize - columns % tabSize : columns + 1;
            }
            var indentation = toSpaces
                ? new string(' ', columns)
                : new string('\t', columns / tabSize) + new string(' ', columns % tabSize);
            return indentation + line[whitespace.Length..];
        }).ToList());
    }

    public bool SelectLine()
    {
        var range = SelectedLineRange();
        return SetSelection(new TextSelection(range.Start, range.End > range.Start && Text[range.End - 1] == '\n'
            ? range.End - 1 : range.End));
    }

    public bool SelectMatchingBracket(bool includeBrackets = false)
    {
        var pair = FindMatchingBracket();
        if (pair is null) return false;
        return includeBrackets
            ? SetSelection(new TextSelection(pair.Value.Open, pair.Value.Close + 1))
            : SetSelection(new TextSelection(pair.Value.Open + 1, pair.Value.Close));
    }

    public bool SelectParentSyntax()
    {
        if (Text.Length > 2_000_000) return false;
        var candidates = new List<TextSelection>();
        var word = UnicodeWordRange(Selection.Head);
        if (word is not null && ContainsStrictly(word, Selection)) candidates.Add(word);
        foreach (var pair in BalancedPairs())
        {
            var inner = new TextSelection(pair.Open + 1, pair.Close);
            var outer = new TextSelection(pair.Open, pair.Close + 1);
            if (ContainsStrictly(inner, Selection)) candidates.Add(inner);
            if (ContainsStrictly(outer, Selection)) candidates.Add(outer);
        }
        var next = candidates.OrderBy(candidate => candidate.Length)
            .ThenByDescending(candidate => candidate.Start).FirstOrDefault();
        return next is not null && SetSelection(next);
    }

    public bool ExpandSelection()
    {
        if (SelectParentSyntax()) return true;
        var line = SelectedLineRange();
        if (line.End > line.Start && Text[line.End - 1] == '\n') line = new TextSelection(line.Start, line.End - 1);
        if (ContainsStrictly(line, Selection) && SetSelection(line)) return true;
        return (Selection.Start > 0 || Selection.End < Text.Length)
            && SetSelection(new TextSelection(0, Text.Length));
    }

    public bool GoToMatchingBracket()
    {
        var pair = FindMatchingBracket();
        if (pair is null) return false;
        var cursor = Selection.Start <= pair.Value.Open ? pair.Value.Close : pair.Value.Open;
        return SetSelection(new TextSelection(cursor, cursor));
    }

    private (int Open, int Close)? FindMatchingBracket()
    {
        if (Text.Length == 0) return null;
        var cursor = Selection.Start;
        var candidate = cursor < Text.Length && IsBracket(Text[cursor]) ? cursor
            : cursor > 0 && IsBracket(Text[cursor - 1]) ? cursor - 1 : -1;
        if (candidate < 0) return FindEnclosingBracket(cursor);
        var value = Text[candidate];
        var opening = value is '(' or '[' or '{';
        var open = opening ? value : value switch { ')' => '(', ']' => '[', _ => '{' };
        var close = opening ? value switch { '(' => ')', '[' => ']', _ => '}' } : value;
        var depth = 0;
        if (opening)
        {
            for (var index = candidate; index < Text.Length; index++)
            {
                if (Text[index] == open) depth++;
                else if (Text[index] == close && --depth == 0) return (candidate, index);
            }
        }
        else
        {
            for (var index = candidate; index >= 0; index--)
            {
                if (Text[index] == close) depth++;
                else if (Text[index] == open && --depth == 0) return (index, candidate);
            }
        }
        return null;
    }

    private (int Open, int Close)? FindEnclosingBracket(int cursor)
    {
        for (var openIndex = Math.Min(cursor - 1, Text.Length - 1); openIndex >= 0; openIndex--)
        {
            if (Text[openIndex] is not ('(' or '[' or '{')) continue;
            var saved = Selections;
            Selections = MultiSelectionSet.Single(new TextSelection(openIndex, openIndex));
            var pair = FindMatchingBracket();
            Selections = saved;
            if (pair is not null && pair.Value.Close >= cursor) return pair;
        }
        return null;
    }

    private TextSelection? UnicodeWordRange(int cursor)
    {
        if (Text.Length == 0) return null;
        var probe = Math.Clamp(cursor, 0, Text.Length);
        if (probe == Text.Length || (probe < Text.Length && RuneCategory(RuneAt(Text, probe, out _)) != 1))
        {
            if (probe == 0) return null;
            var previous = RuneBefore(Text, probe, out var previousOffset);
            if (RuneCategory(previous) != 1) return null;
            probe = previousOffset;
        }
        var start = probe;
        while (start > 0)
        {
            var rune = RuneBefore(Text, start, out var previous);
            if (RuneCategory(rune) != 1) break;
            start = previous;
        }
        var end = probe;
        while (end < Text.Length)
        {
            var rune = RuneAt(Text, end, out var next);
            if (RuneCategory(rune) != 1) break;
            end = next;
        }
        return end > start ? new TextSelection(start, end) : null;
    }

    private IReadOnlyList<(int Open, int Close)> BalancedPairs()
    {
        var pairs = new List<(int Open, int Close)>();
        var stack = new Stack<(char Value, int Position)>();
        var quote = '\0';
        var escaped = false;
        var lineComment = false;
        var blockComment = false;
        for (var index = 0; index < Text.Length; index++)
        {
            var value = Text[index];
            var next = index + 1 < Text.Length ? Text[index + 1] : '\0';
            if (lineComment)
            {
                if (value == '\n') lineComment = false;
                continue;
            }
            if (blockComment)
            {
                if (value == '*' && next == '/') { blockComment = false; index++; }
                continue;
            }
            if (quote != '\0')
            {
                if (escaped) escaped = false;
                else if (value == '\\') escaped = true;
                else if (value == quote) quote = '\0';
                continue;
            }
            if (value == '/' && next == '/') { lineComment = true; index++; continue; }
            if (value == '/' && next == '*') { blockComment = true; index++; continue; }
            if (value == '"' || value == '\'') { quote = value; continue; }
            if (value is '(' or '[' or '{')
            {
                if (stack.Count < 4_096) stack.Push((value, index));
                continue;
            }
            var expected = value switch { ')' => '(', ']' => '[', '}' => '{', _ => '\0' };
            if (expected == '\0' || stack.Count == 0) continue;
            var opening = stack.Pop();
            if (opening.Value == expected && pairs.Count < 100_000) pairs.Add((opening.Position, index));
        }
        return pairs;
    }

    private static bool ContainsStrictly(TextSelection candidate, TextSelection selection) =>
        candidate.Start <= selection.Start && candidate.End >= selection.End
        && (candidate.Start < selection.Start || candidate.End > selection.End);

    private static bool IsBracket(char value) => value is '(' or ')' or '[' or ']' or '{' or '}';

    public bool ToTitleCase() => TransformSelectionOrDocument(text =>
        CultureInfo.InvariantCulture.TextInfo.ToTitleCase(text.ToLowerInvariant()));

    public bool SwapCase() => TransformSelectionOrDocument(text =>
    {
        var builder = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            var value = rune.ToString();
            builder.Append(Rune.IsUpper(rune) || Rune.GetUnicodeCategory(rune) == UnicodeCategory.TitlecaseLetter
                ? value.ToLowerInvariant()
                : Rune.IsLower(rune) ? value.ToUpperInvariant() : value);
        }
        return builder.ToString();
    });

    private static Rune RuneAt(string text, int offset, out int next)
    {
        var rune = Rune.GetRuneAt(text, offset);
        next = offset + rune.Utf16SequenceLength;
        return rune;
    }

    private static Rune RuneBefore(string text, int offset, out int previous)
    {
        previous = PreviousRuneOffset(text, offset);
        return Rune.GetRuneAt(text, previous);
    }

    private static int PreviousRuneOffset(string text, int offset) =>
        offset > 1 && char.IsLowSurrogate(text[offset - 1]) && char.IsHighSurrogate(text[offset - 2])
            ? offset - 2 : Math.Max(0, offset - 1);

    private static int NextRuneOffset(string text, int offset) =>
        offset < text.Length - 1 && char.IsHighSurrogate(text[offset]) && char.IsLowSurrogate(text[offset + 1])
            ? offset + 2 : Math.Min(text.Length, offset + 1);

    private static int RuneCategory(Rune rune) => Rune.IsLetterOrDigit(rune) || rune.Value == '_' ? 1 : 2;

    private sealed record ParagraphLineParts(
        string Indent, string Marker, string Prefix, string Content, bool Boundary);

    private static ParagraphLineParts ParagraphParts(string line)
    {
        var indentLength = line.TakeWhile(character => character is ' ' or '\t').Count();
        var indent = line[..indentLength];
        var rest = line[indentLength..];
        if (String.IsNullOrWhiteSpace(rest)) return new(indent, String.Empty, indent, String.Empty, true);
        var marker = new[] { "///", "//", "#" }.FirstOrDefault(candidate =>
            rest.StartsWith(candidate, StringComparison.Ordinal)
            && (rest.Length == candidate.Length || rest[candidate.Length] is ' ' or '\t')) ?? String.Empty;
        var content = rest[marker.Length..].TrimStart(' ', '\t');
        var prefix = marker.Length == 0 ? indent : indent + marker + " ";
        return new(indent, marker, prefix, content, content.Length == 0);
    }

    private static string WrapTokens(string prefix, IReadOnlyList<string> tokens, int column, int tabSize)
    {
        if (tokens.Count == 0) return prefix.TrimEnd();
        var lines = new List<string>();
        var current = new List<string>();
        var width = VisualWidth(prefix, tabSize);
        foreach (var token in tokens)
        {
            var tokenWidth = VisualWidth(token, tabSize);
            if (current.Count > 0 && width + 1 + tokenWidth > column)
            {
                lines.Add(prefix + String.Join(' ', current));
                current.Clear();
                width = VisualWidth(prefix, tabSize);
            }
            if (current.Count > 0) width++;
            current.Add(token);
            width += tokenWidth;
        }
        lines.Add(prefix + String.Join(' ', current));
        return String.Join('\n', lines);
    }

    private static int VisualWidth(string value, int tabSize)
    {
        var width = 0;
        var elements = StringInfo.GetTextElementEnumerator(value);
        while (elements.MoveNext()) width = elements.GetTextElement() == "\t"
            ? width + tabSize - width % tabSize : width + 1;
        return width;
    }

    private static void AppendLine(StringBuilder output, string line, bool newline)
    {
        output.Append(line);
        if (newline) output.Append('\n');
    }

    private static int LineIndexAt(IReadOnlyList<int> starts, int position)
    {
        var low = 0;
        var high = starts.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (starts[middle] <= position) low = middle + 1;
            else high = middle;
        }
        return Math.Max(0, low - 1);
    }

    private static int BraceDelta(string line, ref bool inBlockComment)
    {
        var delta = 0;
        var quote = '\0';
        var escaped = false;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            var next = index + 1 < line.Length ? line[index + 1] : '\0';
            if (inBlockComment)
            {
                if (character == '*' && next == '/') { inBlockComment = false; index++; }
                continue;
            }
            if (quote != '\0')
            {
                if (escaped) escaped = false;
                else if (character == '\\') escaped = true;
                else if (character == quote) quote = '\0';
                continue;
            }
            if (character == '/' && next == '/') break;
            if (character == '/' && next == '*') { inBlockComment = true; index++; continue; }
            if (character == '"' || character == '\'') { quote = character; continue; }
            if (character == '{') delta++;
            else if (character == '}') delta--;
        }
        return delta;
    }

    private TextSelection SelectedLineRange()
    {
        var start = Selection.Start == 0 ? 0 : Text.LastIndexOf('\n', Selection.Start - 1) + 1;
        var selectionEnd = Selection.Length > 0 && Selection.End > 0 && Text[Selection.End - 1] == '\n'
            ? Selection.End - 1 : Selection.End;
        var end = Text.IndexOf('\n', selectionEnd);
        end = end < 0 ? Text.Length : end + 1;
        return new TextSelection(start, end);
    }

    private static TextSelection ClampSelection(TextSelection selection, string text)
    {
        var anchor = Math.Clamp(selection.Anchor, 0, text.Length);
        var head = Math.Clamp(selection.Head, 0, text.Length);
        if (anchor > 0 && anchor < text.Length && char.IsHighSurrogate(text[anchor - 1]) && char.IsLowSurrogate(text[anchor])) anchor--;
        if (head > 0 && head < text.Length && char.IsHighSurrogate(text[head - 1]) && char.IsLowSurrogate(text[head])) head--;
        return new(anchor, head);
    }
}
