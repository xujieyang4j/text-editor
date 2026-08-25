import type { LineEnding, TextEncoding } from './ipc.js'

/** Unicode-aware statistics for a document or a selected text range. */
export interface TextStatistics {
  lines: number
  characters: number
  charactersExcludingWhitespace: number
  words: number
}

/**
 * Count user-visible characters (grapheme clusters) and word-like segments.
 * Intl.Segmenter handles CJK text, combining marks, and emoji more faithfully
 * than UTF-16 string length or an ASCII-only whitespace split.
 */
export function textStatistics(text: string): TextStatistics {
  const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
  const words = new Intl.Segmenter(undefined, { granularity: 'word' })
  let characters = 0
  let charactersExcludingWhitespace = 0
  for (const segment of graphemes.segment(text)) {
    characters += 1
    if (!/^\s$/u.test(segment.segment)) charactersExcludingWhitespace += 1
  }
  let wordCount = 0
  for (const segment of words.segment(text)) if (segment.isWordLike) wordCount += 1
  return {
    lines: text === '' ? 0 : text.split(/\r\n|\r|\n/).length,
    characters,
    charactersExcludingWhitespace,
    words: wordCount
  }
}

/** Detect the physical newline convention before CodeMirror normalises it. */
export function detectLineEnding(text: string): LineEnding {
  if (/\r\n/.test(text)) return 'CRLF'
  if (/\r(?!\n)/.test(text)) return 'CR'
  return 'LF'
}

/** Preserve a file's newline convention whenever editor text returns to disk. */
export function applyLineEnding(text: string, eol: LineEnding): string {
  const lineBreak = eol === 'CRLF' ? '\r\n' : eol === 'CR' ? '\r' : '\n'
  return text.replace(/\r\n|\r|\n/g, lineBreak)
}

/** Encode the built-in set of portable text encodings, including their BOMs. */
export function encodeText(content: string, encoding: TextEncoding, eol: LineEnding): Buffer {
  const normalized = applyLineEnding(content, eol)
  if (encoding === 'utf8bom') return Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(normalized, 'utf8')])
  if (encoding === 'utf16le') return Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(normalized, 'utf16le')])
  if (encoding === 'utf16be') {
    const body = Buffer.from(normalized, 'utf16le')
    body.swap16()
    return Buffer.concat([Buffer.from([0xfe, 0xff]), body])
  }
  return Buffer.from(normalized, 'utf8')
}
