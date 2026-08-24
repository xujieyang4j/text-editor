import type { MenuEvent } from '../../shared/ipc.js'

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
  { id: 'save', title: 'File: Save', hint: 'Ctrl/Cmd+S' },
  { id: 'save-as', title: 'File: Save As…', hint: 'Ctrl/Cmd+Shift+S' },
  { id: 'close-tab', title: 'File: Close Tab', hint: 'Ctrl/Cmd+W' },
  { id: 'reopen-tab', title: 'File: Reopen Closed Tab', hint: 'Ctrl/Cmd+Shift+T' },

  { id: 'goto-anything', title: 'Goto: Goto Anything…', hint: 'Ctrl/Cmd+P' },
  { id: 'goto-symbol', title: 'Goto: Goto Symbol…', hint: 'Ctrl/Cmd+R' },
  { id: 'goto-project-symbol', title: 'Goto: Goto Symbol in Project…', hint: 'Ctrl/Cmd+Shift+R' },
  { id: 'go-to-line', title: 'Goto: Goto Line…', hint: 'Ctrl/Cmd+G' },
  { id: 'navigate-back', title: 'Goto: Back', hint: 'Alt+Left' },
  { id: 'navigate-forward', title: 'Goto: Forward', hint: 'Alt+Right' },

  { id: 'find', title: 'Find: Find…', hint: 'Ctrl/Cmd+F' },
  { id: 'replace', title: 'Find: Replace…', hint: 'Ctrl/Cmd+H' },
  { id: 'find-in-files', title: 'Find: Find in Files…', hint: 'Ctrl/Cmd+Shift+F' },
  { id: 'replace-in-files', title: 'Find: Replace in Files…', hint: 'Ctrl/Cmd+Shift+H' },
  { id: 'find-results-next', title: 'Find: Next Result', hint: 'F4' },
  { id: 'find-results-prev', title: 'Find: Previous Result', hint: 'Shift+F4' },

  { id: 'toggle-comment', title: 'Edit: Toggle Comment', hint: 'Ctrl/Cmd+/' },
  { id: 'move-line-up', title: 'Edit: Move Line Up', hint: 'Alt+Up' },
  { id: 'move-line-down', title: 'Edit: Move Line Down', hint: 'Alt+Down' },
  { id: 'copy-line-up', title: 'Edit: Copy Line Up', hint: 'Shift+Alt+Up' },
  { id: 'copy-line-down', title: 'Edit: Copy Line Down', hint: 'Shift+Alt+Down' },
  { id: 'duplicate-selection', title: 'Edit: Duplicate Line/Selection', hint: 'Ctrl/Cmd+Shift+D' },
  { id: 'delete-line', title: 'Edit: Delete Line', hint: 'Ctrl/Cmd+Shift+K' },
  { id: 'sort-lines', title: 'Edit: Sort Lines' },
  { id: 'toggle-bookmark', title: 'Navigate: Toggle Bookmark', hint: 'Ctrl/Cmd+F2' },
  { id: 'next-bookmark', title: 'Navigate: Next Bookmark', hint: 'F2' },
  { id: 'prev-bookmark', title: 'Navigate: Previous Bookmark', hint: 'Shift+F2' },
  { id: 'record-macro', title: 'Tools: Start / Stop Macro Recording' },
  { id: 'run-macro', title: 'Tools: Run Last Macro' },
  { id: 'insert-snippet', title: 'Tools: Insert Snippet…' },

  { id: 'select-language', title: 'View: Set Syntax…' },
  { id: 'toggle-preview', title: 'View: Toggle Markdown Preview', hint: 'Ctrl/Cmd+Shift+V' },
  { id: 'open-in-browser', title: 'View: Open in Browser' },
  { id: 'toggle-sidebar', title: 'View: Toggle Sidebar', hint: 'Ctrl/Cmd+B' },
  { id: 'split-editor', title: 'View: Toggle Split Editor', hint: 'Ctrl/Cmd+Alt+2' },
  { id: 'toggle-minimap', title: 'View: Toggle Minimap' },
  { id: 'toggle-word-wrap', title: 'View: Toggle Word Wrap', hint: 'Alt+Z' },
  { id: 'toggle-theme', title: 'View: Toggle Theme', hint: 'Ctrl/Cmd+K' },
  { id: 'font-zoom-in', title: 'View: Zoom In', hint: 'Ctrl/Cmd+=' },
  { id: 'font-zoom-out', title: 'View: Zoom Out', hint: 'Ctrl/Cmd+-' },
  { id: 'font-zoom-reset', title: 'View: Reset Zoom', hint: 'Ctrl/Cmd+0' },
  { id: 'build', title: 'Tools: Build', hint: 'Ctrl/Cmd+B' },
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
  { id: 'split-selection-lines', title: 'Selection: Split Selection into Lines' },
  { id: 'indent-selection', title: 'Edit: Indent Selection' },
  { id: 'outdent-selection', title: 'Edit: Outdent Selection' },
  { id: 'toggle-problems', title: 'View: Toggle Build Output' },
  { id: 'select-color-scheme', title: 'View: Select Color Scheme…' },
  { id: 'toggle-git', title: 'View: Toggle Git Changes' },
  { id: 'refresh-git', title: 'Git: Refresh Changes' },
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
]
