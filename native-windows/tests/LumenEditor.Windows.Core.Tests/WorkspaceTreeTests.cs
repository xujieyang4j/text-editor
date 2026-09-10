using LumenEditor.Windows.Core.Workspace;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class WorkspaceTreeTests
{
    [Fact]
    public void Tree_RejectsOutsidePathAndFiltersIgnoredEntries()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenTree", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "src"));
            Directory.CreateDirectory(Path.Combine(root, "node_modules"));
            File.WriteAllText(Path.Combine(root, "readme.txt"), "x");
            var tree = new WorkspaceTree();
            var entries = tree.ReadChildren(root, root);
            Assert.Equal(["src", "readme.txt"], entries.Select(entry => entry.Name));
            Assert.Empty(tree.ReadChildren(root, Path.GetTempPath()));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Exclusions_MatchCompactGlobsAndAreAppliedToDirectoryListings()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenTreeExclude", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "src"));
            Directory.CreateDirectory(Path.Combine(root, "build"));
            File.WriteAllText(Path.Combine(root, "notes.tmp"), "ignored");
            File.WriteAllText(Path.Combine(root, "readme.txt"), "visible");
            var exclusions = new WorkspaceExclusionPolicy([
                "./build/**", "**/*.tmp", "../outside/**", "build/**"
            ]);

            var entries = new WorkspaceTree().ReadChildren(root, root, exclusions);

            Assert.Equal(["src", "readme.txt"], entries.Select(entry => entry.Name));
            Assert.Equal(["build/**", "**/*.tmp"], exclusions.Patterns);
            Assert.True(exclusions.IsExcluded(root, Path.Combine(root, "src", "cache.tmp"), false));
            Assert.False(exclusions.IsExcluded(root, Path.Combine(root, "src", "cache.txt"), false));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task SearchWorkspace_FindsNestedWholeWordsAndSkipsIgnoredDirectories()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenSearch", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var nested = Path.Combine(root, "src", "nested");
            var ignored = Path.Combine(root, "node_modules", "package");
            Directory.CreateDirectory(nested);
            Directory.CreateDirectory(ignored);
            File.WriteAllText(
                Path.Combine(nested, "editor.txt"),
                "prefix editorSuffix\nThe Editor opens files.\neditor again");
            File.WriteAllText(Path.Combine(ignored, "ignored.txt"), "editor must not be returned");
            var excluded = Path.Combine(root, "generated");
            Directory.CreateDirectory(excluded);
            File.WriteAllText(Path.Combine(excluded, "generated.txt"), "editor must not be returned");

            var runner = new WorkspaceSearchRunner();
            var result = await runner.SearchWorkspaceAsync(
                new WorkspaceSearchQuery(root, "editor", WholeWord: true),
                new WorkspaceTree(), exclusions: new WorkspaceExclusionPolicy(["generated/**"]));

            Assert.False(result.IsTruncated);
            Assert.Collection(
                result.Matches,
                match =>
                {
                    Assert.Equal(Path.Combine(nested, "editor.txt"), match.Path);
                    Assert.Equal(2, match.Line);
                    Assert.Equal(5, match.Column);
                    Assert.Equal("The Editor opens files.", match.LineText);
                    Assert.Equal("Editor", match.MatchText);
                },
                match =>
                {
                    Assert.Equal(Path.Combine(nested, "editor.txt"), match.Path);
                    Assert.Equal(3, match.Line);
                    Assert.Equal(1, match.Column);
                    Assert.Equal("editor again", match.LineText);
                    Assert.Equal("editor", match.MatchText);
                });
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void ChangeAccumulator_IsRootConfinedDeduplicatedAndDrained()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenWatcher", Guid.NewGuid().ToString("N"));
        var inside = Path.Combine(root, "src", "file.cs");
        var accumulator = new WorkspaceChangeAccumulator(root);

        accumulator.Add(inside, WorkspaceChangeKind.Created);
        accumulator.Add(inside, WorkspaceChangeKind.Changed);
        accumulator.Add(Path.GetTempPath(), WorkspaceChangeKind.Deleted);
        accumulator.MarkOverflow();

        var batch = accumulator.Drain();
        Assert.True(batch.IsOverflow);
        Assert.Equal(new WorkspaceChange(inside, WorkspaceChangeKind.Changed), Assert.Single(batch.Changes));
        Assert.Empty(accumulator.Drain().Changes);
        Assert.False(accumulator.Drain().IsOverflow);
    }

    [Fact]
    public void ChangeAccumulator_DropsProjectExcludedPaths()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenWatcherExclude", Guid.NewGuid().ToString("N"));
        var accumulator = new WorkspaceChangeAccumulator(
            root, new WorkspaceExclusionPolicy(["generated/**", "**/*.tmp"]));

        accumulator.Add(Path.Combine(root, "src", "included.cs"), WorkspaceChangeKind.Changed);
        accumulator.Add(Path.Combine(root, "generated", "ignored.cs"), WorkspaceChangeKind.Changed);
        accumulator.Add(Path.Combine(root, "src", "ignored.tmp"), WorkspaceChangeKind.Changed);
        accumulator.Add(Path.Combine(root, ".lumen-project.json"), WorkspaceChangeKind.Changed);

        Assert.Equal(
            [Path.Combine(root, ".lumen-project.json"), Path.Combine(root, "src", "included.cs")],
            accumulator.Drain().Changes.Select(change => change.Path));
    }
}
