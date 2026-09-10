namespace LumenEditor.Windows.Core.Navigation;

public sealed class BookmarkSet
{
    public const int MaximumBookmarks = 10_000;
    private readonly SortedSet<int> lines = [];
    public IReadOnlyList<int> Lines => lines.ToList();

    public bool Toggle(int line)
    {
        line = Math.Max(1, line);
        if (lines.Remove(line)) return false;
        if (lines.Count >= MaximumBookmarks) return false;
        lines.Add(line);
        return true;
    }

    public int? Next(int currentLine, bool reverse = false)
    {
        if (lines.Count == 0) return null;
        if (reverse)
        {
            var previous = lines.LastOrDefault(line => line < currentLine);
            return previous > 0 ? previous : lines.Max;
        }
        var next = lines.FirstOrDefault(line => line > currentLine);
        return next > 0 ? next : lines.Min;
    }

    public void Restore(IEnumerable<int> savedLines, int maximumLine)
    {
        lines.Clear();
        foreach (var line in savedLines.Where(line => line >= 1 && line <= Math.Max(1, maximumLine)).Take(MaximumBookmarks))
        {
            lines.Add(line);
        }
    }
}
