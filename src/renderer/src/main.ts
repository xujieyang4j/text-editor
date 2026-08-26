import { Editor, allLanguageNames } from './editor.js'
import { FileTree } from './fileTree.js'
import { Palette, type PaletteItem } from './palette.js'
import { WorkspaceSearchPanel } from './workspaceSearch.js'
import { FindResultsView } from './findResults.js'
import { GitPanel } from './gitPanel.js'
import { openMarketplace } from './marketplace.js'
import { ExtensionHost } from './extensionHost.js'
import { incrementalChanges, revertIncrementalChange, type IncrementalChange } from './incrementalDiff.js'
import { JsonView } from './jsonView.js'
import { OutlinePanel } from './outlinePanel.js'
import { parseLosslessJson, stringifyLosslessJson } from '../../shared/losslessJson.js'
import { textStatistics, type TextStatistics } from '../../shared/text.js'
import { BuildPanel } from './buildPanel.js'
import { TerminalPanel } from './terminalPanel.js'
import { SettingsPanel } from './settingsPanel.js'
import { MarkdownPreview, isMarkdown, isHtml } from './preview.js'
import { COMMANDS, localizedCommands } from './commands.js'
import { extractSymbols } from './symbols.js'
import { fuzzyFilter } from './fuzzy.js'
import { makeTranslator, type TranslationKey } from '../../shared/i18n.js'
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
import type { CompletionContext, Completion } from '@codemirror/autocomplete'
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
  , type MarketplaceItem
  , type LanguageServerInteractiveResult
  , type LanguageRenameEdit
  , type GitAction
} from '../../shared/ipc.js'
import './styles.css'

/** Match the compact glob subset shared by project excludes, Goto and the file tree. */
function globMatches(relativePath: string, pattern: string, isDirectory = false): boolean {
  const glob = pattern.trim().replaceAll('\\', '/').replace(/^\.\//, '')
  if (!glob) return false
  const source = glob
    .replace(/[.+^${}()|[\]\\]/g, '\$&')
    .replace(/\*\*\//g, '(?:.*/)?')
    .replace(/\*\*/g, '.*')
    .replace(/\*/g, '[^/]*')
    .replace(/\?/g, '[^/]')
  const matcher = new RegExp(`^${source}$`, 'i')
  return matcher.test(relativePath) || (isDirectory && matcher.test(`${relativePath}/`))
}

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
  private gitPanel: GitPanel
  private buildPanel!: BuildPanel
  private terminalPanel!: TerminalPanel
  private settingsPanel!: SettingsPanel
  private preview!: MarkdownPreview
  private jsonView!: JsonView
  private outlinePanel!: OutlinePanel
  private docs: Doc[] = []
  private groups: EditorGroup[] = []
  private activeGroup = 0
  private layoutKind: LayoutKind = 'single'
  private settings: Settings = { ...DEFAULT_SETTINGS }
  private folder: string | null = null
  private folders: string[] = []
  private project: ProjectSettings = { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], pluginPermissions: {}, languageTools: {}, languageServers: {}, buildSystems: [], keyBindingRules: [], marketplaceUrls: [] }
  private plugins: PluginManifest[] = []
  private extensionHost = new ExtensionHost()
  private extensionCommands = new Map<string, { plugin: PluginManifest; title: string; run: () => void }>()
  /** Recently-closed file paths, for Reopen Closed Tab (LIFO). */
  private closedStack: string[] = []
  /** Debounce handle for session persistence. */
  private saveSessionTimer: number | null = null
  private autoSaveTimer: number | null = null
  private autoSaveInFlight = new Set<string>()
  /** Invalidates late language-loader completions after a tab changes. */
  private languageActivation = 0
  /** Commands executed while recording become the replayable macro. */
  private recordingMacro = false
  private lastMacro: MenuEvent[] = []
  private isReplayingMacro = false
  /** External formatter/LSP commands from project config require per-session consent. */
  private approvedExternalTools = new Set<string>()
  private booted = false
  /** Menu events can arrive while hot-exit restoration is still loading. */
  private pendingMenuEvents: MenuEvent[] = []
  private pendingLaunchPaths: string[] = []
  private workspacePollTimer: number | null = null
  private conflictBar: HTMLDivElement | null = null
  private conflictDocId: string | null = null
  private navigationBack: Array<{ path: string; line: number; column: number }> = []
  private navigationForward: Array<{ path: string; line: number; column: number }> = []
  private isNavigatingHistory = false
  private projectSymbols: WorkspaceSymbol[] = []
  private projectSymbolIndexAt = 0
  private workspaceWords: string[] = []
  private workspaceWordIndexAt = 0
  private lspSyncTimer: number | null = null
  private lspDocumentVersion = new Map<string, number>()
  private buildOutputText = ''
  /** Opaque session token prevents a delayed old-shell message affecting a new session. */
  private terminalSessionId: string | null = null
  /** Tracks a start request before the shell has acknowledged creation. */
  private terminalStartingSessionId: string | null = null
  private activeBuildSystem: BuildSystem | null = null
  private replaceUndoToken: string | null = null
  private windowSessionId = new URLSearchParams(location.hash.slice(1)).get('window') ?? 'legacy'
  private pendingKeySequence: string[] = []
  private pendingKeyTimer: number | null = null
  private recordedTextEdits: Array<{ from: number; to: number; insert: string }> = []
  private macroSteps: import('../../shared/ipc.js').MacroStep[] = []
  /** Avoid recording document changes generated by a macro command itself. */
  private suppressRecordedTextEdits = false
  /** Avoid duplicate macro edits while a cloned document is mirrored into another group. */
  private syncingGroupContent = false
  /** Ctrl/Cmd-click tab selection mirrors Sublime's tab multi-select. */
  private selectedTabIds = new Set<string>()
  private sidebarVisibleBeforeDistractionFree = false
  private dragDepth = 0
  private draggingTab: { groupId: number; docId: string } | null = null

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
  private gitPanelHost = document.getElementById('git-panel-host')!
  private outlinePanelHost = document.getElementById('outline-panel-host')!
  private browserBtn = document.getElementById('browser-btn') as HTMLButtonElement
  private previewBtn = document.getElementById('preview-btn') as HTMLButtonElement
  private jsonToolbar = document.getElementById('json-toolbar') as HTMLDivElement
  private jsonFormatBtn = document.getElementById('json-format-btn') as HTMLButtonElement
  private jsonCompactBtn = document.getElementById('json-compact-btn') as HTMLButtonElement
  private jsonViewBtn = document.getElementById('json-view-btn') as HTMLButtonElement

  private t: (key: TranslationKey) => string = makeTranslator(DEFAULT_SETTINGS.locale)

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
      onCopy: (path) => { void this.copyFile(path) },
      onRename: (path) => { void this.renamePath(path) },
      onMove: (path) => { void this.movePath(path) },
      onDelete: (path) => { void this.deletePath(path) },
      onReveal: (path) => { void window.editor.revealInFolder(path).catch((error: unknown) => this.showError('Could not reveal the item.', error)) },
      onCopyPath: (path, relative) => { void this.copyPath(path, relative) },
      onError: (message, error) => this.showError(message, error),
      isExcluded: (path, isDirectory) => this.isProjectExcluded(path, isDirectory)
    })
    this.searchPanel = new WorkspaceSearchPanel({
      getRoot: () => this.folder,
      getRoots: () => [...this.folders],
      getProjectExclude: () => this.project.exclude,
      getSearchHistory: () => this.settings.searchHistory,
      getReplaceHistory: () => this.settings.replaceHistory,
      openMatch: (match) => {
        void this.openPath(match.path).then(() => this.editor.gotoLineNumber(match.line))
      },
      notify: (message, error) => this.showError(message, error),
      afterReplace: () => {
        void this.reloadWorkspaceTree()
        this.renderTabs()
      },
      onResults: (query, matches) => this.showFindResults(query, matches),
      onReplaceComplete: (token, files, replacements) => {
        this.replaceUndoToken = token ?? null
        this.statusSelection.textContent = token
          ? `Replaced ${replacements} match${replacements === 1 ? '' : 'es'} in ${files} file${files === 1 ? '' : 's'} — undo is available`
          : `Replaced ${replacements} match${replacements === 1 ? '' : 'es'}`
      },
      onHistory: (search, replacement) => this.rememberSearchHistory(search, replacement)
    })
    this.findResults = new FindResultsView({
      onOpenMatch: (match) => { void this.openWorkspaceMatch(match) }
    })
    this.findResultsHost.appendChild(this.findResults.root)
    this.gitPanel = new GitPanel({
      onOpenFile: (relativePath) => {
        if (this.folder) void this.openPath(`${this.folder}/${relativePath}`)
      },
      onDiff: (relativePath) => this.folder ? window.editor.gitDiff(this.folder, relativePath) : Promise.reject(new Error('No workspace open.')),
      onHunks: (relativePath) => this.folder ? window.editor.gitHunks(this.folder, relativePath) : Promise.reject(new Error('No workspace open.')),
      onHistory: (relativePath) => this.folder ? window.editor.gitHistory(this.folder, relativePath) : Promise.reject(new Error('No workspace open.')),
      onBlame: (relativePath) => this.folder ? window.editor.gitBlame(this.folder, relativePath) : Promise.reject(new Error('No workspace open.')),
      onAction: (action, paths) => { void this.runGitAction(action, paths) },
      onHunkAction: (action, hunk) => { void this.runGitHunkAction(action, hunk) },
      onCommit: () => { void this.commitGitChanges() },
      onBranch: (create) => { void this.switchGitBranch(create) }
    })
    this.gitPanelHost.appendChild(this.gitPanel.element)
    this.outlinePanel = new OutlinePanel({
      onSelect: (symbol) => {
        this.recordNavigation()
        this.editor.gotoPos(symbol.pos)
        this.editor.focus()
      }
    })
    this.outlinePanelHost.appendChild(this.outlinePanel.element)
    this.createConflictBar()
    // The status-bar language field opens the syntax picker (like Sublime).
    this.statusLanguage.addEventListener('click', () => this.pickLanguage())
    this.statusLanguage.classList.add('clickable')

    // Floating browser icon (shown only for HTML docs) → open in browser.
    this.browserBtn.addEventListener('click', () => this.run('open-in-browser'))
    // Floating preview icon (shown only for markdown docs) → toggle preview.
    this.previewBtn.addEventListener('click', () => this.run('toggle-preview'))
    this.jsonFormatBtn.addEventListener('click', () => this.run('format-json'))
    this.jsonCompactBtn.addEventListener('click', () => this.run('compact-json'))
    this.jsonViewBtn.addEventListener('click', () => this.run('toggle-json-view'))

    this.bindMenu()
    this.bindShortcuts()
    this.bindFileDrop()
    window.addEventListener('blur', () => {
      if (this.settings.autoSave === 'on_focus_change') void this.autoSaveDirtyDocuments()
    })
    window.editor.onFileChange((change) => {
      if (this.folder) void this.reloadWorkspaceTree()
      this.projectSymbols = []
      this.workspaceWords = []
      void this.handleExternalFileChange(change.path)
    })
    window.editor.onOpenPathRequested((filePath) => {
      if (this.booted) void this.openPath(filePath)
      else this.pendingLaunchPaths.push(filePath)
    })
    window.editor.onBuildOutput((output) => this.handleBuildOutput(output))
    window.editor.onTerminalOutput((output) => this.handleTerminalOutput(output))
    window.editor.onLanguageServerDiagnostics((event) => this.applyLanguageServerDiagnostics(event))
    void this.boot()
  }

  /** Load settings, construct the editor, then restore the previous session. */
  private async boot(): Promise<void> {
    try {
      await window.editor.registerWindowSession(this.windowSessionId)
    } catch (error) {
      this.showError('Window session could not be registered.', error)
    }
    try {
      this.settings = await window.editor.readSettings()
    } catch (error) {
      this.showError('Settings could not be read; safe defaults were used.', error)
      this.settings = { ...DEFAULT_SETTINGS }
    }
    document.documentElement.dataset.colorScheme = this.settings.colorScheme
    void window.editor.setMenuLocale(this.settings.locale).catch(() => undefined)
    this.applyLocale(this.settings.locale)
    this.applyDistractionFreeMode(this.settings.distractionFree)

    this.primaryEditor = new Editor(
      this.primaryHost,
      {
        onDocChange: () => this.handleDocChange(),
        onTextEdits: (edits) => this.recordTextEdits(edits),
        onCursorChange: (state) => {
          this.updatePositionStatus(state)
          this.captureActiveViewState()
        },
        onViewChange: () => this.captureActiveViewState(),
        onCompletion: (context) => this.requestLspCompletions(context),
        onTab: () => this.expandSnippetTrigger()
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
    this.bindTabBarDragDrop(this.groups[0])

    this.preview = new MarkdownPreview(this.primaryEditorArea)
    this.jsonView = new JsonView({
      onReplace: (next) => this.editor.replaceContent(next),
      notify: (message) => this.statusSelection.textContent = message
    })
    this.primaryEditorArea.appendChild(this.jsonView.root)
    this.buildPanel = new BuildPanel(
      this.settings.buildCommand,
      {
        onRun: (command) => { void this.runBuild(command) },
        onCancel: () => { void window.editor.cancelBuild() },
        onOpenProblem: (problem) => { void this.openBuildProblem(problem) }
      }
    )
    this.terminalPanel = new TerminalPanel({
      onStart: () => { void this.startTerminal() },
      onWrite: (text) => { void this.writeTerminal(text) },
      onStop: () => { void this.stopTerminal() }
    })
    this.settingsPanel = new SettingsPanel(this.settings, {
      onChange: (settings) => this.applyUserSettings(settings)
    })
    this.applyLocale(this.settings.locale)

    try {
      await this.restoreSession()
      this.booted = true
      for (const filePath of this.pendingLaunchPaths.splice(0)) await this.openPath(filePath)
      for (const event of this.pendingMenuEvents.splice(0)) this.run(event)
      this.startWorkspacePolling()
    } catch (error) {
      this.showError('The previous session could not be restored.', error)
      this.docs = [createUntitled()]
      await this.activate(this.docs[0].id)
      this.booted = true
      for (const event of this.pendingMenuEvents.splice(0)) this.run(event)
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

    const sessionFolders = session.folders?.length ? session.folders : session.folder ? [session.folder] : []
    if (sessionFolders.length > 0) {
      for (const root of sessionFolders) await this.addFolderPath(root, this.folders.length === 0)
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
   * Accept only operating-system file drops. Path extraction is deliberately
   * confined to preload, then main validates and grants each path before any
   * content reaches this renderer.
   */
  private bindFileDrop(): void {
    const isLocalFileDrop = (event: DragEvent): boolean => Array.from(event.dataTransfer?.types ?? []).includes('Files')
    window.addEventListener('dragenter', (event) => {
      if (!isLocalFileDrop(event)) return
      event.preventDefault()
      this.dragDepth += 1
      document.body.classList.add('file-drop-active')
    })
    window.addEventListener('dragover', (event) => {
      if (!isLocalFileDrop(event)) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    })
    window.addEventListener('dragleave', (event) => {
      if (!isLocalFileDrop(event)) return
      event.preventDefault()
      this.dragDepth = Math.max(0, this.dragDepth - 1)
      if (this.dragDepth === 0) document.body.classList.remove('file-drop-active')
    })
    window.addEventListener('drop', (event) => {
      if (!isLocalFileDrop(event)) return
      event.preventDefault()
      this.dragDepth = 0
      document.body.classList.remove('file-drop-active')
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length > 0) void this.openDroppedFiles(files)
    })
  }

  /**
   * Central command dispatch. The native menu, keyboard shortcuts and the
   * command palette all funnel through here so behaviour stays consistent.
   */
  run(event: MenuEvent): void {
    if (!this.booted && event !== 'persist-session') {
      this.pendingMenuEvents.push(event)
      return
    }
    if (this.recordingMacro && !this.isReplayingMacro && this.isRecordableMacroEvent(event)) {
      this.lastMacro.push(event)
      this.macroSteps.push({ kind: 'command', command: event })
      this.suppressRecordedTextEdits = true
      queueMicrotask(() => { this.suppressRecordedTextEdits = false })
    }
    switch (event) {
      case 'new-file':
        this.addDoc(createUntitled())
        break
      case 'new-window':
        void window.editor.newWindow()
        break
      case 'add-folder-to-project':
        void this.addFolderToProject()
        break
      case 'remove-folder-from-project':
        void this.removeFolderFromProject()
        break
      case 'open-recent-project':
        void this.openRecentProject()
        break
      case 'open-recent-file':
        void this.openRecentFile()
        break
      case 'import-sublime-project':
        void this.importSublimeProject()
        break
      case 'import-sublime-settings':
        void this.importSublimeSettings()
        break
      case 'import-sublime-snippet':
        void this.importSublimeSnippet()
        break
      case 'import-sublime-keymap':
        void this.importSublimeKeymap()
        break
      case 'set-ui-language-zh':
        this.setLocale('zh-CN')
        break
      case 'set-ui-language-en':
        this.setLocale('en-US')
        break
      case 'open-settings':
        this.settingsPanel.toggle(true)
        break
      case 'lsp-hover':
        void this.showLspHover()
        break
      case 'lsp-definition':
        void this.runLspLocations('definition')
        break
      case 'lsp-references':
        void this.runLspLocations('references')
        break
      case 'lsp-rename':
        void this.renameLspSymbol()
        break
      case 'open-file':
        void this.openViaDialog()
        break
      case 'open-folder':
        void this.openFolder()
        break
      case 'copy-file-path':
        void this.copyActivePath(false)
        break
      case 'copy-relative-file-path':
        void this.copyActivePath(true)
        break
      case 'save':
        void this.save(false)
        break
      case 'save-as':
        void this.save(true)
        break
      case 'save-all':
        void this.saveAll()
        break
      case 'cycle-auto-save':
        this.cycleAutoSave()
        break
      case 'close-tab':
        this.closeActive()
        break
      case 'close-other-tabs':
        void this.closeTabs('others')
        break
      case 'close-tabs-to-right':
        void this.closeTabs('right')
        break
      case 'close-all-tabs':
        void this.closeTabs('all')
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
      case 'undo-replace-in-files':
        void this.undoReplaceInFiles()
        break
      case 'find-results-next':
        this.findResults.move(1)
        break
      case 'find-results-prev':
        this.findResults.move(-1)
        break
      case 'next-change':
        this.navigateIncrementalChange(1)
        break
      case 'prev-change':
        this.navigateIncrementalChange(-1)
        break
      case 'revert-current-change':
        this.revertCurrentIncrementalChange()
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
      case 'split-selected-tabs':
        this.splitSelectedTabs()
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
      case 'save-macro':
        void this.saveMacro()
        break
      case 'run-saved-macro':
        void this.runSavedMacro()
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
      case 'import-sublime-build':
        void this.importSublimeBuild()
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
        if (!this.editor.joinLines()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN'
            ? '没有可合并的相邻行'
            : 'No adjacent lines to join'
        }
        break
      case 'split-selection-lines':
        if (!this.editor.splitSelectionIntoLines()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN'
            ? '请先选择一个或多个文本行'
            : 'Select one or more text lines first'
        }
        break
      case 'indent-selection':
        this.editor.indentSelection()
        break
      case 'outdent-selection':
        this.editor.outdentSelection()
        break
      case 'reindent-selection':
        if (!this.editor.reindentSelection()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN'
            ? '当前选区没有可重新缩进的行'
            : 'No selected lines could be reindented'
        }
        break
      case 'toggle-problems':
        this.buildPanel.toggle()
        break
      case 'toggle-terminal':
        this.toggleTerminal()
        break
      case 'document-statistics':
        this.showDocumentStatistics()
        break
      case 'toggle-outline':
        this.settings.showOutline = !this.settings.showOutline
        if (this.settings.showOutline && !this.settings.distractionFree) this.sidebar.classList.remove('hidden')
        this.applyUserSettings(this.settings)
        break
      case 'fold-current':
        this.runFoldCommand('fold-current')
        break
      case 'unfold-current':
        this.runFoldCommand('unfold-current')
        break
      case 'fold-all':
        this.runFoldCommand('fold-all')
        break
      case 'unfold-all':
        this.runFoldCommand('unfold-all')
        break
      case 'select-color-scheme':
        this.selectColorScheme()
        break
      case 'toggle-git':
        this.gitPanel.toggle()
        void this.refreshGit()
        break
      case 'refresh-git':
        void this.refreshGit()
        break
      case 'open-git-conflicts':
        void this.openGitConflicts()
        break
      case 'check-for-updates':
        void this.checkForUpdates()
        break
      case 'open-marketplace':
        void this.openMarketplace()
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
      case 'goto-matching-bracket':
        this.recordNavigation()
        if (!this.editor.gotoMatchingBracket()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN' ? '当前位置没有匹配括号' : 'No matching bracket at the cursor'
        }
        break
      case 'toggle-sidebar':
        this.toggleSidebar()
        break
      case 'toggle-word-wrap':
        this.settings.wordWrap = !this.settings.wordWrap
        this.applyUserSettings(this.settings)
        break
      case 'toggle-theme':
        this.settings.colorScheme = this.settings.colorScheme === 'light' ? 'dark' : 'light'
        this.settings.theme = this.settings.colorScheme === 'light' ? 'light' : 'dark'
        this.applyUserSettings(this.settings)
        break
      case 'toggle-minimap':
        this.settings.showMinimap = !this.settings.showMinimap
        this.applyUserSettings(this.settings)
        break
      case 'toggle-distraction-free':
        this.settings.distractionFree = !this.settings.distractionFree
        this.applyUserSettings(this.settings)
        break
      case 'toggle-spell-check':
        this.settings.spellCheck = !this.settings.spellCheck
        this.applyUserSettings(this.settings)
        this.statusSelection.textContent = `Spell Check: ${this.settings.spellCheck ? 'on' : 'off'}`
        break
      case 'format-json':
        this.transformJson(true)
        break
      case 'compact-json':
        this.transformJson(false)
        break
      case 'toggle-json-view':
        this.toggleJsonView()
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
      case 'toggle-block-comment':
        this.editor.toggleBlockComment()
        break
      case 'add-cursor-above':
        this.editor.addCursorAbove()
        break
      case 'add-cursor-below':
        this.editor.addCursorBelow()
        break
      case 'select-next-occurrence':
        this.editor.selectNextOccurrence()
        break
      case 'select-all-occurrences':
        this.editor.selectAllOccurrences()
        break
      case 'select-line':
        this.editor.selectCurrentLine()
        break
      case 'select-matching-bracket':
        if (!this.editor.selectToMatchingBracket()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN' ? '当前位置没有匹配括号' : 'No matching bracket at the cursor'
        }
        break
      case 'select-parent-syntax':
        if (!this.editor.selectEnclosingSyntax()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN'
            ? '当前位置没有可选中的外层语法结构'
            : 'No enclosing syntax structure at the cursor'
        }
        break
      case 'expand-selection':
        this.editor.expandSelection()
        break
      case 'shrink-selection':
        this.editor.shrinkSelection()
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
      case 'delete-word-backward':
        this.editor.deletePreviousWord()
        break
      case 'delete-word-forward':
        this.editor.deleteNextWord()
        break
      case 'delete-to-line-start':
        this.editor.deleteToStartOfLine()
        break
      case 'delete-to-line-end':
        this.editor.deleteToEndOfLine()
        break
      case 'insert-blank-line-above':
        this.editor.insertBlankLineAbove()
        break
      case 'insert-blank-line':
        this.editor.insertBlankLineBelow()
        break
      case 'transpose-characters':
        if (!this.editor.transposeCharacters()) {
          this.statusSelection.textContent = this.settings.locale === 'zh-CN' ? '当前位置无法转置字符' : 'No characters to transpose at the cursor'
        }
        break
      case 'duplicate-selection':
        this.editor.duplicateSelection()
        break
      case 'sort-lines':
        this.editor.sortLines()
        break
      case 'font-zoom-in':
        this.settings.fontSize = Math.min(40, this.settings.fontSize + 1)
        this.applyUserSettings(this.settings)
        break
      case 'font-zoom-out':
        this.settings.fontSize = Math.max(8, this.settings.fontSize - 1)
        this.applyUserSettings(this.settings)
        break
      case 'font-zoom-reset':
        this.settings.fontSize = DEFAULT_SETTINGS.fontSize
        this.applyUserSettings(this.settings)
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
      if (e.key === 'Escape' && this.settings.distractionFree && !this.palette.isOpen) {
        this.settings.distractionFree = false
        this.applyDistractionFreeMode(false)
        this.persistSettings()
        return
      }
      if (this.dispatchKeyBindingRule(e)) return
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

  private dispatchKeyBindingRule(event: KeyboardEvent): boolean {
    const context = this.currentKeyContext()
    const key = this.shortcutString(event)
    const candidate = [...this.pendingKeySequence, key]
    const rules = this.project.keyBindingRules
    const matching = rules.filter((rule) => {
      const sequence = Array.isArray(rule.keys) ? rule.keys : [rule.keys]
      return (!rule.when || rule.when === context) && candidate.every((part, index) => sequence[index] === part)
    })
    if (matching.length === 0) {
      this.clearKeySequence()
      return false
    }
    event.preventDefault()
    const completed = matching.find((rule) => {
      const sequence = Array.isArray(rule.keys) ? rule.keys : [rule.keys]
      return sequence.length === candidate.length
    })
    if (completed && this.isMenuEvent(completed.command)) {
      this.clearKeySequence()
      this.run(completed.command)
      return true
    }
    this.pendingKeySequence = candidate
    if (this.pendingKeyTimer !== null) window.clearTimeout(this.pendingKeyTimer)
    this.pendingKeyTimer = window.setTimeout(() => this.clearKeySequence(), 1_500)
    this.statusSelection.textContent = `Key sequence: ${candidate.join(' ')}`
    return true
  }

  private currentKeyContext(): 'editor' | 'find-results' | 'git' | 'build' {
    if (!this.findResults.element.classList.contains('hidden')) return 'find-results'
    if (!this.gitPanel.element.classList.contains('hidden')) return 'git'
    if (document.querySelector('.build-panel:not(.hidden)')) return 'build'
    return 'editor'
  }

  private clearKeySequence(): void {
    this.pendingKeySequence = []
    if (this.pendingKeyTimer !== null) window.clearTimeout(this.pendingKeyTimer)
    this.pendingKeyTimer = null
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
      active.groupStates.set(currentGroup.id, currentGroup.editor.getState())
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
    tabBar.classList.toggle('hidden', this.settings.distractionFree)
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
        onTextEdits: (edits) => this.recordTextEdits(edits),
        onCursorChange: (state) => {
          if (this.activeGroup === id) this.updatePositionStatus(state)
          this.captureViewState(id)
        },
        onViewChange: () => this.captureViewState(id),
        onCompletion: (context) => this.requestLspCompletions(context),
        onTab: () => this.expandSnippetTrigger()
      },
      this.settings
    )
    root.addEventListener('mousedown', () => this.focusGroup(id))
    this.bindTabBarDragDrop(group)
    return group
  }

  /** Bind each group's background drop target once; tab rows are rebuilt often. */
  private bindTabBarDragDrop(group: EditorGroup): void {
    group.tabBar.addEventListener('dragover', (event) => {
      if (!this.draggingTab || this.draggingTab.groupId !== group.id) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    })
    group.tabBar.addEventListener('drop', (event) => {
      const dragging = this.draggingTab
      if (!dragging || dragging.groupId !== group.id || (event.target as HTMLElement).closest('.tab')) return
      event.preventDefault()
      this.reorderTabs(group.id, dragging.docId, null, false)
    })
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

  private selectedDocs(group: EditorGroup): string[] {
    const selected = group.docIds.filter((id) => this.selectedTabIds.has(id))
    return selected.length > 0 ? selected : group.activeId ? [group.activeId] : []
  }

  /** Open the selected tabs side by side, preserving their independent views. */
  private splitSelectedTabs(): void {
    const source = this.groups[this.activeGroup]
    if (!source) return
    const ids = this.selectedDocs(source)
    if (ids.length < 2) {
      this.moveActiveToNextGroup(true)
      return
    }
    const needed = Math.min(4, Math.max(2, ids.length))
    this.setLayout(needed === 2 ? 'columns2' : needed === 3 ? 'columns3' : 'grid4')
    for (const [index, id] of ids.entries()) {
      const target = this.groups[index]
      if (!target.docIds.includes(id)) target.docIds.push(id)
      target.activeId = id
    }
    this.selectedTabIds.clear()
    this.focusGroup(0)
    this.renderTabs()
    this.scheduleSessionSave()
  }

  /** Keep the configured LSP alive and sync active saved files after edits settle. */
  private scheduleLanguageServerSync(doc: Doc): void {
    const root = this.workspaceRootForPath(doc.path)
    if (!root || !doc.path || !this.project.languageServers[doc.language]) return
    if (this.lspSyncTimer !== null) window.clearTimeout(this.lspSyncTimer)
    this.lspSyncTimer = window.setTimeout(() => {
      const latest = this.docs.find((candidate) => candidate.id === doc.id)
      if (latest) void this.syncLanguageServer(latest)
    }, 250)
  }

  private async syncLanguageServer(doc: Doc): Promise<void> {
    const root = this.workspaceRootForPath(doc.path)
    if (!root || !doc.path) return
    const config = this.project.languageServers[doc.language]
    if (!config || !this.confirmExternalTool(config.command, `language server for ${doc.language}`)) return
    const version = (this.lspDocumentVersion.get(doc.path) ?? 0) + 1
    this.lspDocumentVersion.set(doc.path, version)
    try {
      await window.editor.syncLanguageServer({
        root,
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

  private async requestLsp(method: 'completion' | 'hover' | 'definition' | 'references' | 'rename', newName?: string): Promise<LanguageServerInteractiveResult | null> {
    const doc = this.active
    const root = this.workspaceRootForPath(doc?.path ?? null)
    if (!root || !doc?.path) {
      this.showError('Open a saved file in a workspace before using this language feature.')
      return null
    }
    const config = this.project.languageServers[doc.language]
    if (!config) {
      this.showError(`No language server is configured for ${doc.language}.`)
      return null
    }
    if (!this.confirmExternalTool(config.command, `language server for ${doc.language}`)) return null
    const selection = this.editor.view.state.selection.main
    const line = this.editor.view.state.doc.lineAt(selection.head)
    try {
      return await window.editor.requestLanguageServer({
        root,
        config,
        content: this.editor.getContent(),
        filePath: doc.path,
        languageId: doc.language.toLowerCase().replaceAll(' ', '-'),
        method,
        line: line.number - 1,
        character: selection.head - line.from,
        ...(newName ? { newName } : {})
      })
    } catch (error) {
      this.showError(`Language server ${method} request failed.`, error)
      return null
    }
  }

  private async requestLspCompletions(context: CompletionContext): Promise<Completion[] | null> {
    const doc = this.active
    if (!doc?.path || !this.workspaceRootForPath(doc.path) || !this.project.languageServers[doc.language]) {
      return this.workspaceWordCompletions(context)
    }
    const line = context.state.doc.lineAt(context.pos)
    const result = await this.requestLspAt('completion', line.number - 1, context.pos - line.from)
    const lsp = result?.completions?.map((item) => ({
      label: item.label,
      ...(item.detail ? { detail: item.detail } : {}),
      ...(item.documentation ? { info: item.documentation } : {}),
      ...(item.insertText ? { apply: item.insertText } : {})
    })) ?? []
    return lsp.length > 0 ? lsp : this.workspaceWordCompletions(context)
  }

  /** Sublime-like word completions when a project does not configure an LSP. */
  private workspaceWordCompletions(context: CompletionContext): Completion[] | null {
    const token = context.matchBefore(/[A-Za-z_$][\w$]*/)?.text ?? ''
    if (token.length < 2) return null
    const words = new Set<string>()
    const addWords = (text: string): void => {
      for (const word of text.match(/[A-Za-z_$][\w$]{1,80}/g) ?? []) {
        if (word !== token && word.toLowerCase().startsWith(token.toLowerCase())) words.add(word)
        if (words.size >= 300) return
      }
    }
    for (const doc of this.docs) addWords(doc.content)
    for (const word of this.workspaceWords) {
      if (word !== token && word.toLowerCase().startsWith(token.toLowerCase())) words.add(word)
      if (words.size >= 300) break
    }
    if (words.size < 300) addWords(context.state.doc.toString())
    if (this.workspaceWords.length === 0 || Date.now() - this.workspaceWordIndexAt > 60_000) void this.ensureWorkspaceWords()
    const ordered = [...words].sort((a, b) => a.localeCompare(b)).slice(0, 100)
    return ordered.length > 0 ? ordered.map((label) => ({ label, type: 'text', detail: 'workspace word' })) : null
  }

  private async ensureWorkspaceWords(): Promise<void> {
    if (this.folders.length === 0 || (this.workspaceWords.length > 0 && Date.now() - this.workspaceWordIndexAt <= 60_000)) return
    try {
      this.workspaceWords = (await Promise.all(this.folders.map((root) => window.editor.listWorkspaceWords(root)))).flat()
      this.workspaceWordIndexAt = Date.now()
    } catch {
      // Open-buffer completion remains useful if the project index is unavailable.
    }
  }

  private async requestLspAt(
    method: 'completion' | 'hover' | 'definition' | 'references' | 'rename',
    line: number,
    character: number,
    newName?: string
  ): Promise<LanguageServerInteractiveResult | null> {
    const doc = this.active
    const root = this.workspaceRootForPath(doc?.path ?? null)
    if (!root || !doc?.path) return null
    const config = this.project.languageServers[doc.language]
    if (!config || !this.confirmExternalTool(config.command, `language server for ${doc.language}`)) return null
    try {
      return await window.editor.requestLanguageServer({
        root,
        config,
        content: this.editor.getContent(),
        filePath: doc.path,
        languageId: doc.language.toLowerCase().replaceAll(' ', '-'),
        method,
        line,
        character,
        ...(newName ? { newName } : {})
      })
    } catch (error) {
      this.showError(`Language server ${method} request failed.`, error)
      return null
    }
  }

  private async showLspHover(): Promise<void> {
    const result = await this.requestLsp('hover')
    const text = result?.hover?.text?.trim()
    if (!text) {
      this.statusSelection.textContent = 'No hover information'
      return
    }
    window.alert(text)
  }

  private async runLspLocations(method: 'definition' | 'references'): Promise<void> {
    const doc = this.active
    const hasLsp = !!doc?.path && !!this.workspaceRootForPath(doc.path) && !!this.project.languageServers[doc.language]
    if (!hasLsp) {
      await this.runIndexedLocations(method)
      return
    }
    const result = await this.requestLsp(method)
    const locations = result?.locations ?? []
    if (locations.length === 0) {
      this.statusSelection.textContent = method === 'definition' ? 'No definition found' : 'No references found'
      return
    }
    if (method === 'definition' && locations.length === 1) {
      const location = locations[0]
      await this.openWorkspaceMatch({
        path: location.filePath,
        line: location.line + 1,
        column: location.character + 1,
        lineText: '',
        matchText: ''
      })
      return
    }
    const matches: WorkspaceMatch[] = locations.map((location) => ({
      path: location.filePath,
      line: location.line + 1,
      column: location.character + 1,
      lineText: method === 'definition' ? 'Definition' : 'Reference',
      matchText: method
    }))
    this.showFindResults(method === 'definition' ? 'Definitions' : 'References', matches)
  }

  /** Fast symbol-index fallback for projects that do not run an LSP server. */
  private async runIndexedLocations(method: 'definition' | 'references'): Promise<void> {
    const doc = this.active
    if (!doc?.path || this.folders.length === 0) {
      this.showError('Open a saved file in a project before using symbol navigation.')
      return
    }
    const selection = this.editor.view.state.selection.main
    const source = this.editor.getContent()
    const left = source.slice(0, selection.head)
    const right = source.slice(selection.head)
    const word = /[A-Za-z_$][\w$]*$/.exec(left)?.[0] ?? /^[A-Za-z_$][\w$]*/.exec(right)?.[0]
    if (!word) {
      this.statusSelection.textContent = 'Place the cursor on a symbol name'
      return
    }
    try {
      await this.ensureProjectSymbols()
      const exact = this.projectSymbols.filter((symbol) => symbol.label === word)
      if (method === 'definition') {
        const local = extractSymbols(source).find((symbol) => symbol.label === word)
        if (local) {
          await this.openWorkspaceMatch({ path: doc.path, line: local.line, column: 1, lineText: '', matchText: word })
          return
        }
        const target = exact[0]
        if (!target) {
          this.statusSelection.textContent = `No indexed definition found for ${word}`
          return
        }
        await this.openWorkspaceMatch({ path: target.path, line: target.line, column: target.column, lineText: '', matchText: word })
        return
      }
      const matches = await window.editor.searchWorkspace({
        root: this.folder!,
        roots: this.folders,
        query: word,
        caseSensitive: /[A-Z]/.test(word),
        wholeWord: true,
        useRegex: false,
        exclude: this.project.exclude.join(','),
        maxResults: 5_000
      })
      if (matches.length === 0) {
        this.statusSelection.textContent = `No references found for ${word}`
        return
      }
      this.showFindResults(`References: ${word}`, matches)
    } catch (error) {
      this.showError('Project symbol index could not be queried.', error)
    }
  }

  private async renameLspSymbol(): Promise<void> {
    const name = window.prompt('New symbol name:')?.trim()
    if (!name) return
    const result = await this.requestLsp('rename', name)
    const edits = result?.renameEdits ?? []
    if (edits.length === 0) {
      this.statusSelection.textContent = 'No rename edits returned'
      return
    }
    if (!window.confirm(`Apply ${edits.length} rename edit${edits.length === 1 ? '' : 's'} across ${new Set(edits.map((edit) => edit.filePath)).size} file${new Set(edits.map((edit) => edit.filePath)).size === 1 ? '' : 's'}?`)) return
    await this.applyLspRenameEdits(edits)
  }

  private async applyLspRenameEdits(edits: LanguageRenameEdit[]): Promise<void> {
    const grouped = new Map<string, LanguageRenameEdit[]>()
    for (const edit of edits) grouped.set(edit.filePath, [...(grouped.get(edit.filePath) ?? []), edit])
    for (const [filePath, fileEdits] of grouped) {
      const doc = this.docs.find((candidate) => candidate.path === filePath)
      let content: string
      let encoding: Doc['encoding'] = 'utf8'
      let eol: Doc['eol'] = 'LF'
      if (doc) {
        content = doc.content
        encoding = doc.encoding
        eol = doc.eol
      } else {
        const opened = await window.editor.openPath(filePath)
        if (opened.isBinary || opened.isTooLarge) throw new Error(`Cannot rename inside non-text file ${baseName(filePath)}.`)
        content = opened.content
        encoding = opened.encoding
        eol = opened.eol
      }
      const lines = content.split('\n')
      const offset = (lineIndex: number, character: number): number => {
        const line = Math.max(0, Math.min(lines.length - 1, lineIndex))
        let value = 0
        for (let index = 0; index < line; index += 1) value += lines[index].length + 1
        return value + Math.max(0, Math.min(lines[line].length, character))
      }
      let next = content
      for (const edit of [...fileEdits].sort((a, b) => offset(b.startLine, b.startCharacter) - offset(a.startLine, a.startCharacter))) {
        next = `${next.slice(0, offset(edit.startLine, edit.startCharacter))}${edit.newText}${next.slice(offset(edit.endLine, edit.endCharacter))}`
      }
      if (doc) {
        doc.content = next
        doc.savedContent = next
        doc.editorState = undefined
        if (this.activeId === doc.id) await this.activate(doc.id)
      }
      const result = await window.editor.save(filePath, next, { encoding, eol })
      if (!result.saved) throw new Error(`Could not write ${baseName(filePath)}.`)
    }
    this.renderTabs()
    this.statusSelection.textContent = `Renamed symbol in ${grouped.size} file${grouped.size === 1 ? '' : 's'}`
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

  private captureActiveViewState(): void {
    this.captureViewState(this.activeGroup)
  }

  /** Persist only serialisable selection/scroll data; undo/folds stay in memory. */
  private captureViewState(groupId: number): void {
    const group = this.groups[groupId]
    const doc = group?.activeId ? this.docs.find((candidate) => candidate.id === group.activeId) : undefined
    if (!group || !doc) return
    doc.viewStates.set(groupId, group.editor.getViewState(groupId))
    this.scheduleSessionSave()
  }

  /**
   * Switch a group to a document, preserving the previous group's editor state.
   *
   * A closing tab has already been removed from its group before activation, so
   * its editor content must not be assigned to the newly selected tab.
   */
  private async activate(id: string, groupIndex = this.activeGroup, preservePrevious = true): Promise<void> {
    const previousGroup = this.groups[this.activeGroup]
    const previousId = previousGroup?.activeId
    const previous = previousId ? this.docs.find((doc) => doc.id === previousId) : undefined
    if (preservePrevious && previous && previousGroup) {
      previous.content = previousGroup.editor.getContent()
      previous.editorState = previousGroup.editor.getState()
      previous.groupStates.set(previousGroup.id, previousGroup.editor.getState())
      previous.viewStates.set(previousGroup.id, previousGroup.editor.getViewState(previousGroup.id))
    }

    const group = this.groups[groupIndex]
    const doc = this.docs.find((candidate) => candidate.id === id)
    if (!group || !doc) return
    if (!group.docIds.includes(id)) group.docIds.push(id)
    this.activeGroup = groupIndex
    group.activeId = id
    this.hideFindResults()
    const activation = ++this.languageActivation
    group.editor.setDocument(doc.content, doc.groupStates.get(groupIndex) ?? doc.editorState)
    group.editor.restoreViewState(doc.viewStates.get(groupIndex))
    const indentation = this.detectIndentation(doc.content)
    group.editor.setIndentation(indentation.tabSize, indentation.insertSpaces)
    this.refreshIncrementalDiff(doc, group.editor)
    group.editor.setDiagnostics((doc.diagnostics ?? []).map((diagnostic) => this.toCodeMirrorDiagnostic(diagnostic)))

    // File-name based actions (HTML browser / Markdown preview) must appear
    // immediately. Language support is lazy-loaded and must not delay or block
    // the toolbar when a language chunk is slow or fails to load.
    this.syncEditorChrome()
    this.syncOutline(true)

    try {
      const language = !doc.languageLocked
        ? await group.editor.setLanguageForFile(doc.name)
        : await group.editor.setLanguageByName(doc.language)
      // A slow lazy language bundle can finish after the user moved to another
      // tab. Do not let that request overwrite the active editor configuration.
      if (activation !== this.languageActivation || this.activeGroup !== groupIndex || group.activeId !== id) return
      doc.language = language
      group.editor.setSpellCheck(this.settings.spellCheck && (this.isMarkdownDoc(doc) || language === 'Plain Text'))
      doc.editorState = group.editor.getState()
      doc.groupStates.set(groupIndex, group.editor.getState())
      doc.viewStates.set(groupIndex, group.editor.getViewState(groupIndex))
    } catch (error) {
      console.error(`Failed to load syntax support for ${doc.name}:`, error)
    }
    if (activation !== this.languageActivation || this.activeGroup !== groupIndex || group.activeId !== id) return
    this.renderTabs()
    this.updateStatus()
    group.editor.focus()
    this.scheduleSessionSave()
    this.scheduleLanguageServerSync(doc)
    this.scheduleAutoSave()
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
    doc.groupStates.set(groupIndex, group.editor.getState())
    doc.viewStates.set(groupIndex, group.editor.getViewState(groupIndex))
    for (const sibling of this.groups) {
      if (sibling.id !== groupIndex && sibling.activeId === doc.id && sibling.editor.getContent() !== doc.content) {
        this.syncingGroupContent = true
        try {
          sibling.editor.replaceContent(doc.content)
        } finally {
          this.syncingGroupContent = false
        }
      }
    }
    this.renderTabs()
    this.projectSymbols = []
    this.projectSymbolIndexAt = 0
    this.workspaceWords = []
    this.workspaceWordIndexAt = 0
    this.refreshIncrementalDiff(doc, group.editor)
    if (this.jsonView.visible && groupIndex === 0 && this.isJsonDoc(doc)) this.jsonView.update(doc.content)
    // Live-update the markdown preview if it's showing this doc.
    if (this.preview.isVisible && this.isMarkdownDoc(doc)) {
      this.preview.update(doc.content)
    }
    if (groupIndex === this.activeGroup) this.syncOutline()
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

  /** JSON is enabled by extension, auto-detected syntax, or an explicit syntax choice. */
  private isJsonDoc(doc: Doc): boolean {
    return /\.(json|jsonc|geojson|har)$/i.test(doc.name) || doc.language === 'JSON'
  }

  private transformJson(pretty: boolean): void {
    const doc = this.active
    if (!doc || !this.isJsonDoc(doc)) {
      this.showError(this.settings.locale === 'zh-CN' ? '当前文件不是 JSON。' : 'The active file is not JSON.')
      return
    }
    try {
      const parsed = parseLosslessJson(this.editor.getContent())
      this.editor.replaceContent(pretty ? `${stringifyLosslessJson(parsed, 2)}\n` : stringifyLosslessJson(parsed))
      this.statusSelection.textContent = pretty
        ? (this.settings.locale === 'zh-CN' ? 'JSON 已格式化' : 'JSON formatted')
        : (this.settings.locale === 'zh-CN' ? 'JSON 已压缩' : 'JSON compacted')
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? 'JSON 无法解析，未修改源文件。' : 'Invalid JSON; source was not changed.', error)
    }
  }

  private toggleJsonView(): void {
    const doc = this.active
    if (!doc || !this.isJsonDoc(doc)) {
      this.showError(this.settings.locale === 'zh-CN' ? '当前文件不是 JSON。' : 'The active file is not JSON.')
      return
    }
    if (this.jsonView.visible) this.jsonView.hide()
    else this.jsonView.show(this.editor.getContent())
    this.jsonViewBtn.classList.toggle('active', this.jsonView.visible)
  }

  /** Match Sublime's practical indentation detection without overriding user defaults on sparse files. */
  private detectIndentation(content: string): { tabSize: number; insertSpaces: boolean } {
    let tabs = 0
    const widths = new Map<number, number>()
    for (const line of content.split('\n').slice(0, 2_000)) {
      const prefix = /^[ \t]+/.exec(line)?.[0] ?? ''
      if (!prefix) continue
      if (prefix.includes('\t')) tabs += 1
      else {
        const width = prefix.length
        if (width > 0 && width <= 16) widths.set(width, (widths.get(width) ?? 0) + 1)
      }
    }
    const [bestWidth, count] = [...widths.entries()].sort((a, b) => b[1] - a[1])[0] ?? [this.settings.tabSize, 0]
    if (tabs === 0 && count === 0) return { tabSize: this.settings.tabSize, insertSpaces: this.settings.insertSpaces }
    return { tabSize: bestWidth, insertSpaces: tabs < count }
  }

  /** Compute Sublime-style change markers against the last saved/disk version. */
  private refreshIncrementalDiff(doc: Doc, editor = this.editor): IncrementalChange[] {
    const changes = doc.path ? incrementalChanges(doc.savedContent, doc.content) : []
    editor.setIncrementalChanges(changes)
    return changes
  }

  private navigateIncrementalChange(direction: 1 | -1): void {
    const doc = this.active
    if (!doc?.path) {
      this.statusSelection.textContent = 'Save the file before navigating changes'
      return
    }
    const change = this.editor.nextIncrementalChange(direction)
    this.statusSelection.textContent = change
      ? `${change.kind} change at line ${change.line}`
      : 'No unsaved changes'
  }

  private revertCurrentIncrementalChange(): void {
    const doc = this.active
    if (!doc?.path) {
      this.showError('Save the file before reverting an incremental change.')
      return
    }
    const changes = this.refreshIncrementalDiff(doc)
    const line = this.editor.currentLine()
    const change = changes.find((candidate) => line >= candidate.line && line < candidate.line + Math.max(1, candidate.lineCount))
      ?? [...changes].reverse().find((candidate) => candidate.line <= line)
    if (!change) {
      this.statusSelection.textContent = 'No change at the cursor'
      return
    }
    if (!window.confirm(`Revert this ${change.kind} change near line ${change.line}?`)) return
    this.editor.replaceContent(revertIncrementalChange(doc.content, change))
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
    const json = canShowChrome && !!doc && this.isJsonDoc(doc)
    this.jsonToolbar.hidden = !json
    this.jsonToolbar.classList.toggle('hidden', !json)
    if (!json) this.jsonView.hide()

    // If the preview is open but the new doc isn't markdown, hide it; if it is
    // markdown, refresh it with the new content.
    if (this.preview.isVisible) {
      if (md) this.preview.update(doc!.content)
      else this.preview.hide()
    }
    this.previewBtn.classList.toggle('active', this.preview.isVisible && md)
    this.jsonViewBtn.classList.toggle('active', this.jsonView.visible && json)
    if (doc?.externalChange) this.showExternalConflict(doc)
    else this.hideExternalConflict()
  }

  /** Keep the sidebar outline in sync without changing editor or document state. */
  private syncOutline(immediate = false): void {
    if (!this.outlinePanel) return
    this.outlinePanel.toggle(this.settings.showOutline)
    const doc = this.active
    const cursor = this.editor?.view.state.selection.main.head ?? 0
    this.outlinePanel.setDocument(doc?.name ?? '', doc?.content ?? '', cursor, immediate)
  }

  /** Run a code-folding command and keep unsuccessful requests visible to the user. */
  private runFoldCommand(command: 'fold-current' | 'unfold-current' | 'fold-all' | 'unfold-all'): void {
    const changed = command === 'fold-current'
      ? this.editor.foldCurrent()
      : command === 'unfold-current'
        ? this.editor.unfoldCurrent()
        : command === 'fold-all'
          ? this.editor.foldEverywhere()
          : this.editor.unfoldEverywhere()
    if (!changed) {
      this.statusSelection.textContent = this.settings.locale === 'zh-CN'
        ? (command.startsWith('unfold') ? '没有可展开的代码块' : '当前位置没有可折叠的代码块')
        : (command.startsWith('unfold') ? 'No folded code blocks to unfold' : 'No foldable code block at the cursor')
    }
  }

  /** Show Unicode-aware counts for the active buffer and its main selection. */
  private showDocumentStatistics(): void {
    const state = this.editor.view.state
    const selection = state.selection.main
    const documentStats = textStatistics(state.doc.toString())
    const selectedStats = selection.empty ? null : textStatistics(state.sliceDoc(selection.from, selection.to))
    const zh = this.settings.locale === 'zh-CN'
    const render = (stats: TextStatistics): string => {
      const fields = zh
        ? [`行：${stats.lines}`, `字符：${stats.characters}`, `非空白字符：${stats.charactersExcludingWhitespace}`, `词 / 标记：${stats.words}`]
        : [`Lines: ${stats.lines}`, `Characters: ${stats.characters}`, `Characters (excluding whitespace): ${stats.charactersExcludingWhitespace}`, `Words / tokens: ${stats.words}`]
      return fields.join(String.fromCharCode(10))
    }
    const title = zh ? '文档统计' : 'Document Statistics'
    const documentLabel = zh ? '全文' : 'Document'
    const selectionLabel = zh ? '选区' : 'Selection'
    const sections = [title, '', documentLabel, render(documentStats)]
    if (selectedStats) sections.push('', selectionLabel, render(selectedStats))
    window.alert(sections.join(String.fromCharCode(10)))
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

  /** Copy only an authorised path through main; renderer never receives clipboard read access. */
  private async copyActivePath(relative: boolean): Promise<void> {
    const path = this.active?.path
    if (!path) {
      this.showError(this.settings.locale === 'zh-CN' ? '当前标签没有已保存的文件路径。' : 'The active tab has no saved file path.')
      return
    }
    await this.copyPath(path, relative)
  }

  private async copyPath(path: string, relative: boolean): Promise<void> {
    const root = this.workspaceRootForPath(path)
    if (relative && !root) {
      this.showError(this.settings.locale === 'zh-CN' ? '该文件不在当前项目中，无法复制相对路径。' : 'This file is outside the current project, so it has no relative path.')
      return
    }
    const value = relative && root
      ? path.slice(root.length).replace(/^[/\\]+/, '').replaceAll('\\', '/') || baseName(path)
      : path
    try {
      await window.editor.copyPath(path, relative ? root ?? undefined : undefined)
      this.statusSelection.textContent = this.settings.locale === 'zh-CN'
        ? `已复制${relative ? '相对路径' : '路径'}：${value}`
        : `Copied ${relative ? 'relative path' : 'path'}: ${value}`
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? '无法复制文件路径。' : 'The file path could not be copied.', error)
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

  private async undoReplaceInFiles(): Promise<void> {
    if (!this.replaceUndoToken) {
      this.showError('There is no recent workspace replace to undo.')
      return
    }
    try {
      const result = await window.editor.undoWorkspaceReplace(this.replaceUndoToken)
      this.replaceUndoToken = null
      this.statusSelection.textContent = `Restored ${result.files} file${result.files === 1 ? '' : 's'}`
      for (const doc of this.docs) {
        if (doc.path && !isDirty(doc)) await this.handleExternalFileChange(doc.path)
      }
      await this.reloadWorkspaceTree()
    } catch (error) {
      this.replaceUndoToken = null
      this.showError('Workspace replace could not be undone.', error)
    }
  }

  private rememberSearchHistory(search: string, replacement?: string): void {
    const add = (items: string[], value: string): string[] => [value, ...items.filter((item) => item !== value)].slice(0, 50)
    this.settings.searchHistory = add(this.settings.searchHistory, search)
    if (replacement !== undefined) this.settings.replaceHistory = add(this.settings.replaceHistory, replacement)
    this.persistSettings()
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
    try {
      await this.ensureProjectSymbols()
    } catch (error) {
      this.showError('Project symbols could not be indexed.', error)
      return
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
      await this.replaceWorkspaceFolders(folder.root)
    } catch (error) {
      this.showError('The selected folder could not be opened.', error)
    }
  }

  /** Open a dropped directory as the primary workspace; extra dropped dirs become roots. */
  private async openDroppedFiles(files: File[]): Promise<void> {
    try {
      const dropped = await window.editor.openDroppedFiles(files)
      if (dropped.folders.length > 0) {
        await this.replaceWorkspaceFolders(dropped.folders[0].root)
        for (const folder of dropped.folders.slice(1)) await this.addFolderPath(folder.root)
      }
      for (const file of dropped.files) this.openLoadedFile(file)
      const opened = dropped.files.length + dropped.folders.length
      if (opened > 0) {
        this.statusSelection.textContent = this.settings.locale === 'zh-CN'
          ? `已打开 ${opened} 个拖入项目${dropped.rejected > 0 ? `，跳过 ${dropped.rejected} 个无效项目` : ''}`
          : `Opened ${opened} dropped item${opened === 1 ? '' : 's'}${dropped.rejected > 0 ? `; skipped ${dropped.rejected}` : ''}`
      } else {
        this.showError(this.settings.locale === 'zh-CN' ? '未能打开拖入的项目。' : 'No dropped items could be opened.')
      }
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? '拖入的文件或文件夹无法打开。' : 'The dropped files or folders could not be opened.', error)
    }
  }

  private async replaceWorkspaceFolders(root: string): Promise<void> {
    this.folder = root
    this.folders = [root]
    await this.loadProject(root)
    this.workspaceName.textContent = baseName(root).toUpperCase()
    await this.renderProjectRoots()
    if (!this.settings.distractionFree) this.sidebar.classList.remove('hidden')
    void window.editor.watchWorkspace(root)
    void window.editor.addRecentProject(root)
    this.projectSymbols = []
    this.workspaceWords = []
    this.statusSelection.textContent = this.settings.locale === 'zh-CN'
      ? `已打开文件夹：${root}`
      : `Opened folder: ${root}`
    this.scheduleSessionSave()
  }

  /** Add a folder to the active project without discarding its existing roots. */
  private async addFolderPath(root: string, primary = false): Promise<void> {
    if (this.folders.includes(root)) return
    try {
      await window.editor.readDir(root)
      if (primary || !this.folder) {
        this.folder = root
        if (this.project.buildSystems.length === 0 && this.project.exclude.length === 0) await this.loadProject(root)
      }
      this.folders.push(root)
      this.workspaceName.textContent = this.folders.length === 1 ? baseName(root).toUpperCase() : `${this.folders.length} FOLDERS`
      await this.renderProjectRoots()
      void window.editor.watchWorkspace(root)
      void window.editor.addRecentProject(root)
    } catch (error) {
      this.showError(`Could not add folder “${baseName(root)}”.`, error)
    }
  }

  private async renderProjectRoots(): Promise<void> {
    if (this.folders.length === 0) {
      this.tree.clear()
      return
    }
    try {
      const roots = await Promise.all(this.folders.map(async (root) => ({
        name: baseName(root),
        path: root,
        isDirectory: true,
        children: (await window.editor.readDir(root)).filter((entry) => !this.isProjectExcluded(entry.path, entry.isDirectory))
      })))
      if (roots.length === 1) this.tree.render(roots[0].children, true)
      else this.tree.render(roots.map((root) => ({ name: root.name, path: root.path, isDirectory: true, children: root.children })), true)
    } catch (error) {
      this.showError('Project folders could not be rendered.', error)
    }
  }

  private async addFolderToProject(): Promise<void> {
    const folder = await window.editor.openFolder()
    if (folder) await this.addFolderPath(folder.root)
  }

  /** Remove one root while preserving direct access to tabs already open from it. */
  private async removeFolderFromProject(): Promise<void> {
    if (this.folders.length === 0) {
      this.showError(this.settings.locale === 'zh-CN' ? '当前没有可移除的项目文件夹。' : 'There is no project folder to remove.')
      return
    }
    this.palette.open({
      placeholder: this.settings.locale === 'zh-CN' ? '选择要从项目移除的文件夹…' : 'Select a folder to remove from the project…',
      items: this.folders.map((root) => ({ label: baseName(root), detail: root, value: root })),
      onAccept: (item) => { void this.releaseWorkspaceFolder(item.value as string) }
    })
  }

  private async releaseWorkspaceFolder(root: string): Promise<void> {
    if (!this.folders.includes(root)) return
    const isPrimary = root === this.folder
    const title = this.settings.locale === 'zh-CN' ? '从项目移除文件夹？' : 'Remove folder from project?'
    const detail = this.settings.locale === 'zh-CN'
      ? `将移除：${root}\n\n已打开的文件标签会保留，但该文件夹不再参与文件树、搜索、符号索引、构建、Git 或终端。`
      : `Remove: ${root}\n\nOpen file tabs will remain, but this folder will no longer participate in the file tree, search, symbol index, build, Git, or terminal.`
    if (!window.confirm(`${title}\n\n${detail}`)) return

    const retainedFiles = this.docs
      .map((doc) => doc.path)
      .filter((path): path is string => !!path && (path === root || path.startsWith(`${root}/`) || path.startsWith(`${root}\\`)))
    try {
      if (isPrimary) await this.stopTerminal()
      for (const config of Object.values(this.project.languageServers)) {
        await window.editor.stopLanguageServer(root, config).catch(() => undefined)
      }
      await window.editor.releaseWorkspace(root, retainedFiles)
      this.folders = this.folders.filter((candidate) => candidate !== root)
      this.projectSymbols = []
      this.workspaceWords = []
      this.projectSymbolIndexAt = 0
      this.workspaceWordIndexAt = 0

      if (isPrimary) {
        this.folder = this.folders[0] ?? null
        if (this.folder) await this.loadProject(this.folder)
        else {
          this.project = { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], pluginPermissions: {}, languageTools: {}, languageServers: {}, buildSystems: [], keyBindingRules: [], marketplaceUrls: [] }
          this.plugins = []
          this.extensionHost.dispose()
          this.extensionCommands.clear()
          this.buildPanel.setCommand('')
          this.tree.clear()
          this.gitPanel.toggle(false)
        }
      }

      if (this.folder) {
        this.workspaceName.textContent = this.folders.length === 1 ? baseName(this.folder).toUpperCase() : `${this.folders.length} FOLDERS`
        await this.renderProjectRoots()
      } else {
        this.workspaceName.textContent = this.t('noFolder')
        this.sidebar.classList.add('hidden')
      }
      this.scheduleSessionSave()
      this.statusSelection.textContent = this.settings.locale === 'zh-CN'
        ? `已从项目移除：${baseName(root)}`
        : `Removed from project: ${baseName(root)}`
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? '无法从项目移除文件夹。' : 'The folder could not be removed from the project.', error)
    }
  }

  /** Import the portable subset of a `.sublime-project` after user file selection. */
  private async importSublimeProject(): Promise<void> {
    try {
      const imported = await window.editor.importSublimeProject()
      if (!imported) return
      const names = imported.roots.map((root) => baseName(root)).join(', ')
      if (!window.confirm(`Import Sublime project roots: ${names}?\n\nThis converts folders, exclude patterns, and Build Systems only. It will not execute Sublime Python plugins.`)) return
      const folders = await window.editor.acceptSublimeProjectImport(imported.token)
      this.folder = null
      this.folders = []
      this.project = imported.project
      this.plugins = []
      this.extensionHost.dispose()
      this.extensionCommands.clear()
      for (const folder of folders) await this.addFolderPath(folder.root, this.folders.length === 0)
      if (!this.folder) return
      await this.saveProject()
      this.buildPanel.setCommand(this.project.buildCommand)
      await this.renderProjectRoots()
      this.scheduleSessionSave()
      this.statusSelection.textContent = `Imported Sublime project: ${baseName(imported.sourcePath)}`
    } catch (error) {
      this.showError('Sublime project could not be imported.', error)
    }
  }

  private async importSublimeSettings(): Promise<void> {
    try {
      const settings = await window.editor.importSublimeSettings()
      if (!settings) return
      if (!window.confirm('Apply the imported Sublime settings to this Lumen window?')) return
      this.applyUserSettings(settings)
      this.statusSelection.textContent = 'Imported Sublime settings'
    } catch (error) {
      this.showError('Sublime settings could not be imported.', error)
    }
  }

  /** Apply and persist user preferences from the settings panel or importer. */
  private applyUserSettings(settings: Settings): void {
    const previousLocale = this.settings.locale
    this.settings = { ...settings, rulers: [...settings.rulers], searchHistory: [...settings.searchHistory], replaceHistory: [...settings.replaceHistory] }
    document.documentElement.dataset.colorScheme = this.settings.colorScheme
    for (const group of this.groups) group.editor.applySettings(this.settings)
    for (const group of this.groups) {
      const doc = group.activeId ? this.docs.find((candidate) => candidate.id === group.activeId) : undefined
      group.editor.setSpellCheck(this.settings.spellCheck && !!doc && (this.isMarkdownDoc(doc) || doc.language === 'Plain Text'))
    }
    this.applyDistractionFreeMode(this.settings.distractionFree)
    this.applyLocale(this.settings.locale)
    this.settingsPanel?.setSettings(this.settings)
    this.persistSettings()
    if (previousLocale !== this.settings.locale) {
      void window.editor.setMenuLocale(this.settings.locale).catch((error: unknown) =>
        this.showError(this.settings.locale === 'zh-CN' ? '界面语言切换失败。' : 'Could not switch interface language.', error)
      )
    }
    if (this.settings.autoSave === 'after_delay') this.scheduleAutoSave()
    else if (this.autoSaveTimer !== null) {
      window.clearTimeout(this.autoSaveTimer)
      this.autoSaveTimer = null
    }
  }

  private async importSublimeSnippet(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a project before importing a Sublime snippet.')
      return
    }
    try {
      const imported = await window.editor.importSublimeSnippet()
      if (!imported) return
      const detail = `${imported.snippet.label}${imported.snippet.trigger ? ` (trigger: ${imported.snippet.trigger})` : ''}`
      if (!window.confirm(`Import Sublime snippet: ${detail}?\n\nOnly the snippet text, trigger and scope are imported.`)) return
      this.project.snippets = [imported.snippet, ...(this.project.snippets ?? []).filter((snippet) => snippet.label !== imported.snippet.label)].slice(0, 500)
      await this.saveProject()
      this.statusSelection.textContent = `Imported Sublime snippet: ${imported.snippet.label}`
    } catch (error) {
      this.showError('Sublime snippet could not be imported.', error)
    }
  }

  private async importSublimeKeymap(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a project before importing a Sublime keymap.')
      return
    }
    try {
      const imported = await window.editor.importSublimeKeymap()
      if (!imported) return
      if (imported.rules.length === 0) {
        this.showError(`No supported bindings were found. ${imported.skipped} entries were skipped.`)
        return
      }
      if (!window.confirm(`Import ${imported.rules.length} supported key binding${imported.rules.length === 1 ? '' : 's'}?\n\n${imported.skipped} unsupported or parameterized entries will be skipped.`)) return
      const keyFor = (rule: import('../../shared/ipc.js').KeyBindingRule): string => `${Array.isArray(rule.keys) ? rule.keys.join(' ') : rule.keys}\0${rule.command}`
      const incoming = new Set(imported.rules.map(keyFor))
      this.project.keyBindingRules = [...imported.rules, ...this.project.keyBindingRules.filter((rule) => !incoming.has(keyFor(rule)))].slice(0, 200)
      await this.saveProject()
      this.statusSelection.textContent = `Imported ${imported.rules.length} Sublime key bindings`
    } catch (error) {
      this.showError('Sublime keymap could not be imported.', error)
    }
  }

  private async openRecentProject(): Promise<void> {
    const projects = await window.editor.readRecentProjects()
    if (projects.length === 0) {
      this.showError(this.t('noRecentProjects'))
      return
    }
    this.palette.open({
      placeholder: 'Open Recent Project',
      items: projects.map((project) => ({ label: baseName(project.path), detail: project.path, value: project.path })),
      onAccept: (item) => { void this.openRecentProjectPath(item.value as string) }
    })
  }

  private async openRecentFile(): Promise<void> {
    try {
      const files = await window.editor.readRecentFiles()
      if (files.length === 0) {
        this.showError(this.t('noRecentFiles'))
        return
      }
      this.palette.open({
        placeholder: 'Open Recent File',
        items: files.map((file) => ({ label: baseName(file.path), detail: file.path, value: file.path })),
        onAccept: (item) => {
          void window.editor.openRecentFile(item.value as string).then((file) => this.openLoadedFile(file)).catch((error: unknown) => this.showError('The recent file could not be opened.', error))
        }
      })
    } catch (error) {
      this.showError('Recent files could not be loaded.', error)
    }
  }

  private async openRecentProjectPath(root: string): Promise<void> {
    try {
      const folder = await window.editor.openRecentProject(root)
      this.folder = folder.root
      this.folders = [folder.root]
      await this.loadProject(folder.root)
      this.workspaceName.textContent = baseName(folder.root).toUpperCase()
      await this.renderProjectRoots()
      if (!this.settings.distractionFree) this.sidebar.classList.remove('hidden')
      void window.editor.watchWorkspace(folder.root)
      void window.editor.addRecentProject(folder.root)
      this.projectSymbols = []
      this.workspaceWords = []
      this.scheduleSessionSave()
    } catch (error) {
      this.showError('The recent project could not be opened.', error)
    }
  }

  private async loadProject(root: string): Promise<void> {
    try {
      this.project = (await window.editor.readProject(root)) ?? { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], pluginPermissions: {}, languageTools: {}, languageServers: {}, buildSystems: [], keyBindingRules: [], marketplaceUrls: [] }
      if (this.project.buildCommand) this.buildPanel?.setCommand(this.project.buildCommand)
      this.plugins = (await window.editor.listPlugins(root)).filter(
        (plugin) => plugin.enabled && (this.project.plugins.length === 0 || this.project.plugins.includes(plugin.id))
      )
      await this.loadExtensionWorkers(root)
      void this.refreshGit()
    } catch (error) {
      this.showError('Project settings could not be read.', error)
    }
  }

  private async loadExtensionWorkers(root: string): Promise<void> {
    this.extensionHost.dispose()
    this.extensionCommands.clear()
    for (const plugin of this.plugins) {
      const required = plugin.extension?.permissions ?? []
      const granted = this.project.pluginPermissions[plugin.id] ?? []
      const missing = required.filter((permission) => !granted.includes(permission))
      if (missing.length > 0) {
        const ok = window.confirm(`Allow plugin “${plugin.name}” to use: ${missing.join(', ')}?\n\nIt runs in a sandboxed Web Worker without filesystem, network, Node, or process access.`)
        if (!ok) continue
        this.project.pluginPermissions[plugin.id] = [...new Set([...granted, ...missing])]
        void this.saveProject()
      }
      const permissions = this.project.pluginPermissions[plugin.id] ?? []
      await this.extensionHost.load(root, plugin, permissions, {
        getDocument: () => {
          const selection = this.editor.view.state.selection.main
          return { text: this.editor.getContent(), language: this.active?.language ?? 'Plain Text', selection: { from: selection.from, to: selection.to } }
        },
        replaceDocument: (text) => this.editor.replaceContent(text),
        registerCommand: (owner, id, title, run) => this.extensionCommands.set(`${owner.id}:${id}`, { plugin: owner, title, run }),
        notify: (message) => { this.statusSelection.textContent = message }
      })
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
        pluginPermissions: parsed.pluginPermissions && typeof parsed.pluginPermissions === 'object' ? parsed.pluginPermissions : {},
        languageTools: parsed.languageTools && typeof parsed.languageTools === 'object' ? parsed.languageTools : {},
        languageServers: parsed.languageServers && typeof parsed.languageServers === 'object' ? parsed.languageServers : {},
        buildSystems: Array.isArray(parsed.buildSystems) ? parsed.buildSystems : [],
        keyBindingRules: Array.isArray(parsed.keyBindingRules) ? parsed.keyBindingRules : [],
        marketplaceUrls: Array.isArray(parsed.marketplaceUrls) ? parsed.marketplaceUrls.filter((url): url is string => typeof url === 'string') : []
        , snippets: Array.isArray(parsed.snippets) ? parsed.snippets : []
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

  private selectColorScheme(): void {
    const schemes: Array<{ label: string; value: Settings['colorScheme']; detail: string }> = [
      { label: 'Dark', value: 'dark', detail: 'Default dark UI and One Dark editor' },
      { label: 'Light', value: 'light', detail: 'Light UI and editor' },
      { label: 'Solarized Dark', value: 'solarized-dark', detail: 'Low-contrast Solarized palette' },
      { label: 'Dracula', value: 'dracula', detail: 'Purple Dracula palette' }
    ]
    this.palette.open({
      placeholder: 'Select color scheme…',
      items: schemes.map((scheme) => ({ label: scheme.label, detail: scheme.detail, value: scheme.value })),
      onAccept: (item) => {
        const scheme = item.value as Settings['colorScheme']
        this.settings.colorScheme = scheme
        this.settings.theme = scheme === 'light' ? 'light' : 'dark'
        this.applyUserSettings(this.settings)
      }
    })
  }

  private async refreshGit(): Promise<void> {
    if (!this.folder) return
    try {
      this.gitPanel.setStatus(await window.editor.gitStatus(this.folder))
    } catch (error) {
      this.showError('Git status could not be loaded.', error)
    }
  }

  private async openGitConflicts(): Promise<void> {
    if (!this.folder) return
    try {
      const conflicts = await window.editor.gitConflicts(this.folder)
      if (conflicts.length === 0) {
        this.statusSelection.textContent = 'No merge conflicts detected'
        return
      }
      if (this.groups.length < 2) this.setLayout('columns2')
      for (const conflict of conflicts) {
        const targetGroup = (this.activeGroup + 1) % this.groups.length
        await this.openPath(`${this.folder}/${conflict.path}`)
        const doc = this.docs.find((candidate) => candidate.path === `${this.folder}/${conflict.path}`)
        if (doc) {
          const group = this.groups[targetGroup]
          if (!group.docIds.includes(doc.id)) group.docIds.push(doc.id)
          group.activeId = doc.id
        }
      }
      this.renderTabs()
      this.statusSelection.textContent = `Opened ${conflicts.length} conflicted file${conflicts.length === 1 ? '' : 's'}`
    } catch (error) {
      this.showError('Git conflicts could not be opened.', error)
    }
  }

  private async checkForUpdates(): Promise<void> {
    try {
      const update = await window.editor.checkForUpdate()
      if (!update.available || !update.latestVersion) {
        this.statusSelection.textContent = `Lumen ${update.currentVersion} is up to date`
        return
      }
      const message = `Lumen ${update.latestVersion} is available (current: ${update.currentVersion}).`
      if (update.releaseUrl && window.confirm(`${message}\n\nOpen the release page to download the signed installer?`)) {
        await window.editor.openExternal(update.releaseUrl)
      } else {
        this.statusSelection.textContent = message
      }
    } catch (error) {
      this.showError('Update check failed.', error)
    }
  }

  private async runGitAction(action: GitAction, paths: string[] = []): Promise<void> {
    if (!this.folder) return
    if (paths.length === 0) {
      this.showError('Select one or more files with Ctrl/Cmd-click in the Git panel.')
      return
    }
    const actionLabel = action === 'stage' ? 'Stage' : action === 'unstage' ? 'Unstage' : 'Discard local changes for'
    if (!window.confirm(`${actionLabel} ${paths.length} selected file${paths.length === 1 ? '' : 's'}?`)) return
    try {
      this.gitPanel.setStatus(await window.editor.gitAction({ root: this.folder, action, paths }))
      await this.reloadWorkspaceTree()
    } catch (error) {
      this.showError(`Git ${action} failed.`, error)
    }
  }

  private async runGitHunkAction(action: 'stage-hunk' | 'discard-hunk', hunk: import('../../shared/ipc.js').GitHunk): Promise<void> {
    if (!this.folder) return
    const label = action === 'stage-hunk' ? 'Stage' : 'Discard'
    if (!window.confirm(`${label} selected hunk in “${hunk.path}”?`)) return
    try {
      this.gitPanel.setStatus(await window.editor.gitAction({ root: this.folder, action, paths: [hunk.path], patch: hunk.patch }))
      await this.reloadWorkspaceTree()
      this.statusSelection.textContent = `${label}d selected hunk`
    } catch (error) {
      this.showError(`Git ${action} failed.`, error)
    }
  }

  private async commitGitChanges(): Promise<void> {
    if (!this.folder) return
    const message = window.prompt('Commit message:')?.trim()
    if (!message || !window.confirm(`Create commit with message:\n\n${message}`)) return
    try {
      this.gitPanel.setStatus(await window.editor.gitAction({ root: this.folder, action: 'commit', message }))
    } catch (error) {
      this.showError('Git commit failed.', error)
    }
  }

  private async switchGitBranch(create: boolean): Promise<void> {
    if (!this.folder) return
    const branch = window.prompt(create ? 'New branch name:' : 'Existing branch name:')?.trim()
    if (!branch || !window.confirm(`${create ? 'Create and switch to' : 'Switch to'} branch “${branch}”?`)) return
    try {
      this.gitPanel.setStatus(await window.editor.gitAction({ root: this.folder, action: create ? 'create-branch' : 'checkout-branch', branch }))
      await this.reloadWorkspaceTree()
    } catch (error) {
      this.showError('Git branch action failed.', error)
    }
  }

  private async openMarketplace(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a folder before browsing plugins.')
      return
    }
    if (this.project.marketplaceUrls.length === 0) {
      this.showError('Add one or more HTTPS marketplaceUrls to .lumen-project.json first.')
      return
    }
    try {
      const items = await window.editor.listMarketplace(this.folder)
      if (items.length === 0) {
        this.showError('No plugins were returned by the configured marketplaces.')
        return
      }
      await openMarketplace(this.palette, items, (item) => { void this.installMarketplaceItem(item) })
    } catch (error) {
      this.showError('Plugin marketplace could not be loaded.', error)
    }
  }

  private async installMarketplaceItem(item: MarketplaceItem): Promise<void> {
    if (!this.folder) return
    const prompt = `Install declarative plugin “${item.name}” (${item.version}) from:\n\n${item.manifestUrl}\n\nOnly its manifest, snippets, and text commands will be stored.`
    if (!window.confirm(prompt)) return
    try {
      const plugin = await window.editor.installMarketplacePlugin({ root: this.folder, manifestUrl: item.manifestUrl })
      if (!this.project.plugins.includes(plugin.id)) this.project.plugins.push(plugin.id)
      await this.saveProject()
      await this.loadProject(this.folder)
      this.statusSelection.textContent = `Installed plugin: ${plugin.name}`
    } catch (error) {
      this.showError('The marketplace plugin could not be installed.', error)
    }
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
    await this.renderProjectRoots()
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

  /** Duplicate one authorised file in place, never recursively or over an existing destination. */
  private async copyFile(source: string): Promise<void> {
    const original = baseName(source)
    const dot = original.lastIndexOf('.')
    const suggested = dot > 0 ? `${original.slice(0, dot)} copy${original.slice(dot)}` : `${original} copy`
    const nextName = window.prompt(this.settings.locale === 'zh-CN' ? '复制为：' : 'Copy as:', suggested)?.trim()
    if (!nextName || nextName === original) return
    if (nextName.includes('/') || nextName.includes('\\') || nextName === '.' || nextName === '..') {
      this.showError(this.settings.locale === 'zh-CN' ? '请使用简单的文件名。' : 'Use a simple file name.')
      return
    }
    const target = `${source.slice(0, source.length - original.length)}${nextName}`
    try {
      const entry = await window.editor.duplicateFile(source, target)
      await this.reloadWorkspaceTree()
      await this.openPath(entry.path)
      this.statusSelection.textContent = this.settings.locale === 'zh-CN'
        ? `已复制文件：${entry.name}`
        : `Copied file: ${entry.name}`
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? '文件无法复制。' : 'The file could not be copied.', error)
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

  private async movePath(source: string): Promise<void> {
    if (!window.confirm(`Choose a destination folder for “${baseName(source)}”?`)) return
    try {
      const target = await window.editor.movePath(source)
      if (!target || target === source) return
      for (const doc of this.docs) {
        if (doc.path === source || (doc.path !== null && (doc.path.startsWith(`${source}/`) || doc.path.startsWith(`${source}\\`)))) {
          doc.path = doc.path === source ? target : `${target}${doc.path.slice(source.length)}`
          doc.name = baseName(doc.path)
        }
      }
      await this.reloadWorkspaceTree()
      this.renderTabs()
      this.statusSelection.textContent = `Moved to ${target}`
    } catch (error) {
      this.showError('The item could not be moved.', error)
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

  private async saveAll(): Promise<void> {
    const dirty = this.docs.filter((doc) => isDirty(doc))
    if (dirty.length === 0) {
      this.statusSelection.textContent = 'All files are saved'
      return
    }
    for (const doc of dirty) {
      const group = this.groups.find((candidate) => candidate.docIds.includes(doc.id))
      if (!group) continue
      const previousGroup = this.activeGroup
      const previousId = this.activeId
      await this.activate(doc.id, group.id)
      await this.save(false)
      if (previousId && this.docs.some((item) => item.id === previousId)) await this.activate(previousId, previousGroup)
      if (isDirty(doc)) {
        this.statusSelection.textContent = 'Save All stopped before an unsaved file'
        return
      }
    }
    this.statusSelection.textContent = `Saved ${dirty.length} file${dirty.length === 1 ? '' : 's'}`
  }

  private cycleAutoSave(): void {
    const modes: Settings['autoSave'][] = ['off', 'after_delay', 'on_focus_change']
    const next = modes[(modes.indexOf(this.settings.autoSave) + 1) % modes.length]
    this.settings.autoSave = next
    if (next !== 'after_delay' && this.autoSaveTimer !== null) {
      window.clearTimeout(this.autoSaveTimer)
      this.autoSaveTimer = null
    }
    this.persistSettings()
    this.statusSelection.textContent = this.settings.locale === 'zh-CN'
      ? `自动保存：${next === 'off' ? '关闭' : next === 'after_delay' ? '延时保存' : '失焦保存'}`
      : `Auto Save: ${next.replaceAll('_', ' ')}`
    if (next === 'after_delay') this.scheduleAutoSave()
  }

  private scheduleAutoSave(): void {
    if (this.settings.autoSave !== 'after_delay') return
    if (this.autoSaveTimer !== null) window.clearTimeout(this.autoSaveTimer)
    this.autoSaveTimer = window.setTimeout(() => {
      this.autoSaveTimer = null
      if (this.settings.autoSave === 'after_delay') void this.autoSaveDirtyDocuments()
    }, this.settings.autoSaveDelayMs)
  }

  /** Never prompts for a destination: untitled files remain protected hot-exit drafts. */
  private async autoSaveDirtyDocuments(): Promise<void> {
    for (const doc of this.docs.filter((item) => !!item.path && isDirty(item) && !item.externalChange && !this.autoSaveInFlight.has(item.id))) {
      this.autoSaveInFlight.add(doc.id)
      const snapshot = doc.content
      try {
        const result = await window.editor.save(doc.path, snapshot, { encoding: doc.encoding, eol: doc.eol })
        if (result.saved) {
          doc.savedContent = snapshot
          doc.externalChange = undefined
          doc.ignoredExternalContent = undefined
        }
      } catch (error) {
        this.showError(`Auto Save could not save “${doc.name}”.`, error)
      } finally {
        this.autoSaveInFlight.delete(doc.id)
      }
    }
    this.renderTabs()
    this.scheduleSessionSave()
  }

  private async closeTabs(mode: 'others' | 'right' | 'all'): Promise<void> {
    const group = this.groups[this.activeGroup]
    const activeId = group?.activeId
    if (!group || !activeId) return
    const activeIndex = group.docIds.indexOf(activeId)
    const ids = group.docIds.filter((id, index) => mode === 'all' || (mode === 'others' ? id !== activeId : index > activeIndex))
    const dirty = ids.map((id) => this.docs.find((doc) => doc.id === id)).filter((doc): doc is Doc => !!doc && isDirty(doc))
    if (dirty.length > 0 && !window.confirm(`Close ${ids.length} tab${ids.length === 1 ? '' : 's'}? ${dirty.length} have unsaved changes.`)) return
    for (const id of ids) this.closeDocFromGroup(id, group.id, false)
  }

  private closeDocFromGroup(id: string, groupIndex: number, confirmClose = true): void {
    const doc = this.docs.find((candidate) => candidate.id === id)
    const group = this.groups[groupIndex]
    if (!doc || !group) return
    if (confirmClose && isDirty(doc) && !confirm(`"${doc.name}" has unsaved changes. Close anyway?`)) return
    if (doc.path && !this.closedStack.includes(doc.path)) this.closedStack.push(doc.path)
    this.selectedTabIds.delete(id)

    const index = group.docIds.indexOf(id)
    group.docIds = group.docIds.filter((docId) => docId !== id)
    if (group.activeId === id) group.activeId = group.docIds[Math.max(0, Math.min(index, group.docIds.length - 1))] ?? null

    const stillVisible = this.groups.some((candidate) => candidate.docIds.includes(id))
    if (!stillVisible) {
      this.docs = this.docs.filter((candidate) => candidate.id !== id)
      this.selectedTabIds.delete(id)
    }
    if (this.docs.length === 0) {
      const fresh = createUntitled()
      this.docs.push(fresh)
      this.groups[0].docIds = [fresh.id]
      this.groups[0].activeId = fresh.id
    }
    if (groupIndex === this.activeGroup) {
      const next = group.activeId ?? this.docs[0].id
      void this.activate(next, groupIndex, false)
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

  private applyDistractionFreeMode(enabled: boolean): void {
    document.body.classList.toggle('distraction-free', enabled)
    if (enabled) {
      this.sidebarVisibleBeforeDistractionFree = !this.sidebar.classList.contains('hidden')
      this.sidebar.classList.add('hidden')
    } else if (this.sidebarVisibleBeforeDistractionFree) {
      this.sidebar.classList.remove('hidden')
    }
    for (const group of this.groups) group.tabBar.classList.toggle('hidden', enabled)
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
      this.recordedTextEdits = []
      this.macroSteps = []
      this.statusSelection.textContent = 'Recording macro…'
    } else {
      const steps = this.lastMacro.length + this.recordedTextEdits.length
      this.statusSelection.textContent = `${steps} macro step${steps === 1 ? '' : 's'} recorded`
    }
  }

  private runMacro(): void {
    if (this.macroSteps.length === 0 && this.lastMacro.length === 0) {
      this.showError('No recorded macro is available.')
      return
    }
    this.isReplayingMacro = true
    try {
      this.replayMacroSteps(this.macroSteps.length > 0
        ? this.macroSteps
        : [{ kind: 'edits', edits: this.recordedTextEdits }, ...this.lastMacro.map((command) => ({ kind: 'command' as const, command }))]
      )
    } finally {
      this.isReplayingMacro = false
    }
  }

  private async saveMacro(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a project before saving a macro.')
      return
    }
    const name = window.prompt('Macro name:')?.trim()
    if (!name) return
    try {
      await window.editor.writeMacro(this.folder, {
        name,
        commands: this.lastMacro,
        ...(this.macroSteps.length > 0 ? { steps: this.macroSteps } : {}),
        ...(this.recordedTextEdits.length > 0 ? { edits: this.recordedTextEdits } : {})
      })
      this.statusSelection.textContent = `Saved macro: ${name}`
    } catch (error) {
      this.showError('Macro could not be saved.', error)
    }
  }

  private async runSavedMacro(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a project before running a saved macro.')
      return
    }
    try {
      const macros = await window.editor.listMacros(this.folder)
      if (macros.length === 0) {
        this.showError('No saved macros are available for this project.')
        return
      }
      this.palette.open({
        placeholder: 'Run saved macro…',
        items: macros.map((macro) => ({ label: macro.name, detail: `${macro.commands.length} command step${macro.commands.length === 1 ? '' : 's'}`, value: macro })),
        onAccept: (item) => {
          const macro = item.value as import('../../shared/ipc.js').SavedMacro
          this.isReplayingMacro = true
          try {
            if (macro.steps?.length) this.replayMacroSteps(macro.steps)
            else {
              if (macro.edits?.length) this.editor.applyEdits(macro.edits)
              else if (macro.text !== undefined) this.editor.replaceContent(macro.text)
              for (const command of macro.commands) if (this.isMenuEvent(command)) this.run(command)
            }
          } finally {
            this.isReplayingMacro = false
          }
        }
      })
    } catch (error) {
      this.showError('Saved macros could not be loaded.', error)
    }
  }

  private isRecordableMacroEvent(event: MenuEvent): boolean {
    return ['toggle-comment', 'move-line-up', 'move-line-down', 'copy-line-up', 'copy-line-down', 'delete-line', 'duplicate-selection', 'sort-lines'].includes(event)
  }

  /** Capture low-level editor edits so a macro can replay transformations, not a document snapshot. */
  private recordTextEdits(edits: Array<{ from: number; to: number; insert: string }>): void {
    if (!this.recordingMacro || this.isReplayingMacro || this.suppressRecordedTextEdits || this.syncingGroupContent) return
    const safeEdits = edits.map((edit) => ({ ...edit, insert: edit.insert.slice(0, 2 * 1024 * 1024) }))
    this.recordedTextEdits.push(...safeEdits)
    this.macroSteps.push({ kind: 'edits', edits: safeEdits })
    if (this.recordedTextEdits.length > 1_000) this.recordedTextEdits.splice(0, this.recordedTextEdits.length - 1_000)
    if (this.macroSteps.length > 1_000) this.macroSteps.splice(0, this.macroSteps.length - 1_000)
  }

  private replayMacroSteps(steps: import('../../shared/ipc.js').MacroStep[]): void {
    for (const step of steps) {
      if (step.kind === 'edits') this.editor.applyEdits(step.edits)
      else if (step.kind === 'command' && this.isMenuEvent(step.command)) this.run(step.command)
    }
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
    for (const snippet of this.project.snippets ?? []) snippets.push({ label: `Project: ${snippet.label}`, value: snippet.text })
    this.palette.open({
      placeholder: 'Insert snippet…',
      items: snippets,
      onAccept: (item) => this.editor.insertSnippet(String(item.value))
    })
  }

  private expandSnippetTrigger(): boolean {
    const doc = this.active
    if (!doc) return false
    const selection = this.editor.view.state.selection.main
    if (!selection.empty) return false
    const line = this.editor.view.state.doc.lineAt(selection.head)
    const before = this.editor.view.state.sliceDoc(line.from, selection.head)
    const trigger = /([\w-]+)$/.exec(before)?.[1]
    if (!trigger) return false
    const snippets = [
      ...this.plugins.flatMap((plugin) => plugin.snippets.map((snippet) => ({ snippet }))),
      ...(this.project.snippets ?? []).map((snippet) => ({ snippet }))
    ]
    const found = snippets.find(({ snippet }) => snippet.trigger === trigger && (!snippet.scope || snippet.scope === doc.language))
    if (!found) return false
    this.editor.view.dispatch({ changes: { from: selection.head - trigger.length, to: selection.head, insert: '' } })
    this.editor.insertSnippet(found.snippet.text)
    return true
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
      await window.editor.runBuild({ root: this.folder, command, shell: true })
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
            fileRegex: variant.fileRegex ?? system.fileRegex,
            env: variant.env ?? system.env,
            shell: variant.shell ?? system.shell
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

  private async importSublimeBuild(): Promise<void> {
    if (!this.folder) {
      this.showError('Open a project before importing a Sublime build system.')
      return
    }
    try {
      const imported = await window.editor.importSublimeBuild()
      if (!imported) return
      const detail = `${imported.system.name}\n${imported.system.command} ${imported.system.args.join(' ')}`.trim()
      if (!window.confirm(`Import Sublime build system?\n\n${detail}\n\nThe command will still require per-session approval before it runs.`)) return
      this.project.buildSystems = [imported.system, ...this.project.buildSystems.filter((system) => system.name !== imported.system.name)].slice(0, 30)
      await this.saveProject()
      this.activeBuildSystem = imported.system
      this.buildPanel.setCommand(imported.system.command)
      this.statusSelection.textContent = `Imported Sublime build system: ${imported.system.name}`
    } catch (error) {
      this.showError('Sublime build system could not be imported.', error)
    }
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
      const active = this.active
      const variables = this.buildVariables(active)
      await window.editor.runBuild({
        root: this.folder,
        name: system.name,
        command: this.expandBuildVariables(system.command, variables),
        args: system.args.map((arg) => this.expandBuildVariables(arg, variables)),
        workingDirectory: system.workingDirectory ? this.expandBuildVariables(system.workingDirectory, variables) : undefined,
        fileRegex: system.fileRegex
        , shell: system.shell
        , env: Object.fromEntries(Object.entries(system.env ?? {}).map(([key, value]) => [key, this.expandBuildVariables(value, variables)]))
      })
    } catch (error) {
      this.showError('The build system could not be started.', error)
    }
  }

  private buildVariables(doc: Doc | undefined): Record<string, string> {
    const file = doc?.path ?? ''
    const slash = Math.max(file.lastIndexOf('/'), file.lastIndexOf('\\'))
    const filePath = slash >= 0 ? file.slice(0, slash) : ''
    const fileName = slash >= 0 ? file.slice(slash + 1) : file
    const extension = /.([^.]+)$/.exec(fileName)?.[1] ?? ''
    const baseName = extension ? fileName.slice(0, -(extension.length + 1)) : fileName
    return {
      project_path: this.folder ?? '',
      folder: this.folder ?? '',
      file,
      file_path: filePath,
      file_name: fileName,
      file_base_name: baseName,
      file_extension: extension
    }
  }

  /** Substitute the familiar $file/$project_path tokens in a structured build system. */
  private expandBuildVariables(value: string, variables: Record<string, string>): string {
    return value.replace(/\$([a-z_][a-z0-9_]*)/gi, (token, name: string) => variables[name.toLowerCase()] ?? token)
  }

  private handleBuildOutput(output: BuildOutput): void {
    this.buildPanel.append(output)
    if (output.kind === 'stdout' || output.kind === 'stderr') this.buildOutputText += output.text
    if (output.kind === 'exit') this.buildPanel.setProblems(this.parseBuildProblems())
  }

  /** Open a project-scoped shell only after explicit per-session approval. */
  private toggleTerminal(): void {
    if (!this.folder) {
      this.showError(this.settings.locale === 'zh-CN' ? '请先打开文件夹，再启动终端。' : 'Open a folder before starting the terminal.')
      return
    }
    const wasVisible = this.terminalPanel.isVisible
    this.terminalPanel.toggle(!wasVisible)
    if (!wasVisible && !this.terminalSessionId && !this.terminalStartingSessionId) void this.startTerminal()
  }

  private newTerminalSessionId(): string {
    const bytes = new Uint32Array(4)
    crypto.getRandomValues(bytes)
    return `terminal-${Array.from(bytes, (value) => value.toString(36)).join('-')}`
  }

  private async startTerminal(): Promise<void> {
    if (!this.folder) {
      this.showError(this.settings.locale === 'zh-CN' ? '请先打开文件夹，再启动终端。' : 'Open a folder before starting the terminal.')
      return
    }
    if (this.terminalSessionId || this.terminalStartingSessionId) {
      this.terminalPanel.toggle(true)
      return
    }
    const root = this.folder
    const approved = window.confirm(this.settings.locale === 'zh-CN'
      ? `启动项目终端？\n\n工作目录：${root}\n\n这会启动本机 shell。该 shell 运行的命令可读取、修改或删除当前项目文件，并可能访问网络。仅在信任此项目和命令时继续。`
      : `Start project terminal?\n\nWorking directory: ${root}\n\nThis starts a local shell. Commands run by it can read, modify, or delete project files and may access the network. Continue only if you trust this project and its commands.`)
    if (!approved) return

    const sessionId = this.newTerminalSessionId()
    this.terminalStartingSessionId = sessionId
    // Register before awaiting IPC: shell output can arrive before the invoke
    // response, and must not be discarded as belonging to no active session.
    this.terminalSessionId = sessionId
    this.terminalPanel.clear()
    this.terminalPanel.toggle(true)
    this.terminalPanel.setStarting(true)
    try {
      await window.editor.startTerminal(root, sessionId)
      // A newer start/stop may have occurred while IPC was pending.
      if (this.terminalStartingSessionId !== sessionId || this.terminalSessionId !== sessionId) {
        void window.editor.stopTerminal(sessionId)
        return
      }
      this.terminalStartingSessionId = null
      this.terminalSessionId = sessionId
      this.terminalPanel.setRunning(true)
      this.statusSelection.textContent = this.settings.locale === 'zh-CN' ? '项目终端已启动' : 'Project terminal started'
    } catch (error) {
      if (this.terminalStartingSessionId === sessionId || this.terminalSessionId === sessionId) {
        this.terminalStartingSessionId = null
        this.terminalSessionId = null
        this.terminalPanel.setRunning(false)
        this.showError(this.settings.locale === 'zh-CN' ? '终端无法启动。' : 'The terminal could not be started.', error)
      }
    }
  }

  private async writeTerminal(text: string): Promise<void> {
    const sessionId = this.terminalSessionId
    if (!sessionId) {
      this.showError(this.settings.locale === 'zh-CN' ? '终端尚未启动。' : 'The terminal is not running.')
      return
    }
    try {
      await window.editor.writeTerminal(sessionId, text)
    } catch (error) {
      this.terminalSessionId = null
      this.terminalPanel.setRunning(false)
      this.showError(this.settings.locale === 'zh-CN' ? '无法向终端发送输入。' : 'Could not send input to the terminal.', error)
    }
  }

  private async stopTerminal(): Promise<void> {
    const sessionId = this.terminalSessionId ?? this.terminalStartingSessionId
    if (!sessionId) {
      this.terminalPanel.setRunning(false)
      return
    }
    // Clear local state first; late output from this session is ignored.
    this.terminalSessionId = null
    this.terminalStartingSessionId = null
    this.terminalPanel.setRunning(false)
    try {
      await window.editor.stopTerminal(sessionId)
      this.statusSelection.textContent = this.settings.locale === 'zh-CN' ? '项目终端已停止' : 'Project terminal stopped'
    } catch (error) {
      this.showError(this.settings.locale === 'zh-CN' ? '终端无法停止。' : 'The terminal could not be stopped.', error)
    }
  }

  private handleTerminalOutput(output: import('../../shared/ipc.js').TerminalOutput): void {
    if (output.sessionId !== this.terminalSessionId) return
    this.terminalPanel.append(output)
    if (output.kind === 'exit') {
      this.terminalSessionId = null
      this.terminalStartingSessionId = null
      this.terminalPanel.setRunning(false)
      this.statusSelection.textContent = this.settings.locale === 'zh-CN'
        ? `终端已退出${output.code === 0 ? '' : `（代码 ${output.code ?? '未知'}）`}`
        : `Terminal exited${output.code === 0 ? '' : ` (code ${output.code ?? 'unknown'})`}`
    }
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
    const items: PaletteItem[] = localizedCommands(this.settings.locale).map((c) => ({
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
    for (const [id, command] of this.extensionCommands) {
      items.push({ label: `${command.plugin.name}: ${command.title}`, detail: id, value: { kind: 'extension-command', id } })
    }
    this.palette.open({
      placeholder: this.settings.locale === 'zh-CN' ? '输入命令…' : 'Type a command…',
      items,
      onAccept: (item) => {
        if (typeof item.value === 'object' && item.value && (item.value as { kind?: string }).kind === 'plugin-command') {
          const command = (item.value as { command: PluginManifest['commands'][number] }).command
          if (command.insertText) this.editor.insertText(command.insertText)
          return
        }
        if (typeof item.value === 'object' && item.value && (item.value as { kind?: string }).kind === 'extension-command') {
          const id = (item.value as { id: string }).id
          this.extensionCommands.get(id)?.run()
          return
        }
        this.run(item.value as MenuEvent)
      }
    })
  }

  private applyLocale(locale: Settings['locale']): void {
    this.t = makeTranslator(locale)
    document.documentElement.lang = locale
    document.title = this.t('appTitle')
    this.tree?.setLocale(locale)
    if (!this.folder) this.workspaceName.textContent = this.t('noFolder')
    this.statusLanguage.textContent = this.active?.language === 'Plain Text' || !this.active
      ? this.t('plainText')
      : this.active.language
    if (this.buildPanel) this.buildPanel.setLocale(locale)
    if (this.gitPanel) this.gitPanel.setLocale(locale)
    if (this.findResults) this.findResults.setLocale(locale)
    if (this.searchPanel) this.searchPanel.setLocale(locale)
    if (this.jsonView) this.jsonView.setLocale(locale)
    if (this.outlinePanel) this.outlinePanel.setLocale(locale)
    if (this.terminalPanel) this.terminalPanel.setLocale(locale)
    if (this.settingsPanel) this.settingsPanel.setLocale(locale)
    this.jsonFormatBtn.textContent = locale === 'zh-CN' ? '格式化' : 'Format'
    this.jsonCompactBtn.textContent = locale === 'zh-CN' ? '压缩' : 'Compact'
    this.jsonViewBtn.textContent = locale === 'zh-CN' ? '视图' : 'View'
    this.jsonFormatBtn.title = this.t('formatJson')
    this.jsonCompactBtn.title = this.t('compactJson')
    this.jsonViewBtn.title = this.t('jsonView')
    if (this.groups.length > 0) {
      this.updateStatus()
      this.syncEditorChrome()
      this.syncOutline(true)
    }
  }

  private setLocale(locale: Settings['locale']): void {
    if (this.settings.locale === locale) return
    this.applyUserSettings({ ...this.settings, locale })
    this.statusSelection.textContent = locale === 'zh-CN' ? '界面语言：简体中文' : 'Interface language: English'
  }

  /** Ctrl/Cmd+P — fuzzy workspace files, :line[:column], @symbol and #project-symbol modes. */
  private async openGotoAnything(): Promise<void> {
    let files: string[] = []
    if (this.folders.length > 0) {
      try {
        files = (await Promise.all(this.folders.map((root) => window.editor.listFiles(root)))).flat().filter((file) => !this.isProjectExcluded(file))
      } catch {
        files = []
      }
    }
    const root = this.folder
    this.palette.open({
      placeholder: 'Goto Anything — file, :line[:column], @symbol, #project symbol',
      onQuery: async (query) => {
        if (query.startsWith('#')) await this.ensureProjectSymbols()
        return this.gotoAnythingItems(query, files, root)
      },
      onAccept: (item) => this.acceptGoto(item)
    })
  }

  private async ensureProjectSymbols(): Promise<void> {
    if (this.folders.length === 0 || (this.projectSymbols.length > 0 && Date.now() - this.projectSymbolIndexAt <= 30_000)) return
    this.projectSymbols = (await Promise.all(this.folders.map((root) => window.editor.listWorkspaceSymbols(root))))
      .flat()
      .filter((symbol) => !this.isProjectExcluded(symbol.path))
    this.projectSymbolIndexAt = Date.now()
  }

  private isProjectExcluded(file: string, isDirectory = false): boolean {
    const root = this.folders.find((candidate) => file === candidate || file.startsWith(`${candidate}/`) || file.startsWith(`${candidate}\\`))
    if (!root) return false
    const relative = file.slice(root.length + 1).replaceAll('\\', '/')
    return this.project.exclude.some((pattern) => globMatches(relative, pattern, isDirectory))
  }

  /** Returns the most specific authorised root containing a document path. */
  private workspaceRootForPath(filePath: string | null): string | null {
    if (!filePath) return null
    return [...this.folders]
      .sort((a, b) => b.length - a.length)
      .find((root) => filePath === root || filePath.startsWith(`${root}/`) || filePath.startsWith(`${root}\\`)) ?? null
  }

  /** Compute palette rows for a Goto Anything query based on its mode prefix. */
  private gotoAnythingItems(query: string, files: string[], root: string | null): PaletteItem[] {
    // ":123" / ":123:8" → go to a line / column in the current file.
    if (query.startsWith(':')) {
      const location = this.parseGotoLocation(query.slice(1))
      const suffix = location ? ` ${location.line}${location.column ? `:${location.column}` : ''}` : ' …'
      return [{ label: `Go to${suffix}`, value: { kind: 'line', line: location?.line ?? Number.NaN, column: location?.column } }]
    }
    // "@sym" → symbols in the current file.
    if (query.startsWith('@')) {
      return this.symbolItems(query.slice(1))
    }
    if (query.startsWith('#')) {
      const symbols = this.projectSymbols
      const source = query.length > 1
        ? fuzzyFilter(query.slice(1), symbols, (symbol) => `${symbol.label} ${symbol.path}`)
        : symbols.map((item) => ({ item }))
      return source.slice(0, 200).map(({ item }) => ({
        label: item.label,
        detail: `${item.path}:${item.line}`,
        value: { kind: 'file-line', path: item.path, line: item.line }
      }))
    }
    // "path/to/file:42" / "path/to/file:42:8" opens a fuzzy-matched file at the requested location.
    const fileLine = /^(.*):(\d+)(?::(\d+))?$/.exec(query)
    if (fileLine && fileLine[1].trim()) {
      const line = Number(fileLine[2])
      const column = fileLine[3] ? Number(fileLine[3]) : undefined
      const relForLine = (p: string): string => root && p.startsWith(root) ? p.slice(root.length + 1) : p
      return fuzzyFilter(fileLine[1], files, relForLine).slice(0, 200).map(({ item }) => ({
        label: baseName(item),
        detail: `${relForLine(item)}:${line}${column ? `:${column}` : ''}`,
        value: { kind: 'file-line', path: item, line, column }
      }))
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

  /** Parse positive 1-based line[:column] text shared by current-file Goto mode. */
  private parseGotoLocation(input: string): { line: number; column?: number } | null {
    const match = /^(\d+)(?::(\d+))?$/.exec(input.trim())
    if (!match) return null
    const line = Number(match[1])
    const column = match[2] ? Number(match[2]) : undefined
    if (!Number.isSafeInteger(line) || line < 1 || (column !== undefined && (!Number.isSafeInteger(column) || column < 1))) return null
    return { line, column }
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
      | { kind: 'line'; line: number; column?: number }
      | { kind: 'file-line'; path: string; line: number; column?: number }
      | { kind: 'pos'; pos: number }
    if (v.kind === 'file') {
      void this.openPath(v.path)
    } else if (v.kind === 'line') {
      if (Number.isFinite(v.line) && v.line > 0) this.editor.gotoLineColumn(v.line, v.column)
    } else if (v.kind === 'file-line') {
      void this.openPath(v.path).then(() => this.editor.gotoLineColumn(v.line, v.column))
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
          this.editor.setSpellCheck(this.settings.spellCheck && (this.isMarkdownDoc(doc) || language === 'Plain Text'))
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
        doc.groupStates.set(group.id, group.editor.getState())
        doc.viewStates.set(group.id, group.editor.getViewState(group.id))
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
          ...(d.bookmarks.length > 0 ? { bookmarks: d.bookmarks } : {}),
          ...(d.viewStates.size > 0 ? { views: [...d.viewStates.values()] } : {}),
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

    const session: Session = { openFiles, activeIndex, folder: this.folder, folders: this.folders, layout }
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
        tab.className = 'tab' + (doc.id === group.activeId ? ' active' : '') + (this.selectedTabIds.has(doc.id) ? ' selected' : '')
        tab.draggable = true
        tab.dataset.docId = doc.id

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
        tab.addEventListener('click', (event) => {
          if (event.ctrlKey || event.metaKey) {
            if (this.selectedTabIds.has(doc.id)) this.selectedTabIds.delete(doc.id)
            else this.selectedTabIds.add(doc.id)
            this.renderTabs()
            return
          }
          this.selectedTabIds.clear()
          void this.activate(doc.id, group.id)
        })
        tab.addEventListener('contextmenu', (event) => {
          event.preventDefault()
          this.openTabContextMenu(doc, group.id, event.clientX, event.clientY)
        })
        tab.addEventListener('dragstart', (event) => {
          this.draggingTab = { groupId: group.id, docId: doc.id }
          tab.classList.add('dragging')
          if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = 'move'
            event.dataTransfer.setData('text/plain', `lumen-tab:${doc.id}`)
          }
        })
        tab.addEventListener('dragend', () => {
          this.draggingTab = null
          for (const target of group.tabBar.querySelectorAll('.tab-drop-before, .tab-drop-after, .dragging')) {
            target.classList.remove('tab-drop-before', 'tab-drop-after', 'dragging')
          }
        })
        tab.addEventListener('dragover', (event) => {
          const dragging = this.draggingTab
          if (!dragging || dragging.groupId !== group.id || dragging.docId === doc.id || (this.selectedTabIds.has(dragging.docId) && this.selectedTabIds.has(doc.id))) return
          event.preventDefault()
          if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
          const rect = tab.getBoundingClientRect()
          const before = event.clientX < rect.left + rect.width / 2
          tab.classList.toggle('tab-drop-before', before)
          tab.classList.toggle('tab-drop-after', !before)
        })
        tab.addEventListener('dragleave', () => tab.classList.remove('tab-drop-before', 'tab-drop-after'))
        tab.addEventListener('drop', (event) => {
          const dragging = this.draggingTab
          if (!dragging || dragging.groupId !== group.id || dragging.docId === doc.id || (this.selectedTabIds.has(dragging.docId) && this.selectedTabIds.has(doc.id))) return
          event.preventDefault()
          const rect = tab.getBoundingClientRect()
          this.reorderTabs(group.id, dragging.docId, doc.id, event.clientX < rect.left + rect.width / 2)
        })
        group.tabBar.appendChild(tab)
      }
    }
  }

  /** Reorder the dragged tab (or its selected set) within one editor group. */
  private reorderTabs(groupId: number, draggedId: string, targetId: string | null, before: boolean): void {
    const group = this.groups[groupId]
    if (!group || !group.docIds.includes(draggedId)) return
    const moving = this.selectedTabIds.has(draggedId)
      ? group.docIds.filter((id) => this.selectedTabIds.has(id))
      : [draggedId]
    if (targetId && moving.includes(targetId)) return
    const remaining = group.docIds.filter((id) => !moving.includes(id))
    let index = targetId ? remaining.indexOf(targetId) : remaining.length
    if (index < 0) index = remaining.length
    if (targetId && !before) index += 1
    group.docIds = [...remaining.slice(0, index), ...moving, ...remaining.slice(index)]
    this.selectedTabIds = new Set(moving)
    this.draggingTab = null
    this.renderTabs()
    this.scheduleSessionSave()
  }

  private openTabContextMenu(doc: Doc, groupId: number, x: number, y: number): void {
    document.querySelector('.tree-context-menu')?.remove()
    const menu = document.createElement('div')
    menu.className = 'tree-context-menu'
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`
    const add = (label: string, run: () => void): void => {
      const button = document.createElement('button')
      button.textContent = label
      button.addEventListener('click', () => { menu.remove(); run() })
      menu.appendChild(button)
    }
    if (doc.path) {
      add(this.settings.locale === 'zh-CN' ? '复制路径' : 'Copy Path', () => { void this.copyPath(doc.path!, false) })
      add(this.settings.locale === 'zh-CN' ? '复制相对路径' : 'Copy Relative Path', () => { void this.copyPath(doc.path!, true) })
    }
    add(this.settings.locale === 'zh-CN' ? '关闭标签页' : 'Close Tab', () => this.closeDocFromGroup(doc.id, groupId))
    document.body.appendChild(menu)
    const dismiss = (event: MouseEvent): void => {
      if (!menu.contains(event.target as Node)) menu.remove()
      document.removeEventListener('mousedown', dismiss)
    }
    window.setTimeout(() => document.addEventListener('mousedown', dismiss), 0)
  }

  /** Refresh all status-bar fields for the active document. */
  private updateStatus(): void {
    const doc = this.active
    this.statusLanguage.textContent = !doc || doc.language === 'Plain Text' ? this.t('plainText') : doc.language
    this.statusEol.textContent = doc?.eol ?? 'LF'
    this.statusEncoding.textContent = doc?.encoding === 'utf8bom' ? 'UTF-8 BOM' : doc?.encoding.toUpperCase() ?? 'UTF-8'
    this.updatePositionStatus(this.editor.view.state)
  }

  /** Update the Ln/Col and selection-length status readouts. */
  private updatePositionStatus(state: EditorState): void {
    const sel = state.selection.main
    const line = state.doc.lineAt(sel.head)
    const col = sel.head - line.from + 1
    this.statusPosition.textContent = this.settings.locale === 'zh-CN'
      ? `行 ${line.number}，列 ${col}`
      : `Ln ${line.number}, Col ${col}`

    const len = Math.abs(sel.to - sel.from)
    this.statusSelection.textContent = len > 0
      ? (this.settings.locale === 'zh-CN' ? `（已选择 ${len} 个字符）` : `(${len} selected)`)
      : ''
    if (this.outlinePanel && state === this.editor.view.state) this.outlinePanel.setCursor(sel.head)
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
