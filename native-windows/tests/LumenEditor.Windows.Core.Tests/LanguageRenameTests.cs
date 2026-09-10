using LumenEditor.Windows.Core.Language;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class LanguageRenameTests
{
    [Fact]
    public async Task Rename_AppliesUtf16EditsAndCanUndo()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenRename", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "file.cs");
            await File.WriteAllTextAsync(path, "😀 old\nold");
            var service = new LanguageRenameService();
            var preview = await service.PreviewAsync([
                new LanguageRenameEdit(path, 0, 3, 0, 6, "next"),
                new LanguageRenameEdit(path, 1, 0, 1, 3, "next")
            ]);

            Assert.Null(preview.Error);
            Assert.Equal(2, preview.EditCount);
            var applied = await service.ApplyAsync(preview);
            Assert.True(applied.Succeeded, applied.Error);
            Assert.Equal("😀 next\nnext", await File.ReadAllTextAsync(path));
            var undone = await service.UndoAsync(Assert.IsType<LanguageRenameUndo>(applied.Undo));
            Assert.True(undone.Succeeded, undone.Error);
            Assert.Equal("😀 old\nold", await File.ReadAllTextAsync(path));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Rename_RejectsOverlappingEdits()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenRename", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "file.cs");
            await File.WriteAllTextAsync(path, "abcdef");
            var service = new LanguageRenameService();
            var preview = await service.PreviewAsync([
                new LanguageRenameEdit(path, 0, 1, 0, 4, "x"),
                new LanguageRenameEdit(path, 0, 3, 0, 5, "y")
            ]);
            Assert.Contains("overlapping", preview.Error);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
