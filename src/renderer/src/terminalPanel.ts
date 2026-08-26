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
  private locale: UiLocale = 'zh-CN'

  constructor(private readonly callbacks: TerminalPanelCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'terminal-panel hidden'
    const toolbar = document.createElement('div')
    toolbar.className = 'terminal-toolbar'
    this.title = document.createElement('strong')
    this.start = this.button('启动', () => this.callbacks.onStart())
    this.stop = this.button('停止', () => this.callbacks.onStop())
    this.close = this.button('×', () => this.toggle(false))
    toolbar.append(this.title, this.start, this.stop, this.close)
    this.output = document.createElement('pre')
    this.output.className = 'terminal-output'
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
    this.root.append(toolbar, this.output, this.input)
    document.body.appendChild(this.root)
    this.setLocale(this.locale)
    this.setRunning(false)
  }

  toggle(show = !this.visible): void {
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    if (show) this.input.focus()
  }

  get isVisible(): boolean { return this.visible }

  setRunning(running: boolean): void {
    this.start.disabled = running
    this.stop.disabled = !running
    this.input.disabled = !running
    this.root.dataset.running = String(running)
    if (running && this.visible) this.input.focus()
  }

  setStarting(starting: boolean): void {
    this.start.disabled = starting
    this.stop.disabled = true
    this.input.disabled = true
    this.root.dataset.running = String(starting)
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.title.textContent = locale === 'zh-CN' ? '终端' : 'Terminal'
    this.start.textContent = locale === 'zh-CN' ? '启动' : 'Start'
    this.stop.textContent = locale === 'zh-CN' ? '停止' : 'Stop'
    this.close.title = locale === 'zh-CN' ? '关闭终端面板' : 'Close terminal panel'
    this.close.setAttribute('aria-label', this.close.title)
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

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
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
