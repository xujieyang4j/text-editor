import type { BuildOutput, BuildProblem, UiLocale } from '../../shared/ipc.js'
import { translate } from '../../shared/i18n.js'

type BuildOutputMessage =
  | { kind: 'text'; text: string }
  | { kind: 'exit'; code: number | null | undefined }

export interface BuildPanelCallbacks {
  onRun: (command: string) => void
  onCancel: () => void
  onOpenProblem: (problem: BuildProblem) => void
}

/** Build output / diagnostic console shared by build commands and future language servers. */
export class BuildPanel {
  private static readonly maxOutputChars = 1_000_000
  private readonly root: HTMLDivElement
  private readonly output: HTMLPreElement
  private readonly problems: HTMLUListElement
  private readonly command: HTMLInputElement
  private readonly run: HTMLButtonElement
  private readonly cancel: HTMLButtonElement
  private readonly title: HTMLElement
  private readonly close: HTMLButtonElement
  private readonly summary: HTMLDivElement
  private visible = false
  private previouslyFocused: HTMLElement | null = null
  private locale: UiLocale = 'zh-CN'
  private problemCount: number | null = null
  private readonly outputMessages: BuildOutputMessage[] = []
  private earlierOutputDiscarded = false
  private systemName: string | null = null

  constructor(
    initialCommand: string,
    private readonly callbacks: BuildPanelCallbacks
  ) {
    this.root = document.createElement('div')
    this.root.className = 'build-panel hidden'
    this.root.setAttribute('role', 'region')
    this.root.setAttribute('aria-hidden', 'true')
    const toolbar = document.createElement('div')
    toolbar.className = 'build-toolbar'
    this.title = document.createElement('strong')
    this.title.id = 'build-panel-title'
    this.title.className = 'visually-hidden'
    this.title.setAttribute('role', 'heading')
    this.title.setAttribute('aria-level', '2')
    this.root.setAttribute('aria-labelledby', this.title.id)
    this.command = document.createElement('input')
    this.command.className = 'build-command'
    this.command.placeholder = translate('zh-CN', 'build')
    this.command.value = initialCommand
    this.run = this.button(translate('zh-CN', 'run'), () => this.callbacks.onRun(this.command.value.trim()))
    this.cancel = this.button(translate('zh-CN', 'stop'), this.callbacks.onCancel)
    this.close = this.button('×', () => this.toggle(false))
    toolbar.append(this.title, this.command, this.run, this.cancel, this.close)
    this.output = document.createElement('pre')
    this.output.className = 'build-output'
    this.output.setAttribute('role', 'log')
    this.output.setAttribute('aria-live', 'off')
    this.output.setAttribute('aria-atomic', 'false')
    this.problems = document.createElement('ul')
    this.problems.className = 'build-problems'
    this.summary = document.createElement('div')
    this.summary.className = 'visually-hidden'
    this.summary.setAttribute('role', 'status')
    this.summary.setAttribute('aria-live', 'polite')
    this.summary.setAttribute('aria-atomic', 'true')
    this.root.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.toggle(false)
    })
    this.root.append(toolbar, this.output, this.problems, this.summary)
    document.body.appendChild(this.root)
    this.setLocale(this.locale)
  }

  toggle(show = !this.visible): void {
    if (show === this.visible) {
      if (show) this.command.focus()
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
      this.command.focus()
    } else {
      const focusTarget = this.previouslyFocused
      this.previouslyFocused = null
      if (focusWasWithinPanel) this.restoreFocus(focusTarget)
    }
  }

  getCommand(): string { return this.command.value.trim() }

  setCommand(command: string): void { this.command.value = command }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.updateOutputTitle()
    this.command.placeholder = locale === 'zh-CN' ? '构建命令，例如 npm test' : 'Build command, e.g. npm test'
    this.command.setAttribute('aria-label', locale === 'zh-CN' ? '构建命令' : 'Build command')
    this.run.textContent = translate(locale, 'run')
    this.cancel.textContent = translate(locale, 'stop')
    this.close.title = locale === 'zh-CN' ? '关闭构建面板' : 'Close build panel'
    this.close.setAttribute('aria-label', this.close.title)
    this.problems.setAttribute('aria-label', locale === 'zh-CN' ? '构建问题' : 'Build problems')
    this.trimOutput()
    this.renderOutput()
    this.updateProblemsSummary()
  }

  clear(): void {
    this.outputMessages.length = 0
    this.earlierOutputDiscarded = false
    this.systemName = null
    this.output.textContent = ''
    this.problems.replaceChildren()
    this.problemCount = null
    this.summary.textContent = ''
    this.updateOutputTitle()
  }

  append(message: BuildOutput): void {
    if (message.systemName !== undefined) {
      this.systemName = message.systemName.trim() || null
      this.updateOutputTitle()
    }
    if (message.kind === 'exit') {
      this.outputMessages.push({ kind: 'exit', code: message.code })
    } else if (message.text) {
      const previous = this.outputMessages.at(-1)
      if (previous?.kind === 'text') previous.text += message.text
      else this.outputMessages.push({ kind: 'text', text: message.text })
    }
    this.trimOutput()
    this.renderOutput(true)
    this.output.classList.toggle(
      'has-error',
      message.kind === 'stderr' || (message.kind === 'exit' && message.code !== 0)
    )
  }

  setProblems(problems: BuildProblem[]): void {
    this.problems.replaceChildren()
    for (const problem of problems) {
      const item = document.createElement('li')
      item.className = `build-problem ${problem.severity}`
      item.tabIndex = 0
      item.setAttribute('role', 'button')
      item.textContent = `${problem.path}:${problem.line}:${problem.column} — ${problem.message}`
      item.title = item.textContent
      item.addEventListener('click', () => this.callbacks.onOpenProblem(problem))
      item.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        event.stopPropagation()
        this.callbacks.onOpenProblem(problem)
      })
      this.problems.appendChild(item)
    }
    this.problemCount = problems.length
    this.updateProblemsSummary()
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
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

  private updateOutputTitle(): void {
    const base = this.locale === 'zh-CN' ? '构建输出' : 'Build output'
    const label = this.systemName ? `${base} — ${this.systemName}` : base
    this.title.textContent = label
    this.output.setAttribute('aria-label', label)
  }

  private renderOutput(scrollToEnd = false): void {
    const wasAtBottom = this.output.scrollTop + this.output.clientHeight >= this.output.scrollHeight - 1
    const scrollTop = this.output.scrollTop
    const content = this.outputMessages.map((message) => this.outputText(message)).join('')
    this.output.textContent = `${this.earlierOutputDiscarded ? this.discardedOutputText() : ''}${content}`
    this.output.scrollTop = scrollToEnd || wasAtBottom ? this.output.scrollHeight : scrollTop
  }

  private outputText(message: BuildOutputMessage): string {
    if (message.kind === 'text') return message.text
    if (this.locale === 'zh-CN') {
      return message.code === 0 ? '构建已成功完成。\n' : `构建已退出（代码 ${message.code ?? '未知'}）。\n`
    }
    return message.code === 0
      ? 'Build completed successfully.\n'
      : `Build exited with code ${message.code ?? 'unknown'}.\n`
  }

  private discardedOutputText(): string {
    return this.locale === 'zh-CN'
      ? '[较早构建输出已丢弃]\n'
      : '[Earlier build output discarded]\n'
  }

  private trimOutput(): void {
    let excess = this.outputMessages.reduce(
      (length, message) => length + this.outputText(message).length,
      0
    ) - BuildPanel.maxOutputChars
    if (excess <= 0) return

    this.earlierOutputDiscarded = true
    while (excess > 0) {
      const first = this.outputMessages[0]
      if (!first) return
      const length = this.outputText(first).length
      if (length <= excess || first.kind === 'exit') {
        this.outputMessages.shift()
        excess -= length
      } else {
        let cutAt = excess
        // Keep UTF-16 surrogate pairs intact when trimming through an emoji.
        if (cutAt < first.text.length && cutAt > 0 &&
          first.text.charCodeAt(cutAt) >= 0xdc00 && first.text.charCodeAt(cutAt) <= 0xdfff &&
          first.text.charCodeAt(cutAt - 1) >= 0xd800 && first.text.charCodeAt(cutAt - 1) <= 0xdbff) {
          cutAt += 1
        }
        first.text = first.text.slice(cutAt)
        excess = 0
      }
    }
  }

  private updateProblemsSummary(): void {
    if (this.problemCount === null) return
    if (this.locale === 'zh-CN') {
      this.summary.textContent = this.problemCount === 0 ? '未发现构建问题。' : `发现 ${this.problemCount} 个构建问题。`
      return
    }
    this.summary.textContent = this.problemCount === 0
      ? 'No build problems found.'
      : `${this.problemCount} build ${this.problemCount === 1 ? 'problem' : 'problems'} found.`
  }
}
