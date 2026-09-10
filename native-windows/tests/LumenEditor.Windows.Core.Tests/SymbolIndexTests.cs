using LumenEditor.Windows.Core.Navigation;
using LumenEditor.Windows.Core.Workspace;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class SymbolIndexTests
{
    [Fact]
    public void Extractor_FindsMarkdownPythonAndTypeScriptSymbols()
    {
        Assert.Equal("Heading", Assert.Single(SymbolExtractor.Extract("a.md", "# Heading", "markdown")).Name);
        Assert.Equal(["Thing", "run"], SymbolExtractor.Extract("a.py", "class Thing:\n  def run(self):", "python").Select(symbol => symbol.Name));
        Assert.Equal(["Widget", "start"], SymbolExtractor.Extract("a.ts", "export class Widget {}\nfunction start() {}", "typescript").Select(symbol => symbol.Name));
    }

    [Fact]
    public async Task WorkspaceIndex_SkipsIgnoredDirectoriesAndSearchesNames()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenSymbols", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        Directory.CreateDirectory(Path.Combine(root, "node_modules"));
        Directory.CreateDirectory(Path.Combine(root, "generated"));
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, "src", "app.ts"), "class IncidentController {}\nfunction boot() {}");
            await File.WriteAllTextAsync(Path.Combine(root, "node_modules", "ignored.ts"), "class IncidentNoise {}");
            await File.WriteAllTextAsync(Path.Combine(root, "generated", "ignored.ts"), "class IncidentGenerated {}");
            var symbols = await new WorkspaceSymbolIndex().BuildAsync(
                [root], new WorkspaceTree(), exclusions: new WorkspaceExclusionPolicy(["generated/**"]));
            var result = WorkspaceSymbolIndex.Search(symbols, "ic");
            Assert.Equal("IncidentController", Assert.Single(result).Name);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
