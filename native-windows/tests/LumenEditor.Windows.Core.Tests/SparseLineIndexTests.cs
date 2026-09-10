using LumenEditor.Windows.Core.Editing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class SparseLineIndexTests
{
    [Fact]
    public void Index_MapsOffsetsAndEnumeratesTrailingEmptyLine()
    {
        var index = new SparseLineIndex("alpha\nβeta\n");

        Assert.Equal(3, index.LineCount);
        Assert.Equal(0, index.LineAtOffset(0));
        Assert.Equal(1, index.LineAtOffset(6));
        Assert.Equal(2, index.LineAtOffset(11));
        Assert.Equal(6, index.StartOffset(1));
        Assert.Equal(11, index.StartOffset(2));
        Assert.Equal(
            [new IndexedLine(2, 6), new IndexedLine(3, 11)],
            index.LinesFrom(1, 10));
    }

    [Fact]
    public void Index_UsesSparseAnchorsAcrossLargeDocumentsAndClampsInputs()
    {
        var text = String.Join('\n', Enumerable.Range(0, 800).Select(value => value.ToString()));
        var index = new SparseLineIndex(text);
        var line700 = index.StartOffset(699);

        Assert.Equal(800, index.LineCount);
        Assert.Equal(699, index.LineAtOffset(line700));
        Assert.Equal(799, index.LineAtOffset(Int32.MaxValue));
        Assert.Equal(0, index.StartOffset(-1));
        Assert.Equal(800, Assert.Single(index.LinesFrom(799, 20)).Number);
        Assert.Empty(index.LinesFrom(0, 0));
    }

    [Fact]
    public void Index_EnumeratesWhitespaceWithinHardBudgets()
    {
        var index = new SparseLineIndex("a b\n\tc  d\nignored space");

        Assert.Equal(
            [new IndexedWhitespace(1, false), new IndexedWhitespace(4, true),
             new IndexedWhitespace(6, false), new IndexedWhitespace(7, false)],
            index.WhitespaceFrom(0, maximumLines: 2));
        Assert.Single(index.WhitespaceFrom(0, maximumMarkers: 1));
        Assert.Empty(index.WhitespaceFrom(0, maximumCharacters: 1));
    }

    [Fact]
    public void Index_MinimapSamplesEntireDocumentWithinBudget()
    {
        var text = String.Join('\n', Enumerable.Range(1, 1_000).Select(value =>
            value % 2 == 0 ? $"    line {value}  " : $"line {value}"));
        var samples = new SparseLineIndex(text).MinimapSamples(100);

        Assert.Equal(100, samples.Count);
        Assert.Equal(1, samples[0].Number);
        Assert.Equal(1_000, samples[^1].Number);
        Assert.Contains(samples, sample => sample.IndentColumns == 4);
        Assert.All(samples, sample => Assert.InRange(sample.VisibleColumns, 0, 200));
    }

    [Fact]
    public void Index_ProvidesBoundedIndentAndTrailingWhitespaceDetails()
    {
        var index = new SparseLineIndex("\talpha  \n    beta\nplain");
        var lines = index.LineDetailsFrom(0, maximumLines: 2, tabWidth: 2);

        Assert.Equal(2, lines.Count);
        Assert.Equal(2, lines[0].IndentColumns);
        Assert.Equal(6, lines[0].TrailingWhitespaceStart);
        Assert.Equal(8, lines[0].ContentEndOffset);
        Assert.Equal(4, lines[1].IndentColumns);
        Assert.Single(index.LineDetailsFrom(0, maximumLines: 50, maximumCharacters: 1));
    }
}
