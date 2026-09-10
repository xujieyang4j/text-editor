using LumenEditor.Windows.Core.Build;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class BuildSystemTests
{
    [Fact]
    public void ConfiguredCommand_ParsesQuotedArgumentsWithoutAShell()
    {
        var root = Path.GetTempPath();
        var system = Assert.IsType<DetectedBuildSystem>(BuildSystemDetector.FromCommand(
            root, "dotnet build \"project with spaces.csproj\" --no-restore"));
        Assert.Equal("dotnet", system.Executable);
        Assert.Equal(["build", "project with spaces.csproj", "--no-restore"], system.Arguments);
        Assert.Null(BuildSystemDetector.FromCommand(root, "dotnet \"unterminated"));
    }

    [Fact]
    public void Detector_OnlyAddsDeclaredPackageBuildAndProjectMarkers()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenBuild", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "package.json"), "{\"scripts\":{\"test\":\"echo no\"}}");
            Assert.Empty(BuildSystemDetector.Detect(root));

            File.WriteAllText(Path.Combine(root, "package.json"), "{\"scripts\":{\"build\":\"vite build\"}}");
            File.WriteAllText(Path.Combine(root, "app.csproj"), "<Project />");
            var detected = BuildSystemDetector.Detect(root);

            Assert.Equal(["npm-build", "dotnet-project"], detected.Select(system => system.Id));
            Assert.All(detected, system => Assert.Equal(root, system.WorkingDirectory));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
