import type { UiLocale } from '../../shared/ipc.js'
import { extractSymbols, type Symbol } from './symbols.js'

export interface OutlinePanelCallbacks {
  onSelect: (symbol: Symbol) => void
}

/**
 * A lightweight, local outline for the active document. It deliberately uses
 * the same dependency-free symbol extraction as Goto Symbol, so browsing code
 * structure never starts a language server or exposes additional privileges.
 */
export class OutlinePanel {
  private static readonly maxSourceChars = 2 * 1024 * 1024
  private static readonly maxSymbols = 5_000
  private static nextPanelId = 0

  readonly element: HTMLDivElement
  private readonly heading: HTMLDivElement
  private readonly title: HTMLElement
  private readonly summary: HTMLSpanElement
  private readonly filter: HTMLInputElement
  private readonly list: HTMLUListElement
  private visible = false
  private locale: UiLocale = 'zh-CN'
  private documentName = ''
  private documentContent = ''
  private cursorPos = 0
  private symbols: Symbol[] = []
  private sourceWasTruncated = false
  private updateTimer: number | null = null
  private previouslyFocused: HTMLElement | null = null

  constructor(private readonly callbacks: OutlinePanelCallbacks) {
    this.element = document.createElement('div')
    this.element.className = 'outline-panel hidden'
    this.element.setAttribute('role', 'region')
    this.element.setAttribute('aria-hidden', 'true')
    this.heading = document.createElement('div')
    this.heading.className = 'outline-panel-heading'
    this.title = document.createElement('strong')
    this.title.id = `outline-panel-title-${++OutlinePanel.nextPanelId}`
    this.title.setAttribute('role', 'heading')
    this.title.setAttribute('aria-level', '2')
    this.element.setAttribute('aria-labelledby', this.title.id)
    this.summary = document.createElement('span')
    this.summary.setAttribute('role', 'status')
    this.summary.setAttribute('aria-live', 'polite')
    this.summary.setAttribute('aria-atomic', 'true')
    this.heading.append(this.title, this.summary)
    this.filter = document.createElement('input')
    this.filter.className = 'outline-filter'
    this.filter.type = 'search'
    this.filter.spellcheck = false
    this.filter.addEventListener('input', () => this.renderList())
    this.list = document.createElement('ul')
    this.list.className = 'outline-list'
    this.list.setAttribute('aria-labelledby', this.title.id)
    this.element.append(this.heading, this.filter, this.list)
    this.setLocale(this.locale)
  }

  get isVisible(): boolean { return this.visible }

  toggle(show = !this.visible): void {
    const changed = this.visible !== show
    if (!changed) return
    const focusWasWithinPanel = this.element.contains(document.activeElement)
    if (show) {
      this.previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null
    }
    this.visible = show
    this.element.classList.toggle('hidden', !show)
    this.element.setAttribute('aria-hidden', String(!show))
    if (show) {
      this.refreshNow()
    } else {
      const focusTarget = this.previouslyFocused
      this.previouslyFocused = null
      if (focusWasWithinPanel) this.restoreFocus(focusTarget)
    }
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.title.textContent = locale === 'zh-CN' ? '大纲' : 'Outline'
    this.filter.placeholder = locale === 'zh-CN' ? '筛选符号…' : 'Filter symbols…'
    this.filter.setAttribute('aria-label', locale === 'zh-CN' ? '筛选大纲符号' : 'Filter outline symbols')
    this.renderList()
  }

  /** Set the active document. A short debounce prevents rescanning on every keypress. */
  setDocument(name: string, content: string, cursorPos: number, immediate = false): void {
    this.documentName = name
    this.documentContent = content
    this.cursorPos = cursorPos
    if (!this.visible) return
    if (immediate) {
      if (this.updateTimer !== null) window.clearTimeout(this.updateTimer)
      this.updateTimer = null
      this.refreshNow()
      return
    }
    if (this.updateTimer !== null) window.clearTimeout(this.updateTimer)
    this.updateTimer = window.setTimeout(() => {
      this.updateTimer = null
      this.refreshNow()
    }, 120)
  }

  /** Update the active row without rescanning the current document. */
  setCursor(pos: number): void {
    const previous = this.activeSymbol()
    this.cursorPos = pos
    // Cursor motion is much more frequent than edits. Only rebuild the DOM
    // when the cursor crosses a symbol boundary and the highlighted item must
    // actually change.
    if (this.visible && previous !== this.activeSymbol()) this.renderList()
  }

  private refreshNow(): void {
    const source = this.documentContent.slice(0, OutlinePanel.maxSourceChars)
    this.sourceWasTruncated = source.length !== this.documentContent.length
    this.symbols = extractSymbols(source).slice(0, OutlinePanel.maxSymbols)
    this.renderList()
  }

  private renderList(): void {
    this.list.replaceChildren()
    const query = this.filter.value.trim().toLocaleLowerCase()
    const symbols = query
      ? this.symbols.filter((symbol) => symbol.label.toLocaleLowerCase().includes(query))
      : this.symbols
    const active = this.activeSymbol()

    if (!this.documentName) {
      this.summary.textContent = this.locale === 'zh-CN' ? '没有活动文件' : 'No active file'
      return
    }
    if (symbols.length === 0) {
      this.summary.textContent = this.locale === 'zh-CN' ? '未找到符号' : 'No symbols'
      return
    }
    const suffix = this.sourceWasTruncated || this.symbols.length >= OutlinePanel.maxSymbols
      ? (this.locale === 'zh-CN' ? '（已截断）' : ' (truncated)')
      : ''
    this.summary.textContent = `${symbols.length}${suffix}`
    for (const symbol of symbols) {
      const item = document.createElement('li')
      item.className = 'outline-item'
      if (symbol === active) item.classList.add('active')
      const button = document.createElement('button')
      button.type = 'button'
      button.className = 'outline-symbol'
      if (symbol === active) button.setAttribute('aria-current', 'location')
      const markdownHeading = /^(#+)\s+/.exec(symbol.label)
      if (markdownHeading) button.style.paddingLeft = `${8 + Math.min(5, markdownHeading[1].length - 1) * 12}px`
      button.textContent = symbol.label
      button.title = `${symbol.label} — ${this.locale === 'zh-CN' ? '第' : 'Line '}${symbol.line}${this.locale === 'zh-CN' ? '行' : ''}`
      button.addEventListener('click', () => this.callbacks.onSelect(symbol))
      item.appendChild(button)
      this.list.appendChild(item)
    }
  }

  private activeSymbol(): Symbol | undefined {
    let active: Symbol | undefined
    for (const symbol of this.symbols) {
      if (symbol.pos > this.cursorPos) break
      active = symbol
    }
    return active
  }

  private restoreFocus(preferred: HTMLElement | null): void {
    const candidates = [
      preferred,
      ...document.querySelectorAll<HTMLElement>('.cm-content, [contenteditable="true"], button, input, select, textarea, [tabindex]:not([tabindex="-1"])')
    ]
    const target = candidates.find((candidate): candidate is HTMLElement =>
      candidate instanceof HTMLElement && candidate.isConnected && !this.element.contains(candidate) &&
      !candidate.matches(':disabled') && !candidate.closest('.hidden, [hidden], [aria-hidden="true"], [inert]'))
    target?.focus()
  }
}
