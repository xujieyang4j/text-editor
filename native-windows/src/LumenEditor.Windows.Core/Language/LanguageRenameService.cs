using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Navigation;

namespace LumenEditor.Windows.Core.Language;

public sealed record LanguageRenameFile(
    string Path, string Before, string After, TextEncodingKind Encoding,
    LineEnding LineEnding, string Revision, int EditCount);

public sealed record LanguageRenamePreview(
    IReadOnlyList<LanguageRenameFile> Files, int EditCount, string? Error = null);

public sealed record LanguageRenameUndo(IReadOnlyList<Workspace.WorkspaceUndoFile> Files);

public sealed record LanguageRenameApplyResult(
    bool Succeeded, int Files, int Edits, LanguageRenameUndo? Undo = null, string? Error = null);

/// <summary>Revision-pinned application of server-provided UTF-16 workspace edits.</summary>
public sealed class LanguageRenameService
{
    public const int MaximumFiles = 1_000;
    public const long MaximumSourceBytes = 100L * 1024 * 1024;
    private readonly FileWriteService writer = new();

    public async Task<LanguageRenamePreview> PreviewAsync(
        IReadOnlyList<LanguageRenameEdit> edits, CancellationToken cancellationToken = default)
    {
        if (edits.Count == 0) return new([], 0);
        if (edits.Count > LanguageServerResults.MaximumRenameEdits)
        {
            return new([], 0, "Language-server rename exceeds the edit limit.");
        }
        var files = new List<LanguageRenameFile>();
        long totalBytes = 0;
        foreach (var group in edits.GroupBy(edit => edit.Path, StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (files.Count >= MaximumFiles) return new([], 0, "Language-server rename exceeds the file limit.");
            byte[] bytes;
            try { bytes = await File.ReadAllBytesAsync(group.Key, cancellationToken); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return new([], 0, $"Could not read {group.Key}: {error.Message}");
            }
            totalBytes += bytes.LongLength;
            if (totalBytes > MaximumSourceBytes) return new([], 0, "Language-server rename exceeds the memory safety limit.");
            var decoded = TextFileCodec.DecodeAuto(bytes);
            if (decoded.EncodingIssue == TextEncodingIssue.InvalidBytes)
            {
                return new([], 0, $"{group.Key} contains invalid text bytes.");
            }
            var planned = new List<(int Start, int End, string Text)>();
            foreach (var edit in group)
            {
                var start = TextNavigation.LineColumnToOffset(decoded.Content, edit.StartLine + 1, edit.StartCharacter + 1);
                var end = TextNavigation.LineColumnToOffset(decoded.Content, edit.EndLine + 1, edit.EndCharacter + 1);
                if (end < start || edit.NewText.Length > LanguageServerResults.MaximumTextCharacters)
                {
                    return new([], 0, $"Language server returned an invalid edit for {group.Key}.");
                }
                planned.Add((start, end, edit.NewText));
            }
            var ordered = planned.OrderByDescending(edit => edit.Start).ThenByDescending(edit => edit.End).ToList();
            for (var index = 1; index < ordered.Count; index++)
            {
                if (ordered[index].End > ordered[index - 1].Start)
                {
                    return new([], 0, $"Language server returned overlapping edits for {group.Key}.");
                }
            }
            var after = decoded.Content;
            foreach (var edit in ordered) after = after[..edit.Start] + edit.Text + after[edit.End..];
            files.Add(new(
                group.Key, decoded.Content, after, decoded.Encoding, decoded.LineEnding,
                FileWriteService.ComputeRevision(bytes), planned.Count));
        }
        return new(files, files.Sum(file => file.EditCount));
    }

    public async Task<LanguageRenameApplyResult> ApplyAsync(
        LanguageRenamePreview preview, CancellationToken cancellationToken = default)
    {
        if (preview.Error is not null) return new(false, 0, 0, Error: preview.Error);
        foreach (var file in preview.Files)
        {
            if (!StringComparer.Ordinal.Equals(
                await FileWriteService.RevisionAsync(file.Path, cancellationToken), file.Revision))
            {
                return new(false, 0, 0, Error: $"{file.Path} changed after the rename preview.");
            }
        }
        var written = new List<(LanguageRenameFile File, string Revision)>();
        foreach (var file in preview.Files)
        {
            var result = await writer.SaveAsync(
                file.Path, file.After, file.Encoding, file.LineEnding, file.Revision, cancellationToken);
            if (!result.Saved || result.Revision is null)
            {
                foreach (var item in written.AsEnumerable().Reverse())
                {
                    await writer.SaveAsync(item.File.Path, item.File.Before, item.File.Encoding,
                        item.File.LineEnding, item.Revision, cancellationToken);
                }
                return new(false, 0, 0, Error: result.Message ?? $"Could not rename in {file.Path}.");
            }
            written.Add((file, result.Revision));
        }
        var undo = new LanguageRenameUndo(written.Select(item => new Workspace.WorkspaceUndoFile(
            item.File.Path, item.File.Before, item.File.Encoding, item.File.LineEnding, item.Revision)).ToList());
        return new(true, written.Count, preview.EditCount, undo);
    }

    public async Task<LanguageRenameApplyResult> UndoAsync(
        LanguageRenameUndo undo, CancellationToken cancellationToken = default)
    {
        foreach (var file in undo.Files)
        {
            if (!StringComparer.Ordinal.Equals(
                await FileWriteService.RevisionAsync(file.Path, cancellationToken), file.ExpectedRevision))
            {
                return new(false, 0, 0, Error: $"{file.Path} changed after the rename.");
            }
        }
        var restored = 0;
        foreach (var file in undo.Files)
        {
            var result = await writer.SaveAsync(
                file.Path, file.Content, file.Encoding, file.LineEnding, file.ExpectedRevision, cancellationToken);
            if (!result.Saved) return new(false, restored, 0, Error: result.Message);
            restored++;
        }
        return new(true, restored, 0);
    }
}
