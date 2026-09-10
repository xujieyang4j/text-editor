using LumenEditor.Windows.Core.Settings;

namespace LumenEditor.Windows.Core.Documents;

public enum AutoSaveAction
{
    None,
    ScheduleAfterDelay,
    SaveNow
}

/// <summary>Pure automatic-save policy shared by the WinUI event adapters and tests.</summary>
public static class AutoSavePolicy
{
    public static AutoSaveAction DocumentChanged(AutoSaveMode mode) => mode == AutoSaveMode.AfterDelay
        ? AutoSaveAction.ScheduleAfterDelay
        : AutoSaveAction.None;

    public static AutoSaveAction WindowFocusLost(AutoSaveMode mode) => mode == AutoSaveMode.OnFocusChange
        ? AutoSaveAction.SaveNow
        : AutoSaveAction.None;

    public static bool IsEligible(OpenedDocument document, bool hasExternalConflict = false) =>
        document.IsDirty
        && !document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)
        && document.EncodingIssue == TextEncodingIssue.None
        && !hasExternalConflict;
}
