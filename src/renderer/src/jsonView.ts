import type { UiLocale } from '../../shared/ipc.js'

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }
type JsonPath = Array<string | number>

export interface JsonStats {
  keys: number
  objects: number
  arrays: number
  values: number
  maxDepth: number
}

export interface JsonViewCallbacks {
  onReplace: (next: string) => void
  notify: (message: string) => void
}

function isRecord(value: JsonValue): value is { [key: string]: JsonValue } {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function statsFor(value: JsonValue): JsonStats {
  const stats: JsonStats = { keys: 0, objects: 0, arrays: 0, values: 0, maxDepth: 0 }
  const visit = (current: JsonValue, depth: number): void => {
    stats.maxDepth = Math.max(stats.maxDepth, depth)
    if (Array.isArray(current)) {
      stats.arrays += 1
      current.forEach((item) => visit(item, depth + 1))
    } else if (isRecord(current)) {
      stats.objects += 1
      const entries = Object.entries(current)
      stats.keys += entries.length
      entries.forEach(([, item]) => visit(item, depth + 1))
    } else stats.values += 1
  }
  visit(value, 0)
  return stats
}

function cloneJson(value: JsonValue): JsonValue {
  return JSON.parse(JSON.stringify(value)) as JsonValue
}

function getContainer(root: JsonValue, path: JsonPath): JsonValue | null {
  let current = root
  for (const part of path) {
    if (Array.isArray(current) && typeof part === 'number') current = current[part]
    else if (isRecord(current) && typeof part === 'string') current = current[part]
    else return null
  }
  return current
}

function parseInput(value: string): JsonValue {
  return JSON.parse(value) as JsonValue
}

function allowProperty(name: string): boolean {
  return name !== '' && !['__proto__', 'prototype', 'constructor'].includes(name)
}

/**
 * Read-only by default JSON tree with focused, explicit operations for editing
 * primitive values and collection structure. All mutations are returned as JSON
 * source, leaving undo/save ownership to the CodeMirror editor.
 */
export class JsonView {
  readonly root: HTMLElement
  private readonly summary: HTMLDivElement
  private readonly tree: HTMLDivElement
  private value: JsonValue | null = null
  private locale: UiLocale = 'zh-CN'
  private parseError = ''

  constructor(private readonly callbacks: JsonViewCallbacks) {
    this.root = document.createElement('aside')
    this.root.className = 'json-view hidden'
    const header = document.createElement('div')
    header.className = 'json-view-header'
    const title = document.createElement('strong')
    title.className = 'json-view-title'
    header.appendChild(title)
    this.summary = document.createElement('div')
    this.summary.className = 'json-view-summary'
    this.tree = document.createElement('div')
    this.tree.className = 'json-view-tree'
    this.root.append(header, this.summary, this.tree)
    this.setLocale(this.locale)
  }

  get visible(): boolean { return !this.root.classList.contains('hidden') }

  setLocale(locale: UiLocale): void {
    this.locale = locale
    const title = this.root.querySelector<HTMLElement>('.json-view-title')
    if (title) title.textContent = locale === 'zh-CN' ? 'JSON 视图' : 'JSON View'
    this.render()
  }

  show(source: string): void {
    this.root.classList.remove('hidden')
    this.update(source)
  }

  hide(): void {
    this.root.classList.add('hidden')
  }

  update(source: string): void {
    if (source.length > 2 * 1024 * 1024) {
      this.value = null
      this.parseError = this.locale === 'zh-CN' ? 'JSON 超过 2 MB，已停止可视化解析。' : 'JSON exceeds 2 MB; visual parsing is disabled.'
      this.render()
      return
    }
    try {
      this.value = parseInput(source)
      this.parseError = ''
    } catch (error) {
      this.value = null
      this.parseError = error instanceof Error ? error.message : String(error)
    }
    this.render()
  }

  private render(): void {
    this.tree.replaceChildren()
    if (this.parseError) {
      this.summary.textContent = this.locale === 'zh-CN' ? `JSON 无法解析：${this.parseError}` : `Invalid JSON: ${this.parseError}`
      this.summary.classList.add('error')
      return
    }
    this.summary.classList.remove('error')
    if (this.value === null) {
      this.summary.textContent = this.locale === 'zh-CN' ? '顶层值：null' : 'Root value: null'
      return
    }
    const stats = statsFor(this.value)
    this.summary.textContent = this.locale === 'zh-CN'
      ? `${stats.keys} 个键 · ${stats.objects} 个对象 · ${stats.arrays} 个数组 · ${stats.values} 个值 · 深度 ${stats.maxDepth}`
      : `${stats.keys} keys · ${stats.objects} objects · ${stats.arrays} arrays · ${stats.values} values · depth ${stats.maxDepth}`
    this.tree.appendChild(this.node(this.value, [], '$'))
  }

  private node(value: JsonValue, path: JsonPath, label: string): HTMLElement {
    const wrapper = document.createElement('div')
    wrapper.className = 'json-node'
    if (Array.isArray(value) || isRecord(value)) {
      const details = document.createElement('details')
      details.open = path.length < 2
      const summary = document.createElement('summary')
      summary.className = 'json-node-summary'
      const type = Array.isArray(value) ? `[${value.length}]` : `{${Object.keys(value).length}}`
      summary.textContent = `${label} ${type}`
      const controls = document.createElement('span')
      controls.className = 'json-node-controls'
      const add = (text: string, onClick: () => void): void => {
        const button = document.createElement('button')
        button.className = 'json-node-button'
        button.textContent = text
        button.addEventListener('click', (event) => { event.preventDefault(); event.stopPropagation(); onClick() })
        controls.appendChild(button)
      }
      if (Array.isArray(value)) add(this.locale === 'zh-CN' ? '+ 项' : '+ Item', () => this.addArrayItem(path))
      else add(this.locale === 'zh-CN' ? '+ 键' : '+ Key', () => this.addObjectKey(path))
      if (path.length > 0) add(this.locale === 'zh-CN' ? '删除' : 'Delete', () => this.remove(path))
      summary.appendChild(controls)
      details.appendChild(summary)
      const children = document.createElement('div')
      children.className = 'json-node-children'
      if (Array.isArray(value)) value.forEach((item, index) => children.appendChild(this.node(item, [...path, index], `[${index}]`)))
      else Object.entries(value).forEach(([key, item]) => children.appendChild(this.node(item, [...path, key], key)))
      details.appendChild(children)
      wrapper.appendChild(details)
      return wrapper
    }

    const row = document.createElement('div')
    row.className = 'json-value-row'
    const key = document.createElement('span')
    key.className = 'json-key'
    key.textContent = label
    const content = document.createElement('button')
    content.className = `json-value json-${value === null ? 'null' : typeof value}`
    content.textContent = typeof value === 'string' ? `"${value}"` : String(value)
    content.title = this.locale === 'zh-CN' ? '点击编辑值' : 'Click to edit value'
    content.addEventListener('click', () => this.editPrimitive(path, value))
    row.append(key, content)
    if (path.length > 0) {
      const remove = document.createElement('button')
      remove.className = 'json-node-button'
      remove.textContent = this.locale === 'zh-CN' ? '删除' : 'Delete'
      remove.addEventListener('click', () => this.remove(path))
      row.appendChild(remove)
    }
    wrapper.appendChild(row)
    return wrapper
  }

  private editPrimitive(path: JsonPath, current: JsonValue): void {
    const prompt = this.locale === 'zh-CN' ? '输入新的 JSON 值（字符串请保留引号）:' : 'Enter a new JSON value (quote strings):'
    const raw = window.prompt(prompt, JSON.stringify(current))
    if (raw === null) return
    try {
      this.mutate((root) => {
        const parent = getContainer(root, path.slice(0, -1))
        const part = path[path.length - 1]
        if (Array.isArray(parent) && typeof part === 'number') parent[part] = parseInput(raw)
        else if (isRecord(parent) && typeof part === 'string') parent[part] = parseInput(raw)
      })
    } catch (error) {
      this.callbacks.notify(this.locale === 'zh-CN' ? `值无效：${error instanceof Error ? error.message : String(error)}` : `Invalid value: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  private addObjectKey(path: JsonPath): void {
    const key = window.prompt(this.locale === 'zh-CN' ? '新键名:' : 'New key name:')
    if (key === null) return
    if (!allowProperty(key)) { this.callbacks.notify(this.locale === 'zh-CN' ? '键名无效或受保护。' : 'Invalid or protected key.') ; return }
    const raw = window.prompt(this.locale === 'zh-CN' ? '新键的 JSON 值:' : 'New key JSON value:', 'null')
    if (raw === null) return
    try {
      this.mutate((root) => {
        const target = getContainer(root, path)
        if (!isRecord(target)) throw new Error('Target is not an object.')
        if (Object.hasOwn(target, key)) throw new Error('Key already exists.')
        Object.defineProperty(target, key, { value: parseInput(raw), enumerable: true, configurable: true, writable: true })
      })
    } catch (error) {
      this.callbacks.notify(this.locale === 'zh-CN' ? `无法添加键：${error instanceof Error ? error.message : String(error)}` : `Could not add key: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  private addArrayItem(path: JsonPath): void {
    const raw = window.prompt(this.locale === 'zh-CN' ? '新数组项的 JSON 值:' : 'New array item JSON value:', 'null')
    if (raw === null) return
    try {
      this.mutate((root) => {
        const target = getContainer(root, path)
        if (!Array.isArray(target)) throw new Error('Target is not an array.')
        target.push(parseInput(raw))
      })
    } catch (error) {
      this.callbacks.notify(this.locale === 'zh-CN' ? `无法添加数组项：${error instanceof Error ? error.message : String(error)}` : `Could not add array item: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  private remove(path: JsonPath): void {
    const prompt = this.locale === 'zh-CN' ? '删除这个 JSON 节点？' : 'Delete this JSON node?'
    if (!window.confirm(prompt)) return
    this.mutate((root) => {
      const parent = getContainer(root, path.slice(0, -1))
      const part = path[path.length - 1]
      if (Array.isArray(parent) && typeof part === 'number') parent.splice(part, 1)
      else if (isRecord(parent) && typeof part === 'string') delete parent[part]
    })
  }

  private mutate(operation: (root: JsonValue) => void): void {
    if (this.value === null) return
    const next = cloneJson(this.value)
    operation(next)
    this.callbacks.onReplace(`${JSON.stringify(next, null, 2)}\n`)
  }
}
