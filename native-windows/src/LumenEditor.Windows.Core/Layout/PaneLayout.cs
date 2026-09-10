namespace LumenEditor.Windows.Core.Layout;

public enum PaneLayoutKind { Single, Columns2, Columns3, Grid4 }

public sealed record PaneSnapshot(IReadOnlyList<string> Documents, string? ActiveDocument);
public sealed record PaneLayoutSnapshot(PaneLayoutKind Kind, int ActivePane, IReadOnlyList<PaneSnapshot> Panes);

/// <summary>Document-to-pane layout model with deterministic move/clone/focus semantics.</summary>
public sealed class PaneLayout
{
    private readonly List<List<string>> panes = [[ ]];
    private readonly List<string?> activeDocuments = [null];
    public PaneLayoutKind Kind { get; private set; } = PaneLayoutKind.Single;
    public int ActivePane { get; private set; }
    public IReadOnlyList<IReadOnlyList<string>> Panes => panes;
    public IReadOnlyList<string?> ActiveDocuments => activeDocuments;
    public string? ActiveDocument => activeDocuments[ActivePane];

    public void SetKind(PaneLayoutKind kind)
    {
        var previouslyActiveDocument = ActiveDocument;
        var count = kind switch { PaneLayoutKind.Single => 1, PaneLayoutKind.Columns2 => 2, PaneLayoutKind.Columns3 => 3, _ => 4 };
        while (panes.Count < count)
        {
            panes.Add([]);
            activeDocuments.Add(null);
        }
        while (panes.Count > count)
        {
            var removed = panes[^1];
            panes.RemoveAt(panes.Count - 1);
            panes[0].AddRange(removed.Where(id => !panes[0].Contains(id, StringComparer.Ordinal)));
            activeDocuments.RemoveAt(activeDocuments.Count - 1);
        }
        if (count == 1 && previouslyActiveDocument is not null
            && panes[0].Contains(previouslyActiveDocument, StringComparer.Ordinal))
        {
            activeDocuments[0] = previouslyActiveDocument;
        }
        else activeDocuments[0] ??= panes[0].FirstOrDefault();
        Kind = kind;
        ActivePane = Math.Min(ActivePane, panes.Count - 1);
    }

    public bool AddToActive(string documentId)
    {
        if (panes[ActivePane].Contains(documentId, StringComparer.Ordinal)) return false;
        panes[ActivePane].Add(documentId);
        activeDocuments[ActivePane] = documentId;
        return true;
    }

    public bool Activate(string documentId, int? paneIndex = null)
    {
        var target = paneIndex ?? ActivePane;
        if (target < 0 || target >= panes.Count) return false;
        if (!panes[target].Contains(documentId, StringComparer.Ordinal)) panes[target].Add(documentId);
        ActivePane = target;
        activeDocuments[target] = documentId;
        return true;
    }

    public bool SetActivePane(int paneIndex)
    {
        if (paneIndex < 0 || paneIndex >= panes.Count) return false;
        ActivePane = paneIndex;
        return true;
    }

    public bool MoveToNext(string documentId, bool clone)
    {
        var source = panes[ActivePane].Contains(documentId, StringComparer.Ordinal)
            ? ActivePane
            : panes.FindIndex(pane => pane.Contains(documentId, StringComparer.Ordinal));
        if (source < 0 || panes.Count == 1) return false;
        var target = (source + 1) % panes.Count;
        if (!clone)
        {
            panes[source].Remove(documentId);
            if (StringComparer.Ordinal.Equals(activeDocuments[source], documentId))
            {
                activeDocuments[source] = panes[source].LastOrDefault();
            }
        }
        if (!panes[target].Contains(documentId, StringComparer.Ordinal)) panes[target].Add(documentId);
        ActivePane = target;
        activeDocuments[target] = documentId;
        return true;
    }

    /// <summary>
    /// Displays up to four selected documents side by side, ordered by their
    /// position in the active pane. Documents that are not split remain in
    /// their existing panes. With fewer than two valid selections, the active
    /// document is cloned to the next pane, matching the cross-platform
    /// command fallback.
    /// </summary>
    public bool SplitSelectedTabs(IEnumerable<string> selectedDocumentIds)
    {
        ArgumentNullException.ThrowIfNull(selectedDocumentIds);
        var selected = selectedDocumentIds.ToHashSet(StringComparer.Ordinal);
        var ordered = panes[ActivePane].Where(selected.Contains).Take(4).ToList();
        if (ordered.Count < 2)
        {
            var active = ActiveDocument;
            if (active is null) return false;
            if (Kind == PaneLayoutKind.Single) SetKind(PaneLayoutKind.Columns2);
            return MoveToNext(active, clone: true);
        }

        var seed = ActiveDocument;
        SetKind(ordered.Count switch
        {
            2 => PaneLayoutKind.Columns2,
            3 => PaneLayoutKind.Columns3,
            _ => PaneLayoutKind.Grid4
        });
        if (seed is not null)
        {
            for (var index = 0; index < panes.Count; index++)
            {
                if (panes[index].Count == 0) Activate(seed, index);
            }
        }
        for (var index = 0; index < ordered.Count; index++)
        {
            Activate(ordered[index], index);
        }
        ActivePane = 0;
        return true;
    }

    public bool Remove(string documentId)
    {
        var removed = false;
        for (var index = 0; index < panes.Count; index++)
        {
            removed |= panes[index].Remove(documentId);
            if (StringComparer.Ordinal.Equals(activeDocuments[index], documentId))
            {
                activeDocuments[index] = panes[index].LastOrDefault();
            }
        }
        return removed;
    }

    public bool RemoveFromPane(string documentId, int? paneIndex = null)
    {
        var target = paneIndex ?? ActivePane;
        if (target < 0 || target >= panes.Count || !panes[target].Remove(documentId)) return false;
        if (StringComparer.Ordinal.Equals(activeDocuments[target], documentId))
        {
            activeDocuments[target] = panes[target].LastOrDefault();
        }
        return true;
    }

    public bool Contains(string documentId) => panes.Any(pane =>
        pane.Contains(documentId, StringComparer.Ordinal));

    public bool RenameDocument(string previousId, string nextId)
    {
        if (StringComparer.Ordinal.Equals(previousId, nextId)) return Contains(previousId);
        var renamed = false;
        for (var paneIndex = 0; paneIndex < panes.Count; paneIndex++)
        {
            for (var documentIndex = panes[paneIndex].Count - 1; documentIndex >= 0; documentIndex--)
            {
                if (!StringComparer.Ordinal.Equals(panes[paneIndex][documentIndex], previousId)) continue;
                if (panes[paneIndex].Contains(nextId, StringComparer.Ordinal)) panes[paneIndex].RemoveAt(documentIndex);
                else panes[paneIndex][documentIndex] = nextId;
                renamed = true;
            }
            if (StringComparer.Ordinal.Equals(activeDocuments[paneIndex], previousId))
            {
                activeDocuments[paneIndex] = nextId;
            }
        }
        return renamed;
    }

    public void Reset(IEnumerable<string> documentIds, string? activeDocument = null)
    {
        panes.Clear();
        activeDocuments.Clear();
        var documents = documentIds.Distinct(StringComparer.Ordinal).ToList();
        panes.Add(documents);
        activeDocuments.Add(activeDocument is not null && documents.Contains(activeDocument, StringComparer.Ordinal)
            ? activeDocument
            : documents.FirstOrDefault());
        Kind = PaneLayoutKind.Single;
        ActivePane = 0;
    }

    public PaneLayoutSnapshot Snapshot() => new(
        Kind,
        ActivePane,
        panes.Select((pane, index) => new PaneSnapshot(pane.ToList(), activeDocuments[index])).ToList());

    public void Restore(PaneLayoutSnapshot? snapshot, IEnumerable<string> validDocumentIds, string? fallbackActive)
    {
        var valid = validDocumentIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (snapshot is null || snapshot.Panes.Count is < 1 or > 4)
        {
            Reset(validDocumentIds, fallbackActive);
            return;
        }
        panes.Clear();
        activeDocuments.Clear();
        foreach (var savedPane in snapshot.Panes.Take(PaneCount(snapshot.Kind)))
        {
            var documents = savedPane.Documents.Where(valid.Contains)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            panes.Add(documents);
            activeDocuments.Add(savedPane.ActiveDocument is not null
                && documents.Contains(savedPane.ActiveDocument, StringComparer.OrdinalIgnoreCase)
                    ? documents.First(document => StringComparer.OrdinalIgnoreCase.Equals(document, savedPane.ActiveDocument))
                    : documents.FirstOrDefault());
        }
        while (panes.Count < PaneCount(snapshot.Kind))
        {
            panes.Add([]);
            activeDocuments.Add(null);
        }
        var assigned = panes.SelectMany(pane => pane).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var document in validDocumentIds.Where(document => !assigned.Contains(document))) panes[0].Add(document);
        activeDocuments[0] ??= panes[0].FirstOrDefault();
        Kind = snapshot.Kind;
        ActivePane = Math.Clamp(snapshot.ActivePane, 0, panes.Count - 1);
        if (activeDocuments[ActivePane] is null && fallbackActive is not null && valid.Contains(fallbackActive))
        {
            Activate(fallbackActive, ActivePane);
        }
    }

    private static int PaneCount(PaneLayoutKind kind) => kind switch
    {
        PaneLayoutKind.Single => 1,
        PaneLayoutKind.Columns2 => 2,
        PaneLayoutKind.Columns3 => 3,
        _ => 4
    };

    public void FocusNext(bool reverse = false)
    {
        ActivePane = reverse ? (ActivePane + panes.Count - 1) % panes.Count : (ActivePane + 1) % panes.Count;
    }
}
