using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Documents;

namespace LumenEditor.Windows.Core.Workspace;

public sealed record WorkspaceSearchQuery(
    string Root,
    string Text,
    bool CaseSensitive = false,
    bool WholeWord = false,
    bool UseRegex = false,
    int MaximumResults = 5_000);

public sealed record WorkspaceSearchMatch(
    string Path, int Line, int Column, string LineText, string MatchText);

public sealed record WorkspaceSearchResult(
    IReadOnlyList<WorkspaceSearchMatch> Matches, bool IsTruncated);

public static class WorkspaceSearchPattern
{
    public static Regex? Compile(WorkspaceSearchQuery query)
    {
        if (String.IsNullOrWhiteSpace(query.Text)) return null;
        try
        {
            var source = query.UseRegex ? query.Text : Regex.Escape(query.Text);
            if (query.WholeWord) source = @"\b(?:" + source + @")\b";
            return new Regex(
                source,
                RegexOptions.CultureInvariant | (query.CaseSensitive ? RegexOptions.None : RegexOptions.IgnoreCase),
                TimeSpan.FromMilliseconds(100));
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    public static IReadOnlyList<WorkspaceSearchMatch> Locate(
        string path,
        string text,
        Regex pattern,
        int maximum)
    {
        var results = new List<WorkspaceSearchMatch>();
        var line = 1;
        var lineStart = 0;
        try
        {
            foreach (Match match in pattern.Matches(text))
            {
                if (match.Length == 0) continue;
                while (lineStart < match.Index)
                {
                    var next = text.IndexOf('\n', lineStart);
                    if (next < 0 || next >= match.Index) break;
                    line++;
                    lineStart = next + 1;
                }
                var lineEnd = text.IndexOf('\n', match.Index);
                if (lineEnd < 0) lineEnd = text.Length;
                results.Add(new(path, line, match.Index - lineStart + 1, text[lineStart..lineEnd], match.Value));
                if (results.Count >= Math.Max(0, maximum)) break;
            }
        }
        catch (RegexMatchTimeoutException)
        {
            return [];
        }
        return results;
    }
}

public sealed class WorkspaceSearchRunner
{
    public const int MaximumFileBytes = 2 * 1024 * 1024;
    public const int MaximumFiles = 20_000;

    public async Task<WorkspaceSearchResult> SearchWorkspaceAsync(
        WorkspaceSearchQuery query,
        WorkspaceTree tree,
        CancellationToken cancellationToken = default,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        if (WorkspaceSearchPattern.Compile(query) is null) return new([], false);
        var root = Path.GetFullPath(query.Root);
        if (!Directory.Exists(root)) return new([], false);
        var limit = Math.Clamp(query.MaximumResults, 1, 5_000);
        var matches = new List<WorkspaceSearchMatch>();
        var directories = new Stack<string>();
        directories.Push(root);
        var fileCount = 0;
        while (directories.Count > 0 && matches.Count < limit && fileCount < MaximumFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = directories.Pop();
            foreach (var entry in tree.ReadChildren(root, directory, exclusions))
            {
                if (entry.IsDirectory)
                {
                    directories.Push(entry.FullPath);
                    continue;
                }
                if (++fileCount > MaximumFiles) return new(matches, true);
                var perFile = await SearchFileAsync(query, entry.FullPath, cancellationToken, exclusions);
                matches.AddRange(perFile.Take(limit - matches.Count));
                if (matches.Count >= limit) return new(matches, true);
            }
        }
        return new(matches, directories.Count > 0 || fileCount >= MaximumFiles);
    }

    public async Task<IReadOnlyList<WorkspaceSearchMatch>> SearchFileAsync(
        WorkspaceSearchQuery query,
        string path,
        CancellationToken cancellationToken = default,
        WorkspaceExclusionPolicy? exclusions = null)
    {
        var root = Path.GetFullPath(query.Root);
        var file = Path.GetFullPath(path);
        var pattern = WorkspaceSearchPattern.Compile(query);
        if (pattern is null || !WorkspaceTree.IsInside(root, file) || !File.Exists(file)
            || (exclusions ?? WorkspaceExclusionPolicy.Empty).IsExcluded(root, file, isDirectory: false)) return [];
        var info = new FileInfo(file);
        if (info.Length > MaximumFileBytes) return [];
        byte[] bytes;
        try { bytes = await File.ReadAllBytesAsync(file, cancellationToken); }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
        var encoding = TextFileCodec.DetectEncoding(bytes);
        var utf16 = encoding is TextEncodingKind.Utf16Le or TextEncodingKind.Utf16Be or TextEncodingKind.Utf16LeNoBom or TextEncodingKind.Utf16BeNoBom;
        if (TextFileCodec.LooksBinary(bytes, utf16)) return [];
        var text = TextFileCodec.DecodeAuto(bytes).Content;
        return WorkspaceSearchPattern.Locate(file, text, pattern, Math.Clamp(query.MaximumResults, 1, WorkspaceSearchPatternMaximum));
    }

    private const int WorkspaceSearchPatternMaximum = 5_000;
}
