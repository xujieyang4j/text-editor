namespace LumenEditor.Windows.Core.Workspace;

public enum WorkspaceChangeKind { Changed, Created, Deleted, Renamed, Overflow }

public sealed record WorkspaceChange(string Path, WorkspaceChangeKind Kind);

public sealed record WorkspaceChangeBatch(IReadOnlyList<WorkspaceChange> Changes, bool IsOverflow);

/// <summary>Root-confined, bounded accumulator shared by the native watcher and tests.</summary>
public sealed class WorkspaceChangeAccumulator
{
    public const int MaximumChanges = 4_096;
    private readonly string root;
    private readonly WorkspaceExclusionPolicy exclusions;
    private readonly Dictionary<string, WorkspaceChangeKind> changes = new(StringComparer.OrdinalIgnoreCase);
    private bool overflow;

    public WorkspaceChangeAccumulator(string root, WorkspaceExclusionPolicy? exclusions = null)
    {
        this.root = Path.GetFullPath(root);
        this.exclusions = exclusions ?? WorkspaceExclusionPolicy.Empty;
    }

    public void Add(string path, WorkspaceChangeKind kind)
    {
        string fullPath;
        try { fullPath = Path.GetFullPath(path); }
        catch (ArgumentException) { return; }
        catch (IOException) { return; }
        catch (NotSupportedException) { return; }
        if (!WorkspaceTree.IsInside(root, fullPath)) return;
        // The settings file must always reach the shell so a changed exclusion
        // snapshot can replace this watcher's policy. Treating paths as
        // possible directories also filters deletion events after their type
        // can no longer be queried from disk.
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetFileName(fullPath), ".lumen-project.json")
            && exclusions.IsExcluded(root, fullPath, isDirectory: true)) return;
        if (changes.Count >= MaximumChanges && !changes.ContainsKey(fullPath))
        {
            overflow = true;
            return;
        }
        changes[fullPath] = kind;
    }

    public void MarkOverflow() => overflow = true;

    public WorkspaceChangeBatch Drain()
    {
        var result = changes
            .OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase)
            .Select(entry => new WorkspaceChange(entry.Key, entry.Value))
            .ToList();
        var wasOverflow = overflow;
        changes.Clear();
        overflow = false;
        return new(result, wasOverflow);
    }
}

/// <summary>Recursive Windows workspace watcher with debounced, bounded delivery.</summary>
public sealed class WorkspaceFileWatcher : IDisposable
{
    public static readonly TimeSpan DefaultDebounce = TimeSpan.FromMilliseconds(250);
    private readonly object gate = new();
    private readonly WorkspaceChangeAccumulator accumulator;
    private readonly Action<WorkspaceChangeBatch> callback;
    private readonly FileSystemWatcher watcher;
    private readonly Timer timer;
    private bool disposed;

    public WorkspaceFileWatcher(
        string root,
        Action<WorkspaceChangeBatch> callback,
        TimeSpan? debounce = null,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        var fullRoot = Path.GetFullPath(root);
        if (!Path.IsPathFullyQualified(fullRoot) || !Directory.Exists(fullRoot))
        {
            throw new DirectoryNotFoundException($"Workspace root does not exist: {fullRoot}");
        }
        this.callback = callback ?? throw new ArgumentNullException(nameof(callback));
        accumulator = new WorkspaceChangeAccumulator(fullRoot, exclusions);
        timer = new Timer(_ => Flush(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        watcher = new FileSystemWatcher(fullRoot)
        {
            IncludeSubdirectories = true,
            InternalBufferSize = 64 * 1024,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName
                | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime
        };
        watcher.Changed += (_, args) => Queue(args.FullPath, WorkspaceChangeKind.Changed);
        watcher.Created += (_, args) => Queue(args.FullPath, WorkspaceChangeKind.Created);
        watcher.Deleted += (_, args) => Queue(args.FullPath, WorkspaceChangeKind.Deleted);
        watcher.Renamed += (_, args) =>
        {
            Queue(args.OldFullPath, WorkspaceChangeKind.Deleted);
            Queue(args.FullPath, WorkspaceChangeKind.Renamed);
        };
        watcher.Error += (_, _) => Queue(fullRoot, WorkspaceChangeKind.Overflow, isOverflow: true);
        watcher.EnableRaisingEvents = true;
        Debounce = debounce ?? DefaultDebounce;
    }

    public TimeSpan Debounce { get; }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            watcher.EnableRaisingEvents = false;
            watcher.Dispose();
            timer.Dispose();
        }
    }

    private void Queue(string path, WorkspaceChangeKind kind, bool isOverflow = false)
    {
        lock (gate)
        {
            if (disposed) return;
            if (isOverflow) accumulator.MarkOverflow();
            else accumulator.Add(path, kind);
            timer.Change(Debounce, Timeout.InfiniteTimeSpan);
        }
    }

    private void Flush()
    {
        WorkspaceChangeBatch batch;
        lock (gate)
        {
            if (disposed) return;
            batch = accumulator.Drain();
        }
        if (batch.Changes.Count == 0 && !batch.IsOverflow) return;
        try { callback(batch); }
        catch
        {
            // A consumer failure must not terminate FileSystemWatcher delivery.
        }
    }
}
