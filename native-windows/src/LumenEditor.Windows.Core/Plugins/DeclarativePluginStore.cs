using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Plugins;

public sealed record PluginTextCommand(string Id, string Title, string InsertText);
public sealed record PluginSnippet(string Label, string Text, string? Trigger = null, string? Scope = null);
public enum PluginPermission { DocumentRead, DocumentEdit }
public sealed record PluginExtensionManifest(
    string Worker, IReadOnlyList<PluginPermission> Permissions, Uri? WorkerUrl = null, string? WorkerIntegrity = null);
public sealed record DeclarativePlugin(
    string Id, string Name, string Version, bool Enabled,
    IReadOnlyList<PluginTextCommand> Commands, IReadOnlyList<PluginSnippet> Snippets,
    PluginExtensionManifest? Extension = null);
public sealed record PluginWorkerPackage(
    DeclarativePlugin Manifest, byte[] Source, string SourceIntegrity, IReadOnlyList<PluginPermission> Permissions);

public static class DeclarativePluginParser
{
    public const int MaximumManifestBytes = 1024 * 1024;
    public const int MaximumCommands = 50;
    public const int MaximumSnippets = 100;
    public const int MaximumWorkerBytes = 512 * 1024;
    private static readonly Regex SafeId = new("^[a-z0-9-]+$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex SafeCommandId = new("^[a-z0-9._-]+$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex SafeTrigger = new("^[a-z0-9_-]{1,80}$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static DeclarativePlugin? Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaximumManifestBytes) return null;
        try
        {
            using var json = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !StringProperty(root, "id", 100, out var id) || !SafeId.IsMatch(id)
                || !StringProperty(root, "name", 200, out var name)) return null;
            var version = StringProperty(root, "version", 50, out var parsedVersion) ? parsedVersion : "0.0.0";
            var enabled = !root.TryGetProperty("enabled", out var enabledValue)
                || enabledValue.ValueKind != JsonValueKind.False;
            var commands = new List<PluginTextCommand>();
            if (root.TryGetProperty("commands", out var commandValues) && commandValues.ValueKind == JsonValueKind.Array)
            {
                foreach (var value in commandValues.EnumerateArray())
                {
                    if (commands.Count >= MaximumCommands) break;
                    if (value.ValueKind != JsonValueKind.Object
                        || !StringProperty(value, "id", 100, out var commandId) || !SafeCommandId.IsMatch(commandId)
                        || !StringProperty(value, "title", 200, out var title)
                        || !StringProperty(value, "insertText", 10_000, out var insertText)) continue;
                    commands.Add(new(commandId, title, insertText));
                }
            }
            var snippets = new List<PluginSnippet>();
            if (root.TryGetProperty("snippets", out var snippetValues) && snippetValues.ValueKind == JsonValueKind.Array)
            {
                foreach (var value in snippetValues.EnumerateArray())
                {
                    if (snippets.Count >= MaximumSnippets) break;
                    if (value.ValueKind != JsonValueKind.Object
                        || !StringProperty(value, "label", 200, out var label)
                        || !StringProperty(value, "text", 10_000, out var text)) continue;
                    var trigger = StringProperty(value, "trigger", 80, out var parsedTrigger)
                        && SafeTrigger.IsMatch(parsedTrigger) ? parsedTrigger : null;
                    var scope = StringProperty(value, "scope", 100, out var parsedScope) ? parsedScope : null;
                    snippets.Add(new(label, text, trigger, scope));
                }
            }
            return new(id, name, version, enabled, commands, snippets, ParseExtension(root));
        }
        catch (JsonException) { return null; }
    }

    private static PluginExtensionManifest? ParseExtension(JsonElement root)
    {
        if (!root.TryGetProperty("extension", out var value) || value.ValueKind != JsonValueKind.Object
            || !StringProperty(value, "worker", 500, out var worker) || !SafeWorkerPath(worker)) return null;
        var permissions = new List<PluginPermission>();
        if (value.TryGetProperty("permissions", out var rawPermissions)
            && rawPermissions.ValueKind == JsonValueKind.Array)
        {
            foreach (var permission in rawPermissions.EnumerateArray())
            {
                var parsed = permission.ValueKind == JsonValueKind.String ? permission.GetString() switch
                {
                    "document-read" => PluginPermission.DocumentRead,
                    "document-edit" => PluginPermission.DocumentEdit,
                    _ => (PluginPermission?)null
                } : null;
                if (parsed is { } item && !permissions.Contains(item)) permissions.Add(item);
            }
        }
        Uri? workerUrl = null;
        if (StringProperty(value, "workerUrl", 2_000, out var urlText)
            && Uri.TryCreate(urlText, UriKind.Absolute, out var parsedUrl)
            && MarketplaceClient.IsApprovedHttpsUri(parsedUrl)) workerUrl = parsedUrl;
        var integrity = StringProperty(value, "workerIntegrity", 60, out var rawIntegrity)
            && PluginIntegrity.IsValid(rawIntegrity) ? rawIntegrity : null;
        return new(worker, permissions, workerUrl, integrity);
    }

    private static bool StringProperty(JsonElement root, string name, int maximum, out string value)
    {
        value = String.Empty;
        if (!root.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String) return false;
        value = (element.GetString() ?? String.Empty).Trim();
        if (value.Length > maximum) value = value[..maximum];
        return value.Length > 0;
    }

    public static bool SafeWorkerPath(string value) => !String.IsNullOrWhiteSpace(value)
        && !Path.IsPathFullyQualified(value) && !value.Contains("..", StringComparison.Ordinal)
        && value.All(character => Char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-' or '/');
}

public static class PluginIntegrity
{
    private static readonly Regex Shape = new("^sha256-[A-Za-z0-9+/]{43}=$", RegexOptions.CultureInvariant);
    public static bool IsValid(string value) => Shape.IsMatch(value);
    public static string Compute(ReadOnlySpan<byte> bytes) =>
        "sha256-" + Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(bytes));
    public static bool Matches(string expected, ReadOnlySpan<byte> bytes) =>
        IsValid(expected) && System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(
            Convert.FromBase64String(expected[7..]), System.Security.Cryptography.SHA256.HashData(bytes));
}

public sealed class DeclarativePluginStore
{
    public const int MaximumPlugins = 100;
    private readonly string root;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new PluginPermissionJsonConverter() }
    };

    public DeclarativePluginStore(string workspaceRoot)
    {
        root = Path.GetFullPath(workspaceRoot);
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
    }

    public IReadOnlyList<DeclarativePlugin> Load()
    {
        var directory = Path.Combine(root, ".lumen-plugins");
        if (!Directory.Exists(directory)) return [];
        var result = new List<DeclarativePlugin>();
        foreach (var candidate in Directory.EnumerateDirectories(directory).Take(MaximumPlugins))
        {
            try
            {
                var info = new DirectoryInfo(candidate);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                var manifestPath = Path.Combine(candidate, "plugin.json");
                var manifestInfo = new FileInfo(manifestPath);
                if (!manifestInfo.Exists || manifestInfo.Length is 0 or > DeclarativePluginParser.MaximumManifestBytes) continue;
                var plugin = DeclarativePluginParser.Parse(File.ReadAllBytes(manifestPath));
                if (plugin is null || !plugin.Enabled || !StringComparer.OrdinalIgnoreCase.Equals(plugin.Id, info.Name)) continue;
                result.Add(plugin);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return result.OrderBy(plugin => plugin.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public async Task<DeclarativePlugin> InstallAsync(
        string sourceDirectory, CancellationToken cancellationToken = default)
    {
        var source = Path.GetFullPath(sourceDirectory);
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException(source);
        var sourceInfo = new DirectoryInfo(source);
        if ((sourceInfo.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException("Plugin source cannot be a reparse point.");
        }
        var manifestPath = Path.Combine(source, "plugin.json");
        var info = new FileInfo(manifestPath);
        if (!info.Exists || info.Length is 0 or > DeclarativePluginParser.MaximumManifestBytes)
        {
            throw new InvalidDataException("plugin.json is missing or too large.");
        }
        var manifest = DeclarativePluginParser.Parse(await File.ReadAllBytesAsync(manifestPath, cancellationToken))
            ?? throw new InvalidDataException("plugin.json is invalid.");
        byte[]? worker = null;
        if (manifest.Extension is { } extension) worker = await ReadLocalWorkerAsync(source, extension, cancellationToken);
        var installedManifest = manifest.Extension is null ? manifest : manifest with
        {
            Extension = manifest.Extension with { WorkerUrl = null, WorkerIntegrity = null }
        };
        return await InstallManifestAsync(installedManifest, worker, cancellationToken);
    }

    public async Task<DeclarativePlugin> InstallManifestAsync(
        DeclarativePlugin manifest, byte[]? workerSource = null, CancellationToken cancellationToken = default)
    {
        if (manifest.Extension is null != (workerSource is null))
        {
            throw new InvalidDataException("Plugin worker metadata and source must be installed together.");
        }
        if (workerSource is { Length: 0 })
        {
            throw new InvalidDataException("Plugin worker cannot be empty.");
        }
        if (workerSource is { Length: > DeclarativePluginParser.MaximumWorkerBytes })
        {
            throw new InvalidDataException("Plugin worker exceeds the 512 KiB limit.");
        }
        if (manifest.Extension is { WorkerIntegrity: { } expected } && workerSource is not null
            && !PluginIntegrity.Matches(expected, workerSource))
        {
            throw new InvalidDataException("Plugin worker failed its SHA-256 integrity check.");
        }
        var installedManifest = manifest.Extension is null ? manifest : manifest with
        {
            Extension = manifest.Extension with { WorkerUrl = null, WorkerIntegrity = null }
        };
        if (workerSource is not null)
        {
            try { _ = new System.Text.UTF8Encoding(false, true).GetString(workerSource); }
            catch (System.Text.DecoderFallbackException error)
            {
                throw new InvalidDataException("Plugin worker must be valid UTF-8.", error);
            }
        }
        var sanitizedBytes = JsonSerializer.SerializeToUtf8Bytes(installedManifest, JsonOptions);
        var sanitized = DeclarativePluginParser.Parse(sanitizedBytes)
            ?? throw new InvalidDataException("Plugin manifest is invalid.");
        var pluginsRoot = Path.Combine(root, ".lumen-plugins");
        var target = Path.Combine(pluginsRoot, sanitized.Id);
        if (!WorkspaceTree.IsInside(pluginsRoot, target)) throw new InvalidDataException("Plugin ID escapes its install directory.");
        if (Directory.Exists(target)) throw new IOException($"Plugin {sanitized.Id} is already installed.");
        Directory.CreateDirectory(pluginsRoot);
        var staging = Path.Combine(pluginsRoot, $".{sanitized.Id}.{Guid.NewGuid():N}.tmp");
        Directory.CreateDirectory(staging);
        try
        {
            if (sanitized.Extension is { } extension && workerSource is not null)
            {
                var workerPath = Path.GetFullPath(Path.Combine(staging, extension.Worker.Replace('/', Path.DirectorySeparatorChar)));
                if (!WorkspaceTree.IsInside(staging, workerPath)) throw new InvalidDataException("Plugin worker path escapes its install directory.");
                Directory.CreateDirectory(Path.GetDirectoryName(workerPath)!);
                await File.WriteAllBytesAsync(workerPath, workerSource, cancellationToken);
            }
            await File.WriteAllBytesAsync(Path.Combine(staging, "plugin.json"), sanitizedBytes, cancellationToken);
            Directory.Move(staging, target);
            staging = String.Empty;
            return sanitized;
        }
        catch
        {
            throw;
        }
        finally
        {
            if (staging.Length > 0 && Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    public IReadOnlyList<PluginWorkerPackage> LoadWorkerPackages()
    {
        var result = new List<PluginWorkerPackage>();
        foreach (var manifest in Load())
        {
            if (manifest.Extension is not { } extension) continue;
            var directory = Path.Combine(root, ".lumen-plugins", manifest.Id);
            try
            {
                var source = ReadLocalWorkerAsync(directory, extension, CancellationToken.None).GetAwaiter().GetResult();
                result.Add(new(manifest, source, PluginIntegrity.Compute(source), extension.Permissions));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException
                or InvalidDataException or InvalidOperationException) { }
        }
        return result;
    }

    private static async Task<byte[]> ReadLocalWorkerAsync(
        string sourceDirectory, PluginExtensionManifest extension, CancellationToken cancellationToken)
    {
        var root = Path.GetFullPath(sourceDirectory);
        var candidate = Path.GetFullPath(Path.Combine(root, extension.Worker.Replace('/', Path.DirectorySeparatorChar)));
        if (!WorkspaceTree.IsInside(root, candidate)) throw new InvalidDataException("Plugin worker path escapes its source directory.");
        var current = root;
        var components = Path.GetRelativePath(root, candidate).Split(Path.DirectorySeparatorChar);
        for (var index = 0; index < components.Length; index++)
        {
            current = Path.Combine(current, components[index]);
            FileSystemInfo info = index == components.Length - 1
                ? new FileInfo(current) : new DirectoryInfo(current);
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new InvalidDataException("Plugin worker is missing or uses a reparse point.");
            }
        }
        var workerInfo = new FileInfo(candidate);
        if (workerInfo.Length is <= 0 or > DeclarativePluginParser.MaximumWorkerBytes)
        {
            throw new InvalidDataException("Plugin worker must contain 1 to 512 KiB.");
        }
        return await File.ReadAllBytesAsync(candidate, cancellationToken);
    }
}

public sealed class PluginPermissionJsonConverter : JsonConverter<PluginPermission>
{
    public override PluginPermission Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "document-read" => PluginPermission.DocumentRead,
            "document-edit" => PluginPermission.DocumentEdit,
            _ => throw new JsonException("Unknown plugin permission.")
        } : throw new JsonException("Plugin permission must be a string.");

    public override void Write(Utf8JsonWriter writer, PluginPermission value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value == PluginPermission.DocumentRead ? "document-read" : "document-edit");
}
