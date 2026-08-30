import type { DirEntry, UiLocale } from '../../shared/ipc.js'

/** Callback fired when a file (not a folder) is activated in the tree. */
type FileOpenHandler = (path: string) => void

interface AsyncTreeToken {
  renderVersion: number
  revealGeneration?: number
  activePathVersion: number
}

export interface FileTreeHandlers {
  onOpenFile: FileOpenHandler
  onCreate: (parent: string, isDirectory: boolean) => void
  onRename: (path: string) => void
  onMove: (path: string) => void
  onDelete: (path: string) => void
  onReveal: (path: string) => void
  onCopyPath: (path: string, relative: boolean) => void
  onError: (message: string, error: unknown) => void
  isExcluded?: (path: string, isDirectory: boolean) => boolean
}

export interface TreeEntry extends DirEntry {
  children?: TreeEntry[]
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
  /** Invalidates stale async reveals when a newer reveal overtakes an older one. */
  private revealGeneration = 0
  /** Persistent current tree path, restored across rerenders when still present. */
  private activePath: string | null = null
  /** Prevents stale reveals from overwriting a newer explicit active-path update. */
  private activePathVersion = 0
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
    this.revealGeneration += 1
    this.expanded.clear()
    this.rootEntries = []
    this.activePath = null
    this.activePathVersion += 1
    this.container.replaceChildren()
  }

  /** Re-render existing entries while preserving expansion, for callers without new data. */
  refresh(): void {
    if (this.rootEntries.length > 0) this.render(this.rootEntries, true)
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
  }

  /** Persist the active/current row without expanding or scrolling the tree. */
  setActivePath(path: string | null): void {
    this.revealGeneration += 1
    this.applyActivePath(path, true)
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
    row.dataset.treePath = entry.path
    row.style.paddingLeft = `${depth * 14 + 8}px`
    if (this.isSamePath(entry.path, this.activePath)) row.setAttribute('aria-current', 'location')

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
    entries: TreeEntry[],
    parent: HTMLElement,
    depth: number,
    version: number
  ): Promise<void> {
    for (const entry of entries) {
      if (!entry.isDirectory || !this.expanded.has(entry.path) || version !== this.renderVersion) continue
      const li = this.findDirectRenderedItem(parent, entry.path)
      if (!(li instanceof HTMLElement)) continue
      const childList = await this.ensureDirectoryExpanded(entry, li, depth, {
        renderVersion: version,
        activePathVersion: this.activePathVersion
      })
      if (!childList || version !== this.renderVersion) return
      await this.restoreExpanded(entry.children ?? [], childList, depth + 1, version)
    }
  }

  /**
   * Reveal a path in the current tree without opening or focusing it.
   * Returns true when the path is rendered and highlighted in the tree.
   */
  async revealPath(targetPath: string, workspaceRoot: string): Promise<boolean> {
    const token = this.beginReveal()
    const rootList = this.rootList()
    if (!rootList || !this.containsPath(workspaceRoot, targetPath)) return false

    const renderedRoot = this.findEntryByPath(this.rootEntries, workspaceRoot)
    const multiRoot = !!renderedRoot && renderedRoot.isDirectory

    if (multiRoot) {
      const rootItem = this.findDirectRenderedItem(rootList, renderedRoot.path)
      if (!rootItem) return false
      if (this.isSamePath(targetPath, renderedRoot.path)) {
        if (!this.canCommitReveal(token)) return false
        this.applyActivePath(renderedRoot.path, false)
        this.scrollRowIntoView(rootItem)
        return true
      }

      const childList = await this.ensureDirectoryExpanded(renderedRoot, rootItem, 0, token)
      if (!childList || !this.isTokenCurrent(token)) return false
      return this.revealWithinEntries(targetPath, workspaceRoot, renderedRoot, childList, 0, token)
    }

    if (this.isSamePath(targetPath, workspaceRoot)) return false
    return this.revealWithinEntries(targetPath, workspaceRoot, undefined, rootList, -1, token)
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
    action(this.locale === 'zh-CN' ? '复制路径' : 'Copy Path', () => this.handlers.onCopyPath(entry.path, false))
    action(this.locale === 'zh-CN' ? '复制相对路径' : 'Copy Relative Path', () => this.handlers.onCopyPath(entry.path, true))
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

    const version = this.renderVersion
    const childList = await this.ensureDirectoryExpanded(entry, li, depth, {
      renderVersion: version,
      activePathVersion: this.activePathVersion
    })
    if (!childList || version !== this.renderVersion) return
    const currentRow = this.findCurrentRow()
    if (currentRow && !currentRow.isConnected && this.activePath) this.syncActivePathToVisibleRow(this.activePath)
  }

  private beginReveal(): AsyncTreeToken {
    return {
      renderVersion: this.renderVersion,
      revealGeneration: ++this.revealGeneration,
      activePathVersion: this.activePathVersion
    }
  }

  private isTokenCurrent(token: AsyncTreeToken): boolean {
    return token.renderVersion === this.renderVersion &&
      (token.revealGeneration === undefined || token.revealGeneration === this.revealGeneration)
  }

  private normalizePath(path: string): string {
    const withForwardSlashes = path.replaceAll('\\', '/')
    const prefix = withForwardSlashes.startsWith('//')
      ? '//'
      : withForwardSlashes.startsWith('/')
        ? '/'
        : ''
    const body = prefix ? withForwardSlashes.slice(prefix.length) : withForwardSlashes
    let normalized = `${prefix}${body.replace(/\/+/g, '/')}`
    if (normalized.length > prefix.length && normalized.endsWith('/')) normalized = normalized.replace(/\/+$/, '')
    if (/^[A-Za-z]:$/.test(normalized)) normalized = `${normalized}/`
    const resolved = normalized || '/'
    return /^[A-Za-z]:/.test(resolved) || resolved.startsWith('//') ? resolved.toLowerCase() : resolved
  }

  private isSamePath(left: string | null | undefined, right: string | null | undefined): boolean {
    return !!left && !!right && this.normalizePath(left) === this.normalizePath(right)
  }

  private containsPath(root: string, path: string): boolean {
    const normalizedRoot = this.normalizePath(root)
    const normalizedPath = this.normalizePath(path)
    if (normalizedRoot === normalizedPath) return true
    const boundary = normalizedRoot.endsWith('/') ? normalizedRoot : `${normalizedRoot}/`
    return normalizedPath.startsWith(boundary)
  }

  private descendantPaths(root: string, targetPath: string): string[] {
    const normalizedRoot = this.normalizePath(root)
    const normalizedTarget = this.normalizePath(targetPath)
    if (normalizedRoot === normalizedTarget) return []
    const relative = normalizedTarget.slice(normalizedRoot.length).replace(/^\/+/, '')
    if (!relative) return []
    const parts = relative.split('/').filter(Boolean)
    const paths: string[] = []
    let current = normalizedRoot
    for (const part of parts) {
      current = current === '/' || current.endsWith('/') ? `${current}${part}` : `${current}/${part}`
      paths.push(current)
    }
    return paths
  }

  private findEntryByPath(entries: TreeEntry[], path: string): TreeEntry | undefined {
    return entries.find((entry) => this.isSamePath(entry.path, path))
  }

  private rootList(): HTMLElement | null {
    const list = this.container.firstElementChild
    return list instanceof HTMLElement ? list : null
  }

  private findDirectRenderedItem(parent: Element, path: string): HTMLElement | null {
    for (const child of parent.children) {
      if (child instanceof HTMLElement && this.isSamePath(child.dataset.treePath, path)) return child
    }
    return null
  }

  private directChildList(item: HTMLElement): HTMLElement | null {
    for (const child of item.children) {
      if (child instanceof HTMLElement && child.classList.contains('tree-list')) return child
    }
    return null
  }

  private directRow(item: HTMLElement): HTMLElement | null {
    for (const child of item.children) {
      if (child instanceof HTMLElement && child.classList.contains('tree-row')) return child
    }
    return null
  }

  private directTwisty(item: HTMLElement): HTMLElement | null {
    const row = this.directRow(item)
    if (!row) return null
    for (const child of row.children) {
      if (child instanceof HTMLElement && child.classList.contains('tree-twisty')) return child
    }
    return null
  }

  private findCurrentRow(): HTMLElement | null {
    return this.container.querySelector<HTMLElement>('.tree-row[aria-current="location"]')
  }

  private findRenderedRow(path: string): HTMLElement | null {
    const item = this.container.querySelectorAll<HTMLElement>('[data-tree-path]')
    for (const candidate of item) {
      if (!candidate.classList.contains('tree-row') && !candidate.classList.contains('tree-item')) continue
      if (candidate.classList.contains('tree-row') && this.isSamePath(candidate.dataset.treePath, path)) return candidate
      if (candidate.classList.contains('tree-item') && this.isSamePath(candidate.dataset.treePath, path)) {
        return this.directRow(candidate)
      }
    }
    return null
  }

  private applyActivePath(path: string | null, explicit: boolean): void {
    const current = this.findCurrentRow()
    if (current) current.removeAttribute('aria-current')
    this.activePath = path
    if (explicit) this.activePathVersion += 1
    if (!path) return
    this.syncActivePathToVisibleRow(path)
  }

  private syncActivePathToVisibleRow(path: string): void {
    const row = this.findRenderedRow(path)
    if (row) row.setAttribute('aria-current', 'location')
  }

  private canCommitReveal(token: AsyncTreeToken): boolean {
    return this.isTokenCurrent(token) && token.activePathVersion === this.activePathVersion
  }

  private scrollRowIntoView(item: HTMLElement): void {
    this.directRow(item)?.scrollIntoView({ block: 'nearest' })
  }

  private async loadDirectoryChildren(entry: TreeEntry, refresh = false): Promise<TreeEntry[]> {
    if (!refresh && entry.children) return entry.children
    const children = (await window.editor.readDir(entry.path))
      .filter((child) => !this.handlers.isExcluded?.(child.path, child.isDirectory))
      .map((child) => ({ ...child }))
    entry.children = children
    return children
  }

  private renderDirectoryChildren(
    entry: TreeEntry,
    item: HTMLElement,
    twisty: HTMLElement,
    depth: number,
    children: TreeEntry[]
  ): HTMLElement {
    const nextList = this.buildList(children, depth + 1)
    const existing = this.directChildList(item)
    if (existing) existing.replaceWith(nextList)
    else item.appendChild(nextList)
    twisty.textContent = '▾'
    this.expanded.add(entry.path)
    return nextList
  }

  private async ensureDirectoryExpanded(
    entry: TreeEntry,
    item: HTMLElement,
    depth: number,
    token: AsyncTreeToken,
    refresh = false
  ): Promise<HTMLElement | null> {
    const twisty = this.directTwisty(item)
    if (!twisty) return null
    const existing = this.directChildList(item)
    if (existing && !refresh) {
      twisty.textContent = '▾'
      this.expanded.add(entry.path)
      return existing
    }
    try {
      const children = await this.loadDirectoryChildren(entry, refresh)
      if (!this.isTokenCurrent(token)) return null
      return this.renderDirectoryChildren(entry, item, twisty, depth, children)
    } catch (error) {
      if (this.isTokenCurrent(token)) this.handlers.onError(`Could not read “${entry.name}”.`, error)
      return null
    }
  }

  private async revealWithinEntries(
    targetPath: string,
    workspaceRoot: string,
    parentEntry: TreeEntry | undefined,
    parentList: HTMLElement,
    parentDepth: number,
    token: AsyncTreeToken
  ): Promise<boolean> {
    let entries = parentEntry?.children ?? this.rootEntries
    let list = parentList
    let directory = parentEntry
    let directoryItem = parentEntry ? this.findDirectRenderedItem(this.rootList() ?? parentList, parentEntry.path) : null
    let depth = parentDepth

    for (const descendantPath of this.descendantPaths(workspaceRoot, targetPath)) {
      if (!this.isTokenCurrent(token)) return false
      let entry = this.findEntryByPath(entries, descendantPath)
      if (!entry && directory && directoryItem) {
        const refreshedList = await this.ensureDirectoryExpanded(directory, directoryItem, depth, token, true)
        if (!refreshedList || !this.isTokenCurrent(token)) return false
        list = refreshedList
        entries = directory.children ?? []
        entry = this.findEntryByPath(entries, descendantPath)
      }
      if (!entry) return false
      const item = this.findDirectRenderedItem(list, entry.path)
      if (!item) return false

      const isTarget = this.isSamePath(entry.path, targetPath)
      if (isTarget) {
        if (!this.canCommitReveal(token)) return false
        this.applyActivePath(entry.path, false)
        this.scrollRowIntoView(item)
        return true
      }
      if (!entry.isDirectory) return false

      const childDepth = depth + 1
      const childList = await this.ensureDirectoryExpanded(entry, item, childDepth, token)
      if (!childList || !this.isTokenCurrent(token)) return false
      directory = entry
      directoryItem = item
      list = childList
      entries = entry.children ?? []
      depth = childDepth
    }

    return false
  }
}
