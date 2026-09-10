using System.Globalization;
using System.Text;
using System.Text.Json;

namespace LumenEditor.Windows.Core.Editing;

public sealed record DocumentStatistics(int Lines, int Utf16Characters, int NonWhitespaceCharacters, int Words);

public static class DocumentTransforms
{
    public static string? FormatJson(string text, bool compact)
    {
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
                MaxDepth = 256
            });
            return JsonSerializer.Serialize(document.RootElement, new JsonSerializerOptions { WriteIndented = !compact })
                + (compact ? String.Empty : "\n");
        }
        catch (JsonException) { return null; }
    }

    public static DocumentStatistics Statistics(string text)
    {
        var lines = text.Length == 0 ? 0 : text.Count(character => character == '\n') + 1;
        var nonWhitespace = text.EnumerateRunes().Count(rune => !Rune.IsWhiteSpace(rune));
        var words = 0;
        var inWord = false;
        foreach (var rune in text.EnumerateRunes())
        {
            var next = RuneIsWord(rune);
            if (next && !inWord) words++;
            inWord = next;
        }
        return new(lines, text.Length, nonWhitespace, words);
    }

    private static bool RuneIsWord(System.Text.Rune rune)
    {
        var category = Rune.GetUnicodeCategory(rune);
        return category is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
            or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
            or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber
            or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
            or UnicodeCategory.ConnectorPunctuation;
    }
}
