import { Editor } from './editor.js'
import { FileTree } from './fileTree.js'
import { createUntitled, createFromFile, isDirty, baseName, type Doc } from './documents.js'
import type { EditorState } from '@codemirror/state'
import type { MenuEvent } from '../../shared/ipc.js'
import './styles.css'

/**
 * The renderer application shell. Owns the list of open documents, the single
 * CodeMirror editor instance, the tab bar, file tree and status bar, and wires
 * all of them to the menu/accelerator events forwarded from the main process.
 */
class App {
  private editor: Editor
  private tree: FileTree
  private docs: Doc[] = []
  private activeId: string | null = null

  // Cached DOM references.
  private tabBar = document.getElementById('tab-bar')!
  private workspaceName = document.getElementById('workspace-name')!
  private statusPosition = document.getElementById('status-position')!
  private statusSelection = document.getElementById('status-selection')!
  private statusLanguage = document.getElementById('status-language')!
  private sidebar = document.getElementById('sidebar')!

  constructor() {
    const host = document.getElementById('editor-host')!
    this.editor = new Editor(host, {
      onDocChange: () => this.handleDocChange(),
      onCursorChange: (state) => this.updatePositionStatus(state)
    })

    this.tree = new FileTree(document.getElementById('file-tree')!, (path) =>
      this.openPath(path)
    )

    this.bindMenu()
    this.bindShortcuts()

    // Start with a single empty buffer so the editor is never blank/broken.
    this.addDoc(createUntitled())
  }

  /** Subscribe to menu / accelerator events from the main process. */
  private bindMenu(): void {
    const handlers: Record<MenuEvent, () => void> = {
      'new-file': () => this.addDoc(createUntitled()),
      'open-file': () => this.openViaDialog(),
      'open-folder': () => this.openFolder(),
      save: () => this.save(false),
      'save-as': () => this.save(true),
      'close-tab': () => this.closeActive(),
      'next-tab': () => this.cycleTab(1),
      'prev-tab': () => this.cycleTab(-1),
      find: () => this.editor.openSearch(),
      replace: () => this.editor.openSearch(),
      'toggle-sidebar': () => this.toggleSidebar(),
      'toggle-word-wrap': () => this.editor.toggleWordWrap(),
      'toggle-theme': () => this.editor.toggleTheme(),
      'command-palette': () => this.editor.openSearch(),
      'go-to-line': () => this.editor.goToLine()
    }
    window.editor.onMenu((event) => handlers[event]?.())
  }

  /** Keyboard shortcuts handled in the renderer (tab switching by number, etc.). */
  private bindShortcuts(): void {
    window.addEventListener('keydown', (e) => {
      const mod = e.ctrlKey || e.metaKey
      if (mod && e.key >= '1' && e.key <= '9') {
        const idx = Number(e.key) - 1
        if (idx < this.docs.length) {
          e.preventDefault()
          this.activate(this.docs[idx].id)
        }
      }
    })
  }

  /** Add a document, make it active and render the UI. */
  private addDoc(doc: Doc): void {
    this.docs.push(doc)
    this.activate(doc.id)
  }

  /** Get the currently active document, if any. */
  private get active(): Doc | undefined {
    return this.docs.find((d) => d.id === this.activeId)
  }

  /** Switch the active tab, syncing the editor content and status bar. */
  private async activate(id: string): Promise<void> {
    // Persist current editor text into the outgoing doc before switching.
    const current = this.active
    if (current) current.content = this.editor.getContent()

    const doc = this.docs.find((d) => d.id === id)
    if (!doc) return
    this.activeId = id
    this.editor.setDocument(doc.content)
    doc.language = await this.editor.setLanguageForFile(doc.name)
    this.renderTabs()
    this.updateStatus()
    this.editor.focus()
  }

  /** Update the active doc's cached content and refresh the dirty indicator. */
  private handleDocChange(): void {
    const doc = this.active
    if (!doc) return
    doc.content = this.editor.getContent()
    this.renderTabs()
  }

  /** Open a file chosen from the native dialog. */
  private async openViaDialog(): Promise<void> {
    const file = await window.editor.openFile()
    if (file) this.openLoaded(file.path, file.content)
  }

  /** Open a file by path (from the file tree). */
  private async openPath(path: string): Promise<void> {
    // Focus the tab if the file is already open.
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      this.activate(existing.id)
      return
    }
    const file = await window.editor.openPath(path)
    this.openLoaded(file.path, file.content)
  }

  /** Create (or focus) a tab for an already-loaded file. */
  private openLoaded(path: string, content: string): void {
    const existing = this.docs.find((d) => d.path === path)
    if (existing) {
      this.activate(existing.id)
      return
    }
    // Replace a single pristine untitled buffer instead of stacking tabs.
    if (
      this.docs.length === 1 &&
      this.docs[0].path === null &&
      !isDirty(this.docs[0])
    ) {
      this.docs = []
    }
    this.addDoc(createFromFile(path, content))
  }

  /** Open a workspace folder and populate the file tree. */
  private async openFolder(): Promise<void> {
    const folder = await window.editor.openFolder()
    if (!folder) return
    this.workspaceName.textContent = baseName(folder.root).toUpperCase()
    this.tree.render(folder.entries)
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
    doc.language = await this.editor.setLanguageForFile(doc.name)
    this.renderTabs()
    this.updateStatus()
  }

  /** Close the active tab, guarding against losing unsaved changes. */
  private closeActive(): void {
    const doc = this.active
    if (!doc) return
    if (isDirty(doc)) {
      const ok = confirm(`"${doc.name}" has unsaved changes. Close anyway?`)
      if (!ok) return
    }
    const idx = this.docs.findIndex((d) => d.id === doc.id)
    this.docs.splice(idx, 1)

    if (this.docs.length === 0) {
      this.addDoc(createUntitled())
      return
    }
    // Activate the neighbour that now occupies this slot.
    const next = this.docs[Math.min(idx, this.docs.length - 1)]
    this.activate(next.id)
  }

  /** Cycle to the next/previous tab, wrapping around. */
  private cycleTab(delta: number): void {
    if (this.docs.length < 2) return
    const idx = this.docs.findIndex((d) => d.id === this.activeId)
    const next = (idx + delta + this.docs.length) % this.docs.length
    this.activate(this.docs[next].id)
  }

  /** Show or hide the sidebar. */
  private toggleSidebar(): void {
    this.sidebar.classList.toggle('hidden')
  }

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
        this.activate(doc.id)
        this.closeActive()
      })

      tab.append(dot, label, close)
      tab.addEventListener('click', () => this.activate(doc.id))
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
