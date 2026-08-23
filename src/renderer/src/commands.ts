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
  { id: 'go-to-line', title: 'Goto: Goto Line…', hint: 'Ctrl/Cmd+G' },

  { id: 'find', title: 'Find: Find…', hint: 'Ctrl/Cmd+F' },
  { id: 'replace', title: 'Find: Replace…', hint: 'Ctrl/Cmd+H' },

  { id: 'toggle-comment', title: 'Edit: Toggle Comment', hint: 'Ctrl/Cmd+/' },
  { id: 'move-line-up', title: 'Edit: Move Line Up', hint: 'Alt+Up' },
  { id: 'move-line-down', title: 'Edit: Move Line Down', hint: 'Alt+Down' },
  { id: 'copy-line-up', title: 'Edit: Copy Line Up', hint: 'Shift+Alt+Up' },
  { id: 'copy-line-down', title: 'Edit: Copy Line Down', hint: 'Shift+Alt+Down' },
  { id: 'duplicate-selection', title: 'Edit: Duplicate Line/Selection', hint: 'Ctrl/Cmd+Shift+D' },
  { id: 'delete-line', title: 'Edit: Delete Line', hint: 'Ctrl/Cmd+Shift+K' },
  { id: 'sort-lines', title: 'Edit: Sort Lines' },

  { id: 'select-language', title: 'View: Set Syntax…' },
  { id: 'toggle-sidebar', title: 'View: Toggle Sidebar', hint: 'Ctrl/Cmd+B' },
  { id: 'toggle-minimap', title: 'View: Toggle Minimap' },
  { id: 'toggle-word-wrap', title: 'View: Toggle Word Wrap', hint: 'Alt+Z' },
  { id: 'toggle-theme', title: 'View: Toggle Theme', hint: 'Ctrl/Cmd+K' },
  { id: 'font-zoom-in', title: 'View: Zoom In', hint: 'Ctrl/Cmd+=' },
  { id: 'font-zoom-out', title: 'View: Zoom Out', hint: 'Ctrl/Cmd+-' },
  { id: 'font-zoom-reset', title: 'View: Reset Zoom', hint: 'Ctrl/Cmd+0' },

  { id: 'next-tab', title: 'Go: Next Tab', hint: 'Ctrl/Cmd+Alt+Right' },
  { id: 'prev-tab', title: 'Go: Previous Tab', hint: 'Ctrl/Cmd+Alt+Left' }
]
