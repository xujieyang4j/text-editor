using System.Text.Json;
using LumenEditor.Windows.Core.Updates;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class UpdateTests
{
    [Fact]
    public void Parse_RequiresNewerVersionApprovedReleaseAndArchitectureAsset()
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            tag_name = "v1.2.0",
            html_url = "https://github.com/xujieyang4j/text-editor/releases/tag/v1.2.0",
            draft = false,
            prerelease = false,
            assets = new[] { new { name = "text-editor-xujieyang-1.2.0-native-windows-x64.msix" } }
        });
        var update = UpdateService.Parse(payload, "1.1.9", "x64");
        Assert.True(update.IsAvailable);
        Assert.Equal("1.2.0", update.LatestVersion);
        Assert.NotNull(update.ReleaseUri);

        Assert.False(UpdateService.Parse(payload, "1.2.0", "x64").IsAvailable);
        Assert.False(UpdateService.Parse(payload, "1.1.9", "arm64").IsAvailable);
    }

    [Theory]
    [InlineData("1.10.0", "1.9.9", 1)]
    [InlineData("1.0.0", "1.0.0-beta", 1)]
    [InlineData("1.0.0-beta", "1.0.0", -1)]
    [InlineData("1.0", "1.0.0", 0)]
    public void CompareVersions_IsNumericAndPrereleaseAware(string left, string right, int expected)
    {
        Assert.Equal(expected, Math.Sign(UpdateService.CompareVersions(left, right)));
    }

    [Fact]
    public void ReleaseUrl_RejectsWrongHostsAndCredentials()
    {
        Assert.True(UpdateService.IsApprovedReleaseUri(
            new Uri("https://github.com/xujieyang4j/text-editor/releases/tag/v1")));
        Assert.False(UpdateService.IsApprovedReleaseUri(
            new Uri("https://example.com/xujieyang4j/text-editor/releases/tag/v1")));
        Assert.False(UpdateService.IsApprovedReleaseUri(
            new Uri("https://user:password@github.com/xujieyang4j/text-editor/releases/tag/v1")));
    }
}
