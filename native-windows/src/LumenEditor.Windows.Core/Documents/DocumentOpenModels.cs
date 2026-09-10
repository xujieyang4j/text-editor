using LumenEditor.Windows.Core.Settings;
using System.Text;

namespace LumenEditor.Windows.Core.Documents;

public enum DocumentOpenRejection { None, Missing, NotARegularFile, TooLarge, Binary, ReadFailed }

public sealed record OpenedDocument(
    string Path, string DisplayName, string Content, long ByteLength,
    TextEncodingKind Encoding = TextEncodingKind.Utf8, LineEnding LineEnding = LineEnding.Lf,
    TextEncodingIssue EncodingIssue = TextEncodingIssue.None, bool IsDirty = false, string? Revision = null,
    bool IsPinned = false)
{
    public string TabTitle => (IsPinned ? "📌 " : String.Empty) + (IsDirty ? $"{DisplayName} ●" : DisplayName);
}

public sealed record DocumentOpenFailure(string Path, DocumentOpenRejection Reason, string Message);

public sealed record DocumentOpenBatchResult(
    IReadOnlyList<OpenedDocument> Documents, IReadOnlyList<DocumentOpenFailure> Failures);

/// <summary>Bounded, order-preserving policy used by FileOpenPicker and shell activation.</summary>
public static class DocumentOpenBatchPlanner
{
    public const int MaximumDocumentsPerRequest = 100;

    public static (IReadOnlyList<string> Accepted, IReadOnlyList<string> Rejected) Plan(
        IEnumerable<string> paths, int maximum = MaximumDocumentsPerRequest)
    {
        var limit = Math.Max(0, maximum);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var accepted = new List<string>();
        var rejected = new List<string>();
        foreach (var path in paths)
        {
            if (!seen.Add(path)) continue;
            if (accepted.Count < limit) accepted.Add(path);
            else rejected.Add(path);
        }
        return (accepted, rejected);
    }
}

public sealed class DocumentOpenService
{
    public async Task<DocumentOpenBatchResult> OpenAsync(
        IEnumerable<string> requestedPaths, EditorSettings settings,
        CancellationToken cancellationToken = default)
    {
        var plan = DocumentOpenBatchPlanner.Plan(requestedPaths);
        var documents = new List<OpenedDocument>();
        var failures = new List<DocumentOpenFailure>();
        foreach (var rejected in plan.Rejected)
        {
            failures.Add(new(rejected, DocumentOpenRejection.TooLarge,
                $"Opening is limited to {DocumentOpenBatchPlanner.MaximumDocumentsPerRequest} files at a time."));
        }
        foreach (var path in plan.Accepted)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await OpenOneAsync(path, settings.MaximumEditableBytes, cancellationToken);
            if (result.Document is not null) documents.Add(result.Document);
            else if (result.Failure is not null) failures.Add(result.Failure);
        }
        return new(documents, failures);
    }

    public async Task<DocumentOpenBatchResult> OpenWithEncodingAsync(
        IEnumerable<string> requestedPaths,
        EditorSettings settings,
        TextEncodingKind encoding,
        CancellationToken cancellationToken = default)
    {
        var plan = DocumentOpenBatchPlanner.Plan(requestedPaths);
        var documents = new List<OpenedDocument>();
        var failures = new List<DocumentOpenFailure>();
        foreach (var rejected in plan.Rejected)
        {
            failures.Add(new(rejected, DocumentOpenRejection.TooLarge,
                $"Opening is limited to {DocumentOpenBatchPlanner.MaximumDocumentsPerRequest} files at a time."));
        }
        foreach (var path in plan.Accepted)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await OpenOneWithEncodingAsync(path, settings.MaximumEditableBytes, encoding, cancellationToken);
            if (result.Document is not null) documents.Add(result.Document);
            else if (result.Failure is not null) failures.Add(result.Failure);
        }
        return new(documents, failures);
    }

    private static async Task<(OpenedDocument? Document, DocumentOpenFailure? Failure)> OpenOneAsync(
        string candidate, long maximumBytes, CancellationToken cancellationToken)
    {
        var path = Path.GetFullPath(candidate);
        try
        {
            var info = new FileInfo(path);
            if (Directory.Exists(path))
            {
                return (null, new(path, DocumentOpenRejection.NotARegularFile, "The selected path is a directory."));
            }
            if (!info.Exists) return (null, new(path, DocumentOpenRejection.Missing, "The selected file no longer exists."));
            if (info.Length > maximumBytes)
            {
                return (null, new(path, DocumentOpenRejection.TooLarge,
                    $"{info.Name} is {info.Length / 1024d / 1024d:F1} MB and exceeds the current {maximumBytes / 1024 / 1024} MB editor limit."));
            }
            var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
            var detected = TextFileCodec.DetectEncoding(bytes);
            if (TextFileCodec.LooksBinary(bytes, detected is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom))
            {
                return (null, new(path, DocumentOpenRejection.Binary, "The selected file appears to be binary."));
            }
            var decoded = TextFileCodec.DecodeAuto(bytes);
            return (new(path, info.Name, decoded.Content, bytes.LongLength, decoded.Encoding, decoded.LineEnding, decoded.EncodingIssue, false, FileWriteService.ComputeRevision(bytes)), null);
        }
        catch (DecoderFallbackException)
        {
            return (null, new(path, DocumentOpenRejection.ReadFailed, "The file is not valid UTF-8 text."));
        }
        catch (UnauthorizedAccessException error) { return (null, new(path, DocumentOpenRejection.ReadFailed, error.Message)); }
        catch (IOException error) { return (null, new(path, DocumentOpenRejection.ReadFailed, error.Message)); }
    }

    private static async Task<(OpenedDocument? Document, DocumentOpenFailure? Failure)> OpenOneWithEncodingAsync(
        string candidate, long maximumBytes, TextEncodingKind encoding, CancellationToken cancellationToken)
    {
        var path = Path.GetFullPath(candidate);
        try
        {
            var info = new FileInfo(path);
            if (Directory.Exists(path)) return (null, new(path, DocumentOpenRejection.NotARegularFile, "The selected path is a directory."));
            if (!info.Exists) return (null, new(path, DocumentOpenRejection.Missing, "The selected file no longer exists."));
            if (info.Length > maximumBytes)
            {
                return (null, new(path, DocumentOpenRejection.TooLarge,
                    $"{info.Name} is {info.Length / 1024d / 1024d:F1} MB and exceeds the current {maximumBytes / 1024 / 1024} MB editor limit."));
            }
            var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
            var utf16 = encoding is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be
                or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom;
            if (TextFileCodec.LooksBinary(bytes, utf16))
            {
                return (null, new(path, DocumentOpenRejection.Binary, "The selected file appears to be binary."));
            }
            var decoded = TextFileCodec.Decode(bytes, encoding);
            return (new(path, info.Name, decoded.Content, bytes.LongLength, decoded.Encoding,
                decoded.LineEnding, decoded.EncodingIssue, false, FileWriteService.ComputeRevision(bytes)), null);
        }
        catch (DecoderFallbackException error) { return (null, new(path, DocumentOpenRejection.ReadFailed, error.Message)); }
        catch (UnauthorizedAccessException error) { return (null, new(path, DocumentOpenRejection.ReadFailed, error.Message)); }
        catch (IOException error) { return (null, new(path, DocumentOpenRejection.ReadFailed, error.Message)); }
    }
}
