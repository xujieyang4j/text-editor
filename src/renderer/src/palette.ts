import { fuzzyFilter, type FuzzyResult } from './fuzzy.js'

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

  constructor() {
    this.root = document.createElement('div')
    this.root.className = 'palette-overlay hidden'

    const box = document.createElement('div')
    box.className = 'palette-box'

    this.input = document.createElement('input')
    this.input.className = 'palette-input'
    this.input.type = 'text'
    this.input.spellcheck = false

    this.list = document.createElement('ul')
    this.list.className = 'palette-list'

    box.append(this.input, this.list)
    this.root.appendChild(box)
    document.body.appendChild(this.root)

    // Clicking the dimmed backdrop closes the palette.
    this.root.addEventListener('mousedown', (e) => {
      if (e.target === this.root) this.close()
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
    this.opts = opts
    this.activeIndex = 0
    this.input.placeholder = opts.placeholder
    this.input.value = opts.initialQuery ?? ''
    this.root.classList.remove('hidden')
    this.refresh()
    this.input.focus()
    // Put the cursor at the end so a prefixed query is ready to extend.
    const len = this.input.value.length
    this.input.setSelectionRange(len, len)
  }

  /** Hide the palette and clear transient state. */
  close(): void {
    this.root.classList.add('hidden')
    this.list.replaceChildren()
    this.opts?.onHighlight?.(null)
    this.opts = null
  }

  /** Recompute the filtered rows for the current query. */
  private async refresh(): Promise<void> {
    if (!this.opts) return
    const raw = this.input.value
    const query = this.opts.stripPrefix
      ? raw.startsWith(this.opts.stripPrefix)
        ? raw.slice(this.opts.stripPrefix.length)
        : raw
      : raw

    const token = ++this.queryToken

    let items: PaletteItem[]
    if (this.opts.onQuery) {
      items = await this.opts.onQuery(query)
      if (token !== this.queryToken) return // a newer keystroke superseded us
    } else {
      const source = this.opts.items ?? []
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
    children.forEach((el, i) => el.classList.toggle('active', i === this.activeIndex))
    children[this.activeIndex]?.scrollIntoView({ block: 'nearest' })
  }

  /** Fire the highlight callback for the active row (live preview). */
  private notifyHighlight(): void {
    this.opts?.onHighlight?.(this.rendered[this.activeIndex] ?? null)
  }

  /** Keyboard navigation + accept/close. */
  private onKeyDown(e: KeyboardEvent): void {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      this.move(1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      this.move(-1)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      this.accept(this.activeIndex)
    } else if (e.key === 'Escape') {
      e.preventDefault()
      this.close()
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
    this.close()
    if (item && accept) accept(item)
  }
}
