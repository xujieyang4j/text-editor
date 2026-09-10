using System.Text.Json;

namespace LumenEditor.Windows.Core.Recent;

public sealed record RecentItems(IReadOnlyList<string> Files, IReadOnlyList<string> Projects);

public sealed class RecentItemsStore(string path)
{
    public const int MaximumItems = 50;
    public const int MaximumSerializedBytes = 1024 * 1024;

    public async Task<RecentItems> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaximumSerializedBytes) return new([], []);
            var value = JsonSerializer.Deserialize<RecentItems>(await File.ReadAllBytesAsync(path, cancellationToken));
            return Sanitize(value);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return new([], []); }
    }

    public Task<RecentItems> AddFileAsync(string file, CancellationToken cancellationToken = default) =>
        UpdateAsync(file, project: false, cancellationToken);

    public Task<RecentItems> AddProjectAsync(string project, CancellationToken cancellationToken = default) =>
        UpdateAsync(project, project: true, cancellationToken);

    private async Task<RecentItems> UpdateAsync(string item, bool project, CancellationToken cancellationToken)
    {
        var current = await LoadAsync(cancellationToken);
        var normalized = Path.GetFullPath(item);
        var files = current.Files.ToList();
        var projects = current.Projects.ToList();
        var target = project ? projects : files;
        target.RemoveAll(candidate => StringComparer.OrdinalIgnoreCase.Equals(candidate, normalized));
        target.Insert(0, normalized);
        if (target.Count > MaximumItems) target.RemoveRange(MaximumItems, target.Count - MaximumItems);
        var next = Sanitize(new(files, projects));
        var bytes = JsonSerializer.SerializeToUtf8Bytes(next);
        var directory = Path.GetDirectoryName(path) ?? throw new InvalidOperationException("Recent-items path has no directory.");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, cancellationToken);
            if (File.Exists(path)) File.Replace(temporary, path, null, true);
            else File.Move(temporary, path);
            temporary = String.Empty;
        }
        finally { if (temporary.Length > 0) File.Delete(temporary); }
        return next;
    }

    private static RecentItems Sanitize(RecentItems? value)
    {
        static IReadOnlyList<string> Valid(IEnumerable<string>? items, bool directory) => (items ?? [])
            .Where(item => !String.IsNullOrWhiteSpace(item) && item.Length <= 32 * 1024)
            .Select(item =>
            {
                try { return Path.GetFullPath(item); }
                catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException) { return null; }
            })
            .Where(item => item is not null && (directory ? Directory.Exists(item) : File.Exists(item)))
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(MaximumItems)
            .ToList();
        return new(Valid(value?.Files, false), Valid(value?.Projects, true));
    }
}
