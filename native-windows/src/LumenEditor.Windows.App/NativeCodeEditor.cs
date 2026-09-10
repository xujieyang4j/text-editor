using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using LumenEditor.Windows.Core.Settings;

namespace LumenEditor.Windows.App;

/// <summary>
/// Plain-text adapter over the native RichEditBox. It keeps the existing
/// UTF-16 editor contract while exposing TOM hidden ranges for code folding.
/// </summary>
public sealed class NativeCodeEditor : RichEditBox
{
    private string cachedText = String.Empty;
    private IReadOnlyList<Core.Editing.TextSelection> appliedHiddenRanges = [];
    private IReadOnlyList<Core.Editing.SyntaxTokenSpan> appliedSyntaxSpans = [];
    private EditorColorScheme? appliedSyntaxColorScheme;

    public NativeCodeEditor()
    {
        DisabledFormattingAccelerators = DisabledFormattingAccelerators.All;
    }

    public string Text
    {
        get
        {
            Document.GetText(TextGetOptions.UseLf, out var value);
            cachedText = value ?? String.Empty;
            return cachedText;
        }
        set
        {
            value ??= String.Empty;
            if (StringComparer.Ordinal.Equals(cachedText, value)) return;
            Document.SetText(TextSetOptions.Unhide, value);
            cachedText = value;
            appliedHiddenRanges = [];
            appliedSyntaxSpans = [];
            appliedSyntaxColorScheme = null;
        }
    }

    public int SelectionStart => Math.Min(Document.Selection.StartPosition, Document.Selection.EndPosition);
    public int SelectionLength => Math.Abs(Document.Selection.EndPosition - Document.Selection.StartPosition);

    public void Select(int start, int length)
    {
        var textLength = Math.Max(0, Document.Selection.StoryLength - 1);
        start = Math.Clamp(start, 0, textLength);
        length = Math.Clamp(length, 0, textLength - start);
        Document.Selection.SetRange(start, start + length);
    }

    public global::Windows.Foundation.Rect GetRectFromCharacterIndex(int offset, bool trailingEdge)
    {
        var length = Math.Max(0, Document.Selection.StoryLength - 1);
        offset = Math.Clamp(offset, 0, length);
        var end = Math.Min(length, offset + 1);
        var range = Document.GetRange(offset, end);
        range.GetRect(PointOptions.ClientCoordinates | PointOptions.AllowOffClient, out var rect, out _);
        return trailingEdge
            ? new global::Windows.Foundation.Rect(rect.X + rect.Width, rect.Y, 0, rect.Height)
            : new global::Windows.Foundation.Rect(rect.X, rect.Y, 0, rect.Height);
    }

    public void ApplyHiddenRanges(IEnumerable<Core.Editing.TextSelection> ranges, int textLength)
    {
        var requested = ranges.ToList();
        if (requested.SequenceEqual(appliedHiddenRanges)) return;
        textLength = Math.Clamp(textLength, 0, Math.Max(0, Document.Selection.StoryLength - 1));
        Document.BatchDisplayUpdates();
        try
        {
            if (appliedHiddenRanges.Count > 0)
            {
                Document.GetRange(0, textLength).CharacterFormat.Hidden = FormatEffect.Off;
            }
            foreach (var range in requested)
            {
                var start = Math.Clamp(range.Start, 0, textLength);
                var end = Math.Clamp(range.End, start, textLength);
                if (end > start) Document.GetRange(start, end).CharacterFormat.Hidden = FormatEffect.On;
            }
        }
        finally
        {
            Document.ApplyDisplayUpdates();
        }
        appliedHiddenRanges = requested;
    }

    public void RefreshTextCache()
    {
        Document.GetText(TextGetOptions.UseLf, out var value);
        cachedText = value ?? String.Empty;
        appliedSyntaxSpans = [];
        appliedSyntaxColorScheme = null;
    }

    public void ApplySyntaxHighlighting(
        Core.Editing.SyntaxHighlightPlan plan, EditorColorScheme colorScheme, int textLength)
    {
        var spans = plan.Spans;
        if (colorScheme == appliedSyntaxColorScheme && spans.SequenceEqual(appliedSyntaxSpans)) return;
        textLength = Math.Clamp(textLength, 0, Math.Max(0, Document.Selection.StoryLength - 1));
        var defaultColor = Palette(colorScheme).Foreground;
        Document.BatchDisplayUpdates();
        try
        {
            Document.GetRange(0, textLength).CharacterFormat.ForegroundColor = defaultColor;
            foreach (var span in spans)
            {
                var start = Math.Clamp(span.Start, 0, textLength);
                var end = Math.Clamp(span.Start + span.Length, start, textLength);
                if (end <= start) continue;
                Document.GetRange(start, end).CharacterFormat.ForegroundColor = Color(span.Kind, colorScheme);
            }
        }
        finally
        {
            Document.ApplyDisplayUpdates();
        }
        appliedSyntaxSpans = spans.ToList();
        appliedSyntaxColorScheme = colorScheme;
    }

    public void ApplyColorScheme(EditorColorScheme scheme)
    {
        var palette = Palette(scheme);
        Background = new SolidColorBrush(palette.Background);
        Foreground = new SolidColorBrush(palette.Foreground);
        SelectionHighlightColor = new SolidColorBrush(palette.Selection);
        appliedSyntaxColorScheme = null;
    }

    public static (global::Windows.UI.Color Background, global::Windows.UI.Color Foreground,
        global::Windows.UI.Color Selection) Palette(EditorColorScheme scheme) => scheme switch
    {
        EditorColorScheme.Light => (global::Windows.UI.Color.FromArgb(255, 255, 255, 255),
            global::Windows.UI.Color.FromArgb(255, 36, 41, 47), global::Windows.UI.Color.FromArgb(125, 9, 105, 218)),
        EditorColorScheme.SolarizedDark => (global::Windows.UI.Color.FromArgb(255, 0, 43, 54),
            global::Windows.UI.Color.FromArgb(255, 147, 161, 161), global::Windows.UI.Color.FromArgb(125, 181, 137, 0)),
        EditorColorScheme.Dracula => (global::Windows.UI.Color.FromArgb(255, 40, 42, 54),
            global::Windows.UI.Color.FromArgb(255, 248, 248, 242), global::Windows.UI.Color.FromArgb(125, 189, 147, 249)),
        _ => (global::Windows.UI.Color.FromArgb(255, 40, 44, 52),
            global::Windows.UI.Color.FromArgb(255, 236, 239, 244), global::Windows.UI.Color.FromArgb(125, 82, 139, 255))
    };

    private static global::Windows.UI.Color Color(
        Core.Editing.SyntaxTokenKind kind, EditorColorScheme scheme) => (kind, scheme) switch
    {
        (Core.Editing.SyntaxTokenKind.Keyword, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 133, 153, 0),
        (Core.Editing.SyntaxTokenKind.String, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 42, 161, 152),
        (Core.Editing.SyntaxTokenKind.Number, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 211, 54, 130),
        (Core.Editing.SyntaxTokenKind.Comment, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 88, 110, 117),
        (Core.Editing.SyntaxTokenKind.Type, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 181, 137, 0),
        (Core.Editing.SyntaxTokenKind.Constant, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 203, 75, 22),
        (Core.Editing.SyntaxTokenKind.Markup, EditorColorScheme.SolarizedDark) => global::Windows.UI.Color.FromArgb(255, 38, 139, 210),
        (Core.Editing.SyntaxTokenKind.Keyword, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 255, 121, 198),
        (Core.Editing.SyntaxTokenKind.String, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 241, 250, 140),
        (Core.Editing.SyntaxTokenKind.Number, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 189, 147, 249),
        (Core.Editing.SyntaxTokenKind.Comment, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 98, 114, 164),
        (Core.Editing.SyntaxTokenKind.Type, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 139, 233, 253),
        (Core.Editing.SyntaxTokenKind.Constant, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 189, 147, 249),
        (Core.Editing.SyntaxTokenKind.Markup, EditorColorScheme.Dracula) => global::Windows.UI.Color.FromArgb(255, 80, 250, 123),
        (Core.Editing.SyntaxTokenKind.Keyword, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 198, 120, 221),
        (Core.Editing.SyntaxTokenKind.String, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 152, 195, 121),
        (Core.Editing.SyntaxTokenKind.Number, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 209, 154, 102),
        (Core.Editing.SyntaxTokenKind.Comment, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 110, 128, 112),
        (Core.Editing.SyntaxTokenKind.Type, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 229, 192, 123),
        (Core.Editing.SyntaxTokenKind.Constant, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 86, 182, 194),
        (Core.Editing.SyntaxTokenKind.Markup, EditorColorScheme.Dark) => global::Windows.UI.Color.FromArgb(255, 224, 108, 117),
        (Core.Editing.SyntaxTokenKind.Keyword, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 126, 45, 130),
        (Core.Editing.SyntaxTokenKind.String, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 35, 115, 45),
        (Core.Editing.SyntaxTokenKind.Number, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 145, 80, 18),
        (Core.Editing.SyntaxTokenKind.Comment, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 80, 120, 80),
        (Core.Editing.SyntaxTokenKind.Type, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 125, 85, 0),
        (Core.Editing.SyntaxTokenKind.Constant, EditorColorScheme.Light) => global::Windows.UI.Color.FromArgb(255, 0, 105, 125),
        _ => global::Windows.UI.Color.FromArgb(255, 165, 35, 50)
    };
}
