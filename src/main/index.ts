import { app, BrowserWindow, ipcMain, type WebContents } from 'electron'
import path from 'path'
import { fileURLToPath, pathToFileURL } from 'url'
import { authorizePathForRenderer, authorizeWorkspaceForRenderer, clearWindowSessionId, listWindowSessionIds, registerFileHandlers, setWindowSessionId } from './files.js'
import { buildMenu } from './menu.js'
import { IPC, type MenuEvent } from '../shared/ipc.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// GUI smoke tests exercise real settings, session persistence and IPC. Keep
// their transient application data outside a developer's normal profile so a
// test cannot change their restored tabs, locale or other preferences.
if (process.env['LUMEN_SMOKE'] === '1') {
  app.setPath('userData', path.join(app.getPath('temp'), `lumen-editor-smoke-${process.pid}-${Date.now().toString(36)}`))
}

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

  // Smoke-test hook: exercise a real CodeMirror edit before quitting, rather
  // than treating merely loading index.html as a GUI success.
  if (process.env['LUMEN_SMOKE'] === '1') {
    win.webContents.on('console-message', (_event, level, message, line, sourceId) => {
      if (level >= 2) console.error(`[smoke renderer:${level}] ${sourceId}:${line} ${message}`)
    })
    win.webContents.once('did-finish-load', async () => {
      try {
        const smokeRoot = process.cwd()
        authorizeWorkspaceForRenderer(win.webContents.id, smokeRoot)
        const initialUi = await win.webContents.executeJavaScript(`(async () => {
          const deadline = Date.now() + 3_000
          let editor = document.querySelector('.cm-content')
          while (!(editor instanceof HTMLElement) && Date.now() < deadline) {
            await new Promise((resolve) => window.setTimeout(resolve, 25))
            editor = document.querySelector('.cm-content')
          }
          if (!(editor instanceof HTMLElement)) return { editorMounted: false, terminalPanelMounted: false, terminalStartDisabledInitially: false, outlinePanelMounted: false }
          editor.focus()
          const terminalCommand = [...document.querySelectorAll('button')].find((button) =>
            /^(启动|Start)$/.test(button.textContent?.trim() ?? '')
          )
          const terminalPanel = document.querySelector('.terminal-panel')
          const outlinePanel = document.querySelector('.outline-panel')
          const languageButton = document.querySelector('#status-language')
          const a11yStatus = document.querySelector('#a11y-status')
          const a11yAlert = document.querySelector('#a11y-alert')
          return {
            editorMounted: true,
            terminalPanelMounted: terminalPanel instanceof HTMLElement && terminalPanel.classList.contains('hidden'),
            terminalStartAvailableInitially: terminalCommand instanceof HTMLButtonElement && !terminalCommand.disabled,
            outlinePanelMounted: outlinePanel instanceof HTMLElement && outlinePanel.classList.contains('hidden'),
            accessibilityMounted: languageButton instanceof HTMLButtonElement
              && a11yStatus?.getAttribute('role') === 'status'
              && a11yAlert?.getAttribute('role') === 'alert'
          }
        })()`, true)
        if (!initialUi.editorMounted) throw new Error('CodeMirror did not mount')
        if (!initialUi.terminalPanelMounted || !initialUi.terminalStartAvailableInitially || !initialUi.outlinePanelMounted) {
          throw new Error(`Terminal or outline panel did not mount with its expected initial state: ${JSON.stringify(initialUi)}`)
        }
        if (!initialUi.accessibilityMounted) throw new Error('Accessibility status regions or language button did not mount')
        const accessibilityPrepared = await win.webContents.executeJavaScript(`(() => {
          const languageButton = document.querySelector('#status-language')
          if (!(languageButton instanceof HTMLButtonElement)) return false
          languageButton.focus()
          return document.activeElement === languageButton
        })()`, true)
        if (!accessibilityPrepared) throw new Error('Could not prepare command palette accessibility test')
        win.webContents.send(IPC.menuEvent, 'command-palette' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 50))
        const accessibilityResult = await win.webContents.executeJavaScript(`(() => {
          const languageButton = document.querySelector('#status-language')
          const dialog = document.querySelector('.palette-overlay')
          const combo = dialog?.querySelector('[role="combobox"]')
          const activeId = combo?.getAttribute('aria-activedescendant')
          const active = activeId ? document.getElementById(activeId) : null
          if (!(dialog instanceof HTMLElement) || dialog.getAttribute('aria-modal') !== 'true' ||
            !(combo instanceof HTMLInputElement) || !active || active.getAttribute('aria-selected') !== 'true') return false
          combo.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
          return languageButton instanceof HTMLButtonElement
            && dialog.classList.contains('hidden')
            && document.activeElement === languageButton
        })()`, true)
        if (!accessibilityResult) throw new Error('Command palette accessibility lifecycle failed')
        await win.webContents.executeJavaScript(`document.querySelector('.cm-content')?.focus()`, true)
        await win.webContents.insertText('smoke')
        const editorAcceptedInput = await win.webContents.executeJavaScript(`document.querySelector('.cm-content')?.textContent?.includes('smoke') === true`, true)
        if (!editorAcceptedInput) throw new Error('CodeMirror did not receive smoke input')
        win.webContents.send(IPC.menuEvent, 'new-file' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 80))
        const tabDragResult = await win.webContents.executeJavaScript(`(() => {
          const tabs = [...document.querySelectorAll('#tab-bar > .tab')]
          if (tabs.length < 2 || !tabs.every((tab) => tab.draggable)) return false
          const before = tabs.map((tab) => tab.querySelector('.tab-label')?.textContent ?? '')
          const source = tabs[1]
          const target = tabs[0]
          const transfer = new DataTransfer()
          source.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: transfer }))
          target.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, clientX: -1, dataTransfer: transfer }))
          target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, clientX: -1, dataTransfer: transfer }))
          const after = [...document.querySelectorAll('#tab-bar > .tab')].map((tab) => tab.querySelector('.tab-label')?.textContent ?? '')
          return after[0] === before[1] && after[1] === before[0]
        })()`, true)
        if (!tabDragResult) throw new Error('Tab drag-and-drop did not reorder the tab bar')
        const tabCloseResult = await win.webContents.executeJavaScript(`(async () => {
          const activeClose = document.querySelector('#tab-bar > .tab.active .tab-close')
          if (!(activeClose instanceof HTMLButtonElement)) return { preservedAdjacentContent: false, freshUntitled: false }
          activeClose.click()
          await new Promise((resolve) => window.setTimeout(resolve, 80))
          const adjacentContent = document.querySelector('.cm-content')?.textContent ?? ''
          const adjacentLabel = document.querySelector('#tab-bar > .tab.active .tab-label')?.textContent ?? ''
          const preservedAdjacentContent = adjacentContent.includes('smoke')
          const remainingClose = document.querySelector('#tab-bar > .tab.active .tab-close')
          if (!(remainingClose instanceof HTMLButtonElement)) return { preservedAdjacentContent, freshUntitled: false }
          const originalConfirm = window.confirm
          window.confirm = () => true
          remainingClose.click()
          window.confirm = originalConfirm
          await new Promise((resolve) => window.setTimeout(resolve, 80))
          const tabs = [...document.querySelectorAll('#tab-bar > .tab')]
          const freshUntitled = tabs.length === 1
            && tabs[0].querySelector('.tab-label')?.textContent === 'Untitled-1'
            && document.querySelector('.cm-content')?.textContent === ''
          return { preservedAdjacentContent, adjacentContent, adjacentLabel, freshUntitled }
        })()`, true)
        if (!tabCloseResult.preservedAdjacentContent || !tabCloseResult.freshUntitled) {
          throw new Error(`Tab close lifecycle failed: ${JSON.stringify(tabCloseResult)}`)
        }
        const selectionResult = await win.webContents.executeJavaScript(`(async () => {
          const content = document.querySelector('.cm-content')
          if (!(content instanceof HTMLElement)) return false
          content.focus()
          document.execCommand('insertText', false, ${JSON.stringify('alpha\nbeta\ngamma')})
          document.execCommand('selectAll')
          await new Promise((resolve) => window.setTimeout(resolve, 20))
          return true
        })()`, true)
        if (!selectionResult) throw new Error('Could not prepare multi-cursor smoke test')
        win.webContents.send(IPC.menuEvent, 'add-cursors-line-ends' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 50))
        await win.webContents.insertText('!')
        const editorTextScript = `[...document.querySelectorAll('.cm-content .cm-line')].map((line) => line.textContent ?? '').join(${JSON.stringify('\n')})`
        const multiCursorText = await win.webContents.executeJavaScript(editorTextScript, true)
        if (multiCursorText !== 'alpha!\nbeta!\ngamma!') throw new Error(`Line-end cursors failed: ${JSON.stringify(multiCursorText)}`)
        win.webContents.send(IPC.menuEvent, 'undo-selection' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 50))
        const textAfterSelectionUndo = await win.webContents.executeJavaScript(editorTextScript, true)
        if (textAfterSelectionUndo !== multiCursorText) {
          throw new Error(`Selection undo changed document text: ${JSON.stringify(textAfterSelectionUndo)}`)
        }
        // The default profile has outline hidden; this explicit event verifies
        // its menu path without altering normal user settings (smoke userData
        // is isolated above).
        win.webContents.send(IPC.menuEvent, 'toggle-outline' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 120))
        const outlineResult = await win.webContents.executeJavaScript(`(() => {
          const panel = document.querySelector('.outline-panel')
          return panel instanceof HTMLElement && !panel.classList.contains('hidden')
        })()`, true)
        if (!outlineResult) throw new Error('Outline did not open from its menu event')
        win.webContents.send(IPC.menuEvent, 'open-settings' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 80))
        const settingsResult = await win.webContents.executeJavaScript(`(() => {
          const panel = document.querySelector('.settings-panel')
          const fontSize = panel?.querySelector('input[data-setting="fontSize"]')
          const editor = document.querySelector('.cm-editor')
          if (!(panel instanceof HTMLElement) || panel.classList.contains('hidden') || !(fontSize instanceof HTMLInputElement) || !(editor instanceof HTMLElement)) return false
          fontSize.value = '17'
          fontSize.dispatchEvent(new Event('change', { bubbles: true }))
          return getComputedStyle(editor).fontSize === '17px'
        })()`, true)
        if (!settingsResult) throw new Error('Settings panel did not apply a font-size change')
        const settingsA11yResult = await win.webContents.executeJavaScript(`(() => {
          const panel = document.querySelector('.settings-panel')
          if (!(panel instanceof HTMLElement)) return false
          const label = panel.getAttribute('aria-labelledby')
          const title = label ? document.getElementById(label) : null
          panel.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
          return !!title?.textContent && panel.classList.contains('hidden') && panel.getAttribute('aria-hidden') === 'true'
        })()`, true)
        if (!settingsA11yResult) throw new Error('Settings panel accessibility lifecycle failed')
        const sidebarA11yResult = await win.webContents.executeJavaScript(`(() => {
          const sidebar = document.querySelector('#sidebar')
          if (!(sidebar instanceof HTMLElement) || sidebar.classList.contains('hidden') || sidebar.inert) return false
          const focusable = document.createElement('button')
          focusable.textContent = 'smoke-focus'
          sidebar.appendChild(focusable)
          focusable.focus()
          return document.activeElement === focusable
        })()`, true)
        if (!sidebarA11yResult) throw new Error('Could not prepare sidebar focus test')
        win.webContents.send(IPC.menuEvent, 'toggle-sidebar' as MenuEvent)
        await new Promise<void>((resolve) => setTimeout(resolve, 30))
        const sidebarFocusResult = await win.webContents.executeJavaScript(`(() => {
          const sidebar = document.querySelector('#sidebar')
          const active = document.activeElement
          return sidebar instanceof HTMLElement && sidebar.inert && sidebar.getAttribute('aria-hidden') === 'true'
            && active instanceof HTMLElement && !sidebar.contains(active)
        })()`, true)
        if (!sidebarFocusResult) throw new Error('Sidebar hid without moving focus out of its inert subtree')
        const copiedPath = await win.webContents.executeJavaScript(`(async () => {
          try {
            await window.editor.copyPath(${JSON.stringify(path.join(process.cwd(), 'package.json'))})
            await window.editor.copyPath(${JSON.stringify(path.join(process.cwd(), 'package.json'))}, ${JSON.stringify(smokeRoot)})
            return true
          } catch {
            return false
          }
        })()`, true)
        if (!copiedPath) throw new Error('Authorised path could not be copied to the clipboard')
        const terminalSmokeScript = [
          '(() => {',
          '  const api = window.editor',
          "  const sessionId = 'terminal-smoke-session-0001'",
          "  const marker = 'LUMEN_TERMINAL_SMOKE_OK'",
          '  return new Promise((resolve, reject) => {',
          '    let unsubscribe = () => {}',
          '    const timeout = window.setTimeout(() => {',
          '      unsubscribe()',
          "      void api.stopTerminal(sessionId).finally(() => reject(new Error('Timed out waiting for terminal output')))",
          '    }, 5000)',
          '    unsubscribe = api.onTerminalOutput((output) => {',
          '      if (output.sessionId !== sessionId || !output.text.includes(marker)) return',
          '      window.clearTimeout(timeout)',
          '      unsubscribe()',
          '      void api.stopTerminal(sessionId).then(() => resolve(true), reject)',
          '    })',
          '    void (async () => {',
          '      try {',
          '        await api.startTerminal(' + JSON.stringify(smokeRoot) + ', sessionId)',
          '        await api.writeTerminal(sessionId, "echo " + marker + String.fromCharCode(10))',
          '      } catch (error) {',
          '        window.clearTimeout(timeout)',
          '        unsubscribe()',
          '        reject(error)',
          '      }',
          '    })()',
          '  })',
          '})()'
        ].join('\n')
        const terminalResult = await win.webContents.executeJavaScript(terminalSmokeScript, true)
        if (!terminalResult) throw new Error('Terminal did not echo its smoke marker')
        await win.webContents.executeJavaScript(`window.editor.releaseWorkspace(${JSON.stringify(smokeRoot)}, [])`, true)
        console.log('[smoke] renderer, editor, and controlled terminal passed')
        setTimeout(() => app.quit(), 250)
      } catch (error) {
        console.error('[smoke] GUI interaction failed:', error)
        process.exit(1)
      }
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
  buildMenu('zh-CN')
  ipcMain.handle(IPC.menuSetLocale, (_event, locale: unknown) => {
    buildMenu(locale === 'en-US' ? 'en-US' : 'zh-CN')
  })
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
