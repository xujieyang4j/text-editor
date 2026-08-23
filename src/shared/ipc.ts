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
  | 'next-tab'
  | 'prev-tab'
  | 'find'
  | 'replace'
  | 'toggle-sidebar'
  | 'toggle-word-wrap'
  | 'toggle-theme'
  | 'command-palette'
  | 'go-to-line'
