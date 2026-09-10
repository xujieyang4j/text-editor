using System.Text.Json;

namespace LumenEditor.Windows.Core.Editing;

public sealed record MacroStep(string Before, string After, TextSelection AfterSelection);
public sealed record RecordedMacro(IReadOnlyList<MacroStep> Steps);

public sealed class MacroRecorder
{
    public const int MaximumSteps = 1_000;
    public const int MaximumTextCharacters = 2_000_000;
    public const long MaximumTotalCharacters = 8L * 1024 * 1024;
    private readonly List<MacroStep> steps = [];
    private long totalCharacters;
    public bool IsRecording { get; private set; }
    public RecordedMacro? LastMacro { get; private set; }

    public bool Start(string currentText)
    {
        if (IsRecording || currentText.Length > MaximumTextCharacters) return false;
        steps.Clear();
        totalCharacters = 0;
        IsRecording = true;
        return true;
    }

    public RecordedMacro Stop()
    {
        IsRecording = false;
        LastMacro = new RecordedMacro(steps.ToList());
        return LastMacro;
    }

    public void Observe(string before, string after, TextSelection afterSelection)
    {
        var added = (long)before.Length + after.Length;
        if (!IsRecording || steps.Count >= MaximumSteps || before == after
            || before.Length > MaximumTextCharacters || after.Length > MaximumTextCharacters) return;
        if (steps.Count > 0 && !StringComparer.Ordinal.Equals(steps[^1].After, before)) return;
        if (added > MaximumTotalCharacters - totalCharacters) return;
        steps.Add(new(before, after, afterSelection));
        totalCharacters += added;
    }

    public bool Replay(EditorBuffer buffer, RecordedMacro? macro = null)
    {
        macro ??= LastMacro;
        if (macro is null || macro.Steps.Count == 0 || macro.Steps.Count > MaximumSteps
            || macro.Steps.Sum(step => (long)step.Before.Length + step.After.Length) > MaximumTotalCharacters) return false;
        var text = buffer.Text;
        var selection = buffer.Selection;
        foreach (var step in macro.Steps)
        {
            if (!StringComparer.Ordinal.Equals(text, step.Before)) return false;
            text = step.After;
            selection = step.AfterSelection;
        }
        return buffer.Apply(text, selection);
    }
}

public sealed class MacroStore(string path)
{
    public async Task SaveAsync(RecordedMacro macro, CancellationToken cancellationToken = default)
    {
        if (macro.Steps.Count > MacroRecorder.MaximumSteps
            || macro.Steps.Any(step => step.Before.Length > MacroRecorder.MaximumTextCharacters
                || step.After.Length > MacroRecorder.MaximumTextCharacters)
            || macro.Steps.Sum(step => (long)step.Before.Length + step.After.Length) > MacroRecorder.MaximumTotalCharacters)
        {
            throw new InvalidOperationException("Macro exceeds the safety limits.");
        }
        var data = JsonSerializer.SerializeToUtf8Bytes(macro);
        var directory = Path.GetDirectoryName(path) ?? throw new InvalidOperationException("Macro path has no directory.");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllBytesAsync(temporary, data, cancellationToken);
            if (File.Exists(path)) File.Replace(temporary, path, null, true);
            else File.Move(temporary, path);
            temporary = String.Empty;
        }
        finally { if (temporary.Length > 0) File.Delete(temporary); }
    }

    public async Task<RecordedMacro?> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MacroRecorder.MaximumTotalCharacters * 3) return null;
            var macro = JsonSerializer.Deserialize<RecordedMacro>(await File.ReadAllBytesAsync(path, cancellationToken));
            if (macro is null || macro.Steps.Count > MacroRecorder.MaximumSteps) return null;
            return macro.Steps.Any(step => step.Before.Length > MacroRecorder.MaximumTextCharacters
                || step.After.Length > MacroRecorder.MaximumTextCharacters)
                || macro.Steps.Sum(step => (long)step.Before.Length + step.After.Length) > MacroRecorder.MaximumTotalCharacters
                    ? null : macro;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
}
