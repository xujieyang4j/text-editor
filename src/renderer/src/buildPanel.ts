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
  private visible = false

  constructor(
    initialCommand: string,
    private readonly callbacks: BuildPanelCallbacks
  ) {
    this.root = document.createElement('div')
    this.root.className = 'build-panel hidden'
    const toolbar = document.createElement('div')
    toolbar.className = 'build-toolbar'
    this.command = document.createElement('input')
    this.command.className = 'build-command'
    this.command.placeholder = translate('zh-CN', 'build')
    this.command.value = initialCommand
    this.run = this.button(translate('zh-CN', 'run'), () => this.callbacks.onRun(this.command.value.trim()))
    this.cancel = this.button(translate('zh-CN', 'stop'), this.callbacks.onCancel)
    const close = this.button('×', () => this.toggle(false))
    toolbar.append(this.command, this.run, this.cancel, close)
    this.output = document.createElement('pre')
    this.output.className = 'build-output'
    this.problems = document.createElement('ul')
    this.problems.className = 'build-problems'
    this.root.append(toolbar, this.output, this.problems)
    document.body.appendChild(this.root)
  }

  toggle(show = !this.visible): void {
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    if (show) this.command.focus()
  }

  getCommand(): string { return this.command.value.trim() }

  setCommand(command: string): void { this.command.value = command }

  setLocale(locale: UiLocale): void {
    this.command.placeholder = locale === 'zh-CN' ? '构建命令，例如 npm test' : 'Build command, e.g. npm test'
    this.run.textContent = translate(locale, 'run')
    this.cancel.textContent = translate(locale, 'stop')
  }

  clear(): void {
    this.output.textContent = ''
    this.problems.replaceChildren()
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
      item.textContent = `${problem.path}:${problem.line}:${problem.column} — ${problem.message}`
      item.title = item.textContent
      item.addEventListener('click', () => this.callbacks.onOpenProblem(problem))
      this.problems.appendChild(item)
    }
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
  }
}
