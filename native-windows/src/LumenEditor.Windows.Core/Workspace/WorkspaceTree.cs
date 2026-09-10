namespace LumenEditor.Windows.Core.Workspace;

public sealed record WorkspaceEntry(string FullPath, string Name, bool IsDirectory, long? ByteLength = null);

/// <summary>Root-confined bounded directory reader for a Windows workspace sidebar.</summary>
public sealed class WorkspaceTree
{
    public const int MaximumEntriesPerDirectory = 20_000;
    private static readonly HashSet<string> IgnoredNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", "node_modules", ".DS_Store", ".cache", "dist", "out", "release", ".npm-cache", ".lumen-project.json"
    };

    public IReadOnlyList<WorkspaceEntry> ReadChildren(
        string root, string directory, WorkspaceExclusionPolicy? exclusions = null)
    {
        var canonicalRoot = Path.GetFullPath(root);
        var canonicalDirectory = Path.GetFullPath(directory);
        if (!IsInside(canonicalRoot, canonicalDirectory) || !Directory.Exists(canonicalDirectory)) return [];
        try
        {
            return Directory.EnumerateFileSystemEntries(canonicalDirectory)
                .Take(MaximumEntriesPerDirectory + 1)
                .Select(ToEntry)
                .Where(entry => entry is not null && !IgnoredNames.Contains(entry.Name))
                .Cast<WorkspaceEntry>()
                .Where(entry => !(exclusions ?? WorkspaceExclusionPolicy.Empty)
                    .IsExcluded(canonicalRoot, entry.FullPath, entry.IsDirectory))
                .OrderByDescending(entry => entry.IsDirectory)
                .ThenBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase)
                .Take(MaximumEntriesPerDirectory)
                .ToList();
        }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    public static bool IsInside(string root, string candidate)
    {
        var relative = Path.GetRelativePath(Path.GetFullPath(root), Path.GetFullPath(candidate));
        return relative == "." || (!relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            && relative != ".." && !Path.IsPathRooted(relative));
    }

    private static WorkspaceEntry? ToEntry(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0) return null;
        var isDirectory = (attributes & FileAttributes.Directory) != 0;
        return new(path, Path.GetFileName(path), isDirectory, isDirectory ? null : new FileInfo(path).Length);
    }
}
