import type { DirEntry, UiLocale } from '../../shared/ipc.js'

/** Callback fired when a file (not a folder) is activated in the tree. */
type FileOpenHandler = (path: string) => void

export interface FileTreeHandlers {
  onOpenFile: FileOpenHandler
  onCreate: (parent: string, isDirectory: boolean) => void
  onRename: (path: string) => void
  onMove: (path: string) => void
  onDelete: (path: string) => void
  onReveal: (path: string) => void
  onError: (message: string, error: unknown) => void
  isExcluded?: (path: string, isDirectory: boolean) => boolean
}

export interface TreeEntry extends DirEntry {
  children?: DirEntry[]
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

  private rootEntries: TreeEntry[] = []
  /** Invalidates async expansion restores when the workspace changes. */
  private renderVersion = 0
  private locale: UiLocale = 'zh-CN'

  constructor(container: HTMLElement, handlers: FileTreeHandlers) {
    this.container = container
    this.handlers = handlers
  }

  /**
   * Render workspace entries. A true `preserveExpansion` keeps the user's
   * expanded folders open across watcher/poll refreshes.
   */
  render(entries: TreeEntry[], preserveExpansion = false): void {
    const version = ++this.renderVersion
    if (!preserveExpansion) this.expanded.clear()
    this.rootEntries = entries
    const rootList = this.buildList(entries, 0)
    this.container.replaceChildren(rootList)
    if (preserveExpansion) void this.restoreExpanded(entries, rootList, 0, version)
  }

  /** Clear the tree (no workspace open). */
  clear(): void {
    this.renderVersion += 1
    this.expanded.clear()
    this.rootEntries = []
    this.container.replaceChildren()
  }

  /** Re-render existing entries while preserving expansion, for callers without new data. */
  refresh(): void {
    if (this.rootEntries.length > 0) this.render(this.rootEntries, true)
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
  }

  /** Build a <ul> for a set of sibling entries at the given depth. */
  private buildList(entries: TreeEntry[], depth: number): HTMLElement {
    const ul = document.createElement('ul')
    ul.className = 'tree-list'
    for (const entry of entries) {
      if (this.handlers.isExcluded?.(entry.path, entry.isDirectory)) continue
      ul.appendChild(this.buildItem(entry, depth))
    }
    return ul
  }

  /** Build a single <li> row plus (for expanded dirs) its child list. */
  private buildItem(entry: TreeEntry, depth: number): HTMLElement {
    const li = document.createElement('li')
    li.className = 'tree-item'
    li.dataset.treePath = entry.path

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

  /** Re-expand known folders after a root refresh, without blocking the tree UI. */
  private async restoreExpanded(
    entries: DirEntry[],
    parent: HTMLElement,
    depth: number,
    version: number
  ): Promise<void> {
    for (const entry of entries) {
      if (!entry.isDirectory || !this.expanded.has(entry.path) || version !== this.renderVersion) continue
      const li = Array.from(parent.children).find(
        (element) => element instanceof HTMLElement && element.dataset.treePath === entry.path
      )
      if (!(li instanceof HTMLElement)) continue
      const twisty = li.querySelector<HTMLElement>(':scope > .tree-row > .tree-twisty')
      if (!twisty) continue
      try {
        const children = (await window.editor.readDir(entry.path)).filter((child) => !this.handlers.isExcluded?.(child.path, child.isDirectory))
        if (version !== this.renderVersion) return
        const childList = this.buildList(children, depth + 1)
        li.appendChild(childList)
        twisty.textContent = '▾'
        await this.restoreExpanded(children, childList, depth + 1, version)
      } catch (error) {
        if (version === this.renderVersion) this.handlers.onError(`Could not read “${entry.name}”.`, error)
      }
    }
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
      action(this.locale === 'zh-CN' ? '新建文件…' : 'New File…', () => this.handlers.onCreate(entry.path, false))
      action(this.locale === 'zh-CN' ? '新建文件夹…' : 'New Folder…', () => this.handlers.onCreate(entry.path, true))
    }
    action(this.locale === 'zh-CN' ? '重命名…' : 'Rename…', () => this.handlers.onRename(entry.path))
    action(this.locale === 'zh-CN' ? '移动到…' : 'Move To…', () => this.handlers.onMove(entry.path))
    action(this.locale === 'zh-CN' ? '移到废纸篓' : 'Move to Trash', () => this.handlers.onDelete(entry.path))
    action(this.locale === 'zh-CN' ? '在文件管理器中显示' : 'Reveal in Folder', () => this.handlers.onReveal(entry.path))
    document.body.appendChild(menu)

    const dismiss = (event: MouseEvent): void => {
      if (!menu.contains(event.target as Node)) menu.remove()
      document.removeEventListener('mousedown', dismiss)
    }
    window.setTimeout(() => document.addEventListener('mousedown', dismiss), 0)
  }

  /** Expand or collapse a directory row, loading children on demand. */
  private async toggleDir(
    entry: TreeEntry,
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
      const children = (entry.children ?? await window.editor.readDir(entry.path)).filter((child) => !this.handlers.isExcluded?.(child.path, child.isDirectory))
      entry.children = children
      li.appendChild(this.buildList(children, depth + 1))
      twisty.textContent = '▾'
      this.expanded.add(entry.path)
    } catch (error) {
      this.handlers.onError(`Could not read “${entry.name}”.`, error)
    }
  }
}
