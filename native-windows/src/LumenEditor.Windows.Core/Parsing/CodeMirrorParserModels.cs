using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using LumenEditor.Windows.Core.Editing;
using LumenEditor.Windows.Core.Navigation;

namespace LumenEditor.Windows.Core.Parsing;

public static class CodeMirrorParserProtocol
{
    public const int Version = 2;
    public const int MaximumBundleBytes = 8 * 1024 * 1024;
    public const int MaximumSourceUtf16Length = 128 * 1024;
    public const int MaximumSourceLines = 50_000;
    public const int MaximumRequestUtf8Bytes = 1024 * 1024;
    public const int MaximumBundleResultUtf8Bytes = 1792 * 1024;
    public const int MaximumTransportResponseUtf8Bytes = 2 * 1024 * 1024;
    public const int MaximumHighlights = 20_000;
    public const int MaximumSyntaxNodes = 50_000;
    public const int MaximumBracketPairs = 10_000;
    public const int MaximumFolds = 10_000;
    public const int MaximumSymbols = 5_000;
    public const int MaximumIndentationEntries = 100_000;
    public const int MaximumNewlineIndentationEntries = 8;
    public const int MaximumNewlineIndentationTransitions = 48;
    public const int MaximumLanguageUtf16Length = 128;
    public const int MaximumNodeTypeUtf16Length = 128;
    public const int MaximumSymbolLabelUtf16Length = 1024;
    public const int MaximumSymbolLevel = 256;
    public const int MaximumSyntaxDepth = 256;
    public const int MaximumIndentationColumns = 1_000_000;
    public const int MaximumErrorCharacters = 2_000;

    public static bool IsSourceWithinBudget(string text)
    {
        if (text is null || text.Length > MaximumSourceUtf16Length) return false;
        var lines = 1;
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] == '\n') lines++;
            else if (text[index] == '\r')
            {
                lines++;
                if (index + 1 < text.Length && text[index + 1] == '\n') index++;
            }
            if (lines > MaximumSourceLines) return false;
        }
        return true;
    }
}

public enum CodeMirrorParserKind { Lezer, Stream, Unsupported }
public enum CodeMirrorHighlightKind { Keyword, String, Number, Comment, Type, Constant, Markup }
public enum CodeMirrorSymbolKind { Type, Function, Method, Variable, Heading }

public sealed record CodeMirrorParserRequest(
    int Version, string RequestId, string Text, string Language, int TabWidth,
    int IndentWidth, bool InsertSpaces, IReadOnlyList<int>? NewlineIndentationPositions = null);

public sealed record CodeMirrorParserResponse(
    int Version, string RequestId, CodeMirrorParserResult? Result = null, string? Error = null);

public sealed record CodeMirrorParserBundleEnvelope(CodeMirrorParserResult Result);
public sealed record CodeMirrorHighlight(int From, int To, CodeMirrorHighlightKind Kind);
public sealed record CodeMirrorSyntaxNode(int From, int To, string Type, int Parent);
public sealed record CodeMirrorBracketPair(int Open, int Close);
public sealed record CodeMirrorFold(
    int FullFrom, int FullTo, int From, int To, int StartLine, int EndLine);
public sealed record CodeMirrorSymbol(
    string Label, CodeMirrorSymbolKind Kind, int From, int To, int Line, int Level);
public sealed record CodeMirrorLineIndentation(int LineFrom, int? Columns);
public sealed record CodeMirrorNewlineIndentation(
    int Position, int? Columns, int? DoubleColumns = null, bool? Explode = null);
public sealed record CodeMirrorNewlineIndentationTransition(
    int Position, string Insert, int? Columns, int? DoubleColumns = null, bool? Explode = null);
public sealed record CodeMirrorTruncation(
    bool Source, bool Highlights, bool SyntaxNodes, bool BracketPairs,
    bool Folds, bool Symbols, bool Indentation);

/// <summary>Untrusted schema-v2 wire result. Consume only through Validate.</summary>
public sealed record CodeMirrorParserResult(
    int SchemaVersion, bool Supported, CodeMirrorParserKind ParserKind,
    string RequestedLanguage, string ResolvedLanguage,
    [property: JsonPropertyName("sourceUTF16Length")] int SourceUtf16Length,
    List<CodeMirrorHighlight> Highlights, List<CodeMirrorSyntaxNode> SyntaxNodes,
    List<CodeMirrorBracketPair> BracketPairs, List<CodeMirrorFold> Folds,
    List<CodeMirrorSymbol> Symbols, List<CodeMirrorLineIndentation> Indentation,
    List<CodeMirrorNewlineIndentation>? NewlineIndentation,
    List<CodeMirrorNewlineIndentationTransition>? NewlineIndentationTransitions,
    CodeMirrorTruncation Truncated)
{
    public CodeMirrorParserAnalysis? Validate(string text, string language)
    {
        if (SchemaVersion != CodeMirrorParserProtocol.Version || RequestedLanguage != language
            || SourceUtf16Length != text.Length || !SafeString(RequestedLanguage,
                CodeMirrorParserProtocol.MaximumLanguageUtf16Length, allowsEmpty: true)
            || !SafeString(ResolvedLanguage, CodeMirrorParserProtocol.MaximumLanguageUtf16Length, allowsEmpty: true)
            || Highlights is null || Highlights.Count > CodeMirrorParserProtocol.MaximumHighlights
            || SyntaxNodes is null || SyntaxNodes.Count > CodeMirrorParserProtocol.MaximumSyntaxNodes
            || BracketPairs is null || BracketPairs.Count > CodeMirrorParserProtocol.MaximumBracketPairs
            || Folds is null || Folds.Count > CodeMirrorParserProtocol.MaximumFolds
            || Symbols is null || Symbols.Count > CodeMirrorParserProtocol.MaximumSymbols
            || Indentation is null || Indentation.Count > CodeMirrorParserProtocol.MaximumIndentationEntries
            || (NewlineIndentation?.Count ?? 0) > CodeMirrorParserProtocol.MaximumNewlineIndentationEntries
            || (NewlineIndentationTransitions?.Count ?? 0)
                > CodeMirrorParserProtocol.MaximumNewlineIndentationTransitions || Truncated is null) return null;

        if (Supported)
        {
            if (ParserKind == CodeMirrorParserKind.Lezer && SyntaxNodes.Count == 0) return null;
            if (ParserKind == CodeMirrorParserKind.Stream
                && (SyntaxNodes.Count != 1 || SyntaxNodes[0] != new CodeMirrorSyntaxNode(
                    0, SourceUtf16Length, "Document", -1) || Folds.Count != 0 || Symbols.Count != 0
                    || Truncated.SyntaxNodes || Truncated.Folds || Truncated.Symbols)) return null;
            if (ParserKind == CodeMirrorParserKind.Unsupported) return null;
        }
        else if (ParserKind != CodeMirrorParserKind.Unsupported || Highlights.Count != 0
            || SyntaxNodes.Count != 0 || BracketPairs.Count != 0 || Folds.Count != 0
            || Symbols.Count != 0 || Indentation.Count != 0 || NewlineIndentation?.Count > 0
            || NewlineIndentationTransitions?.Count > 0 || Truncated.Source || Truncated.Highlights
            || Truncated.SyntaxNodes || Truncated.BracketPairs || Truncated.Folds
            || Truncated.Symbols || Truncated.Indentation) return null;

        if (!ValidHighlights(Highlights, text.Length)
            || !ValidSyntaxNodes(SyntaxNodes, text.Length)
            || !ValidBracketPairs(BracketPairs, text) || !ValidFolds(Folds, text)
            || !ValidSymbols(Symbols, text) || !ValidIndentation(Indentation, text)
            || !ValidNewlineIndentation(NewlineIndentation ?? [], text.Length)
            || !ValidNewlineTransitions(NewlineIndentationTransitions ?? [], text.Length)) return null;

        return new CodeMirrorParserAnalysis(Supported, ParserKind, RequestedLanguage, ResolvedLanguage,
            SourceUtf16Length, Highlights.ToArray(), SyntaxNodes.ToArray(), BracketPairs.ToArray(),
            Folds.ToArray(), Symbols.ToArray(), Indentation.ToArray(),
            (NewlineIndentation ?? []).ToArray(), (NewlineIndentationTransitions ?? []).ToArray(), Truncated);
    }

    private static bool ValidHighlights(IReadOnlyList<CodeMirrorHighlight> values, int length)
    {
        var previousTo = -1;
        foreach (var value in values)
        {
            if (!NonemptyRange(value.From, value.To, length) || value.From < previousTo
                || !Enum.IsDefined(value.Kind)) return false;
            previousTo = value.To;
        }
        return true;
    }

    private static bool ValidSyntaxNodes(IReadOnlyList<CodeMirrorSyntaxNode> values, int length)
    {
        if (values.Count == 0) return true;
        var root = values[0];
        if (root.From != 0 || root.To != length || root.Parent != -1) return false;
        var activePath = new List<int> { 0 };
        var lastChildEnd = new Dictionary<int, int>();
        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];
            if (!Range(value.From, value.To, length) || !SafeString(value.Type,
                CodeMirrorParserProtocol.MaximumNodeTypeUtf16Length)) return false;
            if (index == 0) continue;
            while (activePath.Count > 0 && activePath[^1] != value.Parent) activePath.RemoveAt(activePath.Count - 1);
            if (value.Parent < 0 || value.Parent >= index || activePath.Count == 0
                || activePath[^1] != value.Parent || activePath.Count >= CodeMirrorParserProtocol.MaximumSyntaxDepth
                || value.From < (lastChildEnd.TryGetValue(value.Parent, out var end) ? end : values[value.Parent].From))
                return false;
            var parent = values[value.Parent];
            if (parent.From > value.From || parent.To < value.To) return false;
            lastChildEnd[value.Parent] = value.To;
            activePath.Add(index);
        }
        return true;
    }

    private static bool ValidBracketPairs(IReadOnlyList<CodeMirrorBracketPair> values, string text)
    {
        var matching = new Dictionary<char, char> { ['('] = ')', ['['] = ']', ['{'] = '}' };
        var previousOpen = -1;
        var containingCloses = new Stack<int>();
        var positions = new HashSet<int>();
        foreach (var value in values)
        {
            while (containingCloses.TryPeek(out var containingClose) && value.Open > containingClose)
                containingCloses.Pop();
            if (value.Open < 0 || value.Open >= value.Close || value.Close >= text.Length
                || value.Open <= previousOpen || !matching.TryGetValue(text[value.Open], out var expected)
                || expected != text[value.Close]
                || containingCloses.Count > 0 && value.Close >= containingCloses.Peek()
                || !positions.Add(value.Open) || !positions.Add(value.Close)) return false;
            previousOpen = value.Open;
            containingCloses.Push(value.Close);
        }
        return true;
    }

    private static bool ValidFolds(IReadOnlyList<CodeMirrorFold> values, string text)
    {
        var starts = LineStarts(text);
        var previousFullFrom = -1;
        var containingEnds = new Stack<int>();
        foreach (var value in values)
        {
            while (containingEnds.TryPeek(out var containingEnd) && value.FullFrom >= containingEnd)
                containingEnds.Pop();
            if (!NonemptyRange(value.FullFrom, value.FullTo, text.Length)
                || !NonemptyRange(value.From, value.To, text.Length) || value.FullFrom > value.From
                || value.To > value.FullTo || value.StartLine < 1 || value.StartLine >= value.EndLine
                || value.EndLine > starts.Count || LineNumber(value.FullFrom, starts) != value.StartLine
                || LineNumberForRangeEnd(value.FullTo, text, starts) != value.EndLine
                || value.FullFrom < previousFullFrom
                || containingEnds.Count > 0 && value.FullTo > containingEnds.Peek()) return false;
            previousFullFrom = value.FullFrom;
            containingEnds.Push(value.FullTo);
        }
        return true;
    }

    private static bool ValidSymbols(IReadOnlyList<CodeMirrorSymbol> values, string text)
    {
        var starts = LineStarts(text);
        var previousFrom = -1;
        foreach (var value in values)
        {
            if (!NonemptyRange(value.From, value.To, text.Length)
                || !SafeString(value.Label, CodeMirrorParserProtocol.MaximumSymbolLabelUtf16Length)
                || !Enum.IsDefined(value.Kind) || value.Line < 1 || value.Line > starts.Count
                || LineNumber(value.From, starts) != value.Line || value.Level < 0
                || value.Level > CodeMirrorParserProtocol.MaximumSymbolLevel || value.From < previousFrom) return false;
            previousFrom = value.From;
        }
        return true;
    }

    private static bool ValidIndentation(IReadOnlyList<CodeMirrorLineIndentation> values, string text)
    {
        var starts = LineStarts(text).ToHashSet();
        var previous = -1;
        foreach (var value in values)
        {
            if (value.LineFrom <= previous || !starts.Contains(value.LineFrom)
                || value.Columns is { } columns && (columns < 0
                    || columns > CodeMirrorParserProtocol.MaximumIndentationColumns)) return false;
            previous = value.LineFrom;
        }
        return true;
    }

    private static bool ValidNewlineIndentation(IReadOnlyList<CodeMirrorNewlineIndentation> values, int length)
    {
        var previous = -1;
        foreach (var value in values)
        {
            if (value.Position <= previous || value.Position > length
                || !ValidColumns(value.Columns) || !ValidColumns(value.DoubleColumns)) return false;
            previous = value.Position;
        }
        return true;
    }

    private static bool ValidNewlineTransitions(
        IReadOnlyList<CodeMirrorNewlineIndentationTransition> values, int length)
    {
        string[] allowed = ["(", "[", "{", ":", ",", ">"];
        (int Position, int Rank)? previous = null;
        foreach (var value in values)
        {
            var rank = Array.IndexOf(allowed, value.Insert);
            if (value.Position < 0 || value.Position > length || rank < 0 || value.Insert.Length != 1
                || !ValidColumns(value.Columns) || !ValidColumns(value.DoubleColumns)
                || previous is { } prior && (value.Position < prior.Position
                    || value.Position == prior.Position && rank <= prior.Rank)) return false;
            previous = (value.Position, rank);
        }
        return true;
    }

    private static bool ValidColumns(int? value) => value is null
        || value >= 0 && value <= CodeMirrorParserProtocol.MaximumIndentationColumns;
    private static bool Range(int from, int to, int length) => from >= 0 && to >= from && to <= length;
    private static bool NonemptyRange(int from, int to, int length) => from >= 0 && to > from && to <= length;

    private static bool SafeString(string? value, int maximum, bool allowsEmpty = false)
    {
        if (value is null || (!allowsEmpty && value.Length == 0) || value.Length > maximum) return false;
        for (var index = 0; index < value.Length; index++)
        {
            if (char.IsHighSurrogate(value[index]))
            {
                if (index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1])) return false;
                index++;
                continue;
            }
            if (char.IsLowSurrogate(value[index])) return false;
            var category = char.GetUnicodeCategory(value[index]);
            if (category is UnicodeCategory.Control or UnicodeCategory.LineSeparator
                or UnicodeCategory.ParagraphSeparator) return false;
        }
        return true;
    }

    private static List<int> LineStarts(string text)
    {
        var starts = new List<int> { 0 };
        for (var index = 0; index < text.Length;)
        {
            if (text[index] == '\r')
            {
                index++;
                if (index < text.Length && text[index] == '\n') index++;
                starts.Add(index);
            }
            else if (text[index++] == '\n') starts.Add(index);
        }
        return starts;
    }

    private static int LineNumber(int offset, IReadOnlyList<int> starts)
    {
        var low = 0;
        var high = starts.Count;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (starts[middle] <= offset) low = middle + 1; else high = middle;
        }
        return Math.Max(1, low);
    }

    private static int LineNumberForRangeEnd(int offset, string text, IReadOnlyList<int> starts)
    {
        if (offset <= 0) return 1;
        var last = offset - 1;
        if (text[last] == '\n')
        {
            last--;
            if (last >= 0 && text[last] == '\r') last--;
        }
        else if (text[last] == '\r') last--;
        return LineNumber(Math.Max(0, last), starts);
    }
}

/// <summary>Fully validated parser data safe for editor consumers.</summary>
public sealed record CodeMirrorParserAnalysis(
    bool Supported, CodeMirrorParserKind ParserKind, string RequestedLanguage,
    string ResolvedLanguage, int SourceUtf16Length, IReadOnlyList<CodeMirrorHighlight> Highlights,
    IReadOnlyList<CodeMirrorSyntaxNode> SyntaxNodes, IReadOnlyList<CodeMirrorBracketPair> BracketPairs,
    IReadOnlyList<CodeMirrorFold> Folds, IReadOnlyList<CodeMirrorSymbol> Symbols,
    IReadOnlyList<CodeMirrorLineIndentation> Indentation,
    IReadOnlyList<CodeMirrorNewlineIndentation> NewlineIndentation,
    IReadOnlyList<CodeMirrorNewlineIndentationTransition> NewlineIndentationTransitions,
    CodeMirrorTruncation Truncated)
{
    public SyntaxHighlightPlan ToSyntaxHighlightPlan() => new(Highlights.Select(value => new SyntaxTokenSpan(
        value.From, value.To - value.From, value.Kind switch
        {
            CodeMirrorHighlightKind.Keyword => SyntaxTokenKind.Keyword,
            CodeMirrorHighlightKind.String => SyntaxTokenKind.String,
            CodeMirrorHighlightKind.Number => SyntaxTokenKind.Number,
            CodeMirrorHighlightKind.Comment => SyntaxTokenKind.Comment,
            CodeMirrorHighlightKind.Type => SyntaxTokenKind.Type,
            CodeMirrorHighlightKind.Constant => SyntaxTokenKind.Constant,
            _ => SyntaxTokenKind.Markup
        })).ToArray(), Truncated.Source || Truncated.Highlights);

    public IReadOnlyList<FoldRegion> ToFoldRegions(string text)
    {
        if (text.Length != SourceUtf16Length || ParserKind != CodeMirrorParserKind.Lezer) return [];
        if (Folds.Count > 0) return Folds.Select(value => new FoldRegion(
            value.StartLine, value.EndLine, new TextSelection(value.FullFrom, value.FullTo),
            new TextSelection(value.From, value.To))).ToArray();
        if (Truncated.SyntaxNodes || Truncated.BracketPairs) return [];

        // CodeMirror's fold NodeProp is unavailable for a few grammars under
        // Jint even though their validated syntax tree and bracket pairs are
        // complete. Derive only multiline regions from those parser pairs;
        // unlike the lexical fallback, these pairs already exclude strings
        // and comments.
        var starts = new List<int> { 0 };
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] == '\n') starts.Add(index + 1);
            else if (text[index] == '\r')
            {
                if (index + 1 < text.Length && text[index + 1] == '\n') index++;
                starts.Add(index + 1);
            }
        }
        int LineIndex(int offset)
        {
            var index = starts.BinarySearch(offset);
            return index >= 0 ? index : Math.Max(0, ~index - 1);
        }
        var regions = new List<FoldRegion>();
        foreach (var pair in BracketPairs)
        {
            var startLine = LineIndex(pair.Open);
            var endLine = LineIndex(pair.Close);
            if (endLine <= startLine) continue;
            var hiddenStart = starts[startLine + 1];
            var fullEnd = endLine + 1 < starts.Count ? starts[endLine + 1] : text.Length;
            if (hiddenStart >= fullEnd) continue;
            regions.Add(new(startLine + 1, endLine + 1,
                new TextSelection(starts[startLine], fullEnd),
                new TextSelection(hiddenStart, fullEnd)));
            if (regions.Count >= CodeMirrorParserProtocol.MaximumFolds) break;
        }
        return regions.DistinctBy(value => value.Id).OrderBy(value => value.FullRange.Start)
            .ThenByDescending(value => value.FullRange.Length).ToArray();
    }

    public IReadOnlyList<DocumentSymbol> ToDocumentSymbols(string path, string text) => Symbols.Select(value =>
    {
        var (_, column) = TextNavigation.OffsetToLineColumn(text, value.From);
        return new DocumentSymbol(path, value.Label, value.Kind.ToString().ToLowerInvariant(), value.Line, column);
    }).ToArray();
}

public static class CodeMirrorParserCodec
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public static string EncodeRequest(CodeMirrorParserRequest request)
    {
        ValidateRequest(request);
        return EncodeBounded(request, CodeMirrorParserProtocol.MaximumRequestUtf8Bytes);
    }

    public static CodeMirrorParserRequest DecodeRequest(string json)
    {
        var request = Decode<CodeMirrorParserRequest>(json, CodeMirrorParserProtocol.MaximumRequestUtf8Bytes);
        ValidateRequest(request);
        return request;
    }

    public static string EncodeResponse(CodeMirrorParserResponse response)
    {
        ValidateResponse(response);
        return EncodeBounded(response, CodeMirrorParserProtocol.MaximumTransportResponseUtf8Bytes);
    }

    public static CodeMirrorParserResponse DecodeResponse(string json)
    {
        var response = Decode<CodeMirrorParserResponse>(json,
            CodeMirrorParserProtocol.MaximumTransportResponseUtf8Bytes);
        ValidateResponse(response);
        return response;
    }

    public static CodeMirrorParserResult DecodeBundleResult(
        string json, string text, string language)
    {
        var envelope = Decode<CodeMirrorParserBundleEnvelope>(json,
            CodeMirrorParserProtocol.MaximumBundleResultUtf8Bytes);
        return envelope.Result?.Validate(text, language) is null
            ? throw new InvalidDataException("The parser bundle returned an invalid result.")
            : envelope.Result;
    }

    public static string EncodeBundleRequest(CodeMirrorParserRequest request) => JsonSerializer.Serialize(new
    {
        request.Text, request.Language, request.TabWidth, request.IndentWidth, request.InsertSpaces,
        request.NewlineIndentationPositions
    }, Options);

    private static T Decode<T>(string json, int maximumBytes)
    {
        if (String.IsNullOrWhiteSpace(json) || Encoding.UTF8.GetByteCount(json) > maximumBytes)
            throw new InvalidDataException("Parser message has an invalid size.");
        try { return JsonSerializer.Deserialize<T>(json, Options)
            ?? throw new InvalidDataException("Parser message is empty."); }
        catch (JsonException error) { throw new InvalidDataException("Parser message is invalid JSON.", error); }
    }

    private static string EncodeBounded<T>(T value, int maximumBytes)
    {
        var json = JsonSerializer.Serialize(value, Options);
        if (Encoding.UTF8.GetByteCount(json) > maximumBytes)
            throw new InvalidDataException("Parser message exceeds its size limit.");
        return json;
    }

    private static void ValidateRequest(CodeMirrorParserRequest request)
    {
        if (request.Version != CodeMirrorParserProtocol.Version || String.IsNullOrEmpty(request.RequestId)
            || request.RequestId.Length > 100 || !CodeMirrorParserProtocol.IsSourceWithinBudget(request.Text)
            || request.Language is null
            || request.Language.Length > CodeMirrorParserProtocol.MaximumLanguageUtf16Length
            || request.TabWidth is < 1 or > 16 || request.IndentWidth is < 1 or > 16
            || (request.NewlineIndentationPositions?.Count ?? 0)
                > CodeMirrorParserProtocol.MaximumNewlineIndentationEntries
            || request.NewlineIndentationPositions?.Any(position => position < 0
                || position > request.Text.Length) == true
            || request.NewlineIndentationPositions?.Distinct().Count()
                != request.NewlineIndentationPositions?.Count)
            throw new InvalidDataException("Parser request is invalid.");
    }

    private static void ValidateResponse(CodeMirrorParserResponse response)
    {
        if (response.Version != CodeMirrorParserProtocol.Version || String.IsNullOrEmpty(response.RequestId)
            || response.RequestId.Length > 100 || (response.Result is null) == (response.Error is null)
            || response.Error?.Length > CodeMirrorParserProtocol.MaximumErrorCharacters)
            throw new InvalidDataException("Parser response is invalid.");
    }

}
