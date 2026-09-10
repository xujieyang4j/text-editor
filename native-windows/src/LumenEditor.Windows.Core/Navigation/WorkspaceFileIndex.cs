using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Navigation;

public sealed record WorkspaceFileMatch(string Path, string RelativePath, int Score);

public static class WorkspaceFileIndex
{
    public const int MaximumFiles = 20_000;
    public const int MaximumResults = 200;

    public static IReadOnlyList<string> EnumerateFiles(
        IEnumerable<string> roots, WorkspaceTree tree, WorkspaceExclusionPolicy? exclusions = null)
    {
        var files = new List<string>();
        foreach (var root in WorkspaceRoots.Normalize(roots))
        {
            var directories = new Stack<string>();
            directories.Push(root);
            while (directories.Count > 0 && files.Count < MaximumFiles)
            {
                var directory = directories.Pop();
                foreach (var entry in tree.ReadChildren(root, directory, exclusions))
                {
                    if (entry.IsDirectory) directories.Push(entry.FullPath);
                    else files.Add(entry.FullPath);
                    if (files.Count >= MaximumFiles) break;
                }
            }
            if (files.Count >= MaximumFiles) break;
        }
        return files;
    }

    public static IReadOnlyList<WorkspaceFileMatch> Search(
        IEnumerable<string> roots, WorkspaceTree tree, string query,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        var normalizedRoots = WorkspaceRoots.Normalize(roots);
        var needle = query.Trim();
        return SearchFiles(EnumerateFiles(normalizedRoots, tree, exclusions), normalizedRoots, needle);
    }

    public static IReadOnlyList<WorkspaceFileMatch> SearchFiles(
        IEnumerable<string> files, IReadOnlyList<string> roots, string query)
    {
        var needle = query.Trim();
        return files
            .Select(path =>
            {
                var root = roots.FirstOrDefault(candidate => WorkspaceTree.IsInside(candidate, path));
                if (root is null) return null;
                var relative = Path.GetRelativePath(root, path);
                return new WorkspaceFileMatch(path, relative, Score(relative, needle));
            })
            .Where(match => match is not null && (needle.Length == 0 || match.Score >= 0))
            .Cast<WorkspaceFileMatch>()
            .OrderByDescending(match => match.Score)
            .ThenBy(match => match.RelativePath, StringComparer.OrdinalIgnoreCase)
            .Take(MaximumResults)
            .ToList();
    }

    public static int Score(string candidate, string query)
    {
        if (query.Length == 0) return 0;
        var score = 0;
        var cursor = 0;
        var previous = -2;
        foreach (var requested in query)
        {
            var found = candidate.IndexOf(requested.ToString(), cursor, StringComparison.OrdinalIgnoreCase);
            if (found < 0) return -1;
            score += found == previous + 1 ? 8 : 1;
            if (found == 0 || candidate[found - 1] is '/' or '\\' or '-' or '_' or '.') score += 6;
            previous = found;
            cursor = found + 1;
        }
        return score - candidate.Length / 10;
    }
}
