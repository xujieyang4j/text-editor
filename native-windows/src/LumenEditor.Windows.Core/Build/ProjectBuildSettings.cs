using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Build;

public sealed record ProjectBuildSystemImport(
    string Name, string Command, IReadOnlyList<string> Arguments,
    string? WorkingDirectory = null,
    IReadOnlyDictionary<string, string?>? Environment = null,
    bool SaveBeforeBuild = false);

public sealed record ProjectSettingsSnapshot(
    string Json, string? Revision, IReadOnlyList<DetectedBuildSystem> BuildSystems,
    IReadOnlyList<string> Exclusions);

public static class ProjectBuildSettings
{
    public const int MaximumSerializedBytes = 1024 * 1024;
    public const int MaximumBuildSystems = 30;
    public const int MaximumVariantsPerSystem = 20;
    public const int MaximumArguments = 50;
    public const int MaximumEnvironmentVariables = 100;

    public static IReadOnlyList<DetectedBuildSystem> ParseBuildSystems(string root, JsonObject project)
    {
        var systems = new List<DetectedBuildSystem>();
        if (project["buildSystems"] is not JsonArray values) return systems;
        for (var index = 0; index < values.Count && index < MaximumBuildSystems; index++)
        {
            if (values[index] is not JsonObject source) continue;
            var system = ParseOne(root, source, $"project-{index}", null);
            if (system is null) continue;
            systems.Add(system);
            if (source["variants"] is not JsonArray variants) continue;
            for (var variantIndex = 0; variantIndex < variants.Count
                && variantIndex < MaximumVariantsPerSystem; variantIndex++)
            {
                if (variants[variantIndex] is not JsonObject variant) continue;
                var resolved = ParseOne(root, variant, $"project-{index}-variant-{variantIndex}", system);
                if (resolved is not null) systems.Add(resolved);
            }
        }
        return systems;
    }

    public static IReadOnlyList<string> ParseExclusions(JsonObject project)
    {
        if (project["exclude"] is not JsonArray values) return [];
        var patterns = new List<string>();
        foreach (var value in values)
        {
            if (value is JsonValue scalar && scalar.TryGetValue<string>(out var pattern)) patterns.Add(pattern);
        }
        return new WorkspaceExclusionPolicy(patterns).Patterns;
    }

    public static IReadOnlyList<string> ParsePluginIds(JsonObject project)
    {
        if (project["plugins"] is not JsonArray values) return [];
        return values.OfType<JsonValue>().Select(value => value.TryGetValue<string>(out var id) ? id : null)
            .Where(id => id is not null && System.Text.RegularExpressions.Regex.IsMatch(
                id, "^[a-z0-9-]+$", System.Text.RegularExpressions.RegexOptions.IgnoreCase
                    | System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            .Cast<string>().Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToList();
    }

    public static IReadOnlyDictionary<string, IReadOnlyList<Plugins.PluginPermission>> ParsePluginPermissions(JsonObject project)
    {
        var result = new Dictionary<string, IReadOnlyList<Plugins.PluginPermission>>(StringComparer.OrdinalIgnoreCase);
        if (project["pluginPermissions"] is not JsonObject values) return result;
        foreach (var pair in values.Take(100))
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(pair.Key, "^[a-z0-9-]+$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant)
                || pair.Value is not JsonArray permissions) continue;
            result[pair.Key] = permissions.OfType<JsonValue>().Select(value => value.TryGetValue<string>(out var item)
                ? item switch
                {
                    "document-read" => Plugins.PluginPermission.DocumentRead,
                    "document-edit" => Plugins.PluginPermission.DocumentEdit,
                    _ => (Plugins.PluginPermission?)null
                } : null).OfType<Plugins.PluginPermission>().Distinct().ToList();
        }
        return result;
    }

    public static string MergePluginPermissions(
        string json, string pluginId, IReadOnlyList<Plugins.PluginPermission> permissions)
    {
        var project = ParseProject(json);
        var grants = project["pluginPermissions"] as JsonObject ?? new JsonObject();
        project["pluginPermissions"] = grants;
        grants[pluginId] = new JsonArray(permissions.Distinct().Select(permission =>
            JsonValue.Create(permission == Plugins.PluginPermission.DocumentRead ? "document-read" : "document-edit")).ToArray());
        return Serialize(project);
    }

    public static string EnablePlugin(string json, string pluginId)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(pluginId, "^[a-z0-9-]+$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            throw new InvalidDataException("Plugin ID is invalid.");
        var project = ParseProject(json);
        var plugins = project["plugins"] as JsonArray ?? new JsonArray();
        project["plugins"] = plugins;
        if (!plugins.OfType<JsonValue>().Any(value => value.TryGetValue<string>(out var id)
            && StringComparer.OrdinalIgnoreCase.Equals(id, pluginId))) plugins.Add(pluginId);
        while (plugins.Count > 100) plugins.RemoveAt(0);
        return Serialize(project);
    }

    public static ProjectBuildSystemImport ParseSublimeBuild(ReadOnlySpan<byte> bytes, string sourcePath)
    {
        if (bytes.Length > MaximumSerializedBytes) throw new InvalidDataException("Sublime build file is too large.");
        JsonNode? parsed;
        try
        {
            parsed = JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
                MaxDepth = 32
            });
        }
        catch (JsonException error) { throw new InvalidDataException("Sublime build file is not valid JSON with comments.", error); }
        if (parsed is not JsonObject source) throw new InvalidDataException("Sublime build file must contain a JSON object.");
        if (source["cmd"] is not JsonArray cmd || cmd.Count == 0
            || cmd.Any(value => value is not JsonValue || !value.AsValue().TryGetValue<string>(out _)))
        {
            if (source["shell_cmd"] is JsonValue)
            {
                throw new InvalidDataException("shell_cmd is not imported because native Windows builds never execute project shell strings.");
            }
            throw new InvalidDataException("Sublime build file must declare a non-empty string cmd array.");
        }
        var parts = cmd.Select(value => value!.GetValue<string>()).Take(MaximumArguments + 1).ToList();
        var command = Bound(parts[0], 1_000);
        if (String.IsNullOrWhiteSpace(command) || command.Contains('\0'))
        {
            throw new InvalidDataException("Sublime build executable is invalid.");
        }
        var fallbackName = Path.GetFileNameWithoutExtension(sourcePath);
        return new(
            Bound(StringValue(source["name"]) ?? fallbackName, 100), command,
            parts.Skip(1).Select(argument => Bound(argument, 32 * 1024)).ToList(),
            BoundNullable(StringValue(source["working_dir"]), 500),
            ParseEnvironment(source["env"]), BoolValue(source["save_before_build"]));
    }

    public static string MergeBuildSystem(string json, ProjectBuildSystemImport imported)
    {
        var project = ParseProject(json);
        var systems = project["buildSystems"] as JsonArray ?? new JsonArray();
        project["buildSystems"] = systems;
        for (var index = systems.Count - 1; index >= 0; index--)
        {
            if (systems[index] is JsonObject existing
                && StringComparer.OrdinalIgnoreCase.Equals(StringValue(existing["name"]), imported.Name))
            {
                systems.RemoveAt(index);
            }
        }
        var value = new JsonObject
        {
            ["name"] = Bound(imported.Name, 100),
            ["command"] = Bound(imported.Command, 1_000),
            ["args"] = new JsonArray(imported.Arguments.Take(MaximumArguments)
                .Select(argument => JsonValue.Create(Bound(argument, 32 * 1024))).ToArray()),
            ["saveBeforeBuild"] = imported.SaveBeforeBuild
        };
        if (!String.IsNullOrWhiteSpace(imported.WorkingDirectory)) value["workingDirectory"] = Bound(imported.WorkingDirectory, 500);
        if (imported.Environment is { Count: > 0 })
        {
            value["env"] = new JsonObject(imported.Environment.Take(MaximumEnvironmentVariables)
                .ToDictionary(pair => pair.Key, pair => (JsonNode?)JsonValue.Create(pair.Value)));
        }
        systems.Insert(0, value);
        while (systems.Count > MaximumBuildSystems) systems.RemoveAt(systems.Count - 1);
        return Serialize(project);
    }

    public static JsonObject ParseProject(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > MaximumSerializedBytes) throw new InvalidDataException("Project settings exceed the 1 MiB limit.");
        try
        {
            return JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { MaxDepth = 32 }) as JsonObject
                ?? throw new InvalidDataException("Project settings must contain a JSON object.");
        }
        catch (JsonException error) { throw new InvalidDataException("Project settings are not valid JSON.", error); }
    }

    public static string Serialize(JsonObject project)
    {
        var json = project.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        if (Encoding.UTF8.GetByteCount(json) > MaximumSerializedBytes) throw new InvalidDataException("Project settings exceed the 1 MiB limit.");
        return json + "\n";
    }

    private static DetectedBuildSystem? ParseOne(string root, JsonObject source, string id, DetectedBuildSystem? inherited)
    {
        if (BoolValue(source["shell"])) return null;
        var command = BoundNullable(StringValue(source["command"]), 1_000) ?? inherited?.Executable;
        var name = BoundNullable(StringValue(source["name"]), 100);
        if (String.IsNullOrWhiteSpace(command) || command.Contains('\0') || String.IsNullOrWhiteSpace(name)) return null;
        var arguments = source["args"] is JsonArray rawArguments
            ? rawArguments.OfType<JsonValue>().Select(value => value.TryGetValue<string>(out var text) ? text : null)
                .Where(text => text is not null && !text.Contains('\0')).Cast<string>()
                .Take(MaximumArguments).Select(argument => Bound(argument, 32 * 1024)).ToList()
            : inherited?.Arguments.ToList() ?? [];
        var workingDirectory = ResolveWorkingDirectory(root, BoundNullable(StringValue(source["workingDirectory"]), 500))
            ?? inherited?.WorkingDirectory ?? root;
        if (!WorkspaceTree.IsInside(root, workingDirectory) || !Directory.Exists(workingDirectory)) return null;
        var environment = source["env"] is null ? inherited?.Environment : ParseEnvironment(source["env"]);
        return new(id, inherited is null ? name : $"{inherited.Name}: {name}", command, arguments,
            workingDirectory, environment, BoolValue(source["saveBeforeBuild"]) || inherited?.SaveBeforeBuild == true);
    }

    private static string? ResolveWorkingDirectory(string root, string? value)
    {
        if (String.IsNullOrWhiteSpace(value)) return root;
        var expanded = value.Replace("${project_path}", root, StringComparison.OrdinalIgnoreCase)
            .Replace("$project_path", root, StringComparison.OrdinalIgnoreCase);
        try { return Path.GetFullPath(Path.IsPathFullyQualified(expanded) ? expanded : Path.Combine(root, expanded)); }
        catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException) { return null; }
    }

    private static IReadOnlyDictionary<string, string?> ParseEnvironment(JsonNode? node)
    {
        if (node is not JsonObject values) return new Dictionary<string, string?>();
        var result = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in values.Take(MaximumEnvironmentVariables))
        {
            if (pair.Key.Length is < 1 or > 256 || pair.Key.Contains('\0')
                || pair.Value is not JsonValue value || !value.TryGetValue<string>(out var text)
                || text.Contains('\0')) continue;
            result[pair.Key] = Bound(text, 32 * 1024);
        }
        return result;
    }

    private static string? StringValue(JsonNode? node) => node is JsonValue value
        && value.TryGetValue<string>(out var text) ? text : null;
    private static bool BoolValue(JsonNode? node) => node is JsonValue value
        && value.TryGetValue<bool>(out var result) && result;
    private static string Bound(string value, int maximum) => value.Length <= maximum ? value : value[..maximum];
    private static string? BoundNullable(string? value, int maximum) => value is null ? null : Bound(value, maximum);
}

public sealed class ProjectSettingsStore(string root)
{
    public const string FileName = ".lumen-project.json";
    private readonly string normalizedRoot = WorkspaceRoots.Normalize([root]).FirstOrDefault()
        ?? throw new DirectoryNotFoundException("Workspace root is unavailable.");
    private string Path => System.IO.Path.Combine(normalizedRoot, FileName);

    public async Task<ProjectSettingsSnapshot> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(Path)) return new("{}\n", null, [], []);
        var info = new FileInfo(Path);
        if (info.Length > ProjectBuildSettings.MaximumSerializedBytes || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new InvalidDataException("Project settings are too large or use a reparse point.");
        }
        var bytes = await File.ReadAllBytesAsync(Path, cancellationToken);
        string json;
        try { json = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException error) { throw new InvalidDataException("Project settings must be valid UTF-8.", error); }
        var project = ProjectBuildSettings.ParseProject(json);
        return new(
            json, FileWriteService.ComputeRevision(bytes),
            ProjectBuildSettings.ParseBuildSystems(normalizedRoot, project),
            ProjectBuildSettings.ParseExclusions(project));
    }

    public async Task<FileWriteResult> SaveAsync(string json, string? expectedRevision, CancellationToken cancellationToken = default)
    {
        var project = ProjectBuildSettings.ParseProject(json);
        var normalized = ProjectBuildSettings.Serialize(project);
        if (File.Exists(Path) && new FileInfo(Path).Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            return new(false, null, FileWriteFailure.NotARegularFile, "Project settings cannot be a reparse point.");
        }
        return await new FileWriteService().SaveAsync(Path, normalized, TextEncodingKind.Utf8, LineEnding.Lf, expectedRevision, cancellationToken);
    }
}
