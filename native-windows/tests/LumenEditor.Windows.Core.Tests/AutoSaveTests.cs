using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Settings;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class AutoSaveTests
{
    [Theory]
    [InlineData(AutoSaveMode.Off, AutoSaveAction.None)]
    [InlineData(AutoSaveMode.AfterDelay, AutoSaveAction.ScheduleAfterDelay)]
    [InlineData(AutoSaveMode.OnFocusChange, AutoSaveAction.None)]
    public void DocumentChange_SelectsExpectedAction(AutoSaveMode mode, AutoSaveAction expected) =>
        Assert.Equal(expected, AutoSavePolicy.DocumentChanged(mode));

    [Theory]
    [InlineData(AutoSaveMode.Off, AutoSaveAction.None)]
    [InlineData(AutoSaveMode.AfterDelay, AutoSaveAction.None)]
    [InlineData(AutoSaveMode.OnFocusChange, AutoSaveAction.SaveNow)]
    public void FocusLoss_SelectsExpectedAction(AutoSaveMode mode, AutoSaveAction expected) =>
        Assert.Equal(expected, AutoSavePolicy.WindowFocusLost(mode));

    [Fact]
    public void Eligibility_RejectsUntitledCleanEncodingIssueAndConflict()
    {
        var eligible = new OpenedDocument("C:\\file.txt", "file.txt", "changed", 7, IsDirty: true);
        Assert.True(AutoSavePolicy.IsEligible(eligible));
        Assert.False(AutoSavePolicy.IsEligible(eligible with { Path = "untitled://one" }));
        Assert.False(AutoSavePolicy.IsEligible(eligible with { IsDirty = false }));
        Assert.False(AutoSavePolicy.IsEligible(eligible with { EncodingIssue = TextEncodingIssue.InvalidBytes }));
        Assert.False(AutoSavePolicy.IsEligible(eligible, hasExternalConflict: true));
    }

    [Fact]
    public async Task SettingsStore_RoundTripsElectronCompatibleAutoSaveValues()
    {
        var directory = Path.Combine(Path.GetTempPath(), "LumenWindowsAutoSaveTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "settings.json");
            var store = new SettingsStore(path);
            await store.SaveAsync(new EditorSettings(AutoSave: AutoSaveMode.AfterDelay, AutoSaveDelayMs: 1234));
            var json = await File.ReadAllTextAsync(path);
            Assert.Contains("\"autoSave\": \"after_delay\"", json);
            var loaded = await store.LoadAsync();
            Assert.Equal(AutoSaveMode.AfterDelay, loaded.AutoSave);
            Assert.Equal(1234, loaded.AutoSaveDelayMs);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void Settings_BoundsAutoSaveDelayAndUnknownMode()
    {
        Assert.Equal(250, EditorSettings.Sanitize(new EditorSettings(AutoSaveDelayMs: 1)).AutoSaveDelayMs);
        Assert.Equal(60_000, EditorSettings.Sanitize(new EditorSettings(AutoSaveDelayMs: 99_999)).AutoSaveDelayMs);
        Assert.Equal(AutoSaveMode.Off, EditorSettings.Sanitize(
            new EditorSettings(AutoSave: (AutoSaveMode)99)).AutoSave);
    }
}
