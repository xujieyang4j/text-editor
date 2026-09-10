using LumenEditor.Windows.Core.Navigation;
using LumenEditor.Windows.Core.Workspace;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class NavigationHistoryTests
{
    [Fact]
    public void History_BackAndForwardPreservePaneAndSelection()
    {
        var history = new NavigationHistory();
        var first = new NavigationLocation("a", 0, 1, 2);
        var second = new NavigationLocation("b", 2, 3, 4);
        Assert.False(history.Record(first, first));
        Assert.True(history.Record(first, second));
        Assert.Equal(first, history.GoBack(second));
        Assert.Equal(second, history.GoForward(first));
    }

    [Fact]
    public void FileIndex_FuzzyRanksMatchesAndSkipsIgnoredTrees()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenIndex", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        Directory.CreateDirectory(Path.Combine(root, "node_modules"));
        try
        {
            File.WriteAllText(Path.Combine(root, "src", "MainWindow.xaml.cs"), "x");
            File.WriteAllText(Path.Combine(root, "src", "Other.cs"), "x");
            File.WriteAllText(Path.Combine(root, "node_modules", "MainWindow.js"), "x");
            var generated = Path.Combine(root, "generated");
            Directory.CreateDirectory(generated);
            File.WriteAllText(Path.Combine(generated, "MainWindow.generated.cs"), "x");
            var matches = WorkspaceFileIndex.Search(
                [root], new WorkspaceTree(), "mwx", new WorkspaceExclusionPolicy(["generated/**"]));
            Assert.Equal("src/MainWindow.xaml.cs".Replace('/', Path.DirectorySeparatorChar), Assert.Single(matches).RelativePath);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
