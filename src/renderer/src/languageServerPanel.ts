import type {
  LanguageServerLogEvent,
  LanguageServerStatusEvent,
  UiLocale
} from '../../shared/ipc.js'

export interface LanguageServerPanelCallbacks {
  onRestart: (key: string) => void | Promise<void>
}

type StoredLogEvent = Pick<LanguageServerLogEvent, 'stream' | 'level' | 'text' | 'timestamp'>

interface StoredLog {
  id: number
  event: StoredLogEvent
  estimatedBytes: number
  omittedTextBytes: number
}

interface LogBucket {
  root: string
  entries: StoredLog[]
  estimatedBytes: number
  discardedEntries: number
  discardedEstimatedBytes: number
}

type StoredStatus = Omit<LanguageServerStatusEvent, 'capabilities'> & {
  /** Bounded display-only summary; never retain the server's raw capability object. */
  capabilities?: string[]
}

type LogScrollMode = 'preserve' | 'follow' | 'end'

interface LogScrollSnapshot {
  serverKey?: string
  scrollTop: number
  atBottom: boolean
  anchorId?: string
  anchorOffset?: number
}

/** A project-independent view of persistent language-server processes and logs. */
export class LanguageServerPanel {
  private static readonly maxLogEntries = 500
  private static readonly maxLogEstimatedBytes = 200 * 1024
  private static readonly maxLogTextBytes = 32 * 1024
  private static readonly maxCapabilityItems = 128
  private static readonly maxCapabilityBytes = 32 * 1024
  private static readonly maxServerBuckets = 64
  private static nextPanelId = 0

  readonly element: HTMLDivElement
  private readonly title: HTMLHeadingElement
  private readonly summary: HTMLSpanElement
  private readonly servicesTitle: HTMLHeadingElement
  private readonly serviceList: HTMLUListElement
  private readonly logTitle: HTMLHeadingElement
  private readonly details: HTMLDivElement
  private readonly logOutput: HTMLDivElement
  private readonly restart: HTMLButtonElement
  private readonly close: HTMLButtonElement
  private readonly onRestart: (key: string) => void | Promise<void>
  private readonly statuses = new Map<string, StoredStatus>()
  private readonly logs = new Map<string, LogBucket>()
  private readonly lastTouched = new Map<string, number>()
  private readonly restartErrors = new Map<string, string>()
  private locale: UiLocale = 'zh-CN'
  private selectedKey: string | null = null
  private previouslyFocused: HTMLElement | null = null
  private visible = false
  private viewDirty = true
  private hasRendered = false
  private touchSequence = 0
  private logSequence = 0
  private restartSequence = 0
  private readonly restartAttempts = new Map<string, number>()

  constructor(callbacks: LanguageServerPanelCallbacks | LanguageServerPanelCallbacks['onRestart']) {
    this.onRestart = typeof callbacks === 'function' ? callbacks : callbacks.onRestart
    const panelId = ++LanguageServerPanel.nextPanelId

    this.element = document.createElement('div')
    this.element.className = 'language-server-panel hidden'
    this.element.setAttribute('role', 'region')
    this.element.setAttribute('aria-hidden', 'true')

    const header = document.createElement('header')
    header.className = 'language-server-panel-header'
    const headingGroup = document.createElement('div')
    headingGroup.className = 'language-server-heading-group'
    this.title = document.createElement('h2')
    this.title.id = `language-server-panel-title-${panelId}`
    this.element.setAttribute('aria-labelledby', this.title.id)
    this.summary = document.createElement('span')
    this.summary.className = 'language-server-summary'
    this.summary.setAttribute('role', 'status')
    this.summary.setAttribute('aria-live', 'polite')
    this.summary.setAttribute('aria-atomic', 'true')
    headingGroup.append(this.title, this.summary)

    const actions = document.createElement('div')
    actions.className = 'language-server-actions'
    this.restart = this.button('', () => { void this.restartSelected() })
    this.restart.classList.add('language-server-restart')
    this.restart.disabled = true
    this.close = this.button('×', () => this.toggle(false))
    this.close.classList.add('language-server-close')
    actions.append(this.restart, this.close)
    header.append(headingGroup, actions)

    const body = document.createElement('div')
    body.className = 'language-server-panel-body'
    const services = document.createElement('section')
    services.className = 'language-server-services'
    this.servicesTitle = document.createElement('h3')
    this.servicesTitle.id = `language-server-services-title-${panelId}`
    this.serviceList = document.createElement('ul')
    this.serviceList.className = 'language-server-list'
    this.serviceList.setAttribute('role', 'listbox')
    this.serviceList.setAttribute('aria-labelledby', this.servicesTitle.id)
    this.serviceList.addEventListener('keydown', (event) => this.navigateServices(event))
    services.append(this.servicesTitle, this.serviceList)

    const logSection = document.createElement('section')
    logSection.className = 'language-server-log-section'
    this.logTitle = document.createElement('h3')
    this.logTitle.id = `language-server-log-title-${panelId}`
    this.details = document.createElement('div')
    this.details.className = 'language-server-details'
    this.logOutput = document.createElement('div')
    this.logOutput.className = 'language-server-log'
    this.logOutput.tabIndex = 0
    this.logOutput.setAttribute('role', 'log')
    this.logOutput.setAttribute('aria-labelledby', this.logTitle.id)
    this.logOutput.setAttribute('aria-live', 'off')
    this.logOutput.setAttribute('aria-atomic', 'false')
    logSection.append(this.logTitle, this.details, this.logOutput)
    body.append(services, logSection)

    this.element.append(header, body)
    this.element.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      event.stopPropagation()
      this.toggle(false)
    })

    this.setLocale(this.locale)
  }

  get isVisible(): boolean {
    return this.visible
  }

  toggle(show = !this.visible): void {
    if (show === this.visible) {
      if (show && !this.element.contains(document.activeElement)) this.focusPanel()
      return
    }

    const focusWasWithinPanel = this.element.contains(document.activeElement)
    if (show) {
      const active = document.activeElement
      this.previouslyFocused = active instanceof HTMLElement && !this.element.contains(active) ? active : null
    }
    this.visible = show
    this.element.classList.toggle('hidden', !show)
    this.element.setAttribute('aria-hidden', String(!show))

    if (show) {
      if (this.viewDirty || !this.hasRendered) this.renderView(this.hasRendered ? 'follow' : 'end')
      this.focusPanel()
      return
    }

    const focusTarget = this.previouslyFocused
    this.previouslyFocused = null
    if (focusWasWithinPanel) this.restoreFocus(focusTarget)
  }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    this.viewDirty = true
    // Locale changes are infrequent. Render once even while hidden so the
    // mounted accessibility shell always has complete, non-empty text.
    this.renderView('preserve')
  }

  updateStatus(status: LanguageServerStatusEvent): void {
    const { capabilities, ...metadata } = status
    this.statuses.set(status.key, {
      key: metadata.key,
      root: metadata.root,
      command: metadata.command,
      state: metadata.state,
      ...(metadata.pid === undefined ? {} : { pid: metadata.pid }),
      ...(metadata.message === undefined ? {} : { message: metadata.message }),
      capabilities: this.sanitizeCapabilities(capabilities)
    })
    this.touch(status.key)
    if (status.state === 'starting' || status.state === 'running') this.restartErrors.delete(status.key)
    if (this.selectedKey === null) this.selectedKey = status.key
    this.enforceServerLimit()
    this.viewDirty = true
    // A status-only update must not move a reader away from their current log position.
    if (this.visible) this.renderView('preserve')
  }

  appendLog(log: LanguageServerLogEvent): void {
    const truncated = this.truncateLogText(log.text)
    const event: StoredLogEvent = {
      stream: log.stream,
      level: log.level,
      text: truncated.text,
      timestamp: log.timestamp
    }
    const stored: StoredLog = {
      id: ++this.logSequence,
      event,
      estimatedBytes: this.estimateStoredLogBytes(event),
      omittedTextBytes: truncated.omittedBytes
    }
    let bucket = this.logs.get(log.key)
    if (!bucket) {
      bucket = {
        root: log.root,
        entries: [],
        estimatedBytes: this.estimateBucketBytes(log.key, log.root),
        discardedEntries: 0,
        discardedEstimatedBytes: 0
      }
      this.logs.set(log.key, bucket)
    } else {
      bucket.estimatedBytes += (log.root.length - bucket.root.length) * 2
      bucket.root = log.root
    }
    bucket.entries.push(stored)
    bucket.estimatedBytes += stored.estimatedBytes
    const removedIds: number[] = []
    while (
      bucket.entries.length > LanguageServerPanel.maxLogEntries ||
      bucket.estimatedBytes > LanguageServerPanel.maxLogEstimatedBytes
    ) {
      const discarded = bucket.entries.shift()
      if (!discarded) break
      bucket.estimatedBytes -= discarded.estimatedBytes
      bucket.discardedEntries += 1
      bucket.discardedEstimatedBytes += discarded.estimatedBytes
      removedIds.push(discarded.id)
    }
    this.touch(log.key)
    const evicted = this.enforceServerLimit()
    this.viewDirty = true

    if (!this.visible) return
    if (evicted) {
      this.renderView('follow')
      return
    }
    if (this.selectedKey !== log.key) {
      this.viewDirty = false
      return
    }
    if (this.logOutput.dataset.serverKey !== log.key || bucket.entries.at(-1)?.id !== stored.id) {
      this.renderView('follow')
      return
    }

    const scroll = this.captureLogScroll()
    this.logOutput.querySelector('.language-server-log-empty')?.remove()
    for (const id of removedIds) {
      this.logOutput.querySelector<HTMLElement>(`[data-log-id=\"${id}\"]`)?.remove()
    }
    this.syncTotalTruncationSentinel(bucket)
    this.logOutput.appendChild(this.createLogEntry(stored))
    this.restoreLogScroll(scroll, 'follow', log.key)
    this.viewDirty = false
  }

  /** Drop all status and log state associated with one server process. */
  remove(key: string): boolean {
    const removed = this.deleteServer(key)
    if (!removed) return false
    this.repairSelection()
    this.viewDirty = true
    if (this.visible) this.renderView('preserve')
    return true
  }

  /** Drop retained processes and logs when a workspace root leaves the session. */
  clearRoot(root: string): number {
    const keys = this.serverKeys().filter((key) =>
      this.statuses.get(key)?.root === root || this.logs.get(key)?.root === root)
    for (const key of keys) this.deleteServer(key)
    if (keys.length === 0) return 0
    this.repairSelection()
    this.viewDirty = true
    if (this.visible) this.renderView('preserve')
    return keys.length
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
  }

  private renderView(scrollMode: LogScrollMode): void {
    const scroll = this.captureLogScroll()
    const zh = this.locale === 'zh-CN'
    this.title.textContent = zh ? '语言服务器' : 'Language Servers'
    this.servicesTitle.textContent = zh ? '服务器' : 'Servers'
    this.close.title = zh ? '关闭语言服务器面板' : 'Close language server panel'
    this.close.setAttribute('aria-label', this.close.title)
    this.repairSelection()
    this.renderSummary()
    this.renderServices()
    this.renderSelectedService()
    this.restoreLogScroll(scroll, scrollMode, this.selectedKey)
    this.hasRendered = true
    this.viewDirty = false
  }

  private renderSummary(): void {
    const total = this.statuses.size
    const running = [...this.statuses.values()].filter((status) => status.state === 'running').length
    this.summary.textContent = this.locale === 'zh-CN'
      ? `${total} 个服务器，${running} 个运行中`
      : `${total} ${total === 1 ? 'server' : 'servers'}, ${running} running`
  }

  private renderServices(): void {
    const focusedKey = document.activeElement instanceof HTMLElement
      ? document.activeElement.dataset.serverKey
      : undefined
    this.serviceList.replaceChildren()

    if (this.statuses.size === 0) {
      const empty = document.createElement('li')
      empty.className = 'language-server-empty'
      empty.textContent = this.locale === 'zh-CN' ? '没有语言服务器' : 'No language servers'
      this.serviceList.appendChild(empty)
      this.updateRestartButton()
      return
    }

    for (const status of this.statuses.values()) {
      const item = document.createElement('li')
      item.className = 'language-server-item'
      item.dataset.serverKey = status.key
      item.dataset.state = status.state
      item.tabIndex = status.key === this.selectedKey ? 0 : -1
      item.setAttribute('role', 'option')
      item.setAttribute('aria-selected', String(status.key === this.selectedKey))

      const primary = document.createElement('div')
      primary.className = 'language-server-item-primary'
      const command = document.createElement('span')
      command.className = 'language-server-command'
      command.textContent = status.command
      const state = document.createElement('span')
      state.className = 'language-server-state'
      state.textContent = this.stateLabel(status.state)
      primary.append(command, state)

      const secondary = document.createElement('div')
      secondary.className = 'language-server-item-secondary'
      secondary.textContent = status.pid === undefined ? status.root : `${status.root} · PID ${status.pid}`
      item.append(primary, secondary)
      if (status.message) {
        const message = document.createElement('div')
        message.className = 'language-server-item-message'
        message.textContent = status.message
        item.appendChild(message)
      }
      item.title = [status.command, status.root, this.stateLabel(status.state), status.message].filter(Boolean).join(' — ')
      item.addEventListener('click', () => {
        this.selectService(status.key)
        item.focus()
      })
      item.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        event.stopPropagation()
        this.selectService(status.key)
      })
      this.serviceList.appendChild(item)
    }
    this.updateRestartButton()

    if (focusedKey) {
      const focused = [...this.serviceList.querySelectorAll<HTMLElement>('[role="option"]')]
        .find((item) => item.dataset.serverKey === focusedKey)
      focused?.focus()
    }
  }

  private selectService(key: string): void {
    if (!this.statuses.has(key)) return
    this.selectedKey = key
    for (const item of this.serviceList.querySelectorAll<HTMLElement>('[role="option"]')) {
      const selected = item.dataset.serverKey === key
      item.tabIndex = selected ? 0 : -1
      item.setAttribute('aria-selected', String(selected))
    }
    this.updateRestartButton()
    this.renderSelectedService()
    this.restoreLogScroll(undefined, 'end', key)
  }

  private renderSelectedService(): void {
    const status = this.selectedKey === null ? undefined : this.statuses.get(this.selectedKey)
    if (!status) {
      this.logTitle.textContent = this.locale === 'zh-CN' ? '日志' : 'Logs'
      this.details.textContent = this.locale === 'zh-CN' ? '选择服务器以查看日志。' : 'Select a server to view its logs.'
      this.updateRestartButton()
      this.renderLogs()
      return
    }

    this.logTitle.textContent = `${this.locale === 'zh-CN' ? '日志' : 'Logs'} — ${status.command}`
    this.details.replaceChildren()
    this.details.appendChild(this.detailRow(this.locale === 'zh-CN' ? '工作区' : 'Workspace', status.root))
    this.details.appendChild(this.detailRow(this.locale === 'zh-CN' ? '状态' : 'Status', this.stateLabel(status.state)))
    if (status.pid !== undefined) this.details.appendChild(this.detailRow('PID', String(status.pid)))
    const capabilities = this.capabilityText(status.capabilities)
    if (capabilities) {
      this.details.appendChild(this.detailRow(this.locale === 'zh-CN' ? '能力' : 'Capabilities', capabilities))
    }
    if (status.message) {
      this.details.appendChild(this.detailRow(this.locale === 'zh-CN' ? '消息' : 'Message', status.message))
    }
    const restartError = this.restartErrors.get(status.key)
    if (restartError) {
      const row = this.detailRow(this.locale === 'zh-CN' ? '重启失败' : 'Restart failed', restartError)
      row.classList.add('language-server-restart-error')
      row.setAttribute('role', 'alert')
      this.details.appendChild(row)
    }
    this.updateRestartButton()
    this.renderLogs()
  }

  private detailRow(labelText: string, valueText: string): HTMLDivElement {
    const row = document.createElement('div')
    row.className = 'language-server-detail-row'
    const label = document.createElement('span')
    label.className = 'language-server-detail-label'
    label.textContent = `${labelText}:`
    const value = document.createElement('span')
    value.className = 'language-server-detail-value'
    value.textContent = valueText
    row.append(label, value)
    return row
  }

  private renderLogs(): void {
    this.logOutput.replaceChildren()
    const key = this.selectedKey
    if (key === null || !this.statuses.has(key)) {
      delete this.logOutput.dataset.serverKey
      const empty = document.createElement('div')
      empty.className = 'language-server-log-empty'
      empty.textContent = this.locale === 'zh-CN' ? '未选择服务器' : 'No server selected'
      this.logOutput.appendChild(empty)
      return
    }

    this.logOutput.dataset.serverKey = key
    const bucket = this.logs.get(key)
    const entries = bucket?.entries ?? []
    if (bucket?.discardedEntries) this.syncTotalTruncationSentinel(bucket)
    if (entries.length === 0) {
      const empty = document.createElement('div')
      empty.className = 'language-server-log-empty'
      empty.textContent = this.locale === 'zh-CN' ? '暂无日志' : 'No logs yet'
      this.logOutput.appendChild(empty)
      return
    }
    for (const entry of entries) this.logOutput.appendChild(this.createLogEntry(entry))
  }

  private createLogEntry(stored: StoredLog): HTMLDivElement {
    const log = stored.event
    const row = document.createElement('div')
    row.className = `language-server-log-entry ${log.level}`
    row.dataset.logId = String(stored.id)
    const metadata = document.createElement('span')
    metadata.className = 'language-server-log-meta'
    metadata.textContent = `[${this.formatTimestamp(log.timestamp)}] [${this.streamLabel(log.stream)}/${this.levelLabel(log.level)}]`
    const content = document.createElement('span')
    content.className = 'language-server-log-content'
    if (stored.omittedTextBytes > 0) {
      const sentinel = document.createElement('span')
      sentinel.className = 'language-server-log-truncated'
      sentinel.textContent = this.locale === 'zh-CN'
        ? `［本条日志前部已截断，省略 ${this.formatCount(stored.omittedTextBytes)} 字节］`
        : `[Earlier text truncated; ${this.formatCount(stored.omittedTextBytes)} bytes omitted]`
      content.appendChild(sentinel)
    }
    const text = document.createElement('span')
    text.className = 'language-server-log-text'
    text.textContent = log.text
    content.appendChild(text)
    row.append(metadata, content)
    return row
  }

  private syncTotalTruncationSentinel(bucket: LogBucket): void {
    let sentinel = this.logOutput.querySelector<HTMLElement>('.language-server-log-truncation-summary')
    if (bucket.discardedEntries === 0) {
      sentinel?.remove()
      return
    }
    if (!sentinel) {
      sentinel = document.createElement('div')
      sentinel.className = 'language-server-log-truncation-summary'
      sentinel.setAttribute('role', 'note')
      this.logOutput.prepend(sentinel)
    }
    const count = this.formatCount(bucket.discardedEntries)
    const memory = this.formatBytes(bucket.discardedEstimatedBytes)
    sentinel.textContent = this.locale === 'zh-CN'
      ? `较早的 ${count} 条日志已因上限被丢弃（估算 ${memory}）`
      : `${count} earlier log ${bucket.discardedEntries === 1 ? 'entry was' : 'entries were'} discarded at the limit (estimated ${memory})`
  }

  private async restartSelected(): Promise<void> {
    const key = this.selectedKey
    const status = key === null ? undefined : this.statuses.get(key)
    if (!key || !status || this.restartAttempts.has(key) || status.state === 'starting' || status.state === 'stopping') return

    const token = ++this.restartSequence
    this.restartAttempts.set(key, token)
    this.restartErrors.delete(key)
    this.viewDirty = true
    if (this.visible) this.renderView('preserve')

    try {
      await this.onRestart(key)
    } catch (error) {
      if (this.restartAttempts.get(key) !== token) return
      this.restartErrors.set(key, this.errorMessage(error))
    } finally {
      if (this.restartAttempts.get(key) !== token) return
      this.restartAttempts.delete(key)
      this.viewDirty = true
      if (this.visible) this.renderView('preserve')
    }
  }

  private updateRestartButton(): void {
    const status = this.selectedKey === null ? undefined : this.statuses.get(this.selectedKey)
    const busy = status ? this.restartAttempts.has(status.key) : false
    const transitioning = status?.state === 'starting' || status?.state === 'stopping'
    const zh = this.locale === 'zh-CN'
    this.restart.disabled = !status || busy || transitioning
    this.restart.textContent = busy ? (zh ? '正在重启…' : 'Restarting…') : (zh ? '重启' : 'Restart')
    this.restart.title = transitioning
      ? (zh ? '请等待语言服务器完成状态切换' : 'Wait for the language server to finish changing state')
      : busy
        ? (zh ? '正在重启语言服务器' : 'Restarting language server')
        : (zh ? '重启选中的语言服务器' : 'Restart selected language server')
    this.restart.setAttribute('aria-label', this.restart.title)
    this.restart.setAttribute('aria-busy', String(busy))
  }

  private captureLogScroll(): LogScrollSnapshot | undefined {
    if (!this.hasRendered || !this.logOutput.dataset.serverKey) return undefined
    const scrollTop = this.logOutput.scrollTop
    const snapshot: LogScrollSnapshot = {
      serverKey: this.logOutput.dataset.serverKey,
      scrollTop,
      atBottom: this.isLogAtBottom()
    }
    const entries = this.logOutput.querySelectorAll<HTMLElement>('[data-log-id]')
    for (const entry of entries) {
      if (entry.offsetTop + entry.offsetHeight < scrollTop) continue
      snapshot.anchorId = entry.dataset.logId
      snapshot.anchorOffset = entry.offsetTop - scrollTop
      break
    }
    return snapshot
  }

  private restoreLogScroll(
    snapshot: LogScrollSnapshot | undefined,
    mode: LogScrollMode,
    serverKey: string | null
  ): void {
    if (mode === 'end' || !snapshot || snapshot.serverKey !== serverKey) {
      this.logOutput.scrollTop = this.logOutput.scrollHeight
      return
    }
    if (mode === 'follow' && snapshot.atBottom) {
      this.logOutput.scrollTop = this.logOutput.scrollHeight
      return
    }
    const anchor = snapshot.anchorId === undefined
      ? null
      : this.logOutput.querySelector<HTMLElement>(`[data-log-id=\"${snapshot.anchorId}\"]`)
    this.logOutput.scrollTop = anchor && snapshot.anchorOffset !== undefined
      ? anchor.offsetTop - snapshot.anchorOffset
      : snapshot.scrollTop
  }

  private touch(key: string): void {
    this.lastTouched.set(key, ++this.touchSequence)
  }

  private enforceServerLimit(): boolean {
    let keys = this.serverKeys()
    let evicted = false
    while (keys.length > LanguageServerPanel.maxServerBuckets) {
      keys.sort((left, right) => {
        const rank = (key: string): number => {
          const state = this.statuses.get(key)?.state
          const terminal = state === undefined || state === 'stopped' || state === 'error'
          return (terminal ? 0 : 2) + (key === this.selectedKey ? 1 : 0)
        }
        return rank(left) - rank(right) || (this.lastTouched.get(left) ?? 0) - (this.lastTouched.get(right) ?? 0)
      })
      const victim = keys.shift()
      if (!victim) break
      this.deleteServer(victim)
      evicted = true
    }
    if (evicted) this.repairSelection()
    return evicted
  }

  private serverKeys(): string[] {
    return [...new Set([...this.statuses.keys(), ...this.logs.keys()])]
  }

  private deleteServer(key: string): boolean {
    const removedStatus = this.statuses.delete(key)
    const removedLog = this.logs.delete(key)
    this.lastTouched.delete(key)
    this.restartErrors.delete(key)
    this.restartAttempts.delete(key)
    return removedStatus || removedLog
  }

  private repairSelection(): void {
    if (this.selectedKey !== null && this.statuses.has(this.selectedKey)) return
    this.selectedKey = this.statuses.keys().next().value ?? null
  }

  private estimateStoredLogBytes(log: StoredLogEvent): number {
    const timestampBytes = typeof log.timestamp === 'string' ? log.timestamp.length * 2 : 8
    // Includes the entry/event objects, array slot, numeric fields and retained UTF-16 text.
    return 192 + timestampBytes + log.text.length * 2
  }

  private estimateBucketBytes(key: string, root: string): number {
    // Includes map entries, bucket/array objects, counters and retained UTF-16 identifiers.
    return 256 + (key.length + root.length) * 2
  }

  private formatCount(value: number): string {
    return new Intl.NumberFormat(this.locale).format(value)
  }

  private formatBytes(value: number): string {
    if (value < 1024) return this.locale === 'zh-CN' ? `${value} 字节` : `${value} B`
    return `${new Intl.NumberFormat(this.locale, { maximumFractionDigits: 1 }).format(value / 1024)} KiB`
  }

  private errorMessage(error: unknown): string {
    if (error instanceof Error && error.message) return error.message
    if (typeof error === 'string' && error) return error
    return this.locale === 'zh-CN' ? '未知错误' : 'Unknown error'
  }

  private navigateServices(event: KeyboardEvent): void {
    const items = [...this.serviceList.querySelectorAll<HTMLElement>('[role="option"]')]
    if (items.length === 0) return
    const focused = items.indexOf(document.activeElement as HTMLElement)
    let next = focused >= 0 ? focused : Math.max(0, items.findIndex((item) => item.dataset.serverKey === this.selectedKey))
    if (event.key === 'ArrowDown') next = Math.min(items.length - 1, next + 1)
    else if (event.key === 'ArrowUp') next = Math.max(0, next - 1)
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = items.length - 1
    else return
    event.preventDefault()
    event.stopPropagation()
    const key = items[next].dataset.serverKey
    if (key) this.selectService(key)
    items[next].focus()
  }

  private focusPanel(): void {
    const selected = [...this.serviceList.querySelectorAll<HTMLElement>('[role="option"]')]
      .find((item) => item.dataset.serverKey === this.selectedKey)
    ;(selected ?? this.close).focus()
  }

  private restoreFocus(preferred: HTMLElement | null): void {
    const candidates = [
      preferred,
      ...document.querySelectorAll<HTMLElement>('.cm-content, [contenteditable="true"], button, input, select, textarea, [tabindex]:not([tabindex="-1"])')
    ]
    const target = candidates.find((candidate): candidate is HTMLElement =>
      candidate instanceof HTMLElement && candidate.isConnected && !this.element.contains(candidate) &&
      !candidate.matches(':disabled') && !candidate.closest('.hidden, [hidden], [aria-hidden="true"], [inert]'))
    target?.focus()
  }

  private stateLabel(state: LanguageServerStatusEvent['state']): string {
    const labels: Record<LanguageServerStatusEvent['state'], [string, string]> = {
      starting: ['正在启动', 'Starting'],
      running: ['运行中', 'Running'],
      stopping: ['正在停止', 'Stopping'],
      stopped: ['已停止', 'Stopped'],
      error: ['错误', 'Error']
    }
    return labels[state][this.locale === 'zh-CN' ? 0 : 1]
  }

  private streamLabel(stream: LanguageServerLogEvent['stream']): string {
    if (stream === 'stderr') return this.locale === 'zh-CN' ? '标准错误' : 'stderr'
    return this.locale === 'zh-CN' ? '服务器' : 'server'
  }

  private levelLabel(level: LanguageServerLogEvent['level']): string {
    const labels: Record<LanguageServerLogEvent['level'], [string, string]> = {
      info: ['信息', 'info'],
      warning: ['警告', 'warning'],
      error: ['错误', 'error']
    }
    return labels[level][this.locale === 'zh-CN' ? 0 : 1]
  }

  private sanitizeCapabilities(capabilities: unknown): string[] | undefined {
    const summary: string[] = []
    let bytes = 0
    const append = (value: string): boolean => {
      if (summary.length >= LanguageServerPanel.maxCapabilityItems) return false
      const separatorBytes = summary.length === 0 ? 0 : 2
      const remaining = LanguageServerPanel.maxCapabilityBytes - bytes - separatorBytes
      if (remaining <= 0) return false
      const bounded = this.truncateUtf8Prefix(value, remaining)
      if (!bounded) return false
      summary.push(bounded)
      bytes += separatorBytes + this.utf8Bytes(bounded)
      return bounded === value
    }

    if (typeof capabilities === 'string') append(capabilities)
    else if (Array.isArray(capabilities)) {
      for (const capability of capabilities) {
        if (typeof capability === 'string' && !append(capability)) break
      }
    } else if (capabilities && typeof capabilities === 'object') {
      for (const name in capabilities) {
        if (!Object.prototype.hasOwnProperty.call(capabilities, name)) continue
        if (!append(name)) break
      }
    }
    return summary.length > 0 ? summary : undefined
  }

  private capabilityText(capabilities: string[] | undefined): string {
    return capabilities?.join(', ') ?? ''
  }

  private truncateUtf8Prefix(text: string, maxBytes: number): string {
    let bytes = 0
    let end = 0
    while (end < text.length) {
      const codePoint = text.codePointAt(end)
      if (codePoint === undefined) break
      const width = codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4
      if (bytes + width > maxBytes) break
      bytes += width
      end += codePoint > 0xffff ? 2 : 1
    }
    return text.slice(0, end)
  }

  private formatTimestamp(timestamp: number | string): string {
    const date = new Date(timestamp)
    if (Number.isNaN(date.getTime())) return String(timestamp)
    const part = (value: number): string => String(value).padStart(2, '0')
    return `${part(date.getHours())}:${part(date.getMinutes())}:${part(date.getSeconds())}`
  }

  private truncateLogText(text: string): { text: string; omittedBytes: number } {
    const originalBytes = this.utf8Bytes(text)
    if (originalBytes <= LanguageServerPanel.maxLogTextBytes) return { text, omittedBytes: 0 }
    const budget = LanguageServerPanel.maxLogTextBytes
    let bytes = 0
    let start = text.length
    while (start > 0) {
      let next = start - 1
      const lastUnit = text.charCodeAt(next)
      if (lastUnit >= 0xdc00 && lastUnit <= 0xdfff && next > 0) {
        const firstUnit = text.charCodeAt(next - 1)
        if (firstUnit >= 0xd800 && firstUnit <= 0xdbff) --next
      }
      const charBytes = this.utf8Bytes(text.slice(next, start))
      if (bytes + charBytes > budget) break
      bytes += charBytes
      start = next
    }
    return { text: text.slice(start), omittedBytes: originalBytes - bytes }
  }

  private utf8Bytes(text: string): number {
    let bytes = 0
    for (let index = 0; index < text.length; ++index) {
      const code = text.charCodeAt(index)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
        const next = text.charCodeAt(index + 1)
        if (next >= 0xdc00 && next <= 0xdfff) {
          bytes += 4
          ++index
        } else bytes += 3
      } else bytes += 3
    }
    return bytes
  }

  private isLogAtBottom(): boolean {
    return this.logOutput.scrollHeight - this.logOutput.scrollTop - this.logOutput.clientHeight < 24
  }
}
