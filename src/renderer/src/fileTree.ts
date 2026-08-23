import type { DirEntry } from '../../shared/ipc.js'

/** Callback fired when a file (not a folder) is activated in the tree. */
type FileOpenHandler = (path: string) => void

/**
 * Lazy, collapsible file tree rendered from the opened workspace folder.
 * Directory children are fetched on first expand via the preload API.
 */
export class FileTree {
  private container: HTMLElement
  private onOpenFile: FileOpenHandler
  /** Tracks which directory paths are currently expanded. */
  private expanded = new Set<string>()

  constructor(container: HTMLElement, onOpenFile: FileOpenHandler) {
    this.container = container
    this.onOpenFile = onOpenFile
  }

  /** Render a fresh workspace root and reset expansion state. */
  render(entries: DirEntry[]): void {
    this.expanded.clear()
    this.container.replaceChildren(this.buildList(entries, 0))
  }

  /** Clear the tree (no workspace open). */
  clear(): void {
    this.container.replaceChildren()
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
      row.addEventListener('click', () => this.onOpenFile(entry.path))
    }

    return li
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

    const children = await window.editor.readDir(entry.path)
    li.appendChild(this.buildList(children, depth + 1))
    twisty.textContent = '▾'
    this.expanded.add(entry.path)
  }
}
