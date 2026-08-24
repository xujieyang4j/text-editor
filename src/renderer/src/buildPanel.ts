import type { BuildOutput } from '../../shared/ipc.js'

/** Build output / diagnostic console shared by build commands and future language servers. */
export class BuildPanel {
  private readonly root: HTMLDivElement
  private readonly output: HTMLPreElement
  private readonly command: HTMLInputElement
  private visible = false

  constructor(
    initialCommand: string,
    private readonly onRun: (command: string) => void,
    private readonly onCancel: () => void
  ) {
    this.root = document.createElement('div')
    this.root.className = 'build-panel hidden'
    const toolbar = document.createElement('div')
    toolbar.className = 'build-toolbar'
    this.command = document.createElement('input')
    this.command.className = 'build-command'
    this.command.placeholder = 'Build command, e.g. npm test'
    this.command.value = initialCommand
    const run = this.button('Run', () => this.onRun(this.command.value.trim()))
    const cancel = this.button('Stop', this.onCancel)
    const close = this.button('×', () => this.toggle(false))
    toolbar.append(this.command, run, cancel, close)
    this.output = document.createElement('pre')
    this.output.className = 'build-output'
    this.root.append(toolbar, this.output)
    document.body.appendChild(this.root)
  }

  toggle(show = !this.visible): void {
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    if (show) this.command.focus()
  }

  getCommand(): string { return this.command.value.trim() }

  setCommand(command: string): void { this.command.value = command }

  clear(): void { this.output.textContent = '' }

  append(message: BuildOutput): void {
    this.output.textContent += message.text
    this.output.scrollTop = this.output.scrollHeight
    this.output.classList.toggle(
      'has-error',
      message.kind === 'stderr' || (message.kind === 'exit' && message.code !== 0)
    )
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
  }
}
