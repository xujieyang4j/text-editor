namespace LumenEditor.Windows.Core.Documents;

/// <summary>Minimal tab lifecycle; panes/session persistence layer builds upon this owner.</summary>
public sealed class DocumentWorkspace
{
    private readonly List<OpenedDocument> documents = [];
    public IReadOnlyList<OpenedDocument> Documents => documents;
    public OpenedDocument? ActiveDocument { get; private set; }

    public void AddOrActivate(IEnumerable<OpenedDocument> opened)
    {
        foreach (var document in opened)
        {
            var existing = documents.FirstOrDefault(candidate =>
                StringComparer.OrdinalIgnoreCase.Equals(candidate.Path, document.Path));
            if (existing is null)
            {
                documents.Add(document);
                ActiveDocument = document;
            }
            else ActiveDocument = existing;
        }
    }

    public OpenedDocument NewUntitled()
    {
        var next = 1;
        while (documents.Any(document => document.DisplayName == $"Untitled-{next}")) next++;
        var document = new OpenedDocument(
            $"untitled://{Guid.NewGuid():N}", $"Untitled-{next}", "", 0, IsDirty: true);
        documents.Add(document);
        ActiveDocument = document;
        return document;
    }

    public bool Activate(string path)
    {
        var document = documents.FirstOrDefault(candidate =>
            StringComparer.OrdinalIgnoreCase.Equals(candidate.Path, path));
        if (document is null) return false;
        ActiveDocument = document;
        return true;
    }

    public bool UpdateActiveContent(string content)
    {
        if (ActiveDocument is null) return false;
        var index = documents.IndexOf(ActiveDocument);
        if (index < 0) return false;
        ActiveDocument = ActiveDocument with { Content = content, IsDirty = true };
        documents[index] = ActiveDocument;
        return true;
    }

    public bool ReplaceActive(OpenedDocument replacement)
    {
        if (ActiveDocument is null) return false;
        var index = documents.IndexOf(ActiveDocument);
        if (index < 0) return false;
        documents[index] = replacement;
        ActiveDocument = replacement;
        return true;
    }

    public bool Replace(string path, OpenedDocument replacement)
    {
        var index = documents.FindIndex(document =>
            StringComparer.OrdinalIgnoreCase.Equals(document.Path, path));
        if (index < 0) return false;
        var wasActive = ReferenceEquals(ActiveDocument, documents[index])
            || StringComparer.OrdinalIgnoreCase.Equals(ActiveDocument?.Path, path);
        documents[index] = replacement;
        if (wasActive) ActiveDocument = replacement;
        return true;
    }

    public OpenedDocument? Find(string path) => documents.FirstOrDefault(document =>
        StringComparer.OrdinalIgnoreCase.Equals(document.Path, path));

    public bool TogglePin(string path)
    {
        var index = documents.FindIndex(document => StringComparer.OrdinalIgnoreCase.Equals(document.Path, path));
        if (index < 0) return false;
        var replacement = documents[index] with { IsPinned = !documents[index].IsPinned };
        documents[index] = replacement;
        if (StringComparer.OrdinalIgnoreCase.Equals(ActiveDocument?.Path, path)) ActiveDocument = replacement;
        return replacement.IsPinned;
    }

    public IReadOnlyList<DocumentPathChange> RemapPaths(string sourcePath, string targetPath)
    {
        var source = Path.GetFullPath(sourcePath);
        var target = Path.GetFullPath(targetPath);
        var changes = new List<DocumentPathChange>();
        for (var index = 0; index < documents.Count; index++)
        {
            var document = documents[index];
            if (document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)) continue;
            var path = Path.GetFullPath(document.Path);
            if (!Workspace.WorkspaceTree.IsInside(source, path)) continue;
            var relative = Path.GetRelativePath(source, path);
            var nextPath = relative == "." ? target : Path.Combine(target, relative);
            var replacement = document with { Path = nextPath, DisplayName = Path.GetFileName(nextPath) };
            documents[index] = replacement;
            if (StringComparer.OrdinalIgnoreCase.Equals(ActiveDocument?.Path, document.Path)) ActiveDocument = replacement;
            changes.Add(new(document.Path, nextPath));
        }
        return changes;
    }

    public void Restore(IEnumerable<OpenedDocument> restored, string? activePath)
    {
        documents.Clear();
        documents.AddRange(restored);
        ActiveDocument = activePath is null
            ? documents.FirstOrDefault()
            : documents.FirstOrDefault(document =>
                StringComparer.OrdinalIgnoreCase.Equals(document.Path, activePath))
                ?? documents.FirstOrDefault();
        if (ActiveDocument is null) NewUntitled();
    }

    public bool Close(string path)
    {
        var index = documents.FindIndex(document => StringComparer.OrdinalIgnoreCase.Equals(document.Path, path));
        if (index < 0) return false;
        var closing = documents[index];
        documents.RemoveAt(index);
        if (ActiveDocument?.Path == closing.Path)
        {
            ActiveDocument = documents.ElementAtOrDefault(Math.Min(index, Math.Max(0, documents.Count - 1)));
        }
        if (ActiveDocument is null) NewUntitled();
        return true;
    }

    public bool Next(bool reverse = false)
    {
        if (documents.Count < 2 || ActiveDocument is null) return false;
        var index = documents.IndexOf(ActiveDocument);
        if (index < 0) return false;
        index = reverse ? (index + documents.Count - 1) % documents.Count : (index + 1) % documents.Count;
        ActiveDocument = documents[index];
        return true;
    }

    public IReadOnlyList<OpenedDocument> DocumentsAfter(string path)
    {
        var index = documents.FindIndex(document => StringComparer.OrdinalIgnoreCase.Equals(document.Path, path));
        return index < 0 ? [] : documents.Skip(index + 1).ToList();
    }
}

public sealed record DocumentPathChange(string PreviousPath, string CurrentPath);
