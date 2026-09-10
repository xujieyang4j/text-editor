using System.Text.Json;
using System.Text.RegularExpressions;

namespace LumenEditor.Windows.Core.Language;

public sealed record LanguageCompletionItem(
    string Label, string? Detail = null, string? Documentation = null, string? InsertText = null);
public sealed record CompletionPrefix(int From, int To, string Text);

public static class CompletionEngine
{
    public const int MaximumServerItems = 200;
    public const int MaximumFallbackWords = 300;
    public const int MaximumVisibleItems = 100;
    public const int MaximumLabelCharacters = 256;
    public const int MaximumDetailCharacters = 1_024;
    public const int MaximumDocumentationCharacters = 16_384;
    public const int MaximumInsertCharacters = 64 * 1024;
    private static readonly Regex Words = new(
        @"[A-Za-z_$][A-Za-z0-9_$]{1,80}", RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    public static CompletionPrefix PrefixAt(string text, int offset)
    {
        ArgumentNullException.ThrowIfNull(text);
        offset = Math.Clamp(offset, 0, text.Length);
        var start = offset;
        while (start > 0 && IsWord(text[start - 1])) start--;
        if (start == offset || !IsStart(text[start])) return new(offset, offset, String.Empty);
        return new(start, offset, text[start..offset]);
    }

    public static IReadOnlyList<LanguageCompletionItem> ParseLsp(JsonElement result)
    {
        var values = result.ValueKind == JsonValueKind.Array ? result
            : result.ValueKind == JsonValueKind.Object && result.TryGetProperty("items", out var items)
                && items.ValueKind == JsonValueKind.Array ? items : default;
        if (values.ValueKind != JsonValueKind.Array) return [];
        var completions = new List<LanguageCompletionItem>();
        var labels = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values.EnumerateArray())
        {
            if (completions.Count >= MaximumServerItems) break;
            if (value.ValueKind != JsonValueKind.Object
                || !value.TryGetProperty("label", out var labelValue)
                || labelValue.ValueKind != JsonValueKind.String) continue;
            var label = Bound(labelValue.GetString(), MaximumLabelCharacters);
            if (String.IsNullOrWhiteSpace(label) || HasUnsafeControl(label) || !labels.Add(label)) continue;
            var detail = Text(value, "detail", MaximumDetailCharacters);
            var documentation = value.TryGetProperty("documentation", out var docs)
                ? MarkedText(docs, MaximumDocumentationCharacters) : null;
            var insertText = Text(value, "insertText", MaximumInsertCharacters);
            if (insertText is not null && HasUnsafeControl(insertText, allowLines: true)) insertText = null;
            completions.Add(new(label, detail, documentation, insertText));
        }
        return completions;
    }

    public static IReadOnlyList<LanguageCompletionItem> WordFallback(
        string prefix, IEnumerable<string> documents)
    {
        if (prefix.Length < 2 || prefix.Length > 81 || !IsStart(prefix[0])
            || prefix.Skip(1).Any(character => !IsWord(character))) return [];
        var words = new HashSet<string>(StringComparer.Ordinal);
        foreach (var document in documents)
        {
            if (document is null) continue;
            var source = document.Length <= 2_000_000 ? document : document[..2_000_000];
            MatchCollection matches;
            try { matches = Words.Matches(source); }
            catch (RegexMatchTimeoutException) { continue; }
            foreach (Match match in matches)
            {
                var word = match.Value;
                if (!word.Equals(prefix, StringComparison.Ordinal)
                    && word.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) words.Add(word);
                if (words.Count >= MaximumFallbackWords) break;
            }
            if (words.Count >= MaximumFallbackWords) break;
        }
        return words.Order(StringComparer.OrdinalIgnoreCase).Take(MaximumVisibleItems)
            .Select(word => new LanguageCompletionItem(word, "workspace word", InsertText: word)).ToArray();
    }

    private static string? Text(JsonElement value, string name, int maximum) =>
        value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String
            ? SafeBound(property.GetString(), maximum) : null;

    private static string? MarkedText(JsonElement value, int maximum)
    {
        if (value.ValueKind == JsonValueKind.String) return SafeBound(value.GetString(), maximum);
        if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty("value", out var text)
            && text.ValueKind == JsonValueKind.String) return SafeBound(text.GetString(), maximum);
        return null;
    }

    private static string? SafeBound(string? value, int maximum)
    {
        if (value is null || HasUnsafeControl(value, allowLines: true)) return null;
        return Bound(value, maximum);
    }

    private static string Bound(string? value, int maximum)
    {
        value ??= String.Empty;
        if (value.Length <= maximum) return value;
        var end = maximum;
        if (end > 0 && Char.IsHighSurrogate(value[end - 1]) && Char.IsLowSurrogate(value[end])) end--;
        return value[..end];
    }

    private static bool HasUnsafeControl(string value, bool allowLines = false) => value.Any(character =>
        Char.IsControl(character) && !(allowLines && character is '\r' or '\n' or '\t'));
    private static bool IsStart(char character) => Char.IsAsciiLetter(character) || character is '_' or '$';
    private static bool IsWord(char character) => Char.IsAsciiLetterOrDigit(character) || character is '_' or '$';
}
