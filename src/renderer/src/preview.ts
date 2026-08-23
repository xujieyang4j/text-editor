import { marked } from 'marked'
import DOMPurify from 'dompurify'

/**
 * A live Markdown preview pane rendered next to the editor.
 *
 * Security: the editor runs in an Electron renderer, so untrusted Markdown that
 * contains raw HTML (`<script>`, `onerror=`, `javascript:` URLs, …) would be a
 * genuine XSS/RCE vector. Every rendered fragment is therefore passed through
 * DOMPurify before it touches the DOM. `marked` is configured synchronously so
 * we can sanitize the string it returns.
 */
export class MarkdownPreview {
  private root: HTMLDivElement
  private body: HTMLDivElement
  private visible = false

  constructor(parent: HTMLElement) {
    this.root = document.createElement('div')
    this.root.className = 'preview-pane hidden'

    this.body = document.createElement('div')
    this.body.className = 'preview-body markdown-body'

    this.root.appendChild(this.body)
    parent.appendChild(this.root)
  }

  /** Whether the preview pane is currently shown. */
  get isVisible(): boolean {
    return this.visible
  }

  /** Show the pane and render the given source. */
  show(markdown: string): void {
    this.visible = true
    this.root.classList.remove('hidden')
    this.render(markdown)
  }

  /** Hide the pane. */
  hide(): void {
    this.visible = false
    this.root.classList.add('hidden')
  }

  /** Toggle visibility; returns the new state. Renders when turning on. */
  toggle(markdown: string): boolean {
    if (this.visible) this.hide()
    else this.show(markdown)
    return this.visible
  }

  /** Re-render the preview from fresh source (no-op while hidden). */
  update(markdown: string): void {
    if (!this.visible) return
    this.render(markdown)
  }

  /** Convert Markdown → HTML → sanitized DOM. */
  private render(markdown: string): void {
    // `marked.parse` returns a string in sync mode (async: false is default).
    const rawHtml = marked.parse(markdown, { async: false }) as string
    const clean = DOMPurify.sanitize(rawHtml, {
      // Disallow inline event handlers and javascript: URLs by default;
      // DOMPurify already strips these, this just keeps target/rel safe.
      ADD_ATTR: ['target']
    })
    this.body.innerHTML = clean
    // Reset scroll to top on a full re-render would be jarring while typing,
    // so we intentionally preserve scroll position here.
  }
}

/** True when a file name looks like Markdown. */
export function isMarkdown(fileName: string): boolean {
  return /\.(md|markdown|mdown|mkd|mkdn|mdx)$/i.test(fileName)
}

/** True when a file name looks like HTML. */
export function isHtml(fileName: string): boolean {
  return /\.(html?|xhtml)$/i.test(fileName)
}
