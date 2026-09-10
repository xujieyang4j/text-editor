using System.Text;
using System.Text.Json;
using LumenEditor.Windows.Core.Build;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class ProjectKeyBindingTests
{
    [Fact]
    public void SublimeKeymap_ImportsSupportedSingleStepRulesAndCountsSkips()
    {
        var imported = ProjectKeyBindings.ParseSublime(Encoding.UTF8.GetBytes("""
            [
              {"keys":["ctrl+alt+s"],"command":"save"},
              {"keys":["ctrl+k","ctrl+s"],"command":"save"},
              {"keys":["ctrl+b"],"command":"unknown"},
              {"keys":["ctrl+g"],"command":"goto_line","args":{"line":2}},
            ]
            """));
        var binding = Assert.Single(imported.Bindings);
        Assert.Equal("Ctrl+Alt+S", binding.Display);
        Assert.Equal("save", binding.CommandId);
        Assert.Equal(3, imported.Skipped);
    }

    [Fact]
    public void ProjectBindings_ParseAndMergeLastBindingForSameKey()
    {
        var first = new ProjectKeyBinding("save", "S", Control: true);
        var merged = ProjectKeyBindings.Merge(
            "{\"unknown\":true,\"keyBindingRules\":[{\"keys\":\"Ctrl+S\",\"command\":\"save-as\"}]}", [first]);
        using var document = JsonDocument.Parse(merged);
        var binding = Assert.Single(ProjectKeyBindings.ParseProject(document.RootElement));
        Assert.Equal(first, binding);
        Assert.True(document.RootElement.GetProperty("unknown").GetBoolean());
    }

    [Theory]
    [InlineData("ctrl+shift+f3", "find-next", "Ctrl+Shift+F3")]
    [InlineData("super+alt+left", "navigate-back", "Ctrl+Alt+Left")]
    public void Parser_NormalizesSupportedKeys(string raw, string command, string expected)
    {
        Assert.True(ProjectKeyBindings.TryParse(raw, command, out var binding));
        Assert.Equal(expected, binding.Display);
    }
}
