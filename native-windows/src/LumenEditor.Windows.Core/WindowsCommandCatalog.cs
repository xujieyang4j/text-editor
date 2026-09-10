namespace LumenEditor.Windows.Core;

/// <summary>Canonical Windows command identity surface; routes are phased in via typed handlers.</summary>
public static class WindowsCommandCatalog
{
    public static readonly string[] All =
    [
        "new-file", "open-file", "open-file-with-encoding", "open-folder", "copy-file-path", "copy-relative-file-path", "open-recent-file", "save", "save-as", "save-all",
        "select-line-ending", "select-encoding", "reopen-with-encoding", "toggle-pin-tab", "close-tab", "close-other-tabs", "close-tabs-to-right", "close-all-tabs", "reopen-tab",
        "goto-anything", "goto-symbol", "goto-project-symbol", "go-to-line", "goto-matching-bracket", "navigate-back", "navigate-forward", "find", "find-next", "find-previous", "replace",
        "find-in-files", "replace-in-files", "undo-replace-in-files", "find-results-next", "find-results-prev", "next-change", "prev-change", "revert-current-change", "toggle-comment", "toggle-block-comment",
        "add-cursor-above", "add-cursor-below", "undo-selection", "redo-selection", "select-next-occurrence", "skip-current-occurrence", "remove-last-cursor", "select-all-occurrences", "add-cursors-line-starts",
        "add-cursors-line-ends", "select-line", "select-matching-bracket", "select-parent-syntax", "expand-selection", "shrink-selection", "move-line-up", "move-line-down", "copy-line-up", "copy-line-down",
        "duplicate-selection", "delete-line", "delete-word-backward", "delete-word-forward", "delete-to-line-start", "delete-to-line-end", "insert-blank-line-above", "insert-blank-line", "transpose-characters",
        "sort-lines", "sort-lines-descending", "reverse-lines", "unique-lines", "remove-blank-lines", "toggle-bookmark", "next-bookmark", "prev-bookmark", "record-macro", "run-macro",
        "save-macro", "run-saved-macro", "insert-snippet", "select-language", "toggle-preview", "open-in-browser", "toggle-sidebar", "reveal-active-file-in-sidebar", "split-editor", "split-selected-tabs",
        "toggle-line-numbers", "toggle-minimap", "toggle-whitespace", "toggle-outline", "fold-current", "unfold-current", "fold-all", "unfold-all", "toggle-distraction-free", "cycle-auto-save",
        "toggle-spell-check", "format-json", "compact-json", "toggle-json-view", "toggle-word-wrap", "toggle-theme", "font-zoom-in", "font-zoom-out", "font-zoom-reset", "build",
        "toggle-terminal", "document-statistics", "import-sublime-build", "format-document", "trim-trailing-whitespace", "ensure-single-final-newline", "convert-indent-spaces", "convert-indent-tabs",
        "convert-eol-lf", "convert-eol-crlf", "convert-eol-cr", "to-upper-case", "to-lower-case", "to-title-case", "swap-case", "join-lines", "wrap-paragraph-80", "unwrap-paragraph",
        "split-selection-lines", "indent-selection", "outdent-selection", "reindent-selection", "toggle-problems", "select-color-scheme", "toggle-git", "refresh-git", "open-git-conflicts", "check-for-updates",
        "open-marketplace", "project-settings", "language-tools", "install-plugin", "manage-plugins", "next-tab", "prev-tab", "layout-single", "layout-columns2", "layout-columns3",
        "layout-grid4", "move-file-next-group", "clone-file-next-group", "focus-next-group", "focus-prev-group", "new-window", "add-folder-to-project", "remove-folder-from-project", "open-recent-project",
        "import-sublime-project", "import-sublime-settings", "import-sublime-snippet", "import-sublime-keymap", "set-ui-language-zh", "set-ui-language-en", "open-settings", "lsp-hover", "lsp-definition",
        "lsp-references", "lsp-rename", "toggle-language-servers", "command-palette", "select-build-system"
    ];
}
