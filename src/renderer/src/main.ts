import { Editor, allLanguageNames } from './editor.js'
import { FileTree } from './fileTree.js'
import { Palette, type PaletteItem } from './palette.js'
import { WorkspaceSearchPanel } from './workspaceSearch.js'
import { BuildPanel } from './buildPanel.js'
import { MarkdownPreview, isMarkdown, isHtml } from './preview.js'
import { COMMANDS } from './commands.js'
import { extractSymbols } from './symbols.js'
import { fuzzyFilter } from './fuzzy.js'
import {
  createUntitled,
  createFromFile,
  createFromSession,
  isDirty,
  baseName,
  type Doc
} from './documents.js'
import type { EditorState } from '@codemirror/state'
import type { Diagnostic } from '@codemirror/lint'
import {
  DEFAULT_SETTINGS,
  type MenuEvent,
  type Settings,
  type Session,
  type SessionFile,
  type OpenedFile,
  type ProjectSettings,
  type PluginManifest,
  type LanguageServerResult
} from '../../shared/ipc.js'
import './styles.css'

/**
 * The renderer application shell. Owns the list of open documents, the single
 * CodeMirror editor instance, the tab bar, file tree, status bar, palette and
 * settings/session persistence, and wires all of them to the menu/accelerator
 * events forwarded from the main process.
 */
class App {
  private editor!: Editor
  private tree: FileTree
  private palette = new Palette()
  private searchPanel: WorkspaceSearchPanel
  private buildPanel!: BuildPanel
  private preview!: MarkdownPreview
  private docs: Doc[] = []
  private activeId: string | null = null
  private settings: Settings = { ...DEFAULT_SETTINGS }
  private folder: string | null = null
  private project: ProjectSettings = { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], languageTools: {}, languageServers: {} }
  private plugins: PluginManifest[] = []
  /** Recently-closed file paths, for Reopen Closed Tab (LIFO). */
  private closedStack: string[] = []
  /** Debounce handle for session persistence. */
  private saveSessionTimer: number | null = null
  /** Invalidates late language-loader completions after a tab changes. */
  private languageActivation = 0
  /** Commands executed while recording become the replayable macro. */
  private recordingMacro = false
  private lastMacro: MenuEvent[] = []
  private isReplayingMacro = false
  /** External formatter/LSP commands from project config require per-session consent. */
  private approvedExternalTools = new Set<string>()
  private booted = false
  private pendingLaunchPaths: string[] = []
  private workspacePollTimer: number | null = null

  // Cached DOM references.
  private tabBar = document.getElementById('tab-bar')!
  private workspaceName = document.getElementById('workspace-name')!
  private statusPosition = document.getElementById('status-position')!
  private statusSelection = document.getElementById('status-selection')!
  private statusLanguage = document.getElementById('status-language')!
  private statusEol = document.getElementById('status-eol')!
  private statusEncoding = document.getElementById('status-encoding')!
  private sidebar = document.getElementById('sidebar')!
  private host = document.getElementById('editor-host')!
  private splitHost: HTMLElement | null = null
  private splitEditor: Editor | null = null
  private editorArea = document.getElementById('editor-area')!
  private browserBtn = document.getElementById('browser-btn') as HTMLButtonElement
  private previewBtn = document.getElementById('preview-btn') as HTMLButtonElement

  constructor() {
    this.tree = new FileTree(document.getElementById('file-tree')!, {
      onOpenFile: (path) => this.openPath(path),
      onCreate: (parent, isDirectory) => { void this.createPath(parent, isDirectory) },
      onRename: (path) => { void this.renamePath(path) },
      onDelete: (path) => { void this.deletePath(path) },
      onReveal: (path) => { void window.editor.revealInFolder(path).catch((error: unknown) => this.showError('Could not reveal the item.', error)) },
      onError: (message, error) => this.showError(message, error)
    })
    this.searchPanel = new WorkspaceSearchPanel({
      getRoot: () => this.folder,
      getProjectExclude: () => this.project.exclude,
      openMatch: (match) => {
        void this.openPath(match.path).then(() => this.editor.gotoLineNumber(match.line))
      },
      notify: (message, error) => this.showError(message, error),
      afterReplace: () => {
        void this.reloadWorkspaceTree()
        this.renderTabs()
      }
    })
    // The status-bar language field opens the syntax picker (like Sublime).
    this.statusLanguage.addEventListener('click', () => this.pickLanguage())
    this.statusLanguage.classList.add('clickable')

    // Floating browser icon (shown only for HTML docs) → open in browser.
    this.browserBtn.addEventListener('click', () => this.run('open-in-browser'))
    // Floating preview icon (shown only for markdown docs) → toggle preview.
    this.previewBtn.addEventListener('click', () => this.run('toggle-preview'))

    this.bindMenu()
    this.bindShortcuts()
    window.editor.onFileChange((change) => {
      if (this.folder) void this.reloadWorkspaceTree()
      void this.handleExternalFileChange(change.path)
    })
    window.editor.onOpenPathRequested((filePath) => {
      if (this.booted) void this.openPath(filePath)
      else this.pendingLaunchPaths.push(filePath)
    })
    window.editor.onBuildOutput((output) => this.buildPanel.append(output))
    void this.boot()
  }

  /** Load settings, construct the editor, then restore the previous session. */
  private async boot(): Promise<void> {
    try {
      this.settings = await window.editor.readSettings()
    } catch (error) {
      this.showError('Settings could not be read; safe defaults were used.', error)
      this.settings = { ...DEFAULT_SETTINGS }
    }

    this.editor = new Editor(
      this.host,
      {
        onDocChange: () => this.handleDocChange(),
        onCursorChange: (state) => this.updatePositionStatus(state)
      },
      this.settings
    )

    this.preview = new MarkdownPreview(this.editorArea)
    this.buildPanel = new BuildPanel(this.settings.buildCommand, (command) => { void this.runBuild(command) }, () => { void window.editor.cancelBuild() })

    try {
      await this.restoreSession()
      this.booted = true
      for (const filePath of this.pendingLaunchPaths.splice(0)) await this.openPath(filePath)
      this.startWorkspacePolling()
    } catch (error) {
      this.showError('The previous session could not be restored.', error)
      this.docs = [createUntitled()]
      await this.activate(this.docs[0].id)
      this.booted = true
      this.startWorkspacePolling()
    }
  }

  /** Reopen files + folder from the persisted session, or a blank buffer. */
  private async restoreSession(): Promise<void> {
    let session: Session
    try {
      session = await window.editor.readSession()
    } catch {
      session = { openFiles: [], activeIndex: 0, folder: null }
    }

    if (session.folder) {
      await this.openFolderPath(session.folder)
    }

    for (const sf of session.openFiles) {
      try {
        // For file-backed buffers, re-read the current on-disk text so a clean
        // buffer reflects external edits; the draft (if any) is layered on top.
        // Untitled buffers have no path, so disk content is empty.
        const opened = sf.path ? await window.editor.openPath(sf.path) : null
        if (opened?.isBinary || opened?.isTooLarge) continue
        this.docs.push(createFromSession(opened?.content ?? '', {
          ...sf,
          encoding: opened?.encoding ?? sf.encoding,
          eol: opened?.eol ?? sf.eol
        }))
      } catch {
        // File was moved/deleted since last run. If we still hold the user's
        // unsaved draft, keep it as an untitled-style buffer rather than lose
        // their work; otherwise skip.
        if (sf.draft !== undefined) {
          this.docs.push(
            createFromSession('', {
              ...sf,
              path: null,
              name: `${sf.name} (recovered)`,
              encoding: sf.encoding ?? 'utf8',
              eol: sf.eol ?? 'LF'
            })
          )
        }
      }
    }

    if (this.docs.length === 0) {
      this.docs.push(createUntitled())
    }

    const idx =
      session.activeIndex >= 0 && session.activeIndex < this.docs.length
        ? session.activeIndex
        : 0
    await this.activate(this.docs[idx].id)
  }

  /** Subscribe to menu / accelerator events from the main process. */
  private bindMenu(): void {
    window.editor.onMenu((event) => this.run(event))
  }

  /**
   * Central command dispatch. The native menu, keyboard shortcuts and the
   * command palette all funnel through here so behaviour stays consistent.
   */
  run(event: MenuEvent): void {
    if (this.recordingMacro && !this.isReplayingMacro && this.isRecordableMacroEvent(event)) {
      this.lastMacro.push(event)
    }
    switch (event) {
      case 'new-file':
        this.addDoc(createUntitled())
        break
      case 'open-file':
        void this.openViaDialog()
        break
      case 'open-folder':
        void this.openFolder()
        break
      case 'save':
        void this.save(false)
        break
      case 'save-as':
        void this.save(true)
        break
      case 'close-tab':
        this.closeActive()
        break
      case 'reopen-tab':
        void this.reopenClosed()
        break
      case 'next-tab':
        this.cycleTab(1)
        break
      case 'prev-tab':
        this.cycleTab(-1)
        break
      case 'find':
        this.editor.openSearch()
        break
      case 'replace':
        this.editor.openReplace()
        break
      case 'find-in-files':
        this.searchPanel.show(false)
        break
      case 'replace-in-files':
        this.searchPanel.show(true)
        break
      case 'split-editor':
        this.toggleSplitEditor()
        break
      case 'toggle-bookmark':
        this.toggleBookmark()
        break
      case 'next-bookmark':
        this.gotoBookmark(1)
        break
      case 'prev-bookmark':
        this.gotoBookmark(-1)
        break
      case 'record-macro':
        this.toggleMacroRecording()
        break
      case 'run-macro':
        this.runMacro()
        break
      case 'insert-snippet':
        this.insertSnippet()
        break
      case 'build':
        void this.runBuild(this.buildPanel.getCommand() || this.settings.buildCommand)
        break
      case 'format-document':
        void this.formatDocument()
        break
      case 'toggle-problems':
        this.buildPanel.toggle()
        break
      case 'project-settings':
        this.configureProject()
        break
      case 'language-tools':
        this.configureLanguageTool()
        break
      case 'install-plugin':
        void this.installPlugin()
        break
      case 'manage-plugins':
        void this.managePlugins()
        break
      case 'go-to-line':
        this.editor.goToLine()
        break
      case 'toggle-sidebar':
        this.toggleSidebar()
        break
      case 'toggle-word-wrap':
        this.settings.wordWrap = this.editor.toggleWordWrap()
        this.persistSettings()
        break
      case 'toggle-theme':
        this.settings.theme = this.editor.toggleTheme() ? 'dark' : 'light'
        this.persistSettings()
        break
      case 'toggle-minimap':
        this.settings.showMinimap = this.editor.toggleMinimap()
        this.persistSettings()
        this.syncEditorChrome()
        break
      case 'command-palette':
        this.openCommandPalette()
        break
      case 'goto-anything':
        void this.openGotoAnything()
        break
      case 'goto-symbol':
        this.openGotoSymbol()
        break
      case 'select-language':
        void this.pickLanguage()
        break
      case 'toggle-comment':
        this.editor.toggleComment()
        break
      case 'move-line-up':
        this.editor.moveLineUp()
        break
      case 'move-line-down':
        this.editor.moveLineDown()
        break
      case 'copy-line-up':
        this.editor.copyLineUp()
        break
      case 'copy-line-down':
        this.editor.copyLineDown()
        break
      case 'delete-line':
        this.editor.deleteLine()
        break
      case 'duplicate-selection':
        this.editor.duplicateSelection()
        break
      case 'sort-lines':
        this.editor.sortLines()
        break
      case 'font-zoom-in':
        this.settings.fontSize = this.editor.zoomFont(1)
        this.persistSettings()
        break
      case 'font-zoom-out':
        this.settings.fontSize = this.editor.zoomFont(-1)
        this.persistSettings()
        break
      case 'font-zoom-reset':
        this.settings.fontSize = this.editor.setFontSize(DEFAULT_SETTINGS.fontSize)
        this.persistSettings()
        break
      case 'toggle-preview':
        this.togglePreview()
        break
      case 'open-in-browser':
        void this.openInBrowser()
        break
      case 'persist-session':
        void this.persistSessionNow().finally(() => void window.editor.sessionFlushed())
        break
    }
  }

  /** Renderer-owned keyboard shortcuts not expressible as menu accelerators. */
  private bindShortcuts(): void {
    window.addEventListener('keydown', (e) => {
      const override = this.project.keyBindings[this.shortcutString(e)]
      if (override && this.isMenuEvent(override)) {
        e.preventDefault()
        this.run(override)
        return
      }
      const mod = e.ctrlKey || e.metaKey
      // Ctrl/Cmd+1..9 → jump to tab N.
      if (mod && !e.shiftKey && !e.altKey && e.key >= '1' && e.key <= '9') {
        const idx = Number(e.key) - 1
        if (idx < this.docs.length) {
          e.preventDefault()
          void this.activate(this.docs[idx].id)
        }
      }
    })
    // Flush the session when the window is going away.
    window.addEventListener('beforeunload', () => { void this.persistSessionNow() })
  }

  private shortcutString(event: KeyboardEvent): string {
    const parts: string[] = []
    if (event.ctrlKey || event.metaKey) parts.push('Mod')
    if (event.altKey) parts.push('Alt')
    if (event.shiftKey) parts.push('Shift')
    parts.push(event.key.length === 1 ? event.key.toUpperCase() : event.key)
    return parts.join('+')
  }

  private isMenuEvent(value: string): value is MenuEvent {
    return COMMANDS.some((command) => command.id === value)
  }

  /** Add a document, make it active and render the UI. */
  private addDoc(doc: Doc): void {
    this.docs.push(doc)
    void this.activate(doc.id)
    this.scheduleSessionSave()
  }

  /** Get the currently active document, if any. */
  private get active(): Doc | undefined {
    return this.docs.find((d) => d.id === this.activeId)
  }

  /** Switch the active tab, syncing the editor content and status bar. */
  private async activate(id: string): Promise<void> {
    const current = this.active
    if (current) {
      current.content = this.editor.getContent()
      current.editorState = this.editor.getState()
    }

    const doc = this.docs.find((d) => d.id === id)
    if (!doc) return
    this.activeId = id
    const activation = ++this.languageActivation
    this.editor.setDocument(doc.content, doc.editorState)
    if (this.splitEditor) {
      this.splitEditor.setDocument(doc.content)
      void this.splitEditor.setLanguageByName(doc.language).catch(() => undefined)
    }

    // File-name based actions (HTML browser / Markdown preview) must appear
    // immediately. Language support is lazy-loaded and must not delay or block
    // the toolbar when a language chunk is slow or fails to load.
    this.syncEditorChrome()

    try {
      const language = !doc.languageLocked
        ? await this.editor.setLanguageForFile(doc.name)
        : await this.editor.setLanguageByName(doc.language)
      // A slow lazy language bundle can finish after the user moved to another
      // tab. Do not let that request overwrite the active editor configuration.
      if (activation !== this.languageActivation || this.activeId !== id) return
      doc.language = language
      doc.editorState = this.editor.getState()
    } catch (error) {
      console.error(`Failed to load syntax support for ${doc.name}:`, error)
    }
    if (activation !== this.languageActivation || this.activeId !== id) return
    this.renderTabs()
    this.updateStatus()
    this.editor.focus()
    this.scheduleSessionSave()
    // Run again because a manually-selected HTML/Markdown language can reveal
    // an action even when the filename has no recognised extension.
    this.syncEditorChrome()
  }

  /** Update the active doc's cached content and refresh the dirty indicator. */
  private handleDocChange(): void {
    const doc = this.active
    if (!doc) return
    doc.content = this.editor.getContent()
    doc.editorState = this.editor.getState()
    if (this.splitEditor && this.splitEditor.getContent() !== doc.content) {
      this.splitEditor.replaceContent(doc.content)
    }
    this.renderTabs()
    // Live-update the markdown preview if it's showing this doc.
    if (this.preview.isVisible && this.isMarkdownDoc(doc)) {
      this.preview.update(doc.content)
    }
    // Persist drafts as the user types (debounced) so an unexpected quit or
    // machine crash never loses unsaved work — this is the core of hot exit.
    this.scheduleSessionSave()
  }

  /**
   * A document counts as Markdown if its file name is a markdown extension OR
   * the user manually set the syntax to Markdown. This lets an unsaved/renamed
   * buffer be previewed once its language is chosen from the status bar.
   */
  private isMarkdownDoc(doc: Doc): boolean {
    return isMarkdown(doc.name) || doc.language === 'Markdown'
  }

  /** Keep native and CSS visibility state in lockstep. */
  private setActionVisible(button: HTMLButtonElement, visible: boolean): void {
    button.hidden = !visible
    button.classList.toggle('hidden', !visible)
  }

  /**
   * Show/hide the per-document chrome that depends on the active file type:
   * the floating "open in browser" icon (HTML), the markdown preview icon, and
   * the markdown preview pane.
   */
  private syncEditorChrome(): void {
    const doc = this.active
    const html = !!doc && (isHtml(doc.name) || doc.language === 'HTML')
    const md = !!doc && this.isMarkdownDoc(doc)

    this.host.classList.toggle('has-minimap', this.settings.showMinimap)
    this.setActionVisible(this.browserBtn, html)
    this.setActionVisible(this.previewBtn, md)

    // If the preview is open but the new doc isn't markdown, hide it; if it is
    // markdown, refresh it with the new content.
    if (this.preview.isVisible) {
      if (md) this.preview.update(doc!.content)
      else this.preview.hide()
    }
    this.previewBtn.classList.toggle('active', this.preview.isVisible && md)
  }

  /** Toggle the markdown preview for the active document. */
  private togglePreview(): void {
    const doc = this.active
    if (!doc) return
    if (!this.isMarkdownDoc(doc)) {
      // Only meaningful for markdown; give a hint rather than showing blank.
      if (!this.preview.isVisible) {
        window.alert(
          'Markdown preview is only available for Markdown files.\n' +
            'Save the file with a .md extension, or set the syntax to Markdown ' +
            '(click the language in the status bar).'
        )
        return
      }
    }
    const visible = this.preview.toggle(doc.content)
    this.previewBtn.classList.toggle('active', visible)
  }

  /**
   * Open the active document in the system browser. Untitled and dirty buffers
   * are sent as temporary snapshots, so previewing never opens a Save dialog
   * and never modifies the user's source file.
   */
  private async openInBrowser(): Promise<void> {
    const doc = this.active
    if (!doc) return

    doc.content = this.editor.getContent()
    try {
      await window.editor.openInBrowser({
        path: doc.path,
        content: doc.content,
        dirty: isDirty(doc)
      })
    } catch (error) {
      this.showError('The browser preview could not be opened.', error)
    }
  }

  /** Open a file chosen from the native dialog. */
  private async openViaDialog(): Promise<void> {
    try {
      const file = await window.editor.openFile()
      if (file) this.openLoadedFile(file)
    } catch (error) {
      this.showError('The selected file could not be opened.', error)
    }
  }

  /** Open a file by path (from the file tree or Goto Anything). */
  private async openPath(path: string): Promise<void> {
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      void this.activate(existing.id)
      return
    }
    try {
      const file = await window.editor.openPath(path)
      this.openLoadedFile(file)
    } catch (error) {
      this.showError(`Could not open “${baseName(path)}”.`, error)
    }
  }

  /** Handle text/binary/large-file policy consistently for all open routes. */
  private openLoadedFile(file: OpenedFile): void {
    if (file.isBinary) {
      this.showError(`“${baseName(file.path)}” looks like a binary file and was not opened.`)
      return
    }
    if (file.isTooLarge) {
      const mb = (file.byteLength / 1024 / 1024).toFixed(1)
      this.showError(`“${baseName(file.path)}” is ${mb} MB and exceeds the safe editor limit.`)
      return
    }
    this.openLoaded(file.path, file.content, file.encoding, file.eol)
  }

  /** Create (or focus) a tab for an already-loaded file. */
  private openLoaded(
    path: string,
    content: string,
    encoding: Doc['encoding'] = 'utf8',
    eol: Doc['eol'] = 'LF'
  ): void {
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      void this.activate(existing.id)
      return
    }
    // Replace a single pristine untitled buffer instead of stacking tabs.
    if (this.docs.length === 1 && this.docs[0].path === null && !isDirty(this.docs[0])) {
      this.docs = []
    }
    this.addDoc(createFromFile(path, content, encoding, eol))
  }

  /** Open a workspace folder via dialog and populate the file tree. */
  private async openFolder(): Promise<void> {
    try {
      const folder = await window.editor.openFolder()
      if (!folder) return
      this.folder = folder.root
      await this.loadProject(folder.root)
      this.workspaceName.textContent = baseName(folder.root).toUpperCase()
      this.tree.render(folder.entries)
      void window.editor.watchWorkspace(folder.root)
      this.scheduleSessionSave()
    } catch (error) {
      this.showError('The selected folder could not be opened.', error)
    }
  }

  /** Open a workspace folder by a known path (session restore). */
  private async openFolderPath(root: string): Promise<void> {
    try {
      const entries = await window.editor.readDir(root)
      this.folder = root
      await this.loadProject(root)
      this.workspaceName.textContent = baseName(root).toUpperCase()
      this.tree.render(entries)
      void window.editor.watchWorkspace(root)
    } catch {
      // Folder gone since last run — ignore.
    }
  }

  private async loadProject(root: string): Promise<void> {
    try {
      this.project = (await window.editor.readProject(root)) ?? { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], languageTools: {}, languageServers: {} }
      if (this.project.buildCommand) this.buildPanel?.setCommand(this.project.buildCommand)
      this.plugins = (await window.editor.listPlugins(root)).filter(
        (plugin) => plugin.enabled && (this.project.plugins.length === 0 || this.project.plugins.includes(plugin.id))
      )
    } catch (error) {
      this.showError('Project settings could not be read.', error)
    }
  }

  private async saveProject(): Promise<void> {
    if (!this.folder) return
    try {
      await window.editor.writeProject(this.folder, this.project)
    } catch (error) {
      this.showError('Project settings could not be saved.', error)
    }
  }

  /** Minimal project editor: filters, build command, keyboard overrides and enabled plugin IDs. */
  private configureProject(): void {
    if (!this.folder) {
      this.showError('Open a folder before configuring a project.')
      return
    }
    const current = JSON.stringify(this.project, null, 2)
    const next = window.prompt('Edit project JSON (.lumen-project.json):', current)
    if (next === null) return
    try {
      const parsed = JSON.parse(next) as ProjectSettings
      if (!parsed || typeof parsed !== 'object') throw new Error('Project settings must be a JSON object.')
      this.project = {
        exclude: Array.isArray(parsed.exclude) ? parsed.exclude.filter((item): item is string => typeof item === 'string') : [],
        buildCommand: typeof parsed.buildCommand === 'string' ? parsed.buildCommand : '',
        keyBindings: parsed.keyBindings && typeof parsed.keyBindings === 'object' ? parsed.keyBindings : {},
        plugins: Array.isArray(parsed.plugins) ? parsed.plugins.filter((item): item is string => typeof item === 'string') : [],
        languageTools: parsed.languageTools && typeof parsed.languageTools === 'object' ? parsed.languageTools : {},
        languageServers: parsed.languageServers && typeof parsed.languageServers === 'object' ? parsed.languageServers : {}
      }
      this.buildPanel.setCommand(this.project.buildCommand)
      void this.saveProject()
    } catch (error) {
      this.showError('Project settings are not valid JSON.', error)
    }
  }

  /**
   * Configure a document filter/formatter command. This deliberately uses a
   * generic stdin/stdout contract so users can point at prettier, black, gofmt
   * or an LSP-adjacent wrapper without baking one language runtime into Lumen.
   */
  private configureLanguageTool(): void {
    const language = this.active?.language ?? 'Plain Text'
    const current = this.project.languageTools[language]?.command ?? ''
    const command = window.prompt(`Language tool for ${language} (reads document from stdin, writes result to stdout):`, current)
    if (command === null) return
    if (command.trim()) this.project.languageTools[language] = { command: command.trim(), args: [] }
    else delete this.project.languageTools[language]
    void this.saveProject()
  }

  private async installPlugin(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before installing a plugin.')
      return
    }
    const source = window.prompt('Absolute path to a local plugin folder (must contain plugin.json):')?.trim()
    if (!source) return
    try {
      const plugin = await window.editor.installPlugin({ root: this.folder, source })
      if (!this.project.plugins.includes(plugin.id)) this.project.plugins.push(plugin.id)
      await this.saveProject()
      await this.loadProject(this.folder)
      this.statusSelection.textContent = `Installed plugin: ${plugin.name}`
    } catch (error) {
      this.showError('The plugin could not be installed.', error)
    }
  }

  private async managePlugins(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before managing plugins.')
      return
    }
    if (this.plugins.length === 0) {
      this.showError('No enabled plugins are installed for this project.')
      return
    }
    const choices = this.plugins.map((plugin) => `${plugin.id} — ${plugin.name}`).join('\n')
    const id = window.prompt(`Enter a plugin ID to remove:\n\n${choices}`)?.trim()
    if (!id) return
    if (!window.confirm(`Move plugin “${id}” to the system trash?`)) return
    try {
      await window.editor.removePlugin(this.folder, id)
      this.project.plugins = this.project.plugins.filter((pluginId) => pluginId !== id)
      await this.saveProject()
      await this.loadProject(this.folder)
    } catch (error) {
      this.showError('The plugin could not be removed.', error)
    }
  }

  private async reloadWorkspaceTree(): Promise<void> {
    if (!this.folder) return
    try {
      this.tree.render(await window.editor.readDir(this.folder))
    } catch (error) {
      this.showError('The workspace tree could not be refreshed.', error)
    }
  }

  /**
   * `fs.watch({recursive:true})` is not available on every Linux filesystem.
   * This small fallback keeps clean open buffers and the root tree current even
   * where the native watcher cannot recurse. Dirty buffers are never replaced.
   */
  private startWorkspacePolling(): void {
    if (this.workspacePollTimer !== null) return
    this.workspacePollTimer = window.setInterval(() => {
      if (this.folder) void this.reloadWorkspaceTree()
      for (const doc of this.docs) {
        if (doc.path && !isDirty(doc)) void this.handleExternalFileChange(doc.path)
      }
    }, 5_000)
    window.addEventListener('beforeunload', () => {
      if (this.workspacePollTimer !== null) window.clearInterval(this.workspacePollTimer)
      this.workspacePollTimer = null
    }, { once: true })
  }

  /** Offer a safe reload when a clean open file changes outside Lumen. */
  private async handleExternalFileChange(changedPath: string): Promise<void> {
    const doc = this.docs.find((candidate) => candidate.path === changedPath)
    if (!doc || isDirty(doc)) return
    try {
      const opened = await window.editor.openPath(changedPath)
      if (opened.isBinary || opened.isTooLarge) return
      if (opened.content === doc.savedContent && opened.encoding === doc.encoding && opened.eol === doc.eol) return
      doc.content = opened.content
      doc.savedContent = opened.content
      doc.encoding = opened.encoding
      doc.eol = opened.eol
      doc.editorState = undefined
      if (this.activeId === doc.id) await this.activate(doc.id)
      this.renderTabs()
    } catch {
      // A delete/rename is reflected by the tree. Keep any already-open buffer.
    }
  }

  private async createPath(parent: string, isDirectory: boolean): Promise<void> {
    const name = window.prompt(isDirectory ? 'New folder name:' : 'New file name:')?.trim()
    if (!name) return
    if (name.includes('/') || name.includes('\\') || name === '.' || name === '..') {
      this.showError('Use a simple file or folder name.')
      return
    }
    try {
      const entry = await window.editor.createPath(`${parent}/${name}`, isDirectory)
      await this.reloadWorkspaceTree()
      if (!entry.isDirectory) await this.openPath(entry.path)
    } catch (error) {
      this.showError('The new item could not be created.', error)
    }
  }

  private async renamePath(source: string): Promise<void> {
    const nextName = window.prompt('Rename to:', baseName(source))?.trim()
    if (!nextName || nextName === baseName(source)) return
    if (nextName.includes('/') || nextName.includes('\\') || nextName === '.' || nextName === '..') {
      this.showError('Use a simple file or folder name.')
      return
    }
    const target = `${source.slice(0, source.length - baseName(source).length)}${nextName}`
    try {
      await window.editor.renamePath(source, target)
      for (const doc of this.docs) {
        if (
          doc.path === source ||
          (doc.path !== null && (doc.path.startsWith(`${source}/`) || doc.path.startsWith(`${source}\\`)))
        ) {
          doc.path = doc.path === source ? target : `${target}${doc.path.slice(source.length)}`
          doc.name = baseName(doc.path)
        }
      }
      this.renderTabs()
      await this.reloadWorkspaceTree()
    } catch (error) {
      this.showError('The item could not be renamed.', error)
    }
  }

  private async deletePath(target: string): Promise<void> {
    if (!window.confirm(`Move “${baseName(target)}” to the system trash?`)) return
    try {
      await window.editor.deletePath(target)
      const affected = this.docs.filter(
        (doc) => doc.path === target || (doc.path !== null && (doc.path.startsWith(`${target}/`) || doc.path.startsWith(`${target}\\`)))
      )
      for (const doc of affected) this.closeActive(doc.id)
      await this.reloadWorkspaceTree()
    } catch (error) {
      this.showError('The item could not be moved to the trash.', error)
    }
  }

  /** Save the active document. `forceDialog` forces a save-as. */
  private async save(forceDialog: boolean): Promise<void> {
    const doc = this.active
    if (!doc) return
    const savedSnapshot = this.editor.getContent()
    doc.content = savedSnapshot

    let result
    try {
      result = forceDialog
        ? await window.editor.saveAs(savedSnapshot, doc.name, { encoding: doc.encoding, eol: doc.eol })
        : await window.editor.save(doc.path, savedSnapshot, { encoding: doc.encoding, eol: doc.eol })
    } catch (error) {
      this.showError(`Could not save “${doc.name}”.`, error)
      return
    }

    if (!result.saved || !result.path) return
    doc.path = result.path
    doc.name = baseName(result.path)
    // Mark only the exact snapshot written to disk as saved. Edits made while
    // the async write was in flight remain dirty and cannot be silently lost.
    doc.savedContent = savedSnapshot
    if (!doc.languageLocked && this.activeId === doc.id) {
      try {
        doc.language = await this.editor.setLanguageForFile(doc.name)
      } catch (error) {
        this.showError(`Syntax support for “${doc.name}” could not be loaded.`, error)
      }
    }
    this.renderTabs()
    this.updateStatus()
    this.scheduleSessionSave()
    this.syncEditorChrome()
  }

  /** Close the active tab, guarding against losing unsaved changes. */
  private closeActive(id = this.activeId): void {
    const doc = this.docs.find((candidate) => candidate.id === id)
    if (!doc) return
    if (isDirty(doc)) {
      const ok = confirm(`"${doc.name}" has unsaved changes. Close anyway?`)
      if (!ok) return
    }
    if (doc.path) this.closedStack.push(doc.path)

    const idx = this.docs.findIndex((d) => d.id === doc.id)
    this.docs.splice(idx, 1)

    if (this.docs.length === 0) {
      this.addDoc(createUntitled())
      return
    }
    const next = this.docs[Math.min(idx, this.docs.length - 1)]
    void this.activate(next.id)
    this.scheduleSessionSave()
  }

  /** Reopen the most recently closed file (Ctrl/Cmd+Shift+T). */
  private async reopenClosed(): Promise<void> {
    const path = this.closedStack[this.closedStack.length - 1]
    if (!path) return
    const before = this.docs.length
    await this.openPath(path)
    if (this.docs.length > before || this.docs.some((doc) => doc.path === path)) this.closedStack.pop()
  }

  /** Cycle to the next/previous tab, wrapping around. */
  private cycleTab(delta: number): void {
    if (this.docs.length < 2) return
    const idx = this.docs.findIndex((d) => d.id === this.activeId)
    const next = (idx + delta + this.docs.length) % this.docs.length
    void this.activate(this.docs[next].id)
  }

  /** Show or hide the sidebar. */
  private toggleSidebar(): void {
    this.sidebar.classList.toggle('hidden')
  }

  /**
   * Toggle a lightweight second editor view. It mirrors the active document
   * live, providing a practical split reading/editing surface without creating
   * a second document model that could diverge from the primary tab state.
   */
  private toggleSplitEditor(): void {
    if (this.splitHost) {
      this.splitEditor?.view.destroy()
      this.splitHost.remove()
      this.splitHost = null
      this.splitEditor = null
      return
    }
    const split = document.createElement('div')
    split.className = 'editor-split-host'
    this.editorArea.appendChild(split)
    this.splitHost = split
    this.splitEditor = new Editor(
      split,
      {
        onDocChange: () => this.handleSplitDocChange(),
        onCursorChange: () => undefined
      },
      this.settings
    )
    const doc = this.active
    this.splitEditor.setDocument(this.editor.getContent())
    if (doc) void this.splitEditor.setLanguageByName(doc.language).catch(() => undefined)
  }

  /** Keep both CodeMirror panes on the same active document without event loops. */
  private handleSplitDocChange(): void {
    const split = this.splitEditor
    const doc = this.active
    if (!split || !doc) return
    const content = split.getContent()
    if (this.editor.getContent() !== content) this.editor.replaceContent(content)
    doc.content = content
    doc.editorState = this.editor.getState()
    this.renderTabs()
    this.scheduleSessionSave()
  }

  private toggleBookmark(): void {
    const doc = this.active
    if (!doc) return
    const line = this.editor.currentLine()
    const index = doc.bookmarks.indexOf(line)
    if (index >= 0) doc.bookmarks.splice(index, 1)
    else doc.bookmarks.push(line)
    doc.bookmarks.sort((a, b) => a - b)
    this.statusSelection.textContent = doc.bookmarks.includes(line) ? `Bookmark: line ${line}` : 'Bookmark removed'
  }

  private gotoBookmark(delta: number): void {
    const doc = this.active
    if (!doc || doc.bookmarks.length === 0) return
    const current = this.editor.currentLine()
    const next = delta > 0
      ? doc.bookmarks.find((line) => line > current) ?? doc.bookmarks[0]
      : [...doc.bookmarks].reverse().find((line) => line < current) ?? doc.bookmarks[doc.bookmarks.length - 1]
    this.editor.gotoLineNumber(next)
  }

  private toggleMacroRecording(): void {
    this.recordingMacro = !this.recordingMacro
    if (this.recordingMacro) {
      this.lastMacro = []
      this.statusSelection.textContent = 'Recording macro…'
    } else {
      this.statusSelection.textContent = `${this.lastMacro.length} macro step${this.lastMacro.length === 1 ? '' : 's'} recorded`
    }
  }

  private runMacro(): void {
    if (this.lastMacro.length === 0) {
      this.showError('No recorded macro is available.')
      return
    }
    this.isReplayingMacro = true
    try {
      for (const event of this.lastMacro) this.run(event)
    } finally {
      this.isReplayingMacro = false
    }
  }

  private isRecordableMacroEvent(event: MenuEvent): boolean {
    return ['toggle-comment', 'move-line-up', 'move-line-down', 'copy-line-up', 'copy-line-down', 'delete-line', 'duplicate-selection', 'sort-lines'].includes(event)
  }

  private insertSnippet(): void {
    const snippets = [
      { label: 'Console log', value: 'console.log(${1:value})' },
      { label: 'Function', value: 'function ${1:name}(${2:args}) {\n  ${0}\n}' },
      { label: 'Try / catch', value: 'try {\n  ${1}\n} catch (error) {\n  ${2}\n}' }
    ]
    for (const plugin of this.plugins) {
      for (const snippet of plugin.snippets) {
        snippets.push({ label: `${plugin.name}: ${snippet.label}`, value: snippet.text })
      }
    }
    this.palette.open({
      placeholder: 'Insert snippet…',
      items: snippets,
      onAccept: (item) => this.editor.insertText(String(item.value).replace(/\$\{\d+(?::([^}]*))?\}/g, (_token, fallback) => fallback ?? ''))
    })
  }

  /** Execute the configured build command inside the active project directory. */
  private async runBuild(command: string): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before running a build.')
      return
    }
    if (!command) {
      this.buildPanel.toggle(true)
      this.showError('Enter a build command, such as “npm test”.')
      return
    }
    if (!this.confirmExternalTool(command, 'build command')) return
    this.settings.buildCommand = command
    this.project.buildCommand = command
    this.persistSettings()
    void this.saveProject()
    this.buildPanel.setCommand(command)
    this.buildPanel.clear()
    this.buildPanel.toggle(true)
    try {
      await window.editor.runBuild({ root: this.folder, command })
    } catch (error) {
      this.showError('The build could not be started.', error)
    }
  }

  /** A conservative built-in formatter for whitespace-only languages. */
  private async formatDocument(): Promise<void> {
    const content = this.editor.getContent()
    const doc = this.active
    const server = doc ? this.project.languageServers[doc.language] : undefined
    if (server && this.folder && doc?.path) {
      if (!this.confirmExternalTool(server.command, `language server for ${doc.language}`)) return
      try {
        const result = await window.editor.runLanguageServer({
          root: this.folder,
          config: server,
          content,
          filePath: doc.path,
          languageId: doc.language.toLowerCase().replaceAll(' ', '-')
        })
        this.applyLanguageServerResult(result)
        return
      } catch (error) {
        this.showError('The configured language server could not run.', error)
        return
      }
    }
    const tool = doc ? this.project.languageTools[doc.language] : undefined
    if (tool && this.folder) {
      if (!this.confirmExternalTool(tool.command, 'language tool')) return
      try {
        const result = await window.editor.runLanguageTool({
          root: this.folder,
          command: [tool.command, ...tool.args].join(' '),
          content,
          filePath: this.active?.path ?? null
        })
        if (typeof result.content === 'string' && result.content !== content) this.editor.replaceContent(result.content)
        this.editor.setDiagnostics(result.diagnostics.map((diagnostic) => this.toCodeMirrorDiagnostic(diagnostic)))
        this.statusSelection.textContent = result.diagnostics.length
          ? `${result.diagnostics.length} diagnostic${result.diagnostics.length === 1 ? '' : 's'}`
          : 'Language tool completed'
        return
      } catch (error) {
        this.showError('The configured language tool could not run.', error)
        return
      }
    }
    const formatted = content
      .split('\n')
      .map((line) => line.replace(/[ \t]+$/g, ''))
      .join('\n')
      .replace(/\n{3,}/g, '\n\n')
    if (formatted !== content) this.editor.replaceContent(formatted)
  }

  private applyLanguageServerResult(result: LanguageServerResult): void {
    const lines = this.editor.getContent().split('\n')
    const offsetAt = (lineIndex: number, character: number): number => {
      const clampedLine = Math.max(0, Math.min(lines.length - 1, lineIndex))
      let offset = 0
      for (let index = 0; index < clampedLine; index += 1) offset += lines[index].length + 1
      return offset + Math.max(0, Math.min(lines[clampedLine].length, character))
    }
    const edits = [...result.edits]
      .sort((a, b) => offsetAt(b.startLine, b.startCharacter) - offsetAt(a.startLine, a.startCharacter))
    let next = this.editor.getContent()
    for (const edit of edits) {
      const from = offsetAt(edit.startLine, edit.startCharacter)
      const to = offsetAt(edit.endLine, edit.endCharacter)
      next = `${next.slice(0, from)}${edit.newText}${next.slice(to)}`
    }
    if (next !== this.editor.getContent()) this.editor.replaceContent(next)
    this.editor.setDiagnostics(result.diagnostics.map((diagnostic) => this.toCodeMirrorDiagnostic(diagnostic)))
    this.statusSelection.textContent = result.diagnostics.length
      ? `${result.diagnostics.length} diagnostic${result.diagnostics.length === 1 ? '' : 's'}`
      : 'Language server completed'
  }

  private toCodeMirrorDiagnostic(diagnostic: {
    line: number
    column: number
    endLine?: number
    endColumn?: number
    severity: 'error' | 'warning' | 'info'
    message: string
  }): Diagnostic {
    const state = this.editor.view.state
    const line = state.doc.line(Math.max(1, Math.min(state.doc.lines, diagnostic.line)))
    const from = Math.min(line.to, line.from + diagnostic.column - 1)
    const endLine = state.doc.line(Math.max(1, Math.min(state.doc.lines, diagnostic.endLine ?? diagnostic.line)))
    const to = Math.max(from, Math.min(endLine.to, endLine.from + (diagnostic.endColumn ?? diagnostic.column) - 1))
    return { from, to, severity: diagnostic.severity, message: diagnostic.message, source: 'language-tool' }
  }

  private confirmExternalTool(command: string, label: string): boolean {
    const key = `${label}\u0000${command}`
    if (this.approvedExternalTools.has(key)) return true
    const approved = window.confirm(
      `Run the configured ${label}?\n\n${command}\n\n` +
        'This starts a local process from the project configuration. Approval lasts for this app session.'
    )
    if (approved) this.approvedExternalTools.add(key)
    return approved
  }

  // ---- Command palette & Goto modes ----

  /** Ctrl/Cmd+Shift+P — fuzzy list of all commands. */
  private openCommandPalette(): void {
    const items: PaletteItem[] = COMMANDS.map((c) => ({
      label: c.title,
      hint: c.hint,
      value: c.id
    }))
    for (const plugin of this.plugins) {
      for (const command of plugin.commands) {
        items.push({
          label: `${plugin.name}: ${command.title}`,
          detail: plugin.id,
          value: { kind: 'plugin-command', command }
        })
      }
    }
    this.palette.open({
      placeholder: 'Type a command…',
      items,
      onAccept: (item) => {
        if (typeof item.value === 'object' && item.value && (item.value as { kind?: string }).kind === 'plugin-command') {
          const command = (item.value as { command: PluginManifest['commands'][number] }).command
          if (command.insertText) this.editor.insertText(command.insertText)
          return
        }
        this.run(item.value as MenuEvent)
      }
    })
  }

  /** Ctrl/Cmd+P — fuzzy list of workspace files, with :line and @symbol modes. */
  private async openGotoAnything(): Promise<void> {
    let files: string[] = []
    if (this.folder) {
      try {
        files = (await window.editor.listFiles(this.folder)).filter((file) => !this.isProjectExcluded(file))
      } catch {
        files = []
      }
    }
    const root = this.folder
    this.palette.open({
      placeholder: 'Goto Anything — file, :line, @symbol',
      onQuery: (query) => this.gotoAnythingItems(query, files, root),
      onAccept: (item) => this.acceptGoto(item)
    })
  }

  private isProjectExcluded(file: string): boolean {
    if (!this.folder) return false
    const relative = file.slice(this.folder.length + 1).replaceAll('\\', '/')
    return this.project.exclude.some((pattern) => {
      const source = pattern
        .replace(/[.+^${}()|[\]\\]/g, '\\$&')
        .replaceAll('**', '.*')
        .replaceAll('*', '[^/]*')
      return new RegExp(`^${source}$`).test(relative)
    })
  }

  /** Compute palette rows for a Goto Anything query based on its mode prefix. */
  private gotoAnythingItems(query: string, files: string[], root: string | null): PaletteItem[] {
    // ":123" → go to line in the current file.
    if (query.startsWith(':')) {
      const line = query.slice(1)
      return [{ label: `Go to line ${line || '…'}`, value: { kind: 'line', line: Number(line) } }]
    }
    // "@sym" → symbols in the current file.
    if (query.startsWith('@')) {
      return this.symbolItems(query.slice(1))
    }
    // Otherwise fuzzy-match file paths relative to the workspace root.
    const rel = (p: string): string =>
      root && p.startsWith(root) ? p.slice(root.length + 1) : p
    const matched = fuzzyFilter(query, files, rel)
    return matched.slice(0, 200).map(({ item }) => ({
      label: baseName(item),
      detail: rel(item),
      value: { kind: 'file', path: item }
    }))
  }

  /** Ctrl/Cmd+R — symbols in the current document. */
  private openGotoSymbol(): void {
    this.palette.open({
      placeholder: 'Goto Symbol in file',
      onQuery: (query) => this.symbolItems(query),
      onAccept: (item) => this.acceptGoto(item)
    })
  }

  /** Build palette rows from the current document's symbols. */
  private symbolItems(query: string): PaletteItem[] {
    const symbols = extractSymbols(this.editor.getContent())
    const source = query
      ? fuzzyFilter(query, symbols, (s) => s.label).map((r) => r.item)
      : symbols
    return source.slice(0, 200).map((s) => ({
      label: s.label,
      hint: `Ln ${s.line}`,
      value: { kind: 'pos', pos: s.pos }
    }))
  }

  /** Handle a chosen Goto row (file / line / symbol position). */
  private acceptGoto(item: PaletteItem): void {
    const v = item.value as
      | { kind: 'file'; path: string }
      | { kind: 'line'; line: number }
      | { kind: 'pos'; pos: number }
    if (v.kind === 'file') {
      void this.openPath(v.path)
    } else if (v.kind === 'line') {
      if (Number.isFinite(v.line) && v.line > 0) this.editor.gotoLineNumber(v.line)
    } else {
      this.editor.gotoPos(v.pos)
    }
  }

  /** Open the syntax picker and lock the active doc's language on choice. */
  private async pickLanguage(): Promise<void> {
    const items: PaletteItem[] = allLanguageNames().map((name) => ({
      label: name,
      value: name
    }))
    this.palette.open({
      placeholder: 'Set syntax…',
      items,
      onAccept: async (item) => {
        const doc = this.active
        if (!doc) return
        const name = item.value as string
        const id = doc.id
        const activation = ++this.languageActivation
        try {
          const language = await this.editor.setLanguageByName(name)
          if (this.activeId !== id || activation !== this.languageActivation) return
          doc.language = language
          doc.languageLocked = name !== 'Plain Text'
          this.updateStatus()
        } catch (error) {
          this.showError(`Syntax support for “${name}” could not be loaded.`, error)
        }
        // Picking "Markdown" (or leaving it) should immediately reveal/hide the
        // preview icon, so refresh the type-dependent editor chrome.
        this.syncEditorChrome()
      }
    })
  }

  // ---- Persistence ----

  /** Persist settings to disk (fire-and-forget). */
  private persistSettings(): void {
    void window.editor.writeSettings(this.settings).catch((error: unknown) =>
      this.showError('Settings could not be saved.', error)
    )
  }

  /** Debounced session save to avoid thrashing on rapid edits/switches. */
  private scheduleSessionSave(): void {
    if (this.saveSessionTimer !== null) window.clearTimeout(this.saveSessionTimer)
    this.saveSessionTimer = window.setTimeout(() => { void this.persistSessionNow() }, 400)
  }

  /**
   * Write the current session immediately. Persists a draft for every buffer
   * that is dirty or untitled-with-content, so unsaved work survives an
   * unexpected quit (hot exit). Clean file-backed buffers store only their
   * path and are re-read from disk on restore.
   */
  private async persistSessionNow(): Promise<void> {
    // Keep the active buffer's cached content current before snapshotting.
    const current = this.active
    if (current) current.content = this.editor.getContent()

    const openFiles: SessionFile[] = this.docs
      // Drop pristine untitled buffers (no path, no content) — nothing to keep.
      .filter((d) => d.path !== null || d.content.length > 0)
      .map((d) => {
        const keepDraft = isDirty(d) || (d.path === null && d.content.length > 0)
        return {
          path: d.path,
          name: d.name,
          language: d.language,
          languageLocked: d.languageLocked,
          encoding: d.encoding,
          eol: d.eol,
          ...(keepDraft ? { draft: d.content } : {})
        }
      })

    const activeDoc = this.active
    const activeIndex = activeDoc
      ? Math.max(
          0,
          openFiles.findIndex((f) => f.path === activeDoc.path && f.name === activeDoc.name)
        )
      : 0

    const session: Session = { openFiles, activeIndex, folder: this.folder }
    try {
      await window.editor.writeSession(session)
    } catch (error) {
      this.showError('Session recovery data could not be saved.', error)
    }
  }

  // ---- Rendering ----

  /** Rebuild the tab bar DOM from the current document list. */
  private renderTabs(): void {
    this.tabBar.replaceChildren()
    for (const doc of this.docs) {
      const tab = document.createElement('div')
      tab.className = 'tab' + (doc.id === this.activeId ? ' active' : '')

      const dot = document.createElement('span')
      dot.className = 'tab-dirty'
      dot.textContent = isDirty(doc) ? '●' : ''

      const label = document.createElement('span')
      label.className = 'tab-label'
      label.textContent = doc.name

      const close = document.createElement('span')
      close.className = 'tab-close'
      close.textContent = '×'
      close.addEventListener('click', (e) => {
        e.stopPropagation()
        this.closeActive(doc.id)
      })

      tab.append(dot, label, close)
      tab.addEventListener('click', () => void this.activate(doc.id))
      this.tabBar.appendChild(tab)
    }
  }

  /** Refresh all status-bar fields for the active document. */
  private updateStatus(): void {
    const doc = this.active
    this.statusLanguage.textContent = doc?.language ?? 'Plain Text'
    this.statusEol.textContent = doc?.eol ?? 'LF'
    this.statusEncoding.textContent = doc?.encoding === 'utf8bom' ? 'UTF-8 BOM' : doc?.encoding.toUpperCase() ?? 'UTF-8'
    this.updatePositionStatus(this.editor.view.state)
  }

  /** Update the Ln/Col and selection-length status readouts. */
  private updatePositionStatus(state: EditorState): void {
    const sel = state.selection.main
    const line = state.doc.lineAt(sel.head)
    const col = sel.head - line.from + 1
    this.statusPosition.textContent = `Ln ${line.number}, Col ${col}`

    const len = Math.abs(sel.to - sel.from)
    this.statusSelection.textContent = len > 0 ? `(${len} selected)` : ''
  }

  /** Keep filesystem failures actionable without exposing low-level stacks in the UI. */
  private showError(message: string, error?: unknown): void {
    console.error(message, error)
    const detail = error instanceof Error && error.message ? `\n\n${error.message}` : ''
    window.alert(`${message}${detail}`)
  }
}

// Boot the app once the DOM is ready.
window.addEventListener('DOMContentLoaded', () => {
  new App()
})
