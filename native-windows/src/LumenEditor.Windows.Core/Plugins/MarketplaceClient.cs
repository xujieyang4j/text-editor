using System.Net;
using System.Text.Json;

namespace LumenEditor.Windows.Core.Plugins;

public sealed record MarketplaceItem(string Id, string Name, string Version, string? Description, Uri ManifestUri)
{
    public string Display => $"{Name} {Version} — {Description ?? Id}";
}

public sealed record MarketplaceCatalogResult(
    IReadOnlyList<MarketplaceItem> Items, IReadOnlyList<string> Failures);
public sealed record MarketplacePluginPackage(DeclarativePlugin Manifest, byte[]? WorkerSource);

/// <summary>Credential-free, redirect-free and bounded read-only marketplace catalog client.</summary>
public sealed class MarketplaceClient
{
    public const int MaximumSources = 20;
    public const int MaximumItems = 1_000;
    public const int MaximumCatalogBytes = 4 * 1024 * 1024;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    public async Task<MarketplaceCatalogResult> FetchAsync(
        IEnumerable<Uri> requestedSources, CancellationToken cancellationToken = default)
    {
        var sources = requestedSources.Where(IsApprovedHttpsUri).Distinct().Take(MaximumSources).ToList();
        var items = new List<MarketplaceItem>();
        var indexes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var failures = new List<string>();
        foreach (var source in sources)
        {
            try
            {
                foreach (var item in ParseCatalog(await DownloadAsync(source, MaximumCatalogBytes, cancellationToken)))
                {
                    if (indexes.TryGetValue(item.Id, out var index)) items[index] = item;
                    else if (items.Count < MaximumItems)
                    {
                        indexes[item.Id] = items.Count;
                        items.Add(item);
                    }
                }
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException
                or InvalidDataException)
            {
                failures.Add($"{source.Host}: {error.Message}");
            }
        }
        return new(items, failures);
    }

    public async Task<DeclarativePlugin> FetchManifestAsync(
        MarketplaceItem item, CancellationToken cancellationToken = default) =>
        ParseManifest(item, await DownloadAsync(
            item.ManifestUri, DeclarativePluginParser.MaximumManifestBytes, cancellationToken));

    public async Task<MarketplacePluginPackage> FetchPackageAsync(
        MarketplaceItem item, CancellationToken cancellationToken = default)
    {
        var manifest = await FetchManifestAsync(item, cancellationToken);
        if (manifest.Extension is not { } extension) return new(manifest, null);
        if (extension.WorkerUrl is null || extension.WorkerIntegrity is null)
            throw new InvalidDataException("Marketplace workers require both a URL and an integrity digest.");
        if (!SameOrigin(item.ManifestUri, extension.WorkerUrl))
            throw new InvalidDataException("Marketplace worker must use the manifest origin.");
        var worker = await DownloadAsync(extension.WorkerUrl, DeclarativePluginParser.MaximumWorkerBytes, cancellationToken, requireBody: true);
        if (worker.Length == 0 || !PluginIntegrity.Matches(extension.WorkerIntegrity, worker))
            throw new InvalidDataException("Marketplace worker failed its SHA-256 integrity check.");
        return new(manifest with { Extension = extension with { WorkerUrl = null, WorkerIntegrity = null } }, worker);
    }

    public static DeclarativePlugin ParseManifest(MarketplaceItem item, ReadOnlySpan<byte> bytes)
    {
        var manifest = DeclarativePluginParser.Parse(bytes)
            ?? throw new InvalidDataException("Marketplace plugin manifest is invalid.");
        if (!StringComparer.OrdinalIgnoreCase.Equals(item.Id, manifest.Id))
        {
            throw new InvalidDataException("Marketplace plugin manifest ID does not match its catalog ID.");
        }
        return manifest;
    }

    public static IReadOnlyList<Uri> ParseSources(JsonElement project)
    {
        if (project.ValueKind != JsonValueKind.Object
            || !project.TryGetProperty("marketplaceUrls", out var values)
            || values.ValueKind != JsonValueKind.Array) return [];
        return values.EnumerateArray()
            .Where(value => value.ValueKind == JsonValueKind.String)
            .Select(value => value.GetString())
            .Where(value => value is { Length: > 0 and <= 2_000 }
                && Uri.TryCreate(value, UriKind.Absolute, out var parsed) && IsApprovedHttpsUri(parsed))
            .Select(value => new Uri(value!))
            .Distinct().Take(MaximumSources).ToList();
    }

    public static IReadOnlyList<MarketplaceItem> ParseCatalog(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaximumCatalogBytes) throw new InvalidDataException("Marketplace catalog has an invalid size.");
        using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
        var values = document.RootElement.ValueKind == JsonValueKind.Array ? document.RootElement
            : document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("plugins", out var plugins)
                && plugins.ValueKind == JsonValueKind.Array ? plugins
                : default;
        if (values.ValueKind != JsonValueKind.Array) return [];
        var items = new List<MarketplaceItem>();
        var indexes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in values.EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.Object
                || !StringProperty(value, "id", 100, out var id) || !IsSafeId(id)
                || !StringProperty(value, "name", 200, out var name)
                || !StringProperty(value, "manifestUrl", 2_000, out var manifestText)
                || !Uri.TryCreate(manifestText, UriKind.Absolute, out var manifestUri)
                || !IsApprovedHttpsUri(manifestUri)) continue;
            var version = StringProperty(value, "version", 50, out var parsedVersion) ? parsedVersion : "0.0.0";
            var description = StringProperty(value, "description", 500, out var parsedDescription) ? parsedDescription : null;
            var item = new MarketplaceItem(id, name, version, description, manifestUri);
            if (indexes.TryGetValue(id, out var index)) items[index] = item;
            else if (items.Count < MaximumItems)
            {
                indexes[id] = items.Count;
                items.Add(item);
            }
        }
        return items;
    }

    public static bool IsApprovedHttpsUri(Uri uri) => uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps
        && uri.Host.Length > 0 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0;
    public static bool SameOrigin(Uri left, Uri right) => IsApprovedHttpsUri(left) && IsApprovedHttpsUri(right)
        && StringComparer.OrdinalIgnoreCase.Equals(left.Scheme, right.Scheme)
        && StringComparer.OrdinalIgnoreCase.Equals(left.Host, right.Host)
        && left.Port == right.Port;

    private static async Task<byte[]> DownloadAsync(
        Uri source, int maximumBytes, CancellationToken cancellationToken, bool requireBody = false)
    {
        using var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null
        };
        using var client = new HttpClient(handler) { Timeout = Timeout };
        using var request = new HttpRequestMessage(HttpMethod.Get, source);
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LumenEditorNativeWindows/1");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.StatusCode is >= HttpStatusCode.MultipleChoices and < HttpStatusCode.BadRequest
            || response.RequestMessage?.RequestUri != source)
        {
            throw new InvalidDataException("Marketplace redirects are not allowed.");
        }
        if (!response.IsSuccessStatusCode) throw new InvalidDataException($"Marketplace returned HTTP {(int)response.StatusCode}.");
        if (response.Content.Headers.ContentLength > maximumBytes) throw new InvalidDataException("Marketplace response is too large.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0)
            {
                if (requireBody && output.Length == 0) throw new InvalidDataException("Marketplace response is empty.");
                return output.ToArray();
            }
            if (output.Length + count > maximumBytes) throw new InvalidDataException("Marketplace response is too large.");
            output.Write(buffer, 0, count);
        }
    }

    private static bool IsSafeId(string value) => value.All(character => Char.IsAsciiLetterOrDigit(character) || character == '-');
    private static bool StringProperty(JsonElement root, string name, int maximum, out string value)
    {
        value = String.Empty;
        if (!root.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String) return false;
        value = (element.GetString() ?? String.Empty).Trim();
        if (value.Length > maximum) value = value[..maximum];
        return value.Length > 0;
    }
}
