using LumenEditor.Windows.Core.Editing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class DocumentTransformTests
{
    [Fact]
    public void Json_FormatAndCompactRemainValid()
    {
        const string source = "{\"count\":9007199254740993,\"items\":[true,null]}";
        var formatted = Assert.IsType<string>(DocumentTransforms.FormatJson(source, compact: false));
        Assert.Contains("9007199254740993", formatted);
        Assert.EndsWith("\n", formatted);
        Assert.Equal(source, DocumentTransforms.FormatJson(formatted, compact: true));
        Assert.Null(DocumentTransforms.FormatJson("{", compact: false));
    }

    [Fact]
    public void Statistics_CountsUnicodeTextWithoutSplittingWords()
    {
        var result = DocumentTransforms.Statistics("hello 世界\nnext_value 😀");
        Assert.Equal(2, result.Lines);
        Assert.Equal(3, result.Words);
        Assert.Equal(18, result.NonWhitespaceCharacters);
        Assert.Equal(22, result.Utf16Characters);
    }
}
