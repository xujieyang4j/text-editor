namespace LumenEditor.Windows.Core;

/// <summary>Release association set kept in lockstep with Electron and native macOS.</summary>
public static class WindowsFileAssociationExtensions
{
    public static readonly string[] All =
    [
        "txt", "text", "log", "md", "markdown", "mdx", "json", "jsonc",
        "geojson", "yaml", "yml", "toml", "xml", "xsl", "xsd", "svg",
        "html", "htm", "css", "scss", "sass", "less", "js", "mjs",
        "cjs", "jsx", "ts", "mts", "cts", "tsx", "vue", "py", "pyw",
        "java", "kt", "kts", "swift", "c", "cc", "cpp", "cxx", "h",
        "hpp", "hxx", "hh", "cs", "go", "rs", "php", "phtml", "rb",
        "pl", "pm", "sh", "bash", "zsh", "ksh", "ps1", "psm1", "psd1",
        "sql", "proto", "ini", "properties", "conf", "cmake", "gradle", "groovy",
        "lua", "r", "scala", "scm", "lisp", "clj", "cljs", "fs", "dart",
        "diff", "patch", "tex", "rst"
    ];
}
