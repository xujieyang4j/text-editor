using System.Text;

namespace LumenEditor.Windows.Core.Editing;

/// <summary>Normalized, bounded set of UTF-16 selections with one native primary selection.</summary>
public sealed class MultiSelectionSet : IEquatable<MultiSelectionSet>
{
    public const int MaximumSelections = 10_000;
    public MultiSelectionSet(IEnumerable<TextSelection> selections, int mainIndex = 0)
    {
        ArgumentNullException.ThrowIfNull(selections);
        var input = selections.Take(MaximumSelections + 1).ToList();
        if (input.Count is 0 or > MaximumSelections)
        {
            throw new ArgumentException("A selection set must contain between 1 and 10,000 ranges.", nameof(selections));
        }
        if (mainIndex < 0 || mainIndex >= input.Count) throw new ArgumentOutOfRangeException(nameof(mainIndex));
        var indexed = input.Select((range, index) => (Range: range, Original: index))
            .OrderBy(value => value.Range.Start).ThenBy(value => value.Original).ToList();
        var normalized = new List<TextSelection>(indexed.Count);
        var groups = new List<HashSet<int>>(indexed.Count);
        for (var index = 0; index < indexed.Count; index++)
        {
            var item = indexed[index];
            if (normalized.Count > 0)
            {
                var previous = normalized[^1];
                var overlaps = item.Range.Length == 0
                    ? item.Range.Start <= previous.End
                    : item.Range.Start < previous.End;
                if (overlaps)
                {
                    var mergedStart = Math.Min(previous.Start, item.Range.Start);
                    var mergedEnd = Math.Max(previous.End, item.Range.End);
                    normalized[^1] = item.Range.Anchor > item.Range.Head
                        ? new TextSelection(mergedEnd, mergedStart)
                        : new TextSelection(mergedStart, mergedEnd);
                    groups[^1].Add(item.Original);
                    continue;
                }
            }
            normalized.Add(item.Range);
            groups.Add([item.Original]);
        }
        Ranges = normalized;
        MainIndex = groups.FindIndex(group => group.Contains(mainIndex));
    }

    public IReadOnlyList<TextSelection> Ranges { get; }
    public int MainIndex { get; }
    public TextSelection Main => Ranges[MainIndex];
    public static MultiSelectionSet Single(TextSelection selection) => new([selection]);
    public bool IsValidFor(string text) => Ranges.All(range => range.IsValidFor(text));

    public bool Equals(MultiSelectionSet? other) => other is not null && MainIndex == other.MainIndex
        && Ranges.SequenceEqual(other.Ranges);
    public override bool Equals(object? obj) => obj is MultiSelectionSet other && Equals(other);
    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(MainIndex);
        foreach (var range in Ranges) hash.Add(range);
        return hash.ToHashCode();
    }
}

/// <summary>Selection-only and multi-edit operations shared by the WinUI adapter.</summary>
public static class MultiSelectionCommands
{
    public static bool AddVertical(EditorBuffer buffer, bool below)
    {
        var index = new SparseLineIndex(buffer.Text);
        var ranges = buffer.Selections.Ranges.ToList();
        var heads = ranges.Select(range => range.Head).ToHashSet();
        foreach (var range in buffer.Selections.Ranges)
        {
            var line = index.LineAtOffset(range.Head);
            var targetLine = below ? line + 1 : line - 1;
            if (targetLine < 0 || targetLine >= index.LineCount) continue;
            var column = range.Head - index.StartOffset(line);
            var targetStart = index.StartOffset(targetLine);
            var targetEnd = LineEnd(buffer.Text, index, targetLine);
            var position = Math.Min(targetEnd, targetStart + column);
            if (heads.Add(position)) ranges.Add(new TextSelection(position, position));
        }
        return ranges.Count != buffer.Selections.Ranges.Count
            && buffer.SetSelections(new MultiSelectionSet(ranges, ranges.Count - 1));
    }

    public static bool SelectNextOccurrence(EditorBuffer buffer, bool skip)
    {
        var current = buffer.Selections;
        if (current.Ranges.Any(range => range.Length == 0))
        {
            var expanded = current.Ranges.Select(range => range.Length == 0
                ? WordRange(buffer.Text, range.Head) ?? range : range).ToList();
            return buffer.SetSelections(new MultiSelectionSet(expanded, current.MainIndex));
        }
        var needle = buffer.Text[current.Main.Start..current.Main.End];
        if (needle.Length == 0 || current.Ranges.Any(range =>
            !StringComparer.Ordinal.Equals(buffer.Text[range.Start..range.End], needle))) return false;
        var wholeWord = WordRange(buffer.Text, current.Main.Start) is { } word
            && word.Start == current.Main.Start && word.End == current.Main.End;
        var start = current.Ranges.Max(range => range.End);
        var match = FindOccurrence(buffer.Text, needle, start, current.Ranges, wholeWord)
            ?? FindOccurrence(buffer.Text, needle, 0, current.Ranges, wholeWord, start);
        if (match is null) return false;
        var ranges = current.Ranges.ToList();
        var main = current.MainIndex;
        if (skip) ranges[main] = match;
        else
        {
            ranges.Add(match);
            main = ranges.Count - 1;
        }
        return buffer.SetSelections(new MultiSelectionSet(ranges, main));
    }

    public static bool SelectAllOccurrences(EditorBuffer buffer)
    {
        var selected = buffer.Selections.Main;
        var wordMode = selected.Length == 0;
        if (wordMode && WordRange(buffer.Text, selected.Head) is { } word) selected = word;
        if (selected.Length == 0) return false;
        var needle = buffer.Text[selected.Start..selected.End];
        var ranges = new List<TextSelection>();
        for (var offset = 0; offset <= buffer.Text.Length - needle.Length && ranges.Count < MultiSelectionSet.MaximumSelections;)
        {
            var found = buffer.Text.IndexOf(needle, offset, StringComparison.Ordinal);
            if (found < 0) break;
            var match = new TextSelection(found, found + needle.Length);
            if (!wordMode || IsWholeWord(buffer.Text, match)) ranges.Add(match);
            offset = found + Math.Max(1, needle.Length);
        }
        return ranges.Count > 0 && buffer.SetSelections(new MultiSelectionSet(ranges));
    }

    public static bool RemoveMain(EditorBuffer buffer)
    {
        if (buffer.Selections.Ranges.Count < 2) return false;
        var ranges = buffer.Selections.Ranges.ToList();
        var removed = buffer.Selections.MainIndex;
        ranges.RemoveAt(removed);
        return buffer.SetSelections(new MultiSelectionSet(ranges, removed == 0 ? ranges.Count - 1 : removed - 1));
    }

    public static bool AddLineBoundaries(EditorBuffer buffer, bool atEnd, bool requireNonEmpty = false)
    {
        var index = new SparseLineIndex(buffer.Text);
        var positions = new SortedSet<int>();
        int? mainPosition = null;
        var found = false;
        for (var rangeIndex = 0; rangeIndex < buffer.Selections.Ranges.Count; rangeIndex++)
        {
            var range = buffer.Selections.Ranges[rangeIndex];
            if (requireNonEmpty && range.Length == 0) continue;
            found = true;
            var first = index.LineAtOffset(range.Start);
            var endpoint = range.End;
            if (range.Length > 0 && endpoint > 0 && index.StartOffset(index.LineAtOffset(endpoint)) == endpoint) endpoint--;
            var last = index.LineAtOffset(endpoint);
            for (var line = first; line <= last && positions.Count < MultiSelectionSet.MaximumSelections; line++)
            {
                positions.Add(atEnd ? LineEnd(buffer.Text, index, line) : index.StartOffset(line));
            }
            if (rangeIndex == buffer.Selections.MainIndex)
            {
                mainPosition = atEnd ? LineEnd(buffer.Text, index, first) : index.StartOffset(first);
            }
        }
        if (!found || positions.Count == 0) return false;
        var ordered = positions.ToList();
        var main = mainPosition is null ? 0 : Math.Max(0, ordered.IndexOf(mainPosition.Value));
        return buffer.SetSelections(new MultiSelectionSet(
            ordered.Select(position => new TextSelection(position, position)), main));
    }

    public static bool ApplyPrimaryEdit(
        EditorBuffer buffer, string nativeAfter, TextSelection nativeAfterSelection)
    {
        if (buffer.Selections.Ranges.Count < 2) return false;
        var before = buffer.Text;
        var main = buffer.Selections.Main;
        var delta = nativeAfter.Length - before.Length;
        var insertedLength = delta + main.Length;
        var prefix = -1;
        var changeEnd = -1;
        var insertedEnd = -1;
        if (main.Length == 0 && delta < 0 && nativeAfterSelection.Length == 0)
        {
            var removed = -delta;
            if (nativeAfterSelection.Head == main.Head - removed)
            {
                prefix = main.Head - removed;
                changeEnd = main.Head;
                insertedEnd = prefix;
            }
            else if (nativeAfterSelection.Head == main.Head)
            {
                prefix = main.Head;
                changeEnd = Math.Min(before.Length, main.Head + removed);
                insertedEnd = prefix;
            }
        }
        else if (nativeAfterSelection.Length == 0 && insertedLength >= 0)
        {
            prefix = nativeAfterSelection.Head - insertedLength;
            changeEnd = main.End;
            insertedEnd = prefix + insertedLength;
        }
        if (prefix < 0 || insertedEnd < prefix || insertedEnd > nativeAfter.Length
            || !StringComparer.Ordinal.Equals(before[..prefix], nativeAfter[..prefix])
            || changeEnd < main.End
            || !StringComparer.Ordinal.Equals(before[changeEnd..], nativeAfter[insertedEnd..]))
        {
            prefix = 0;
            while (prefix < before.Length && prefix < nativeAfter.Length && before[prefix] == nativeAfter[prefix]) prefix++;
            var suffix = 0;
            while (suffix < before.Length - prefix && suffix < nativeAfter.Length - prefix
                && before[before.Length - suffix - 1] == nativeAfter[nativeAfter.Length - suffix - 1]) suffix++;
            if (prefix > 0 && prefix < before.Length && Char.IsLowSurrogate(before[prefix])) prefix--;
            changeEnd = before.Length - suffix;
            insertedEnd = nativeAfter.Length - suffix;
        }
        var removeBefore = main.Start - prefix;
        var removeAfter = changeEnd - main.End;
        if (removeBefore < 0 || removeAfter < 0 || removeBefore > 2 || removeAfter > 2) return false;
        var inserted = nativeAfter[prefix..insertedEnd];
        var edits = buffer.Selections.Ranges.Select((range, index) => new
        {
            Index = index,
            Start = Math.Max(0, range.Start - removeBefore),
            End = Math.Min(before.Length, range.End + removeAfter)
        }).OrderBy(edit => edit.Start).ToList();
        if (edits.Any(edit => !new TextSelection(edit.Start, edit.End).IsValidFor(before))) return false;
        for (var index = 1; index < edits.Count; index++) if (edits[index].Start < edits[index - 1].End) return false;
        var result = new StringBuilder(before);
        foreach (var edit in edits.AsEnumerable().Reverse())
        {
            result.Remove(edit.Start, edit.End - edit.Start);
            result.Insert(edit.Start, inserted);
        }
        var shift = 0;
        var selections = new TextSelection[edits.Count];
        foreach (var edit in edits)
        {
            var position = edit.Start + shift + inserted.Length;
            selections[edit.Index] = new TextSelection(position, position);
            shift += inserted.Length - (edit.End - edit.Start);
        }
        var next = new MultiSelectionSet(selections, buffer.Selections.MainIndex);
        return buffer.Apply(result.ToString(), next);
    }

    private static TextSelection? FindOccurrence(
        string text, string needle, int start, IReadOnlyList<TextSelection> excluded, bool wholeWord, int? before = null)
    {
        var limit = before ?? text.Length;
        for (var offset = Math.Clamp(start, 0, text.Length); offset <= limit - needle.Length;)
        {
            var found = text.IndexOf(needle, offset, StringComparison.Ordinal);
            if (found < 0 || found + needle.Length > limit) return null;
            var candidate = new TextSelection(found, found + needle.Length);
            if ((!wholeWord || IsWholeWord(text, candidate))
                && !excluded.Any(range => candidate.Start < range.End && range.Start < candidate.End)) return candidate;
            offset = found + Math.Max(1, needle.Length);
        }
        return null;
    }

    private static TextSelection? WordRange(string text, int rawOffset)
    {
        if (text.Length == 0) return null;
        var offset = Math.Clamp(rawOffset, 0, text.Length);
        if (offset == text.Length || !IsWord(text[offset])) offset--;
        if (offset < 0 || !IsWord(text[offset])) return null;
        var start = offset;
        var end = offset + 1;
        while (start > 0 && IsWord(text[start - 1])) start--;
        while (end < text.Length && IsWord(text[end])) end++;
        return new TextSelection(start, end);
    }

    private static bool IsWholeWord(string text, TextSelection range) =>
        (range.Start == 0 || !IsWord(text[range.Start - 1]))
        && (range.End == text.Length || !IsWord(text[range.End]));
    private static bool IsWord(char value) => Char.IsLetterOrDigit(value) || value is '_' or '$';
    private static int LineEnd(string text, SparseLineIndex index, int line)
    {
        var start = index.StartOffset(line);
        var newline = text.IndexOf('\n', start);
        return newline < 0 ? text.Length : newline > start && text[newline - 1] == '\r' ? newline - 1 : newline;
    }
}
