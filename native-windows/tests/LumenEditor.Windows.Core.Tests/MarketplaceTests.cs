using System.Text;
using System.Text.Json;
using LumenEditor.Windows.Core.Plugins;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class MarketplaceTests
{
    [Fact]
    public void Catalog_SanitizesFieldsAndUsesLastDuplicate()
    {
        var items = MarketplaceClient.ParseCatalog(Encoding.UTF8.GetBytes("""
            {"plugins":[
              {"id":"safe-plugin","name":"Old","version":"1","manifestUrl":"https://plugins.example/old.json"},
              {"id":"bad/path","name":"Bad","manifestUrl":"https://plugins.example/bad.json"},
              {"id":"safe-plugin","name":"New","version":"2","description":"updated","manifestUrl":"https://plugins.example/new.json"},
              {"id":"insecure","name":"No","manifestUrl":"http://plugins.example/no.json"}
            ]}
            """));
        var item = Assert.Single(items);
        Assert.Equal("New", item.Name);
        Assert.Equal("https://plugins.example/new.json", item.ManifestUri.AbsoluteUri);
    }

    [Fact]
    public void Sources_RequireCredentialFreeHttpsAndAreBounded()
    {
        using var document = JsonDocument.Parse("""
            {"marketplaceUrls":[
              "http://insecure.example/index.json",
              "https://user:secret@plugins.example/private.json",
              "https://plugins.example/index.json"
            ]}
            """);
        var source = Assert.Single(MarketplaceClient.ParseSources(document.RootElement));
        Assert.Equal("https://plugins.example/index.json", source.AbsoluteUri);
    }

    [Fact]
    public void Manifest_MustMatchCatalogIdentityAndRemainsDeclarative()
    {
        var item = new MarketplaceItem("safe", "Safe", "1", null,
            new Uri("https://plugins.example/safe.json"));
        var manifest = MarketplaceClient.ParseManifest(item, Encoding.UTF8.GetBytes(
            """{"id":"safe","name":"Safe","commands":[{"id":"insert","title":"Insert","insertText":"ok"}],"extension":{"worker":"ignored.js"}}"""));
        Assert.Equal("safe", manifest.Id);
        Assert.Equal("ok", Assert.Single(manifest.Commands).InsertText);
        Assert.Throws<InvalidDataException>(() => MarketplaceClient.ParseManifest(item,
            Encoding.UTF8.GetBytes("""{"id":"other","name":"Other"}""")));
    }

    [Fact]
    public void WorkerMetadata_RequiresSafePathIntegrityAndSameOrigin()
    {
        var source = Encoding.UTF8.GetBytes("self.onmessage = function () {}");
        var integrity = PluginIntegrity.Compute(source);
        var item = new MarketplaceItem("safe", "Safe", "1", null,
            new Uri("https://plugins.example/manifests/safe.json"));
        var json = "{\"id\":\"safe\",\"name\":\"Safe\",\"extension\":{"
            + "\"worker\":\"worker.js\",\"permissions\":[\"document-read\",\"document-edit\"],"
            + "\"workerUrl\":\"https://plugins.example/assets/worker.js\",\"workerIntegrity\":\""
            + integrity + "\"}}";
        var manifest = MarketplaceClient.ParseManifest(item, Encoding.UTF8.GetBytes(json));
        Assert.Equal([PluginPermission.DocumentRead, PluginPermission.DocumentEdit], manifest.Extension?.Permissions);
        Assert.True(MarketplaceClient.SameOrigin(item.ManifestUri, manifest.Extension!.WorkerUrl!));
        Assert.False(MarketplaceClient.SameOrigin(item.ManifestUri, new Uri("https://other.example/worker.js")));
        Assert.True(PluginIntegrity.Matches(integrity, source));
    }
}
