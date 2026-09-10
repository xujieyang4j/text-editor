using LumenEditor.Windows.Core.Workspace;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class WorkspaceFileOperationTests
{
    [Fact]
    public async Task CreateAndRename_StayInsideWorkspaceAndNeverOverwrite()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenWorkspaceOps", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var folder = WorkspaceFileOperations.CreateDirectory(root, root, "src");
            var file = await WorkspaceFileOperations.CreateFileAsync(root, folder, "a.txt");
            await File.WriteAllTextAsync(file, "content");
            var renamed = WorkspaceFileOperations.Rename(root, file, "b.txt");

            Assert.Equal(Path.Combine(folder, "b.txt"), renamed);
            Assert.Equal("content", await File.ReadAllTextAsync(renamed));
            Assert.Throws<ArgumentException>(() => WorkspaceFileOperations.ResolveNewChild(root, folder, "../escape"));
            Assert.Throws<IOException>(() => WorkspaceFileOperations.CreateDirectory(root, root, "src"));
            Assert.False(WorkspaceFileOperations.IsSafeTrashTarget(root, root));
            Assert.True(WorkspaceFileOperations.IsSafeTrashTarget(root, renamed));
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
