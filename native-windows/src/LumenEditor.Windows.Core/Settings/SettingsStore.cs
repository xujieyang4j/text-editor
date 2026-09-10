using System.Text.Json;
using System.Text.Json.Serialization;

namespace LumenEditor.Windows.Core.Settings;

/// <summary>Bounded, atomic per-user settings persistence for the Windows preview.</summary>
public sealed class SettingsStore
{
    public const int MaximumSerializedBytes = 1024 * 1024;
    public static readonly string DefaultDirectory = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LumenEditorNativeWindowsPreview");

    public SettingsStore(string? path = null)
    {
        Path = path ?? System.IO.Path.Combine(DefaultDirectory, "settings.json");
    }

    public string Path { get; }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters =
        {
            new JsonStringEnumConverter<AutoSaveMode>(JsonNamingPolicy.SnakeCaseLower),
            new JsonStringEnumConverter<EditorTheme>(JsonNamingPolicy.SnakeCaseLower),
            new JsonStringEnumConverter<EditorColorScheme>(JsonNamingPolicy.KebabCaseLower)
        }
    };

    public async Task<EditorSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var info = new FileInfo(Path);
            if (!info.Exists || info.Length > MaximumSerializedBytes) return EditorSettings.Sanitize(null);
            await using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, true);
            var settings = await JsonSerializer.DeserializeAsync<EditorSettings>(
                stream, JsonOptions, cancellationToken);
            return EditorSettings.Sanitize(settings);
        }
        catch (JsonException)
        {
            return EditorSettings.Sanitize(null);
        }
        catch (IOException)
        {
            return EditorSettings.Sanitize(null);
        }
        catch (UnauthorizedAccessException)
        {
            return EditorSettings.Sanitize(null);
        }
    }

    public async Task SaveAsync(EditorSettings settings, CancellationToken cancellationToken = default)
    {
        if (settings.FormatVersion > EditorSettings.CurrentFormatVersion)
        {
            throw new InvalidOperationException("Settings format version is newer than this Windows native preview supports.");
        }
        var sanitized = EditorSettings.Sanitize(settings);
        var data = JsonSerializer.SerializeToUtf8Bytes(sanitized, JsonOptions);
        if (data.Length > MaximumSerializedBytes) throw new InvalidOperationException("Settings snapshot exceeds the maximum size.");
        var directory = System.IO.Path.GetDirectoryName(Path) ?? throw new InvalidOperationException("Settings path has no directory.");
        Directory.CreateDirectory(directory);
        var temporary = System.IO.Path.Combine(directory, $".{System.IO.Path.GetFileName(Path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllBytesAsync(temporary, data, cancellationToken);
            if (File.Exists(Path)) File.Replace(temporary, Path, destinationBackupFileName: null, ignoreMetadataErrors: true);
            else File.Move(temporary, Path);
            temporary = string.Empty;
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporary)) File.Delete(temporary);
        }
    }
}
