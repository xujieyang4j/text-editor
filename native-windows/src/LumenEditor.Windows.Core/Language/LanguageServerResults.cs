using System.Text.Json;
using System.Text;
using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Language;

public sealed record LanguageLocation(string Path, int Line, int Character);
public sealed record LanguageRenameEdit(
    string Path, int StartLine, int StartCharacter, int EndLine, int EndCharacter, string NewText);
public sealed record LanguageDiagnostic(
    string Path, int Line, int Character, int EndLine, int EndCharacter, string Severity, string Message);
public sealed record LanguageDiagnosticSnapshot(
    string Path, int? Version, IReadOnlyList<LanguageDiagnostic> Diagnostics);
public sealed record LanguageTextEdit(
    int StartLine, int StartCharacter, int EndLine, int EndCharacter, string NewText);

public static class LanguageServerResults
{
    public const int MaximumLocations = 5_000;
    public const int MaximumRenameEdits = 5_000;
    public const int MaximumFormattingEdits = 5_000;
    public const int MaximumTextCharacters = 2_000_000;

    public static IReadOnlyList<LanguageCompletionItem> ParseCompletions(JsonElement result) =>
        CompletionEngine.ParseLsp(result);

    public static string ErrorMessage(JsonElement error)
    {
        if (error.ValueKind != JsonValueKind.Object) return "Language server returned an error.";
        var code = error.TryGetProperty("code", out var codeElement) && codeElement.TryGetInt32(out var number)
            ? number.ToString() : "unknown";
        var message = error.TryGetProperty("message", out var messageElement)
            && messageElement.ValueKind == JsonValueKind.String
            ? messageElement.GetString() ?? "Language server error"
            : "Language server error";
        if (message.Length > 2_000) message = message[..2_000];
        return $"Language server error {code}: {message}";
    }

    public static string? ParseHover(JsonElement result)
    {
        if (result.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("contents", out var contents)) return null;
        var text = FlattenMarkedContent(contents);
        return String.IsNullOrWhiteSpace(text) ? null : Bound(text);
    }

    public static IReadOnlyList<LanguageLocation> ParseLocations(JsonElement result, string root)
    {
        var values = result.ValueKind == JsonValueKind.Array
            ? result.EnumerateArray()
            : result.ValueKind == JsonValueKind.Object
                ? new[] { result }.AsEnumerable()
                : [];
        var locations = new List<LanguageLocation>();
        foreach (var value in values)
        {
            if (locations.Count >= MaximumLocations || value.ValueKind != JsonValueKind.Object) break;
            if (!value.TryGetProperty("uri", out var uriElement) || uriElement.ValueKind != JsonValueKind.String
                || !value.TryGetProperty("range", out var range)
                || !range.TryGetProperty("start", out var start)
                || !TryFilePath(uriElement.GetString(), root, out var path)) continue;
            locations.Add(new(path, Position(start, "line"), Position(start, "character")));
        }
        return locations;
    }

    public static IReadOnlyList<LanguageRenameEdit> ParseRenameEdits(JsonElement result, string root)
    {
        var edits = new List<LanguageRenameEdit>();
        if (result.ValueKind != JsonValueKind.Object
            || !result.TryGetProperty("changes", out var changes)
            || changes.ValueKind != JsonValueKind.Object) return edits;
        foreach (var file in changes.EnumerateObject())
        {
            if (!TryFilePath(file.Name, root, out var path) || file.Value.ValueKind != JsonValueKind.Array) continue;
            foreach (var edit in file.Value.EnumerateArray())
            {
                if (edits.Count >= MaximumRenameEdits) return edits;
                if (edit.ValueKind != JsonValueKind.Object
                    || !edit.TryGetProperty("range", out var range)
                    || !range.TryGetProperty("start", out var start)
                    || !range.TryGetProperty("end", out var end)
                    || !edit.TryGetProperty("newText", out var newText)
                    || newText.ValueKind != JsonValueKind.String) continue;
                var text = newText.GetString() ?? String.Empty;
                if (text.Length > MaximumTextCharacters) continue;
                edits.Add(new(path, Position(start, "line"), Position(start, "character"),
                    Position(end, "line"), Position(end, "character"), text));
            }
        }
        return edits;
    }

    public static IReadOnlyList<LanguageTextEdit> ParseFormattingEdits(JsonElement result)
    {
        if (result.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return [];
        if (result.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Formatting result must be an array.");
        var edits = new List<LanguageTextEdit>();
        var totalCharacters = 0L;
        foreach (var edit in result.EnumerateArray())
        {
            if (edits.Count >= MaximumFormattingEdits)
            {
                throw new InvalidDataException("Formatting result contains too many edits.");
            }
            if (edit.ValueKind != JsonValueKind.Object
                || !edit.TryGetProperty("range", out var range)
                || !range.TryGetProperty("start", out var start)
                || !range.TryGetProperty("end", out var end)
                || !edit.TryGetProperty("newText", out var newText)
                || newText.ValueKind != JsonValueKind.String)
            {
                throw new InvalidDataException("Formatting result contains an invalid edit.");
            }
            var text = newText.GetString() ?? String.Empty;
            totalCharacters += text.Length;
            if (totalCharacters > MaximumTextCharacters)
            {
                throw new InvalidDataException("Formatting replacement text is too large.");
            }
            edits.Add(new(RequiredPosition(start, "line"), RequiredPosition(start, "character"),
                RequiredPosition(end, "line"), RequiredPosition(end, "character"), text));
        }
        return edits;
    }

    public static string ApplyFormattingEdits(string source, IReadOnlyList<LanguageTextEdit> edits)
    {
        if (source.Length > MaximumTextCharacters || edits.Count > MaximumFormattingEdits)
        {
            throw new InvalidDataException("Formatting input exceeds the supported limit.");
        }
        var resolved = edits.Select(edit =>
        {
            var start = PositionOffset(source, edit.StartLine, edit.StartCharacter);
            var end = PositionOffset(source, edit.EndLine, edit.EndCharacter);
            if (end < start) throw new InvalidDataException("Formatting edit range is reversed.");
            return (Start: start, End: end, NewText: TextFileCodec.NormalizeLineEndings(edit.NewText));
        }).OrderBy(edit => edit.Start).ThenBy(edit => edit.End).ToList();
        for (var index = 1; index < resolved.Count; index++)
        {
            if (resolved[index].Start < resolved[index - 1].End)
            {
                throw new InvalidDataException("Formatting edits overlap.");
            }
        }
        var projectedLength = (long)source.Length + resolved.Sum(edit =>
            (long)edit.NewText.Length - (edit.End - edit.Start));
        if (projectedLength is < 0 or > MaximumTextCharacters)
        {
            throw new InvalidDataException("Formatted document exceeds the supported limit.");
        }
        var output = new StringBuilder(source);
        foreach (var edit in resolved.OrderByDescending(edit => edit.Start))
        {
            output.Remove(edit.Start, edit.End - edit.Start);
            output.Insert(edit.Start, edit.NewText);
        }
        return output.ToString();
    }

    public static IReadOnlyList<LanguageDiagnostic> ParseDiagnostics(JsonElement message, string root)
    {
        return ParseDiagnosticSnapshot(message, root)?.Diagnostics ?? [];
    }

    public static LanguageDiagnosticSnapshot? ParseDiagnosticSnapshot(JsonElement message, string root)
    {
        var diagnostics = new List<LanguageDiagnostic>();
        if (message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("method", out var method)
            || method.GetString() != "textDocument/publishDiagnostics"
            || !message.TryGetProperty("params", out var parameters)
            || !parameters.TryGetProperty("uri", out var uri)
            || !TryFilePath(uri.GetString(), root, out var path)
            || !parameters.TryGetProperty("diagnostics", out var values)
            || values.ValueKind != JsonValueKind.Array) return null;
        int? version = null;
        if (parameters.TryGetProperty("version", out var versionValue)
            && versionValue.ValueKind is not JsonValueKind.Null)
        {
            if (!versionValue.TryGetInt32(out var parsedVersion) || parsedVersion < 0) return null;
            version = parsedVersion;
        }
        foreach (var value in values.EnumerateArray().Take(1_000))
        {
            if (value.ValueKind != JsonValueKind.Object
                || !value.TryGetProperty("range", out var range)
                || !range.TryGetProperty("start", out var start)
                || !range.TryGetProperty("end", out var end)
                || !value.TryGetProperty("message", out var diagnosticMessage)
                || diagnosticMessage.ValueKind != JsonValueKind.String) continue;
            var text = diagnosticMessage.GetString() ?? "Language-server diagnostic";
            if (text.Length > 2_000) text = text[..2_000];
            var severity = value.TryGetProperty("severity", out var severityValue)
                && severityValue.TryGetInt32(out var level)
                ? level switch { 2 => "warning", 3 or 4 => "info", _ => "error" }
                : "error";
            diagnostics.Add(new(path, Position(start, "line"), Position(start, "character"),
                Position(end, "line"), Position(end, "character"), severity, text));
        }
        return new(path, version, diagnostics);
    }

    private static string FlattenMarkedContent(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String) return value.GetString() ?? String.Empty;
        if (value.ValueKind == JsonValueKind.Object)
        {
            if (value.TryGetProperty("value", out var text) && text.ValueKind == JsonValueKind.String)
            {
                return text.GetString() ?? String.Empty;
            }
            return String.Empty;
        }
        if (value.ValueKind != JsonValueKind.Array) return String.Empty;
        return String.Join("\n\n", value.EnumerateArray().Select(FlattenMarkedContent).Where(text => text.Length > 0));
    }

    private static int Position(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var number)
            && number.TryGetInt32(out var parsed) ? Math.Max(0, parsed) : 0;

    private static int RequiredPosition(JsonElement value, string property)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(property, out var number)
            || !number.TryGetInt32(out var parsed) || parsed < 0)
        {
            throw new InvalidDataException("Formatting edit contains an invalid position.");
        }
        return parsed;
    }

    private static int PositionOffset(string source, int line, int character)
    {
        var offset = 0;
        for (var currentLine = 0; currentLine < line; currentLine++)
        {
            var newline = source.IndexOf('\n', offset);
            if (newline < 0) throw new InvalidDataException("Formatting edit line is outside the document.");
            offset = newline + 1;
        }
        var lineEnd = source.IndexOf('\n', offset);
        if (lineEnd < 0) lineEnd = source.Length;
        var position = offset + character;
        if (position > lineEnd || position < offset
            || (position > 0 && position < source.Length
                && Char.IsHighSurrogate(source[position - 1]) && Char.IsLowSurrogate(source[position])))
        {
            throw new InvalidDataException("Formatting edit character is outside a UTF-16 boundary.");
        }
        return position;
    }

    private static bool TryFilePath(string? uriText, string root, out string path)
    {
        path = String.Empty;
        if (!Uri.TryCreate(uriText, UriKind.Absolute, out var uri) || !uri.IsFile) return false;
        try { path = Path.GetFullPath(uri.LocalPath); }
        catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException) { return false; }
        return WorkspaceTree.IsInside(root, path);
    }

    private static string Bound(string text) => text.Length <= MaximumTextCharacters
        ? text : text[..MaximumTextCharacters] + "\n[Language-server result truncated.]";
}
