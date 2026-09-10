namespace LumenEditor.Windows.Core.Workspace;

public static class WorkspaceRoots
{
    public const int MaximumRoots = 12;

    public static IReadOnlyList<string> Normalize(IEnumerable<string> roots)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots)
        {
            if (result.Count >= MaximumRoots) break;
            if (String.IsNullOrWhiteSpace(root)) continue;
            try
            {
                var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
                if (!Directory.Exists(full) || !seen.Add(full)) continue;
                result.Add(full);
            }
            catch (ArgumentException) { }
            catch (IOException) { }
            catch (NotSupportedException) { }
        }
        return result;
    }

    public static bool Contains(string root, string path) => WorkspaceTree.IsInside(root, path);
}
