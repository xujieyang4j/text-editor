import { dialog, ipcMain, BrowserWindow } from 'electron'
import { promises as fs } from 'fs'
import path from 'path'
import {
  IPC,
  type OpenedFile,
  type SaveResult,
  type OpenedFolder,
  type DirEntry
} from '../shared/ipc.js'

/** Directory entries that are noisy and rarely useful in a file tree. */
const IGNORED_ENTRIES = new Set(['.git', 'node_modules', '.DS_Store'])

/** Read a directory and return its immediate children, folders first. */
async function readDirectory(dirPath: string): Promise<DirEntry[]> {
  const dirents = await fs.readdir(dirPath, { withFileTypes: true })
  const entries: DirEntry[] = dirents
    .filter((d) => !IGNORED_ENTRIES.has(d.name))
    .map((d) => ({
      name: d.name,
      path: path.join(dirPath, d.name),
      isDirectory: d.isDirectory()
    }))

  entries.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
    return a.name.localeCompare(b.name)
  })

  return entries
}

/** Read a single file from disk as UTF-8 text. */
async function readFile(filePath: string): Promise<OpenedFile> {
  const content = await fs.readFile(filePath, 'utf-8')
  return { path: filePath, content }
}

/**
 * Register all file-system related IPC handlers.
 * The renderer never touches `fs` directly; every operation flows through here.
 */
export function registerFileHandlers(): void {
  // Show an open-file dialog and return the chosen file's contents.
  ipcMain.handle(IPC.fileOpen, async (event): Promise<OpenedFile | null> => {
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, {
      properties: ['openFile'],
      title: 'Open File'
    })
    if (result.canceled || result.filePaths.length === 0) return null
    return readFile(result.filePaths[0])
  })

  // Open a file by an already-known path (e.g. clicked in the file tree).
  ipcMain.handle(IPC.fileOpenPath, async (_event, filePath: string): Promise<OpenedFile> => {
    return readFile(filePath)
  })

  // Show an open-folder dialog and return the root plus its top-level entries.
  ipcMain.handle(IPC.folderOpen, async (event): Promise<OpenedFolder | null> => {
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, {
      properties: ['openDirectory'],
      title: 'Open Folder'
    })
    if (result.canceled || result.filePaths.length === 0) return null
    const root = result.filePaths[0]
    return { root, entries: await readDirectory(root) }
  })

  // Lazily read a directory's children — used to expand tree nodes on demand.
  ipcMain.handle(IPC.dirRead, async (_event, dirPath: string): Promise<DirEntry[]> => {
    return readDirectory(dirPath)
  })

  // Save content to a known path. If no path is provided, fall through to save-as.
  ipcMain.handle(
    IPC.fileSave,
    async (event, filePath: string | null, content: string): Promise<SaveResult> => {
      if (!filePath) {
        return saveAs(event.sender, content)
      }
      await fs.writeFile(filePath, content, 'utf-8')
      return { saved: true, path: filePath }
    }
  )

  // Always prompt for a destination path, then write.
  ipcMain.handle(
    IPC.fileSaveAs,
    async (event, content: string, suggestedName?: string): Promise<SaveResult> => {
      return saveAs(event.sender, content, suggestedName)
    }
  )
}

/** Shared save-as implementation used by both save (untitled) and explicit save-as. */
async function saveAs(
  sender: Electron.WebContents,
  content: string,
  suggestedName?: string
): Promise<SaveResult> {
  const win = BrowserWindow.fromWebContents(sender)
  const result = await dialog.showSaveDialog(win!, {
    title: 'Save File',
    defaultPath: suggestedName
  })
  if (result.canceled || !result.filePath) return { saved: false }
  await fs.writeFile(result.filePath, content, 'utf-8')
  return { saved: true, path: result.filePath }
}
