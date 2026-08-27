import type { TerminalOutput, UiLocale } from '../../shared/ipc.js'

export interface TerminalPanelCallbacks {
  onStart: () => void
  onWrite: (text: string) => void
  onStop: () => void
}

/** A deliberately small terminal front-end. Process ownership remains in main. */
export class TerminalPanel {
  private static readonly maxOutputChars = 1_000_000
  readonly root: HTMLDivElement
  private readonly output: HTMLPreElement
  private readonly input: HTMLInputElement
  private readonly start: HTMLButtonElement
  private readonly stop: HTMLButtonElement
  private readonly title: HTMLElement
  private readonly close: HTMLButtonElement
  private visible = false
  private previouslyFocused: HTMLElement | null = null
  private locale: UiLocale = 'zh-CN'

  constructor(private readonly callbacks: TerminalPanelCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'terminal-panel hidden'
    this.root.setAttribute('role', 'region')
    this.root.setAttribute('aria-hidden', 'true')
    const toolbar = document.createElement('div')
    toolbar.className = 'terminal-toolbar'
    this.title = document.createElement('strong')
    this.title.id = 'terminal-panel-title'
    this.title.setAttribute('role', 'heading')
    this.title.setAttribute('aria-level', '2')
    this.root.setAttribute('aria-labelledby', this.title.id)
    this.start = this.button('启动', () => this.callbacks.onStart())
    this.stop = this.button('停止', () => this.callbacks.onStop())
    this.close = this.button('×', () => this.toggle(false))
    toolbar.append(this.title, this.start, this.stop, this.close)
    this.output = document.createElement('pre')
    this.output.className = 'terminal-output'
    this.output.setAttribute('role', 'log')
    this.output.setAttribute('aria-live', 'off')
    this.output.setAttribute('aria-atomic', 'false')
    this.input = document.createElement('input')
    this.input.className = 'terminal-input'
    this.input.spellcheck = false
    this.input.addEventListener('keydown', (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'c' && !this.input.value) {
        event.preventDefault()
        this.callbacks.onWrite('\u0003')
        return
      }
      if (event.key !== 'Enter') return
      event.preventDefault()
      const text = this.input.value
      if (!text) return
      this.callbacks.onWrite(`${text}\n`)
      this.input.value = ''
    })
    this.root.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.toggle(false)
    })
    this.root.append(toolbar, this.output, this.input)
    document.body.appendChild(this.root)
    this.setLocale(this.locale)
    this.setRunning(false)
  }

  toggle(show = !this.visible): void {
    if (show === this.visible) {
      if (show) this.focusPanel()
      return
    }
    const focusWasWithinPanel = this.root.contains(document.activeElement)
    if (show) {
      this.previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null
    }
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    this.root.setAttribute('aria-hidden', String(!show))
    if (show) {
      this.focusPanel()
    } else {
      const focusTarget = this.previouslyFocused
      this.previouslyFocused = null
      if (focusWasWithinPanel) this.restoreFocus(focusTarget)
    }
  }

  get isVisible(): boolean { return this.visible }

  setRunning(running: boolean): void {
    const focusWasWithinPanel = this.root.contains(document.activeElement)
    this.start.disabled = running
    this.stop.disabled = !running
    this.input.disabled = !running
    this.root.dataset.running = String(running)
    if (this.visible && focusWasWithinPanel) this.focusPanel()
  }

  setStarting(starting: boolean): void {
    const focusWasWithinPanel = this.root.contains(document.activeElement)
    this.start.disabled = starting
    this.stop.disabled = true
    this.input.disabled = true
    this.root.dataset.running = String(starting)
    if (this.visible && focusWasWithinPanel) this.focusPanel()
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.title.textContent = locale === 'zh-CN' ? '终端' : 'Terminal'
    this.start.textContent = locale === 'zh-CN' ? '启动' : 'Start'
    this.stop.textContent = locale === 'zh-CN' ? '停止' : 'Stop'
    this.close.title = locale === 'zh-CN' ? '关闭终端面板' : 'Close terminal panel'
    this.close.setAttribute('aria-label', this.close.title)
    this.output.setAttribute('aria-label', locale === 'zh-CN' ? '终端输出' : 'Terminal output')
    this.input.setAttribute('aria-label', locale === 'zh-CN' ? '终端命令输入' : 'Terminal command input')
    this.input.placeholder = locale === 'zh-CN' ? '输入命令并按回车（Ctrl+C 可中断）…' : 'Type a command and press Enter (Ctrl+C interrupts)…'
  }

  append(output: TerminalOutput): void {
    const exitText = output.kind !== 'exit' ? output.text : this.exitMessage(output.code)
    const next = `${this.output.textContent ?? ''}${exitText}`
    this.output.textContent = next.length > TerminalPanel.maxOutputChars
      ? `[Earlier terminal output discarded]\n${next.slice(-TerminalPanel.maxOutputChars)}`
      : next
    this.output.scrollTop = this.output.scrollHeight
  }

  clear(): void { this.output.textContent = '' }

  private focusPanel(): void {
    const target = !this.input.disabled ? this.input : !this.start.disabled ? this.start : this.close
    target.focus()
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

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
  }

  private exitMessage(code: number | null | undefined): string {
    if (this.locale === 'zh-CN') return code === 0 ? '终端已退出。\n' : `终端已退出（代码 ${code ?? '未知'}）。\n`
    return code === 0 ? 'Terminal exited.\n' : `Terminal exited with code ${code ?? 'unknown'}.\n`
  }
}
