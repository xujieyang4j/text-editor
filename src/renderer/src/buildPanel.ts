import type { BuildOutput, BuildProblem, UiLocale } from '../../shared/ipc.js'
import { translate } from '../../shared/i18n.js'

export interface BuildPanelCallbacks {
  onRun: (command: string) => void
  onCancel: () => void
  onOpenProblem: (problem: BuildProblem) => void
}

/** Build output / diagnostic console shared by build commands and future language servers. */
export class BuildPanel {
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
    this.title.textContent = locale === 'zh-CN' ? '构建输出' : 'Build output'
    this.command.placeholder = locale === 'zh-CN' ? '构建命令，例如 npm test' : 'Build command, e.g. npm test'
    this.command.setAttribute('aria-label', locale === 'zh-CN' ? '构建命令' : 'Build command')
    this.run.textContent = translate(locale, 'run')
    this.cancel.textContent = translate(locale, 'stop')
    this.close.title = locale === 'zh-CN' ? '关闭构建面板' : 'Close build panel'
    this.close.setAttribute('aria-label', this.close.title)
    this.output.setAttribute('aria-label', locale === 'zh-CN' ? '构建输出' : 'Build output')
    this.problems.setAttribute('aria-label', locale === 'zh-CN' ? '构建问题' : 'Build problems')
    this.updateProblemsSummary()
  }

  clear(): void {
    this.output.textContent = ''
    this.problems.replaceChildren()
    this.problemCount = null
    this.summary.textContent = ''
  }

  append(message: BuildOutput): void {
    this.output.textContent += message.text
    this.output.scrollTop = this.output.scrollHeight
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
