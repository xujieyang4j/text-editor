import { Editor, allLanguageNames } from './editor.js'
import { FileTree } from './fileTree.js'
import { Palette, type PaletteItem } from './palette.js'
import { WorkspaceSearchPanel } from './workspaceSearch.js'
import { FindResultsView } from './findResults.js'
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
  type LanguageServerResult,
  type WorkspaceMatch,
  type WorkspaceSymbol,
  type LayoutKind,
  type SessionLayout,
  type LanguageServerDiagnosticEvent,
  type BuildSystem,
  type BuildProblem,
  type BuildOutput
} from '../../shared/ipc.js'
import './styles.css'

interface EditorGroup {
  id: number
  root: HTMLElement
  tabBar: HTMLElement
  host: HTMLElement
  editorArea: HTMLElement
  editor: Editor
  docIds: string[]
  activeId: string | null
}

/**
 * The renderer application shell. Owns the list of open documents, the single
 * CodeMirror editor instance, the tab bar, file tree, status bar, palette and
 * settings/session persistence, and wires all of them to the menu/accelerator
 * events forwarded from the main process.
 */
class App {
  private primaryEditor!: Editor
  private tree: FileTree
  private palette = new Palette()
  private searchPanel: WorkspaceSearchPanel
  private findResults: FindResultsView
  private buildPanel!: BuildPanel
  private preview!: MarkdownPreview
  private docs: Doc[] = []
  private groups: EditorGroup[] = []
  private activeGroup = 0
  private layoutKind: LayoutKind = 'single'
  private settings: Settings = { ...DEFAULT_SETTINGS }
  private folder: string | null = null
  private project: ProjectSettings = { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], languageTools: {}, languageServers: {}, buildSystems: [] }
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
  private conflictBar: HTMLDivElement | null = null
  private conflictDocId: string | null = null
  private navigationBack: Array<{ path: string; line: number; column: number }> = []
  private navigationForward: Array<{ path: string; line: number; column: number }> = []
  private isNavigatingHistory = false
  private projectSymbols: WorkspaceSymbol[] = []
  private projectSymbolIndexAt = 0
  private lspSyncTimer: number | null = null
  private lspDocumentVersion = new Map<string, number>()
  private buildOutputText = ''
  private activeBuildSystem: BuildSystem | null = null

  // Cached DOM references.
  private primaryTabBar = document.getElementById('tab-bar')!
  private workspaceName = document.getElementById('workspace-name')!
  private statusPosition = document.getElementById('status-position')!
  private statusSelection = document.getElementById('status-selection')!
  private statusLanguage = document.getElementById('status-language')!
  private statusEol = document.getElementById('status-eol')!
  private statusEncoding = document.getElementById('status-encoding')!
  private sidebar = document.getElementById('sidebar')!
  private primaryHost = document.getElementById('editor-host')!
  private primaryEditorArea = document.getElementById('editor-area')!
  private layoutRoot = document.getElementById('layout-root')!
  private primaryGroupRoot = document.getElementById('editor-group-0')!
  private findResultsHost = document.getElementById('find-results-host')!
  private browserBtn = document.getElementById('browser-btn') as HTMLButtonElement
  private previewBtn = document.getElementById('preview-btn') as HTMLButtonElement

  private get editor(): Editor {
    return this.groups[this.activeGroup]?.editor ?? this.primaryEditor
  }

  private get host(): HTMLElement {
    return this.groups[this.activeGroup]?.host ?? this.primaryHost
  }

  private get editorArea(): HTMLElement {
    return this.groups[this.activeGroup]?.editorArea ?? this.primaryEditorArea
  }

  private get activeId(): string | null {
    return this.groups[this.activeGroup]?.activeId ?? null
  }

  private set activeId(value: string | null) {
    const group = this.groups[this.activeGroup]
    if (group) group.activeId = value
  }

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
      },
      onResults: (query, matches) => this.showFindResults(query, matches)
    })
    this.findResults = new FindResultsView({
      onOpenMatch: (match) => { void this.openWorkspaceMatch(match) }
    })
    this.findResultsHost.appendChild(this.findResults.root)
    this.createConflictBar()
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
      this.projectSymbols = []
      void this.handleExternalFileChange(change.path)
    })
    window.editor.onOpenPathRequested((filePath) => {
      if (this.booted) void this.openPath(filePath)
      else this.pendingLaunchPaths.push(filePath)
    })
    window.editor.onBuildOutput((output) => this.handleBuildOutput(output))
    window.editor.onLanguageServerDiagnostics((event) => this.applyLanguageServerDiagnostics(event))
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

    this.primaryEditor = new Editor(
      this.primaryHost,
      {
        onDocChange: () => this.handleDocChange(),
        onCursorChange: (state) => this.updatePositionStatus(state)
      },
      this.settings
    )
    this.groups = [{
      id: 0,
      root: this.primaryGroupRoot,
      tabBar: this.primaryTabBar,
      host: this.primaryHost,
      editorArea: this.primaryEditorArea,
      editor: this.primaryEditor,
      docIds: [],
      activeId: null
    }]
    this.primaryGroupRoot.classList.add('active')
    this.primaryGroupRoot.addEventListener('mousedown', () => this.focusGroup(0))

    this.preview = new MarkdownPreview(this.primaryEditorArea)
    this.buildPanel = new BuildPanel(
      this.settings.buildCommand,
      {
        onRun: (command) => { void this.runBuild(command) },
        onCancel: () => { void window.editor.cancelBuild() },
        onOpenProblem: (problem) => { void this.openBuildProblem(problem) }
      }
    )

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

    if (this.docs.length === 0) this.docs.push(createUntitled())

    const layout = session.layout
    if (layout && layout.groups.length > 0) {
      this.setLayout(layout.kind)
      for (const [groupIndex, savedGroup] of layout.groups.entries()) {
        const group = this.groups[groupIndex]
        if (!group) continue
        group.docIds = savedGroup.docIndexes
          .map((index) => this.docs[index]?.id)
          .filter((id): id is string => !!id)
        if (group.docIds.length === 0) group.docIds = [this.docs[0].id]
        group.activeId = group.docIds[Math.max(0, Math.min(savedGroup.activeIndex, group.docIds.length - 1))]
      }
      this.activeGroup = Math.max(0, Math.min(layout.activeGroup, this.groups.length - 1))
      await this.activate(this.groups[this.activeGroup].activeId ?? this.docs[0].id, this.activeGroup)
    } else {
      const first = this.groups[0]
      first.docIds = this.docs.map((doc) => doc.id)
      const idx = session.activeIndex >= 0 && session.activeIndex < this.docs.length ? session.activeIndex : 0
      await this.activate(this.docs[idx].id, 0)
    }
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
      case 'new-window':
        void window.editor.newWindow()
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
      case 'find-results-next':
        this.findResults.move(1)
        break
      case 'find-results-prev':
        this.findResults.move(-1)
        break
      case 'goto-project-symbol':
        void this.openProjectSymbol()
        break
      case 'navigate-back':
        void this.navigateHistory(-1)
        break
      case 'navigate-forward':
        void this.navigateHistory(1)
        break
      case 'split-editor':
        this.toggleSplitEditor()
        break
      case 'layout-single':
        this.setLayout('single')
        break
      case 'layout-columns2':
        this.setLayout('columns2')
        break
      case 'layout-columns3':
        this.setLayout('columns3')
        break
      case 'layout-grid4':
        this.setLayout('grid4')
        break
      case 'move-file-next-group':
        this.moveActiveToNextGroup(false)
        break
      case 'clone-file-next-group':
        this.moveActiveToNextGroup(true)
        break
      case 'focus-next-group':
        this.focusGroup((this.activeGroup + 1) % this.groups.length)
        break
      case 'focus-prev-group':
        this.focusGroup((this.activeGroup - 1 + this.groups.length) % this.groups.length)
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
        if (this.activeBuildSystem) void this.runBuildSystem(this.activeBuildSystem)
        else void this.runBuild(this.buildPanel.getCommand() || this.settings.buildCommand)
        break
      case 'select-build-system':
        this.selectBuildSystem()
        break
      case 'format-document':
        void this.formatDocument()
        break
      case 'trim-trailing-whitespace':
        this.editor.trimTrailingWhitespace()
        break
      case 'convert-indent-spaces':
        this.editor.convertIndentation(false)
        break
      case 'convert-indent-tabs':
        this.editor.convertIndentation(true)
        break
      case 'convert-eol-lf':
        this.setDocumentEol('LF')
        break
      case 'convert-eol-crlf':
        this.setDocumentEol('CRLF')
        break
      case 'convert-eol-cr':
        this.setDocumentEol('CR')
        break
      case 'to-upper-case':
        this.editor.changeCase('upper')
        break
      case 'to-lower-case':
        this.editor.changeCase('lower')
        break
      case 'to-title-case':
        this.editor.changeCase('title')
        break
      case 'join-lines':
        this.editor.joinLines()
        break
      case 'split-selection-lines':
        this.editor.splitSelectionIntoLines()
        break
      case 'indent-selection':
        this.editor.indentSelection()
        break
      case 'outdent-selection':
        this.editor.outdentSelection()
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
        const group = this.groups[this.activeGroup]
        if (group && idx < group.docIds.length) {
          e.preventDefault()
          void this.activate(group.docIds[idx], this.activeGroup)
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

  /** Select a layout, create/destroy editor groups, and retain group-local tabs. */
  private setLayout(kind: LayoutKind): void {
    const count = kind === 'single' ? 1 : kind === 'columns2' ? 2 : kind === 'columns3' ? 3 : 4
    const active = this.active
    const currentGroup = this.groups[this.activeGroup]
    if (currentGroup && active) {
      active.content = currentGroup.editor.getContent()
      active.editorState = currentGroup.editor.getState()
    }

    while (this.groups.length > count) {
      const group = this.groups.pop()!
      const destination = this.groups[0]
      for (const id of group.docIds) {
        if (!destination.docIds.includes(id)) destination.docIds.push(id)
      }
      if (!destination.activeId) destination.activeId = group.activeId
      group.editor.view.destroy()
      group.root.remove()
    }
    while (this.groups.length < count) this.groups.push(this.createEditorGroup(this.groups.length))

    for (const group of this.groups) {
      if (group.docIds.length === 0 && active) {
        group.docIds.push(active.id)
        group.activeId = active.id
      }
    }

    this.layoutKind = kind
    this.layoutRoot.className = `layout-root layout-${kind}`
    this.activeGroup = Math.min(this.activeGroup, this.groups.length - 1)
    this.focusGroup(this.activeGroup)
    this.renderTabs()
    this.scheduleSessionSave()
  }

  private createEditorGroup(id: number): EditorGroup {
    const root = document.createElement('section')
    root.className = 'editor-group'
    root.dataset.groupId = String(id)
    const tabBar = document.createElement('div')
    tabBar.className = 'tab-bar'
    const area = document.createElement('div')
    area.className = 'editor-area'
    const host = document.createElement('div')
    host.className = 'editor-host'
    area.appendChild(host)
    root.append(tabBar, area)
    this.layoutRoot.appendChild(root)

    const group: EditorGroup = {
      id,
      root,
      tabBar,
      host,
      editorArea: area,
      editor: undefined as unknown as Editor,
      docIds: [],
      activeId: null
    }
    group.editor = new Editor(
      host,
      {
        onDocChange: () => this.handleDocChange(id),
        onCursorChange: (state) => {
          if (this.activeGroup === id) this.updatePositionStatus(state)
        }
      },
      this.settings
    )
    root.addEventListener('mousedown', () => this.focusGroup(id))
    return group
  }

  private focusGroup(index: number): void {
    const group = this.groups[index]
    if (!group) return
    const changed = this.activeGroup !== index
    for (const candidate of this.groups) candidate.root.classList.toggle('active', candidate.id === index)
    if (changed && group.activeId) void this.activate(group.activeId, index)
  }

  private moveActiveToNextGroup(clone: boolean): void {
    if (this.groups.length < 2) {
      this.setLayout('columns2')
    }
    const source = this.groups[this.activeGroup]
    const doc = this.active
    if (!source || !doc) return
    const targetIndex = (this.activeGroup + 1) % this.groups.length
    const target = this.groups[targetIndex]
    if (!target.docIds.includes(doc.id)) target.docIds.push(doc.id)
    target.activeId = doc.id
    if (!clone) {
      source.docIds = source.docIds.filter((id) => id !== doc.id)
      if (source.activeId === doc.id) source.activeId = source.docIds[0] ?? null
    }
    this.focusGroup(targetIndex)
    this.renderTabs()
    this.scheduleSessionSave()
  }

  /** Keep the configured LSP alive and sync active saved files after edits settle. */
  private scheduleLanguageServerSync(doc: Doc): void {
    if (!this.folder || !doc.path || !this.project.languageServers[doc.language]) return
    if (this.lspSyncTimer !== null) window.clearTimeout(this.lspSyncTimer)
    this.lspSyncTimer = window.setTimeout(() => {
      const latest = this.docs.find((candidate) => candidate.id === doc.id)
      if (latest) void this.syncLanguageServer(latest)
    }, 250)
  }

  private async syncLanguageServer(doc: Doc): Promise<void> {
    if (!this.folder || !doc.path) return
    const config = this.project.languageServers[doc.language]
    if (!config || !this.confirmExternalTool(config.command, `language server for ${doc.language}`)) return
    const version = (this.lspDocumentVersion.get(doc.path) ?? 0) + 1
    this.lspDocumentVersion.set(doc.path, version)
    try {
      await window.editor.syncLanguageServer({
        root: this.folder,
        config,
        content: doc.content,
        filePath: doc.path,
        languageId: doc.language.toLowerCase().replaceAll(' ', '-'),
        version
      })
    } catch (error) {
      this.showError('The configured language server could not synchronize.', error)
    }
  }

  private applyLanguageServerDiagnostics(event: LanguageServerDiagnosticEvent): void {
    const doc = this.docs.find((candidate) => candidate.path === event.filePath)
    if (!doc) return
    doc.diagnostics = event.diagnostics
    if (this.activeId === doc.id) {
      this.editor.setDiagnostics(event.diagnostics.map((diagnostic) => this.toCodeMirrorDiagnostic(diagnostic)))
      this.statusSelection.textContent = event.diagnostics.length
        ? `${event.diagnostics.length} diagnostic${event.diagnostics.length === 1 ? '' : 's'}`
        : ''
    }
  }

  /** Add a document to the active editor group, then focus it. */
  private addDoc(doc: Doc): void {
    this.docs.push(doc)
    const group = this.groups[this.activeGroup]
    if (group && !group.docIds.includes(doc.id)) group.docIds.push(doc.id)
    void this.activate(doc.id, this.activeGroup)
    this.scheduleSessionSave()
  }

  /** Get the currently active document, if any. */
  private get active(): Doc | undefined {
    return this.docs.find((d) => d.id === this.activeId)
  }

  /** Switch a group to a document, preserving the previous group's editor state. */
  private async activate(id: string, groupIndex = this.activeGroup): Promise<void> {
    const previousGroup = this.groups[this.activeGroup]
    const previousId = previousGroup?.activeId
    const previous = previousId ? this.docs.find((doc) => doc.id === previousId) : undefined
    if (previous && previousGroup) {
      previous.content = previousGroup.editor.getContent()
      previous.editorState = previousGroup.editor.getState()
    }

    const group = this.groups[groupIndex]
    const doc = this.docs.find((candidate) => candidate.id === id)
    if (!group || !doc) return
    if (!group.docIds.includes(id)) group.docIds.push(id)
    this.activeGroup = groupIndex
    group.activeId = id
    this.hideFindResults()
    const activation = ++this.languageActivation
    group.editor.setDocument(doc.content, doc.editorState)
    group.editor.setDiagnostics((doc.diagnostics ?? []).map((diagnostic) => this.toCodeMirrorDiagnostic(diagnostic)))

    // File-name based actions (HTML browser / Markdown preview) must appear
    // immediately. Language support is lazy-loaded and must not delay or block
    // the toolbar when a language chunk is slow or fails to load.
    this.syncEditorChrome()

    try {
      const language = !doc.languageLocked
        ? await group.editor.setLanguageForFile(doc.name)
        : await group.editor.setLanguageByName(doc.language)
      // A slow lazy language bundle can finish after the user moved to another
      // tab. Do not let that request overwrite the active editor configuration.
      if (activation !== this.languageActivation || this.activeGroup !== groupIndex || group.activeId !== id) return
      doc.language = language
      doc.editorState = group.editor.getState()
    } catch (error) {
      console.error(`Failed to load syntax support for ${doc.name}:`, error)
    }
    if (activation !== this.languageActivation || this.activeGroup !== groupIndex || group.activeId !== id) return
    this.renderTabs()
    this.updateStatus()
    group.editor.focus()
    this.scheduleSessionSave()
    this.scheduleLanguageServerSync(doc)
    // Run again because a manually-selected HTML/Markdown language can reveal
    // an action even when the filename has no recognised extension.
    this.syncEditorChrome()
  }

  /** Update the active doc's cached content and refresh the dirty indicator. */
  private handleDocChange(groupIndex = this.activeGroup): void {
    const group = this.groups[groupIndex]
    const doc = group?.activeId ? this.docs.find((candidate) => candidate.id === group.activeId) : undefined
    if (!doc) return
    doc.content = group.editor.getContent()
    doc.editorState = group.editor.getState()
    for (const sibling of this.groups) {
      if (sibling.id !== groupIndex && sibling.activeId === doc.id && sibling.editor.getContent() !== doc.content) {
        sibling.editor.replaceContent(doc.content)
      }
    }
    this.renderTabs()
    // Live-update the markdown preview if it's showing this doc.
    if (this.preview.isVisible && this.isMarkdownDoc(doc)) {
      this.preview.update(doc.content)
    }
    // Persist drafts as the user types (debounced) so an unexpected quit or
    // machine crash never loses unsaved work — this is the core of hot exit.
    this.scheduleSessionSave()
    this.scheduleLanguageServerSync(doc)
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

  /** A non-blocking conflict action bar for external edits to dirty buffers. */
  private createConflictBar(): void {
    const bar = document.createElement('div')
    bar.className = 'external-conflict-bar hidden'
    const message = document.createElement('span')
    message.className = 'external-conflict-message'
    const addAction = (label: string, action: () => void): void => {
      const button = document.createElement('button')
      button.className = 'panel-button'
      button.textContent = label
      button.addEventListener('click', action)
      bar.appendChild(button)
    }
    bar.appendChild(message)
    addAction('Compare', () => this.compareExternalChange())
    addAction('Reload Disk', () => this.reloadExternalChange())
    addAction('Keep Local', () => this.keepLocalExternalChange())
    addAction('Save Local As…', () => { void this.saveExternalConflictAs() })
    this.editorArea.parentElement?.insertBefore(bar, this.editorArea)
    this.conflictBar = bar
  }

  private showExternalConflict(doc: Doc): void {
    if (!doc.externalChange || !this.conflictBar) return
    this.conflictDocId = doc.id
    const message = this.conflictBar.querySelector<HTMLElement>('.external-conflict-message')
    if (message) message.textContent = `“${doc.name}” changed on disk while you have unsaved edits.`
    this.conflictBar.classList.remove('hidden')
  }

  private hideExternalConflict(): void {
    this.conflictDocId = null
    this.conflictBar?.classList.add('hidden')
  }

  private get conflictDoc(): Doc | undefined {
    return this.docs.find((doc) => doc.id === this.conflictDocId && doc.externalChange)
  }

  /** Open an ephemeral comparison buffer without discarding either version. */
  private compareExternalChange(): void {
    const doc = this.conflictDoc
    if (!doc?.externalChange) return
    const comparison = createUntitled()
    comparison.name = `${doc.name} (disk version)`
    comparison.content = doc.externalChange.content
    comparison.savedContent = doc.externalChange.content
    comparison.language = doc.language
    comparison.languageLocked = true
    comparison.encoding = doc.externalChange.encoding
    comparison.eol = doc.externalChange.eol
    this.addDoc(comparison)
  }

  private reloadExternalChange(): void {
    const doc = this.conflictDoc
    if (!doc?.externalChange) return
    doc.content = doc.externalChange.content
    doc.savedContent = doc.externalChange.content
    doc.encoding = doc.externalChange.encoding
    doc.eol = doc.externalChange.eol
    doc.editorState = undefined
    doc.externalChange = undefined
    doc.ignoredExternalContent = undefined
    if (this.activeId === doc.id) void this.activate(doc.id)
    this.renderTabs()
    this.hideExternalConflict()
  }

  private keepLocalExternalChange(): void {
    const doc = this.conflictDoc
    if (!doc?.externalChange) return
    doc.ignoredExternalContent = doc.externalChange.content
    doc.externalChange = undefined
    this.renderTabs()
    this.hideExternalConflict()
  }

  private async saveExternalConflictAs(): Promise<void> {
    const doc = this.conflictDoc
    if (!doc) return
    const activeBefore = this.activeId
    if (activeBefore !== doc.id) await this.activate(doc.id)
    await this.save(true)
    if (activeBefore && activeBefore !== doc.id) await this.activate(activeBefore)
  }

  /**
   * Show/hide the per-document chrome that depends on the active file type:
   * the floating "open in browser" icon (HTML), the markdown preview icon, and
   * the markdown preview pane.
   */
  private syncEditorChrome(): void {
    const doc = this.active
    const canShowChrome = this.activeGroup === 0
    const html = canShowChrome && !!doc && (isHtml(doc.name) || doc.language === 'HTML')
    const md = canShowChrome && !!doc && this.isMarkdownDoc(doc)

    this.primaryHost.classList.toggle('has-minimap', this.settings.showMinimap)
    this.setActionVisible(this.browserBtn, html)
    this.setActionVisible(this.previewBtn, md)

    // If the preview is open but the new doc isn't markdown, hide it; if it is
    // markdown, refresh it with the new content.
    if (this.preview.isVisible) {
      if (md) this.preview.update(doc!.content)
      else this.preview.hide()
    }
    this.previewBtn.classList.toggle('active', this.preview.isVisible && md)
    if (doc?.externalChange) this.showExternalConflict(doc)
    else this.hideExternalConflict()
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
      const group = this.groups[this.activeGroup]
      if (group && !group.docIds.includes(existing.id)) group.docIds.push(existing.id)
      void this.activate(existing.id, this.activeGroup)
      return
    }
    try {
      const file = await window.editor.openPath(path)
      this.openLoadedFile(file)
    } catch (error) {
      this.showError(`Could not open “${baseName(path)}”.`, error)
    }
  }

  private currentLocation(): { path: string; line: number; column: number } | null {
    const doc = this.active
    if (!doc?.path) return null
    const selection = this.editor.view.state.selection.main
    const line = this.editor.view.state.doc.lineAt(selection.head)
    return { path: doc.path, line: line.number, column: selection.head - line.from + 1 }
  }

  private recordNavigation(): void {
    if (this.isNavigatingHistory) return
    const current = this.currentLocation()
    if (!current) return
    const previous = this.navigationBack[this.navigationBack.length - 1]
    if (!previous || previous.path !== current.path || previous.line !== current.line || previous.column !== current.column) {
      this.navigationBack.push(current)
      if (this.navigationBack.length > 100) this.navigationBack.shift()
    }
    this.navigationForward = []
  }

  private async openWorkspaceMatch(match: WorkspaceMatch): Promise<void> {
    this.recordNavigation()
    await this.openPath(match.path)
    this.editor.gotoLineNumber(match.line)
    const state = this.editor.view.state
    const line = state.doc.line(Math.max(1, Math.min(state.doc.lines, match.line)))
    this.editor.gotoPos(Math.min(line.to, line.from + match.column - 1))
  }

  private showFindResults(query: string, matches: WorkspaceMatch[]): void {
    this.focusGroup(0)
    this.findResults.setResults(query, matches)
    this.findResults.show()
    this.host.classList.add('hidden')
  }

  private hideFindResults(): void {
    this.findResults.hide()
    this.host.classList.remove('hidden')
  }

  private async openProjectSymbol(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before searching project symbols.')
      return
    }
    if (this.projectSymbols.length === 0 || Date.now() - this.projectSymbolIndexAt > 30_000) {
      try {
        this.projectSymbols = (await window.editor.listWorkspaceSymbols(this.folder)).filter(
          (symbol) => !this.isProjectExcluded(symbol.path)
        )
        this.projectSymbolIndexAt = Date.now()
      } catch (error) {
        this.showError('Project symbols could not be indexed.', error)
        return
      }
    }
    const symbols = this.projectSymbols
    this.palette.open({
      placeholder: 'Goto Symbol in Project',
      onQuery: (query) => {
        const source = query ? fuzzyFilter(query, symbols, (symbol) => `${symbol.label} ${symbol.path}`) : symbols.map((symbol) => ({ item: symbol }))
        return source.slice(0, 500).map(({ item }) => ({
          label: item.label,
          detail: `${item.path}:${item.line}`,
          value: item
        }))
      },
      onAccept: (item) => {
        const symbol = item.value as WorkspaceSymbol
        void this.openWorkspaceMatch({
          path: symbol.path,
          line: symbol.line,
          column: symbol.column,
          lineText: '',
          matchText: symbol.label
        })
      }
    })
  }

  private async navigateHistory(direction: -1 | 1): Promise<void> {
    const source = direction < 0 ? this.navigationBack : this.navigationForward
    const target = source.pop()
    if (!target) return
    const current = this.currentLocation()
    if (current) (direction < 0 ? this.navigationForward : this.navigationBack).push(current)
    this.isNavigatingHistory = true
    try {
      await this.openPath(target.path)
      const state = this.editor.view.state
      const line = state.doc.line(Math.max(1, Math.min(state.doc.lines, target.line)))
      this.editor.gotoPos(Math.min(line.to, line.from + target.column - 1))
    } finally {
      this.isNavigatingHistory = false
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
      const group = this.groups[this.activeGroup]
      if (group && !group.docIds.includes(existing.id)) group.docIds.push(existing.id)
      void this.activate(existing.id, this.activeGroup)
      return
    }
    // Replace a single pristine untitled buffer instead of stacking tabs.
    if (this.docs.length === 1 && this.docs[0].path === null && !isDirty(this.docs[0])) {
      const replacement = this.docs[0].id
      this.docs = []
      for (const group of this.groups) group.docIds = group.docIds.filter((id) => id !== replacement)
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
      this.project = (await window.editor.readProject(root)) ?? { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], languageTools: {}, languageServers: {}, buildSystems: [] }
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
        languageServers: parsed.languageServers && typeof parsed.languageServers === 'object' ? parsed.languageServers : {},
        buildSystems: Array.isArray(parsed.buildSystems) ? parsed.buildSystems : []
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
      this.tree.render(await window.editor.readDir(this.folder), true)
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
      if (isDirty(doc)) {
        if (doc.externalChange?.content === opened.content || doc.ignoredExternalContent === opened.content) return
        doc.externalChange = { content: opened.content, encoding: opened.encoding, eol: opened.eol }
        doc.ignoredExternalContent = undefined
        this.renderTabs()
        if (this.activeId === doc.id) this.showExternalConflict(doc)
        return
      }
      doc.content = opened.content
      doc.savedContent = opened.content
      doc.encoding = opened.encoding
      doc.eol = opened.eol
      doc.editorState = undefined
      doc.externalChange = undefined
      doc.ignoredExternalContent = undefined
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
    doc.externalChange = undefined
    doc.ignoredExternalContent = undefined
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
    this.hideExternalConflict()
  }

  /** Close the active tab, guarding against losing unsaved changes. */
  private closeActive(id = this.activeId): void {
    const doc = this.docs.find((candidate) => candidate.id === id)
    if (!doc) return
    if (isDirty(doc)) {
      const ok = confirm(`"${doc.name}" has unsaved changes. Close anyway?`)
      if (!ok) return
    }
    this.closeDocFromGroup(doc.id, this.activeGroup, false)
  }

  private closeDocFromGroup(id: string, groupIndex: number, confirmClose = true): void {
    const doc = this.docs.find((candidate) => candidate.id === id)
    const group = this.groups[groupIndex]
    if (!doc || !group) return
    if (confirmClose && isDirty(doc) && !confirm(`"${doc.name}" has unsaved changes. Close anyway?`)) return
    if (doc.path && !this.closedStack.includes(doc.path)) this.closedStack.push(doc.path)

    const index = group.docIds.indexOf(id)
    group.docIds = group.docIds.filter((docId) => docId !== id)
    if (group.activeId === id) group.activeId = group.docIds[Math.max(0, Math.min(index, group.docIds.length - 1))] ?? null

    const stillVisible = this.groups.some((candidate) => candidate.docIds.includes(id))
    if (!stillVisible) this.docs = this.docs.filter((candidate) => candidate.id !== id)
    if (this.docs.length === 0) {
      const fresh = createUntitled()
      this.docs.push(fresh)
      this.groups[0].docIds = [fresh.id]
      this.groups[0].activeId = fresh.id
    }
    if (groupIndex === this.activeGroup) {
      const next = group.activeId ?? this.docs[0].id
      void this.activate(next, groupIndex)
    }
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

  /** Cycle within the active group's tab order. */
  private cycleTab(delta: number): void {
    const group = this.groups[this.activeGroup]
    if (!group || group.docIds.length < 2) return
    const idx = group.docIds.indexOf(group.activeId ?? '')
    const next = (idx + delta + group.docIds.length) % group.docIds.length
    void this.activate(group.docIds[next], this.activeGroup)
  }

  /** Show or hide the sidebar. */
  private toggleSidebar(): void {
    this.sidebar.classList.toggle('hidden')
  }

  /** Legacy split shortcut now toggles a proper two-column editor group layout. */
  private toggleSplitEditor(): void {
    this.setLayout(this.layoutKind === 'columns2' ? 'single' : 'columns2')
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
      onAccept: (item) => this.editor.insertSnippet(String(item.value))
    })
  }

  private setDocumentEol(eol: Doc['eol']): void {
    const doc = this.active
    if (!doc) return
    doc.eol = eol
    this.updateStatus()
    this.scheduleSessionSave()
    this.statusSelection.textContent = `Save line endings as ${eol}`
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
    this.buildOutputText = ''
    this.buildPanel.toggle(true)
    try {
      await window.editor.runBuild({ root: this.folder, command })
    } catch (error) {
      this.showError('The build could not be started.', error)
    }
  }

  private selectBuildSystem(): void {
    const systems = this.project.buildSystems
    if (systems.length === 0) {
      this.showError('Add buildSystems to .lumen-project.json first.')
      return
    }
    const items: PaletteItem[] = []
    for (const system of systems) {
      items.push({ label: system.name, detail: system.command, value: { system } })
      for (const variant of system.variants ?? []) {
        items.push({
          label: `${system.name}: ${variant.name}`,
          detail: variant.command ?? system.command,
          value: { system: {
            ...system,
            name: `${system.name}: ${variant.name}`,
            command: variant.command ?? system.command,
            args: variant.args ?? system.args,
            workingDirectory: variant.workingDirectory ?? system.workingDirectory,
            fileRegex: variant.fileRegex ?? system.fileRegex
          } as BuildSystem }
        })
      }
    }
    this.palette.open({
      placeholder: 'Select Build System',
      items,
      onAccept: (item) => {
        this.activeBuildSystem = (item.value as { system: BuildSystem }).system
        this.buildPanel.setCommand(this.activeBuildSystem.command)
        void this.runBuildSystem(this.activeBuildSystem)
      }
    })
  }

  private async runBuildSystem(system: BuildSystem): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before running a build.')
      return
    }
    if (system.saveBeforeBuild) await this.save(false)
    if (!this.confirmExternalTool(system.command, `build system “${system.name}”`)) return
    this.activeBuildSystem = system
    this.buildPanel.setCommand(system.command)
    this.buildPanel.clear()
    this.buildOutputText = ''
    this.buildPanel.toggle(true)
    try {
      await window.editor.runBuild({
        root: this.folder,
        name: system.name,
        command: system.command,
        args: system.args,
        workingDirectory: system.workingDirectory,
        fileRegex: system.fileRegex
      })
    } catch (error) {
      this.showError('The build system could not be started.', error)
    }
  }

  private handleBuildOutput(output: BuildOutput): void {
    this.buildPanel.append(output)
    if (output.kind === 'stdout' || output.kind === 'stderr') this.buildOutputText += output.text
    if (output.kind === 'exit') this.buildPanel.setProblems(this.parseBuildProblems())
  }

  private parseBuildProblems(): BuildProblem[] {
    const root = this.folder
    if (!root) return []
    let matcher: RegExp
    try {
      matcher = this.activeBuildSystem?.fileRegex
        ? new RegExp(this.activeBuildSystem.fileRegex, 'gm')
        : /(?:^|\n)([^:\n]+):(\d+):(\d+):\s*(?:warning:\s*)?(.*)/gm
    } catch {
      return []
    }
    const problems: BuildProblem[] = []
    let match: RegExpExecArray | null
    while ((match = matcher.exec(this.buildOutputText)) && problems.length < 500) {
      const rawPath = match[1]
      const line = Number(match[2])
      const column = Number(match[3])
      const message = match[4] || match[0]
      if (!Number.isFinite(line) || !Number.isFinite(column)) continue
      const path = rawPath.startsWith('/') ? rawPath : `${root}/${rawPath}`
      problems.push({
        path,
        line: Math.max(1, line),
        column: Math.max(1, column),
        message: message.trim(),
        severity: /warning/i.test(match[0]) ? 'warning' : 'error'
      })
      if (match[0].length === 0) matcher.lastIndex += 1
    }
    return problems
  }

  private async openBuildProblem(problem: BuildProblem): Promise<void> {
    await this.openWorkspaceMatch({
      path: problem.path,
      line: problem.line,
      column: problem.column,
      lineText: '',
      matchText: problem.message
    })
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
        if (doc) doc.diagnostics = result.diagnostics
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
    const doc = this.active
    if (doc) doc.diagnostics = result.diagnostics
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
    // Keep all group-local active buffers current before snapshotting.
    for (const group of this.groups) {
      const doc = group.activeId ? this.docs.find((candidate) => candidate.id === group.activeId) : undefined
      if (doc) {
        doc.content = group.editor.getContent()
        doc.editorState = group.editor.getState()
      }
    }

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

    const indexForId = (id: string): number => {
      const doc = this.docs.find((candidate) => candidate.id === id)
      return doc ? openFiles.findIndex((file) => file.path === doc.path && file.name === doc.name) : -1
    }
    const activeDoc = this.active
    const activeIndex = activeDoc ? Math.max(0, indexForId(activeDoc.id)) : 0
    const layout: SessionLayout = {
      kind: this.layoutKind,
      activeGroup: this.activeGroup,
      groups: this.groups.map((group) => ({
        docIndexes: group.docIds.map(indexForId).filter((index) => index >= 0),
        activeIndex: Math.max(0, group.docIds.indexOf(group.activeId ?? ''))
      }))
    }

    const session: Session = { openFiles, activeIndex, folder: this.folder, layout }
    try {
      await window.editor.writeSession(session)
    } catch (error) {
      this.showError('Session recovery data could not be saved.', error)
    }
  }

  // ---- Rendering ----

  /** Rebuild each editor group's tab bar from its independent tab order. */
  private renderTabs(): void {
    for (const group of this.groups) {
      group.tabBar.replaceChildren()
      for (const id of group.docIds) {
        const doc = this.docs.find((candidate) => candidate.id === id)
        if (!doc) continue
        const tab = document.createElement('div')
        tab.className = 'tab' + (doc.id === group.activeId ? ' active' : '')

        const dot = document.createElement('span')
        dot.className = 'tab-dirty'
        dot.textContent = doc.externalChange ? '!' : isDirty(doc) ? '●' : ''
        dot.title = doc.externalChange ? 'Changed on disk' : isDirty(doc) ? 'Unsaved changes' : ''

        const label = document.createElement('span')
        label.className = 'tab-label'
        label.textContent = doc.name

        const close = document.createElement('span')
        close.className = 'tab-close'
        close.textContent = '×'
        close.addEventListener('click', (e) => {
          e.stopPropagation()
          this.closeDocFromGroup(doc.id, group.id)
        })

        tab.append(dot, label, close)
        tab.addEventListener('click', () => void this.activate(doc.id, group.id))
        group.tabBar.appendChild(tab)
      }
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
