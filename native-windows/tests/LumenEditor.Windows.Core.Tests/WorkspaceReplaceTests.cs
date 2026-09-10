using LumenEditor.Windows.Core.Workspace;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class WorkspaceReplaceTests
{
    [Fact]
    public async Task Replace_PreviewsAppliesAndUndoesWithLiteralDollar()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenReplace", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var first = Path.Combine(root, "first.txt");
            var second = Path.Combine(root, "second.txt");
            await File.WriteAllTextAsync(first, "cat catalog cat");
            await File.WriteAllTextAsync(second, "CAT");
            var service = new WorkspaceReplaceService();

            var preview = await service.PreviewAsync(
                [root], "cat", "$1", caseSensitive: false, wholeWord: true, useRegex: false, new WorkspaceTree());
            Assert.Null(preview.Error);
            Assert.Equal(2, preview.Files.Count);
            Assert.Equal(3, preview.ReplacementCount);

            var applied = await service.ApplyAsync(preview);
            Assert.True(applied.Succeeded, applied.Error);
            Assert.Equal("$1 catalog $1", await File.ReadAllTextAsync(first));
            Assert.Equal("$1", await File.ReadAllTextAsync(second));

            var undone = await service.UndoAsync(Assert.IsType<WorkspaceReplaceUndo>(applied.Undo));
            Assert.True(undone.Succeeded, undone.Error);
            Assert.Equal("cat catalog cat", await File.ReadAllTextAsync(first));
            Assert.Equal("CAT", await File.ReadAllTextAsync(second));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Replace_RejectsRevisionChangedAfterPreview()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenReplace", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "file.txt");
            await File.WriteAllTextAsync(path, "before");
            var service = new WorkspaceReplaceService();
            var preview = await service.PreviewAsync(
                [root], "before", "after", false, false, false, new WorkspaceTree());
            await File.WriteAllTextAsync(path, "external change");

            var applied = await service.ApplyAsync(preview);

            Assert.False(applied.Succeeded);
            Assert.Contains("changed after", applied.Error);
            Assert.Equal("external change", await File.ReadAllTextAsync(path));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Replace_DoesNotPreviewOrModifyProjectExcludedFiles()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenReplaceExclude", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "generated"));
        try
        {
            var included = Path.Combine(root, "included.txt");
            var excluded = Path.Combine(root, "generated", "excluded.txt");
            await File.WriteAllTextAsync(included, "before");
            await File.WriteAllTextAsync(excluded, "before");

            var service = new WorkspaceReplaceService();
            var exclusions = new WorkspaceExclusionPolicy(["generated/**"]);
            var preview = await service.PreviewAsync(
                [root], "before", "after", false, false, false, new WorkspaceTree(),
                exclusions: exclusions);
            var applied = await service.ApplyAsync(preview, currentExclusions: exclusions);

            Assert.True(applied.Succeeded, applied.Error);
            Assert.Equal("after", await File.ReadAllTextAsync(included));
            Assert.Equal("before", await File.ReadAllTextAsync(excluded));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Replace_RejectsPreviewAfterProjectExclusionsChange()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenReplaceExcludeRevision", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "included.txt");
            await File.WriteAllTextAsync(path, "before");
            var service = new WorkspaceReplaceService();
            var preview = await service.PreviewAsync(
                [root], "before", "after", false, false, false, new WorkspaceTree(),
                exclusions: WorkspaceExclusionPolicy.Empty);

            var applied = await service.ApplyAsync(
                preview, currentExclusions: new WorkspaceExclusionPolicy(["**/*.txt"]));

            Assert.False(applied.Succeeded);
            Assert.Contains("exclusions changed", applied.Error);
            Assert.Equal("before", await File.ReadAllTextAsync(path));
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
