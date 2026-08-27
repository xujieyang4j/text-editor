/**
 * A single open document (tab). The editor holds only ONE CodeMirror view;
 * each Doc caches its own text so we can swap content when tabs change.
 */
export interface Doc {
  /** Stable id used for DOM + lookup. */
  id: string
  /** Absolute path on disk, or null for an untitled buffer. */
  path: string | null
  /** Display name shown on the tab. */
  name: string
  /** Keep this document visible at the front of every editor group's tab row. */
  pinned: boolean
  /** Cached text content (kept in sync with the editor for the active tab). */
  content: string
  /** Text last written to / read from disk, used to compute the dirty flag. */
  savedContent: string
  /** Resolved language display name for the status bar. */
  language: string
  /** True when the user manually picked a language (skip auto-detect). */
  languageLocked: boolean
  /** Original physical file encoding, preserved on save. */
  encoding: import('../../shared/ipc.js').TextEncoding
  /** Original physical newline convention, preserved on save. */
  eol: import('../../shared/ipc.js').LineEnding
  /** Per-tab CodeMirror state preserves undo history, selection and folds. */
  editorState?: import('@codemirror/state').EditorState
  /** Per-editor-group view states for cloned tabs (selection/history/folds are group-local). */
  groupStates: Map<number, import('@codemirror/state').EditorState>
  /** Serializable selection and scroll snapshots used by hot-exit restore. */
  viewStates: Map<number, import('../../shared/ipc.js').SessionViewState>
  /** Bookmarked 1-based line numbers for quick navigation. */
  bookmarks: number[]
  /** New on-disk version held while local unsaved edits need a conflict decision. */
  externalChange?: {
    content: string
    encoding: import('../../shared/ipc.js').TextEncoding
    eol: import('../../shared/ipc.js').LineEnding
  }
  /** Disk version explicitly kept aside while the user continues local edits. */
  ignoredExternalContent?: string
  /** Latest diagnostics received from an LSP or configured language tool. */
  diagnostics?: Array<{
    line: number
    column: number
    endLine?: number
    endColumn?: number
    severity: 'error' | 'warning' | 'info'
    message: string
  }>
}

let counter = 0

/** Create a new untitled document. */
export function createUntitled(): Doc {
  counter += 1
  return {
    id: `doc-${counter}`,
    path: null,
    name: `Untitled-${counter}`,
    pinned: false,
    content: '',
    savedContent: '',
    language: 'Plain Text',
    languageLocked: false,
    encoding: 'utf8',
    eol: 'LF',
    bookmarks: [],
    groupStates: new Map(),
    viewStates: new Map()
  }
}

/** Create a document from a file loaded off disk. */
export function createFromFile(
  path: string,
  content: string,
  encoding: import('../../shared/ipc.js').TextEncoding = 'utf8',
  eol: import('../../shared/ipc.js').LineEnding = 'LF'
): Doc {
  counter += 1
  return {
    id: `doc-${counter}`,
    path,
    name: baseName(path),
    pinned: false,
    content,
    savedContent: content,
    language: 'Plain Text',
    languageLocked: false,
    encoding,
    eol,
    bookmarks: [],
    groupStates: new Map(),
    viewStates: new Map()
  }
}

/**
 * Reconstruct a document when restoring a session (hot exit).
 *
 * @param diskContent  the text currently on disk (empty string for untitled)
 * @param sf           the persisted buffer metadata + optional draft
 *
 * If a `draft` was saved, it becomes the live content while `savedContent`
 * tracks the on-disk text — so the buffer restores as *dirty* with the user's
 * unsaved edits intact. Without a draft the buffer restores clean.
 */
export function createFromSession(
  diskContent: string,
  sf: {
    path: string | null
    name: string
    language: string
    languageLocked: boolean
    pinned?: boolean
    draft?: string
    encoding?: import('../../shared/ipc.js').TextEncoding
    eol?: import('../../shared/ipc.js').LineEnding
    bookmarks?: number[]
    views?: import('../../shared/ipc.js').SessionViewState[]
  }
): Doc {
  counter += 1
  const hasDraft = sf.draft !== undefined
  return {
    id: `doc-${counter}`,
    path: sf.path,
    name: sf.name,
    pinned: sf.pinned === true,
    content: hasDraft ? sf.draft! : diskContent,
    savedContent: diskContent,
    language: sf.language,
    languageLocked: sf.languageLocked,
    encoding: sf.encoding ?? 'utf8',
    eol: sf.eol ?? 'LF',
    bookmarks: Array.isArray(sf.bookmarks) ? sf.bookmarks.filter((line) => Number.isInteger(line) && line > 0).slice(0, 10_000) : [],
    groupStates: new Map(),
    viewStates: new Map((sf.views ?? []).map((view) => [view.group, view]))
  }
}

/** True when the document has unsaved changes. */
export function isDirty(doc: Doc): boolean {
  return doc.content !== doc.savedContent
}

/** Extract the final path segment for display, handling both separators. */
export function baseName(p: string): string {
  const parts = p.split(/[\\/]/)
  return parts[parts.length - 1] || p
}
