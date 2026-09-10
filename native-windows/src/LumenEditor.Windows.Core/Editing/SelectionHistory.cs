namespace LumenEditor.Windows.Core.Editing;

/// <summary>Bounded selection-only history, independent from text undo/redo.</summary>
public sealed class SelectionHistory
{
    public const int MaximumEntries = 1_000;
    private readonly Stack<MultiSelectionSet> undo = new();
    private readonly Stack<MultiSelectionSet> redo = new();

    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public void Observe(TextSelection previous, TextSelection current)
        => Observe(MultiSelectionSet.Single(previous), MultiSelectionSet.Single(current));

    public void Observe(MultiSelectionSet previous, MultiSelectionSet current)
    {
        if (previous.Equals(current)) return;
        undo.Push(previous);
        Trim(undo);
        redo.Clear();
    }

    public TextSelection? Undo(TextSelection current) => Undo(MultiSelectionSet.Single(current))?.Main;

    public MultiSelectionSet? Undo(MultiSelectionSet current)
    {
        if (!undo.TryPop(out var previous)) return null;
        redo.Push(current);
        Trim(redo);
        return previous;
    }

    public TextSelection? Redo(TextSelection current) => Redo(MultiSelectionSet.Single(current))?.Main;

    public MultiSelectionSet? Redo(MultiSelectionSet current)
    {
        if (!redo.TryPop(out var next)) return null;
        undo.Push(current);
        Trim(undo);
        return next;
    }

    public void Clear()
    {
        undo.Clear();
        redo.Clear();
    }

    private static void Trim(Stack<MultiSelectionSet> entries)
    {
        if (entries.Count <= MaximumEntries) return;
        var retained = entries.Take(MaximumEntries).Reverse().ToArray();
        entries.Clear();
        foreach (var selection in retained) entries.Push(selection);
    }
}
