export interface TextSelectionRange {
  readonly anchor: number
  readonly head: number
}

export interface FinalNewlinePlan {
  readonly changes: Array<{ from: number; to: number; insert: string }>
  readonly ranges: TextSelectionRange[]
}

/**
 * Ensure a non-empty LF-normalised document ends in exactly one newline.
 * The edit is limited to the end of the document so selections elsewhere are
 * stable and cursors at old EOF remain before an inserted newline.
 */
export function planSingleFinalNewline(
  text: string,
  ranges: readonly TextSelectionRange[]
): FinalNewlinePlan | null {
  if (text.length === 0) return null

  if (!text.endsWith('\n')) {
    return {
      changes: [{ from: text.length, to: text.length, insert: '\n' }],
      ranges: ranges.map(({ anchor, head }) => ({ anchor, head }))
    }
  }

  let firstTrailingNewline = text.length - 1
  while (firstTrailingNewline > 0 && text[firstTrailingNewline - 1] === '\n') {
    firstTrailingNewline -= 1
  }
  const keepThrough = firstTrailingNewline + 1
  if (keepThrough === text.length) return null

  const mapPosition = (position: number): number =>
    Math.min(Math.max(0, Math.min(text.length, position)), keepThrough)

  return {
    changes: [{ from: keepThrough, to: text.length, insert: '' }],
    ranges: ranges.map(({ anchor, head }) => ({
      anchor: mapPosition(anchor),
      head: mapPosition(head)
    }))
  }
}
