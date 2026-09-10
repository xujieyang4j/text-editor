using System.Text.Json;
using System.Text.Json.Serialization;

namespace LumenEditor.Windows.Core.Plugins;

public static class PluginWorkerProtocol
{
    public const int Version = 1;
    public const int MaximumDocumentBytes = 8 * 1024 * 1024;
    public const int MaximumReplacementBytes = 8 * 1024 * 1024;
    public const int MaximumMessageBytes = 16 * 1024 * 1024;
    public const int MaximumMessagesPerRequest = 256;
    public const int MaximumCommandsPerWorker = 50;
    public const int MaximumControlResponseBytes = 4 * 1024;
    public const int MaximumResponseBytes = MaximumMessageBytes
        + MaximumMessagesPerRequest * MaximumControlResponseBytes;
    public const int MaximumFailureCharacters = 2_000;
}

public enum PluginWorkerRequestKind { Load, Activate, RunCommand, Deactivate }
public enum PluginWorkerResponseKind { RegisterCommand, ReplaceDocument, Notify, Completed, Failed }
public sealed record PluginWorkerSelection(int From, int To);
public sealed record PluginWorkerDocument(string Text, string Language, PluginWorkerSelection Selection);
public sealed record PluginWorkerContext(IReadOnlyList<PluginPermission> Permissions, PluginWorkerDocument? Document = null);
public sealed record PluginWorkerRequest(
    int Version, PluginWorkerRequestKind Type, string RequestId, string? Source = null,
    string? SourceIntegrity = null, string? CommandId = null, PluginWorkerContext? Context = null);
public sealed record PluginWorkerResponse(
    int Version, PluginWorkerResponseKind Type, string RequestId, string? Id = null,
    string? Title = null, string? Text = null);

public static class PluginWorkerCodec
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true,
        Converters =
        {
            new JsonStringEnumConverter<PluginWorkerRequestKind>(JsonNamingPolicy.KebabCaseLower),
            new JsonStringEnumConverter<PluginWorkerResponseKind>(JsonNamingPolicy.KebabCaseLower),
            new PluginPermissionJsonConverter()
        }
    };

    public static string Encode(PluginWorkerRequest request)
    {
        Validate(request);
        return EncodeBounded(request);
    }
    public static string Encode(PluginWorkerResponse response)
    {
        Validate(response);
        return EncodeBounded(response);
    }
    public static PluginWorkerRequest DecodeRequest(string line)
    {
        var request = Decode<PluginWorkerRequest>(line);
        Validate(request);
        return request;
    }
    public static PluginWorkerResponse DecodeResponse(string line)
    {
        var response = Decode<PluginWorkerResponse>(line);
        Validate(response);
        return response;
    }
    public static string EncodePayload<T>(T value) => EncodeBounded(value);
    public static IReadOnlyList<PluginPermission> DecodePermissions(string json) => Decode<List<PluginPermission>>(json);

    private static T Decode<T>(string line)
    {
        if (String.IsNullOrWhiteSpace(line) || System.Text.Encoding.UTF8.GetByteCount(line) > PluginWorkerProtocol.MaximumMessageBytes)
            throw new InvalidDataException("Plugin worker message has an invalid size.");
        try { return JsonSerializer.Deserialize<T>(line, Options) ?? throw new InvalidDataException("Plugin worker message is empty."); }
        catch (JsonException error) { throw new InvalidDataException("Plugin worker message is invalid JSON.", error); }
    }
    private static string EncodeBounded<T>(T value)
    {
        var json = JsonSerializer.Serialize(value, Options);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > PluginWorkerProtocol.MaximumMessageBytes)
            throw new InvalidDataException("Plugin worker message exceeds the size limit.");
        return json;
    }
    private static void Validate(PluginWorkerRequest value)
    {
        if (value.Version != PluginWorkerProtocol.Version || String.IsNullOrEmpty(value.RequestId)
            || value.RequestId.Length > 100)
            throw new InvalidDataException("Plugin worker request is invalid.");
        if (value.Type == PluginWorkerRequestKind.Load && (value.Source is null || value.SourceIntegrity is null
            || System.Text.Encoding.UTF8.GetByteCount(value.Source) > DeclarativePluginParser.MaximumWorkerBytes
            || !PluginIntegrity.Matches(value.SourceIntegrity, System.Text.Encoding.UTF8.GetBytes(value.Source))))
            throw new InvalidDataException("Plugin worker load request is invalid.");
        if (value.Type == PluginWorkerRequestKind.RunCommand && String.IsNullOrWhiteSpace(value.CommandId))
            throw new InvalidDataException("Plugin worker command request is invalid.");
        if (value.Context?.Document is { } document
            && System.Text.Encoding.UTF8.GetByteCount(document.Text) > PluginWorkerProtocol.MaximumDocumentBytes)
            throw new InvalidDataException("Plugin worker document exceeds the size limit.");
        if (value.Context is { } context)
        {
            if (context.Permissions is null || context.Permissions.Any(permission => !Enum.IsDefined(permission))
                || context.Permissions.Distinct().Count() != context.Permissions.Count)
                throw new InvalidDataException("Plugin worker permissions contain duplicates.");
            if (!context.Permissions.Contains(PluginPermission.DocumentRead) && context.Document is not null)
                throw new InvalidDataException("Plugin worker document context requires document-read permission.");
            if (context.Document is { } contextDocument && (contextDocument.Text is null || contextDocument.Language is null
                || contextDocument.Language.Length > 100
                || contextDocument.Selection is null || contextDocument.Selection.From < 0
                || contextDocument.Selection.To < contextDocument.Selection.From || contextDocument.Selection.To > contextDocument.Text.Length))
                throw new InvalidDataException("Plugin worker document selection is invalid.");
        }
    }
    private static void Validate(PluginWorkerResponse value)
    {
        if (value.Version != PluginWorkerProtocol.Version || String.IsNullOrEmpty(value.RequestId)
            || value.RequestId.Length > 100)
            throw new InvalidDataException("Plugin worker response is invalid.");
        if (value.Type == PluginWorkerResponseKind.RegisterCommand
            && (String.IsNullOrWhiteSpace(value.Id) || value.Id.Length > 100
                || !value.Id.All(character => Char.IsAsciiLetterOrDigit(character) || character is '-' or '.' or '_')
                || String.IsNullOrWhiteSpace(value.Title) || value.Title.Length > 200 || value.Text is not null))
            throw new InvalidDataException("Plugin worker command registration is invalid.");
        if (value.Type == PluginWorkerResponseKind.ReplaceDocument
            && (value.Text is null || value.Id is not null || value.Title is not null
                || System.Text.Encoding.UTF8.GetByteCount(value.Text) > PluginWorkerProtocol.MaximumReplacementBytes))
            throw new InvalidDataException("Plugin worker replacement is invalid.");
        if (value.Type == PluginWorkerResponseKind.Notify && (value.Text is null || value.Text.Length > 500
            || value.Id is not null || value.Title is not null))
            throw new InvalidDataException("Plugin worker notification is invalid.");
        if (value.Type == PluginWorkerResponseKind.Failed && (String.IsNullOrEmpty(value.Text)
            || value.Text.Length > PluginWorkerProtocol.MaximumFailureCharacters))
            throw new InvalidDataException("Plugin worker failure is invalid.");
        if (value.Type == PluginWorkerResponseKind.Completed && (value.Id is not null || value.Title is not null || value.Text is not null))
            throw new InvalidDataException("Plugin worker completion is invalid.");
        if (value.Type == PluginWorkerResponseKind.Failed && (value.Id is not null || value.Title is not null))
            throw new InvalidDataException("Plugin worker failure is invalid.");
    }
}
