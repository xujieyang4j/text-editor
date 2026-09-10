using LumenEditor.Windows.Core.Git;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class GitServiceTests
{
    [Theory]
    [InlineData("UU", true)]
    [InlineData("AA", true)]
    [InlineData("DD", true)]
    [InlineData(" M", false)]
    [InlineData("M ", false)]
    public void FileStatus_DetectsMergeConflicts(string status, bool expected)
    {
        Assert.Equal(expected, new GitFileStatus("file.txt", status[0].ToString(), status[1].ToString()).HasConflict);
    }

    [Fact]
    public void StatusParser_HandlesBranchRenameAndUntrackedEntries()
    {
        var result = GitService.ParseStatus("# branch.oid abc\0# branch.head feature\0"
            + "# branch.upstream origin/feature\0# branch.ab +2 -3\0"
            + "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\0old.txt\0"
            + "1 .M N... 100644 100644 100644 aaa bbb src/app.cs\0? notes.txt\0");

        Assert.True(result.Succeeded);
        Assert.Equal("feature", result.Branch);
        Assert.Equal("origin/feature", result.Upstream);
        Assert.Equal(2, result.Ahead);
        Assert.Equal(3, result.Behind);
        Assert.Collection(result.Files,
            file => Assert.Equal(new GitFileStatus("new.txt", "R", " "), file),
            file => Assert.Equal(new GitFileStatus("src/app.cs", " ", "M"), file),
            file => Assert.Equal(new GitFileStatus("notes.txt", "?", "?"), file));
    }

    [Fact]
    public void RemoteParser_RemovesCredentialsAndQuerySecrets()
    {
        var remotes = GitService.ParseRemotes(
            "remote.origin.url https://token:secret@example.com/org/repo.git?auth=x#fragment\n"
            + "remote.origin.pushurl git@example.com:org/repo.git\n");
        var remote = Assert.Single(remotes);
        Assert.DoesNotContain("token", remote.FetchUrl);
        Assert.DoesNotContain("secret", remote.FetchUrl);
        Assert.DoesNotContain("auth", remote.FetchUrl);
        Assert.Equal("example.com:org/repo.git", remote.PushUrl);
    }

    [Fact]
    public void HunkParser_PreservesHeadersAndBoundsIndividualPatches()
    {
        var diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n"
            + "@@ -1 +1 @@\n-old\n+new\n@@ -4,0 +5 @@\n+added\n";
        var hunks = GitService.ParseHunks("a.txt", diff);

        Assert.Equal(2, hunks.Count);
        Assert.Equal("@@ -1 +1 @@", hunks[0].Header);
        Assert.Contains("diff --git a/a.txt b/a.txt", hunks[1].Patch);
        Assert.Contains("+added", hunks[1].Patch);
    }

    [Fact]
    public void HistoryParser_IsBoundedAndSkipsIncompleteRecords()
    {
        var history = GitService.ParseHistory(
            "full-id\0abc123\0Author\02026-09-04T10:00:00Z\0Subject\0incomplete\0");
        var entry = Assert.Single(history);
        Assert.Equal("full-id", entry.Id);
        Assert.Equal("abc123", entry.ShortId);
        Assert.Equal("Subject", entry.Subject);
    }

    [Fact]
    public async Task Service_ExercisesRepositoryActionsWithoutShellInterpolation()
    {
        var root = Path.Combine(Path.GetTempPath(), "LumenGit", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var runner = new LumenEditor.Windows.Core.Processes.BoundedProcessRunner();
            async Task Run(params string[] arguments)
            {
                var result = await runner.RunAsync(new("git", ["-C", root, .. arguments], root));
                Assert.True(result.Started && result.ExitCode == 0, result.Error ?? result.StandardError);
            }
            await Run("init");
            await Run("config", "user.email", "tests@example.invalid");
            await Run("config", "user.name", "Lumen Tests");
            var path = Path.Combine(root, "file.txt");
            await File.WriteAllTextAsync(path, "one\ntwo\n");
            await Run("add", "--", "file.txt");
            await Run("commit", "-m", "initial");
            await File.WriteAllTextAsync(path, "one\nTWO\nthree\n");

            var service = new GitService(runner);
            Assert.Contains((await service.StatusAsync(root)).Files, file => file.Path == "file.txt");
            var hunk = Assert.Single(await service.HunksAsync(root, "file.txt"));
            Assert.True((await service.ApplyHunkAsync(root, "file.txt", hunk.Patch, stage: true)).ExitCode == 0);
            Assert.True((await service.UnstageAsync(root, ["file.txt"])).ExitCode == 0);
            Assert.True((await service.DiscardAsync(root, ["file.txt"])).ExitCode == 0);
            Assert.Equal("one\ntwo\n", await File.ReadAllTextAsync(path));
            Assert.Single(await service.HistoryAsync(root, "file.txt"));
            Assert.Contains("Lumen Tests", (await service.BlameAsync(root, "file.txt")).StandardOutput);
            Assert.True((await service.SwitchBranchAsync(root, "feature/test", create: true)).ExitCode == 0);
            Assert.Equal("feature/test", (await service.StatusAsync(root)).Branch);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
