using System.Text.Json;
using System.Text.Json.Nodes;

namespace LumenEditor.Windows.Core.Build;

public sealed record ProjectKeyBinding(
    string CommandId, string Key, bool Control = false, bool Alt = false, bool Shift = false)
{
    public string Display => String.Join('+', new[]
    {
        Control ? "Ctrl" : null,
        Alt ? "Alt" : null,
        Shift ? "Shift" : null,
        Key
    }.Where(value => value is not null));
}

public sealed record SublimeKeymapImport(IReadOnlyList<ProjectKeyBinding> Bindings, int Skipped);

public static class ProjectKeyBindings
{
    public const int MaximumRules = 200;
    public const int MaximumInspectedRules = 500;

    private static readonly IReadOnlyDictionary<string, string> SublimeCommands =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["save"] = "save", ["save_as"] = "save-as", ["close_file"] = "close-tab",
            ["close_all"] = "close-all-tabs", ["reopen_last_file"] = "reopen-tab",
            ["next_view"] = "next-tab", ["prev_view"] = "prev-tab", ["goto_line"] = "go-to-line",
            ["toggle_comment"] = "toggle-comment", ["toggle_block_comment"] = "toggle-block-comment",
            ["move_line_up"] = "move-line-up", ["move_line_down"] = "move-line-down",
            ["duplicate_line"] = "duplicate-selection", ["delete_line"] = "delete-line",
            ["sort_lines"] = "sort-lines", ["upper_case"] = "to-upper-case",
            ["lower_case"] = "to-lower-case", ["join_lines"] = "join-lines",
            ["indent"] = "indent-selection", ["unindent"] = "outdent-selection",
            ["toggle_setting"] = "toggle-word-wrap", ["build"] = "build",
            ["toggle_side_bar"] = "toggle-sidebar", ["toggle_distraction_free"] = "toggle-distraction-free",
            ["toggle_bookmark"] = "toggle-bookmark", ["next_bookmark"] = "next-bookmark",
            ["prev_bookmark"] = "prev-bookmark", ["show_scope_name"] = "goto-symbol"
        };

    public static SublimeKeymapImport ParseSublime(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > ProjectBuildSettings.MaximumSerializedBytes)
        {
            throw new InvalidDataException("Sublime keymap has an invalid size.");
        }
        JsonNode? parsed;
        try
        {
            parsed = JsonNode.Parse(bytes.ToArray(), documentOptions: new JsonDocumentOptions
            {
                AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip, MaxDepth = 32
            });
        }
        catch (JsonException error) { throw new InvalidDataException("Sublime keymap is not valid JSON with comments.", error); }
        if (parsed is not JsonArray entries) throw new InvalidDataException("Sublime keymap must contain a JSON array.");
        var bindings = new List<ProjectKeyBinding>();
        var skipped = Math.Max(0, entries.Count - MaximumInspectedRules);
        foreach (var value in entries.Take(MaximumInspectedRules))
        {
            if (value is not JsonObject rule
                || StringValue(rule["command"]) is not { } sublimeCommand
                || !SublimeCommands.TryGetValue(sublimeCommand, out var commandId)
                || rule["args"] is JsonObject { Count: > 0 }
                || rule["context"] is JsonArray { Count: > 0 }
                || rule["keys"] is not JsonArray { Count: 1 } keys
                || StringValue(keys[0]) is not { } key
                || !TryParse(key, commandId, out var binding)
                || bindings.Count >= MaximumRules)
            {
                skipped++;
                continue;
            }
            bindings.Add(binding);
        }
        return new(bindings, skipped);
    }

    public static IReadOnlyList<ProjectKeyBinding> ParseProject(JsonElement project)
    {
        if (project.ValueKind != JsonValueKind.Object
            || !project.TryGetProperty("keyBindingRules", out var rules)
            || rules.ValueKind != JsonValueKind.Array) return [];
        var bindings = new List<ProjectKeyBinding>();
        foreach (var rule in rules.EnumerateArray().Take(MaximumRules))
        {
            if (rule.ValueKind != JsonValueKind.Object
                || !rule.TryGetProperty("command", out var command) || command.ValueKind != JsonValueKind.String
                || !rule.TryGetProperty("keys", out var keys)) continue;
            var commandId = command.GetString() ?? String.Empty;
            string? key = keys.ValueKind == JsonValueKind.String ? keys.GetString()
                : keys.ValueKind == JsonValueKind.Array && keys.GetArrayLength() == 1
                    && keys[0].ValueKind == JsonValueKind.String ? keys[0].GetString() : null;
            if (key is not null && TryParse(key, commandId, out var binding)) bindings.Add(binding);
        }
        return bindings;
    }

    public static string Merge(string json, IReadOnlyList<ProjectKeyBinding> incoming)
    {
        var project = ProjectBuildSettings.ParseProject(json);
        var rules = project["keyBindingRules"] as JsonArray ?? new JsonArray();
        project["keyBindingRules"] = rules;
        var keys = incoming.Select(binding => binding.Display).ToHashSet(StringComparer.OrdinalIgnoreCase);
        for (var index = rules.Count - 1; index >= 0; index--)
        {
            if (rules[index] is JsonObject rule && StringValue(rule["keys"]) is { } existing
                && keys.Contains(existing)) rules.RemoveAt(index);
        }
        foreach (var binding in incoming.Reverse())
        {
            rules.Insert(0, new JsonObject { ["keys"] = binding.Display, ["command"] = binding.CommandId });
        }
        while (rules.Count > MaximumRules) rules.RemoveAt(rules.Count - 1);
        return ProjectBuildSettings.Serialize(project);
    }

    public static bool TryParse(string raw, string commandId, out ProjectKeyBinding binding)
    {
        binding = null!;
        if (!LumenEditor.Windows.Core.WindowsCommandCatalog.All.Contains(commandId, StringComparer.Ordinal)) return false;
        var parts = raw.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var control = false;
        var altModifier = false;
        var shift = false;
        string? key = null;
        foreach (var part in parts)
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl": case "control": case "super": case "command": case "cmd": case "mod": control = true; break;
                case "alt": case "option": altModifier = true; break;
                case "shift": shift = true; break;
                default:
                    if (key is not null) return false;
                    key = NormalizeKey(part);
                    if (key is null) return false;
                    break;
            }
        }
        if (key is null) return false;
        binding = new(commandId, key, control, altModifier, shift);
        return true;
    }

    private static string? NormalizeKey(string value)
    {
        var lower = value.ToLowerInvariant();
        if (lower.Length == 1 && Char.IsAsciiLetterOrDigit(lower[0])) return lower.ToUpperInvariant();
        if (lower.Length is 2 or 3 && lower[0] == 'f' && Int32.TryParse(lower[1..], out var number)
            && number is >= 2 and <= 12) return $"F{number}";
        return lower switch
        {
            "up" => "Up", "down" => "Down", "left" => "Left", "right" => "Right",
            "backspace" => "Back", "delete" => "Delete", "enter" or "return" => "Enter",
            "space" => "Space", "tab" => "Tab", "home" => "Home", "end" => "End",
            "pageup" => "PageUp", "pagedown" => "PageDown", "escape" or "esc" => "Escape",
            _ => null
        };
    }

    private static string? StringValue(JsonNode? node) => node is JsonValue value
        && value.TryGetValue<string>(out var text) ? text : null;
}
