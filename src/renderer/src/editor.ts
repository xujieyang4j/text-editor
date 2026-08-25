import { EditorState, Compartment, EditorSelection, StateEffect, StateField, RangeSet, RangeSetBuilder, type Extension, type SelectionRange } from '@codemirror/state'
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
  gutter,
  GutterMarker,
  gutterLineClass,
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
  transposeChars,
  toggleComment,
  toggleBlockComment,
  addCursorAbove,
  addCursorBelow,
  cursorMatchingBracket,
  selectMatchingBracket,
  selectLine,
  selectParentSyntax,
  indentMore,
  indentLess
} from '@codemirror/commands'
import {
  indentOnInput,
  indentUnit,
  bracketMatching,
  foldGutter,
  foldCode,
  unfoldCode,
  foldAll,
  unfoldAll,
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
  SearchQuery,
  selectNextOccurrence
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
import type { IncrementalChange } from './incrementalDiff.js'
import type { Settings, ColorScheme, SessionViewState } from '../../shared/ipc.js'

/** Callbacks the editor emits so the shell can update tabs/status bar. */
export interface EditorCallbacks {
  onDocChange: () => void
  /** Exact document transactions for macro recording; absent for programmatic replay. */
  onTextEdits?: (edits: Array<{ from: number; to: number; insert: string }>) => void
  onCursorChange: (state: EditorState) => void
  onCompletion?: (context: CompletionContext) => Promise<Completion[] | null>
  onTab?: () => boolean
  /** Scroll changes are view state, not document changes, but belong in hot exit. */
  onViewChange?: () => void
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
const spellCheckConf = new Compartment()

const setIncrementalDiff = StateEffect.define<IncrementalChange[]>()

class IncrementalDiffMarker extends GutterMarker {
  constructor(kind: IncrementalChange['kind']) {
    super()
    this.elementClass = `incremental-diff-marker incremental-diff-${kind}`
  }
}

const incrementalDiffMarkers = StateField.define<RangeSet<IncrementalDiffMarker>>({
  create: () => RangeSet.empty,
  update: (markers, transaction) => {
    for (const effect of transaction.effects) {
      if (!effect.is(setIncrementalDiff)) continue
      const builder = new RangeSetBuilder<IncrementalDiffMarker>()
      for (const change of effect.value) {
        const line = Math.max(1, Math.min(transaction.state.doc.lines, change.line))
        builder.add(transaction.state.doc.line(line).from, transaction.state.doc.line(line).from, new IncrementalDiffMarker(change.kind))
      }
      return builder.finish()
    }
    return markers.map(transaction.changes)
  },
  provide: (field) => [gutter({ class: 'incremental-diff-gutter', markers: (view) => view.state.field(field) }), gutterLineClass.from(field)]
})

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
      if (update.docChanged) {
        const edits: Array<{ from: number; to: number; insert: string }> = []
        update.changes.iterChanges((fromA, toA, _fromB, _toB, insert) => edits.push({ from: fromA, to: toA, insert: insert.toString() }))
        callbacks.onTextEdits?.(edits)
        callbacks.onDocChange()
      }
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
  private incrementalChanges: IncrementalChange[] = []
  private viewRestoreToken = 0
  /** Selections generated by Expand Selection, so Shrink can restore exact prior ranges. */
  private selectionHistory: EditorSelection[] = []
  private applyingSelectionHistory = false

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
    this.view.scrollDOM.addEventListener('scroll', () => this.callbacks.onViewChange?.(), { passive: true })
  }

  /** Build a fresh EditorState for the given document text. */
  private makeState(doc: string): EditorState {
    const s = this.settings
    const indent = s.insertSpaces ? ' '.repeat(s.tabSize) : '\t'
    return EditorState.create({
      doc,
      extensions: [
        baseExtensions(this.callbacks, (update) => {
          this.mapSnippetRanges(update)
          if (!this.applyingSelectionHistory && (update.docChanged || update.selectionSet)) this.selectionHistory = []
        }),
        languageConf.of([]),
        themeConf.of(colorSchemeTheme(s.colorScheme)),
        wrapConf.of(s.wordWrap ? EditorView.lineWrapping : []),
        tabConf.of([indentUnit.of(indent), EditorState.tabSize.of(s.tabSize)]),
        minimapConf.of(s.showMinimap ? minimapExtension() : []),
        indentGuideConf.of(s.showIndentGuides ? indentationMarkers() : []),
        trailingWsConf.of(s.highlightTrailingWhitespace ? highlightTrailingWhitespace() : []),
        rulerConf.of(rulers(s.rulers)),
        fontThemeConf.of(fontTheme(s.fontSize)),
        spellCheckConf.of(EditorView.contentAttributes.of({ spellcheck: s.spellCheck ? 'true' : 'false' })),
        incrementalDiffMarkers,
        lintGutter()
      ]
    })
  }

  /** Replace the entire document (used when switching tabs). */
  setDocument(doc: string, state?: EditorState): void {
    this.viewRestoreToken += 1
    this.clearSnippet()
    this.selectionHistory = []
    this.view.setState(state ?? this.makeState(doc))
  }

  /** Replace document text without discarding extensions, undo history or folds. */
  replaceContent(doc: string): void {
    this.clearSnippet()
    const state = this.view.state
    this.view.dispatch({ changes: { from: 0, to: state.doc.length, insert: doc }, userEvent: 'input.replace' })
  }

  /** Apply recorded edits against the current document in one undoable transaction. */
  applyEdits(edits: Array<{ from: number; to: number; insert: string }>): void {
    const length = this.view.state.doc.length
    const changes = edits
      .filter((edit) => Number.isInteger(edit.from) && Number.isInteger(edit.to) && edit.from >= 0 && edit.to >= edit.from && edit.to <= length && typeof edit.insert === 'string')
      .map((edit) => ({ from: edit.from, to: edit.to, insert: edit.insert }))
      .sort((a, b) => a.from - b.from)
    if (changes.length > 0) this.view.dispatch({ changes, userEvent: 'input.macro' })
  }

  /** Snapshot the complete CM state so a tab keeps undo, selection and folds. */
  getState(): EditorState {
    return this.view.state
  }

  /** Capture the part of a view state that remains safe and compact to persist. */
  getViewState(group: number): SessionViewState {
    const selection = this.view.state.selection
    return {
      group,
      selections: selection.ranges.map((range) => ({ anchor: range.anchor, head: range.head })),
      mainIndex: selection.mainIndex,
      scrollTop: Math.max(0, Math.round(this.view.scrollDOM.scrollTop)),
      scrollLeft: Math.max(0, Math.round(this.view.scrollDOM.scrollLeft))
    }
  }

  /** Restore selections immediately and scroll after layout has stabilised. */
  restoreViewState(snapshot: SessionViewState | undefined): void {
    if (!snapshot) return
    const length = this.view.state.doc.length
    const ranges = snapshot.selections
      .slice(0, 100)
      .map((range) => EditorSelection.range(
        Math.max(0, Math.min(length, range.anchor)),
        Math.max(0, Math.min(length, range.head))
      ))
    if (ranges.length === 0) return
    this.view.dispatch({ selection: EditorSelection.create(ranges, Math.max(0, Math.min(ranges.length - 1, snapshot.mainIndex))) })
    const token = ++this.viewRestoreToken
    requestAnimationFrame(() => {
      if (token !== this.viewRestoreToken) return
      this.view.scrollDOM.scrollTop = Math.max(0, snapshot.scrollTop)
      this.view.scrollDOM.scrollLeft = Math.max(0, snapshot.scrollLeft)
    })
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
        fontThemeConf.reconfigure(fontTheme(settings.fontSize)),
        spellCheckConf.reconfigure(EditorView.contentAttributes.of({ spellcheck: settings.spellCheck ? 'true' : 'false' }))
      ]
    })
  }

  /** Apply per-document indentation inferred from its existing non-empty lines. */
  setIndentation(tabSize: number, insertSpaces: boolean): void {
    const width = Math.max(1, Math.min(16, Math.round(tabSize)))
    const indent = insertSpaces ? ' '.repeat(width) : '\t'
    this.view.dispatch({ effects: tabConf.reconfigure([indentUnit.of(indent), EditorState.tabSize.of(width)]) })
  }

  setSpellCheck(enabled: boolean): void {
    this.view.dispatch({ effects: spellCheckConf.reconfigure(EditorView.contentAttributes.of({ spellcheck: enabled ? 'true' : 'false' })) })
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
  transposeCharacters(): boolean {
    return transposeChars(this.view)
  }
  toggleComment(): void {
    toggleComment(this.view)
  }
  toggleBlockComment(): void {
    toggleBlockComment(this.view)
  }
  addCursorAbove(): void {
    addCursorAbove(this.view)
  }
  addCursorBelow(): void {
    addCursorBelow(this.view)
  }
  selectNextOccurrence(): void {
    selectNextOccurrence(this.view)
  }
  selectAllOccurrences(): void {
    const state = this.view.state
    const main = state.selection.main
    const before = state.sliceDoc(Math.max(0, main.head - 100), main.head)
    const after = state.sliceDoc(main.head, Math.min(state.doc.length, main.head + 100))
    const selected = main.empty
      ? ((/[A-Za-z_$][\w$]*$/.exec(before)?.[0] ?? '') + (/^[\w$]*/.exec(after)?.[0] ?? ''))
      : state.sliceDoc(main.from, main.to)
    if (!selected) return
    const ranges: SelectionRange[] = []
    let index = 0
    const text = state.doc.toString()
    while (index <= text.length - selected.length && ranges.length < 10_000) {
      const found = text.indexOf(selected, index)
      if (found < 0) break
      if (main.empty && (/[$\w]/.test(text[found - 1] ?? '') || /[$\w]/.test(text[found + selected.length] ?? ''))) {
        index = found + 1
        continue
      }
      ranges.push(EditorSelection.range(found, found + selected.length))
      index = found + Math.max(1, selected.length)
    }
    if (ranges.length > 0) this.view.dispatch({ selection: EditorSelection.create(ranges) })
  }

  /** Move each cursor to its matching bracket, returning false when none match. */
  gotoMatchingBracket(): boolean {
    const moved = cursorMatchingBracket(this.view)
    if (moved) this.view.focus()
    return moved
  }

  /** Select the full physical line(s) touched by the current selection. */
  selectCurrentLine(): boolean { return selectLine(this.view) }

  /** Extend each selection to the bracket matching its active end. */
  selectToMatchingBracket(): boolean { return selectMatchingBracket(this.view) }

  foldCurrent(): boolean { return foldCode(this.view) }
  unfoldCurrent(): boolean { return unfoldCode(this.view) }
  foldEverywhere(): boolean { return foldAll(this.view) }
  unfoldEverywhere(): boolean { return unfoldAll(this.view) }

  /**
   * Grow each cursor/selection to the next useful boundary. Syntax-tree parent
   * nodes are preferred for parsed languages; word, line and document scopes
   * provide a predictable fallback for plain text or incomplete code.
   */
  expandSelection(): boolean {
    const { state } = this.view
    const previous = state.selection
    this.applyingSelectionHistory = true
    if (selectParentSyntax(this.view)) {
      this.selectionHistory.push(previous)
      this.applyingSelectionHistory = false
      this.view.focus()
      return true
    }
    const next = EditorSelection.create(
      state.selection.ranges.map((range) => this.nextExpandedFallbackRange(range)),
      state.selection.mainIndex
    )
    if (next.eq(previous)) {
      this.applyingSelectionHistory = false
      return false
    }
    this.selectionHistory.push(previous)
    this.view.dispatch({ selection: next, scrollIntoView: true, userEvent: 'select.expand' })
    this.applyingSelectionHistory = false
    this.view.focus()
    return true
  }

  /** Restore the immediate previous range created by {@link expandSelection}. */
  shrinkSelection(): boolean {
    const previous = this.selectionHistory.pop()
    if (!previous) return false
    this.applyingSelectionHistory = true
    this.view.dispatch({ selection: previous, scrollIntoView: true, userEvent: 'select.shrink' })
    this.applyingSelectionHistory = false
    this.view.focus()
    return true
  }

  private nextExpandedFallbackRange(range: SelectionRange): SelectionRange {
    const { state } = this.view
    const currentFrom = range.from
    const currentTo = range.to
    const word = this.wordRangeAt(range.head)
    if (word && (word.from < currentFrom || word.to > currentTo)) {
      return EditorSelection.range(word.from, word.to)
    }

    const firstLine = state.doc.lineAt(currentFrom)
    const lastLine = state.doc.lineAt(currentTo)
    const lineFrom = firstLine.from
    const lineTo = Math.min(state.doc.length, lastLine.to + (lastLine.to < state.doc.length ? 1 : 0))
    if (lineFrom < currentFrom || lineTo > currentTo) return EditorSelection.range(lineFrom, lineTo)

    if (currentFrom > 0 || currentTo < state.doc.length) return EditorSelection.range(0, state.doc.length)
    return range
  }

  /** Return the word under or immediately before the cursor, including Unicode letters. */
  private wordRangeAt(pos: number): { from: number; to: number } | null {
    const text = this.view.state.doc.toString()
    const word = /[\p{L}\p{N}_$]/u
    let from = Math.max(0, Math.min(text.length, pos))
    let to = from
    if (!word.test(text[from] ?? '') && word.test(text[from - 1] ?? '')) from -= 1
    if (!word.test(text[from] ?? '')) return null
    while (from > 0 && word.test(text[from - 1])) from -= 1
    while (to < text.length && word.test(text[to])) to += 1
    return { from, to }
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
    this.gotoLineColumn(line, 1)
  }

  /** Move the cursor to a 1-based line and column, clamping within the document. */
  gotoLineColumn(line: number, column = 1): void {
    const clamped = Math.max(1, Math.min(this.view.state.doc.lines, line))
    const info = this.view.state.doc.line(clamped)
    this.view.dispatch({
      selection: EditorSelection.cursor(Math.max(info.from, Math.min(info.to, info.from + Math.max(0, column - 1)))),
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

  /** Show lightweight incremental-diff markers without extending renderer privileges. */
  setIncrementalChanges(changes: IncrementalChange[]): void {
    this.incrementalChanges = changes
    this.view.dispatch({ effects: setIncrementalDiff.of(changes) })
  }

  nextIncrementalChange(direction: 1 | -1): IncrementalChange | null {
    if (this.incrementalChanges.length === 0) return null
    const current = this.currentLine()
    const changes = this.incrementalChanges
    const target = direction > 0
      ? changes.find((change) => change.line > current) ?? changes[0]
      : [...changes].reverse().find((change) => change.line < current) ?? changes[changes.length - 1]
    this.gotoLineNumber(target.line)
    return target
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
