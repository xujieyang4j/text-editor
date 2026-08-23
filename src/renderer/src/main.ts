import { Editor, allLanguageNames } from './editor.js'
import { FileTree } from './fileTree.js'
import { Palette, type PaletteItem } from './palette.js'
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
import {
  DEFAULT_SETTINGS,
  type MenuEvent,
  type Settings,
  type Session,
  type SessionFile
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
  private preview!: MarkdownPreview
  private docs: Doc[] = []
  private activeId: string | null = null
  private settings: Settings = { ...DEFAULT_SETTINGS }
  private folder: string | null = null
  /** Recently-closed file paths, for Reopen Closed Tab (LIFO). */
  private closedStack: string[] = []
  /** Debounce handle for session persistence. */
  private saveSessionTimer: number | null = null

  // Cached DOM references.
  private tabBar = document.getElementById('tab-bar')!
  private workspaceName = document.getElementById('workspace-name')!
  private statusPosition = document.getElementById('status-position')!
  private statusSelection = document.getElementById('status-selection')!
  private statusLanguage = document.getElementById('status-language')!
  private sidebar = document.getElementById('sidebar')!
  private host = document.getElementById('editor-host')!
  private editorArea = document.getElementById('editor-area')!
  private browserBtn = document.getElementById('browser-btn') as HTMLButtonElement
  private previewBtn = document.getElementById('preview-btn') as HTMLButtonElement

  constructor() {
    this.tree = new FileTree(document.getElementById('file-tree')!, (path) =>
      this.openPath(path)
    )
    // The status-bar language field opens the syntax picker (like Sublime).
    this.statusLanguage.addEventListener('click', () => this.pickLanguage())
    this.statusLanguage.classList.add('clickable')

    // Floating browser icon (shown only for HTML docs) → open in browser.
    this.browserBtn.addEventListener('click', () => this.run('open-in-browser'))
    // Floating preview icon (shown only for markdown docs) → toggle preview.
    this.previewBtn.addEventListener('click', () => this.run('toggle-preview'))

    this.bindMenu()
    this.bindShortcuts()
    void this.boot()
  }

  /** Load settings, construct the editor, then restore the previous session. */
  private async boot(): Promise<void> {
    this.settings = await window.editor.readSettings()

    this.editor = new Editor(
      this.host,
      {
        onDocChange: () => this.handleDocChange(),
        onCursorChange: (state) => this.updatePositionStatus(state)
      },
      this.settings
    )

    this.preview = new MarkdownPreview(this.editorArea)

    await this.restoreSession()
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
        const diskContent = sf.path ? (await window.editor.openPath(sf.path)).content : ''
        this.docs.push(createFromSession(diskContent, sf))
      } catch {
        // File was moved/deleted since last run. If we still hold the user's
        // unsaved draft, keep it as an untitled-style buffer rather than lose
        // their work; otherwise skip.
        if (sf.draft !== undefined) {
          this.docs.push(createFromSession('', { ...sf }))
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
      case 'replace':
        this.editor.openSearch()
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
        this.persistSessionNow()
        break
    }
  }

  /** Renderer-owned keyboard shortcuts not expressible as menu accelerators. */
  private bindShortcuts(): void {
    window.addEventListener('keydown', (e) => {
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
    window.addEventListener('beforeunload', () => this.persistSessionNow())
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
    if (current) current.content = this.editor.getContent()

    const doc = this.docs.find((d) => d.id === id)
    if (!doc) return
    this.activeId = id
    this.editor.setDocument(doc.content)
    if (!doc.languageLocked) {
      doc.language = await this.editor.setLanguageForFile(doc.name)
    } else {
      await this.editor.setLanguageByName(doc.language)
    }
    this.renderTabs()
    this.updateStatus()
    this.editor.focus()
    this.scheduleSessionSave()
    this.syncEditorChrome()
  }

  /** Update the active doc's cached content and refresh the dirty indicator. */
  private handleDocChange(): void {
    const doc = this.active
    if (!doc) return
    doc.content = this.editor.getContent()
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
    this.browserBtn.classList.toggle('hidden', !html)
    this.previewBtn.classList.toggle('hidden', !md)

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
    await window.editor.openInBrowser({
      path: doc.path,
      content: doc.content,
      dirty: isDirty(doc)
    })
  }

  /** Open a file chosen from the native dialog. */
  private async openViaDialog(): Promise<void> {
    const file = await window.editor.openFile()
    if (file) this.openLoaded(file.path, file.content)
  }

  /** Open a file by path (from the file tree or Goto Anything). */
  private async openPath(path: string): Promise<void> {
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      void this.activate(existing.id)
      return
    }
    const file = await window.editor.openPath(path)
    this.openLoaded(file.path, file.content)
  }

  /** Create (or focus) a tab for an already-loaded file. */
  private openLoaded(path: string, content: string): void {
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      void this.activate(existing.id)
      return
    }
    // Replace a single pristine untitled buffer instead of stacking tabs.
    if (this.docs.length === 1 && this.docs[0].path === null && !isDirty(this.docs[0])) {
      this.docs = []
    }
    this.addDoc(createFromFile(path, content))
  }

  /** Open a workspace folder via dialog and populate the file tree. */
  private async openFolder(): Promise<void> {
    const folder = await window.editor.openFolder()
    if (!folder) return
    this.folder = folder.root
    this.workspaceName.textContent = baseName(folder.root).toUpperCase()
    this.tree.render(folder.entries)
    this.scheduleSessionSave()
  }

  /** Open a workspace folder by a known path (session restore). */
  private async openFolderPath(root: string): Promise<void> {
    try {
      const entries = await window.editor.readDir(root)
      this.folder = root
      this.workspaceName.textContent = baseName(root).toUpperCase()
      this.tree.render(entries)
    } catch {
      // Folder gone since last run — ignore.
    }
  }

  /** Save the active document. `forceDialog` forces a save-as. */
  private async save(forceDialog: boolean): Promise<void> {
    const doc = this.active
    if (!doc) return
    doc.content = this.editor.getContent()

    const result = forceDialog
      ? await window.editor.saveAs(doc.content, doc.name)
      : await window.editor.save(doc.path, doc.content)

    if (!result.saved || !result.path) return
    doc.path = result.path
    doc.name = baseName(result.path)
    doc.savedContent = doc.content
    if (!doc.languageLocked) {
      doc.language = await this.editor.setLanguageForFile(doc.name)
    }
    this.renderTabs()
    this.updateStatus()
    this.scheduleSessionSave()
    this.syncEditorChrome()
  }

  /** Close the active tab, guarding against losing unsaved changes. */
  private closeActive(): void {
    const doc = this.active
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
    const path = this.closedStack.pop()
    if (!path) return
    await this.openPath(path)
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

  // ---- Command palette & Goto modes ----

  /** Ctrl/Cmd+Shift+P — fuzzy list of all commands. */
  private openCommandPalette(): void {
    const items: PaletteItem[] = COMMANDS.map((c) => ({
      label: c.title,
      hint: c.hint,
      value: c.id
    }))
    this.palette.open({
      placeholder: 'Type a command…',
      items,
      onAccept: (item) => this.run(item.value as MenuEvent)
    })
  }

  /** Ctrl/Cmd+P — fuzzy list of workspace files, with :line and @symbol modes. */
  private async openGotoAnything(): Promise<void> {
    let files: string[] = []
    if (this.folder) {
      try {
        files = await window.editor.listFiles(this.folder)
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
        doc.language = await this.editor.setLanguageByName(name)
        doc.languageLocked = name !== 'Plain Text'
        this.updateStatus()
        // Picking "Markdown" (or leaving it) should immediately reveal/hide the
        // preview icon, so refresh the type-dependent editor chrome.
        this.syncEditorChrome()
      }
    })
  }

  // ---- Persistence ----

  /** Persist settings to disk (fire-and-forget). */
  private persistSettings(): void {
    void window.editor.writeSettings(this.settings)
  }

  /** Debounced session save to avoid thrashing on rapid edits/switches. */
  private scheduleSessionSave(): void {
    if (this.saveSessionTimer !== null) window.clearTimeout(this.saveSessionTimer)
    this.saveSessionTimer = window.setTimeout(() => this.persistSessionNow(), 400)
  }

  /**
   * Write the current session immediately. Persists a draft for every buffer
   * that is dirty or untitled-with-content, so unsaved work survives an
   * unexpected quit (hot exit). Clean file-backed buffers store only their
   * path and are re-read from disk on restore.
   */
  private persistSessionNow(): void {
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
    void window.editor.writeSession(session)
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
        void this.activate(doc.id).then(() => this.closeActive())
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
}

// Boot the app once the DOM is ready.
window.addEventListener('DOMContentLoaded', () => {
  new App()
})
