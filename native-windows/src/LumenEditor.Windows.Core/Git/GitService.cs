using LumenEditor.Windows.Core.Processes;
using LumenEditor.Windows.Core.Workspace;

namespace LumenEditor.Windows.Core.Git;

public sealed record GitFileStatus(string Path, string IndexStatus, string WorkTreeStatus)
{
    public bool IsStaged => IndexStatus != " " && IndexStatus != "?";
    public bool HasConflict => IndexStatus == "U" || WorkTreeStatus == "U"
        || (IndexStatus, WorkTreeStatus) is ("A", "A") or ("D", "D");
    public string Display => $"{IndexStatus}{WorkTreeStatus} {Path}";
}

public sealed record GitStatusResult(
    bool Succeeded, string Branch, IReadOnlyList<GitFileStatus> Files, string? Error = null,
    string? Upstream = null, int? Ahead = null, int? Behind = null,
    IReadOnlyList<GitRemote>? Remotes = null);
public sealed record GitRemote(string Name, string? FetchUrl = null, string? PushUrl = null);
public sealed record GitHunk(string Path, string Header, string Patch);
public sealed record GitHistoryEntry(string Id, string ShortId, string Author, string Date, string Subject);

public sealed class GitService
{
    public const int MaximumStatusEntries = 10_000;
    private readonly BoundedProcessRunner runner;

    public GitService(BoundedProcessRunner? runner = null) => this.runner = runner ?? new BoundedProcessRunner();

    public async Task<GitStatusResult> StatusAsync(string root, CancellationToken cancellationToken = default)
    {
        var normalized = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        if (normalized is null) return new(false, String.Empty, [], "Workspace root is unavailable.");
        var result = await RunGitAsync(normalized,
            ["status", "--porcelain=v2", "-z", "--branch"], cancellationToken);
        if (!result.Started || result.ExitCode != 0)
        {
            return new(false, String.Empty, [], result.Error ?? result.StandardError.Trim());
        }
        var status = ParseStatus(result.StandardOutput);
        var remotes = await RunGitAsync(normalized,
            ["config", "--get-regexp", "^remote[.].*[.](url|pushurl)$"], cancellationToken);
        var remoteValues = remotes.Started && remotes.ExitCode is 0 or 1
            ? ParseRemotes(remotes.StandardOutput) : [];
        return status with { Remotes = remoteValues };
    }

    public Task<ProcessResult> DiffAsync(
        string root, string relativePath, bool staged = false, CancellationToken cancellationToken = default)
    {
        if (!TryNormalizeRelativePath(root, relativePath, out var normalizedRoot, out var relative))
        {
            return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Path is outside the repository root."));
        }
        var arguments = staged
            ? new[] { "diff", "--cached", "--", relative }
            : new[] { "diff", "--", relative };
        return RunGitAsync(normalizedRoot, arguments, cancellationToken);
    }

    public Task<ProcessResult> StageAsync(
        string root, string relativePath, CancellationToken cancellationToken = default) =>
        RunPathCommandAsync(root, relativePath, ["add", "--"], cancellationToken);

    public Task<ProcessResult> UnstageAsync(
        string root, string relativePath, CancellationToken cancellationToken = default) =>
        RunPathCommandAsync(root, relativePath, ["restore", "--staged", "--"], cancellationToken);

    public Task<ProcessResult> StageAsync(
        string root, IReadOnlyList<string> relativePaths, CancellationToken cancellationToken = default) =>
        RunPathsCommandAsync(root, relativePaths, ["add", "--"], cancellationToken);

    public Task<ProcessResult> UnstageAsync(
        string root, IReadOnlyList<string> relativePaths, CancellationToken cancellationToken = default) =>
        RunPathsCommandAsync(root, relativePaths, ["restore", "--staged", "--"], cancellationToken);

    public Task<ProcessResult> DiscardAsync(
        string root, IReadOnlyList<string> relativePaths, CancellationToken cancellationToken = default) =>
        RunPathsCommandAsync(root, relativePaths, ["restore", "--worktree", "--"], cancellationToken);

    public async Task<IReadOnlyList<GitHunk>> HunksAsync(
        string root, string relativePath, CancellationToken cancellationToken = default)
    {
        var result = await DiffAsync(root, relativePath, cancellationToken: cancellationToken);
        return result.Started && result.ExitCode == 0 ? ParseHunks(relativePath, result.StandardOutput) : [];
    }

    public async Task<ProcessResult> ApplyHunkAsync(
        string root, string relativePath, string patch, bool stage, CancellationToken cancellationToken = default)
    {
        if (String.IsNullOrEmpty(patch) || patch.Length > 2 * 1024 * 1024)
            return new(false, null, String.Empty, String.Empty, Error: "Git hunk is invalid.");
        var current = await DiffAsync(root, relativePath, cancellationToken: cancellationToken);
        if (!current.Started || current.ExitCode != 0
            || !ParseHunks(relativePath, current.StandardOutput).Any(hunk => hunk.Patch == patch))
            return new(false, null, String.Empty, String.Empty, Error: "The selected Git hunk is stale.");
        if (!TryNormalizeRelativePath(root, relativePath, out var normalizedRoot, out _))
            return new(false, null, String.Empty, String.Empty, Error: "Path is outside the repository root.");
        var arguments = stage ? new[] { "apply", "--cached", "-" }
            : new[] { "apply", "--reverse", "-" };
        return await RunGitAsync(normalizedRoot, arguments, cancellationToken, patch);
    }

    public async Task<IReadOnlyList<GitHistoryEntry>> HistoryAsync(
        string root, string relativePath, CancellationToken cancellationToken = default)
    {
        if (!TryNormalizeRelativePath(root, relativePath, out var normalizedRoot, out var relative)) return [];
        var result = await RunGitAsync(normalizedRoot,
            ["log", "-n", "100", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00", "--", relative],
            cancellationToken);
        return result.Started && result.ExitCode == 0 ? ParseHistory(result.StandardOutput) : [];
    }

    public Task<ProcessResult> BlameAsync(
        string root, string relativePath, CancellationToken cancellationToken = default) =>
        RunPathCommandAsync(root, relativePath, ["blame", "--date=short", "--"], cancellationToken);

    public Task<ProcessResult> SwitchBranchAsync(
        string root, string branch, bool create, CancellationToken cancellationToken = default)
    {
        var normalized = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        if (normalized is null || !ValidBranch(branch))
            return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Branch name is invalid."));
        return RunGitAsync(normalized, create ? ["switch", "-c", branch] : ["switch", branch], cancellationToken);
    }

    public Task<ProcessResult> CommitAsync(
        string root, string message, CancellationToken cancellationToken = default)
    {
        var normalized = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        var trimmed = message.Trim();
        if (normalized is null || trimmed.Length is < 1 or > 10_000 || trimmed.Contains('\0'))
        {
            return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Commit message is invalid."));
        }
        return RunGitAsync(normalized, ["commit", "-m", trimmed], cancellationToken);
    }

    public static GitStatusResult ParseStatus(string porcelain)
    {
        var records = porcelain.Split('\0', StringSplitOptions.RemoveEmptyEntries);
        var branch = String.Empty;
        string? upstream = null;
        int? ahead = null;
        int? behind = null;
        var files = new List<GitFileStatus>();
        for (var index = 0; index < records.Length; index++)
        {
            var record = records[index];
            if (record.StartsWith("# branch.head ", StringComparison.Ordinal))
            {
                branch = record[14..];
                continue;
            }
            if (record.StartsWith("# branch.upstream ", StringComparison.Ordinal))
            {
                upstream = record[18..];
                continue;
            }
            if (record.StartsWith("# branch.ab ", StringComparison.Ordinal))
            {
                var values = record[12..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (values.Length == 2 && Int32.TryParse(values[0].TrimStart('+'), out var parsedAhead)
                    && Int32.TryParse(values[1].TrimStart('-'), out var parsedBehind))
                {
                    ahead = Math.Max(0, parsedAhead);
                    behind = Math.Max(0, parsedBehind);
                }
                continue;
            }
            if (record.StartsWith("? ", StringComparison.Ordinal))
            {
                files.Add(new(record[2..], "?", "?"));
                if (files.Count >= MaximumStatusEntries) break;
                continue;
            }
            if (record.Length < 4 || record[0] is not ('1' or '2' or 'u')) continue;
            var fields = record.Split(' ', record[0] == '1' ? 9 : record[0] == '2' ? 10 : 11,
                StringSplitOptions.None);
            if (fields.Length < 2 || fields[1].Length != 2) continue;
            var path = fields[^1];
            var indexStatus = fields[1][0] == '.' ? " " : fields[1][0].ToString();
            var workTreeStatus = fields[1][1] == '.' ? " " : fields[1][1].ToString();
            if (record[0] == '2' && index + 1 < records.Length) index++;
            files.Add(new(path, indexStatus, workTreeStatus));
            if (files.Count >= MaximumStatusEntries) break;
        }
        return new(true, branch.Length == 0 ? "(detached)" : branch, files,
            Upstream: upstream, Ahead: ahead, Behind: behind);
    }

    public static IReadOnlyList<GitRemote> ParseRemotes(string text)
    {
        var values = new Dictionary<string, GitRemote>(StringComparer.Ordinal);
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = line.IndexOfAny([' ', '\t']);
            if (separator <= 7) continue;
            var key = line[..separator];
            var suffix = key.EndsWith(".pushurl", StringComparison.Ordinal) ? "pushurl"
                : key.EndsWith(".url", StringComparison.Ordinal) ? "url" : null;
            if (suffix is null || !key.StartsWith("remote.", StringComparison.Ordinal)) continue;
            var name = key[7..^(suffix.Length + 1)];
            if (name.Length == 0 || name.Length > 200) continue;
            var url = SanitizeRemoteUrl(line[(separator + 1)..]);
            if (url.Length == 0) continue;
            var current = values.GetValueOrDefault(name) ?? new GitRemote(name);
            values[name] = suffix == "url" && current.FetchUrl is null
                ? current with { FetchUrl = url } : current with { PushUrl = url };
            if (values.Count >= 100) break;
        }
        return values.Values.OrderBy(value => value.Name, StringComparer.Ordinal).ToArray();
    }

    public static string SanitizeRemoteUrl(string value)
    {
        var url = value.Trim();
        if (url.Length == 0) return String.Empty;
        var scheme = url.IndexOf("://", StringComparison.Ordinal);
        if (scheme > 0 && Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            var builder = new UriBuilder(parsed) { UserName = String.Empty, Password = String.Empty, Query = String.Empty, Fragment = String.Empty };
            return Bound(Uri.UnescapeDataString(builder.Uri.AbsoluteUri), 4_096);
        }
        var at = url.IndexOf('@');
        var colon = url.IndexOf(':');
        if (at > 0 && colon > 0 && colon < at) url = url[(at + 1)..];
        else if (at > 0) url = url[(at + 1)..];
        return Bound(url, 4_096);
    }

    public static IReadOnlyList<GitHunk> ParseHunks(string relativePath, string diff)
    {
        if (diff.Length > 2 * 1024 * 1024) return [];
        var lines = diff.Split('\n');
        var prefix = new List<string>();
        var hunks = new List<GitHunk>();
        List<string>? current = null;
        var header = String.Empty;
        foreach (var line in lines)
        {
            if (line.StartsWith("@@ ", StringComparison.Ordinal))
            {
                if (current is not null) hunks.Add(new(relativePath, header,
                    String.Join('\n', prefix.Concat(current))));
                if (hunks.Count >= 200) break;
                header = line;
                current = [line];
            }
            else if (current is not null) current.Add(line);
            else prefix.Add(line);
        }
        if (current is not null && hunks.Count < 200)
            hunks.Add(new(relativePath, header, String.Join('\n', prefix.Concat(current))));
        return hunks.Where(hunk => hunk.Patch.Contains("@@ ", StringComparison.Ordinal)).ToArray();
    }

    public static IReadOnlyList<GitHistoryEntry> ParseHistory(string output)
    {
        var values = output.Split('\0');
        var entries = new List<GitHistoryEntry>();
        for (var index = 0; index + 4 < values.Length && entries.Count < 100; index += 5)
        {
            var id = Bound(values[index], 64);
            var shortId = Bound(values[index + 1], 64);
            if (id.Length == 0 || shortId.Length == 0) continue;
            entries.Add(new(id, shortId, Bound(values[index + 2], 500),
                Bound(values[index + 3], 100), Bound(values[index + 4], 2_000)));
        }
        return entries;
    }

    private Task<ProcessResult> RunPathCommandAsync(
        string root, string relativePath, IReadOnlyList<string> prefix, CancellationToken cancellationToken)
    {
        if (!TryNormalizeRelativePath(root, relativePath, out var normalizedRoot, out var relative))
        {
            return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Path is outside the repository root."));
        }
        return RunGitAsync(normalizedRoot, [.. prefix, relative], cancellationToken);
    }

    private Task<ProcessResult> RunPathsCommandAsync(
        string root, IReadOnlyList<string> relativePaths, IReadOnlyList<string> prefix,
        CancellationToken cancellationToken)
    {
        var normalizedRoot = WorkspaceRoots.Normalize([root]).FirstOrDefault();
        if (normalizedRoot is null || relativePaths.Count is < 1 or > 500)
            return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Git paths are invalid."));
        var normalized = new List<string>();
        foreach (var path in relativePaths.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!TryNormalizeRelativePath(normalizedRoot, path, out _, out var relative))
                return Task.FromResult(new ProcessResult(false, null, String.Empty, String.Empty, Error: "Path is outside the repository root."));
            normalized.Add(relative);
        }
        return RunGitAsync(normalizedRoot, [.. prefix, .. normalized], cancellationToken);
    }

    private Task<ProcessResult> RunGitAsync(
        string root, IReadOnlyList<string> arguments, CancellationToken cancellationToken, string? standardInput = null) =>
        runner.RunAsync(new ProcessRequest("git", ["-C", root, .. arguments], root,
            TimeSpan.FromMinutes(2), StandardInput: standardInput), cancellationToken);

    private static bool ValidBranch(string branch) => !String.IsNullOrWhiteSpace(branch)
        && branch.Length <= 255 && !branch.Contains("..", StringComparison.Ordinal)
        && branch.All(character => Char.IsAsciiLetterOrDigit(character)
            || character is '.' or '_' or '/' or '-');
    private static string Bound(string value, int maximum) => value.Length <= maximum
        ? value : value[..maximum];

    private static bool TryNormalizeRelativePath(
        string root, string relativePath, out string normalizedRoot, out string relative)
    {
        normalizedRoot = WorkspaceRoots.Normalize([root]).FirstOrDefault() ?? String.Empty;
        relative = String.Empty;
        if (normalizedRoot.Length == 0 || String.IsNullOrWhiteSpace(relativePath)) return false;
        var candidate = Path.GetFullPath(Path.Combine(normalizedRoot, relativePath));
        if (!WorkspaceTree.IsInside(normalizedRoot, candidate)) return false;
        relative = Path.GetRelativePath(normalizedRoot, candidate);
        return relative != ".";
    }
}
