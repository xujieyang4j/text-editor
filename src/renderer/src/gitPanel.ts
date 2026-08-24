import type { GitDiff, GitStatus } from '../../shared/ipc.js'

export interface GitPanelCallbacks {
  onOpenFile: (relativePath: string) => void
  onDiff: (relativePath: string) => Promise<GitDiff>
}

/** Read-only Git changes sidebar with per-file diff preview. */
export class GitPanel {
  private readonly root: HTMLDivElement
  private readonly list: HTMLUListElement
  private readonly diff: HTMLPreElement
  private visible = false

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
    this.root.append(heading, this.list, this.diff)
  }

  get element(): HTMLElement { return this.root }
  toggle(show = !this.visible): void {
    this.visible = show
    this.root.classList.toggle('hidden', !show)
  }

  setStatus(status: GitStatus): void {
    this.list.replaceChildren()
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
      item.addEventListener('click', () => this.callbacks.onOpenFile(entry.path))
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
