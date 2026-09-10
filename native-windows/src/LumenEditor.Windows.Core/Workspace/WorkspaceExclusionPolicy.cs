using System.Text;
using System.Text.RegularExpressions;

namespace LumenEditor.Windows.Core.Workspace;

/// <summary>
/// Immutable, bounded project exclusion rules shared by every recursive
/// workspace consumer. Patterns use the same compact glob subset as the
/// Electron and native macOS clients: *, ?, ** and forward-slash separators.
/// </summary>
public sealed class WorkspaceExclusionPolicy
{
    public const int MaximumPatterns = 100;
    public const int MaximumPatternCharacters = 200;
    private static readonly TimeSpan MatchTimeout = TimeSpan.FromMilliseconds(50);
    public static WorkspaceExclusionPolicy Empty { get; } = new([]);

    private readonly IReadOnlyList<Regex> matchers;
    public IReadOnlyList<string> Patterns { get; }

    public WorkspaceExclusionPolicy(IEnumerable<string> patterns)
    {
        ArgumentNullException.ThrowIfNull(patterns);
        var normalized = patterns
            .Select(Normalize)
            .Where(pattern => pattern is not null)
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(MaximumPatterns)
            .ToArray();
        Patterns = normalized;
        matchers = normalized.Select(Compile).ToArray();
    }

    public bool IsExcluded(string root, string candidate, bool isDirectory)
    {
        if (matchers.Count == 0 || !WorkspaceTree.IsInside(root, candidate)) return false;
        var relative = Path.GetRelativePath(Path.GetFullPath(root), Path.GetFullPath(candidate))
            .Replace('\\', '/');
        if (relative == ".") return false;
        foreach (var matcher in matchers)
        {
            try
            {
                if (matcher.IsMatch(relative) || (isDirectory && matcher.IsMatch(relative + "/"))) return true;
            }
            catch (RegexMatchTimeoutException)
            {
                // A pathological pattern is ignored instead of blocking a workspace walk.
            }
        }
        return false;
    }

    private static string? Normalize(string? value)
    {
        if (String.IsNullOrWhiteSpace(value)) return null;
        var pattern = value.Trim().Replace('\\', '/');
        while (pattern.StartsWith("./", StringComparison.Ordinal)) pattern = pattern[2..];
        if (pattern.Length == 0 || pattern[0] == '/' || pattern.Contains('\0')
            || pattern == ".." || pattern.StartsWith("../", StringComparison.Ordinal)
            || pattern.Contains("/../", StringComparison.Ordinal)
            || (pattern.Length >= 3 && Char.IsAsciiLetter(pattern[0]) && pattern[1] == ':' && pattern[2] == '/'))
        {
            return null;
        }
        return pattern[..Math.Min(pattern.Length, MaximumPatternCharacters)];
    }

    private static Regex Compile(string pattern)
    {
        var source = new StringBuilder("^");
        for (var index = 0; index < pattern.Length; index++)
        {
            var character = pattern[index];
            if (character == '*')
            {
                if (index + 1 < pattern.Length && pattern[index + 1] == '*')
                {
                    index++;
                    if (index + 1 < pattern.Length && pattern[index + 1] == '/')
                    {
                        index++;
                        source.Append("(?:.*/)?");
                    }
                    else source.Append(".*");
                }
                else source.Append("[^/]*");
            }
            else if (character == '?') source.Append("[^/]");
            else source.Append(Regex.Escape(character.ToString()));
        }
        source.Append('$');
        return new Regex(source.ToString(), RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, MatchTimeout);
    }
}
