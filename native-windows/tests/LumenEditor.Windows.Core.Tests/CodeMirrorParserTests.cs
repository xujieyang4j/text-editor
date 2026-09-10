using System.Text.Json;
using LumenEditor.Windows.Core.Parsing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class CodeMirrorParserTests
{
    [Fact]
    public void Codec_RoundTripsSchemaV2RequestAndValidatedResponse()
    {
        const string text = "const answer = 42;";
        var request = new CodeMirrorParserRequest(2, "request", text, "javascript", 4, 2, true);
        Assert.Equal(request, CodeMirrorParserCodec.DecodeRequest(
            CodeMirrorParserCodec.EncodeRequest(request)));

        var result = ValidResult(text, "javascript") with
        {
            Highlights = [new(0, 5, CodeMirrorHighlightKind.Keyword),
                new(15, 17, CodeMirrorHighlightKind.Number)]
        };
        var response = new CodeMirrorParserResponse(2, "request", result);
        var decoded = CodeMirrorParserCodec.DecodeResponse(CodeMirrorParserCodec.EncodeResponse(response));
        var analysis = Assert.IsType<CodeMirrorParserAnalysis>(decoded.Result?.Validate(text, "javascript"));
        Assert.Equal(2, analysis.Highlights.Count);
        Assert.Equal(2, analysis.ToSyntaxHighlightPlan().Spans.Count);
    }

    [Fact]
    public void Validator_RejectsMismatchesInvalidRangesAndBrokenTrees()
    {
        const string text = "function f() {\n  return 1;\n}";
        Assert.Null(ValidResult(text, "javascript").Validate(text, "typescript"));
        Assert.Null((ValidResult(text, "javascript") with
        {
            Highlights = [new(text.Length - 1, text.Length + 1, CodeMirrorHighlightKind.String)]
        }).Validate(text, "javascript"));
        Assert.Null((ValidResult(text, "javascript") with
        {
            SyntaxNodes = [new(0, text.Length, "Script", -1), new(0, 8, "Function", 0),
                new(2, 4, "Identifier", 0)]
        }).Validate(text, "javascript"));
        Assert.Null((ValidResult(text, "javascript") with
        {
            BracketPairs = [new(text.IndexOf('('), text.IndexOf('}'))]
        }).Validate(text, "javascript"));
        Assert.Null((ValidResult(text, "javascript") with
        {
            Folds = [new(0, text.Length, 1, text.Length, 2, 3)]
        }).Validate(text, "javascript"));
    }

    [Fact]
    public void Validator_MapsParserFoldsAndSymbolsToEditorModels()
    {
        const string text = "function hello() {\n  return 1;\n}";
        var result = ValidResult(text, "javascript") with
        {
            Folds = [new(0, text.Length, 19, text.Length, 1, 3)],
            Symbols = [new("hello", CodeMirrorSymbolKind.Function, 9, 14, 1, 0)]
        };
        var analysis = Assert.IsType<CodeMirrorParserAnalysis>(result.Validate(text, "javascript"));
        var fold = Assert.Single(analysis.ToFoldRegions(text));
        Assert.Equal(19, fold.HiddenRange.Start);
        var symbol = Assert.Single(analysis.ToDocumentSymbols("sample.js", text));
        Assert.Equal(10, symbol.Column);
        Assert.Equal("function", symbol.Kind);
    }

    [Fact]
    public void Validator_AcceptsStrictUnsupportedEnvelope()
    {
        const string text = "plain";
        var result = new CodeMirrorParserResult(2, false, CodeMirrorParserKind.Unsupported,
            "unknown", "unknown", text.Length, [], [], [], [], [], [], [], [],
            new(false, false, false, false, false, false, false));
        var analysis = Assert.IsType<CodeMirrorParserAnalysis>(result.Validate(text, "unknown"));
        Assert.False(analysis.Supported);
    }

    [Fact]
    public void WorkerHost_ExecutesCommittedCodeMirrorBundle()
    {
        var bundlePath = Path.Combine(AppContext.BaseDirectory, "CodeMirrorParserBundle.js");
        var host = new CodeMirrorParserWorkerHost(CodeMirrorParserWorkerHost.ReadBundle(bundlePath), bundlePath);
        const string text = "😀 function demo(value) {\nreturn (value + 1)\n}\n";
        var response = host.Handle(new(2, "parse", text, "javascript", 4, 2, true));
        Assert.Null(response.Error);
        var analysis = Assert.IsType<CodeMirrorParserAnalysis>(response.Result?.Validate(text, "javascript"));
        Assert.True(analysis.Supported);
        Assert.Equal(CodeMirrorParserKind.Lezer, analysis.ParserKind);
        Assert.Contains(analysis.Highlights, value => value.Kind == CodeMirrorHighlightKind.Keyword);
        Assert.NotEmpty(analysis.SyntaxNodes);
        Assert.NotEmpty(analysis.ToFoldRegions(text));
        Assert.Contains(analysis.Symbols, value => value.Label == "demo"
            && value.Kind == CodeMirrorSymbolKind.Function);
    }

    [Fact]
    public void WorkerHost_SeparatesStreamAndUnsupportedLanguages()
    {
        var bundlePath = Path.Combine(AppContext.BaseDirectory, "CodeMirrorParserBundle.js");
        var host = new CodeMirrorParserWorkerHost(CodeMirrorParserWorkerHost.ReadBundle(bundlePath), bundlePath);
        const string text = "class Example {\n  int Value = 1;\n}";
        var streamResponse = host.Handle(new(2, "stream", text, "csharp", 4, 4, true));
        var stream = Assert.IsType<CodeMirrorParserAnalysis>(
            streamResponse.Result?.Validate(text, "csharp"));
        Assert.Equal(CodeMirrorParserKind.Stream, stream.ParserKind);
        Assert.Equal(new CodeMirrorSyntaxNode(0, text.Length, "Document", -1),
            Assert.Single(stream.SyntaxNodes));
        Assert.Empty(stream.Folds);
        Assert.Empty(stream.Symbols);

        var unsupportedResponse = host.Handle(new(2, "unsupported", text, "not-a-language", 4, 4, true));
        var unsupported = Assert.IsType<CodeMirrorParserAnalysis>(
            unsupportedResponse.Result?.Validate(text, "not-a-language"));
        Assert.False(unsupported.Supported);
        Assert.Equal(CodeMirrorParserKind.Unsupported, unsupported.ParserKind);
    }

    [Fact]
    public void WorkerHost_ReturnsExactNewlineIndentationProbe()
    {
        var bundlePath = Path.Combine(AppContext.BaseDirectory, "CodeMirrorParserBundle.js");
        var host = new CodeMirrorParserWorkerHost(CodeMirrorParserWorkerHost.ReadBundle(bundlePath), bundlePath);
        const string text = "if (ready) {";
        var response = host.Handle(new(2, "indent", text, "JavaScript", 4, 2, true, [text.Length]));
        var analysis = Assert.IsType<CodeMirrorParserAnalysis>(
            response.Result?.Validate(text, "JavaScript"));
        var indentation = Assert.Single(analysis.NewlineIndentation);
        Assert.Equal(text.Length, indentation.Position);
        Assert.Equal(2, indentation.Columns);
    }

    [Fact]
    public void Codec_EnforcesRequestBudgetsAndUnknownMembers()
    {
        Assert.Throws<InvalidDataException>(() => CodeMirrorParserCodec.EncodeRequest(new(2, "large",
            new string('x', CodeMirrorParserProtocol.MaximumSourceUtf16Length + 1), "plain", 4, 4, true)));
        Assert.Throws<InvalidDataException>(() => CodeMirrorParserCodec.DecodeRequest(
            "{\"version\":2,\"requestId\":\"x\",\"text\":\"\",\"language\":\"plain\",\"tabWidth\":4,\"indentWidth\":4,\"insertSpaces\":true,\"extra\":1}"));
        Assert.False(CodeMirrorParserProtocol.IsSourceWithinBudget(
            String.Concat(Enumerable.Repeat("x\n", CodeMirrorParserProtocol.MaximumSourceLines))));
    }

    [Fact]
    public void Codec_UsesFrozenSourceUTF16LengthWireName()
    {
        const string text = "x";
        var response = CodeMirrorParserCodec.EncodeResponse(new(2, "request",
            ValidResult(text, "javascript")));
        Assert.Contains("\"sourceUTF16Length\":1", response);
        Assert.DoesNotContain("sourceUtf16Length", response);
    }

    [Fact]
    public void Codec_RoundTripsBoundedNewlineIndentationProbes()
    {
        var request = new CodeMirrorParserRequest(2, "indent", "{}", "JavaScript",
            4, 2, true, [1]);
        var decoded = CodeMirrorParserCodec.DecodeRequest(CodeMirrorParserCodec.EncodeRequest(request));
        Assert.Equal([1], decoded.NewlineIndentationPositions);
        Assert.Throws<InvalidDataException>(() => CodeMirrorParserCodec.EncodeRequest(
            request with { NewlineIndentationPositions = [1, 1] }));
    }

    private static CodeMirrorParserResult ValidResult(string text, string language) => new(
        2, true, CodeMirrorParserKind.Lezer, language, "JavaScript", text.Length, [],
        [new(0, text.Length, "Script", -1)], [], [], [], [], [], [],
        new(false, false, false, false, false, false, false));
}
