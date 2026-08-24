import { app, Menu, shell, BrowserWindow, type MenuItemConstructorOptions } from 'electron'
import { IPC, type MenuEvent } from '../shared/ipc.js'

/** Send a menu-driven command to the focused window's renderer. */
function emit(event: MenuEvent): void {
  const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
  win?.webContents.send(IPC.menuEvent, event)
}

/** Small helper to define a command menu item that emits a renderer event. */
function item(
  label: string,
  event: MenuEvent,
  accelerator?: string
): MenuItemConstructorOptions {
  return { label, accelerator, click: () => emit(event) }
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
        item('New File', 'new-file', 'CmdOrCtrl+N'),
        item('New Window', 'new-window', 'CmdOrCtrl+Shift+N'),
        item('Open File…', 'open-file', 'CmdOrCtrl+O'),
        item('Open Folder…', 'open-folder', 'CmdOrCtrl+Shift+O'),
        { type: 'separator' },
        item('Save', 'save', 'CmdOrCtrl+S'),
        item('Save As…', 'save-as', 'CmdOrCtrl+Shift+S'),
        { type: 'separator' },
        item('Close Tab', 'close-tab', 'CmdOrCtrl+W'),
        item('Reopen Closed Tab', 'reopen-tab', 'CmdOrCtrl+Shift+T'),
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
        item('Toggle Comment', 'toggle-comment', 'CmdOrCtrl+/'),
        item('Move Line Up', 'move-line-up', 'Alt+Up'),
        item('Move Line Down', 'move-line-down', 'Alt+Down'),
        item('Copy Line Up', 'copy-line-up', 'Shift+Alt+Up'),
        item('Copy Line Down', 'copy-line-down', 'Shift+Alt+Down'),
        item('Duplicate Line/Selection', 'duplicate-selection', 'CmdOrCtrl+Shift+D'),
        item('Delete Line', 'delete-line', 'CmdOrCtrl+Shift+K'),
        item('Sort Lines', 'sort-lines'),
        { type: 'separator' },
        item('Find', 'find', 'CmdOrCtrl+F'),
        item('Replace', 'replace', 'CmdOrCtrl+H'),
        item('Find in Files…', 'find-in-files', 'CmdOrCtrl+Shift+F'),
        item('Replace in Files…', 'replace-in-files', 'CmdOrCtrl+Shift+H'),
        item('Next Find Result', 'find-results-next', 'F4'),
        item('Previous Find Result', 'find-results-prev', 'Shift+F4')
      ]
    },
    {
      label: 'Selection',
      submenu: [
        // These map to CM6 defaults already bound in-editor; listed for
        // discoverability. selectAll is provided by the Edit role above.
        item('Duplicate Line/Selection', 'duplicate-selection', 'CmdOrCtrl+Shift+D'),
        item('Sort Lines', 'sort-lines')
      ]
    },
    {
      label: 'Goto',
      submenu: [
        item('Goto Anything…', 'goto-anything', 'CmdOrCtrl+P'),
        item('Goto Symbol…', 'goto-symbol', 'CmdOrCtrl+R'),
        item('Goto Symbol in Project…', 'goto-project-symbol', 'CmdOrCtrl+Shift+R'),
        item('Goto Line…', 'go-to-line', 'CmdOrCtrl+G'),
        { type: 'separator' },
        item('Back', 'navigate-back', 'Alt+Left'),
        item('Forward', 'navigate-forward', 'Alt+Right'),
        { type: 'separator' },
        item('Next Tab', 'next-tab', 'CmdOrCtrl+Alt+Right'),
        item('Previous Tab', 'prev-tab', 'CmdOrCtrl+Alt+Left'),
        { type: 'separator' },
        item('Toggle Bookmark', 'toggle-bookmark', 'CmdOrCtrl+F2'),
        item('Next Bookmark', 'next-bookmark', 'F2'),
        item('Previous Bookmark', 'prev-bookmark', 'Shift+F2')
      ]
    },
    {
      label: 'View',
      submenu: [
        item('Command Palette…', 'command-palette', 'CmdOrCtrl+Shift+P'),
        item('Set Syntax…', 'select-language'),
        { type: 'separator' },
        item('Toggle Markdown Preview', 'toggle-preview', 'CmdOrCtrl+Shift+V'),
        item('Open in Browser', 'open-in-browser'),
        { type: 'separator' },
        item('Toggle Sidebar', 'toggle-sidebar', 'CmdOrCtrl+B'),
        item('Toggle Split Editor', 'split-editor', 'CmdOrCtrl+Alt+2'),
        { type: 'separator' },
        item('Layout: Single', 'layout-single'),
        item('Layout: Columns 2', 'layout-columns2'),
        item('Layout: Columns 3', 'layout-columns3'),
        item('Layout: Grid 4', 'layout-grid4'),
        item('Move File to Next Group', 'move-file-next-group'),
        item('Clone File to Next Group', 'clone-file-next-group'),
        item('Focus Next Group', 'focus-next-group', 'CmdOrCtrl+Alt+]'),
        item('Focus Previous Group', 'focus-prev-group', 'CmdOrCtrl+Alt+['),
        item('Toggle Minimap', 'toggle-minimap'),
        item('Toggle Word Wrap', 'toggle-word-wrap', 'Alt+Z'),
        item('Toggle Theme', 'toggle-theme', 'CmdOrCtrl+K'),
        { type: 'separator' },
        item('Zoom In', 'font-zoom-in', 'CmdOrCtrl+='),
        item('Zoom Out', 'font-zoom-out', 'CmdOrCtrl+-'),
        item('Reset Zoom', 'font-zoom-reset', 'CmdOrCtrl+0'),
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { role: 'toggleDevTools' }
      ]
    },
    {
      label: 'Tools',
      submenu: [
        item('Build', 'build', 'CmdOrCtrl+Shift+B'),
        item('Format Document', 'format-document'),
        item('Toggle Build Output', 'toggle-problems'),
        item('Configure Language Tool…', 'language-tools'),
        item('Install Local Plugin…', 'install-plugin'),
        item('Manage Plugins…', 'manage-plugins'),
        { type: 'separator' },
        item('Start / Stop Macro Recording', 'record-macro'),
        item('Run Last Macro', 'run-macro'),
        item('Insert Snippet…', 'insert-snippet')
      ]
    },
    {
      label: 'Project',
      submenu: [item('Configure Project…', 'project-settings')]
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
