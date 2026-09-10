namespace LumenEditor.Windows.Core.Navigation;

public sealed record NavigationLocation(string DocumentPath, int Pane, int Anchor, int Head);

/// <summary>Bounded session-only back/forward navigation with duplicate suppression.</summary>
public sealed class NavigationHistory
{
    public const int MaximumEntries = 500;
    private readonly List<NavigationLocation> back = [];
    private readonly List<NavigationLocation> forward = [];

    public bool CanGoBack => back.Count > 0;
    public bool CanGoForward => forward.Count > 0;

    public bool Record(NavigationLocation from, NavigationLocation to)
    {
        if (from == to) return false;
        if (back.Count == 0 || back[^1] != from) back.Add(from);
        while (back.Count > MaximumEntries) back.RemoveAt(0);
        forward.Clear();
        return true;
    }

    public NavigationLocation? GoBack(NavigationLocation current)
    {
        if (back.Count == 0) return null;
        var destination = back[^1];
        back.RemoveAt(back.Count - 1);
        if (forward.Count == 0 || forward[^1] != current) forward.Add(current);
        return destination;
    }

    public NavigationLocation? GoForward(NavigationLocation current)
    {
        if (forward.Count == 0) return null;
        var destination = forward[^1];
        forward.RemoveAt(forward.Count - 1);
        if (back.Count == 0 || back[^1] != current) back.Add(current);
        return destination;
    }
}
