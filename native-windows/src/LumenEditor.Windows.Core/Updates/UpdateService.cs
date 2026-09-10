using System.Net;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace LumenEditor.Windows.Core.Updates;

public sealed record UpdateInformation(
    string CurrentVersion, string? LatestVersion, Uri? ReleaseUri, bool IsAvailable);

/// <summary>Bounded, redirect-free GitHub Releases checker for signed native Windows MSIX assets.</summary>
public sealed class UpdateService
{
    public static readonly Uri Endpoint = new("https://api.github.com/repos/xujieyang4j/text-editor/releases/latest");
    public const int MaximumResponseBytes = 256 * 1024;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(8);

    public async Task<UpdateInformation> CheckAsync(string currentVersion, CancellationToken cancellationToken = default)
    {
        using var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            UseDefaultCredentials = false,
            Credentials = null
        };
        using var client = new HttpClient(handler) { Timeout = Timeout };
        using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("LumenEditorNativeWindows/" + NormalizeVersion(currentVersion));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.StatusCode is >= HttpStatusCode.MultipleChoices and < HttpStatusCode.BadRequest
            || response.RequestMessage?.RequestUri != Endpoint)
        {
            throw new InvalidDataException("The update service redirected the request unexpectedly.");
        }
        if (!response.IsSuccessStatusCode) throw new InvalidDataException($"Update check failed with HTTP {(int)response.StatusCode}.");
        var bytes = await ReadBoundedAsync(response.Content, MaximumResponseBytes, cancellationToken);
        return Parse(bytes, currentVersion, CurrentArchitecture());
    }

    public static UpdateInformation Parse(ReadOnlySpan<byte> bytes, string currentVersion, string architecture)
    {
        if (bytes.Length is 0 or > MaximumResponseBytes) throw new InvalidDataException("Update metadata has an invalid size.");
        using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String
            || root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True
            || root.TryGetProperty("prerelease", out var prerelease) && prerelease.ValueKind == JsonValueKind.True)
        {
            throw new InvalidDataException("The update service returned malformed release metadata.");
        }
        var latest = NormalizeVersion(tag.GetString() ?? String.Empty);
        if (latest.Length is < 1 or > 64 || latest.Any(Char.IsControl))
        {
            throw new InvalidDataException("The update version is invalid.");
        }
        Uri? releaseUri = null;
        if (root.TryGetProperty("html_url", out var release) && release.ValueKind == JsonValueKind.String
            && Uri.TryCreate(release.GetString(), UriKind.Absolute, out var candidate) && IsApprovedReleaseUri(candidate))
        {
            releaseUri = candidate;
        }
        var expectedAsset = $"text-editor-xujieyang-{latest}-native-windows-{architecture}.msix";
        var hasAsset = root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array
            && assets.EnumerateArray().Any(asset => asset.ValueKind == JsonValueKind.Object
                && asset.TryGetProperty("name", out var name) && name.GetString() == expectedAsset);
        var available = hasAsset && releaseUri is not null && CompareVersions(latest, currentVersion) > 0;
        return new(NormalizeVersion(currentVersion), latest, hasAsset ? releaseUri : null, available);
    }

    public static int CompareVersions(string left, string right)
    {
        var a = VersionParts(left);
        var b = VersionParts(right);
        for (var index = 0; index < Math.Max(a.Numbers.Length, b.Numbers.Length); index++)
        {
            var leftValue = index < a.Numbers.Length ? a.Numbers[index] : 0;
            var rightValue = index < b.Numbers.Length ? b.Numbers[index] : 0;
            if (leftValue != rightValue) return leftValue.CompareTo(rightValue);
        }
        if (a.Prerelease is null && b.Prerelease is not null) return 1;
        if (a.Prerelease is not null && b.Prerelease is null) return -1;
        return StringComparer.OrdinalIgnoreCase.Compare(a.Prerelease, b.Prerelease);
    }

    public static bool IsApprovedReleaseUri(Uri uri) => uri.Scheme == Uri.UriSchemeHttps
        && StringComparer.OrdinalIgnoreCase.Equals(uri.Host, "github.com")
        && uri.UserInfo.Length == 0
        && (uri.AbsolutePath == "/xujieyang4j/text-editor/releases"
            || uri.AbsolutePath.StartsWith("/xujieyang4j/text-editor/releases/", StringComparison.Ordinal));

    private static string CurrentArchitecture() => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
    private static string NormalizeVersion(string value) => value.Trim().TrimStart('v', 'V');
    private static (ulong[] Numbers, string? Prerelease) VersionParts(string value)
    {
        var normalized = NormalizeVersion(value).Split('+', 2)[0];
        var pieces = normalized.Split('-', 2);
        return (pieces[0].Split('.').Select(part => UInt64.TryParse(part, out var number) ? number : 0).ToArray(),
            pieces.Length > 1 && pieces[1].Length > 0 ? pieces[1] : null);
    }

    internal static async Task<byte[]> ReadBoundedAsync(HttpContent content, int maximum, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaximumResponseBytes) throw new InvalidDataException("The response is too large.");
        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        using var output = new MemoryStream(Math.Min(maximum, 64 * 1024));
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0) return output.ToArray();
            if (output.Length + count > maximum) throw new InvalidDataException("The response is too large.");
            output.Write(buffer, 0, count);
        }
    }
}
