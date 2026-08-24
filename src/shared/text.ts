import type { LineEnding, TextEncoding } from './ipc.js'

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
