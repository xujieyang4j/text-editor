import type { GitAction, GitDiff, GitHistoryEntry, GitHunk, GitStatus, UiLocale } from '../../shared/ipc.js'
import { translate } from '../../shared/i18n.js'

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
  private static nextPanelId = 0
  private readonly root: HTMLDivElement
  private readonly list: HTMLUListElement
  private readonly diff: HTMLPreElement
  private readonly hunkPicker: HTMLSelectElement
  private readonly heading: HTMLDivElement
  private readonly actionButtons = new Map<string, HTMLButtonElement>()
  private selectedHunk: GitHunk | null = null
  private activePath: string | null = null
  private visible = false
  private previouslyFocused: HTMLElement | null = null
  private selected = new Set<string>()
  private locale: UiLocale = 'zh-CN'

  constructor(private readonly callbacks: GitPanelCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'git-panel hidden'
    this.root.setAttribute('role', 'region')
    this.root.setAttribute('aria-hidden', 'true')
    this.heading = document.createElement('div')
    this.heading.className = 'git-panel-heading'
    this.heading.id = `git-panel-title-${++GitPanel.nextPanelId}`
    this.heading.setAttribute('role', 'heading')
    this.heading.setAttribute('aria-level', '2')
    this.root.setAttribute('aria-labelledby', this.heading.id)
    this.heading.textContent = translate(this.locale, 'gitChanges')
    this.list = document.createElement('ul')
    this.list.className = 'git-change-list'
    this.list.setAttribute('role', 'listbox')
    this.list.setAttribute('aria-label', 'Git 更改文件')
    this.list.setAttribute('aria-multiselectable', 'true')
    this.list.addEventListener('keydown', (event) => this.navigateList(event))
    this.diff = document.createElement('pre')
    this.diff.className = 'git-diff-preview'
    this.diff.tabIndex = 0
    this.diff.setAttribute('aria-label', 'Git 差异预览')
    this.hunkPicker = document.createElement('select')
    this.hunkPicker.className = 'git-hunk-picker'
    this.hunkPicker.setAttribute('aria-label', '选择差异区块')
    this.hunkPicker.disabled = true
    this.hunkPicker.addEventListener('change', () => {
      const index = Number(this.hunkPicker.value)
      this.selectedHunk = Number.isInteger(index) ? (this.hunks[index] ?? null) : null
      if (this.selectedHunk) this.diff.textContent = this.selectedHunk.patch || 'No textual diff is available.'
    })
    const actions = document.createElement('div')
    actions.className = 'git-actions'
    const add = (key: string, label: string, action: () => void): void => {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = 'panel-button'
      button.textContent = label
      button.addEventListener('click', action)
      actions.appendChild(button)
      this.actionButtons.set(key, button)
    }
    add('stage', translate(this.locale, 'stage'), () => this.callbacks.onAction('stage', [...this.selected]))
    add('unstage', translate(this.locale, 'unstage'), () => this.callbacks.onAction('unstage', [...this.selected]))
    add('discard', translate(this.locale, 'discard'), () => this.callbacks.onAction('discard', [...this.selected]))
    add('stageHunk', `${translate(this.locale, 'stage')} Hunk`, () => { if (this.selectedHunk) this.callbacks.onHunkAction('stage-hunk', this.selectedHunk) })
    add('discardHunk', `${translate(this.locale, 'discard')} Hunk`, () => { if (this.selectedHunk) this.callbacks.onHunkAction('discard-hunk', this.selectedHunk) })
    add('history', translate(this.locale, 'history'), () => { if (this.activePath) void this.showHistory(this.activePath) })
    add('blame', translate(this.locale, 'blame'), () => { if (this.activePath) void this.showBlame(this.activePath) })
    add('commit', translate(this.locale, 'commit'), this.callbacks.onCommit)
    add('switch', 'Switch', () => this.callbacks.onBranch(false))
    add('branch', 'New Branch', () => this.callbacks.onBranch(true))
    this.root.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.toggle(false)
    })
    this.root.append(this.heading, actions, this.list, this.hunkPicker, this.diff)
  }

  get element(): HTMLElement { return this.root }
  toggle(show = !this.visible): void {
    if (show === this.visible) return
    const focusWasWithinPanel = this.root.contains(document.activeElement)
    if (show) {
      this.previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null
    }
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    this.root.setAttribute('aria-hidden', String(!show))
    if (!show) {
      const focusTarget = this.previouslyFocused
      this.previouslyFocused = null
      if (focusWasWithinPanel) this.restoreFocus(focusTarget)
    }
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.heading.textContent = translate(locale, 'gitChanges')
    this.list.setAttribute('aria-label', locale === 'zh-CN' ? 'Git 更改文件' : 'Git changed files')
    this.diff.setAttribute('aria-label', locale === 'zh-CN' ? 'Git 差异预览' : 'Git diff preview')
    this.hunkPicker.setAttribute('aria-label', locale === 'zh-CN' ? '选择差异区块' : 'Select diff hunk')
    const labels: Record<string, string> = {
      stage: translate(locale, 'stage'), unstage: translate(locale, 'unstage'), discard: translate(locale, 'discard'),
      stageHunk: `${translate(locale, 'stage')} Hunk`, discardHunk: `${translate(locale, 'discard')} Hunk`,
      history: translate(locale, 'history'), blame: translate(locale, 'blame'), commit: translate(locale, 'commit'),
      switch: locale === 'zh-CN' ? '切换分支' : 'Switch', branch: locale === 'zh-CN' ? '新建分支' : 'New Branch'
    }
    for (const [key, label] of Object.entries(labels)) this.actionButtons.get(key)!.textContent = label
  }

  setStatus(status: GitStatus): void {
    this.list.replaceChildren()
    this.selected.clear()
    this.diff.textContent = ''
    this.hunks = []
    this.selectedHunk = null
    this.hunkPicker.replaceChildren()
    this.hunkPicker.disabled = true
    if (!status.available) {
      this.heading.textContent = this.locale === 'zh-CN' ? 'Git 更改 — 非 Git 仓库' : 'Git Changes — no repository'
      return
    }
    this.heading.textContent = `${translate(this.locale, 'gitChanges')} — ${status.branch ?? ''}`
    status.entries.forEach((entry, index) => {
      const item = document.createElement('li')
      item.className = 'git-change-item'
      item.tabIndex = index === 0 ? 0 : -1
      item.setAttribute('role', 'option')
      item.setAttribute('aria-selected', 'false')
      item.textContent = `${entry.indexStatus}${entry.worktreeStatus}  ${entry.path}`
      const activate = (withModifier: boolean): void => {
        this.activePath = entry.path
        if (withModifier) {
          if (this.selected.has(entry.path)) this.selected.delete(entry.path)
          else this.selected.add(entry.path)
          item.classList.toggle('selected', this.selected.has(entry.path))
          item.setAttribute('aria-selected', String(this.selected.has(entry.path)))
        } else this.callbacks.onOpenFile(entry.path)
      }
      item.addEventListener('click', (event) => {
        activate(event.ctrlKey || event.metaKey)
      })
      item.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        event.stopPropagation()
        activate(event.key === ' ' || event.ctrlKey || event.metaKey)
      })
      item.addEventListener('dblclick', () => { void this.showDiff(entry.path) })
      this.list.appendChild(item)
    })
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

  private navigateList(event: KeyboardEvent): void {
    const items = Array.from(this.list.querySelectorAll<HTMLElement>('[role="option"]'))
    const current = items.indexOf(document.activeElement as HTMLElement)
    if (current < 0 || items.length === 0) return
    let next = current
    if (event.key === 'ArrowDown') next = Math.min(items.length - 1, current + 1)
    else if (event.key === 'ArrowUp') next = Math.max(0, current - 1)
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = items.length - 1
    else return
    event.preventDefault()
    event.stopPropagation()
    items.forEach((item, index) => { item.tabIndex = index === next ? 0 : -1 })
    items[next].focus()
  }

  private restoreFocus(preferred: HTMLElement | null): void {
    const candidates = [
      preferred,
      ...document.querySelectorAll<HTMLElement>('.cm-content, [contenteditable="true"], button, input, select, textarea, [tabindex]:not([tabindex="-1"])')
    ]
    const target = candidates.find((candidate): candidate is HTMLElement =>
      candidate instanceof HTMLElement && candidate.isConnected && !this.root.contains(candidate) &&
      !candidate.matches(':disabled') && !candidate.closest('.hidden, [hidden], [aria-hidden="true"], [inert]'))
    target?.focus()
  }

  private hunks: GitHunk[] = []
}
