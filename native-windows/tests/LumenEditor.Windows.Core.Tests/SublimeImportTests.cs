using System.Text;
using System.Text.Json;
using LumenEditor.Windows.Core.Build;
using LumenEditor.Windows.Core.Settings;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class SublimeImportTests
{
    [Fact]
    public void Project_ResolvesExistingRootsAndSkipsShellBuilds()
    {
        var directory = Path.Combine(Path.GetTempPath(), "LumenSublimeProject", Guid.NewGuid().ToString("N"));
        var sourceDirectory = Path.Combine(directory, "config");
        var root = Path.Combine(directory, "workspace");
        Directory.CreateDirectory(sourceDirectory);
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(sourceDirectory, "Sample.sublime-project");
            var bytes = Encoding.UTF8.GetBytes("""
                {"folders":[{"path":"../workspace","folder_exclude_patterns":["node_modules"]}],
                 "build_systems":[{"name":"Safe","cmd":["dotnet","build"]},{"name":"Shell","shell_cmd":"echo bad"}]}
                """);
            var imported = SublimeImport.ParseProject(bytes, path);
            Assert.Equal([root], imported.Roots);
            Assert.Equal(["**/node_modules/**"], imported.Exclusions);
            Assert.Equal("dotnet", Assert.Single(imported.BuildSystems).Command);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void Settings_ImportsSupportedBoundedFields()
    {
        var imported = SublimeImport.ParseSettings(Encoding.UTF8.GetBytes("""
            { // preferences
              "font_size": 99, "tab_size": 2,
              "translate_tabs_to_spaces": false, "word_wrap": true,
              "spell_check": true, "line_numbers": false, "draw_white_space": "all", "mini_map": false,
              "draw_indent_guides": false, "rulers": [80, 100, 80, -1, 2000],
              "auto_save": "after_delay", "auto_save_delay": 10,
              "color_scheme": "Packages/Color Scheme - Default/Breakers.tmTheme",
            }
            """), new EditorSettings());
        Assert.Equal(40, imported.Settings.FontSize);
        Assert.Equal(2, imported.Settings.TabSize);
        Assert.False(imported.Settings.InsertSpaces);
        Assert.True(imported.Settings.WordWrap);
        Assert.True(imported.Settings.SpellCheck);
        Assert.False(imported.Settings.ShowLineNumbers);
        Assert.True(imported.Settings.ShowWhitespace);
        Assert.False(imported.Settings.ShowMinimap);
        Assert.False(imported.Settings.ShowIndentGuides);
        Assert.Equal([80, 100, 80], imported.Settings.Rulers);
        Assert.Equal(AutoSaveMode.AfterDelay, imported.Settings.AutoSave);
        Assert.Equal(250, imported.Settings.AutoSaveDelayMs);
        Assert.Equal(EditorColorScheme.Dark, imported.Settings.ColorScheme);
        Assert.NotEmpty(imported.Changes);
    }

    [Fact]
    public void Snippet_ParsesCdataAndRejectsDoctype()
    {
        var snippet = SublimeImport.ParseSnippet(Encoding.UTF8.GetBytes("""
            <snippet><content><![CDATA[for (item) {$0}]]></content><tabTrigger>loop</tabTrigger><scope>source.cs</scope></snippet>
            """), "Loop.sublime-snippet");
        Assert.Equal("Loop", snippet.Label);
        Assert.Equal("for (item) {$0}", snippet.Text);
        Assert.Equal("loop", snippet.Trigger);
        Assert.Throws<InvalidDataException>(() => SublimeImport.ParseSnippet(
            Encoding.UTF8.GetBytes("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><snippet><content>&e;</content></snippet>"),
            "Unsafe.sublime-snippet"));
    }

    [Fact]
    public void MergeSnippet_PreservesProjectAndMakesSnippetDiscoverable()
    {
        var merged = SublimeImport.MergeSnippet("{\"unknown\":true}", new("Loop", "body", "loop", "source.cs"));
        using var document = JsonDocument.Parse(merged);
        var snippet = Assert.Single(SublimeImport.ParseProjectSnippets(document.RootElement));
        Assert.Equal("body", snippet.Text);
        Assert.True(document.RootElement.GetProperty("unknown").GetBoolean());
    }
}
