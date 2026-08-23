import { app, Menu, shell, BrowserWindow, type MenuItemConstructorOptions } from 'electron'
import { IPC, type MenuEvent } from '../shared/ipc.js'

/** Send a menu-driven command to the focused window's renderer. */
function emit(event: MenuEvent): void {
  const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
  win?.webContents.send(IPC.menuEvent, event)
}

/**
 * Build and install the native application menu.
 * Accelerators are wired to renderer events so the editor owns document state.
 */
export function buildMenu(): void {
  const isMac = process.platform === 'darwin'

  const template: MenuItemConstructorOptions[] = [
    // macOS gets the standard app menu as the first item.
    ...(isMac
      ? ([
          {
            label: app.name,
            submenu: [
              { role: 'about' },
              { type: 'separator' },
              { role: 'services' },
              { type: 'separator' },
              { role: 'hide' },
              { role: 'hideOthers' },
              { role: 'unhide' },
              { type: 'separator' },
              { role: 'quit' }
            ]
          }
        ] as MenuItemConstructorOptions[])
      : []),
    {
      label: 'File',
      submenu: [
        {
          label: 'New File',
          accelerator: 'CmdOrCtrl+N',
          click: () => emit('new-file')
        },
        {
          label: 'Open File…',
          accelerator: 'CmdOrCtrl+O',
          click: () => emit('open-file')
        },
        {
          label: 'Open Folder…',
          accelerator: 'CmdOrCtrl+Shift+O',
          click: () => emit('open-folder')
        },
        { type: 'separator' },
        {
          label: 'Save',
          accelerator: 'CmdOrCtrl+S',
          click: () => emit('save')
        },
        {
          label: 'Save As…',
          accelerator: 'CmdOrCtrl+Shift+S',
          click: () => emit('save-as')
        },
        { type: 'separator' },
        {
          label: 'Close Tab',
          accelerator: 'CmdOrCtrl+W',
          click: () => emit('close-tab')
        },
        isMac ? { role: 'close' } : { role: 'quit' }
      ]
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
        { type: 'separator' },
        {
          label: 'Find',
          accelerator: 'CmdOrCtrl+F',
          click: () => emit('find')
        },
        {
          label: 'Replace',
          accelerator: 'CmdOrCtrl+H',
          click: () => emit('replace')
        },
        {
          label: 'Go to Line…',
          accelerator: 'CmdOrCtrl+G',
          click: () => emit('go-to-line')
        }
      ]
    },
    {
      label: 'View',
      submenu: [
        {
          label: 'Command Palette…',
          accelerator: 'CmdOrCtrl+Shift+P',
          click: () => emit('command-palette')
        },
        { type: 'separator' },
        {
          label: 'Toggle Sidebar',
          accelerator: 'CmdOrCtrl+B',
          click: () => emit('toggle-sidebar')
        },
        {
          label: 'Toggle Word Wrap',
          accelerator: 'Alt+Z',
          click: () => emit('toggle-word-wrap')
        },
        {
          label: 'Toggle Theme',
          accelerator: 'CmdOrCtrl+K',
          click: () => emit('toggle-theme')
        },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { role: 'toggleDevTools' }
      ]
    },
    {
      label: 'Go',
      submenu: [
        {
          label: 'Next Tab',
          accelerator: 'CmdOrCtrl+Alt+Right',
          click: () => emit('next-tab')
        },
        {
          label: 'Previous Tab',
          accelerator: 'CmdOrCtrl+Alt+Left',
          click: () => emit('prev-tab')
        }
      ]
    },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        ...(isMac
          ? ([
              { type: 'separator' },
              { role: 'front' }
            ] as MenuItemConstructorOptions[])
          : ([{ role: 'close' }] as MenuItemConstructorOptions[]))
      ]
    },
    {
      role: 'help',
      submenu: [
        {
          label: 'Learn More',
          click: () => shell.openExternal('https://www.electronjs.org')
        }
      ]
    }
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
