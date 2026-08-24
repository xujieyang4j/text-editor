import { app, BrowserWindow, ipcMain, type WebContents } from 'electron'
import path from 'path'
import { fileURLToPath, pathToFileURL } from 'url'
import { authorizePathForRenderer, clearWindowSessionId, listWindowSessionIds, registerFileHandlers, setWindowSessionId } from './files.js'
import { buildMenu } from './menu.js'
import { IPC, type MenuEvent } from '../shared/ipc.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

/** Graceful closes wait for the renderer to persist hot-exit state. */
const pendingSessionFlushes = new Map<WebContents, () => void>()
const flushingWindows = new Set<WebContents>()
let quitRequested = false
let quitting = false
const pendingOpenPaths: string[] = []
const windowSessionIds = new Map<number, string>()
let windowCounter = 0

function newSessionId(): string {
  windowCounter += 1
  return `${Date.now().toString(36)}-${windowCounter.toString(36)}`
}

function sendOpenPath(filePath: string): void {
  if (!path.isAbsolute(filePath)) return
  const win = BrowserWindow.getAllWindows()[0]
  if (!win || win.webContents.isLoading()) {
    pendingOpenPaths.push(filePath)
    return
  }
  authorizePathForRenderer(win.webContents.id, filePath)
  win.webContents.send(IPC.openPathRequested, filePath)
}

/** Electron injects its own executable/app paths into argv; only pass real files through. */
function filePathFromArgv(argv: string[]): string | undefined {
  return argv.find((arg) =>
    path.isAbsolute(arg) &&
    path.resolve(arg) !== path.resolve(process.execPath) &&
    !arg.endsWith('.asar') &&
    !arg.endsWith('.js')
  )
}

function flushWindowSession(win: BrowserWindow, afterFlush: () => void): void {
  const contents = win.webContents
  if (contents.isDestroyed()) {
    afterFlush()
    return
  }
  const timeout = setTimeout(() => {
    if (pendingSessionFlushes.delete(contents)) afterFlush()
  }, 1_500)
  pendingSessionFlushes.set(contents, () => {
    clearTimeout(timeout)
    afterFlush()
  })
  contents.send(IPC.menuEvent, 'persist-session' as MenuEvent)
}

function allowAppNavigation(win: BrowserWindow): void {
  const packagedEntry = pathToFileURL(path.join(__dirname, '../renderer/index.html')).href
  win.webContents.on('will-navigate', (event, url) => {
    // The editor is a local app. All untrusted links are opened externally by
    // the preview click handler; never let remote content inherit our preload.
    const devUrl = process.env['ELECTRON_RENDERER_URL']
    const allowed = devUrl ? url.startsWith(devUrl) : url === packagedEntry
    if (!allowed) event.preventDefault()
  })
  win.webContents.setWindowOpenHandler(({ url }) => {
    // Never create a renderer window for external content. The renderer uses
    // the typed shell bridge for http(s)/mailto URLs it explicitly permits.
    console.warn(`Blocked window.open request: ${url}`)
    return { action: 'deny' }
  })
}

/** Create the main application window and load the renderer. */
function createWindow(sessionId = newSessionId()): void {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 640,
    minHeight: 480,
    show: false,
    backgroundColor: '#1e1e1e',
    title: 'Lumen Editor',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.cjs'),
      // Security: keep the renderer sandboxed from Node.
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  allowAppNavigation(win)
  windowSessionIds.set(win.webContents.id, sessionId)
  setWindowSessionId(win.webContents.id, sessionId)

  // A direct window close bypasses `before-quit` on some platform paths.
  // Flush the renderer session here and only then let Electron destroy it.
  win.on('close', (event) => {
    if (quitting || flushingWindows.has(win.webContents)) return
    event.preventDefault()
    flushWindowSession(win, () => {
      flushingWindows.add(win.webContents)
      if (!win.isDestroyed()) win.close()
    })
  })

  win.on('ready-to-show', () => win.show())
  win.on('closed', () => {
    windowSessionIds.delete(win.webContents.id)
    clearWindowSessionId(win.webContents.id)
  })
  win.webContents.once('did-finish-load', () => {
    for (const filePath of pendingOpenPaths.splice(0)) {
      authorizePathForRenderer(win.webContents.id, filePath)
      win.webContents.send(IPC.openPathRequested, filePath)
    }
  })

  // Smoke-test hook: when LUMEN_SMOKE=1 we quit as soon as the renderer has
  // finished loading. This lets CI/headless environments verify the full boot
  // path (main → preload → renderer) without a human at the keyboard.
  if (process.env['LUMEN_SMOKE'] === '1') {
    win.webContents.once('did-finish-load', () => {
      console.log('[smoke] renderer finished loading')
      setTimeout(() => app.quit(), 500)
    })
    win.webContents.on('render-process-gone', (_e, details) => {
      console.error('[smoke] renderer gone:', details.reason)
      process.exit(1)
    })
  }

  // electron-vite sets ELECTRON_RENDERER_URL in dev; load the file in prod.
  const devUrl = process.env['ELECTRON_RENDERER_URL']
  if (devUrl) {
    const target = new URL(devUrl)
    target.hash = `window=${sessionId}`
    win.loadURL(target.href)
  } else {
    win.loadFile(path.join(__dirname, '../renderer/index.html'), { hash: `window=${sessionId}` })
  }
}

const gotSingleInstanceLock = app.requestSingleInstanceLock()
if (!gotSingleInstanceLock) {
  app.quit()
} else {
app.on('second-instance', (_event, argv) => {
  const filePath = filePathFromArgv(argv)
  const win = BrowserWindow.getAllWindows()[0]
  if (win) {
    if (win.isMinimized()) win.restore()
    win.focus()
  }
  if (filePath) sendOpenPath(filePath)
})

app.on('open-file', (event, filePath) => {
  event.preventDefault()
  sendOpenPath(filePath)
})

app.whenReady().then(() => {
  registerFileHandlers()
  ipcMain.handle(IPC.appNewWindow, (event) => {
    const win = BrowserWindow.fromWebContents(event.sender)
    if (win) createWindow()
  })
  ipcMain.handle(IPC.sessionFlushed, (event) => {
    pendingSessionFlushes.get(event.sender)?.()
    pendingSessionFlushes.delete(event.sender)
  })
  buildMenu()
  void listWindowSessionIds().then((sessions) => {
    if (sessions.length === 0) createWindow('legacy')
    else for (const sessionId of sessions) createWindow(sessionId)
  })
  const initialPath = filePathFromArgv(process.argv)
  if (initialPath) sendOpenPath(initialPath)

  app.on('activate', () => {
    // macOS: re-create a window when the dock icon is clicked and none are open.
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})
}

app.on('before-quit', (event) => {
  if (quitting) return
  event.preventDefault()
  quitRequested = true
  const windows = BrowserWindow.getAllWindows()
  if (windows.length === 0) {
    quitting = true
    app.quit()
    return
  }
  for (const win of windows) win.close()
})

app.on('window-all-closed', () => {
  // A user-initiated Quit must also exit on macOS; ordinary window closes keep
  // the conventional macOS app lifecycle.
  if (quitRequested || process.platform !== 'darwin') {
    quitting = true
    app.quit()
  }
})
