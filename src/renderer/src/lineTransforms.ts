export type LineTransformMode = 'sort-ascending' | 'sort-descending' | 'reverse' | 'unique' | 'remove-blank'

export interface TextSelectionRange {
  readonly anchor: number
  readonly head: number
}

export interface LineTransformEdit {
  readonly from: number
  readonly to: number
  readonly insert: string
}

export interface LineTransformPlan {
  readonly changes: LineTransformEdit[]
  readonly ranges: TextSelectionRange[]
}

interface LineDocument {
  lines: string[]
  trailingNewline: boolean
}

interface TransformedLineDocument {
  text: string
  sourceToOutput: number[]
}

/** Split the editor's LF-normalised text without treating its final newline as a sortable line. */
function splitLineDocument(text: string): LineDocument {
  if (text.length === 0) return { lines: [], trailingNewline: false }

  const trailingNewline = text.endsWith('\n')
  const lines = text.split('\n')
  if (trailingNewline) lines.pop()
  return { lines, trailingNewline }
}

function joinLineDocument({ lines, trailingNewline }: LineDocument): string {
  return `${lines.join('\n')}${trailingNewline ? '\n' : ''}`
}

function transformLineDocument(text: string, mode: LineTransformMode): TransformedLineDocument {
  const document = splitLineDocument(text)
  const records = document.lines.map((line, sourceIndex) => ({ line, sourceIndex }))
  let output: typeof records

  switch (mode) {
    case 'sort-ascending':
      output = stableSort(records, false)
      break
    case 'sort-descending':
      output = stableSort(records, true)
      break
    case 'reverse':
      output = [...records].reverse()
      break
    case 'unique': {
      const firstByLine = new Map<string, number>()
      output = []
      for (const record of records) {
        if (!firstByLine.has(record.line)) {
          firstByLine.set(record.line, output.length)
          output.push(record)
        }
      }
      break
    }
    case 'remove-blank':
      output = records.filter((record) => !/^[\t ]*$/.test(record.line))
      break
  }

  const sourceToOutput = new Array<number>(records.length)
  const firstOutputByLine = new Map<string, number>()
  output.forEach((record, outputIndex) => {
    sourceToOutput[record.sourceIndex] = outputIndex
    if (!firstOutputByLine.has(record.line)) firstOutputByLine.set(record.line, outputIndex)
  })
  if (mode === 'unique') {
    records.forEach((record) => {
      sourceToOutput[record.sourceIndex] = firstOutputByLine.get(record.line) ?? 0
    })
  } else if (mode === 'remove-blank') {
    let retainedBefore = 0
    records.forEach((record) => {
      sourceToOutput[record.sourceIndex] = retainedBefore
      if (!/^[\t ]*$/.test(record.line)) retainedBefore += 1
    })
  }

  return {
    text: mode === 'remove-blank' && output.length === 0
      ? ''
      : joinLineDocument({ ...document, lines: output.map(({ line }) => line) }),
    sourceToOutput
  }
}

/** Locale-independent, case-sensitive and normalization-sensitive string ordering. */
function compareExact(left: string, right: string): number {
  if (left < right) return -1
  if (left > right) return 1
  return 0
}

function stableSort<T extends { line: string; sourceIndex: number }>(lines: T[], descending: boolean): T[] {
  return lines
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      const compared = descending
        ? compareExact(right.record.line, left.record.line)
        : compareExact(left.record.line, right.record.line)
      return compared || left.index - right.index
    })
    .map(({ record }) => record)
}

export function sortLinesAscending(text: string): string {
  return transformLines(text, 'sort-ascending')
}

export function sortLinesDescending(text: string): string {
  return transformLines(text, 'sort-descending')
}

export function reverseLines(text: string): string {
  return transformLines(text, 'reverse')
}

/** Remove exact duplicate lines while retaining the first occurrence. */
export function uniqueLines(text: string): string {
  return transformLines(text, 'unique')
}

/** Remove empty lines and lines containing only spaces or tabs. */
export function removeBlankLines(text: string): string {
  return transformLines(text, 'remove-blank')
}

export function transformLines(text: string, mode: LineTransformMode): string {
  return transformLineDocument(text, mode).text
}

/** Useful for command enablement without giving empty and already-transformed documents special cases. */
export function wouldTransformLines(text: string, mode: LineTransformMode): boolean {
  return transformLines(text, mode) !== text
}

function lineStarts(text: string): number[] {
  const starts = [0]
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] === '\n') starts.push(index + 1)
  }
  return starts
}

function lineIndexAt(starts: readonly number[], position: number): number {
  let low = 0
  let high = starts.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (starts[middle] <= position) low = middle + 1
    else high = middle
  }
  return Math.max(0, low - 1)
}

/**
 * Map a position inside a whole-line replacement without snapping every
 * interior endpoint to one of the replacement boundaries. Positions follow
 * their original line occurrence and UTF-16 column as lines move. Unique maps
 * every removed duplicate to the retained first occurrence of the same line.
 */
interface PlannedBlock extends LineTransformEdit {
  readonly original: string
  readonly sourceToOutput: readonly number[]
  readonly finalFrom: number
  readonly finalTo: number
  readonly rangeIndexes: readonly number[]
  readonly changed: boolean
}

function mapWithinReplacement(change: PlannedBlock, offset: number): number {
  const { original, insert, sourceToOutput } = change
  const clamped = Math.max(0, Math.min(original.length, offset))
  const originalDocument = splitLineDocument(original)
  const outputDocument = splitLineDocument(insert)
  const originalStarts = lineStarts(original)
  const outputStarts = lineStarts(insert)
  const originalLineIndex = lineIndexAt(originalStarts, clamped)

  // A trailing LF creates a structural empty line after the transformed
  // records. Keep an endpoint on that boundary at the new block end.
  if (originalDocument.trailingNewline && originalLineIndex >= originalDocument.lines.length) {
    return insert.length
  }

  const outputLineIndex = sourceToOutput[originalLineIndex]
  if (outputLineIndex >= outputDocument.lines.length) return insert.length
  const outputLineStart = outputStarts[outputLineIndex]
  const column = clamped - originalStarts[originalLineIndex]
  return outputLineStart + Math.min(column, outputDocument.lines[outputLineIndex].length)
}

function mapPositionThroughChanges(
  text: string,
  changes: readonly PlannedBlock[],
  position: number
): number {
  const clamped = Math.max(0, Math.min(text.length, position))
  let delta = 0
  for (const change of changes) {
    if (clamped < change.from) break
    const followsFinalLine = clamped === change.to
      && change.to === text.length
      && !change.original.endsWith('\n')
    if (clamped < change.to || followsFinalLine) {
      return change.finalFrom + mapWithinReplacement(change, clamped - change.from)
    }
    delta += change.insert.length - (change.to - change.from)
  }
  return clamped + delta
}

/**
 * Expand every non-empty selection to complete LF-delimited lines and build
 * independent, non-overlapping edits. Cursor and selection positions are
 * mapped explicitly; when all ranges are empty the command transforms the
 * whole document.
 */
export function planLineTransform(
  text: string,
  ranges: readonly TextSelectionRange[],
  mode: LineTransformMode
): LineTransformPlan {
  const selected = ranges
    .map((range, index) => ({ range, index }))
    .filter(({ range }) => range.anchor !== range.head)
  const spans = selected.length === 0
    ? [{ from: 0, to: text.length, rangeIndexes: [] as number[] }]
    : selected.map(({ range, index }) => {
        const from = Math.max(0, Math.min(text.length, Math.min(range.anchor, range.head)))
        const to = Math.max(0, Math.min(text.length, Math.max(range.anchor, range.head)))
        // lastIndexOf clamps a negative start to zero, which would otherwise
        // mistake a leading newline for the boundary before position zero.
        const lineFrom = from === 0 ? 0 : text.lastIndexOf('\n', from - 1) + 1
        const endpoint = to > from && text[to - 1] === '\n' ? to - 1 : to
        const nextBreak = text.indexOf('\n', endpoint)
        return { from: lineFrom, to: nextBreak < 0 ? text.length : nextBreak + 1, rangeIndexes: [index] }
      })

  const merged: Array<{ from: number; to: number; rangeIndexes: number[] }> = []
  for (const span of spans.sort((left, right) => left.from - right.from || left.to - right.to)) {
    const previous = merged[merged.length - 1]
    if (previous && span.from < previous.to) {
      previous.to = Math.max(previous.to, span.to)
      previous.rangeIndexes.push(...span.rangeIndexes)
    } else {
      merged.push({ ...span, rangeIndexes: [...span.rangeIndexes] })
    }
  }

  if (mode === 'remove-blank') return planRemoveBlankLines(text, ranges, merged)

  let delta = 0
  const plannedBlocks: PlannedBlock[] = []
  for (const { from, to, rangeIndexes } of merged) {
    const original = text.slice(from, to)
    const transformed = transformLineDocument(original, mode)
    const changed = transformed.text !== original
    const finalFrom = from + delta
    const finalTo = finalFrom + transformed.text.length
    plannedBlocks.push({
      from,
      to,
      insert: transformed.text,
      original,
      sourceToOutput: transformed.sourceToOutput,
      finalFrom,
      finalTo,
      rangeIndexes,
      changed
    })
    if (changed) delta += transformed.text.length - (to - from)
  }

  const changes = plannedBlocks.filter(({ changed }) => changed)
  if (changes.length === 0) {
    return { changes: [], ranges: ranges.map(({ anchor, head }) => ({ anchor, head })) }
  }

  const targetBlockByRange = new Map<number, PlannedBlock>()
  plannedBlocks.forEach((block) => {
    block.rangeIndexes.forEach((rangeIndex) => targetBlockByRange.set(rangeIndex, block))
  })
  const mappedRanges = ranges.map(({ anchor, head }, index) => {
    const block = targetBlockByRange.get(index)
    if (anchor !== head && block) {
      return anchor <= head
        ? { anchor: block.finalFrom, head: block.finalTo }
        : { anchor: block.finalTo, head: block.finalFrom }
    }
    return {
      anchor: mapPositionThroughChanges(text, changes, anchor),
      head: mapPositionThroughChanges(text, changes, head)
    }
  })
  return {
    changes: changes.map(({ from, to, insert }) => ({ from, to, insert })),
    ranges: mappedRanges
  }
}

function planRemoveBlankLines(
  text: string,
  ranges: readonly TextSelectionRange[],
  targets: readonly { from: number; to: number; rangeIndexes: readonly number[] }[]
): LineTransformPlan {
  const removals: LineTransformEdit[] = []
  for (const target of targets) {
    let lineStart = target.from
    while (lineStart < target.to) {
      const nextBreak = text.indexOf('\n', lineStart)
      const lineEnd = nextBreak < 0 || nextBreak >= target.to ? target.to : nextBreak
      if (/^[\t ]*$/.test(text.slice(lineStart, lineEnd))) {
        removals.push({
          from: lineStart,
          to: lineEnd < target.to && text[lineEnd] === '\n' ? lineEnd + 1 : lineEnd,
          insert: ''
        })
      }
      if (lineEnd >= target.to) break
      lineStart = lineEnd + 1
    }
  }

  const changes: LineTransformEdit[] = []
  for (const removal of removals.sort((left, right) => left.from - right.from || left.to - right.to)) {
    if (removal.from === removal.to) continue
    const previous = changes[changes.length - 1]
    if (previous && removal.from <= previous.to) {
      changes[changes.length - 1] = { from: previous.from, to: Math.max(previous.to, removal.to), insert: '' }
    } else {
      changes.push(removal)
    }
  }

  // A final physical line without its own line break is separated by the
  // preceding LF. Remove that separator with a deleted terminal blank run so
  // the command does not leave a new final empty line behind.
  const terminal = changes[changes.length - 1]
  if (terminal && terminal.to === text.length && !text.endsWith('\n')
    && terminal.from > 0 && text[terminal.from - 1] === '\n') {
    changes[changes.length - 1] = { ...terminal, from: terminal.from - 1 }
    const previous = changes[changes.length - 2]
    if (previous && previous.to >= terminal.from - 1) {
      changes.splice(changes.length - 2, 2, { from: previous.from, to: terminal.to, insert: '' })
    }
  }

  if (changes.length === 0) {
    return { changes: [], ranges: ranges.map(({ anchor, head }) => ({ anchor, head })) }
  }

  const mapPosition = (position: number): number => {
    const clamped = Math.max(0, Math.min(text.length, position))
    let delta = 0
    for (const change of changes) {
      if (clamped < change.from) break
      if (clamped <= change.to) return change.from + delta
      delta -= change.to - change.from
    }
    return clamped + delta
  }

  const targetByRange = new Map<number, { from: number; to: number }>()
  targets.forEach((target) => {
    const mapped = { from: mapPosition(target.from), to: mapPosition(target.to) }
    target.rangeIndexes.forEach((rangeIndex) => targetByRange.set(rangeIndex, mapped))
  })
  const mappedRanges = ranges.map(({ anchor, head }, index) => {
    const target = targetByRange.get(index)
    if (anchor !== head && target) {
      return anchor <= head
        ? { anchor: target.from, head: target.to }
        : { anchor: target.to, head: target.from }
    }
    return { anchor: mapPosition(anchor), head: mapPosition(head) }
  })
  return { changes, ranges: mappedRanges }
}

export function lineTransformEdits(
  text: string,
  ranges: readonly TextSelectionRange[],
  mode: LineTransformMode
): LineTransformEdit[] {
  return planLineTransform(text, ranges, mode).changes
}
