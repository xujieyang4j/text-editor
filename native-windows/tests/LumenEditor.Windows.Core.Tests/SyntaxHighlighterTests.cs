using LumenEditor.Windows.Core.Editing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class SyntaxHighlighterTests
{
    [Fact]
    public void Code_HighlightsTokensAndDoesNotParseCommentContents()
    {
        var text = "const string value = \"if 42\"; // return 9\nreturn 12;";
        var plan = SyntaxHighlighter.Plan(text, "csharp");

        Assert.Contains(plan.Spans, span => span.Kind == SyntaxTokenKind.Keyword && text.Substring(span.Start, span.Length) == "const");
        Assert.Contains(plan.Spans, span => span.Kind == SyntaxTokenKind.Type && text.Substring(span.Start, span.Length) == "string");
        Assert.Contains(plan.Spans, span => span.Kind == SyntaxTokenKind.String && text.Substring(span.Start, span.Length) == "\"if 42\"");
        Assert.Contains(plan.Spans, span => span.Kind == SyntaxTokenKind.Comment && text.Substring(span.Start, span.Length).StartsWith("//"));
        Assert.Contains(plan.Spans, span => span.Kind == SyntaxTokenKind.Number && text.Substring(span.Start, span.Length) == "12");
    }

    [Fact]
    public void MarkupAndMarkdown_AreBoundedAndClassified()
    {
        Assert.Contains(SyntaxHighlighter.Plan("<tag name=\"value\">text</tag>", "html").Spans,
            span => span.Kind == SyntaxTokenKind.Markup);
        Assert.Contains(SyntaxHighlighter.Plan("# Heading\n`code`", "markdown").Spans,
            span => span.Kind == SyntaxTokenKind.String);
        var large = SyntaxHighlighter.Plan(new string('x', SyntaxHighlighter.MaximumSourceLength + 1), "csharp");
        Assert.True(large.WasTruncated);
        Assert.True(large.Spans.Count <= SyntaxHighlighter.MaximumSpans);
    }
}
