using LumenEditor.Windows.Core.Editing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class CodeFoldingTests
{
    [Fact]
    public void Analyzer_FindsNestedBracesAndIgnoresStringsAndComments()
    {
        var text = "if (ready) {\n  call(\"}\"); // {\n  if (nested) {\n    work();\n  }\n}";
        var regions = CodeFoldAnalyzer.Analyze(text, "csharp");

        Assert.Equal(2, regions.Count);
        Assert.Equal((1, 6), (regions[0].StartLine, regions[0].EndLine));
        Assert.Equal((3, 5), (regions[1].StartLine, regions[1].EndLine));
        Assert.StartsWith("  call", text[regions[0].HiddenRange.Start..regions[0].HiddenRange.End]);
    }

    [Fact]
    public void Analyzer_FindsIndentationAndMarkdownRegions()
    {
        var python = CodeFoldAnalyzer.Analyze("def run():\n    if ready:\n        work()\nnext()", "python");
        Assert.Equal(2, python.Count);
        var markdown = CodeFoldAnalyzer.Analyze("# One\nbody\n## Child\nmore\n# Two\nlast", "markdown");
        Assert.Contains(markdown, region => region.StartLine == 1 && region.EndLine == 4);
        Assert.Contains(markdown, region => region.StartLine == 3 && region.EndLine == 4);
    }

    [Fact]
    public void FoldingState_FoldsSmallestCurrentRegionAndUnfoldsAll()
    {
        var regions = CodeFoldAnalyzer.Analyze("outer {\n inner {\n  x\n }\n}", "javascript");
        var state = new CodeFoldingState();
        state.Update(regions);

        Assert.True(state.FoldCurrent(18));
        Assert.Equal(2, Assert.Single(state.FoldedRegions).StartLine);
        Assert.True(state.FoldAll());
        Assert.Equal(2, state.FoldedRegions.Count);
        Assert.Single(state.HiddenRanges);
        Assert.True(state.UnfoldCurrent(18));
        Assert.Single(state.FoldedRegions);
        Assert.True(state.UnfoldAll());
        Assert.Empty(state.FoldedRegions);
    }

    [Fact]
    public void FoldingState_UnfoldsNestedRegionsOneLayerAtATimeForNavigationReveal()
    {
        var regions = CodeFoldAnalyzer.Analyze("outer {\n inner {\n  x\n }\n}", "javascript");
        var state = new CodeFoldingState();
        state.Update(regions);
        Assert.True(state.FoldAll());
        var offset = 18;

        Assert.True(state.UnfoldCurrent(offset));
        Assert.Single(state.FoldedRegions);
        Assert.True(state.UnfoldCurrent(offset));
        Assert.Empty(state.HiddenRanges);
    }

    [Fact]
    public void FoldingState_TogglesVisibleGutterRegionByStartLine()
    {
        var state = new CodeFoldingState();
        state.Update([new(2, 4, new(4, 14), new(8, 14))]);
        Assert.True(state.ToggleAtStartLine(2));
        Assert.True(state.IsFolded(Assert.Single(state.Regions)));
        Assert.True(state.ToggleAtStartLine(2));
        Assert.Empty(state.FoldedRegions);
        Assert.False(state.ToggleAtStartLine(3));
    }
}
