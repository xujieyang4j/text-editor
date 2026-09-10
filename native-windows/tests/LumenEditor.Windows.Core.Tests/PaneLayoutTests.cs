using LumenEditor.Windows.Core.Layout;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class PaneLayoutTests
{
    [Fact]
    public void Layout_TracksActiveDocumentAcrossMoveCloneFocusAndCollapse()
    {
        var layout = new PaneLayout();
        Assert.True(layout.AddToActive("a"));
        layout.SetKind(PaneLayoutKind.Columns2);

        Assert.True(layout.MoveToNext("a", clone: true));
        Assert.Equal(1, layout.ActivePane);
        Assert.Equal("a", layout.ActiveDocument);
        Assert.Contains("a", layout.Panes[0]);
        Assert.Contains("a", layout.Panes[1]);

        Assert.True(layout.Activate("b"));
        Assert.True(layout.MoveToNext("b", clone: false));
        Assert.Equal(0, layout.ActivePane);
        Assert.Equal("b", layout.ActiveDocument);
        Assert.DoesNotContain("b", layout.Panes[1]);

        layout.SetKind(PaneLayoutKind.Single);
        Assert.Single(layout.Panes);
        Assert.Equal(["a", "b"], layout.Panes[0]);
        Assert.Equal("b", layout.ActiveDocument);
    }

    [Fact]
    public void Layout_RemoveClearsEveryCloneAndChoosesFallback()
    {
        var layout = new PaneLayout();
        layout.Activate("a");
        layout.Activate("b");
        layout.SetKind(PaneLayoutKind.Columns2);
        layout.MoveToNext("b", clone: true);

        Assert.True(layout.Remove("b"));
        Assert.DoesNotContain(layout.Panes, pane => pane.Contains("b"));
        Assert.Null(layout.ActiveDocument);
        layout.FocusNext();
        Assert.Equal("a", layout.ActiveDocument);
    }

    [Fact]
    public void Layout_RemoveFromPaneKeepsCloneAndResetReturnsToSinglePane()
    {
        var layout = new PaneLayout();
        layout.Activate("a");
        layout.SetKind(PaneLayoutKind.Columns2);
        layout.MoveToNext("a", clone: true);

        Assert.True(layout.RemoveFromPane("a"));
        Assert.True(layout.Contains("a"));
        Assert.Null(layout.ActiveDocument);

        layout.Reset(["a", "b"], "b");
        Assert.Equal(PaneLayoutKind.Single, layout.Kind);
        Assert.Equal("b", layout.ActiveDocument);
        Assert.Equal(["a", "b"], layout.Panes[0]);
    }

    [Fact]
    public void Layout_MoveUsesTheActivePaneWhenTheDocumentIsCloned()
    {
        var layout = new PaneLayout();
        layout.Activate("a");
        layout.SetKind(PaneLayoutKind.Columns3);
        layout.MoveToNext("a", clone: true);
        layout.SetActivePane(1);

        Assert.True(layout.MoveToNext("a", clone: false));

        Assert.Contains("a", layout.Panes[0]);
        Assert.DoesNotContain("a", layout.Panes[1]);
        Assert.Contains("a", layout.Panes[2]);
        Assert.Equal(2, layout.ActivePane);
    }

    [Fact]
    public void Layout_RenamesDocumentAcrossClonedPanes()
    {
        var layout = new PaneLayout();
        layout.Activate("untitled://1");
        layout.SetKind(PaneLayoutKind.Columns2);
        layout.MoveToNext("untitled://1", clone: true);

        Assert.True(layout.RenameDocument("untitled://1", "C:\\saved.txt"));
        Assert.All(layout.Panes, pane => Assert.Contains("C:\\saved.txt", pane));
        Assert.Equal("C:\\saved.txt", layout.ActiveDocument);
        Assert.False(layout.Contains("untitled://1"));
    }

    [Fact]
    public void Layout_RestoresOnlyValidDocumentsAndAddsMissingOnes()
    {
        var layout = new PaneLayout();
        layout.Restore(new PaneLayoutSnapshot(PaneLayoutKind.Columns2, 1,
        [
            new PaneSnapshot(["a", "missing"], "missing"),
            new PaneSnapshot(["b"], "b")
        ]), ["a", "b", "c"], "b");

        Assert.Equal(PaneLayoutKind.Columns2, layout.Kind);
        Assert.Equal(1, layout.ActivePane);
        Assert.Equal("b", layout.ActiveDocument);
        Assert.Equal(["a", "c"], layout.Panes[0]);
        Assert.Equal(["b"], layout.Panes[1]);
    }

    [Fact]
    public void Layout_SplitsSelectedTabsInSourceOrderAndCapsAtFour()
    {
        var layout = new PaneLayout();
        foreach (var document in new[] { "a", "b", "c", "d", "e" })
        {
            layout.Activate(document);
        }

        Assert.True(layout.SplitSelectedTabs(["d", "b", "e", "c", "a"]));

        Assert.Equal(PaneLayoutKind.Grid4, layout.Kind);
        Assert.Equal(0, layout.ActivePane);
        Assert.Equal(["a", "b", "c", "d"], layout.ActiveDocuments);
        Assert.Equal(["a", "b", "c", "d", "e"], layout.Panes[0]);
        Assert.Equal(["e", "b"], layout.Panes[1]);
        Assert.Equal(["e", "c"], layout.Panes[2]);
        Assert.Equal(["e", "d"], layout.Panes[3]);
        Assert.Equal(5, layout.Panes.SelectMany(pane => pane).Distinct().Count());
    }

    [Fact]
    public void Layout_SplitSelectedTabsClonesActiveWhenFewerThanTwoAreSelected()
    {
        var layout = new PaneLayout();
        layout.Activate("a");
        layout.Activate("b");

        Assert.True(layout.SplitSelectedTabs(["a"]));

        Assert.Equal(PaneLayoutKind.Columns2, layout.Kind);
        Assert.Equal(1, layout.ActivePane);
        Assert.Equal("b", layout.ActiveDocument);
        Assert.Equal(["b"], layout.Panes[1]);
    }

    [Theory]
    [InlineData(2, PaneLayoutKind.Columns2)]
    [InlineData(3, PaneLayoutKind.Columns3)]
    [InlineData(4, PaneLayoutKind.Grid4)]
    public void Layout_SplitSelectedTabsChoosesLayoutForSelectionCount(
        int selectionCount, PaneLayoutKind expected)
    {
        var layout = new PaneLayout();
        var documents = new[] { "a", "b", "c", "d" };
        foreach (var document in documents) layout.Activate(document);

        Assert.True(layout.SplitSelectedTabs(documents.Take(selectionCount)));

        Assert.Equal(expected, layout.Kind);
    }
}
