using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Find;

namespace LumenEditor.Windows.Core.Workspace;

public sealed record WorkspaceReplacementFile(
    string Path,
    string Before,
    string After,
    TextEncodingKind Encoding,
    LineEnding LineEnding,
    string Revision,
    int ReplacementCount);

public sealed record WorkspaceReplacePreview(
    IReadOnlyList<WorkspaceReplacementFile> Files,
    IReadOnlyList<WorkspaceSearchMatch> Matches,
    bool IsTruncated,
    string? Error = null,
    IReadOnlyList<string>? ProjectExclusions = null)
{
    public int ReplacementCount => Files.Sum(file => file.ReplacementCount);
}

public sealed record WorkspaceUndoFile(
    string Path, string Content, TextEncodingKind Encoding, LineEnding LineEnding, string ExpectedRevision);

public sealed record WorkspaceReplaceUndo(IReadOnlyList<WorkspaceUndoFile> Files);

public sealed record WorkspaceReplaceResult(
    bool Succeeded, int Files, int Replacements, WorkspaceReplaceUndo? Undo = null, string? Error = null);

/// <summary>Revision-pinned workspace replace with bounded preview, rollback, and one-level undo.</summary>
public sealed class WorkspaceReplaceService
{
    public const int MaximumReplacementFiles = 1_000;
    public const long MaximumPreviewBytes = 100L * 1024 * 1024;
    private readonly WorkspaceSearchRunner searchRunner = new();
    private readonly FileWriteService writer = new();

    public async Task<WorkspaceReplacePreview> PreviewAsync(
        IEnumerable<string> roots,
        string searchText,
        string replacement,
        bool caseSensitive,
        bool wholeWord,
        bool useRegex,
        WorkspaceTree tree,
        CancellationToken cancellationToken = default,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        var exclusionSnapshot = exclusions ?? WorkspaceExclusionPolicy.Empty;
        var normalizedRoots = WorkspaceRoots.Normalize(roots);
        if (normalizedRoots.Count == 0) return new([], [], false, "No workspace folder is open.");
        var prototype = new WorkspaceSearchQuery(
            normalizedRoots[0], searchText, caseSensitive, wholeWord, useRegex);
        var pattern = WorkspaceSearchPattern.Compile(prototype);
        if (pattern is null) return new([], [], false, "The search expression is empty or invalid.");

        var located = new List<WorkspaceSearchMatch>();
        var truncated = false;
        foreach (var root in normalizedRoots)
        {
            var remaining = 5_000 - located.Count;
            if (remaining <= 0)
            {
                truncated = true;
                break;
            }
            var result = await searchRunner.SearchWorkspaceAsync(
                prototype with { Root = root, MaximumResults = remaining }, tree, cancellationToken, exclusionSnapshot);
            located.AddRange(result.Matches);
            truncated |= result.IsTruncated;
        }
        if (truncated) return new([], located, true, "The preview was truncated; narrow the search before replacing.");

        var files = new List<WorkspaceReplacementFile>();
        long totalBytes = 0;
        foreach (var group in located.GroupBy(match => match.Path, StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (files.Count >= MaximumReplacementFiles)
            {
                return new([], located, true, "The replacement exceeds the file limit.");
            }
            byte[] bytes;
            try { bytes = await File.ReadAllBytesAsync(group.Key, cancellationToken); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return new([], located, false, $"Could not read {group.Key}: {error.Message}");
            }
            totalBytes += bytes.LongLength;
            if (totalBytes > MaximumPreviewBytes)
            {
                return new([], located, true, "The replacement preview exceeds the memory safety limit.");
            }
            var decoded = TextFileCodec.DecodeAuto(bytes);
            if (decoded.EncodingIssue == TextEncodingIssue.InvalidBytes)
            {
                return new([], located, false, $"{group.Key} contains invalid text bytes and cannot be replaced safely.");
            }
            List<Match> matches;
            try { matches = pattern.Matches(decoded.Content).Cast<Match>().Take(FindEngine.MaximumMatches + 1).ToList(); }
            catch (RegexMatchTimeoutException)
            {
                return new([], located, false, $"The expression timed out in {group.Key}.");
            }
            if (matches.Count == 0) continue;
            if (matches.Count > FindEngine.MaximumMatches || matches.Any(match => match.Length == 0))
            {
                return new([], located, false, "Zero-width or excessive replacements are not supported.");
            }
            string after;
            try { after = ReplaceMatches(decoded.Content, matches, replacement, useRegex); }
            catch (ArgumentException error)
            {
                return new([], located, false, $"Invalid replacement: {error.Message}");
            }
            if (StringComparer.Ordinal.Equals(after, decoded.Content)) continue;
            files.Add(new WorkspaceReplacementFile(
                group.Key, decoded.Content, after, decoded.Encoding, decoded.LineEnding,
                FileWriteService.ComputeRevision(bytes), matches.Count));
        }
        return new(files, located, false, ProjectExclusions: exclusionSnapshot.Patterns);
    }

    public async Task<WorkspaceReplaceResult> ApplyAsync(
        WorkspaceReplacePreview preview, CancellationToken cancellationToken = default,
        WorkspaceExclusionPolicy? currentExclusions = null)
    {
        if (preview.Error is not null || preview.IsTruncated)
        {
            return new(false, 0, 0, Error: preview.Error ?? "A truncated preview cannot be applied.");
        }
        var previewExclusions = preview.ProjectExclusions ?? [];
        var current = (currentExclusions ?? WorkspaceExclusionPolicy.Empty).Patterns;
        if (!previewExclusions.SequenceEqual(current, StringComparer.OrdinalIgnoreCase))
        {
            return new(false, 0, 0, Error: "Project exclusions changed. Create a new replacement preview.");
        }
        var preflight = await VerifyRevisionsAsync(
            preview.Files.Select(file => (file.Path, file.Revision)), cancellationToken);
        if (preflight is not null) return new(false, 0, 0, Error: preflight);

        var written = new List<(WorkspaceReplacementFile File, string Revision)>();
        foreach (var file in preview.Files)
        {
            var result = await writer.SaveAsync(
                file.Path, file.After, file.Encoding, file.LineEnding, file.Revision, cancellationToken);
            if (!result.Saved || result.Revision is null)
            {
                await RollBackAsync(written, cancellationToken);
                return new(false, 0, 0, Error: result.Message ?? $"Could not replace {file.Path}.");
            }
            written.Add((file, result.Revision));
        }
        var undo = new WorkspaceReplaceUndo(written.Select(item => new WorkspaceUndoFile(
            item.File.Path, item.File.Before, item.File.Encoding, item.File.LineEnding, item.Revision)).ToList());
        return new(true, written.Count, preview.ReplacementCount, undo);
    }

    public async Task<WorkspaceReplaceResult> UndoAsync(
        WorkspaceReplaceUndo undo, CancellationToken cancellationToken = default)
    {
        var preflight = await VerifyRevisionsAsync(
            undo.Files.Select(file => (file.Path, file.ExpectedRevision)), cancellationToken);
        if (preflight is not null) return new(false, 0, 0, Error: preflight);
        var restored = 0;
        foreach (var file in undo.Files)
        {
            var result = await writer.SaveAsync(
                file.Path, file.Content, file.Encoding, file.LineEnding, file.ExpectedRevision, cancellationToken);
            if (!result.Saved) return new(false, restored, 0, Error: result.Message ?? $"Could not restore {file.Path}.");
            restored++;
        }
        return new(true, restored, 0);
    }

    private static async Task<string?> VerifyRevisionsAsync(
        IEnumerable<(string Path, string Revision)> files, CancellationToken cancellationToken)
    {
        foreach (var file in files)
        {
            var current = await FileWriteService.RevisionAsync(file.Path, cancellationToken);
            if (!StringComparer.Ordinal.Equals(current, file.Revision))
            {
                return $"{file.Path} changed after the replacement preview. Run the preview again.";
            }
        }
        return null;
    }

    private async Task RollBackAsync(
        IEnumerable<(WorkspaceReplacementFile File, string Revision)> written,
        CancellationToken cancellationToken)
    {
        foreach (var item in written.Reverse())
        {
            await writer.SaveAsync(
                item.File.Path, item.File.Before, item.File.Encoding, item.File.LineEnding,
                item.Revision, cancellationToken);
        }
    }

    private static string Unquote(string value) => value
        .Replace("\\n", "\n", StringComparison.Ordinal)
        .Replace("\\r", "\r", StringComparison.Ordinal)
        .Replace("\\t", "\t", StringComparison.Ordinal)
        .Replace("\\\\", "\\", StringComparison.Ordinal);

    private static string ReplaceMatches(string text, IReadOnlyList<Match> matches, string replacement, bool useRegex)
    {
        var value = Unquote(replacement);
        var builder = new System.Text.StringBuilder(text.Length);
        var cursor = 0;
        foreach (var match in matches)
        {
            builder.Append(text, cursor, match.Index - cursor);
            builder.Append(useRegex ? match.Result(value) : value);
            cursor = match.Index + match.Length;
        }
        builder.Append(text, cursor, text.Length - cursor);
        return builder.ToString();
    }
}
