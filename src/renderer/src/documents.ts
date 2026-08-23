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
  /** Cached text content (kept in sync with the editor for the active tab). */
  content: string
  /** Text last written to / read from disk, used to compute the dirty flag. */
  savedContent: string
  /** Resolved language display name for the status bar. */
  language: string
}

let counter = 0

/** Create a new untitled document. */
export function createUntitled(): Doc {
  counter += 1
  return {
    id: `doc-${counter}`,
    path: null,
    name: `Untitled-${counter}`,
    content: '',
    savedContent: '',
    language: 'Plain Text'
  }
}

/** Create a document from a file loaded off disk. */
export function createFromFile(path: string, content: string): Doc {
  counter += 1
  return {
    id: `doc-${counter}`,
    path,
    name: baseName(path),
    content,
    savedContent: content,
    language: 'Plain Text'
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
