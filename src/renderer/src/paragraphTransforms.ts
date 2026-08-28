export type ParagraphTransformMode = 'wrap' | 'unwrap'
export type ParagraphMarker = '' | '#' | '//' | '///'

export interface TextSelectionRange {
  readonly anchor: number
  readonly head: number
}

export interface ParagraphTransformEdit {
  readonly from: number
  readonly to: number
  readonly insert: string
}

export interface ParagraphLine {
  readonly lineIndex: number
  readonly from: number
  readonly to: number
  readonly text: string
  readonly indent: string
  readonly marker: ParagraphMarker
  readonly prefix: string
  readonly contentFrom: number
  readonly content: string
  readonly isBoundary: boolean
}

export interface ParagraphBlock {
  readonly from: number
  readonly to: number
  readonly text: string
  readonly indent: string
  readonly marker: ParagraphMarker
  readonly prefix: string
  readonly lines: readonly ParagraphLine[]
}

export interface ParagraphTransformPlan {
  readonly changes: ParagraphTransformEdit[]
  readonly ranges: TextSelectionRange[]
}

export interface ParagraphTransformOptions {
  readonly column?: number
  readonly tabWidth?: number
}

export interface ResolvedParagraphTransformOptions {
  readonly column: number
  readonly tabWidth: number
}

interface DocumentLine {
  readonly index: number
  readonly start: number
  readonly end: number
  readonly text: string
  readonly virtual: boolean
}

interface ParagraphToken {
  readonly text: string
  readonly sourceFrom: number
  readonly sourceTo: number
  readonly logicalFrom: number
  readonly logicalTo: number
}

interface ParagraphLayout {
  readonly text: string
  readonly tokens: readonly ParagraphToken[]
  readonly logicalLength: number
}

interface PlannedParagraph {
  readonly paragraphIndex: number
  readonly paragraph: ParagraphBlock
  readonly transformed: string
  readonly changed: boolean
  readonly finalFrom: number
  readonly finalTo: number
  readonly sourceLayout?: ParagraphLayout
  readonly outputLayout?: ParagraphLayout
}

const DEFAULT_WRAP_COLUMN = 80
const DEFAULT_TAB_WIDTH = 8
const MARKERS: readonly ParagraphMarker[] = ['///', '//', '#', '']
const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function isHorizontalWhitespace(character: string | undefined): boolean {
  return character === ' ' || character === '\t'
}

function sanitizePositiveInteger(value: number | undefined, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  const rounded = Math.floor(value)
  return rounded > 0 ? rounded : fallback
}

export function sanitizeParagraphTransformOptions(
  options?: ParagraphTransformOptions
): ResolvedParagraphTransformOptions {
  return {
    column: sanitizePositiveInteger(options?.column, DEFAULT_WRAP_COLUMN),
    tabWidth: sanitizePositiveInteger(options?.tabWidth, DEFAULT_TAB_WIDTH)
  }
}

function nextTabStop(column: number, tabWidth: number): number {
  return column + tabWidth - (column % tabWidth)
}

function graphemeCount(text: string): number {
  let count = 0
  for (const _segment of graphemeSegmenter.segment(text)) count += 1
  return count
}

export function measurePrefixColumns(prefix: string, tabWidth = DEFAULT_TAB_WIDTH): number {
  let column = 0
  for (const { segment } of graphemeSegmenter.segment(prefix)) {
    column = segment === '\t' ? nextTabStop(column, tabWidth) : column + 1
  }
  return column
}

export function splitParagraphTokens(content: string): string[] {
  return content.match(/[^\t ]+/g) ?? []
}

function splitDocumentLines(text: string): DocumentLine[] {
  if (text.length === 0) {
    return [{ index: 0, start: 0, end: 0, text: '', virtual: true }]
  }

  const lines: DocumentLine[] = []
  let lineStart = 0
  let lineIndex = 0
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] !== '\n') continue
    lines.push({
      index: lineIndex,
      start: lineStart,
      end: index,
      text: text.slice(lineStart, index),
      virtual: false
    })
    lineStart = index + 1
    lineIndex += 1
  }

  if (!text.endsWith('\n')) {
    lines.push({
      index: lineIndex,
      start: lineStart,
      end: text.length,
      text: text.slice(lineStart),
      virtual: false
    })
  } else {
    lines.push({
      index: lineIndex,
      start: text.length,
      end: text.length,
      text: '',
      virtual: true
    })
  }

  return lines
}

function markerLength(rest: string): number {
  for (const marker of MARKERS) {
    if (marker === '') return 0
    if (!rest.startsWith(marker)) continue
    const next = rest[marker.length]
    if (next == null || isHorizontalWhitespace(next)) return marker.length
  }
  return 0
}

export function classifyParagraphLine(
  line: string,
  lineIndex = 0,
  from = 0,
  to = line.length
): ParagraphLine {
  const indent = (/^[\t ]*/u.exec(line) ?? [''])[0]
  const rest = line.slice(indent.length)
  const recognisedMarkerLength = markerLength(rest)
  const marker = recognisedMarkerLength === 3
    ? '///'
    : recognisedMarkerLength === 2
      ? '//'
      : recognisedMarkerLength === 1
        ? '#'
        : ''
  const prefixBase = indent + marker

  if (rest.length === 0 || /^[\t ]*$/u.test(rest)) {
    return {
      lineIndex,
      from,
      to,
      text: line,
      indent,
      marker: '',
      prefix: indent,
      contentFrom: line.length,
      content: '',
      isBoundary: true
    }
  }

  if (marker !== '') {
    let contentFrom = indent.length + marker.length
    while (contentFrom < line.length && isHorizontalWhitespace(line[contentFrom])) contentFrom += 1
    const content = line.slice(contentFrom)
    if (content.length === 0) {
      return {
        lineIndex,
        from,
        to,
        text: line,
        indent,
        marker,
        prefix: `${prefixBase} `,
        contentFrom,
        content: '',
        isBoundary: true
      }
    }
    return {
      lineIndex,
      from,
      to,
      text: line,
      indent,
      marker,
      prefix: `${prefixBase} `,
      contentFrom,
      content,
      isBoundary: false
    }
  }

  return {
    lineIndex,
    from,
    to,
    text: line,
    indent,
    marker: '',
    prefix: indent,
    contentFrom: indent.length,
    content: rest,
    isBoundary: false
  }
}

function buildParagraphs(text: string): {
  readonly lines: readonly DocumentLine[]
  readonly paragraphs: readonly ParagraphBlock[]
  readonly paragraphByLineIndex: readonly number[]
  readonly lineStarts: readonly number[]
} {
  const lines = splitDocumentLines(text)
  const paragraphByLineIndex = new Array<number>(lines.length).fill(-1)
  const paragraphs: ParagraphBlock[] = []
  const lineStarts = lines.map((line) => line.start)

  let currentLines: ParagraphLine[] = []

  const flushCurrent = () => {
    if (currentLines.length === 0) return
    const first = currentLines[0]
    const last = currentLines[currentLines.length - 1]
    const paragraphIndex = paragraphs.length
    const paragraph: ParagraphBlock = {
      from: first.from,
      to: last.to,
      text: text.slice(first.from, last.to),
      indent: first.indent,
      marker: first.marker,
      prefix: first.prefix,
      lines: currentLines
    }
    paragraphs.push(paragraph)
    for (const line of currentLines) paragraphByLineIndex[line.lineIndex] = paragraphIndex
    currentLines = []
  }

  for (const line of lines) {
    const classified = classifyParagraphLine(line.text, line.index, line.start, line.end)
    if (line.virtual || classified.isBoundary) {
      flushCurrent()
      continue
    }

    const previous = currentLines[currentLines.length - 1]
    if (previous && (previous.indent !== classified.indent || previous.marker !== classified.marker)) {
      flushCurrent()
    }
    currentLines.push(classified)
  }
  flushCurrent()

  return { lines, paragraphs, paragraphByLineIndex, lineStarts }
}

export function findParagraphBlocks(text: string): ParagraphBlock[] {
  return [...buildParagraphs(text).paragraphs]
}

function lineIndexAt(lineStarts: readonly number[], position: number): number {
  let low = 0
  let high = lineStarts.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (lineStarts[middle] <= position) low = middle + 1
    else high = middle
  }
  return Math.max(0, low - 1)
}

function isLineStart(lineStarts: readonly number[], position: number): boolean {
  const index = lineIndexAt(lineStarts, position)
  return lineStarts[index] === position
}

function paragraphIndexesForRange(
  text: string,
  lineStarts: readonly number[],
  paragraphByLineIndex: readonly number[],
  range: TextSelectionRange
): number[] {
  const minPosition = Math.max(0, Math.min(text.length, Math.min(range.anchor, range.head)))
  const maxPosition = Math.max(0, Math.min(text.length, Math.max(range.anchor, range.head)))

  if (range.anchor === range.head) {
    const lineIndex = lineIndexAt(lineStarts, minPosition)
    const paragraphIndex = paragraphByLineIndex[lineIndex]
    return paragraphIndex < 0 ? [] : [paragraphIndex]
  }

  const effectiveEnd = maxPosition > minPosition && isLineStart(lineStarts, maxPosition)
    ? Math.max(minPosition, maxPosition - 1)
    : maxPosition
  const startLineIndex = lineIndexAt(lineStarts, minPosition)
  const endLineIndex = lineIndexAt(lineStarts, effectiveEnd)
  const paragraphIndexes: number[] = []
  for (let lineIndex = startLineIndex; lineIndex <= endLineIndex; lineIndex += 1) {
    const paragraphIndex = paragraphByLineIndex[lineIndex]
    if (paragraphIndex < 0 || paragraphIndexes[paragraphIndexes.length - 1] === paragraphIndex) continue
    paragraphIndexes.push(paragraphIndex)
  }
  return paragraphIndexes
}

function paragraphTokens(block: ParagraphBlock): string[] {
  const tokens: string[] = []
  for (const line of block.lines) tokens.push(...splitParagraphTokens(line.content))
  return tokens
}

function wrapTokens(
  prefix: string,
  tokens: readonly string[],
  options: ResolvedParagraphTransformOptions
): string {
  if (tokens.length === 0) return prefix.trimEnd()

  const prefixColumns = measurePrefixColumns(prefix, options.tabWidth)
  const lines: string[] = []
  let currentTokens: string[] = []
  let currentColumns = prefixColumns

  for (const token of tokens) {
    const tokenColumns = graphemeCount(token)
    if (currentTokens.length === 0) {
      currentTokens.push(token)
      currentColumns = prefixColumns + tokenColumns
      continue
    }
    if (currentColumns + 1 + tokenColumns <= options.column) {
      currentTokens.push(token)
      currentColumns += 1 + tokenColumns
      continue
    }
    lines.push(`${prefix}${currentTokens.join(' ')}`)
    currentTokens = [token]
    currentColumns = prefixColumns + tokenColumns
  }

  lines.push(`${prefix}${currentTokens.join(' ')}`)
  return lines.join('\n')
}

export function wrapParagraphBlock(
  block: ParagraphBlock,
  options?: ParagraphTransformOptions
): string {
  return wrapTokens(block.prefix, paragraphTokens(block), sanitizeParagraphTransformOptions(options))
}

export function unwrapParagraphBlock(block: ParagraphBlock): string {
  return `${block.prefix}${paragraphTokens(block).join(' ')}`
}

function buildParagraphLayout(text: string): ParagraphLayout {
  if (text.length === 0) return { text, tokens: [], logicalLength: 0 }

  const tokens: ParagraphToken[] = []
  let logicalLength = 0
  let lineStart = 0
  let lineIndex = 0
  const lines = text.split('\n')
  for (const line of lines) {
    const classified = classifyParagraphLine(line, lineIndex, lineStart, lineStart + line.length)
    const content = line.slice(classified.contentFrom)
    for (const match of content.matchAll(/[^\t ]+/gu)) {
      const token = match[0]
      const sourceFrom = lineStart + classified.contentFrom + (match.index ?? 0)
      const logicalFrom = logicalLength
      if (tokens.length > 0) logicalLength += 1
      const adjustedLogicalFrom = tokens.length > 0 ? logicalFrom + 1 : logicalFrom
      tokens.push({
        text: token,
        sourceFrom,
        sourceTo: sourceFrom + token.length,
        logicalFrom: adjustedLogicalFrom,
        logicalTo: adjustedLogicalFrom + token.length
      })
      logicalLength = adjustedLogicalFrom + token.length
    }
    lineStart += line.length + 1
    lineIndex += 1
  }
  return { text, tokens, logicalLength }
}

function mapSourceOffsetToLogical(layout: ParagraphLayout, offset: number): number | 'start' | 'end' {
  const clamped = Math.max(0, Math.min(layout.text.length, offset))
  if (clamped === 0) return 'start'
  if (clamped === layout.text.length) return 'end'

  for (const token of layout.tokens) {
    if (clamped < token.sourceFrom) return token.logicalFrom
    if (clamped <= token.sourceTo) return token.logicalFrom + (clamped - token.sourceFrom)
  }
  return 'end'
}

function mapLogicalToOutput(layout: ParagraphLayout, logical: number | 'start' | 'end'): number {
  if (logical === 'start') return 0
  if (logical === 'end') return layout.text.length
  const clamped = Math.max(0, Math.min(layout.logicalLength, logical))
  for (const token of layout.tokens) {
    if (clamped < token.logicalFrom) return token.sourceFrom
    if (clamped <= token.logicalTo) return token.sourceFrom + (clamped - token.logicalFrom)
  }
  return layout.text.length
}

function mapOffsetWithinParagraph(block: PlannedParagraph, offset: number): number {
  if (!block.changed || !block.sourceLayout || !block.outputLayout) return Math.max(0, Math.min(block.transformed.length, offset))
  const firstSourceToken = block.sourceLayout.tokens[0]
  const firstOutputToken = block.outputLayout.tokens[0]
  // The first line's indentation and structural marker survive the reflow.
  // Keep carets in that prefix at the same position, clamping only whitespace
  // that was normalised after a comment marker.
  if (firstSourceToken && firstOutputToken && offset <= firstSourceToken.sourceFrom) {
    return Math.min(offset, firstOutputToken.sourceFrom)
  }
  return mapLogicalToOutput(block.outputLayout, mapSourceOffsetToLogical(block.sourceLayout, offset))
}

function transformParagraph(
  block: ParagraphBlock,
  mode: ParagraphTransformMode,
  options: ResolvedParagraphTransformOptions
): string {
  return mode === 'wrap' ? wrapTokens(block.prefix, paragraphTokens(block), options) : unwrapParagraphBlock(block)
}

function mapPositionThroughParagraphs(planned: readonly PlannedParagraph[], textLength: number, position: number): number {
  const clamped = Math.max(0, Math.min(textLength, position))
  let delta = 0
  for (const block of planned) {
    if (clamped < block.paragraph.from) break
    if (clamped <= block.paragraph.to) {
      return block.changed
        ? block.finalFrom + mapOffsetWithinParagraph(block, clamped - block.paragraph.from)
        : block.finalFrom + (clamped - block.paragraph.from)
    }
    delta += block.transformed.length - block.paragraph.text.length
  }
  return clamped + delta
}

export function paragraphTransformEdits(
  text: string,
  ranges: readonly TextSelectionRange[],
  mode: ParagraphTransformMode,
  options?: ParagraphTransformOptions
): ParagraphTransformEdit[] {
  return planParagraphTransform(text, ranges, mode, options).changes
}

export function planParagraphTransform(
  text: string,
  ranges: readonly TextSelectionRange[],
  mode: ParagraphTransformMode,
  options?: ParagraphTransformOptions
): ParagraphTransformPlan {
  const resolvedOptions = sanitizeParagraphTransformOptions(options)
  const { paragraphs, paragraphByLineIndex, lineStarts } = buildParagraphs(text)
  const paragraphIndexesByRange = ranges.map((range) =>
    paragraphIndexesForRange(text, lineStarts, paragraphByLineIndex, range)
  )

  const targetedParagraphIndexes: number[] = []
  const targetedSet = new Set<number>()
  for (const paragraphIndexes of paragraphIndexesByRange) {
    for (const paragraphIndex of paragraphIndexes) {
      if (targetedSet.has(paragraphIndex)) continue
      targetedSet.add(paragraphIndex)
      targetedParagraphIndexes.push(paragraphIndex)
    }
  }
  targetedParagraphIndexes.sort((left, right) => paragraphs[left].from - paragraphs[right].from)

  let delta = 0
  const planned: PlannedParagraph[] = []
  for (const paragraphIndex of targetedParagraphIndexes) {
    const paragraph = paragraphs[paragraphIndex]
    const transformed = transformParagraph(paragraph, mode, resolvedOptions)
    const changed = transformed !== paragraph.text
    const finalFrom = paragraph.from + delta
    const finalTo = finalFrom + transformed.length
    planned.push({
      paragraphIndex,
      paragraph,
      transformed,
      changed,
      finalFrom,
      finalTo,
      sourceLayout: changed ? buildParagraphLayout(paragraph.text) : undefined,
      outputLayout: changed ? buildParagraphLayout(transformed) : undefined
    })
    delta += transformed.length - paragraph.text.length
  }

  const changes = planned
    .filter((block) => block.changed)
    .map(({ paragraph, transformed }) => ({
      from: paragraph.from,
      to: paragraph.to,
      insert: transformed
    }))

  if (changes.length === 0) {
    return {
      changes: [],
      ranges: ranges.map(({ anchor, head }) => ({ anchor, head }))
    }
  }

  const mappedRanges = ranges.map(({ anchor, head }) => ({
    anchor: mapPositionThroughParagraphs(planned, text.length, anchor),
    head: mapPositionThroughParagraphs(planned, text.length, head)
  }))

  return { changes, ranges: mappedRanges }
}
