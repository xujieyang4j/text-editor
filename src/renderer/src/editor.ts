import { EditorState, Compartment, EditorSelection, type Extension, type SelectionRange } from '@codemirror/state'
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
  type ViewUpdate
} from '@codemirror/view'
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  moveLineUp,
  moveLineDown,
  copyLineUp,
  copyLineDown,
  deleteLine,
  toggleComment,
  indentMore,
  indentLess
} from '@codemirror/commands'
import {
  indentOnInput,
  indentUnit,
  bracketMatching,
  foldGutter,
  foldKeymap,
  syntaxHighlighting,
  defaultHighlightStyle,
  type LanguageSupport,
  type LanguageDescription
} from '@codemirror/language'
import { languages } from '@codemirror/language-data'
import {
  searchKeymap,
  highlightSelectionMatches,
  openSearchPanel,
  gotoLine,
  getSearchQuery,
  setSearchQuery,
  SearchQuery
} from '@codemirror/search'
import {
  autocompletion,
  completionKeymap,
  closeBrackets,
  closeBracketsKeymap,
  type CompletionContext,
  type Completion
} from '@codemirror/autocomplete'
import { oneDark } from '@codemirror/theme-one-dark'
import { showMinimap } from '@replit/codemirror-minimap'
import { setDiagnostics, lintGutter, type Diagnostic } from '@codemirror/lint'
import { indentationMarkers } from '@replit/codemirror-indentation-markers'
import { rulers } from './extensions/rulers.js'
import { highlightTrailingWhitespace } from './extensions/trailingWhitespace.js'
import type { Settings, ColorScheme } from '../../shared/ipc.js'

/** Callbacks the editor emits so the shell can update tabs/status bar. */
export interface EditorCallbacks {
  onDocChange: () => void
  onCursorChange: (state: EditorState) => void
  onCompletion?: (context: CompletionContext) => Promise<Completion[] | null>
  onTab?: () => boolean
}

/** Compartments allow reconfiguring parts of the editor without a full reset. */
const languageConf = new Compartment()
const themeConf = new Compartment()
const wrapConf = new Compartment()
const tabConf = new Compartment()
const minimapConf = new Compartment()
const indentGuideConf = new Compartment()
const trailingWsConf = new Compartment()
const rulerConf = new Compartment()
const fontThemeConf = new Compartment()

/** Minimap mounted into a container we create on the right edge of the editor. */
function minimapExtension(): Extension {
  return showMinimap.compute([], () => ({
    create: () => {
      const dom = document.createElement('div')
      return { dom }
    },
    displayText: 'blocks',
    showOverlay: 'always'
  }))
}

/** Build a theme that only sets the editor font size (px). */
function fontTheme(fontSize: number): Extension {
  return EditorView.theme({
    '&': { fontSize: `${fontSize}px` }
  })
}

function colorSchemeTheme(scheme: ColorScheme): Extension {
  if (scheme === 'light') return EditorView.theme({
    '&': { backgroundColor: '#ffffff', color: '#24292f' },
    '.cm-content': { caretColor: '#0969da' },
    '.cm-gutters': { backgroundColor: '#f6f8fa', color: '#57606a', border: 'none' }
  }, { dark: false })
  if (scheme === 'solarized-dark') return EditorView.theme({
    '&': { backgroundColor: '#002b36', color: '#93a1a1' },
    '.cm-content': { caretColor: '#b58900' },
    '.cm-gutters': { backgroundColor: '#073642', color: '#839496', border: 'none' },
    '.cm-activeLine': { backgroundColor: '#073642' }
  }, { dark: true })
  if (scheme === 'dracula') return EditorView.theme({
    '&': { backgroundColor: '#282a36', color: '#f8f8f2' },
    '.cm-content': { caretColor: '#ff79c6' },
    '.cm-gutters': { backgroundColor: '#282a36', color: '#6272a4', border: 'none' },
    '.cm-activeLine': { backgroundColor: '#44475a' }
  }, { dark: true })
  return oneDark
}

/** Base set of extensions shared by every document. */
function baseExtensions(
  callbacks: EditorCallbacks,
  onUpdate: (update: ViewUpdate) => void
): Extension {
  return [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    history(),
    foldGutter(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    bracketMatching(),
    closeBrackets(),
    autocompletion(callbacks.onCompletion ? {
      override: [async (context) => {
        const options = await callbacks.onCompletion!(context)
        if (!options || options.length === 0) return null
        const token = context.matchBefore(/[\w$]*/)
        return { from: token?.from ?? context.pos, options }
      }]
    } : {}),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    keymap.of([
      ...closeBracketsKeymap,
      ...defaultKeymap,
      ...searchKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...completionKeymap,
      indentWithTab
    ]),
    EditorView.updateListener.of((update: ViewUpdate) => {
      if (update.docChanged) callbacks.onDocChange()
      if (update.selectionSet || update.docChanged) callbacks.onCursorChange(update.state)
      onUpdate(update)
    })
  ]
}

/**
 * A thin wrapper around a CodeMirror {@link EditorView} that manages the
 * document swap plus every reconfigurable feature (language, theme, wrap,
 * tab size, minimap, indent guides, rulers, font size) for a single pane.
 */
export class Editor {
  readonly view: EditorView
  private callbacks: EditorCallbacks
  private settings: Settings
  /** In-flight language loads are versioned so stale tabs cannot reconfigure the active view. */
  private languageRequest = 0
  private snippetRanges: Array<{ from: number; to: number; index: number }> = []
  private snippetCursor = -1
  private snippetFinalPos: number | null = null
  private applyingSnippetMirror = false

  constructor(parent: HTMLElement, callbacks: EditorCallbacks, settings: Settings) {
    this.callbacks = callbacks
    this.settings = settings
    this.view = new EditorView({
      parent,
      state: this.makeState('')
    })
    this.view.dom.addEventListener('keydown', (event) => {
      if (event.key !== 'Tab') return
      if (this.snippetRanges.length > 0) {
        event.preventDefault()
        this.nextSnippetPlaceholder(event.shiftKey ? -1 : 1)
      } else if (this.callbacks.onTab?.()) {
        event.preventDefault()
      }
    }, true)
  }

  /** Build a fresh EditorState for the given document text. */
  private makeState(doc: string): EditorState {
    const s = this.settings
    const indent = s.insertSpaces ? ' '.repeat(s.tabSize) : '\t'
    return EditorState.create({
      doc,
      extensions: [
        baseExtensions(this.callbacks, (update) => this.mapSnippetRanges(update)),
        languageConf.of([]),
        themeConf.of(colorSchemeTheme(s.colorScheme)),
        wrapConf.of(s.wordWrap ? EditorView.lineWrapping : []),
        tabConf.of([indentUnit.of(indent), EditorState.tabSize.of(s.tabSize)]),
        minimapConf.of(s.showMinimap ? minimapExtension() : []),
        indentGuideConf.of(s.showIndentGuides ? indentationMarkers() : []),
        trailingWsConf.of(s.highlightTrailingWhitespace ? highlightTrailingWhitespace() : []),
        rulerConf.of(rulers(s.rulers)),
        fontThemeConf.of(fontTheme(s.fontSize)),
        lintGutter()
      ]
    })
  }

  /** Replace the entire document (used when switching tabs). */
  setDocument(doc: string, state?: EditorState): void {
    this.clearSnippet()
    this.view.setState(state ?? this.makeState(doc))
  }

  /** Replace document text without discarding extensions, undo history or folds. */
  replaceContent(doc: string): void {
    this.clearSnippet()
    const state = this.view.state
    this.view.dispatch({ changes: { from: 0, to: state.doc.length, insert: doc }, userEvent: 'input.replace' })
  }

  /** Snapshot the complete CM state so a tab keeps undo, selection and folds. */
  getState(): EditorState {
    return this.view.state
  }

  /** Current document text. */
  getContent(): string {
    return this.view.state.doc.toString()
  }

  /** Reconfigure syntax highlighting for a file name/extension. */
  async setLanguageForFile(fileName: string): Promise<string> {
    const desc = fileName ? matchLanguage(fileName) : null
    return this.applyLanguage(desc)
  }

  /** Reconfigure syntax highlighting by language display name (manual pick). */
  async setLanguageByName(name: string): Promise<string> {
    if (name === 'Plain Text') return this.applyLanguage(null)
    const desc = languages.find((l) => l.name === name) ?? null
    return this.applyLanguage(desc)
  }

  /** Load + install a language description (or clear it). Returns display name. */
  private async applyLanguage(desc: LanguageDescription | null): Promise<string> {
    const request = ++this.languageRequest
    if (!desc) {
      this.view.dispatch({ effects: languageConf.reconfigure([]) })
      return 'Plain Text'
    }
    const support: LanguageSupport = await desc.load()
    if (request !== this.languageRequest) return desc.name
    this.view.dispatch({ effects: languageConf.reconfigure(support) })
    return desc.name
  }

  /** Apply a full settings object at once (used on boot + settings change). */
  applySettings(settings: Settings): void {
    this.settings = settings
    const indent = settings.insertSpaces ? ' '.repeat(settings.tabSize) : '\t'
    this.view.dispatch({
      effects: [
        themeConf.reconfigure(colorSchemeTheme(settings.colorScheme)),
        wrapConf.reconfigure(settings.wordWrap ? EditorView.lineWrapping : []),
        tabConf.reconfigure([indentUnit.of(indent), EditorState.tabSize.of(settings.tabSize)]),
        minimapConf.reconfigure(settings.showMinimap ? minimapExtension() : []),
        indentGuideConf.reconfigure(settings.showIndentGuides ? indentationMarkers() : []),
        trailingWsConf.reconfigure(
          settings.highlightTrailingWhitespace ? highlightTrailingWhitespace() : []
        ),
        rulerConf.reconfigure(rulers(settings.rulers)),
        fontThemeConf.reconfigure(fontTheme(settings.fontSize))
      ]
    })
  }

  /** Current settings snapshot the editor is rendering with. */
  getSettings(): Settings {
    return this.settings
  }

  // ---- Individual toggles (also update the cached settings) ----

  toggleTheme(): boolean {
    this.settings.theme = this.settings.theme === 'dark' ? 'light' : 'dark'
    this.view.dispatch({
      effects: themeConf.reconfigure(colorSchemeTheme(this.settings.colorScheme))
    })
    return this.settings.theme === 'dark'
  }

  setColorScheme(scheme: ColorScheme): void {
    this.settings.colorScheme = scheme
    this.view.dispatch({ effects: themeConf.reconfigure(colorSchemeTheme(scheme)) })
  }

  toggleWordWrap(): boolean {
    this.settings.wordWrap = !this.settings.wordWrap
    this.view.dispatch({
      effects: wrapConf.reconfigure(this.settings.wordWrap ? EditorView.lineWrapping : [])
    })
    return this.settings.wordWrap
  }

  toggleMinimap(): boolean {
    this.settings.showMinimap = !this.settings.showMinimap
    this.view.dispatch({
      effects: minimapConf.reconfigure(this.settings.showMinimap ? minimapExtension() : [])
    })
    return this.settings.showMinimap
  }

  /** Change the editor font size in px, clamped to a sane range. */
  setFontSize(px: number): number {
    this.settings.fontSize = Math.max(8, Math.min(40, px))
    this.view.dispatch({ effects: fontThemeConf.reconfigure(fontTheme(this.settings.fontSize)) })
    return this.settings.fontSize
  }

  zoomFont(delta: number): number {
    return this.setFontSize(this.settings.fontSize + delta)
  }

  // ---- Line-manipulation commands (Sublime-style) ----

  moveLineUp(): void {
    moveLineUp(this.view)
  }
  moveLineDown(): void {
    moveLineDown(this.view)
  }
  copyLineUp(): void {
    copyLineUp(this.view)
  }
  copyLineDown(): void {
    copyLineDown(this.view)
  }
  deleteLine(): void {
    deleteLine(this.view)
  }
  toggleComment(): void {
    toggleComment(this.view)
  }

  /** Duplicate the current selection (or line if empty) in place. */
  duplicateSelection(): void {
    const { state } = this.view
    const ranges = state.selection.ranges
    if (ranges.every((range) => range.empty)) {
      copyLineDown(this.view)
      return
    }

    const changes = ranges
      .filter((range) => !range.empty)
      .map((range) => ({ from: range.to, insert: state.sliceDoc(range.from, range.to) }))
      .sort((a, b) => b.from - a.from)
    const changeSet = state.changes(changes)
    const selections: SelectionRange[] = ranges.map((range) =>
      range.empty
        ? range
        : EditorSelection.range(
            changeSet.mapPos(range.from, 1),
            changeSet.mapPos(range.to, 1)
          )
    )
    this.view.dispatch({
      changes: changeSet,
      selection: EditorSelection.create(selections, state.selection.mainIndex),
      userEvent: 'input.duplicate'
    })
  }

  /** Sort the selected lines (or the whole document) alphabetically. */
  sortLines(): void {
    const { state } = this.view
    const sel = state.selection.main
    const fromLine = state.doc.lineAt(sel.from)
    const toLine = state.doc.lineAt(sel.to)
    // If nothing meaningful is selected, sort the entire document.
    const spanFrom = sel.empty ? 0 : fromLine.from
    const spanTo = sel.empty ? state.doc.length : toLine.to
    const text = state.doc.sliceString(spanFrom, spanTo)
    const sorted = text.split('\n').sort((a, b) => a.localeCompare(b)).join('\n')
    if (sorted === text) return
    this.view.dispatch({
      changes: { from: spanFrom, to: spanTo, insert: sorted },
      selection: EditorSelection.range(spanFrom, spanFrom + sorted.length)
    })
  }

  // ---- Search / navigation ----

  openSearch(): void {
    openSearchPanel(this.view)
  }

  openReplace(): void {
    openSearchPanel(this.view)
    const query = getSearchQuery(this.view.state)
    this.view.dispatch({
      effects: setSearchQuery.of(
        new SearchQuery({
          search: query.search,
          replace: query.replace,
          caseSensitive: query.caseSensitive,
          regexp: query.regexp,
          wholeWord: query.wholeWord
        })
      )
    })
    this.view.dom.querySelector<HTMLInputElement>('input[name=replace]')?.focus()
  }
  goToLine(): void {
    gotoLine(this.view)
  }

  /** Move the cursor to a 1-based line number and reveal it. */
  gotoLineNumber(line: number): void {
    const clamped = Math.max(1, Math.min(this.view.state.doc.lines, line))
    const info = this.view.state.doc.line(clamped)
    this.view.dispatch({
      selection: EditorSelection.cursor(info.from),
      scrollIntoView: true
    })
    this.view.focus()
  }

  /** Move the cursor to an absolute document offset and reveal it. */
  gotoPos(pos: number): void {
    const clamped = Math.max(0, Math.min(this.view.state.doc.length, pos))
    this.view.dispatch({
      selection: EditorSelection.cursor(clamped),
      scrollIntoView: true
    })
    this.view.focus()
  }

  /** Current 1-based line number, used by bookmarks and status-driven actions. */
  currentLine(): number {
    return this.view.state.doc.lineAt(this.view.state.selection.main.head).number
  }

  /** Insert reusable text at every selection, retaining normal multi-cursor semantics. */
  insertText(text: string): void {
    const { state } = this.view
    const changes = state.selection.ranges
      .map((range) => ({ from: range.from, to: range.to, insert: text }))
      .sort((a, b) => b.from - a.from)
    this.view.dispatch({ changes, userEvent: 'input.snippet' })
  }

  /** Insert Sublime-style ${1:default}/${0} placeholders and enable Tab navigation. */
  insertSnippet(template: string): void {
    const { state } = this.view
    const selection = state.selection.main
    const parsed = parseSnippet(template)
    const from = selection.from
    const to = selection.to
    this.view.dispatch({
      changes: { from, to, insert: parsed.text },
      selection: EditorSelection.cursor(from + parsed.finalOffset),
      userEvent: 'input.snippet'
    })
    this.snippetRanges = parsed.placeholders
      .map((placeholder) => ({ from: from + placeholder.from, to: from + placeholder.to, index: placeholder.index }))
      .sort((a, b) => a.index - b.index)
    this.snippetCursor = -1
    this.snippetFinalPos = from + parsed.finalOffset
    if (this.snippetRanges.length > 0) this.nextSnippetPlaceholder(1)
  }

  nextSnippetPlaceholder(direction: 1 | -1): boolean {
    if (this.snippetRanges.length === 0) return false
    if (direction === 1 && this.snippetCursor >= this.snippetRanges.length - 1) {
      const finalPos = this.snippetFinalPos ?? this.snippetRanges[this.snippetRanges.length - 1].to
      this.clearSnippet()
      this.view.dispatch({ selection: EditorSelection.cursor(finalPos), scrollIntoView: true })
      this.view.focus()
      return true
    }
    this.snippetCursor = (this.snippetCursor + direction + this.snippetRanges.length) % this.snippetRanges.length
    const target = this.snippetRanges[this.snippetCursor]
    this.view.dispatch({ selection: EditorSelection.range(target.from, target.to), scrollIntoView: true })
    this.view.focus()
    return true
  }

  clearSnippet(): void {
    this.snippetRanges = []
    this.snippetCursor = -1
    this.snippetFinalPos = null
  }

  private mapSnippetRanges(update: ViewUpdate): void {
    if (!update.docChanged || this.snippetRanges.length === 0) return
    this.snippetRanges = this.snippetRanges.map((range) => ({
      ...range,
      from: update.changes.mapPos(range.from, 1),
      to: update.changes.mapPos(range.to, -1)
    }))
    if (this.snippetFinalPos !== null) this.snippetFinalPos = update.changes.mapPos(this.snippetFinalPos, 1)
    if (this.applyingSnippetMirror || this.snippetCursor < 0) return
    const active = this.snippetRanges[this.snippetCursor]
    if (!active) return
    const sameIndex = this.snippetRanges.filter((range) => range.index === active.index)
    if (sameIndex.length < 2) return
    const value = update.state.sliceDoc(active.from, active.to)
    const changes = sameIndex
      .filter((range) => range !== active && update.state.sliceDoc(range.from, range.to) !== value)
      .map((range) => ({ from: range.from, to: range.to, insert: value }))
      .sort((a, b) => b.from - a.from)
    if (changes.length > 0) {
      this.applyingSnippetMirror = true
      this.view.dispatch({ changes, userEvent: 'input.snippet-mirror' })
      this.applyingSnippetMirror = false
    }
  }

  trimTrailingWhitespace(): void {
    this.replaceContent(this.getContent().replace(/[ \t]+(?=\n|$)/g, ''))
  }

  convertIndentation(toTabs: boolean): void {
    const width = this.settings.tabSize
    const converted = this.getContent().split('\n').map((line) => {
      const prefix = /^[ \t]*/.exec(line)?.[0] ?? ''
      const columns = [...prefix].reduce((count, char) => char === '\t' ? count + width : count + 1, 0)
      const indent = toTabs ? '\t'.repeat(Math.floor(columns / width)) + ' '.repeat(columns % width) : ' '.repeat(columns)
      return indent + line.slice(prefix.length)
    }).join('\n')
    this.replaceContent(converted)
  }

  changeCase(kind: 'upper' | 'lower' | 'title'): void {
    const { state } = this.view
    const range = state.selection.main
    const from = range.empty ? 0 : range.from
    const to = range.empty ? state.doc.length : range.to
    const source = state.sliceDoc(from, to)
    const next = kind === 'upper' ? source.toUpperCase() : kind === 'lower' ? source.toLowerCase() : source.toLowerCase().replace(/\b\p{L}/gu, (char) => char.toUpperCase())
    this.view.dispatch({ changes: { from, to, insert: next }, selection: EditorSelection.range(from, from + next.length), userEvent: 'input.case' })
  }

  joinLines(): void {
    const { state } = this.view
    const selection = state.selection.main
    const from = state.doc.lineAt(selection.from).from
    const to = state.doc.lineAt(selection.to).to
    const joined = state.sliceDoc(from, to).replace(/\s*\n\s*/g, ' ')
    this.view.dispatch({ changes: { from, to, insert: joined }, selection: EditorSelection.cursor(from + joined.length), userEvent: 'input.join-lines' })
  }

  splitSelectionIntoLines(): void {
    const { state } = this.view
    const selection = state.selection.main
    if (selection.empty) return
    const firstLine = state.doc.lineAt(selection.from).number
    const lastLine = state.doc.lineAt(selection.to).number
    const ranges: SelectionRange[] = []
    for (let lineNumber = firstLine; lineNumber <= lastLine; lineNumber += 1) {
      ranges.push(EditorSelection.cursor(state.doc.line(lineNumber).from))
    }
    this.view.dispatch({
      selection: EditorSelection.create(ranges),
      userEvent: 'select.split-lines'
    })
  }

  indentSelection(): void { indentMore(this.view) }
  outdentSelection(): void { indentLess(this.view) }

  /** Replace diagnostics supplied by a configured language tool. */
  setDiagnostics(diagnostics: Diagnostic[]): void {
    this.view.dispatch(setDiagnostics(this.view.state, diagnostics))
  }

  focus(): void {
    this.view.focus()
  }
}

interface ParsedSnippet {
  text: string
  placeholders: Array<{ from: number; to: number; index: number }>
  finalOffset: number
}

/** Parse the practical ${1:default}, $1 and ${0} subset of Sublime snippets. */
function parseSnippet(template: string): ParsedSnippet {
  const placeholders: ParsedSnippet['placeholders'] = []
  let text = ''
  let finalOffset = 0
  let cursor = 0
  const matcher = /\$\{(\d+)(?::([^}]*))?\}|\$(\d+)/g
  let match: RegExpExecArray | null
  while ((match = matcher.exec(template))) {
    text += template.slice(cursor, match.index)
    const index = Number(match[1] ?? match[3])
    const value = match[2] ?? ''
    const from = text.length
    text += value
    const to = text.length
    if (index === 0) finalOffset = from
    else placeholders.push({ from, to, index })
    cursor = matcher.lastIndex
  }
  text += template.slice(cursor)
  if (!template.includes('$0') && !template.includes('${0}')) finalOffset = text.length
  return { text, placeholders, finalOffset }
}

/** Match a file name against CodeMirror's language descriptions by extension. */
export function matchLanguage(fileName: string): LanguageDescription | null {
  const ext = fileName.includes('.') ? fileName.split('.').pop()! : ''
  for (const lang of languages) {
    if (lang.extensions.includes(ext)) return lang
    if (lang.filename && lang.filename.test(fileName)) return lang
  }
  return null
}

/** All known language display names, for the manual language picker. */
export function allLanguageNames(): string[] {
  return ['Plain Text', ...languages.map((l) => l.name).sort((a, b) => a.localeCompare(b))]
}
