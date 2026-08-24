import { contextBridge, ipcRenderer } from 'electron'
import {
  IPC,
  type OpenedFile,
  type SaveResult,
  type OpenedFolder,
  type DirEntry,
  type BrowserOpenRequest,
  type Settings,
  type Session,
  type MenuEvent,
  type FileWriteOptions,
  type WorkspaceMatch,
  type WorkspaceSearchRequest,
  type WorkspaceReplaceRequest,
  type WorkspaceReplaceResult,
  type WorkspaceReplacePreview,
  type WorkspaceSymbol,
  type FileChangeEvent,
  type BuildRequest,
  type BuildOutput,
  type ProjectSettings,
  type PluginManifest,
  type LanguageToolRequest,
  type LanguageToolResult,
  type LanguageServerRequest,
  type LanguageServerResult,
  type LanguageServerSyncRequest,
  type LanguageServerDiagnosticEvent,
  type LanguageServerInteractiveRequest,
  type LanguageServerInteractiveResult,
  type PluginInstallRequest
  , type MarketplaceItem
  , type MarketplaceInstallRequest
  , type GitStatus
  , type GitDiff
  , type RecentProject
  , type WindowSessionMeta
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

  /** Preview current HTML in the system browser without forcing a save. */
  openInBrowser: (request: BrowserOpenRequest): Promise<boolean> =>
    ipcRenderer.invoke(IPC.openInBrowser, request),

  /** Save content to a path; passing null triggers a save-as dialog. */
  save: (filePath: string | null, content: string, options: FileWriteOptions): Promise<SaveResult> =>
    ipcRenderer.invoke(IPC.fileSave, filePath, content, options),

  /** Always prompt for a destination, then write content. */
  saveAs: (content: string, suggestedName: string | undefined, options: FileWriteOptions): Promise<SaveResult> =>
    ipcRenderer.invoke(IPC.fileSaveAs, content, suggestedName, options),

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

  readRecentProjects: (): Promise<RecentProject[]> => ipcRenderer.invoke(IPC.recentProjectsRead),

  addRecentProject: (root: string): Promise<void> => ipcRenderer.invoke(IPC.recentProjectsAdd, root),

  openRecentProject: (root: string): Promise<OpenedFolder> => ipcRenderer.invoke(IPC.recentProjectOpen, root),

  registerWindowSession: (id: string): Promise<void> => ipcRenderer.invoke(IPC.windowSessionRegister, id),

  listWindowSessions: (): Promise<WindowSessionMeta[]> => ipcRenderer.invoke(IPC.windowSessionList),

  /** Confirm to the main process that a close-time session flush has completed. */
  sessionFlushed: (): Promise<void> => ipcRenderer.invoke(IPC.sessionFlushed),

  /** Open only a validated external http(s)/mailto link in the system browser. */
  openExternal: (url: string): Promise<void> => ipcRenderer.invoke(IPC.openExternal, url),

  /** Search files in the current workspace without exposing Node to the renderer. */
  searchWorkspace: (request: WorkspaceSearchRequest): Promise<WorkspaceMatch[]> =>
    ipcRenderer.invoke(IPC.workspaceSearch, request),

  /** Apply a controlled workspace-wide replacement. */
  replaceWorkspace: (request: WorkspaceReplaceRequest): Promise<WorkspaceReplaceResult> =>
    ipcRenderer.invoke(IPC.workspaceReplace, request),

  previewWorkspaceReplace: (request: WorkspaceReplaceRequest): Promise<WorkspaceReplacePreview> =>
    ipcRenderer.invoke(IPC.workspaceReplacePreview, request),

  undoWorkspaceReplace: (token: string): Promise<WorkspaceReplaceResult> =>
    ipcRenderer.invoke(IPC.workspaceReplaceUndo, token),

  listWorkspaceSymbols: (root: string): Promise<WorkspaceSymbol[]> =>
    ipcRenderer.invoke(IPC.workspaceSymbols, root),

  createPath: (target: string, isDirectory: boolean): Promise<DirEntry> =>
    ipcRenderer.invoke(IPC.fileCreate, target, isDirectory),

  renamePath: (source: string, target: string): Promise<void> =>
    ipcRenderer.invoke(IPC.fileRename, source, target),

  deletePath: (target: string): Promise<void> => ipcRenderer.invoke(IPC.fileDelete, target),

  revealInFolder: (target: string): Promise<void> => ipcRenderer.invoke(IPC.revealInFolder, target),

  watchWorkspace: (root: string): Promise<void> => ipcRenderer.invoke(IPC.fileWatch, root),

  onFileChange: (handler: (event: FileChangeEvent) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, change: FileChangeEvent): void => handler(change)
    ipcRenderer.on(IPC.fileWatch, listener)
    return () => ipcRenderer.removeListener(IPC.fileWatch, listener)
  },

  runBuild: (request: BuildRequest): Promise<void> => ipcRenderer.invoke(IPC.buildRun, request),

  cancelBuild: (): Promise<void> => ipcRenderer.invoke(IPC.buildCancel),

  onBuildOutput: (handler: (output: BuildOutput) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, output: BuildOutput): void => handler(output)
    ipcRenderer.on(IPC.buildOutput, listener)
    return () => ipcRenderer.removeListener(IPC.buildOutput, listener)
  },

  readProject: (root: string): Promise<ProjectSettings | undefined> =>
    ipcRenderer.invoke(IPC.projectRead, root),

  writeProject: (root: string, project: ProjectSettings): Promise<void> =>
    ipcRenderer.invoke(IPC.projectWrite, root, project),

  listPlugins: (root: string): Promise<PluginManifest[]> => ipcRenderer.invoke(IPC.pluginList, root),

  installPlugin: (request: PluginInstallRequest): Promise<PluginManifest> =>
    ipcRenderer.invoke(IPC.pluginInstall, request),

  removePlugin: (root: string, id: string): Promise<void> => ipcRenderer.invoke(IPC.pluginRemove, root, id),

  listMarketplace: (root: string): Promise<MarketplaceItem[]> => ipcRenderer.invoke(IPC.marketplaceList, root),

  installMarketplacePlugin: (request: MarketplaceInstallRequest): Promise<PluginManifest> =>
    ipcRenderer.invoke(IPC.marketplaceInstall, request),

  gitStatus: (root: string): Promise<GitStatus> => ipcRenderer.invoke(IPC.gitStatus, root),

  gitDiff: (root: string, relativePath: string): Promise<GitDiff> =>
    ipcRenderer.invoke(IPC.gitDiff, root, relativePath),

  runLanguageTool: (request: LanguageToolRequest): Promise<LanguageToolResult> =>
    ipcRenderer.invoke(IPC.languageToolRun, request),

  runLanguageServer: (request: LanguageServerRequest): Promise<LanguageServerResult> =>
    ipcRenderer.invoke(IPC.languageServerRun, request),

  syncLanguageServer: (request: LanguageServerSyncRequest): Promise<void> =>
    ipcRenderer.invoke(IPC.languageServerSync, request),

  stopLanguageServer: (root: string, config: LanguageServerSyncRequest['config']): Promise<void> =>
    ipcRenderer.invoke(IPC.languageServerStop, root, config),

  onLanguageServerDiagnostics: (handler: (event: LanguageServerDiagnosticEvent) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, diagnostic: LanguageServerDiagnosticEvent): void => handler(diagnostic)
    ipcRenderer.on(IPC.languageServerDiagnostics, listener)
    return () => ipcRenderer.removeListener(IPC.languageServerDiagnostics, listener)
  },

  requestLanguageServer: (request: LanguageServerInteractiveRequest): Promise<LanguageServerInteractiveResult> =>
    ipcRenderer.invoke(IPC.languageServerRequest, request),

  onOpenPathRequested: (handler: (filePath: string) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, filePath: string): void => handler(filePath)
    ipcRenderer.on(IPC.openPathRequested, listener)
    return () => ipcRenderer.removeListener(IPC.openPathRequested, listener)
  },

  newWindow: (): Promise<void> => ipcRenderer.invoke(IPC.appNewWindow),

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
