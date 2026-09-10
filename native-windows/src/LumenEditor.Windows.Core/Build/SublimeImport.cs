using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml;
using System.Xml.Linq;
using LumenEditor.Windows.Core.Plugins;
using LumenEditor.Windows.Core.Settings;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Build;

public sealed record SublimeProjectImport(
    IReadOnlyList<string> Roots,
    IReadOnlyList<string> Exclusions,
    IReadOnlyList<ProjectBuildSystemImport> BuildSystems);

public sealed record SublimeSettingsImport(EditorSettings Settings, IReadOnlyList<string> Changes);

public static class SublimeImport
{
    public const int MaximumBytes = 1024 * 1024;
    public const int MaximumSnippetBytes = 128 * 1024;
    public const int MaximumRoots = 20;
    public const int MaximumExclusions = 100;

    public static SublimeProjectImport ParseProject(ReadOnlySpan<byte> bytes, string sourcePath)
    {
        var root = ParseJson(bytes, comments: false);
        var baseDirectory = Path.GetDirectoryName(Path.GetFullPath(sourcePath))
            ?? throw new InvalidDataException("Sublime project has no parent directory.");
        var roots = new List<string>();
        var exclusions = new List<string>();
        if (root["folders"] is JsonArray folders)
        {
            foreach (var value in folders.Take(MaximumRoots))
            {
                if (value is not JsonObject folder || StringValue(folder["path"]) is not { } candidate) continue;
                try
                {
                    var path = Path.GetFullPath(Path.IsPathFullyQualified(candidate)
                        ? candidate : Path.Combine(baseDirectory, candidate));
                    if (Directory.Exists(path) && !roots.Contains(path, StringComparer.OrdinalIgnoreCase)) roots.Add(path);
                }
                catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException) { }
                foreach (var key in new[] { "file_exclude_patterns", "folder_exclude_patterns" })
                {
                    if (folder[key] is not JsonArray patterns) continue;
                    foreach (var pattern in patterns.OfType<JsonValue>())
                    {
                        if (exclusions.Count >= MaximumExclusions) break;
                        if (!pattern.TryGetValue<string>(out var text) || String.IsNullOrWhiteSpace(text)) continue;
                        var normalized = text.Contains('*') ? text : $"**/{text}/**";
                        exclusions.Add(Bound(normalized, 200));
                    }
                }
            }
        }
        if (roots.Count == 0) throw new InvalidDataException("The Sublime project contains no existing folders.");
        var systems = new List<ProjectBuildSystemImport>();
        if (root["build_systems"] is JsonArray builds)
        {
            foreach (var value in builds.Take(ProjectBuildSettings.MaximumBuildSystems))
            {
                if (value is not JsonObject build) continue;
                var imported = ParseBuildObject(build, null);
                if (imported is not null) systems.Add(imported);
            }
        }
        return new(roots, exclusions.Distinct(StringComparer.Ordinal).ToList(), systems);
    }

    public static SublimeSettingsImport ParseSettings(ReadOnlySpan<byte> bytes, EditorSettings current)
    {
        var root = ParseJson(bytes, comments: true);
        var next = current;
        var changes = new List<string>();
        void Change<T>(string name, T oldValue, T nextValue, Func<EditorSettings, T, EditorSettings> apply)
        {
            if (EqualityComparer<T>.Default.Equals(oldValue, nextValue)) return;
            next = apply(next, nextValue);
            changes.Add($"{name}: {oldValue} → {nextValue}");
        }
        if (Number(root["font_size"]) is { } font) Change("fontSize", next.FontSize,
            Math.Clamp((int)Math.Round(font), 8, 40), (value, updated) => value with { FontSize = updated });
        if (Number(root["tab_size"]) is { } tab) Change("tabSize", next.TabSize,
            Math.Clamp((int)Math.Round(tab), 1, 16), (value, updated) => value with { TabSize = updated });
        if (Boolean(root["translate_tabs_to_spaces"]) is { } spaces) Change("insertSpaces", next.InsertSpaces,
            spaces, (value, updated) => value with { InsertSpaces = updated });
        if (Boolean(root["word_wrap"]) is { } wrap) Change("wordWrap", next.WordWrap,
            wrap, (value, updated) => value with { WordWrap = updated });
        if (Boolean(root["line_numbers"]) is { } lineNumbers) Change("showLineNumbers", next.ShowLineNumbers,
            lineNumbers, (value, updated) => value with { ShowLineNumbers = updated });
        if (StringValue(root["draw_white_space"]) is { } whitespace) Change("showWhitespace", next.ShowWhitespace,
            whitespace is "all" or "selection", (value, updated) => value with { ShowWhitespace = updated });
        if (Boolean(root["mini_map"]) is { } minimap) Change("showMinimap", next.ShowMinimap,
            minimap, (value, updated) => value with { ShowMinimap = updated });
        if (Boolean(root["draw_indent_guides"]) is { } indentGuides) Change("showIndentGuides",
            next.ShowIndentGuides, indentGuides, (value, updated) => value with { ShowIndentGuides = updated });
        if (root["rulers"] is JsonArray rulerValues)
        {
            var rulers = rulerValues.Select(Number).OfType<double>()
                .Select(value => (int)Math.Round(value)).Where(value => value is >= 1 and <= 500)
                .Take(10).ToArray();
            if (!rulers.SequenceEqual(next.Rulers ?? []))
            {
                changes.Add($"rulers: {String.Join(',', next.Rulers ?? [])} → {String.Join(',', rulers)}");
                next = next with { Rulers = rulers };
            }
        }
        if (Boolean(root["spell_check"]) is { } spell) Change("spellCheck", next.SpellCheck,
            spell, (value, updated) => value with { SpellCheck = updated });
        if (StringValue(root["auto_save"]) is { } autoSave)
        {
            var mode = autoSave switch
            {
                "after_delay" => AutoSaveMode.AfterDelay,
                "on_focus_change" => AutoSaveMode.OnFocusChange,
                "off" => AutoSaveMode.Off,
                _ => next.AutoSave
            };
            Change("autoSave", next.AutoSave, mode, (value, updated) => value with { AutoSave = updated });
        }
        if (Number(root["auto_save_delay"]) is { } delay) Change("autoSaveDelayMs", next.AutoSaveDelayMs,
            Math.Clamp((int)Math.Round(delay), 250, 60_000), (value, updated) => value with { AutoSaveDelayMs = updated });
        if (StringValue(root["color_scheme"]) is { } scheme)
        {
            var theme = scheme.Contains("light", StringComparison.OrdinalIgnoreCase) ? EditorTheme.Light : EditorTheme.Dark;
            Change("theme", next.Theme, theme, (value, updated) => value with { Theme = updated });
            var colorScheme = scheme.Contains("solarized", StringComparison.OrdinalIgnoreCase)
                ? EditorColorScheme.SolarizedDark
                : scheme.Contains("dracula", StringComparison.OrdinalIgnoreCase)
                    ? EditorColorScheme.Dracula
                    : theme == EditorTheme.Light ? EditorColorScheme.Light : EditorColorScheme.Dark;
            Change("colorScheme", next.ColorScheme, colorScheme,
                (value, updated) => value with { ColorScheme = updated });
        }
        return new(EditorSettings.Sanitize(next), changes);
    }

    public static PluginSnippet ParseSnippet(ReadOnlySpan<byte> bytes, string sourcePath)
    {
        if (bytes.Length is 0 or > MaximumSnippetBytes) throw new InvalidDataException("Sublime snippet has an invalid size.");
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaximumSnippetBytes
        };
        string? content = null;
        string? trigger = null;
        string? scope = null;
        try
        {
            using var stream = new MemoryStream(bytes.ToArray());
            using var reader = XmlReader.Create(stream, settings);
            var document = XDocument.Load(reader, LoadOptions.PreserveWhitespace);
            content = document.Descendants().FirstOrDefault(element => element.Name.LocalName == "content")?.Value;
            trigger = document.Descendants().FirstOrDefault(element => element.Name.LocalName == "tabTrigger")?.Value;
            scope = document.Descendants().FirstOrDefault(element => element.Name.LocalName == "scope")?.Value;
        }
        catch (XmlException error) { throw new InvalidDataException("Sublime snippet is not valid safe XML.", error); }
        if (String.IsNullOrEmpty(content) || content.Length > 10_000)
        {
            throw new InvalidDataException("Sublime snippet content is missing or too large.");
        }
        trigger = trigger is { Length: > 0 and <= 80 } && trigger.All(character => Char.IsAsciiLetterOrDigit(character)
            || character is '_' or '-') ? trigger : null;
        scope = String.IsNullOrWhiteSpace(scope) ? null : Bound(scope, 100);
        return new(Bound(Path.GetFileNameWithoutExtension(sourcePath), 200), content, trigger, scope);
    }

    public static string MergeProject(string json, SublimeProjectImport imported)
    {
        var project = ProjectBuildSettings.ParseProject(json);
        project["exclude"] = new JsonArray(imported.Exclusions.Take(MaximumExclusions)
            .Select(value => JsonValue.Create(value)).ToArray());
        foreach (var system in imported.BuildSystems.Reverse())
        {
            json = ProjectBuildSettings.MergeBuildSystem(ProjectBuildSettings.Serialize(project), system);
            project = ProjectBuildSettings.ParseProject(json);
        }
        return ProjectBuildSettings.Serialize(project);
    }

    public static string MergeSnippet(string json, PluginSnippet snippet)
    {
        var project = ProjectBuildSettings.ParseProject(json);
        var snippets = project["snippets"] as JsonArray ?? new JsonArray();
        project["snippets"] = snippets;
        var value = new JsonObject { ["label"] = snippet.Label, ["text"] = snippet.Text };
        if (snippet.Trigger is not null) value["trigger"] = snippet.Trigger;
        if (snippet.Scope is not null) value["scope"] = snippet.Scope;
        snippets.Insert(0, value);
        while (snippets.Count > 500) snippets.RemoveAt(snippets.Count - 1);
        return ProjectBuildSettings.Serialize(project);
    }

    public static IReadOnlyList<PluginSnippet> ParseProjectSnippets(JsonElement project)
    {
        if (project.ValueKind != JsonValueKind.Object || !project.TryGetProperty("snippets", out var values)
            || values.ValueKind != JsonValueKind.Array) return [];
        var snippets = new List<PluginSnippet>();
        foreach (var value in values.EnumerateArray().Take(500))
        {
            if (value.ValueKind != JsonValueKind.Object || !Text(value, "label", 200, out var label)
                || !Text(value, "text", 10_000, out var text)) continue;
            var trigger = Text(value, "trigger", 80, out var parsedTrigger) ? parsedTrigger : null;
            var scope = Text(value, "scope", 100, out var parsedScope) ? parsedScope : null;
            snippets.Add(new(label, text, trigger, scope));
        }
        return snippets;
    }

    private static JsonObject ParseJson(ReadOnlySpan<byte> bytes, bool comments)
    {
        if (bytes.Length is 0 or > MaximumBytes) throw new InvalidDataException("Sublime import has an invalid size.");
        try
        {
            return JsonNode.Parse(bytes.ToArray(), documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = comments,
                CommentHandling = comments ? JsonCommentHandling.Skip : JsonCommentHandling.Disallow,
                MaxDepth = 32
            }) as JsonObject ?? throw new InvalidDataException("Sublime import must contain a JSON object.");
        }
        catch (JsonException error) { throw new InvalidDataException("Sublime import is not valid JSON.", error); }
    }

    private static ProjectBuildSystemImport? ParseBuildObject(JsonObject source, string? fallbackName)
    {
        if (source["cmd"] is not JsonArray command || command.Count == 0
            || command.Any(value => value is not JsonValue || !value.AsValue().TryGetValue<string>(out _))) return null;
        var parts = command.Select(value => value!.GetValue<string>()).Take(ProjectBuildSettings.MaximumArguments + 1).ToList();
        if (String.IsNullOrWhiteSpace(parts[0]) || parts[0].Contains('\0')) return null;
        var name = StringValue(source["name"]) ?? fallbackName ?? parts[0];
        return new(Bound(name, 100), Bound(parts[0], 1_000), parts.Skip(1).Select(value => Bound(value, 32 * 1024)).ToList(),
            StringValue(source["working_dir"]), null, Boolean(source["save_before_build"]) == true);
    }

    private static string? StringValue(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var result) ? result : null;
    private static double? Number(JsonNode? node) => node is JsonValue value && value.TryGetValue<double>(out var result) && Double.IsFinite(result) ? result : null;
    private static bool? Boolean(JsonNode? node) => node is JsonValue value && value.TryGetValue<bool>(out var result) ? result : null;
    private static string Bound(string value, int maximum) => value.Length <= maximum ? value : value[..maximum];
    private static bool Text(JsonElement root, string name, int maximum, out string value)
    {
        value = String.Empty;
        if (!root.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString() ?? String.Empty;
        if (value.Length > maximum) value = value[..maximum];
        return value.Length > 0;
    }
}
