using LumenEditor.Windows.Core.Build;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class ProjectSettingsTests
{
    [Fact]
    public void BuildSystems_PreserveUnknownFieldsAndRejectShellEntries()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenProject", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        try
        {
            var project = ProjectBuildSettings.ParseProject("""
                {
                  "unknown": { "keep": true },
                  "buildSystems": [
                    { "name": "Safe", "command": "dotnet", "args": ["build"], "workingDirectory": "${project_path}/src" },
                    { "name": "Shell", "command": "echo unsafe", "shell": true }
                  ]
                }
                """);
            var system = Assert.Single(ProjectBuildSettings.ParseBuildSystems(root, project));
            Assert.Equal("dotnet", system.Executable);
            Assert.Equal(["build"], system.Arguments);
            Assert.Equal(Path.Combine(root, "src"), system.WorkingDirectory);
            Assert.Contains("unknown", ProjectBuildSettings.Serialize(project));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void SublimeBuild_ImportsCmdButRejectsShellCmd()
    {
        var imported = ProjectBuildSettings.ParseSublimeBuild(
            "{\"cmd\":[\"dotnet\",\"test\"],\"name\":\"Tests\"}"u8,
            "Tests.sublime-build");
        Assert.Equal("dotnet", imported.Command);
        Assert.Equal(["test"], imported.Arguments);
        Assert.Throws<InvalidDataException>(() => ProjectBuildSettings.ParseSublimeBuild(
            "{\"shell_cmd\":\"rm -rf .\"}"u8, "Unsafe.sublime-build"));
    }

    [Fact]
    public async Task Store_UsesRevisionPinnedAtomicWrites()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenProjectStore", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new ProjectSettingsStore(root);
            var initial = await store.LoadAsync();
            var first = await store.SaveAsync("{\"buildSystems\":[]}", initial.Revision);
            Assert.True(first.Saved);
            await File.WriteAllTextAsync(Path.Combine(root, ProjectSettingsStore.FileName), "{\"external\":true}");
            var conflict = await store.SaveAsync("{}", first.Revision);
            Assert.False(conflict.Saved);
            Assert.Equal(LumenEditor.Windows.Core.Documents.FileWriteFailure.RevisionConflict, conflict.Failure);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void MergeBuildSystem_ReplacesSameNameAndKeepsOtherProjectData()
    {
        var merged = ProjectBuildSettings.MergeBuildSystem(
            "{\"unknown\":1,\"buildSystems\":[{\"name\":\"Build\",\"command\":\"old\"}]}",
            new("Build", "dotnet", ["build"]));
        var project = ProjectBuildSettings.ParseProject(merged);
        Assert.Equal(1, project["unknown"]!.GetValue<int>());
        var systems = Assert.IsType<System.Text.Json.Nodes.JsonArray>(project["buildSystems"]);
        Assert.Single(systems);
        Assert.Equal("dotnet", systems[0]!["command"]!.GetValue<string>());
    }

    [Fact]
    public async Task Store_LoadsBoundedNormalizedProjectExclusions()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenProjectExclude", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, ProjectSettingsStore.FileName),
                "{\"exclude\":[\"./build/**\",\"**/*.tmp\",\"build/**\",\"../outside/**\",42]}");

            var snapshot = await new ProjectSettingsStore(root).LoadAsync();

            Assert.Equal(["build/**", "**/*.tmp"], snapshot.Exclusions);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void PluginsAndPermissions_AreTypedBoundedAndMergeWithoutLosingProjectData()
    {
        var project = ProjectBuildSettings.ParseProject("{\"unknown\":true,\"plugins\":[\"safe\",\"../bad\",\"safe\"],\"pluginPermissions\":{\"safe\":[\"document-read\",\"unknown\"]}}");
        Assert.Equal(["safe"], ProjectBuildSettings.ParsePluginIds(project));
        Assert.Equal([LumenEditor.Windows.Core.Plugins.PluginPermission.DocumentRead],
            ProjectBuildSettings.ParsePluginPermissions(project)["safe"]);
        var merged = ProjectBuildSettings.MergePluginPermissions(project.ToJsonString(), "safe",
            [LumenEditor.Windows.Core.Plugins.PluginPermission.DocumentRead, LumenEditor.Windows.Core.Plugins.PluginPermission.DocumentEdit]);
        Assert.Contains("unknown", merged);
        Assert.Contains("document-edit", merged);
        var enabled = ProjectBuildSettings.EnablePlugin(merged, "safe");
        Assert.Equal(["safe"], ProjectBuildSettings.ParsePluginIds(ProjectBuildSettings.ParseProject(enabled)));
    }
}
