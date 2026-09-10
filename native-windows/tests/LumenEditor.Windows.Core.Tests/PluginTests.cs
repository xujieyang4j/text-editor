using System.Text;
using LumenEditor.Windows.Core.Plugins;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class PluginTests
{
    [Fact]
    public void Parser_AcceptsBoundedContributionsAndSanitizesWorkerMetadata()
    {
        var json = """{"id":"sample-plugin","name":"Sample","version":"1.0.0","commands":[{"id":"hello","title":"Hello","insertText":"hello"},{"id":"bad space","title":"Bad","insertText":"x"}],"snippets":[{"label":"Loop","text":"for (;;) {}","trigger":"loop","scope":"C"}],"extension":{"worker":"ignored.js"}}""";
        var plugin = Assert.IsType<DeclarativePlugin>(DeclarativePluginParser.Parse(Encoding.UTF8.GetBytes(json)));
        Assert.Equal("sample-plugin", plugin.Id);
        Assert.Equal(new PluginTextCommand("hello", "Hello", "hello"), Assert.Single(plugin.Commands));
        Assert.Equal("loop", Assert.Single(plugin.Snippets).Trigger);
        Assert.Equal("ignored.js", plugin.Extension?.Worker);
    }

    [Fact]
    public void Store_RequiresDirectoryNameToMatchPluginIdAndSkipsReparsePoints()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenPlugins", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, ".lumen-plugins", "good"));
        Directory.CreateDirectory(Path.Combine(root, ".lumen-plugins", "wrong-folder"));
        try
        {
            const string manifest = """{"id":"good","name":"Good","commands":[],"snippets":[]}""";
            File.WriteAllText(Path.Combine(root, ".lumen-plugins", "good", "plugin.json"), manifest);
            File.WriteAllText(Path.Combine(root, ".lumen-plugins", "wrong-folder", "plugin.json"), manifest);

            var plugin = Assert.Single(new DeclarativePluginStore(root).Load());
            Assert.Equal("good", plugin.Id);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Store_InstallsOnlySanitizedManifestAndDeclaredWorker()
    {
        var parent = Path.Combine(Path.GetTempPath(), "LumenPlugins", Guid.NewGuid().ToString("N"));
        var root = Path.Combine(parent, "workspace");
        var source = Path.Combine(parent, "source");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(source);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(source, "plugin.json"),
                """{"id":"safe","name":"Safe","commands":[{"id":"insert","title":"Insert","insertText":"ok"}],"snippets":[],"extension":{"worker":"do-not-copy.js"}}""");
            await File.WriteAllTextAsync(Path.Combine(source, "do-not-copy.js"), "self.onmessage = () => {}");
            await File.WriteAllTextAsync(Path.Combine(source, "unlisted.txt"), "secret");
            var store = new DeclarativePluginStore(root);

            var installed = await store.InstallAsync(source);

            Assert.Equal("safe", installed.Id);
            Assert.True(File.Exists(Path.Combine(root, ".lumen-plugins", "safe", "plugin.json")));
            Assert.True(File.Exists(Path.Combine(root, ".lumen-plugins", "safe", "do-not-copy.js")));
            Assert.False(File.Exists(Path.Combine(root, ".lumen-plugins", "safe", "unlisted.txt")));
            var reloaded = Assert.Single(store.Load());
            Assert.Equal("ok", Assert.Single(reloaded.Commands).InsertText);
            Assert.Single(store.LoadWorkerPackages());
        }
        finally { Directory.Delete(parent, recursive: true); }
    }

    [Fact]
    public async Task Store_AtomicallyInstallsAnAlreadyValidatedMarketplaceManifest()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenMarketplaceInstall", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var manifest = new DeclarativePlugin("market", "Market", "1", true,
                [new PluginTextCommand("insert", "Insert", "text")], []);
            var installed = await new DeclarativePluginStore(root).InstallManifestAsync(manifest);
            Assert.Equal("market", installed.Id);
            Assert.Single(new DeclarativePluginStore(root).Load());
            Assert.Empty(Directory.EnumerateDirectories(Path.Combine(root, ".lumen-plugins"), ".*.tmp"));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Store_RequiresMarketplaceWorkerIntegrityBeforePublishing()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenMarketplaceWorker", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var source = Encoding.UTF8.GetBytes("self.onmessage = function () {}");
            var manifest = new DeclarativePlugin("worker", "Worker", "1", true, [], [],
                new PluginExtensionManifest("worker.js", [], WorkerIntegrity: PluginIntegrity.Compute(source)));
            var store = new DeclarativePluginStore(root);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.InstallManifestAsync(manifest, "changed"u8.ToArray()));
            Assert.False(Directory.Exists(Path.Combine(root, ".lumen-plugins", "worker")));
            await store.InstallManifestAsync(manifest, source);
            var package = Assert.Single(store.LoadWorkerPackages());
            Assert.Equal(PluginIntegrity.Compute(source), package.SourceIntegrity);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Store_RejectsMissingOversizedAndReparsePointWorkers()
    {
        var parent = Path.Combine(Path.GetTempPath(), "LumenPluginWorkers", Guid.NewGuid().ToString("N"));
        var root = Path.Combine(parent, "workspace");
        var source = Path.Combine(parent, "source");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(source);
        const string manifest = "{\"id\":\"worker\",\"name\":\"Worker\",\"extension\":{\"worker\":\"worker.js\"}}";
        await File.WriteAllTextAsync(Path.Combine(source, "plugin.json"), manifest);
        try
        {
            var store = new DeclarativePluginStore(root);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.InstallAsync(source));
            await File.WriteAllBytesAsync(Path.Combine(source, "worker.js"), [0xff]);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.InstallAsync(source));
            await File.WriteAllBytesAsync(Path.Combine(source, "worker.js"),
                new byte[DeclarativePluginParser.MaximumWorkerBytes + 1]);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.InstallAsync(source));
        }
        finally { Directory.Delete(parent, recursive: true); }
    }
}
