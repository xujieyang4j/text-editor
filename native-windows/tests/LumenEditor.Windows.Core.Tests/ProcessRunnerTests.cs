using LumenEditor.Windows.Core.Processes;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class ProcessRunnerTests
{
    [Fact]
    public async Task Runner_PassesArgumentsWithoutShellInterpretation()
    {
        if (OperatingSystem.IsWindows()) return;
        var runner = new BoundedProcessRunner();
        var result = await runner.RunAsync(new ProcessRequest(
            "/usr/bin/printf", ["%s", "hello; echo unsafe"], Path.GetTempPath()));

        Assert.True(result.Started, result.Error);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal("hello; echo unsafe", result.StandardOutput);
    }

    [Fact]
    public async Task Runner_BoundsOutput()
    {
        if (OperatingSystem.IsWindows()) return;
        var runner = new BoundedProcessRunner();
        var result = await runner.RunAsync(new ProcessRequest(
            "/usr/bin/printf", ["%02048d", 0.ToString()], Path.GetTempPath(), MaximumOutputCharacters: 1_024));

        Assert.True(result.WasTruncated);
        Assert.Equal(1_024, result.StandardOutput.Length);
    }

    [Fact]
    public async Task Runner_WritesBoundedStandardInputWithoutShell()
    {
        if (OperatingSystem.IsWindows()) return;
        var runner = new BoundedProcessRunner();
        var result = await runner.RunAsync(new ProcessRequest(
            "/bin/sh", ["-c", "read value; printf %s \"$value\""], Path.GetTempPath(),
            StandardInput: "hello; still-data\n"));

        Assert.True(result.Started, result.Error);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal("hello; still-data", result.StandardOutput);
    }
}
