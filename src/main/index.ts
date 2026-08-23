import { app, BrowserWindow } from 'electron'
import path from 'path'
import { fileURLToPath } from 'url'
import { registerFileHandlers } from './files.js'
import { buildMenu } from './menu.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

/** Create the main application window and load the renderer. */
function createWindow(): void {
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
      sandbox: false
    }
  })

  win.on('ready-to-show', () => win.show())

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
    win.loadURL(devUrl)
  } else {
    win.loadFile(path.join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  registerFileHandlers()
  buildMenu()
  createWindow()

  app.on('activate', () => {
    // macOS: re-create a window when the dock icon is clicked and none are open.
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  // Quit on all platforms except macOS, per platform conventions.
  if (process.platform !== 'darwin') app.quit()
})
