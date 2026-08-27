import { EditorSelection, type EditorState, type SelectionRange, type TransactionSpec } from '@codemirror/state'

export type CaseTransformKind = 'upper' | 'lower' | 'title' | 'swap'

const casedCharacter = /\p{Cased}/gu
const lowercaseCharacter = /^\p{Lowercase}$/u

/** Locale-independent case conversion used by all editor case commands. */
export function transformCaseText(source: string, kind: CaseTransformKind): string {
  if (kind === 'upper') return source.toUpperCase()
  if (kind === 'lower') return source.toLowerCase()
  if (kind === 'title') return source.toLowerCase().replace(/\b\p{L}/gu, (char) => char.toUpperCase())
  return source.replace(casedCharacter, (char) =>
    lowercaseCharacter.test(char) ? char.toUpperCase() : char.toLowerCase()
  )
}

function preserveRangeShape(original: SelectionRange, from: number, to: number): SelectionRange {
  if (original.undirectional) return EditorSelection.undirectionalRange(from, to)
  const anchor = original.anchor <= original.head ? from : to
  const head = original.anchor <= original.head ? to : from
  return EditorSelection.range(
    anchor,
    head,
    original.goalColumn,
    original.bidiLevel ?? undefined,
    original.assoc
  )
}

/**
 * Build one atomic, multi-selection-safe case transformation. When every
 * range is a cursor, the established command semantics transform and select
 * the whole document.
 */
export function caseTransformSpec(
  state: EditorState,
  kind: CaseTransformKind
): Pick<TransactionSpec, 'changes' | 'selection'> | null {
  const hasSelection = state.selection.ranges.some((range) => !range.empty)
  if (!hasSelection) {
    const original = state.doc.toString()
    const insert = transformCaseText(original, kind)
    if (insert === original) return null
    return {
      changes: { from: 0, to: state.doc.length, insert },
      selection: EditorSelection.range(0, insert.length)
    }
  }

  let changed = false
  const spec = state.changeByRange((range) => {
    if (range.empty) return { range }
    const original = state.sliceDoc(range.from, range.to)
    const insert = transformCaseText(original, kind)
    if (insert === original) return { range }
    changed = true
    return {
      changes: { from: range.from, to: range.to, insert },
      range: preserveRangeShape(range, range.from, range.from + insert.length)
    }
  })
  return changed ? { changes: spec.changes, selection: spec.selection } : null
}
