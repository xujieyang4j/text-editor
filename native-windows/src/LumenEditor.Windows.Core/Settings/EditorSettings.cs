using System.Text.Json.Serialization;

namespace LumenEditor.Windows.Core.Settings;

public enum AutoSaveMode
{
    Off,
    AfterDelay,
    OnFocusChange
}

public enum EditorTheme
{
    Dark,
    Light
}

public enum EditorColorScheme
{
    Dark,
    Light,
    SolarizedDark,
    Dracula
}

/// <summary>Cross-platform persisted settings subset used by the Windows native preview.</summary>
public sealed record EditorSettings(
    int FormatVersion = 2,
    string Locale = "zh-CN",
    int FontSize = 14,
    int TabSize = 4,
    bool InsertSpaces = true,
    [property: JsonPropertyName("maxFileSizeMB")]
    int MaxFileSizeMb = 200,
    bool WordWrap = false,
    string LanguageServerLanguageId = "",
    string LanguageServerCommand = "",
    string LanguageServerArguments = "",
    AutoSaveMode AutoSave = AutoSaveMode.Off,
    int AutoSaveDelayMs = 1000,
    EditorTheme Theme = EditorTheme.Dark,
    EditorColorScheme ColorScheme = EditorColorScheme.Dark,
    bool DistractionFree = false,
    bool SpellCheck = false,
    bool ShowOutline = false,
    bool ShowLineNumbers = true,
    bool ShowWhitespace = false,
    bool ShowMinimap = true,
    bool ShowIndentGuides = true,
    bool HighlightTrailingWhitespace = true,
    IReadOnlyList<int>? Rulers = null,
    string BuildCommand = "",
    IReadOnlyList<string>? SearchHistory = null,
    IReadOnlyList<string>? ReplaceHistory = null)
{
    public const int CurrentFormatVersion = 2;
    public const int DefaultMaximumFileSizeMb = 200;
    public const int MinimumMaximumFileSizeMb = 1;
    public const int MaximumMaximumFileSizeMb = 200;

    public static EditorSettings Sanitize(EditorSettings? source)
    {
        source ??= new EditorSettings();
        var legacyFormat = source.FormatVersion is <= 0 or 1;
        var maximum = Math.Clamp(source.MaxFileSizeMb, MinimumMaximumFileSizeMb, MaximumMaximumFileSizeMb);
        if (legacyFormat && maximum == 20) maximum = DefaultMaximumFileSizeMb;
        return source with
        {
            FormatVersion = source.FormatVersion > CurrentFormatVersion ? source.FormatVersion : CurrentFormatVersion,
            Locale = source.Locale == "en-US" ? "en-US" : "zh-CN",
            FontSize = Math.Clamp(source.FontSize, 8, 40),
            TabSize = Math.Clamp(source.TabSize, 1, 16),
            MaxFileSizeMb = maximum,
            AutoSave = Enum.IsDefined(source.AutoSave) ? source.AutoSave : AutoSaveMode.Off,
            AutoSaveDelayMs = Math.Clamp(source.AutoSaveDelayMs, 250, 60_000),
            Theme = Enum.IsDefined(source.Theme) ? source.Theme : EditorTheme.Dark,
            ColorScheme = Enum.IsDefined(source.ColorScheme) ? source.ColorScheme : EditorColorScheme.Dark,
            Rulers = (source.Rulers ?? []).Where(value => value is >= 1 and <= 500)
                .Take(10).ToArray(),
            SearchHistory = SanitizeHistory(source.SearchHistory),
            ReplaceHistory = SanitizeHistory(source.ReplaceHistory),
            BuildCommand = Truncate(source.BuildCommand, 1_000),
            LanguageServerLanguageId = Bound(source.LanguageServerLanguageId, 128),
            LanguageServerCommand = Bound(source.LanguageServerCommand, 32 * 1024),
            LanguageServerArguments = Bound(source.LanguageServerArguments, 256 * 32 * 1024)
        };
    }

    public long MaximumEditableBytes => (long)MaxFileSizeMb * 1024 * 1024;

    private static string Bound(string? value, int maximum)
    {
        value = value?.Trim() ?? String.Empty;
        if (value.Length <= maximum) return value;
        var end = maximum;
        if (end > 0 && Char.IsHighSurrogate(value[end - 1]) && Char.IsLowSurrogate(value[end])) end--;
        return value[..end];
    }

    public static IReadOnlyList<string> RememberHistory(
        IReadOnlyList<string>? history, string value)
    {
        var bounded = Truncate(value, 2_000);
        return new[] { bounded }.Concat(history ?? [])
            .Distinct(StringComparer.Ordinal).Take(50).ToArray();
    }

    private static IReadOnlyList<string> SanitizeHistory(IReadOnlyList<string>? values) =>
        (values ?? []).Where(value => value is not null)
            .Select(value => Truncate(value, 2_000)).Take(50).ToArray();

    private static string Truncate(string? value, int maximum)
    {
        value ??= String.Empty;
        if (value.Length <= maximum) return value;
        var end = maximum;
        if (end > 0 && Char.IsHighSurrogate(value[end - 1]) && Char.IsLowSurrogate(value[end])) end--;
        return value[..end];
    }
}
