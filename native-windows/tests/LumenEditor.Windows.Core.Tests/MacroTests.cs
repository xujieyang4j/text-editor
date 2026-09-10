using LumenEditor.Windows.Core.Editing;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class MacroTests
{
    [Fact]
    public void Recorder_ReplaysMatchingTransactionAsSingleUndoEntry()
    {
        var recorder = new MacroRecorder();
        Assert.True(recorder.Start("one"));
        recorder.Observe("one", "one two", new TextSelection(7, 7));
        var macro = recorder.Stop();
        var buffer = new EditorBuffer("one");
        Assert.True(recorder.Replay(buffer, macro));
        Assert.Equal("one two", buffer.Text);
        Assert.True(buffer.Undo());
        Assert.Equal("one", buffer.Text);
        Assert.False(recorder.Replay(new EditorBuffer("different"), macro));
    }

    [Fact]
    public async Task MacroStore_RoundTripsBoundedMacro()
    {
        var directory = Path.Combine(Path.GetTempPath(), "LumenMacros", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var store = new MacroStore(Path.Combine(directory, "macro.json"));
            var macro = new RecordedMacro([new MacroStep("a", "ab", new TextSelection(2, 2))]);
            await store.SaveAsync(macro);
            var loaded = Assert.IsType<RecordedMacro>(await store.LoadAsync());
            Assert.Equal("ab", Assert.Single(loaded.Steps).After);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void Recorder_RejectsDiscontinuousSteps()
    {
        var recorder = new MacroRecorder();
        recorder.Start("a");
        recorder.Observe("a", "ab", new TextSelection(2, 2));
        recorder.Observe("wrong", "wrong!", new TextSelection(6, 6));
        var macro = recorder.Stop();
        Assert.Single(macro.Steps);
    }
}
