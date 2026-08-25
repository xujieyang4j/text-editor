import { app, Menu, shell, BrowserWindow, type MenuItemConstructorOptions } from 'electron'
import { IPC, type MenuEvent, type UiLocale } from '../shared/ipc.js'
import { commandLabel, translate } from '../shared/i18n.js'

let activeLocale: UiLocale = 'zh-CN'

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
  return { label: commandLabel(activeLocale, event, label), accelerator, click: () => emit(event) }
}

/**
 * Build and install the native application menu.
 * Accelerators are wired to renderer events so the editor owns document state.
 */
export function buildMenu(locale: UiLocale = 'zh-CN'): void {
  activeLocale = locale
  const isMac = process.platform === 'darwin'
  const t = (key: Parameters<typeof translate>[1]): string => translate(locale, key)

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
      label: t('file'),
      submenu: [
        item('New File', 'new-file', 'CmdOrCtrl+N'),
        item('New Window', 'new-window', 'CmdOrCtrl+Shift+N'),
        item('Open File…', 'open-file', 'CmdOrCtrl+O'),
        item('Open Folder…', 'open-folder', 'CmdOrCtrl+Shift+O'),
        item('Open Recent File…', 'open-recent-file'),
        item('Open Recent Project…', 'open-recent-project'),
        { type: 'separator' },
        item('Copy File Path', 'copy-file-path'),
        item('Copy Relative File Path', 'copy-relative-file-path'),
        { type: 'separator' },
        item('Save', 'save', 'CmdOrCtrl+S'),
        item('Save As…', 'save-as', 'CmdOrCtrl+Shift+S'),
        item('Save All', 'save-all', 'CmdOrCtrl+Alt+S'),
        item('Cycle Auto Save Mode', 'cycle-auto-save'),
        { type: 'separator' },
        item('Close Tab', 'close-tab', 'CmdOrCtrl+W'),
        item('Close Other Tabs', 'close-other-tabs'),
        item('Close Tabs to the Right', 'close-tabs-to-right'),
        item('Close All Tabs', 'close-all-tabs'),
        item('Reopen Closed Tab', 'reopen-tab', 'CmdOrCtrl+Shift+T'),
        isMac ? { role: 'close' } : { role: 'quit' }
      ]
    },
    {
      label: t('edit'),
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
        item('Toggle Block Comment', 'toggle-block-comment', 'CmdOrCtrl+Shift+/'),
        item('Move Line Up', 'move-line-up', 'Alt+Up'),
        item('Move Line Down', 'move-line-down', 'Alt+Down'),
        item('Copy Line Up', 'copy-line-up', 'Shift+Alt+Up'),
        item('Copy Line Down', 'copy-line-down', 'Shift+Alt+Down'),
        item('Duplicate Line/Selection', 'duplicate-selection', 'CmdOrCtrl+Shift+D'),
        item('Delete Line', 'delete-line', 'CmdOrCtrl+Shift+K'),
        item('Sort Lines', 'sort-lines'),
        item('Upper Case', 'to-upper-case'),
        item('Lower Case', 'to-lower-case'),
        item('Title Case', 'to-title-case'),
        item('Join Lines', 'join-lines'),
        item('Revert Current Change', 'revert-current-change'),
        item('Trim Trailing Whitespace', 'trim-trailing-whitespace'),
        item('Indent Selection', 'indent-selection', 'CmdOrCtrl+]'),
        item('Outdent Selection', 'outdent-selection', 'CmdOrCtrl+['),
        { type: 'separator' },
        item('Find', 'find', 'CmdOrCtrl+F'),
        item('Replace', 'replace', 'CmdOrCtrl+H'),
        item('Find in Files…', 'find-in-files', 'CmdOrCtrl+Shift+F'),
        item('Replace in Files…', 'replace-in-files', 'CmdOrCtrl+Shift+H'),
        item('Undo Last Replace in Files', 'undo-replace-in-files'),
        item('Next Find Result', 'find-results-next', 'F4'),
        item('Previous Find Result', 'find-results-prev', 'Shift+F4')
      ]
    },
    {
      label: t('selection'),
      submenu: [
        // These map to CM6 defaults already bound in-editor; listed for
        // discoverability. selectAll is provided by the Edit role above.
        item('Duplicate Line/Selection', 'duplicate-selection', 'CmdOrCtrl+Shift+D'),
        item('Sort Lines', 'sort-lines'),
        item('Split Selection into Lines', 'split-selection-lines')
        , item('Add Next Occurrence', 'select-next-occurrence', 'CmdOrCtrl+D')
        , item('Select All Occurrences', 'select-all-occurrences', 'Alt+F3')
        , item('Expand Selection', 'expand-selection', 'Shift+Alt+Right')
        , item('Shrink Selection', 'shrink-selection', 'Shift+Alt+Left')
        , item('Add Cursor Above', 'add-cursor-above', 'CmdOrCtrl+Alt+Up')
        , item('Add Cursor Below', 'add-cursor-below', 'CmdOrCtrl+Alt+Down')
      ]
    },
    {
      label: t('goto'),
      submenu: [
        item('Goto Anything…', 'goto-anything', 'CmdOrCtrl+P'),
        item('Goto Symbol…', 'goto-symbol', 'CmdOrCtrl+R'),
        item('Goto Symbol in Project…', 'goto-project-symbol', 'CmdOrCtrl+Shift+R'),
        item('Go to Definition', 'lsp-definition', 'F12'),
        item('Find References', 'lsp-references', 'Shift+F12'),
        item('Goto Line…', 'go-to-line', 'CmdOrCtrl+G'),
        item('Goto Matching Bracket', 'goto-matching-bracket', 'CmdOrCtrl+Shift+\\'),
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
        , { type: 'separator' }
        , item('Next Change', 'next-change', 'CmdOrCtrl+Alt+Shift+Down')
        , item('Previous Change', 'prev-change', 'CmdOrCtrl+Alt+Shift+Up')
      ]
    },
    {
      label: t('view'),
      submenu: [
        item('Command Palette…', 'command-palette', 'CmdOrCtrl+Shift+P'),
        item('Set Syntax…', 'select-language'),
        { type: 'separator' },
        item('Toggle Markdown Preview', 'toggle-preview', 'CmdOrCtrl+Shift+V'),
        item('Open in Browser', 'open-in-browser'),
        { type: 'separator' },
        item('Toggle Sidebar', 'toggle-sidebar', 'CmdOrCtrl+B'),
        item('Toggle Split Editor', 'split-editor', 'CmdOrCtrl+Alt+2'),
        item('Split Selected Tabs into Groups', 'split-selected-tabs'),
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
        item('Toggle Outline', 'toggle-outline'),
        item('Fold Current', 'fold-current'),
        item('Unfold Current', 'unfold-current'),
        item('Fold All', 'fold-all'),
        item('Unfold All', 'unfold-all'),
        item('Distraction Free Mode', 'toggle-distraction-free', 'Shift+F11'),
        item('Toggle Spell Check', 'toggle-spell-check'),
        item('Toggle Word Wrap', 'toggle-word-wrap', 'Alt+Z'),
        item('Toggle Theme', 'toggle-theme', 'CmdOrCtrl+K'),
        item('Select Color Scheme…', 'select-color-scheme'),
        item('Toggle Git Changes', 'toggle-git'),
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
      label: t('tools'),
      submenu: [
        item('Build', 'build', 'CmdOrCtrl+Shift+B'),
        item('Toggle Terminal', 'toggle-terminal', 'CmdOrCtrl+Alt+T'),
        item('Document Statistics', 'document-statistics'),
        item('Format Document', 'format-document'),
        item('Show Hover', 'lsp-hover', 'CmdOrCtrl+Shift+Space'),
        item('Rename Symbol', 'lsp-rename', 'F2'),
        item('Select Build System…', 'select-build-system'),
        item('Import Sublime Build System…', 'import-sublime-build'),
        item('Toggle Build Output', 'toggle-problems'),
        { type: 'separator' },
        item('Format JSON', 'format-json'),
        item('Compact JSON', 'compact-json'),
        item('Toggle JSON View', 'toggle-json-view'),
        item('Configure Language Tool…', 'language-tools'),
        item('Install Local Plugin…', 'install-plugin'),
        item('Import Sublime Snippet…', 'import-sublime-snippet'),
        item('Manage Plugins…', 'manage-plugins'),
        item('Browse Plugin Marketplace…', 'open-marketplace'),
        { type: 'separator' },
        item('Start / Stop Macro Recording', 'record-macro'),
        item('Run Last Macro', 'run-macro'),
        item('Save Last Macro…', 'save-macro'),
        item('Run Saved Macro…', 'run-saved-macro'),
        item('Insert Snippet…', 'insert-snippet')
      ]
    },
    {
      label: t('preferences'),
      submenu: [
        item('Open Settings…', 'open-settings', 'CmdOrCtrl+,'),
        { type: 'separator' },
        item('Import Sublime Settings…', 'import-sublime-settings'),
        item('Import Sublime Keymap…', 'import-sublime-keymap'),
        { type: 'separator' },
        { label: t('languageChinese'), type: 'radio', checked: locale === 'zh-CN', click: () => emit('set-ui-language-zh') },
        { label: t('languageEnglish'), type: 'radio', checked: locale === 'en-US', click: () => emit('set-ui-language-en') }
      ]
    },
    {
      label: t('project'),
      submenu: [
        item('Import Sublime Project…', 'import-sublime-project'),
        item('Add Folder to Project…', 'add-folder-to-project'),
        item('Remove Folder from Project…', 'remove-folder-from-project'),
        item('Open Recent Project…', 'open-recent-project'),
        item('Configure Project…', 'project-settings')
      ]
    },
    {
      label: t('git'),
      submenu: [item('Refresh Changes', 'refresh-git'), item('Open Merge Conflicts', 'open-git-conflicts')]
    },
    {
      label: t('window'),
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
          label: t('learnMore'),
          click: () => shell.openExternal('https://www.electronjs.org')
        },
        item('Check for Updates…', 'check-for-updates')
      ]
    }
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
