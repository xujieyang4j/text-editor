using System.Text.RegularExpressions;
using LumenEditor.Windows.Core.Editing;

namespace LumenEditor.Windows.Core.Find;

public sealed record FindQuery(string Text, bool CaseSensitive = false, bool WholeWord = false, bool UseRegex = false);
public sealed record FindMatch(int Start, int Length);
public enum ReplaceNextOutcome { NotFound, Selected, Replaced }

/// <summary>Bounded document find/replace planner; zero-width matches are never replaced.</summary>
public static class FindEngine
{
    public const int MaximumMatches = 10_000;

    public static IReadOnlyList<FindMatch> Find(string text, FindQuery query)
    {
        var pattern = Compile(query);
        if (pattern is null) return [];
        try
        {
            return pattern.Matches(text)
                .Where(match => WholeWordAccepts(text, match, query.WholeWord))
                .Take(MaximumMatches)
                .Select(match => new FindMatch(match.Index, match.Length))
                .ToList();
        }
        catch (ArgumentException) { return []; }
        catch (RegexMatchTimeoutException) { return []; }
    }

    public static bool IsValid(FindQuery query) => String.IsNullOrEmpty(query.Text) || Compile(query) is not null;

    public static FindMatch? FindNext(
        string text, FindQuery query, TextSelection selection, bool reverse = false)
    {
        var matches = Find(text, query);
        if (matches.Count == 0) return null;
        bool IsCurrent(FindMatch match) => match.Start == selection.Start && match.Length == selection.Length;
        if (reverse)
        {
            return matches.LastOrDefault(match => match.Start + match.Length <= selection.Start && !IsCurrent(match))
                ?? matches.LastOrDefault(match => !IsCurrent(match));
        }
        return matches.FirstOrDefault(match => match.Start >= selection.End && !IsCurrent(match))
            ?? matches.FirstOrDefault(match => !IsCurrent(match));
    }

    public static ReplaceNextOutcome ReplaceNextOrSelect(
        EditorBuffer buffer, FindQuery query, string replacement)
    {
        var pattern = Compile(query);
        if (pattern is null) return ReplaceNextOutcome.NotFound;
        Match? selected;
        try
        {
            selected = pattern.Matches(buffer.Text)
                .FirstOrDefault(match => WholeWordAccepts(buffer.Text, match, query.WholeWord)
                    && match.Index == buffer.Selection.Start && match.Length == buffer.Selection.Length);
        }
        catch (RegexMatchTimeoutException)
        {
            return ReplaceNextOutcome.NotFound;
        }
        if (selected is null || selected.Length == 0)
        {
            var next = FindNext(buffer.Text, query, buffer.Selection);
            if (next is null || next.Length == 0) return ReplaceNextOutcome.NotFound;
            buffer.SetSelection(new TextSelection(next.Start, next.Start + next.Length));
            return ReplaceNextOutcome.Selected;
        }

        var expanded = ReplacementText(selected, query, replacement);
        var after = buffer.Text[..selected.Index] + expanded + buffer.Text[(selected.Index + selected.Length)..];
        var cursor = selected.Index + expanded.Length;
        var nextMatch = FindNext(after, query, new TextSelection(cursor, cursor));
        var nextSelection = nextMatch is null
            ? new TextSelection(cursor, cursor)
            : new TextSelection(nextMatch.Start, nextMatch.Start + nextMatch.Length);
        return buffer.Replace(buffer.Selection, expanded, nextSelection)
            ? ReplaceNextOutcome.Replaced
            : ReplaceNextOutcome.NotFound;
    }

    public static bool ReplaceNext(EditorBuffer buffer, FindQuery query, string replacement)
    {
        var next = FindNext(buffer.Text, query, buffer.Selection);
        if (next is null || next.Length == 0) return false;
        var pattern = Compile(query);
        if (pattern is null) return false;
        var match = pattern.Match(buffer.Text, next.Start);
        if (!match.Success || match.Index != next.Start || match.Length != next.Length) return false;
        return buffer.Replace(
            new TextSelection(next.Start, next.Start + next.Length),
            ReplacementText(match, query, replacement));
    }

    public static bool ReplaceAll(EditorBuffer buffer, FindQuery query, string replacement)
    {
        var pattern = Compile(query);
        if (pattern is null) return false;
        List<Match> matches;
        try
        {
            matches = pattern.Matches(buffer.Text)
                .Where(match => WholeWordAccepts(buffer.Text, match, query.WholeWord))
                .Take(MaximumMatches + 1)
                .ToList();
        }
        catch (RegexMatchTimeoutException) { return false; }
        if (matches.Count == 0 || matches.Count > MaximumMatches || matches.Any(match => match.Length == 0)) return false;
        var builder = new System.Text.StringBuilder(buffer.Text.Length);
        var cursor = 0;
        foreach (var match in matches)
        {
            builder.Append(buffer.Text, cursor, match.Index - cursor);
            builder.Append(ReplacementText(match, query, replacement));
            cursor = match.Index + match.Length;
        }
        builder.Append(buffer.Text, cursor, buffer.Text.Length - cursor);
        return buffer.Apply(builder.ToString(), new TextSelection(0, 0));
    }

    private static Regex? Compile(FindQuery query)
    {
        if (String.IsNullOrEmpty(query.Text)) return null;
        var source = query.UseRegex ? query.Text : Regex.Escape(Unquote(query.Text));
        var options = RegexOptions.CultureInvariant | RegexOptions.Multiline;
        if (!query.CaseSensitive) options |= RegexOptions.IgnoreCase;
        try { return new Regex(source, options, TimeSpan.FromMilliseconds(100)); }
        catch (ArgumentException) { return null; }
    }

    private static string ReplacementText(Match match, FindQuery query, string replacement)
    {
        var value = Unquote(replacement ?? String.Empty);
        if (!query.UseRegex) return value;
        try { return match.Result(value); }
        catch (ArgumentException) { return value; }
    }

    private static string Unquote(string value)
    {
        var builder = new System.Text.StringBuilder(value.Length);
        for (var index = 0; index < value.Length; index++)
        {
            if (value[index] != '\\' || index + 1 >= value.Length)
            {
                builder.Append(value[index]);
                continue;
            }
            var next = value[index + 1];
            if (next is 'n' or 'r' or 't' or '\\')
            {
                builder.Append(next switch { 'n' => '\n', 'r' => '\r', 't' => '\t', _ => '\\' });
                index++;
            }
            else builder.Append(value[index]);
        }
        return builder.ToString();
    }

    private static bool WholeWordAccepts(string text, Match match, bool enabled)
    {
        if (!enabled || match.Length == 0) return true;
        var startsWithWord = IsWordCharacter(text[match.Index]);
        var endsWithWord = IsWordCharacter(text[match.Index + match.Length - 1]);
        return !(startsWithWord && match.Index > 0 && IsWordCharacter(text[match.Index - 1]))
            && !(endsWithWord && match.Index + match.Length < text.Length
                && IsWordCharacter(text[match.Index + match.Length]));
    }

    private static bool IsWordCharacter(char value) => Char.IsLetterOrDigit(value) || value == '_';
}
