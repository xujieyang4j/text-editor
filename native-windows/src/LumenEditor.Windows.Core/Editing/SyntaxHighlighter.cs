namespace LumenEditor.Windows.Core.Editing;

public enum SyntaxTokenKind { Keyword, String, Number, Comment, Type, Constant, Markup }
public sealed record SyntaxTokenSpan(int Start, int Length, SyntaxTokenKind Kind);
public sealed record SyntaxHighlightPlan(IReadOnlyList<SyntaxTokenSpan> Spans, bool WasTruncated);

/// <summary>Bounded UTF-16 lexical highlighting for the native Windows text surface.</summary>
public static class SyntaxHighlighter
{
    public const int MaximumSourceLength = 2 * 1024 * 1024;
    public const int MaximumSpans = 20_000;
    public const int MaximumIdentifierLength = 128;

    private static readonly HashSet<string> CommonKeywords = new(StringComparer.OrdinalIgnoreCase)
    {
        "break", "case", "catch", "class", "const", "continue", "default", "do",
        "else", "enum", "finally", "for", "func", "function", "if", "in", "let",
        "private", "protected", "public", "return", "static", "struct", "switch",
        "throw", "throws", "try", "var", "while"
    };
    private static readonly HashSet<string> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        "bool", "boolean", "byte", "char", "double", "float", "int", "integer",
        "long", "number", "object", "short", "string", "uint", "void", "array",
        "dictionary", "list", "set", "tuple"
    };
    private static readonly HashSet<string> Constants = new(StringComparer.OrdinalIgnoreCase)
        { "false", "nil", "none", "null", "true", "undefined", "nan", "inf" };
    private static readonly HashSet<string> PythonKeywords = new(StringComparer.OrdinalIgnoreCase)
        { "and", "as", "async", "await", "def", "elif", "except", "from", "import", "lambda", "not", "or", "pass", "raise", "with", "yield" };
    private static readonly HashSet<string> JavaScriptKeywords = new(StringComparer.OrdinalIgnoreCase)
        { "async", "await", "delete", "export", "extends", "import", "instanceof", "interface", "new", "of", "typeof", "void", "yield" };
    private static readonly HashSet<string> SqlKeywords = new(StringComparer.OrdinalIgnoreCase)
        { "alter", "and", "as", "create", "delete", "distinct", "drop", "from", "group", "having", "insert", "into", "join", "limit", "on", "or", "order", "select", "table", "union", "update", "values", "where" };

    public static SyntaxHighlightPlan Plan(string text, string languageId)
    {
        if (String.IsNullOrEmpty(text) || languageId is "plain" or "diff") return new([], false);
        var limit = Math.Min(text.Length, MaximumSourceLength);
        IReadOnlyList<SyntaxTokenSpan> spans = languageId switch
        {
            "markdown" or "latex" or "rst" => Markdown(text, limit),
            "html" or "xml" or "vue" => Markup(text, limit),
            _ => Code(text, limit, languageId)
        };
        return new(spans, text.Length > limit || spans.Count >= MaximumSpans);
    }

    private static IReadOnlyList<SyntaxTokenSpan> Code(string text, int limit, string language)
    {
        var spans = new List<SyntaxTokenSpan>();
        var hash = language is "python" or "ruby" or "shell" or "yaml" or "toml" or "powershell";
        var dash = language is "sql" or "lua";
        var semicolon = language is "ini";
        for (var index = 0; index < limit && spans.Count < MaximumSpans;)
        {
            var lineComment = hash && text[index] == '#' || semicolon && text[index] == ';'
                || dash && Starts(text, index, "--", limit) || !hash && !dash && !semicolon && Starts(text, index, "//", limit);
            if (lineComment)
            {
                var end = LineEnd(text, index, limit);
                spans.Add(new(index, end - index, SyntaxTokenKind.Comment)); index = end; continue;
            }
            if (!hash && !semicolon && Starts(text, index, "/*", limit))
            {
                var close = text.IndexOf("*/", index + 2, StringComparison.Ordinal);
                var end = close < 0 || close + 2 > limit ? limit : close + 2;
                spans.Add(new(index, end - index, SyntaxTokenKind.Comment)); index = end; continue;
            }
            if (text[index] == '"' || text[index] == '\'' || text[index] == '`')
            {
                var end = QuotedEnd(text, index, limit);
                spans.Add(new(index, end - index, SyntaxTokenKind.String)); index = end; continue;
            }
            if (Char.IsDigit(text[index]) && (index == 0 || !IsIdentifier(text[index - 1])))
            {
                var end = index + 1;
                while (end < limit && (Char.IsDigit(text[end]) || text[end] is '.' or '_' or 'x' or 'X'
                    || text[end] is >= 'a' and <= 'f' || text[end] is >= 'A' and <= 'F')) end++;
                spans.Add(new(index, end - index, SyntaxTokenKind.Number)); index = end; continue;
            }
            if (IsIdentifierStart(text[index]))
            {
                var end = index + 1;
                while (end < limit && IsIdentifier(text[end]) && end - index <= MaximumIdentifierLength) end++;
                var token = text[index..end];
                var kind = Constants.Contains(token) ? SyntaxTokenKind.Constant
                    : IsKeyword(language, token) ? SyntaxTokenKind.Keyword
                    : Types.Contains(token) ? SyntaxTokenKind.Type : (SyntaxTokenKind?)null;
                if (kind is { } value) spans.Add(new(index, end - index, value));
                index = end; continue;
            }
            index++;
        }
        return spans;
    }

    private static IReadOnlyList<SyntaxTokenSpan> Markup(string text, int limit)
    {
        var spans = new List<SyntaxTokenSpan>();
        for (var index = 0; index < limit && spans.Count < MaximumSpans;)
        {
            if (Starts(text, index, "<!--", limit))
            {
                var close = text.IndexOf("-->", index + 4, StringComparison.Ordinal);
                var end = close < 0 || close + 3 > limit ? limit : close + 3;
                spans.Add(new(index, end - index, SyntaxTokenKind.Comment)); index = end; continue;
            }
            if (text[index] != '<') { index++; continue; }
            var closing = text.IndexOf('>', index + 1);
            var endTag = closing < 0 || closing >= limit ? limit : closing + 1;
            spans.Add(new(index, endTag - index, SyntaxTokenKind.Markup));
            for (var cursor = index + 1; cursor < endTag && spans.Count < MaximumSpans;)
            {
                if (text[cursor] == '"' || text[cursor] == '\'')
                {
                    var end = QuotedEnd(text, cursor, endTag);
                    spans.Add(new(cursor, end - cursor, SyntaxTokenKind.String)); cursor = end;
                }
                else cursor++;
            }
            index = endTag;
        }
        return spans;
    }

    private static IReadOnlyList<SyntaxTokenSpan> Markdown(string text, int limit)
    {
        var spans = new List<SyntaxTokenSpan>();
        for (var start = 0; start < limit && spans.Count < MaximumSpans;)
        {
            var end = LineEnd(text, start, limit);
            var first = start;
            while (first < end && text[first] == ' ') first++;
            if (first < end && text[first] is '#' or '>' or '-' or '*')
            {
                spans.Add(new(first, end - first, SyntaxTokenKind.Markup));
            }
            for (var cursor = start; cursor < end && spans.Count < MaximumSpans;)
            {
                if (text[cursor] == '`')
                {
                    var close = text.IndexOf('`', cursor + 1);
                    var tokenEnd = close < 0 || close >= end ? end : close + 1;
                    spans.Add(new(cursor, tokenEnd - cursor, SyntaxTokenKind.String)); cursor = tokenEnd;
                }
                else cursor++;
            }
            start = end < limit ? end + 1 : limit;
        }
        return spans;
    }

    private static bool IsKeyword(string language, string token) => CommonKeywords.Contains(token)
        || language == "python" && PythonKeywords.Contains(token)
        || language is "javascript" or "typescript" && JavaScriptKeywords.Contains(token)
        || language == "sql" && SqlKeywords.Contains(token);

    private static int QuotedEnd(string text, int start, int limit)
    {
        var quote = text[start];
        var escaped = false;
        for (var index = start + 1; index < limit; index++)
        {
            if (escaped) escaped = false;
            else if (text[index] == '\\') escaped = true;
            else if (text[index] == quote) return index + 1;
            else if (text[index] is '\n' or '\r') return index;
        }
        return limit;
    }

    private static int LineEnd(string text, int start, int limit)
    {
        var newline = text.IndexOf('\n', start);
        return newline < 0 || newline > limit ? limit : newline;
    }
    private static bool Starts(string text, int offset, string marker, int limit) =>
        offset + marker.Length <= limit && text.AsSpan(offset, marker.Length).SequenceEqual(marker);
    private static bool IsIdentifierStart(char value) => Char.IsLetter(value) || value is '_' or '$';
    private static bool IsIdentifier(char value) => IsIdentifierStart(value) || Char.IsDigit(value);
}
