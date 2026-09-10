namespace LumenEditor.Windows.Core.Workspace;

public static class WorkspaceFileOperations
{
    public const int MaximumNameCharacters = 255;

    public static string ResolveNewChild(string root, string parentDirectory, string name)
    {
        var canonicalRoot = Path.GetFullPath(root);
        var parent = Path.GetFullPath(parentDirectory);
        if (!WorkspaceTree.IsInside(canonicalRoot, parent) || !Directory.Exists(parent))
        {
            throw new InvalidOperationException("The parent directory is outside the workspace.");
        }
        var leaf = ValidateLeafName(name);
        var target = Path.GetFullPath(Path.Combine(parent, leaf));
        if (!WorkspaceTree.IsInside(canonicalRoot, target))
        {
            throw new InvalidOperationException("The target path is outside the workspace.");
        }
        return target;
    }

    public static async Task<string> CreateFileAsync(
        string root, string parentDirectory, string name, CancellationToken cancellationToken = default)
    {
        var target = ResolveNewChild(root, parentDirectory, name);
        await using var stream = new FileStream(
            target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4_096, useAsync: true);
        await stream.FlushAsync(cancellationToken);
        return target;
    }

    public static string CreateDirectory(string root, string parentDirectory, string name)
    {
        var target = ResolveNewChild(root, parentDirectory, name);
        if (File.Exists(target) || Directory.Exists(target)) throw new IOException("The target already exists.");
        Directory.CreateDirectory(target);
        return target;
    }

    public static string Rename(string root, string sourcePath, string newName)
    {
        var canonicalRoot = Path.GetFullPath(root);
        var source = Path.GetFullPath(sourcePath);
        if (!WorkspaceTree.IsInside(canonicalRoot, source) || StringComparer.OrdinalIgnoreCase.Equals(canonicalRoot, source))
        {
            throw new InvalidOperationException("The source path cannot be renamed from this workspace.");
        }
        if (!File.Exists(source) && !Directory.Exists(source)) throw new FileNotFoundException("The source no longer exists.", source);
        var attributes = File.GetAttributes(source);
        if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Reparse points cannot be renamed.");
        var parent = Path.GetDirectoryName(source) ?? throw new InvalidOperationException("The source has no parent directory.");
        var target = ResolveNewChild(canonicalRoot, parent, newName);
        if (File.Exists(target) || Directory.Exists(target)) throw new IOException("The target already exists.");
        if ((attributes & FileAttributes.Directory) != 0) Directory.Move(source, target);
        else File.Move(source, target);
        return target;
    }

    public static bool IsSafeTrashTarget(string root, string path)
    {
        try
        {
            var canonicalRoot = Path.GetFullPath(root);
            var target = Path.GetFullPath(path);
            if (StringComparer.OrdinalIgnoreCase.Equals(canonicalRoot, target)
                || !WorkspaceTree.IsInside(canonicalRoot, target)
                || (!File.Exists(target) && !Directory.Exists(target))) return false;
            return (File.GetAttributes(target) & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return false;
        }
    }

    private static string ValidateLeafName(string name)
    {
        var leaf = name.Trim();
        if (leaf.Length is 0 or > MaximumNameCharacters || leaf is "." or ".."
            || leaf.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || leaf.Contains(Path.DirectorySeparatorChar) || leaf.Contains(Path.AltDirectorySeparatorChar))
        {
            throw new ArgumentException("Enter a valid file or folder name.", nameof(name));
        }
        return leaf;
    }
}
