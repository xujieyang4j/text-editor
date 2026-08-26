/**
 * A small line-oriented diff used for Sublime-style incremental change markers.
 * The output is deliberately independent of CodeMirror so it can be tested in
 * Node and rendered either as gutter markers or a compact inline preview.
 */
export type IncrementalChangeKind = 'added' | 'modified' | 'deleted'

export interface IncrementalChange {
  kind: IncrementalChangeKind
  /** 1-based line in the current document. Deleted-only hunks use their insertion point. */
  line: number
  /** Number of current-document lines represented by the hunk (zero for a pure deletion). */
  lineCount: number
  /** Original source range, used to show/restore a precise hunk. */
  baseStart: number
  baseLines: string[]
  currentLines: string[]
}

function splitLines(text: string): string[] {
  return text.length === 0 ? [] : text.split('\n')
}

/** Longest-common-subsequence diff: bounded documents keep this predictable and dependency-free. */
export function incrementalChanges(base: string, current: string, maxLines = 2_000): IncrementalChange[] {
  const before = splitLines(base)
  const after = splitLines(current)
  if (before.length > maxLines || after.length > maxLines) return []
  const rows = before.length + 1
  const columns = after.length + 1
  const table = Array.from({ length: rows }, () => new Uint16Array(columns))
  for (let i = before.length - 1; i >= 0; i -= 1) {
    for (let j = after.length - 1; j >= 0; j -= 1) {
      table[i][j] = before[i] === after[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1])
    }
  }

  const changes: IncrementalChange[] = []
  let beforeIndex = 0
  let afterIndex = 0
  let baseStart = 0
  let currentStart = 0
  let removed: string[] = []
  let added: string[] = []
  const flush = (): void => {
    if (removed.length === 0 && added.length === 0) return
    changes.push({
      kind: removed.length > 0 && added.length > 0 ? 'modified' : added.length > 0 ? 'added' : 'deleted',
      line: currentStart + 1,
      lineCount: added.length,
      baseStart,
      baseLines: removed,
      currentLines: added
    })
    removed = []
    added = []
  }

  while (beforeIndex < before.length || afterIndex < after.length) {
    if (beforeIndex < before.length && afterIndex < after.length && before[beforeIndex] === after[afterIndex]) {
      flush()
      beforeIndex += 1
      afterIndex += 1
      baseStart = beforeIndex
      currentStart = afterIndex
    } else if (afterIndex < after.length && (beforeIndex === before.length || table[beforeIndex][afterIndex + 1] >= table[beforeIndex + 1][afterIndex])) {
      added.push(after[afterIndex])
      afterIndex += 1
    } else {
      removed.push(before[beforeIndex])
      beforeIndex += 1
    }
  }
  flush()
  return changes
}

/** Restore one diff hunk against the current buffer, returning the replacement text. */
export function revertIncrementalChange(current: string, change: IncrementalChange): string {
  const lines = splitLines(current)
  const index = Math.max(0, Math.min(lines.length, change.line - 1))
  lines.splice(index, change.lineCount, ...change.baseLines)
  return lines.join('\n')
}
