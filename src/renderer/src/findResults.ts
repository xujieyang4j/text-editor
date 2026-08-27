import type { WorkspaceMatch, UiLocale } from '../../shared/ipc.js'
import { translate } from '../../shared/i18n.js'
import { baseName } from './documents.js'

export interface FindResultsCallbacks {
  onOpenMatch: (match: WorkspaceMatch) => void
}

/**
 * A persistent, Sublime-style Find Results buffer. It intentionally lives in
 * its own readonly tab so search output survives closing the search overlay.
 */
export class FindResultsView {
  readonly root: HTMLDivElement
  private readonly title: HTMLDivElement
  private readonly titleLabel: HTMLSpanElement
  private readonly titleDetail: HTMLSpanElement
  private readonly summary: HTMLDivElement
  private readonly list: HTMLUListElement
  private matches: WorkspaceMatch[] = []
  private activeIndex = -1
  private locale: UiLocale = 'zh-CN'
  private query = ''
  private previouslyFocused: HTMLElement | null = null

  constructor(private readonly callbacks: FindResultsCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'find-results-view hidden'
    this.root.tabIndex = -1
    this.root.setAttribute('role', 'region')
    this.root.setAttribute('aria-hidden', 'true')
    this.title = document.createElement('div')
    this.title.id = 'lumen-find-results-title'
    this.title.className = 'find-results-header'
    this.title.setAttribute('role', 'heading')
    this.title.setAttribute('aria-level', '2')
    this.titleLabel = document.createElement('span')
    this.titleLabel.textContent = translate(this.locale, 'findResults')
    this.titleDetail = document.createElement('span')
    this.titleDetail.setAttribute('aria-hidden', 'true')
    this.title.append(this.titleLabel, this.titleDetail)
    this.root.setAttribute('aria-labelledby', this.title.id)
    this.summary = document.createElement('div')
    this.summary.className = 'find-results-summary visually-hidden'
    this.summary.setAttribute('role', 'status')
    this.summary.setAttribute('aria-atomic', 'true')
    this.list = document.createElement('ul')
    this.list.className = 'find-results-list'
    this.root.append(this.title, this.summary, this.list)
    this.root.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.hide()
    })
  }

  get element(): HTMLElement { return this.root }

  setResults(query: string, matches: WorkspaceMatch[]): void {
    this.query = query
    this.matches = matches
    this.activeIndex = matches.length > 0 ? 0 : -1
    this.updateHeader()
    this.render()
  }

  show(focus = true): void {
    if (this.root.classList.contains('hidden')) {
      const active = document.activeElement
      this.previouslyFocused = active instanceof HTMLElement && !this.root.contains(active) ? active : null
    }
    this.root.classList.remove('hidden')
    this.root.setAttribute('aria-hidden', 'false')
    this.editorHost()?.classList.add('hidden')
    if (focus) this.focusActiveResult()
  }

  hide(): void {
    const shouldRestoreFocus = this.root.contains(document.activeElement)
    const previouslyFocused = this.previouslyFocused
    this.previouslyFocused = null
    const editorHost = this.editorHost()
    editorHost?.classList.remove('hidden')
    this.root.classList.add('hidden')
    this.root.setAttribute('aria-hidden', 'true')
    if (!shouldRestoreFocus) return
    const target = this.isVisibleFocusTarget(previouslyFocused)
      ? previouslyFocused
      : this.findEditorFocusTarget(editorHost)
    target?.focus()
  }

  get count(): number { return this.matches.length }
  get isVisible(): boolean { return !this.root.classList.contains('hidden') }
  focus(): void { this.focusActiveResult() }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.updateHeader()
  }

  move(delta: number): WorkspaceMatch | null {
    if (this.matches.length === 0) return null
    this.activeIndex = (this.activeIndex + delta + this.matches.length) % this.matches.length
    this.render()
    const match = this.matches[this.activeIndex]
    this.callbacks.onOpenMatch(match)
    return match
  }

  private render(): void {
    const shouldRestoreFocus = this.list.contains(document.activeElement)
    this.list.replaceChildren()
    let lastPath = ''
    this.matches.forEach((match, index) => {
      if (match.path !== lastPath) {
        lastPath = match.path
        const group = document.createElement('li')
        group.className = 'find-results-file'
        group.textContent = match.path
        group.title = match.path
        this.list.appendChild(group)
      }
      const item = document.createElement('li')
      item.className = `find-results-match${index === this.activeIndex ? ' active' : ''}`
      item.tabIndex = 0
      item.setAttribute('role', 'button')
      item.textContent = `  ${baseName(match.path)}:${match.line}:${match.column}  ${match.lineText}`
      const openMatch = (): void => {
        this.activeIndex = index
        this.render()
        this.callbacks.onOpenMatch(match)
      }
      item.addEventListener('click', openMatch)
      item.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        event.stopPropagation()
        openMatch()
      })
      this.list.appendChild(item)
    })
    if (shouldRestoreFocus) this.focusActiveResult()
  }

  private updateHeader(): void {
    this.titleLabel.textContent = translate(this.locale, 'findResults')
    this.titleDetail.textContent = this.query ? ` — “${this.query}” (${this.matches.length})` : ''
    this.summary.textContent = this.query
      ? this.locale === 'zh-CN'
        ? `查询“${this.query}”：${this.matches.length} 个结果`
        : `${this.matches.length} result${this.matches.length === 1 ? '' : 's'} for “${this.query}”`
      : ''
  }

  private focusActiveResult(): void {
    const active = this.list.querySelector<HTMLElement>('.find-results-match.active')
    ;(active ?? this.root).focus()
  }

  private editorHost(): HTMLElement | null {
    return this.root.closest('.editor-area')?.querySelector<HTMLElement>(':scope > .editor-host') ?? null
  }

  private findEditorFocusTarget(editorHost: HTMLElement | null): HTMLElement | null {
    if (!editorHost) return null
    const target = editorHost.querySelector<HTMLElement>('.cm-content, [contenteditable="true"], textarea, input, button, [tabindex]:not([tabindex="-1"])')
    return this.isVisibleFocusTarget(target) ? target : null
  }

  private isVisibleFocusTarget(target: HTMLElement | null): target is HTMLElement {
    return !!target?.isConnected && !target.matches(':disabled') &&
      !target.closest('.hidden, [hidden], [aria-hidden="true"], [inert]')
  }
}
