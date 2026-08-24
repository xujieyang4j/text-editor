import type { GitAction, GitDiff, GitHistoryEntry, GitHunk, GitStatus } from '../../shared/ipc.js'

export interface GitPanelCallbacks {
  onOpenFile: (relativePath: string) => void
  onDiff: (relativePath: string) => Promise<GitDiff>
  onHunks: (relativePath: string) => Promise<GitHunk[]>
  onHistory: (relativePath: string) => Promise<GitHistoryEntry[]>
  onBlame: (relativePath: string) => Promise<string>
  onAction: (action: GitAction, paths?: string[]) => void
  onHunkAction: (action: 'stage-hunk' | 'discard-hunk', hunk: GitHunk) => void
  onCommit: () => void
  onBranch: (create: boolean) => void
}

/** Read-only Git changes sidebar with per-file diff preview. */
export class GitPanel {
  private readonly root: HTMLDivElement
  private readonly list: HTMLUListElement
  private readonly diff: HTMLPreElement
  private readonly hunkPicker: HTMLSelectElement
  private selectedHunk: GitHunk | null = null
  private activePath: string | null = null
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
    this.hunkPicker = document.createElement('select')
    this.hunkPicker.className = 'git-hunk-picker'
    this.hunkPicker.disabled = true
    this.hunkPicker.addEventListener('change', () => {
      const index = Number(this.hunkPicker.value)
      this.selectedHunk = Number.isInteger(index) ? (this.hunks[index] ?? null) : null
      if (this.selectedHunk) this.diff.textContent = this.selectedHunk.patch || 'No textual diff is available.'
    })
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
    add('Stage Hunk', () => { if (this.selectedHunk) this.callbacks.onHunkAction('stage-hunk', this.selectedHunk) })
    add('Discard Hunk', () => { if (this.selectedHunk) this.callbacks.onHunkAction('discard-hunk', this.selectedHunk) })
    add('History', () => { if (this.activePath) void this.showHistory(this.activePath) })
    add('Blame', () => { if (this.activePath) void this.showBlame(this.activePath) })
    add('Commit', this.callbacks.onCommit)
    add('Switch', () => this.callbacks.onBranch(false))
    add('New Branch', () => this.callbacks.onBranch(true))
    this.root.append(heading, actions, this.list, this.hunkPicker, this.diff)
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
    this.hunks = []
    this.selectedHunk = null
    this.hunkPicker.replaceChildren()
    this.hunkPicker.disabled = true
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
      this.activePath = relativePath
      const result = await this.callbacks.onDiff(relativePath)
      this.diff.textContent = result.diff || 'No textual diff is available.'
      this.hunks = await this.callbacks.onHunks(relativePath)
      this.hunkPicker.replaceChildren()
      if (this.hunks.length === 0) {
        this.hunkPicker.disabled = true
        return
      }
      this.hunks.forEach((hunk, index) => {
        const option = document.createElement('option')
        option.value = String(index)
        option.textContent = `Hunk ${index + 1}: ${hunk.header}`
        this.hunkPicker.appendChild(option)
      })
      this.hunkPicker.disabled = false
      this.hunkPicker.value = '0'
      this.selectedHunk = this.hunks[0]
    } catch (error) {
      this.diff.textContent = error instanceof Error ? error.message : 'Could not load diff.'
      this.hunks = []
      this.selectedHunk = null
      this.hunkPicker.disabled = true
    }
  }

  private async showHistory(relativePath: string): Promise<void> {
    try {
      const entries = await this.callbacks.onHistory(relativePath)
      this.diff.textContent = entries.length > 0
        ? entries.map((entry) => `${entry.shortId}  ${entry.date}  ${entry.author}  ${entry.subject}`).join('\n')
        : 'No committed history for this file.'
    } catch (error) {
      this.diff.textContent = error instanceof Error ? error.message : 'Could not load Git history.'
    }
  }

  private async showBlame(relativePath: string): Promise<void> {
    try {
      this.diff.textContent = (await this.callbacks.onBlame(relativePath)) || 'No blame data is available.'
    } catch (error) {
      this.diff.textContent = error instanceof Error ? error.message : 'Could not load Git blame.'
    }
  }

  private hunks: GitHunk[] = []
}
