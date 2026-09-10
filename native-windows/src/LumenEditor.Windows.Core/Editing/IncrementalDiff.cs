namespace LumenEditor.Windows.Core.Editing;

public enum IncrementalChangeKind { Added, Modified, Deleted }

public sealed record IncrementalChange(
    IncrementalChangeKind Kind,
    int Line,
    int LineCount,
    int BaseStart,
    IReadOnlyList<string> BaseLines,
    IReadOnlyList<string> CurrentLines);

/// <summary>Bounded line diff used for saved-file change navigation and one-hunk reverts.</summary>
public static class IncrementalDiff
{
    public const int MaximumLines = 2_000;

    public static IReadOnlyList<IncrementalChange> Compute(
        string baseline, string current, int maximumLines = MaximumLines)
    {
        var before = Lines(baseline);
        var after = Lines(current);
        var limit = Math.Clamp(maximumLines, 0, MaximumLines);
        if (before.Length > limit || after.Length > limit) return [];

        var table = new ushort[before.Length + 1, after.Length + 1];
        for (var left = before.Length - 1; left >= 0; left--)
        {
            for (var right = after.Length - 1; right >= 0; right--)
            {
                table[left, right] = before[left] == after[right]
                    ? checked((ushort)(table[left + 1, right + 1] + 1))
                    : Math.Max(table[left + 1, right], table[left, right + 1]);
            }
        }

        var changes = new List<IncrementalChange>();
        var beforeIndex = 0;
        var afterIndex = 0;
        var baseStart = 0;
        var currentStart = 0;
        var removed = new List<string>();
        var added = new List<string>();
        void Flush()
        {
            if (removed.Count == 0 && added.Count == 0) return;
            changes.Add(new(
                removed.Count > 0 && added.Count > 0 ? IncrementalChangeKind.Modified
                    : added.Count > 0 ? IncrementalChangeKind.Added : IncrementalChangeKind.Deleted,
                currentStart + 1,
                added.Count,
                baseStart,
                removed.ToList(),
                added.ToList()));
            removed.Clear();
            added.Clear();
        }

        while (beforeIndex < before.Length || afterIndex < after.Length)
        {
            if (beforeIndex < before.Length && afterIndex < after.Length
                && before[beforeIndex] == after[afterIndex])
            {
                Flush();
                beforeIndex++;
                afterIndex++;
                baseStart = beforeIndex;
                currentStart = afterIndex;
            }
            else if (afterIndex < after.Length && (beforeIndex == before.Length
                || table[beforeIndex, afterIndex + 1] >= table[beforeIndex + 1, afterIndex]))
            {
                added.Add(after[afterIndex++]);
            }
            else
            {
                removed.Add(before[beforeIndex++]);
            }
        }
        Flush();
        return changes;
    }

    public static string Revert(string current, IncrementalChange change)
    {
        var lines = Lines(current).ToList();
        var index = Math.Clamp(change.Line - 1, 0, lines.Count);
        var count = Math.Clamp(change.LineCount, 0, lines.Count - index);
        lines.RemoveRange(index, count);
        lines.InsertRange(index, change.BaseLines);
        return String.Join('\n', lines);
    }

    private static string[] Lines(string text) => text.Length == 0 ? [] : text.Split('\n');
}
