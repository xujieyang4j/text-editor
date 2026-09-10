using LumenEditor.Windows.Core.Navigation;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class NavigationTests
{
    [Fact]
    public void LineColumnConversion_ClampsAndDoesNotSplitSurrogatePairs()
    {
        const string text = "one\n😀two\nlast";
        Assert.Equal(4, TextNavigation.LineColumnToOffset(text, 2, 1));
        Assert.Equal(4, TextNavigation.LineColumnToOffset(text, 2, 2));
        Assert.Equal(9, TextNavigation.LineColumnToOffset(text, 2, 99));
        Assert.Equal(text.Length, TextNavigation.LineColumnToOffset(text, 99, 1));
        Assert.Equal((2, 3), TextNavigation.OffsetToLineColumn(text, 6));
    }
}
