import type { WorkspaceMatch, WorkspaceReplaceRequest, WorkspaceSearchRequest } from '../../shared/ipc.js'
import { baseName } from './documents.js'

export interface WorkspaceSearchCallbacks {
  getRoot: () => string | null
  getRoots: () => string[]
  getProjectExclude: () => string[]
  getSearchHistory: () => string[]
  getReplaceHistory: () => string[]
  openMatch: (match: WorkspaceMatch) => void
  notify: (message: string, error?: unknown) => void
  afterReplace: () => void
  onResults: (query: string, matches: WorkspaceMatch[]) => void
  onReplaceComplete: (undoToken: string | undefined, files: number, replacements: number) => void
  onHistory: (search: string, replacement?: string) => void
}

/**
 * A deliberately focused Find in Files panel. It keeps the familiar Sublime
 * workflow (query, filters, results, optional replace) without coupling search
 * state to the editor view or exposing filesystem access to the renderer.
 */
export class WorkspaceSearchPanel {
  private readonly root: HTMLDivElement
  private readonly query: HTMLInputElement
  private readonly replacement: HTMLInputElement
  private readonly include: HTMLInputElement
  private readonly exclude: HTMLInputElement
  private readonly caseSensitive: HTMLInputElement
  private readonly wholeWord: HTMLInputElement
  private readonly regex: HTMLInputElement
  private readonly results: HTMLUListElement
  private readonly summary: HTMLDivElement
  private readonly searchHistory: HTMLDataListElement
  private readonly replaceHistory: HTMLDataListElement
  private replaceVisible = false
  private searchToken = 0
  private previewReady = false

  constructor(private readonly callbacks: WorkspaceSearchCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'workspace-search hidden'

    const header = document.createElement('div')
    header.className = 'workspace-search-header'
    const title = document.createElement('strong')
    title.textContent = 'Find in Files'
    const close = document.createElement('button')
    close.className = 'panel-button'
    close.textContent = '×'
    close.title = 'Close'
    close.addEventListener('click', () => this.hide())
    header.append(title, close)

    this.query = this.input('Find')
    this.replacement = this.input('Replace')
    this.searchHistory = document.createElement('datalist')
    this.searchHistory.id = 'lumen-workspace-search-history'
    this.replaceHistory = document.createElement('datalist')
    this.replaceHistory.id = 'lumen-workspace-replace-history'
    this.query.setAttribute('list', this.searchHistory.id)
    this.replacement.setAttribute('list', this.replaceHistory.id)
    this.include = this.input('Include: e.g. **/*.ts')
    this.exclude = this.input('Exclude: e.g. **/node_modules/**')

    const options = document.createElement('div')
    options.className = 'workspace-search-options'
    this.caseSensitive = this.checkbox('Case')
    this.wholeWord = this.checkbox('Word')
    this.regex = this.checkbox('Regex')
    options.append(this.caseSensitive.parentElement!, this.wholeWord.parentElement!, this.regex.parentElement!)

    const actions = document.createElement('div')
    actions.className = 'workspace-search-actions'
    const find = this.button('Find All', () => void this.search())
    const replace = this.button('Replace All', () => void this.replace())
    actions.append(find, replace)

    this.summary = document.createElement('div')
    this.summary.className = 'workspace-search-summary'
    this.results = document.createElement('ul')
    this.results.className = 'workspace-search-results'

    this.root.append(header, this.query, this.replacement, this.include, this.exclude, options, actions, this.summary, this.results)
    document.body.append(this.searchHistory, this.replaceHistory)
    document.body.appendChild(this.root)

    this.query.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault()
        void this.search()
      } else if (event.key === 'Escape') {
        this.hide()
      }
    })
    this.root.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') this.hide()
    })
  }

  show(withReplace: boolean): void {
    if (!this.callbacks.getRoot()) {
      this.callbacks.notify('Open a folder before searching across files.')
      return
    }
    this.replaceVisible = withReplace
    this.previewReady = false
    this.setHistory(this.searchHistory, this.callbacks.getSearchHistory())
    this.setHistory(this.replaceHistory, this.callbacks.getReplaceHistory())
    this.root.classList.remove('hidden')
    this.root.classList.toggle('replace-mode', withReplace)
    this.replacement.hidden = !withReplace
    this.query.focus()
    this.query.select()
  }

  hide(): void {
    this.root.classList.add('hidden')
  }

  private input(placeholder: string): HTMLInputElement {
    const input = document.createElement('input')
    input.className = 'workspace-search-input'
    input.placeholder = placeholder
    input.spellcheck = false
    return input
  }

  private checkbox(label: string): HTMLInputElement {
    const labelEl = document.createElement('label')
    const input = document.createElement('input')
    input.type = 'checkbox'
    labelEl.append(input, document.createTextNode(label))
    return input
  }

  private button(label: string, onClick: () => void): HTMLButtonElement {
    const button = document.createElement('button')
    button.className = 'panel-button'
    button.textContent = label
    button.addEventListener('click', onClick)
    return button
  }

  private setHistory(list: HTMLDataListElement, values: string[]): void {
    list.replaceChildren(...values.slice(0, 50).map((value) => {
      const option = document.createElement('option')
      option.value = value
      return option
    }))
  }

  private request(): WorkspaceSearchRequest | null {
    const root = this.callbacks.getRoot()
    const query = this.query.value
    if (!root || !query) return null
    const excludes = [this.exclude.value, ...this.callbacks.getProjectExclude()].filter(Boolean).join(',')
    return {
      root,
      roots: this.callbacks.getRoots(),
      query,
      caseSensitive: this.caseSensitive.checked,
      wholeWord: this.wholeWord.checked,
      useRegex: this.regex.checked,
      include: this.include.value,
      exclude: excludes
    }
  }

  private async search(): Promise<void> {
    const request = this.request()
    if (!request) {
      this.callbacks.notify('Enter a search term first.')
      return
    }
    const token = ++this.searchToken
    this.summary.textContent = 'Searching…'
    this.results.replaceChildren()
    try {
      const matches = await window.editor.searchWorkspace(request)
      if (token !== this.searchToken) return
      this.renderResults(matches)
      this.callbacks.onHistory(request.query)
      this.callbacks.onResults(request.query, matches)
      this.hide()
    } catch (error) {
      if (token === this.searchToken) this.callbacks.notify('Find in Files could not complete.', error)
    }
  }

  private renderResults(matches: WorkspaceMatch[]): void {
    this.summary.textContent = `${matches.length} match${matches.length === 1 ? '' : 'es'}`
    this.results.replaceChildren()
    for (const match of matches) {
      const item = document.createElement('li')
      item.className = 'workspace-search-result'
      const location = document.createElement('div')
      location.className = 'workspace-search-location'
      location.textContent = `${baseName(match.path)}:${match.line}:${match.column}`
      location.title = match.path
      const source = document.createElement('code')
      source.textContent = match.lineText
      item.append(location, source)
      item.addEventListener('click', () => {
        this.callbacks.openMatch(match)
        this.hide()
      })
      this.results.appendChild(item)
    }
  }

  private async replace(): Promise<void> {
    if (!this.replaceVisible) {
      this.show(true)
      return
    }
    const search = this.request()
    if (!search) {
      this.callbacks.notify('Enter a search term first.')
      return
    }
    const request: WorkspaceReplaceRequest = { ...search, replacement: this.replacement.value }
    try {
      if (!this.previewReady) {
        const preview = await window.editor.previewWorkspaceReplace(request)
        this.summary.textContent = `Preview: ${preview.replacements} replacement${preview.replacements === 1 ? '' : 's'} in ${preview.files} file${preview.files === 1 ? '' : 's'}. Click Replace All again to apply.`
        this.renderResults(preview.matches)
        this.callbacks.onResults(`Replace Preview: ${search.query}`, preview.matches)
        this.previewReady = true
        return
      }
      if (!window.confirm(`Apply the previewed replacements for “${search.query}”?`)) return
      const result = await window.editor.replaceWorkspace(request)
      this.summary.textContent = `Replaced ${result.replacements} match${result.replacements === 1 ? '' : 'es'} in ${result.files} file${result.files === 1 ? '' : 's'}.`
      this.results.replaceChildren()
      this.previewReady = false
      this.callbacks.afterReplace()
      this.callbacks.onReplaceComplete(result.undoToken, result.files, result.replacements)
      this.callbacks.onHistory(search.query, this.replacement.value)
    } catch (error) {
      this.callbacks.notify('Replace in Files could not complete.', error)
    }
  }
}
