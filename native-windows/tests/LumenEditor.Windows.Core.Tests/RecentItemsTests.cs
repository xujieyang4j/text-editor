using LumenEditor.Windows.Core.Recent;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class RecentItemsTests
{
    [Fact]
    public async Task Store_DeduplicatesMovesToFrontAndDropsMissingItems()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenRecent", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var first = Path.Combine(root, "a.txt");
            var second = Path.Combine(root, "b.txt");
            await File.WriteAllTextAsync(first, "a");
            await File.WriteAllTextAsync(second, "b");
            var store = new RecentItemsStore(Path.Combine(root, "recent.json"));
            await store.AddFileAsync(first);
            await store.AddFileAsync(second);
            await store.AddFileAsync(first);
            await store.AddProjectAsync(root);

            var loaded = await store.LoadAsync();
            Assert.Equal([first, second], loaded.Files);
            Assert.Equal([root], loaded.Projects);
            File.Delete(first);
            Assert.Equal([second], (await store.LoadAsync()).Files);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
