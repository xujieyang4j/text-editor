import type { DirEntry } from '../../shared/ipc.js'

/** Callback fired when a file (not a folder) is activated in the tree. */
type FileOpenHandler = (path: string) => void

export interface FileTreeHandlers {
  onOpenFile: FileOpenHandler
  onCreate: (parent: string, isDirectory: boolean) => void
  onRename: (path: string) => void
  onDelete: (path: string) => void
  onReveal: (path: string) => void
  onError: (message: string, error: unknown) => void
}

/**
 * Lazy, collapsible file tree rendered from the opened workspace folder.
 * Directory children are fetched on first expand via the preload API.
 */
export class FileTree {
  private container: HTMLElement
  private handlers: FileTreeHandlers
  /** Tracks which directory paths are currently expanded. */
  private expanded = new Set<string>()

  private rootEntries: DirEntry[] = []

  constructor(container: HTMLElement, handlers: FileTreeHandlers) {
    this.container = container
    this.handlers = handlers
  }

  /** Render a fresh workspace root and reset expansion state. */
  render(entries: DirEntry[]): void {
    this.expanded.clear()
    this.rootEntries = entries
    this.container.replaceChildren(this.buildList(entries, 0))
  }

  /** Clear the tree (no workspace open). */
  clear(): void {
    this.rootEntries = []
    this.container.replaceChildren()
  }

  /** Re-render the root after a mutation or filesystem-watch notification. */
  refresh(): void {
    if (this.rootEntries.length > 0) this.container.replaceChildren(this.buildList(this.rootEntries, 0))
  }

  /** Build a <ul> for a set of sibling entries at the given depth. */
  private buildList(entries: DirEntry[], depth: number): HTMLElement {
    const ul = document.createElement('ul')
    ul.className = 'tree-list'
    for (const entry of entries) {
      ul.appendChild(this.buildItem(entry, depth))
    }
    return ul
  }

  /** Build a single <li> row plus (for expanded dirs) its child list. */
  private buildItem(entry: DirEntry, depth: number): HTMLElement {
    const li = document.createElement('li')
    li.className = 'tree-item'

    const row = document.createElement('div')
    row.className = 'tree-row'
    row.style.paddingLeft = `${depth * 14 + 8}px`

    const twisty = document.createElement('span')
    twisty.className = 'tree-twisty'
    twisty.textContent = entry.isDirectory ? '▸' : ''

    const icon = document.createElement('span')
    icon.className = 'tree-icon'
    icon.textContent = entry.isDirectory ? '📁' : '📄'

    const label = document.createElement('span')
    label.className = 'tree-label'
    label.textContent = entry.name

    row.append(twisty, icon, label)
    li.appendChild(row)

    if (entry.isDirectory) {
      row.addEventListener('click', () => this.toggleDir(entry, li, twisty, depth))
    } else {
      row.addEventListener('click', () => this.handlers.onOpenFile(entry.path))
    }

    row.addEventListener('contextmenu', (event) => {
      event.preventDefault()
      this.openContextMenu(entry, event.clientX, event.clientY)
    })

    return li
  }

  private openContextMenu(entry: DirEntry, x: number, y: number): void {
    document.querySelector('.tree-context-menu')?.remove()
    const menu = document.createElement('div')
    menu.className = 'tree-context-menu'
    menu.style.left = `${x}px`
    menu.style.top = `${y}px`

    const action = (label: string, run: () => void): void => {
      const button = document.createElement('button')
      button.textContent = label
      button.addEventListener('click', () => { menu.remove(); run() })
      menu.appendChild(button)
    }
    if (entry.isDirectory) {
      action('New File…', () => this.handlers.onCreate(entry.path, false))
      action('New Folder…', () => this.handlers.onCreate(entry.path, true))
    }
    action('Rename…', () => this.handlers.onRename(entry.path))
    action('Move to Trash', () => this.handlers.onDelete(entry.path))
    action('Reveal in Folder', () => this.handlers.onReveal(entry.path))
    document.body.appendChild(menu)

    const dismiss = (event: MouseEvent): void => {
      if (!menu.contains(event.target as Node)) menu.remove()
      document.removeEventListener('mousedown', dismiss)
    }
    window.setTimeout(() => document.addEventListener('mousedown', dismiss), 0)
  }

  /** Expand or collapse a directory row, loading children on demand. */
  private async toggleDir(
    entry: DirEntry,
    li: HTMLElement,
    twisty: HTMLElement,
    depth: number
  ): Promise<void> {
    const existing = li.querySelector(':scope > ul.tree-list')
    if (existing) {
      existing.remove()
      twisty.textContent = '▸'
      this.expanded.delete(entry.path)
      return
    }

    try {
      const children = await window.editor.readDir(entry.path)
      li.appendChild(this.buildList(children, depth + 1))
      twisty.textContent = '▾'
      this.expanded.add(entry.path)
    } catch (error) {
      this.handlers.onError(`Could not read “${entry.name}”.`, error)
    }
  }
}
