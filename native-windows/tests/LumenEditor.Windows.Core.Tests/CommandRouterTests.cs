using LumenEditor.Windows.Core;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class CommandRouterTests
{
    [Fact]
    public async Task Router_RegistersKnownCommandsAndReportsUnsupportedOnes()
    {
        var router = new WindowsCommandRouter();
        Assert.True(router.Register("new-file", _ => Task.FromResult(CommandExecutionResult.Executed)));
        Assert.False(router.Register("not-a-command", _ => Task.FromResult(CommandExecutionResult.Executed)));
        Assert.True(router.IsRegistered("new-file"));
        Assert.Equal(CommandExecutionState.Executed, (await router.ExecuteAsync("new-file")).State);
        Assert.Equal(CommandExecutionState.Unsupported, (await router.ExecuteAsync("build")).State);
        Assert.Equal(CommandExecutionState.Unsupported, (await router.ExecuteAsync("not-a-command")).State);
    }
}
