import { EditorState, Compartment, type Extension } from '@codemirror/state'
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
  indentWithTab
} from '@codemirror/commands'
import {
  indentOnInput,
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
  gotoLine
} from '@codemirror/search'
import {
  autocompletion,
  completionKeymap,
  closeBrackets,
  closeBracketsKeymap
} from '@codemirror/autocomplete'
import { oneDark } from '@codemirror/theme-one-dark'

/** Callbacks the editor emits so the shell can update tabs/status bar. */
export interface EditorCallbacks {
  onDocChange: () => void
  onCursorChange: (state: EditorState) => void
}

/** Compartments allow us to reconfigure parts of the editor without a full reset. */
const languageConf = new Compartment()
const themeConf = new Compartment()
const wrapConf = new Compartment()

/** Base set of extensions shared by every document. */
function baseExtensions(callbacks: EditorCallbacks): Extension {
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
    autocompletion(),
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
    })
  ]
}

/**
 * A thin wrapper around a CodeMirror {@link EditorView} that manages the
 * document swap, language, theme and word-wrap for a single editor pane.
 */
export class Editor {
  readonly view: EditorView
  private callbacks: EditorCallbacks
  private dark = true
  private wrap = false

  constructor(parent: HTMLElement, callbacks: EditorCallbacks) {
    this.callbacks = callbacks
    this.view = new EditorView({
      parent,
      state: this.makeState('')
    })
  }

  /** Build a fresh EditorState for the given document text. */
  private makeState(doc: string): EditorState {
    return EditorState.create({
      doc,
      extensions: [
        baseExtensions(this.callbacks),
        languageConf.of([]),
        themeConf.of(this.dark ? oneDark : []),
        wrapConf.of(this.wrap ? EditorView.lineWrapping : [])
      ]
    })
  }

  /** Replace the entire document (used when switching tabs). */
  setDocument(doc: string): void {
    this.view.setState(this.makeState(doc))
  }

  /** Current document text. */
  getContent(): string {
    return this.view.state.doc.toString()
  }

  /** Reconfigure syntax highlighting for a file name/extension. */
  async setLanguageForFile(fileName: string): Promise<string> {
    const desc = fileName ? matchLanguage(fileName) : null
    if (!desc) {
      this.view.dispatch({ effects: languageConf.reconfigure([]) })
      return 'Plain Text'
    }
    const support: LanguageSupport = await desc.load()
    this.view.dispatch({ effects: languageConf.reconfigure(support) })
    return desc.name
  }

  /** Toggle between the dark and light theme. Returns true when dark. */
  toggleTheme(): boolean {
    this.dark = !this.dark
    this.view.dispatch({ effects: themeConf.reconfigure(this.dark ? oneDark : []) })
    return this.dark
  }

  isDark(): boolean {
    return this.dark
  }

  /** Toggle soft word-wrap. Returns the new state. */
  toggleWordWrap(): boolean {
    this.wrap = !this.wrap
    this.view.dispatch({
      effects: wrapConf.reconfigure(this.wrap ? EditorView.lineWrapping : [])
    })
    return this.wrap
  }

  /** Open the built-in search panel. */
  openSearch(): void {
    openSearchPanel(this.view)
  }

  /** Open the go-to-line prompt. */
  goToLine(): void {
    gotoLine(this.view)
  }

  /** Move keyboard focus into the editor. */
  focus(): void {
    this.view.focus()
  }
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
