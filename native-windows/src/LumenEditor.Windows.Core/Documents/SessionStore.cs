using System.Text.Json;
using LumenEditor.Windows.Core.Workspace;
using LumenEditor.Windows.Core.Layout;

namespace LumenEditor.Windows.Core.Documents;

public sealed record SessionDocument(
    string Path, string DisplayName, string? Draft, TextEncodingKind Encoding, LineEnding LineEnding,
    string? Revision, IReadOnlyList<int>? Bookmarks = null, bool IsPinned = false);

public sealed record DocumentSession(
    int FormatVersion,
    IReadOnlyList<SessionDocument> Documents,
    string? ActivePath,
    IReadOnlyList<string>? Folders = null,
    PaneLayoutSnapshot? Layout = null)
{
    public const int CurrentFormatVersion = 3;
    public const int MaximumDocuments = 100;
    public const int MaximumDraftBytes = 200 * 1024 * 1024;
}

/// <summary>Best-effort hot-exit store: bounded data and atomic writes never block a future app launch.</summary>
public sealed class SessionStore
{
    public SessionStore(string path) => Path = path;
    public string Path { get; }

    public async Task<DocumentSession> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var info = new FileInfo(Path);
            if (!info.Exists || info.Length > DocumentSession.MaximumDraftBytes + 8 * 1024 * 1024) return Empty();
            await using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, true);
            var session = await JsonSerializer.DeserializeAsync<DocumentSession>(stream, cancellationToken: cancellationToken);
            return Sanitize(session);
        }
        catch (JsonException) { return Empty(); }
        catch (IOException) { return Empty(); }
        catch (UnauthorizedAccessException) { return Empty(); }
    }

    public async Task SaveAsync(DocumentSession session, CancellationToken cancellationToken = default)
    {
        var sanitized = Sanitize(session);
        var data = JsonSerializer.SerializeToUtf8Bytes(sanitized);
        if (data.Length > DocumentSession.MaximumDraftBytes + 8 * 1024 * 1024) throw new InvalidOperationException("Session snapshot exceeds the maximum size.");
        var directory = System.IO.Path.GetDirectoryName(Path) ?? throw new InvalidOperationException("Session path has no directory.");
        Directory.CreateDirectory(directory);
        var temporary = System.IO.Path.Combine(directory, $".{System.IO.Path.GetFileName(Path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllBytesAsync(temporary, data, cancellationToken);
            if (File.Exists(Path)) File.Replace(temporary, Path, destinationBackupFileName: null, ignoreMetadataErrors: true);
            else File.Move(temporary, Path);
            temporary = string.Empty;
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporary)) File.Delete(temporary);
        }
    }

    private static DocumentSession Empty() => new(DocumentSession.CurrentFormatVersion, [], null, []);

    private static DocumentSession Sanitize(DocumentSession? source)
    {
        var documents = (source?.Documents ?? [])
            .Where(document => !string.IsNullOrWhiteSpace(document.Path) && document.Path.Length <= 32 * 1024)
            .Take(DocumentSession.MaximumDocuments)
            .ToList();
        var bytes = 0;
        var bounded = new List<SessionDocument>();
        foreach (var document in documents)
        {
            var draft = document.Draft;
            if (draft is not null)
            {
                var draftBytes = System.Text.Encoding.UTF8.GetByteCount(draft);
                if (bytes + draftBytes > DocumentSession.MaximumDraftBytes) continue;
                bytes += draftBytes;
            }
            bounded.Add(document with
            {
                Bookmarks = (document.Bookmarks ?? [])
                    .Where(line => line > 0)
                    .Distinct()
                    .Order()
                    .Take(Navigation.BookmarkSet.MaximumBookmarks)
                    .ToList()
            });
        }
        var active = bounded.Any(document => StringComparer.OrdinalIgnoreCase.Equals(document.Path, source?.ActivePath))
            ? source?.ActivePath : bounded.FirstOrDefault()?.Path;
        var folders = WorkspaceRoots.Normalize(source?.Folders ?? []);
        return new(DocumentSession.CurrentFormatVersion, bounded, active, folders, source?.Layout);
    }
}
