import { dialog, ipcMain, BrowserWindow, app, shell } from 'electron'
import { promises as fs } from 'fs'
import path from 'path'
import { pathToFileURL } from 'url'
import {
  IPC,
  DEFAULT_SETTINGS,
  EMPTY_SESSION,
  type OpenedFile,
  type SaveResult,
  type OpenedFolder,
  type DirEntry,
  type Settings,
  type Session
} from '../shared/ipc.js'

/** Directory entries that are noisy and rarely useful in a file tree. */
const IGNORED_ENTRIES = new Set([
  '.git',
  'node_modules',
  '.DS_Store',
  '.cache',
  'dist',
  'out',
  'release',
  '.npm-cache'
])

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

/**
 * Recursively list all files under a root (used by Goto Anything).
 * Bounded by a file cap and depth to stay responsive on huge trees.
 */
async function listFilesRecursive(root: string): Promise<string[]> {
  const MAX_FILES = 20000
  const results: string[] = []

  async function walk(dir: string, depth: number): Promise<void> {
    if (results.length >= MAX_FILES || depth > 20) return
    let dirents: import('fs').Dirent[]
    try {
      dirents = await fs.readdir(dir, { withFileTypes: true })
    } catch {
      return // unreadable dir — skip silently
    }
    for (const d of dirents) {
      if (IGNORED_ENTRIES.has(d.name)) continue
      const full = path.join(dir, d.name)
      if (d.isDirectory()) {
        await walk(full, depth + 1)
      } else if (d.isFile()) {
        results.push(full)
        if (results.length >= MAX_FILES) return
      }
    }
  }

  await walk(root, 0)
  return results
}

/** Read a single file from disk as UTF-8 text. */
async function readFile(filePath: string): Promise<OpenedFile> {
  const content = await fs.readFile(filePath, 'utf-8')
  return { path: filePath, content }
}

/** Absolute path to a JSON file living in the app's userData directory. */
function userDataFile(name: string): string {
  return path.join(app.getPath('userData'), name)
}

/** Read + parse a JSON file, returning `fallback` on any error. */
async function readJson<T>(file: string, fallback: T): Promise<T> {
  try {
    const raw = await fs.readFile(file, 'utf-8')
    return { ...fallback, ...(JSON.parse(raw) as Partial<T>) }
  } catch {
    return fallback
  }
}

/**
 * Serialise + write a JSON file atomically.
 *
 * Writes to a temp file then renames over the target, so a crash or power loss
 * mid-write can never leave a truncated/corrupt file — important because this
 * backs hot-exit session recovery. `rename` is atomic on the same filesystem.
 */
async function writeJson(file: string, data: unknown): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  await fs.writeFile(tmp, JSON.stringify(data, null, 2), 'utf-8')
  await fs.rename(tmp, file)
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

  // Recursively list files under a root — used by Goto Anything.
  ipcMain.handle(IPC.dirListFiles, async (_event, root: string): Promise<string[]> => {
    return listFilesRecursive(root)
  })

  // Open a saved file in the system default browser (e.g. HTML preview).
  // Returns false when the path is missing/unsaved so the renderer can prompt.
  ipcMain.handle(IPC.openInBrowser, async (_event, filePath: string | null): Promise<boolean> => {
    if (!filePath) return false
    await shell.openExternal(pathToFileURL(filePath).href)
    return true
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

  // ---- Settings & session persistence (JSON in userData) ----
  ipcMain.handle(IPC.settingsRead, async (): Promise<Settings> => {
    return readJson<Settings>(userDataFile('settings.json'), DEFAULT_SETTINGS)
  })

  ipcMain.handle(IPC.settingsWrite, async (_event, settings: Settings): Promise<void> => {
    await writeJson(userDataFile('settings.json'), settings)
  })

  ipcMain.handle(IPC.sessionRead, async (): Promise<Session> => {
    return readJson<Session>(userDataFile('session.json'), EMPTY_SESSION)
  })

  ipcMain.handle(IPC.sessionWrite, async (_event, session: Session): Promise<void> => {
    await writeJson(userDataFile('session.json'), session)
  })
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
