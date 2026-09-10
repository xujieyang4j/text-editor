using System.Text;
using LumenEditor.Windows.Core.Navigation;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class WorkspaceWordIndexTests
{
    [Fact]
    public async Task Index_ReadsTextSkipsBinaryAndDeduplicatesWords()
    {
        var directory = Path.Combine(Path.GetTempPath(), "LumenWords", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var first = Path.Combine(directory, "a.cs");
            var second = Path.Combine(directory, "b.txt");
            var binary = Path.Combine(directory, "binary.bin");
            await File.WriteAllTextAsync(first, "AlphaBeta alphabet AlphaBeta", Encoding.UTF8);
            await File.WriteAllTextAsync(second, "anotherWord", Encoding.UTF8);
            await File.WriteAllBytesAsync(binary, [0, 1, 2, 3]);

            var words = await WorkspaceWordIndex.BuildAsync([first, second, binary]);

            Assert.Contains("AlphaBeta", words);
            Assert.Contains("alphabet", words);
            Assert.Contains("anotherWord", words);
            Assert.Equal(words.Count, words.Distinct(StringComparer.Ordinal).Count());
        }
        finally { Directory.Delete(directory, recursive: true); }
    }
}
