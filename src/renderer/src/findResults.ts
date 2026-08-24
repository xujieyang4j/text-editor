import type { WorkspaceMatch } from '../../shared/ipc.js'
import { baseName } from './documents.js'

export interface FindResultsCallbacks {
  onOpenMatch: (match: WorkspaceMatch) => void
}

/**
 * A persistent, Sublime-style Find Results buffer. It intentionally lives in
 * its own readonly tab so search output survives closing the search overlay.
 */
export class FindResultsView {
  readonly root: HTMLDivElement
  private readonly list: HTMLUListElement
  private matches: WorkspaceMatch[] = []
  private activeIndex = -1

  constructor(private readonly callbacks: FindResultsCallbacks) {
    this.root = document.createElement('div')
    this.root.className = 'find-results-view hidden'
    const header = document.createElement('div')
    header.className = 'find-results-header'
    header.textContent = 'Find Results'
    this.list = document.createElement('ul')
    this.list.className = 'find-results-list'
    this.root.append(header, this.list)
  }

  setResults(query: string, matches: WorkspaceMatch[]): void {
    this.matches = matches
    this.activeIndex = matches.length > 0 ? 0 : -1
    const header = this.root.querySelector<HTMLElement>('.find-results-header')
    if (header) header.textContent = `Find Results — “${query}” (${matches.length})`
    this.render()
  }

  show(): void { this.root.classList.remove('hidden') }
  hide(): void { this.root.classList.add('hidden') }
  get count(): number { return this.matches.length }

  move(delta: number): WorkspaceMatch | null {
    if (this.matches.length === 0) return null
    this.activeIndex = (this.activeIndex + delta + this.matches.length) % this.matches.length
    this.render()
    const match = this.matches[this.activeIndex]
    this.callbacks.onOpenMatch(match)
    return match
  }

  private render(): void {
    this.list.replaceChildren()
    let lastPath = ''
    this.matches.forEach((match, index) => {
      if (match.path !== lastPath) {
        lastPath = match.path
        const group = document.createElement('li')
        group.className = 'find-results-file'
        group.textContent = match.path
        group.title = match.path
        this.list.appendChild(group)
      }
      const item = document.createElement('li')
      item.className = `find-results-match${index === this.activeIndex ? ' active' : ''}`
      item.textContent = `  ${baseName(match.path)}:${match.line}:${match.column}  ${match.lineText}`
      item.addEventListener('click', () => {
        this.activeIndex = index
        this.render()
        this.callbacks.onOpenMatch(match)
      })
      this.list.appendChild(item)
    })
  }
}
