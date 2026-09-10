using LumenEditor.Windows.Core.Localization;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class LocalizationTests
{
    [Theory]
    [InlineData("zh-CN", "Save", "保存")]
    [InlineData("en-US", "保存", "Save")]
    [InlineData("zh-CN", "Document preview", "文档预览")]
    public void UiText_TranslatesInBothDirections(string locale, string source, string expected) =>
        Assert.Equal(expected, WindowsLocalization.Text(locale, source));

    [Fact]
    public void CommandTitles_LocalizeKnownCommandsAndHumanizeFallbacks()
    {
        Assert.Equal("保存", WindowsLocalization.CommandTitle("zh-CN", "save"));
        Assert.Equal("将所选标签拆分到分组", WindowsLocalization.CommandTitle("zh-CN", "split-selected-tabs"));
        Assert.Equal("Save As", WindowsLocalization.CommandTitle("en-US", "save-as"));
        Assert.Equal("Unknown Command", WindowsLocalization.CommandTitle("en-US", "unknown-command"));
    }
}
