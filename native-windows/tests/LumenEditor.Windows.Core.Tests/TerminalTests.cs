using LumenEditor.Windows.Core.Terminal;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class TerminalTests
{
    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("two words", "\"two words\"")]
    [InlineData("a\\", "a\\")]
    [InlineData("a\\\"b", "\"a\\\\\\\"b\"")]
    [InlineData("", "\"\"")]
    public void CommandLine_QuotesWindowsArguments(string input, string expected)
    {
        Assert.Equal(expected, WindowsCommandLine.Quote(input));
    }

    [Fact]
    public void CommandLine_BuildsExecutableAndArgumentsWithoutShellSyntax()
    {
        Assert.Equal("cmd.exe /D /Q", WindowsCommandLine.Create("cmd.exe", ["/D", "/Q"]));
        Assert.Equal("\"C:\\Program Files\\tool.exe\" \"two words\"", WindowsCommandLine.Create(
            "C:\\Program Files\\tool.exe", ["two words"]));
    }
}
