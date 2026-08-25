import type { MenuEvent } from '../../shared/ipc.js'
import { commandTitle } from '../../shared/i18n.js'
import type { UiLocale } from '../../shared/ipc.js'

/**
 * A user-invokable command. The `id` doubles as the {@link MenuEvent} name so
 * the native menu, keyboard shortcuts and the command palette all dispatch
 * through one path (App.run in main.ts).
 */
export interface Command {
  id: MenuEvent
  /** Human title shown in the command palette. */
  title: string
  /** Optional keyboard hint shown on the right of the palette row. */
  hint?: string
}

/**
 * The canonical list of commands surfaced in the Command Palette.
 * Keep titles action-first ("File: New File") the way Sublime groups them.
 */
export const COMMANDS: Command[] = [
  { id: 'new-file', title: 'File: New File', hint: 'Ctrl/Cmd+N' },
  { id: 'open-file', title: 'File: Open File…', hint: 'Ctrl/Cmd+O' },
  { id: 'open-folder', title: 'File: Open Folder…', hint: 'Ctrl/Cmd+Shift+O' },
  { id: 'copy-file-path', title: 'File: Copy File Path' },
  { id: 'copy-relative-file-path', title: 'File: Copy Relative File Path' },
  { id: 'open-recent-file', title: 'File: Open Recent File…' },
  { id: 'save', title: 'File: Save', hint: 'Ctrl/Cmd+S' },
  { id: 'save-as', title: 'File: Save As…', hint: 'Ctrl/Cmd+Shift+S' },
  { id: 'save-all', title: 'File: Save All', hint: 'Ctrl/Cmd+Alt+S' },
  { id: 'close-tab', title: 'File: Close Tab', hint: 'Ctrl/Cmd+W' },
  { id: 'close-other-tabs', title: 'File: Close Other Tabs' },
  { id: 'close-tabs-to-right', title: 'File: Close Tabs to the Right' },
  { id: 'close-all-tabs', title: 'File: Close All Tabs' },
  { id: 'reopen-tab', title: 'File: Reopen Closed Tab', hint: 'Ctrl/Cmd+Shift+T' },

  { id: 'goto-anything', title: 'Goto: Goto Anything…', hint: 'Ctrl/Cmd+P' },
  { id: 'goto-symbol', title: 'Goto: Goto Symbol…', hint: 'Ctrl/Cmd+R' },
  { id: 'goto-project-symbol', title: 'Goto: Goto Symbol in Project…', hint: 'Ctrl/Cmd+Shift+R' },
  { id: 'go-to-line', title: 'Goto: Goto Line…', hint: 'Ctrl/Cmd+G' },
  { id: 'goto-matching-bracket', title: 'Goto: Goto Matching Bracket', hint: 'Ctrl/Cmd+Shift+\\' },
  { id: 'navigate-back', title: 'Goto: Back', hint: 'Alt+Left' },
  { id: 'navigate-forward', title: 'Goto: Forward', hint: 'Alt+Right' },

  { id: 'find', title: 'Find: Find…', hint: 'Ctrl/Cmd+F' },
  { id: 'replace', title: 'Find: Replace…', hint: 'Ctrl/Cmd+H' },
  { id: 'find-in-files', title: 'Find: Find in Files…', hint: 'Ctrl/Cmd+Shift+F' },
  { id: 'replace-in-files', title: 'Find: Replace in Files…', hint: 'Ctrl/Cmd+Shift+H' },
  { id: 'undo-replace-in-files', title: 'Find: Undo Last Replace in Files' },
  { id: 'find-results-next', title: 'Find: Next Result', hint: 'F4' },
  { id: 'find-results-prev', title: 'Find: Previous Result', hint: 'Shift+F4' },
  { id: 'next-change', title: 'Goto: Next Change', hint: 'Ctrl/Cmd+Alt+Shift+Down' },
  { id: 'prev-change', title: 'Goto: Previous Change', hint: 'Ctrl/Cmd+Alt+Shift+Up' },
  { id: 'revert-current-change', title: 'Edit: Revert Current Change' },

  { id: 'toggle-comment', title: 'Edit: Toggle Comment', hint: 'Ctrl/Cmd+/' },
  { id: 'toggle-block-comment', title: 'Edit: Toggle Block Comment', hint: 'Ctrl/Cmd+Shift+/' },
  { id: 'add-cursor-above', title: 'Selection: Add Cursor Above', hint: 'Ctrl/Cmd+Alt+Up' },
  { id: 'add-cursor-below', title: 'Selection: Add Cursor Below', hint: 'Ctrl/Cmd+Alt+Down' },
  { id: 'select-next-occurrence', title: 'Selection: Add Next Occurrence', hint: 'Ctrl/Cmd+D' },
  { id: 'select-all-occurrences', title: 'Selection: Select All Occurrences', hint: 'Alt+F3' },
  { id: 'select-line', title: 'Selection: Select Line', hint: 'Alt+L / macOS: Ctrl+L' },
  { id: 'select-matching-bracket', title: 'Selection: Select to Matching Bracket' },
  { id: 'expand-selection', title: 'Selection: Expand Selection', hint: 'Shift+Alt+Right' },
  { id: 'shrink-selection', title: 'Selection: Shrink Selection', hint: 'Shift+Alt+Left' },
  { id: 'move-line-up', title: 'Edit: Move Line Up', hint: 'Alt+Up' },
  { id: 'move-line-down', title: 'Edit: Move Line Down', hint: 'Alt+Down' },
  { id: 'copy-line-up', title: 'Edit: Copy Line Up', hint: 'Shift+Alt+Up' },
  { id: 'copy-line-down', title: 'Edit: Copy Line Down', hint: 'Shift+Alt+Down' },
  { id: 'duplicate-selection', title: 'Edit: Duplicate Line/Selection', hint: 'Ctrl/Cmd+Shift+D' },
  { id: 'delete-line', title: 'Edit: Delete Line', hint: 'Ctrl/Cmd+Shift+K' },
  { id: 'delete-word-backward', title: 'Edit: Delete Previous Word', hint: 'Win/Linux: Ctrl+Backspace · macOS: Alt+Backspace' },
  { id: 'delete-word-forward', title: 'Edit: Delete Next Word', hint: 'Win/Linux: Ctrl+Delete · macOS: Alt+Delete' },
  { id: 'delete-to-line-start', title: 'Edit: Delete to Line Start', hint: 'Ctrl/Cmd+Shift+Backspace' },
  { id: 'delete-to-line-end', title: 'Edit: Delete to Line End', hint: 'Ctrl/Cmd+Shift+Delete' },
  { id: 'insert-blank-line-above', title: 'Edit: Insert Blank Line Above', hint: 'Ctrl/Cmd+Shift+Enter' },
  { id: 'insert-blank-line', title: 'Edit: Insert Blank Line Below', hint: 'Ctrl/Cmd+Enter' },
  { id: 'transpose-characters', title: 'Edit: Transpose Characters', hint: 'Ctrl+T' },
  { id: 'sort-lines', title: 'Edit: Sort Lines' },
  { id: 'toggle-bookmark', title: 'Navigate: Toggle Bookmark', hint: 'Ctrl/Cmd+F2' },
  { id: 'next-bookmark', title: 'Navigate: Next Bookmark', hint: 'F2' },
  { id: 'prev-bookmark', title: 'Navigate: Previous Bookmark', hint: 'Shift+F2' },
  { id: 'record-macro', title: 'Tools: Start / Stop Macro Recording' },
  { id: 'run-macro', title: 'Tools: Run Last Macro' },
  { id: 'save-macro', title: 'Tools: Save Last Macro…' },
  { id: 'run-saved-macro', title: 'Tools: Run Saved Macro…' },
  { id: 'insert-snippet', title: 'Tools: Insert Snippet…' },

  { id: 'select-language', title: 'View: Set Syntax…' },
  { id: 'toggle-preview', title: 'View: Toggle Markdown Preview', hint: 'Ctrl/Cmd+Shift+V' },
  { id: 'open-in-browser', title: 'View: Open in Browser' },
  { id: 'toggle-sidebar', title: 'View: Toggle Sidebar', hint: 'Ctrl/Cmd+B' },
  { id: 'split-editor', title: 'View: Toggle Split Editor', hint: 'Ctrl/Cmd+Alt+2' },
  { id: 'split-selected-tabs', title: 'View: Split Selected Tabs into Groups' },
  { id: 'toggle-minimap', title: 'View: Toggle Minimap' },
  { id: 'toggle-outline', title: 'View: Toggle Outline' },
  { id: 'fold-current', title: 'View: Fold Current', hint: 'Ctrl+Shift+[ / macOS: Cmd+Alt+[' },
  { id: 'unfold-current', title: 'View: Unfold Current', hint: 'Ctrl+Shift+] / macOS: Cmd+Alt+]' },
  { id: 'fold-all', title: 'View: Fold All', hint: 'Ctrl+Alt+[' },
  { id: 'unfold-all', title: 'View: Unfold All', hint: 'Ctrl+Alt+]' },
  { id: 'toggle-distraction-free', title: 'View: Toggle Distraction Free Mode', hint: 'Shift+F11' },
  { id: 'cycle-auto-save', title: 'File: Cycle Auto Save Mode' },
  { id: 'toggle-spell-check', title: 'View: Toggle Spell Check' },
  { id: 'format-json', title: 'JSON: Format JSON' },
  { id: 'compact-json', title: 'JSON: Compact JSON' },
  { id: 'toggle-json-view', title: 'JSON: Toggle JSON View' },
  { id: 'toggle-word-wrap', title: 'View: Toggle Word Wrap', hint: 'Alt+Z' },
  { id: 'toggle-theme', title: 'View: Toggle Theme', hint: 'Ctrl/Cmd+K' },
  { id: 'font-zoom-in', title: 'View: Zoom In', hint: 'Ctrl/Cmd+=' },
  { id: 'font-zoom-out', title: 'View: Zoom Out', hint: 'Ctrl/Cmd+-' },
  { id: 'font-zoom-reset', title: 'View: Reset Zoom', hint: 'Ctrl/Cmd+0' },
  { id: 'build', title: 'Tools: Build', hint: 'Ctrl/Cmd+B' },
  { id: 'toggle-terminal', title: 'Tools: Toggle Terminal', hint: 'Ctrl/Cmd+Alt+T' },
  { id: 'document-statistics', title: 'Tools: Document Statistics' },
  { id: 'import-sublime-build', title: 'Tools: Import Sublime Build System…' },
  { id: 'format-document', title: 'Tools: Format Document' },
  { id: 'trim-trailing-whitespace', title: 'Edit: Trim Trailing Whitespace' },
  { id: 'convert-indent-spaces', title: 'Edit: Convert Indentation to Spaces' },
  { id: 'convert-indent-tabs', title: 'Edit: Convert Indentation to Tabs' },
  { id: 'convert-eol-lf', title: 'Edit: Convert Line Endings to LF' },
  { id: 'convert-eol-crlf', title: 'Edit: Convert Line Endings to CRLF' },
  { id: 'convert-eol-cr', title: 'Edit: Convert Line Endings to CR' },
  { id: 'to-upper-case', title: 'Edit: Upper Case' },
  { id: 'to-lower-case', title: 'Edit: Lower Case' },
  { id: 'to-title-case', title: 'Edit: Title Case' },
  { id: 'join-lines', title: 'Edit: Join Lines' },
  { id: 'split-selection-lines', title: 'Selection: Split Selection into Lines', hint: 'Ctrl/Cmd+Shift+L' },
  { id: 'indent-selection', title: 'Edit: Indent Selection' },
  { id: 'outdent-selection', title: 'Edit: Outdent Selection' },
  { id: 'reindent-selection', title: 'Edit: Reindent Selection', hint: 'Ctrl/Cmd+Alt+\\' },
  { id: 'toggle-problems', title: 'View: Toggle Build Output' },
  { id: 'select-color-scheme', title: 'View: Select Color Scheme…' },
  { id: 'toggle-git', title: 'View: Toggle Git Changes' },
  { id: 'refresh-git', title: 'Git: Refresh Changes' },
  { id: 'open-git-conflicts', title: 'Git: Open Merge Conflicts' },
  { id: 'check-for-updates', title: 'Help: Check for Updates…' },
  { id: 'open-marketplace', title: 'Tools: Browse Plugin Marketplace…' },
  { id: 'project-settings', title: 'Project: Configure…' },
  { id: 'language-tools', title: 'Tools: Configure Language Tool…' },
  { id: 'install-plugin', title: 'Tools: Install Local Plugin…' },
  { id: 'manage-plugins', title: 'Tools: Manage Plugins…' },

  { id: 'next-tab', title: 'Go: Next Tab', hint: 'Ctrl/Cmd+Alt+Right' },
  { id: 'prev-tab', title: 'Go: Previous Tab', hint: 'Ctrl/Cmd+Alt+Left' },
  { id: 'layout-single', title: 'View: Layout Single' },
  { id: 'layout-columns2', title: 'View: Layout Columns 2' },
  { id: 'layout-columns3', title: 'View: Layout Columns 3' },
  { id: 'layout-grid4', title: 'View: Layout Grid 4' },
  { id: 'move-file-next-group', title: 'View: Move File to Next Group' },
  { id: 'clone-file-next-group', title: 'View: Clone File to Next Group' },
  { id: 'focus-next-group', title: 'View: Focus Next Group', hint: 'Ctrl/Cmd+Alt+]' },
  { id: 'focus-prev-group', title: 'View: Focus Previous Group', hint: 'Ctrl/Cmd+Alt+[' },
  { id: 'new-window', title: 'File: New Window' }
  , { id: 'add-folder-to-project', title: 'Project: Add Folder to Project…' }
  , { id: 'remove-folder-from-project', title: 'Project: Remove Folder from Project…' }
  , { id: 'open-recent-project', title: 'Project: Open Recent Project…' }
  , { id: 'import-sublime-project', title: 'Project: Import Sublime Project…' }
  , { id: 'import-sublime-settings', title: 'Preferences: Import Sublime Settings…' }
  , { id: 'import-sublime-snippet', title: 'Tools: Import Sublime Snippet…' }
  , { id: 'import-sublime-keymap', title: 'Preferences: Import Sublime Keymap…' }
  , { id: 'set-ui-language-zh', title: 'Preferences: Switch to Simplified Chinese' }
  , { id: 'set-ui-language-en', title: 'Preferences: Switch to English' }
  , { id: 'open-settings', title: 'Preferences: Open Settings…' }
  , { id: 'lsp-hover', title: 'LSP: Show Hover', hint: 'Ctrl/Cmd+Shift+Space' }
  , { id: 'lsp-definition', title: 'LSP: Go to Definition', hint: 'F12' }
  , { id: 'lsp-references', title: 'LSP: Find References', hint: 'Shift+F12' }
  , { id: 'lsp-rename', title: 'LSP: Rename Symbol', hint: 'F2' }
]

export function localizedCommands(locale: UiLocale): Command[] {
  return COMMANDS.map((command) => ({ ...command, title: commandTitle(locale, command.id, command.title) }))
}
