using System.Net;
using System.Text;
using System.Text.Json;
using Markdig;

namespace LumenEditor.Windows.Core.Documents;

public static class PreviewRenderer
{
    public const int MaximumPreviewCharacters = 2_000_000;
    public const int MaximumRichPreviewUtf8Bytes = 1536 * 1024;
    private static readonly MarkdownPipeline MarkdownPipeline = new MarkdownPipelineBuilder()
        .UseAdvancedExtensions().DisableHtml().Build();

    public static bool IsMarkdownFileName(string path) => Path.GetFileName(path)
        .EndsWith(".md", StringComparison.OrdinalIgnoreCase)
        || new[] { ".markdown", ".mdown", ".mkd", ".mkdn", ".mdx" }
            .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static bool IsHtmlFileName(string path) => new[] { ".html", ".htm", ".xhtml" }
        .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static string MarkdownToSafeHtml(string markdown, bool darkTheme)
    {
        ArgumentNullException.ThrowIfNull(markdown);
        var truncated = markdown.Length > MaximumPreviewCharacters;
        var source = truncated ? SafePrefix(markdown, MaximumPreviewCharacters) : markdown;
        var body = Markdown.ToHtml(source, MarkdownPipeline);
        while (Encoding.UTF8.GetByteCount(body) > MaximumRichPreviewUtf8Bytes && source.Length > 1)
        {
            truncated = true;
            source = SafePrefix(source, source.Length / 2);
            body = Markdown.ToHtml(source, MarkdownPipeline);
        }
        var warning = truncated
            ? "<aside class=\"warning\">Preview truncated at the 2,000,000-character safety limit.</aside>"
            : String.Empty;
        var foreground = darkTheme ? "#eceff4" : "#20242a";
        var background = darkTheme ? "#1e222a" : "#ffffff";
        var muted = darkTheme ? "#9aa5b1" : "#57606a";
        var border = darkTheme ? "#3b4252" : "#d0d7de";
        var code = darkTheme ? "#2b303b" : "#f6f8fa";
        var html = "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">"
            + $"<style>:root{{color-scheme:{(darkTheme ? "dark" : "light")}}}body{{box-sizing:border-box;margin:0 auto;padding:24px;max-width:960px;color:{foreground};background:{background};font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;overflow-wrap:anywhere}}h1,h2{{border-bottom:1px solid {border};padding-bottom:.3em}}pre,code{{font-family:'Cascadia Mono',Consolas,monospace;background:{code};border-radius:4px}}code{{padding:.15em .35em}}pre{{padding:14px;overflow:auto}}pre code{{padding:0;background:transparent}}blockquote{{margin-left:0;padding-left:1em;color:{muted};border-left:4px solid {border}}}table{{border-collapse:collapse;display:block;overflow:auto}}th,td{{border:1px solid {border};padding:6px 12px}}a{{color:#58a6ff}}img{{max-width:100%}}.warning{{padding:8px 12px;border:1px solid #bf8700;background:#fff8c5;color:#4d2d00}}</style>"
            + "</head><body>" + warning + body + "</body></html>";
        if (Encoding.UTF8.GetByteCount(html) > 2 * 1024 * 1024)
            throw new InvalidOperationException("Rendered Markdown exceeds the WebView document limit.");
        return html;
    }

    public static string MarkdownToSafeText(string markdown)
    {
        var source = markdown.Length <= MaximumPreviewCharacters ? markdown : markdown[..MaximumPreviewCharacters];
        var output = new StringBuilder(source.Length);
        var inFence = false;
        var fence = new string((char)96, 3);
        foreach (var rawLine in TextFileCodec.NormalizeLineEndings(source).Split('\n'))
        {
            var line = rawLine.TrimEnd();
            if (line.TrimStart().StartsWith(fence, StringComparison.Ordinal))
            {
                inFence = !inFence;
                continue;
            }
            if (inFence) output.AppendLine("    " + line);
            else
            {
                var content = line.TrimStart();
                while (content.StartsWith('#')) content = content[1..];
                content = content.TrimStart();
                content = content.Replace("**", String.Empty, StringComparison.Ordinal)
                    .Replace("__", String.Empty, StringComparison.Ordinal)
                    .Replace(((char)96).ToString(), String.Empty, StringComparison.Ordinal);
                output.AppendLine(WebUtility.HtmlDecode(content));
            }
        }
        return output.ToString().TrimEnd();
    }

    private static string SafePrefix(string value, int maximum)
    {
        var end = Math.Min(value.Length, maximum);
        if (end > 0 && end < value.Length && Char.IsHighSurrogate(value[end - 1])
            && Char.IsLowSurrogate(value[end])) end--;
        return value[..end];
    }

    public static IReadOnlyList<string> JsonTree(string text, int maximumNodes = 5_000)
    {
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 128, AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            var rows = new List<string>();
            AppendJson(document.RootElement, "$", 0, rows, Math.Clamp(maximumNodes, 1, 5_000));
            return rows;
        }
        catch (JsonException) { return []; }
    }

    private static void AppendJson(JsonElement value, string name, int depth, List<string> rows, int maximum)
    {
        if (rows.Count >= maximum) return;
        var indent = new string(' ', depth * 2);
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                rows.Add($"{indent}{name}: {{object}} ({value.GetRawText().Length} chars)");
                foreach (var property in value.EnumerateObject()) AppendJson(property.Value, property.Name, depth + 1, rows, maximum);
                break;
            case JsonValueKind.Array:
                rows.Add($"{indent}{name}: [array] ({value.GetArrayLength()} items)");
                var index = 0;
                foreach (var item in value.EnumerateArray()) AppendJson(item, $"[{index++}]", depth + 1, rows, maximum);
                break;
            default:
                var rendered = value.GetRawText();
                if (rendered.Length > 200) rendered = rendered[..200] + "…";
                rows.Add($"{indent}{name}: {rendered}");
                break;
        }
    }
}
