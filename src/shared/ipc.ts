/**
 * Shared type definitions used across main, preload and renderer.
 * Keeping the IPC contract in one place avoids drift between processes.
 */

/** IPC channel names. Centralised to avoid typos across process boundaries. */
export const IPC = {
  fileNew: 'file:new',
  fileOpen: 'file:open',
  fileOpenPath: 'file:open-path',
  folderOpen: 'folder:open',
  fileSave: 'file:save',
  fileSaveAs: 'file:save-as',
  dirRead: 'dir:read',
  dirListFiles: 'dir:list-files',
  settingsRead: 'settings:read',
  settingsWrite: 'settings:write',
  sessionRead: 'session:read',
  sessionWrite: 'session:write',
  // main -> renderer notifications (menu / accelerator driven)
  menuEvent: 'menu:event'
} as const

/** A file successfully read from disk. */
export interface OpenedFile {
  /** Absolute path on disk. */
  path: string
  /** UTF-8 text content. */
  content: string
}

/** Result of a save operation. */
export interface SaveResult {
  /** True when the file was written. False when the user cancelled a dialog. */
  saved: boolean
  /** Absolute path the content was written to (present when saved). */
  path?: string
}

/** A single entry inside a directory listing. */
export interface DirEntry {
  name: string
  path: string
  isDirectory: boolean
}

/** Payload returned when a folder is opened as a workspace. */
export interface OpenedFolder {
  /** Absolute path of the opened root folder. */
  root: string
  /** Top-level entries of the folder. */
  entries: DirEntry[]
}

/**
 * User-configurable settings, persisted as JSON in the app's userData dir.
 * Mirrors the subset of Sublime's Preferences that we support.
 */
export interface Settings {
  fontSize: number
  tabSize: number
  /** Insert spaces instead of a literal tab character. */
  insertSpaces: boolean
  theme: 'dark' | 'light'
  wordWrap: boolean
  showMinimap: boolean
  showIndentGuides: boolean
  highlightTrailingWhitespace: boolean
  /** Column positions to draw vertical rulers at (empty = none). */
  rulers: number[]
}

/** Built-in defaults, used when no settings file exists yet. */
export const DEFAULT_SETTINGS: Settings = {
  fontSize: 14,
  tabSize: 4,
  insertSpaces: true,
  theme: 'dark',
  wordWrap: false,
  showMinimap: true,
  showIndentGuides: true,
  highlightTrailingWhitespace: true,
  rulers: []
}

/** A previously-open document remembered across restarts. */
export interface SessionFile {
  path: string
}

/** Editor state persisted across restarts (open tabs + workspace). */
export interface Session {
  /** Absolute paths of files that were open, in tab order. */
  openFiles: SessionFile[]
  /** Path of the tab that was active, if any. */
  activePath: string | null
  /** Root of the workspace folder that was open, if any. */
  folder: string | null
}

/** Empty session used on first launch. */
export const EMPTY_SESSION: Session = {
  openFiles: [],
  activePath: null,
  folder: null
}

/**
 * Menu / accelerator events forwarded from the main process to the renderer.
 * The renderer owns editor state, so structural commands are dispatched here.
 */
export type MenuEvent =
  | 'new-file'
  | 'open-file'
  | 'open-folder'
  | 'save'
  | 'save-as'
  | 'close-tab'
  | 'reopen-tab'
  | 'next-tab'
  | 'prev-tab'
  | 'find'
  | 'replace'
  | 'toggle-sidebar'
  | 'toggle-word-wrap'
  | 'toggle-theme'
  | 'toggle-minimap'
  | 'command-palette'
  | 'goto-anything'
  | 'goto-symbol'
  | 'go-to-line'
  | 'select-language'
  | 'toggle-comment'
  | 'move-line-up'
  | 'move-line-down'
  | 'copy-line-up'
  | 'copy-line-down'
  | 'delete-line'
  | 'duplicate-selection'
  | 'sort-lines'
  | 'font-zoom-in'
  | 'font-zoom-out'
  | 'font-zoom-reset'
  | 'persist-session'
