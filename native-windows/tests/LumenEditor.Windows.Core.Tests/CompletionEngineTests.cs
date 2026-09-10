using System.Text.Json;
using LumenEditor.Windows.Core.Language;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class CompletionEngineTests
{
    [Fact]
    public void PrefixAndWorkspaceFallbackAreBoundedAndDeduplicated()
    {
        Assert.Equal(new CompletionPrefix(5, 9, "alph"), CompletionEngine.PrefixAt("call(alph", 9));
        Assert.Equal(new[] { "alphabet", "AlphaBeta" }, CompletionEngine.WordFallback(
            "alph", ["AlphaBeta alphabet alph AlphaBeta ignored"]).Select(value => value.Label));
        Assert.Empty(CompletionEngine.WordFallback("a", ["alpha"]));
    }

    [Fact]
    public void LspCompletionsSupportArraysAndListsAndRejectUnsafeValues()
    {
        using var json = JsonDocument.Parse("""
            {"items":[
              {"label":"alpha","detail":"variable","documentation":{"kind":"markdown","value":"docs"},"insertText":"alpha()"},
              {"label":"alpha"},{"label":"bad\u0001"}
            ]}
            """);
        var completion = Assert.Single(LanguageServerResults.ParseCompletions(json.RootElement));
        Assert.Equal("alpha()", completion.InsertText);
        Assert.Equal("docs", completion.Documentation);
    }
}
