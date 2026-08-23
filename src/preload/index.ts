import { contextBridge, ipcRenderer } from 'electron'
import {
  IPC,
  type OpenedFile,
  type SaveResult,
  type OpenedFolder,
  type DirEntry,
  type Settings,
  type Session,
  type MenuEvent
} from '../shared/ipc.js'

/**
 * The typed API surface exposed to the renderer via contextBridge.
 * This is the ONLY way the renderer can reach the main process.
 */
const api = {
  /** Show the open-file dialog. Resolves null if the user cancels. */
  openFile: (): Promise<OpenedFile | null> => ipcRenderer.invoke(IPC.fileOpen),

  /** Read a file by absolute path (e.g. from the file tree). */
  openPath: (filePath: string): Promise<OpenedFile> =>
    ipcRenderer.invoke(IPC.fileOpenPath, filePath),

  /** Show the open-folder dialog. Resolves null if the user cancels. */
  openFolder: (): Promise<OpenedFolder | null> => ipcRenderer.invoke(IPC.folderOpen),

  /** List the immediate children of a directory. */
  readDir: (dirPath: string): Promise<DirEntry[]> => ipcRenderer.invoke(IPC.dirRead, dirPath),

  /** Recursively list every file under a root (for Goto Anything). */
  listFiles: (root: string): Promise<string[]> => ipcRenderer.invoke(IPC.dirListFiles, root),

  /** Save content to a path; passing null triggers a save-as dialog. */
  save: (filePath: string | null, content: string): Promise<SaveResult> =>
    ipcRenderer.invoke(IPC.fileSave, filePath, content),

  /** Always prompt for a destination, then write content. */
  saveAs: (content: string, suggestedName?: string): Promise<SaveResult> =>
    ipcRenderer.invoke(IPC.fileSaveAs, content, suggestedName),

  /** Read persisted user settings (merged over defaults). */
  readSettings: (): Promise<Settings> => ipcRenderer.invoke(IPC.settingsRead),

  /** Persist user settings. */
  writeSettings: (settings: Settings): Promise<void> =>
    ipcRenderer.invoke(IPC.settingsWrite, settings),

  /** Read the persisted session (open tabs + folder). */
  readSession: (): Promise<Session> => ipcRenderer.invoke(IPC.sessionRead),

  /** Persist the session. */
  writeSession: (session: Session): Promise<void> =>
    ipcRenderer.invoke(IPC.sessionWrite, session),

  /** Subscribe to menu / accelerator events. Returns an unsubscribe fn. */
  onMenu: (handler: (event: MenuEvent) => void): (() => void) => {
    const listener = (_e: Electron.IpcRendererEvent, ev: MenuEvent): void => handler(ev)
    ipcRenderer.on(IPC.menuEvent, listener)
    return () => ipcRenderer.removeListener(IPC.menuEvent, listener)
  }
}

/** The shape of the API, imported by the renderer for type-safety. */
export type EditorApi = typeof api

contextBridge.exposeInMainWorld('editor', api)
