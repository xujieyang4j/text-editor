using System.Text.RegularExpressions;

namespace LumenEditor.Windows.Core.Documents;

public sealed record LanguageDefinition(
    string Id, string Name, string ParserName, IReadOnlyList<string> Aliases,
    IReadOnlyList<string> Extensions, string? FilenamePattern, bool FilenameIgnoreCase);

public static class LanguageDetector
{
    public static readonly IReadOnlyList<LanguageDefinition> Languages = GeneratedLanguageCatalog.All;

    public static LanguageDefinition Detect(string path)
    {
        var fileName = Path.GetFileName(path);
        var extension = Path.GetExtension(fileName);
        foreach (var language in Languages.Skip(1))
        {
            if (language.Extensions.Contains(extension, StringComparer.OrdinalIgnoreCase)) return language;
            if (language.FilenamePattern is { } pattern && Regex.IsMatch(fileName, pattern,
                RegexOptions.CultureInvariant | (language.FilenameIgnoreCase
                    ? RegexOptions.IgnoreCase : RegexOptions.None), TimeSpan.FromMilliseconds(50))) return language;
        }
        return Languages[0];
    }

    public static LanguageDefinition? FindByNameOrAlias(string value)
    {
        value = value.Trim();
        return Languages.FirstOrDefault(language => language.Name.Equals(value, StringComparison.OrdinalIgnoreCase)
            || language.Id.Equals(value, StringComparison.OrdinalIgnoreCase)
            || language.Aliases.Contains(value, StringComparer.OrdinalIgnoreCase));
    }
}
