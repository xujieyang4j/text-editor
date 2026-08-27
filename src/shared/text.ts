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

/** Keep editor/session text in one logical form; `eol` carries the disk format. */
export function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n|\r/g, '\n')
}

/** Exact UTF-8 byte length of a string as encoded inside JSON, including quotes. */
export function jsonStringUtf8ByteLength(value: string, stopAfter = Number.POSITIVE_INFINITY): number {
  let bytes = 2
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code === 0x22 || code === 0x5c || code === 0x08 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d) bytes += 2
    else if (code < 0x20) bytes += 6
    else if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const low = value.charCodeAt(index + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4
        index += 1
      } else bytes += 6
    } else if (code >= 0xd800 && code <= 0xdfff) bytes += 6
    else bytes += 3
    if (bytes > stopAfter) return bytes
  }
  return bytes
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
