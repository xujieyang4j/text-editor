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
  /** Physical file encoding to use for the next save. */
  encoding: import('../../shared/ipc.js').TextEncoding
  /** Encoding last written to / read from disk, used to compute the dirty flag. */
  savedEncoding: import('../../shared/ipc.js').TextEncoding
  /** Physical newline convention to use for the next save. */
  eol: import('../../shared/ipc.js').LineEnding
  /** Newline convention last written to / read from disk, used to compute the dirty flag. */
  savedEol: import('../../shared/ipc.js').LineEnding
  /** SHA-256 of the last exact disk bytes observed by this document. */
  diskRevision: string | null
  /** Untitled/recovered content that has never been confirmed on disk. */
  requiresSave: boolean
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
    revision: string | null
    unavailable?: 'missing' | 'binary' | 'too-large' | 'hardlink'
  }
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

let documentCounter = 0

/** Pick the first available display name without coupling it to document IDs. */
export function nextUntitledName(existingNames: readonly string[] = []): string {
  const usedNumbers = new Set<number>()
  for (const name of existingNames) {
    const match = /^Untitled-(\d+)$/.exec(name)
    if (match) usedNumbers.add(Number(match[1]))
  }
  let number = 1
  while (usedNumbers.has(number)) number += 1
  return `Untitled-${number}`
}

/** Create a new untitled document. */
export function createUntitled(existingNames: readonly string[] = []): Doc {
  documentCounter += 1
  return {
    id: `doc-${documentCounter}`,
    path: null,
    name: nextUntitledName(existingNames),
    pinned: false,
    content: '',
    savedContent: '',
    language: 'Plain Text',
    languageLocked: false,
    encoding: 'utf8',
    savedEncoding: 'utf8',
    eol: 'LF',
    savedEol: 'LF',
    diskRevision: null,
    requiresSave: false,
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
  eol: import('../../shared/ipc.js').LineEnding = 'LF',
  revision: string | null = null
): Doc {
  documentCounter += 1
  return {
    id: `doc-${documentCounter}`,
    path,
    name: baseName(path),
    pinned: false,
    content,
    savedContent: content,
    language: 'Plain Text',
    languageLocked: false,
    encoding,
    savedEncoding: encoding,
    eol,
    savedEol: eol,
    diskRevision: revision,
    requiresSave: false,
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
 * @param diskFormat   the encoding and line ending currently detected on disk
 *
 * A text `draft`, when present, becomes the live content while `savedContent`
 * tracks the latest on-disk text. A pending format choice is restored from the
 * session when either the text was drafted or `formatDirty` is set; otherwise
 * current and saved metadata both come from disk so the buffer restores clean.
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
    recoveryContent?: string
    formatDirty?: boolean
    baseRevision?: string | null
    encoding?: import('../../shared/ipc.js').TextEncoding
    eol?: import('../../shared/ipc.js').LineEnding
    bookmarks?: number[]
    views?: import('../../shared/ipc.js').SessionViewState[]
  },
  diskFormat: {
    encoding: import('../../shared/ipc.js').TextEncoding
    eol: import('../../shared/ipc.js').LineEnding
    revision?: string | null
  }
): Doc {
  documentCounter += 1
  const hasDraft = sf.draft !== undefined
  // A text draft retains the format in which the user was editing it. A
  // metadata-only session uses `formatDirty` to apply its pending format over
  // freshly read disk text.
  const hasFormatIntent = hasDraft || sf.formatDirty === true
  // The caller must provide this independently of the session metadata: for a
  // real file it is the freshly detected disk format; for an untitled or
  // recovered buffer it is the explicit empty-disk baseline (utf8/LF).
  const diskEncoding = diskFormat.encoding
  const diskEol = diskFormat.eol
  const encoding = hasFormatIntent ? (sf.encoding ?? diskEncoding) : diskEncoding
  const eol = hasFormatIntent ? (sf.eol ?? diskEol) : diskEol
  const diskRevision = diskFormat.revision ?? null
  const diskChangedWhileClosed = sf.path !== null
    && (hasDraft || sf.formatDirty === true)
    // Legacy sessions have no base revision. Treat their restored file draft
    // conservatively as a conflict instead of allowing an unchecked overwrite.
    && (sf.baseRevision === undefined || sf.baseRevision !== diskRevision)
  return {
    id: `doc-${documentCounter}`,
    path: sf.path,
    name: sf.name,
    pinned: sf.pinned === true,
    content: hasDraft ? sf.draft! : diskContent,
    savedContent: diskContent,
    language: sf.language,
    languageLocked: sf.languageLocked,
    encoding,
    savedEncoding: diskEncoding,
    eol,
    savedEol: diskEol,
    diskRevision: diskChangedWhileClosed ? (sf.baseRevision ?? null) : diskRevision,
    requiresSave: sf.path === null && hasDraft,
    bookmarks: Array.isArray(sf.bookmarks) ? sf.bookmarks.filter((line) => Number.isInteger(line) && line > 0).slice(0, 10_000) : [],
    groupStates: new Map(),
    viewStates: new Map((sf.views ?? []).map((view) => [view.group, view])),
    ...(diskChangedWhileClosed
      ? { externalChange: { content: diskContent, encoding: diskEncoding, eol: diskEol, revision: diskRevision } }
      : {})
  }
}

/** True when the document has unsaved changes. */
export function isDirty(doc: Doc): boolean {
  return doc.content !== doc.savedContent
    || doc.encoding !== doc.savedEncoding
    || doc.eol !== doc.savedEol
    || doc.requiresSave
    || doc.externalChange !== undefined
}

/** Only a direct save conflict belongs to the document's external-change UI. */
export function isCurrentDocumentSaveConflict(
  promptedForDestination: boolean,
  originalPath: string | null,
  currentPath: string | null,
  conflictPath: string | undefined
): boolean {
  return !promptedForDestination
    && originalPath !== null
    && currentPath === originalPath
    && conflictPath === originalPath
}

/** Extract the final path segment for display, handling both separators. */
export function baseName(p: string): string {
  const parts = p.split(/[\\/]/)
  return parts[parts.length - 1] || p
}
