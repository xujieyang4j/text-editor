using LumenEditor.Windows.Core.Documents;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class PreviewTests
{
    [Fact]
    public void LanguageDetector_MapsCommonExtensions()
    {
        Assert.Equal(144, LanguageDetector.Languages.Count);
        Assert.Equal("tsx", LanguageDetector.Detect("view.TSX").Id);
        Assert.Equal("TSX", LanguageDetector.Detect("view.TSX").ParserName);
        Assert.Equal("markdown", LanguageDetector.Detect("README.md").Id);
        Assert.Equal("python", LanguageDetector.Detect("BUILD").Id);
        Assert.Equal("dockerfile", LanguageDetector.Detect("Dockerfile").Id);
        Assert.Equal("nginx", LanguageDetector.Detect("NGINX.site.CONF").Id);
        Assert.Equal("plain", LanguageDetector.Detect("LICENSE").Id);
        Assert.Equal("csharp", LanguageDetector.FindByNameOrAlias("C#")?.Id);
        Assert.Equal("javascript", LanguageDetector.FindByNameOrAlias("node")?.Id);
        Assert.True(PreviewRenderer.IsMarkdownFileName("notes.mdx"));
        Assert.True(PreviewRenderer.IsHtmlFileName("page.xhtml"));
    }

    [Fact]
    public void PreviewRenderer_ProducesBoundedMarkdownTextAndJsonTree()
    {
        var fence = new string((char)96, 3);
        Assert.Equal("Heading\nplain bold\n    const x = 1", PreviewRenderer.MarkdownToSafeText(
            "# Heading\nplain **bold**\n" + fence + "js\nconst x = 1\n" + fence));
        var rows = PreviewRenderer.JsonTree("{\"a\":[1,true]}");
        Assert.Equal(["$: {object} (14 chars)", "  a: [array] (2 items)", "    [0]: 1", "    [1]: true"], rows);
        Assert.Empty(PreviewRenderer.JsonTree("{"));
    }

    [Fact]
    public void PreviewRenderer_ProducesStyledScriptFreeMarkdownHtml()
    {
        var html = PreviewRenderer.MarkdownToSafeHtml(
            "# Heading\n\n- one\n- two\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n<script>alert(1)</script>",
            darkTheme: true);
        Assert.Contains("<h1 id=\"heading\">Heading</h1>", html);
        Assert.Contains("<ul>", html);
        Assert.Contains("<table>", html);
        Assert.DoesNotContain("<script>", html, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("default-src 'none'", html);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(html) <= 2 * 1024 * 1024);
    }
}
