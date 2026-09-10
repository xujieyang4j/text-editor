import type { Settings, UiLocale } from '../../shared/ipc.js'

export interface SettingsPanelCallbacks {
  onChange: (settings: Settings) => void
}

type CheckKey = 'insertSpaces' | 'wordWrap' | 'showLineNumbers' | 'showMinimap' | 'showOutline' | 'showIndentGuides' | 'showWhitespace' | 'highlightTrailingWhitespace' | 'spellCheck' | 'distractionFree'

/**
 * Immediate, local user-preferences editor. It never touches project commands
 * or file contents; callers receive a full Settings snapshot to apply through
 * the existing validated preferences persistence path.
 */
export class SettingsPanel {
  readonly root: HTMLDivElement
  private readonly title: HTMLHeadingElement
  private readonly close: HTMLButtonElement
  private readonly localeSelect: HTMLSelectElement
  private readonly schemeSelect: HTMLSelectElement
  private readonly fontSize: HTMLInputElement
  private readonly tabSize: HTMLInputElement
  private readonly autoSave: HTMLSelectElement
  private readonly autoSaveDelay: HTMLInputElement
  private readonly maxFileSize: HTMLInputElement
  private readonly checkboxes = new Map<CheckKey, HTMLInputElement>()
  private readonly labels = new Map<string, HTMLElement>()
  private readonly controls = new Map<string, HTMLElement>()
  private visible = false
  private previouslyFocused: HTMLElement | null = null
  private locale: UiLocale = 'zh-CN'
  private settings: Settings

  constructor(settings: Settings, private readonly callbacks: SettingsPanelCallbacks) {
    this.settings = this.copy(settings)
    this.root = document.createElement('div')
    this.root.className = 'settings-panel hidden'
    this.root.setAttribute('role', 'dialog')
    this.root.setAttribute('aria-modal', 'false')
    this.root.setAttribute('aria-hidden', 'true')

    const header = document.createElement('header')
    header.className = 'settings-panel-header'
    this.title = document.createElement('h2')
    this.title.id = 'lumen-settings-title'
    this.root.setAttribute('aria-labelledby', this.title.id)
    this.close = document.createElement('button')
    this.close.type = 'button'
    this.close.className = 'panel-button'
    this.close.textContent = '×'
    this.close.addEventListener('click', () => this.toggle(false))
    header.append(this.title, this.close)

    const body = document.createElement('div')
    body.className = 'settings-panel-body'
    this.localeSelect = this.select([['zh-CN', '简体中文'], ['en-US', 'English']], () => {
      this.setLocale(this.localeSelect.value === 'en-US' ? 'en-US' : 'zh-CN')
      this.emit()
    })
    this.schemeSelect = this.select([
      ['dark', 'Dark'], ['light', 'Light'], ['solarized-dark', 'Solarized Dark'], ['dracula', 'Dracula']
    ], () => {
      const scheme = this.schemeSelect.value as Settings['colorScheme']
      this.settings.colorScheme = scheme
      this.settings.theme = scheme === 'light' ? 'light' : 'dark'
      this.emit()
    })
    this.fontSize = this.number(8, 40, () => { this.settings.fontSize = this.bounded(this.fontSize, 8, 40, this.settings.fontSize); this.emit() })
    this.tabSize = this.number(1, 16, () => { this.settings.tabSize = this.bounded(this.tabSize, 1, 16, this.settings.tabSize); this.emit() })
    this.autoSave = this.select([['off', 'Off'], ['after_delay', 'After delay'], ['on_focus_change', 'On focus change']], () => {
      this.settings.autoSave = this.autoSave.value as Settings['autoSave']
      this.updateAutoSaveDelayState()
      this.emit()
    })
    this.autoSaveDelay = this.number(250, 60_000, () => { this.settings.autoSaveDelayMs = this.bounded(this.autoSaveDelay, 250, 60_000, this.settings.autoSaveDelayMs); this.emit() })
    this.maxFileSize = this.number(1, 200, () => { this.settings.maxFileSizeMB = this.bounded(this.maxFileSize, 1, 200, this.settings.maxFileSizeMB); this.emit() })

    body.append(
      this.field('locale', this.localeSelect),
      this.field('colorScheme', this.schemeSelect),
      this.field('fontSize', this.fontSize),
      this.field('tabSize', this.tabSize),
      this.field('autoSave', this.autoSave),
      this.field('autoSaveDelay', this.autoSaveDelay),
      this.field('maxFileSize', this.maxFileSize),
      this.check('insertSpaces'),
      this.check('wordWrap'),
      this.check('showLineNumbers'),
      this.check('showMinimap'),
      this.check('showOutline'),
      this.check('showIndentGuides'),
      this.check('showWhitespace'),
      this.check('highlightTrailingWhitespace'),
      this.check('spellCheck'),
      this.check('distractionFree')
    )
    this.root.append(header, body)
    this.root.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.toggle(false)
    })
    document.body.appendChild(this.root)
    this.setLocale(settings.locale)
    this.setSettings(settings)
  }

  get isVisible(): boolean { return this.visible }

  toggle(show = !this.visible): void {
    if (show === this.visible) {
      if (show) this.fontSize.focus()
      return
    }
    const focusWasWithinPanel = this.root.contains(document.activeElement)
    if (show) {
      const active = document.activeElement
      this.previouslyFocused = active instanceof HTMLElement && !this.root.contains(active) ? active : null
    }
    this.visible = show
    this.root.classList.toggle('hidden', !show)
    this.root.setAttribute('aria-hidden', String(!show))
    if (show) {
      this.fontSize.focus()
    } else {
      const focusTarget = this.previouslyFocused
      this.previouslyFocused = null
      if (focusWasWithinPanel && focusTarget?.isConnected) focusTarget.focus()
    }
  }

  setSettings(settings: Settings): void {
    this.settings = this.copy(settings)
    this.localeSelect.value = this.settings.locale
    this.schemeSelect.value = this.settings.colorScheme
    this.fontSize.value = String(this.settings.fontSize)
    this.tabSize.value = String(this.settings.tabSize)
    this.autoSave.value = this.settings.autoSave
    this.autoSaveDelay.value = String(this.settings.autoSaveDelayMs)
    this.maxFileSize.value = String(this.settings.maxFileSizeMB)
    for (const [key, checkbox] of this.checkboxes) checkbox.checked = this.settings[key]
    this.setLocale(this.settings.locale)
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.settings.locale = locale
    this.localeSelect.value = locale
    this.root.lang = locale
    const zh = locale === 'zh-CN'
    this.title.textContent = zh ? '设置' : 'Settings'
    this.close.title = zh ? '关闭设置' : 'Close settings'
    this.close.setAttribute('aria-label', this.close.title)
    const text: Record<string, string> = zh
      ? { locale: '界面语言', colorScheme: '配色方案', fontSize: '字号（px）', tabSize: '默认缩进宽度', autoSave: '自动保存', autoSaveDelay: '自动保存延迟（毫秒）', maxFileSize: '文件大小上限（MB）', insertSpaces: '使用空格缩进', wordWrap: '自动换行', showLineNumbers: '显示行号', showMinimap: '显示缩略图', showOutline: '显示当前文件大纲', showIndentGuides: '显示缩进参考线', showWhitespace: '显示空白字符', highlightTrailingWhitespace: '高亮行尾空白', spellCheck: '启用拼写检查', distractionFree: '专注模式' }
      : { locale: 'Interface language', colorScheme: 'Color scheme', fontSize: 'Font size (px)', tabSize: 'Default tab size', autoSave: 'Auto save', autoSaveDelay: 'Auto-save delay (ms)', maxFileSize: 'File size limit (MB)', insertSpaces: 'Insert spaces', wordWrap: 'Word wrap', showLineNumbers: 'Show line numbers', showMinimap: 'Show minimap', showOutline: 'Show active-file outline', showIndentGuides: 'Show indent guides', showWhitespace: 'Show whitespace characters', highlightTrailingWhitespace: 'Highlight trailing whitespace', spellCheck: 'Enable spell check', distractionFree: 'Distraction free mode' }
    for (const [key, label] of this.labels) {
      const translated = text[key] ?? key
      label.textContent = translated
      this.controls.get(key)?.setAttribute('aria-label', translated)
    }
    this.setOptionLabels(this.schemeSelect, zh
      ? { dark: '深色', light: '浅色', 'solarized-dark': 'Solarized 深色', dracula: 'Dracula' }
      : { dark: 'Dark', light: 'Light', 'solarized-dark': 'Solarized Dark', dracula: 'Dracula' })
    this.setOptionLabels(this.autoSave, zh
      ? { off: '关闭', after_delay: '延时保存', on_focus_change: '焦点切换时保存' }
      : { off: 'Off', after_delay: 'After delay', on_focus_change: 'On focus change' })
    this.updateAutoSaveDelayState()
  }

  private field(key: string, control: HTMLElement): HTMLLabelElement {
    const row = document.createElement('label')
    row.className = 'settings-field'
    control.dataset.setting = key
    this.controls.set(key, control)
    const text = document.createElement('span')
    this.labels.set(key, text)
    row.append(text, control)
    return row
  }

  private check(key: CheckKey): HTMLLabelElement {
    const row = document.createElement('label')
    row.className = 'settings-check'
    const input = document.createElement('input')
    input.type = 'checkbox'
    input.dataset.setting = key
    this.controls.set(key, input)
    input.addEventListener('change', () => {
      this.settings[key] = input.checked
      this.emit()
    })
    this.checkboxes.set(key, input)
    const text = document.createElement('span')
    this.labels.set(key, text)
    row.append(input, text)
    return row
  }

  private number(min: number, max: number, onChange: () => void): HTMLInputElement {
    const input = document.createElement('input')
    input.type = 'number'
    input.min = String(min)
    input.max = String(max)
    input.step = '1'
    input.addEventListener('change', onChange)
    return input
  }

  private select(options: Array<[string, string]>, onChange: () => void): HTMLSelectElement {
    const select = document.createElement('select')
    for (const [value, label] of options) {
      const option = document.createElement('option')
      option.value = value
      option.textContent = label
      select.appendChild(option)
    }
    select.addEventListener('change', onChange)
    return select
  }

  private bounded(input: HTMLInputElement, min: number, max: number, fallback: number): number {
    const value = Number(input.value)
    const next = Number.isFinite(value) ? Math.max(min, Math.min(max, Math.round(value))) : fallback
    input.value = String(next)
    return next
  }

  private updateAutoSaveDelayState(): void {
    this.autoSaveDelay.disabled = this.settings.autoSave !== 'after_delay'
    if (this.autoSaveDelay.disabled) {
      this.autoSaveDelay.title = this.locale === 'zh-CN'
        ? '仅在自动保存设为“延时保存”时可用'
        : 'Available only when Auto save is set to “After delay”'
    } else {
      this.autoSaveDelay.removeAttribute('title')
    }
  }

  private setOptionLabels(select: HTMLSelectElement, labels: Record<string, string>): void {
    for (const option of select.options) option.textContent = labels[option.value] ?? option.value
  }

  private emit(): void {
    this.callbacks.onChange(this.copy(this.settings))
  }

  private copy(settings: Settings): Settings {
    return { ...settings, rulers: [...settings.rulers], searchHistory: [...settings.searchHistory], replaceHistory: [...settings.replaceHistory] }
  }
}
