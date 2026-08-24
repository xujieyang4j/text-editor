import type { GitAction, GitDiff, GitStatus } from '../../shared/ipc.js'

export interface GitPanelCallbacks {
  onOpenFile: (relativePath: string) => void
  onDiff: (relativePath: string) => Promise<GitDiff>
  onAction: (action: GitAction, paths?: string[]) => void
  onCommit: () => void
  onBranch: (create: boolean) => void
}

/** Read-only Git changes sidebar with per-file diff preview. */
export class GitPanel {
  private readonly root: HTMLDivElement
  private readonly list: HTMLUListElement
  private readonly diff: HTMLPreElement
  private visible = false
  private selected = new Set<string>()

  constructor(private readonly callbacks: GitPanelCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'git-panel hidden'
    const heading = document.createElement('div')
    heading.className = 'git-panel-heading'
    heading.textContent = 'Git Changes'
    this.list = document.createElement('ul')
    this.list.className = 'git-change-list'
    this.diff = document.createElement('pre')
    this.diff.className = 'git-diff-preview'
    const actions = document.createElement('div')
    actions.className = 'git-actions'
    const add = (label: string, action: () => void): void => {
      const button = document.createElement('button')
      button.className = 'panel-button'
      button.textContent = label
      button.addEventListener('click', action)
      actions.appendChild(button)
    }
    add('Stage', () => this.callbacks.onAction('stage', [...this.selected]))
    add('Unstage', () => this.callbacks.onAction('unstage', [...this.selected]))
    add('Discard', () => this.callbacks.onAction('discard', [...this.selected]))
    add('Commit', this.callbacks.onCommit)
    add('Switch', () => this.callbacks.onBranch(false))
    add('New Branch', () => this.callbacks.onBranch(true))
    this.root.append(heading, actions, this.list, this.diff)
  }

  get element(): HTMLElement { return this.root }
  toggle(show = !this.visible): void {
    this.visible = show
    this.root.classList.toggle('hidden', !show)
  }

  setStatus(status: GitStatus): void {
    this.list.replaceChildren()
    this.selected.clear()
    this.diff.textContent = ''
    const heading = this.root.querySelector<HTMLElement>('.git-panel-heading')
    if (!status.available) {
      if (heading) heading.textContent = 'Git Changes — no repository'
      return
    }
    if (heading) heading.textContent = `Git Changes — ${status.branch ?? ''}`
    for (const entry of status.entries) {
      const item = document.createElement('li')
      item.className = 'git-change-item'
      item.textContent = `${entry.indexStatus}${entry.worktreeStatus}  ${entry.path}`
      item.addEventListener('click', (event) => {
        if (event.ctrlKey || event.metaKey) {
          if (this.selected.has(entry.path)) this.selected.delete(entry.path)
          else this.selected.add(entry.path)
          item.classList.toggle('selected', this.selected.has(entry.path))
        } else this.callbacks.onOpenFile(entry.path)
      })
      item.addEventListener('dblclick', () => { void this.showDiff(entry.path) })
      this.list.appendChild(item)
    }
  }

  private async showDiff(relativePath: string): Promise<void> {
    try {
      const result = await this.callbacks.onDiff(relativePath)
      this.diff.textContent = result.diff || 'No textual diff is available.'
    } catch (error) {
      this.diff.textContent = error instanceof Error ? error.message : 'Could not load diff.'
    }
  }
}
