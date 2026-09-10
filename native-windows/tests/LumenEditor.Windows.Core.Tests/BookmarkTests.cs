using LumenEditor.Windows.Core.Navigation;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class BookmarkTests
{
    [Fact]
    public void Bookmarks_ToggleWrapAndRestoreWithinBounds()
    {
        var bookmarks = new BookmarkSet();
        Assert.True(bookmarks.Toggle(2));
        Assert.True(bookmarks.Toggle(8));
        Assert.Equal(8, bookmarks.Next(2));
        Assert.Equal(2, bookmarks.Next(8));
        Assert.Equal(8, bookmarks.Next(2, reverse: true));
        Assert.False(bookmarks.Toggle(2));
        Assert.Equal([8], bookmarks.Lines);

        bookmarks.Restore([0, 2, 20, 2], maximumLine: 10);
        Assert.Equal([2], bookmarks.Lines);
    }
}
