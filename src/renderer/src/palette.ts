import { fuzzyFilter, type FuzzyResult } from './fuzzy.js'

let nextPaletteId = 0

/** A selectable row in the palette. */
export interface PaletteItem {
  /** Primary text, fuzzy-matched and highlighted. */
  label: string
  /** Optional dimmed hint on the right (e.g. a shortcut or line number). */
  hint?: string
  /** Optional dimmed secondary line under the label (e.g. a file path). */
  detail?: string
  /** Arbitrary payload the caller uses when the item is chosen. */
  value: unknown
}

export interface PaletteOptions {
  /** Placeholder shown in the input. */
  placeholder: string
  /** Pre-filled query text (e.g. ":" or "@" prefix). */
  initialQuery?: string
  /** Items to filter. For dynamic modes, provide `onQuery` instead. */
  items?: PaletteItem[]
  /** Called on each keystroke to (re)compute items dynamically. */
  onQuery?: (query: string) => PaletteItem[] | Promise<PaletteItem[]>
  /** Called when the user picks a row. */
  onAccept: (item: PaletteItem) => void
  /** Called as the highlighted row changes (for live preview). */
  onHighlight?: (item: PaletteItem | null) => void
  /** How to strip a leading mode prefix before fuzzy matching (":" / "@"). */
  stripPrefix?: string
}

/**
 * A modal fuzzy-search overlay reused for the Command Palette and Goto Anything.
 * Only one instance is visible at a time; opening a new one replaces the old.
 */
export class Palette {
  private root: HTMLDivElement
  private input: HTMLInputElement
  private list: HTMLUListElement
  private opts: PaletteOptions | null = null
  private rendered: PaletteItem[] = []
  private activeIndex = 0
  private queryToken = 0
  private previouslyFocused: Element | null = null

  constructor() {
    const paletteId = ++nextPaletteId

    this.root = document.createElement('div')
    this.root.className = 'palette-overlay hidden'
    this.root.setAttribute('role', 'dialog')
    this.root.setAttribute('aria-modal', 'true')
    this.root.setAttribute('aria-hidden', 'true')

    const box = document.createElement('div')
    box.className = 'palette-box'

    this.input = document.createElement('input')
    this.input.className = 'palette-input'
    this.input.type = 'text'
    this.input.spellcheck = false
    this.input.setAttribute('role', 'combobox')
    this.input.setAttribute('aria-autocomplete', 'list')
    this.input.setAttribute('aria-haspopup', 'listbox')
    this.input.setAttribute('aria-expanded', 'false')

    this.list = document.createElement('ul')
    this.list.className = 'palette-list'
    this.list.id = `palette-listbox-${paletteId}`
    this.list.setAttribute('role', 'listbox')
    this.input.setAttribute('aria-controls', this.list.id)

    box.append(this.input, this.list)
    this.root.appendChild(box)
    document.body.appendChild(this.root)

    // Clicking the dimmed backdrop closes the palette.
    this.root.addEventListener('mousedown', (e) => {
      if (e.target === this.root) {
        // Avoid the backdrop's default mousedown action stealing the focus
        // that close() restores to the element which opened the palette.
        e.preventDefault()
        this.close()
      }
    })
    this.input.addEventListener('input', () => this.refresh())
    this.input.addEventListener('keydown', (e) => this.onKeyDown(e))
  }

  /** True when the palette is currently visible. */
  get isOpen(): boolean {
    return !this.root.classList.contains('hidden')
  }

  /** Open the palette with the given configuration. */
  open(opts: PaletteOptions): void {
    if (!this.isOpen) this.previouslyFocused = document.activeElement
    this.opts = opts
    this.activeIndex = 0
    this.input.placeholder = opts.placeholder
    this.input.setAttribute('aria-label', opts.placeholder)
    this.input.setAttribute('aria-expanded', 'true')
    this.input.value = opts.initialQuery ?? ''
    this.rendered = []
    this.list.replaceChildren()
    this.list.removeAttribute('aria-busy')
    this.input.removeAttribute('aria-activedescendant')
    this.root.setAttribute('aria-label', opts.placeholder)
    this.root.setAttribute('aria-hidden', 'false')
    this.root.classList.remove('hidden')
    this.refresh()
    this.input.focus()
    // Put the cursor at the end so a prefixed query is ready to extend.
    const len = this.input.value.length
    this.input.setSelectionRange(len, len)
  }

  /** Hide the palette and clear transient state. */
  close(restoreFocus = true): void {
    const wasOpen = this.isOpen
    const focusTarget = this.previouslyFocused
    this.previouslyFocused = null
    ++this.queryToken
    this.root.classList.add('hidden')
    this.root.setAttribute('aria-hidden', 'true')
    this.input.setAttribute('aria-expanded', 'false')
    this.input.removeAttribute('aria-activedescendant')
    this.list.replaceChildren()
    this.list.removeAttribute('aria-busy')
    this.opts?.onHighlight?.(null)
    this.opts = null
    this.rendered = []
    this.activeIndex = 0

    if (restoreFocus && wasOpen && focusTarget instanceof HTMLElement && focusTarget.isConnected) {
      focusTarget.focus()
    }
  }

  /** Recompute the filtered rows for the current query. */
  private async refresh(): Promise<void> {
    const opts = this.opts
    if (!opts) return
    const raw = this.input.value
    const query = opts.stripPrefix
      ? raw.startsWith(opts.stripPrefix)
        ? raw.slice(opts.stripPrefix.length)
        : raw
      : raw

    const token = ++this.queryToken

    let items: PaletteItem[]
    if (opts.onQuery) {
      this.list.setAttribute('aria-busy', 'true')
      try {
        items = await opts.onQuery(query)
      } catch {
        items = []
      }
      if (token !== this.queryToken || this.opts !== opts) {
        if (this.opts === opts) this.list.removeAttribute('aria-busy')
        return
      }
      this.list.removeAttribute('aria-busy')
    } else {
      const source = opts.items ?? []
      items =
        query.length === 0
          ? source
          : fuzzyFilter(query, source, (i) => i.label).map((r) => this.withMatches(r.item, r.result))
    }

    this.rendered = items
    this.activeIndex = Math.min(this.activeIndex, Math.max(0, items.length - 1))
    this.renderList(query)
    this.notifyHighlight()
  }

  /** Attach the matched indices onto the item for highlight rendering. */
  private withMatches(item: PaletteItem, result: FuzzyResult): PaletteItem {
    ;(item as PaletteItem & { _matches?: number[] })._matches = result.matches
    return item
  }

  /** Render the list DOM, highlighting matched characters. */
  private renderList(_query: string): void {
    this.list.replaceChildren()
    this.rendered.forEach((item, idx) => {
      const li = document.createElement('li')
      li.className = 'palette-item' + (idx === this.activeIndex ? ' active' : '')
      li.id = `${this.list.id}-option-${idx}`
      li.setAttribute('role', 'option')
      li.setAttribute('aria-selected', String(idx === this.activeIndex))

      const main = document.createElement('div')
      main.className = 'palette-item-main'
      main.appendChild(this.renderLabel(item))

      if (item.detail) {
        const detail = document.createElement('div')
        detail.className = 'palette-item-detail'
        detail.textContent = item.detail
        main.appendChild(detail)
      }
      li.appendChild(main)

      if (item.hint) {
        const hint = document.createElement('span')
        hint.className = 'palette-item-hint'
        hint.textContent = item.hint
        li.appendChild(hint)
      }

      li.addEventListener('mousedown', (e) => {
        e.preventDefault()
        this.accept(idx)
      })
      li.addEventListener('mousemove', () => {
        if (this.activeIndex !== idx) {
          this.activeIndex = idx
          this.syncActive()
          this.notifyHighlight()
        }
      })
      this.list.appendChild(li)
    })
    this.syncActiveDescendant()
  }

  /** Build a label node with matched characters wrapped in <b>. */
  private renderLabel(item: PaletteItem): HTMLElement {
    const span = document.createElement('span')
    const matches = new Set((item as PaletteItem & { _matches?: number[] })._matches ?? [])
    if (matches.size === 0) {
      span.textContent = item.label
      return span
    }
    ;[...item.label].forEach((ch, i) => {
      if (matches.has(i)) {
        const b = document.createElement('b')
        b.textContent = ch
        span.appendChild(b)
      } else {
        span.appendChild(document.createTextNode(ch))
      }
    })
    return span
  }

  /** Update only the `.active` class without a full re-render. */
  private syncActive(): void {
    const children = Array.from(this.list.children)
    children.forEach((el, i) => {
      const active = i === this.activeIndex
      el.classList.toggle('active', active)
      el.setAttribute('aria-selected', String(active))
    })
    children[this.activeIndex]?.scrollIntoView({ block: 'nearest' })
    this.syncActiveDescendant()
  }

  /** Point the combobox at the currently active option, if one exists. */
  private syncActiveDescendant(): void {
    const active = this.list.children[this.activeIndex]
    if (active instanceof HTMLElement) {
      this.input.setAttribute('aria-activedescendant', active.id)
    } else {
      this.input.removeAttribute('aria-activedescendant')
    }
  }

  /** Fire the highlight callback for the active row (live preview). */
  private notifyHighlight(): void {
    this.opts?.onHighlight?.(this.rendered[this.activeIndex] ?? null)
  }

  /** Keyboard navigation + accept/close. */
  private onKeyDown(e: KeyboardEvent): void {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      e.stopPropagation()
      this.move(1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      e.stopPropagation()
      this.move(-1)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      e.stopPropagation()
      this.accept(this.activeIndex)
    } else if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      this.close()
    } else if (e.key === 'Tab') {
      // The combobox is currently the palette's only focusable control. Keep
      // both Tab and Shift+Tab from escaping the modal dialog.
      e.preventDefault()
      e.stopPropagation()
      this.input.focus()
    }
  }

  /** Move the active row by delta, clamped. */
  private move(delta: number): void {
    if (this.rendered.length === 0) return
    this.activeIndex = (this.activeIndex + delta + this.rendered.length) % this.rendered.length
    this.syncActive()
    this.notifyHighlight()
  }

  /** Accept the row at idx, invoking the caller's handler, then close. */
  private accept(idx: number): void {
    const item = this.rendered[idx]
    const accept = this.opts?.onAccept
    if (!item || !accept) return
    const focusTarget = this.previouslyFocused
    this.close(false)
    accept(item)
    if ((document.activeElement === document.body || this.root.contains(document.activeElement)) &&
      focusTarget instanceof HTMLElement && focusTarget.isConnected) focusTarget.focus()
  }
}
