import { TextDecoder } from 'util'
import iconv from 'iconv-lite'
import { textEncodingLabel } from '../shared/text.js'
import type { TextEncoding } from '../shared/ipc.js'

const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf])
const UTF16LE_BOM = Buffer.from([0xff, 0xfe])
const UTF16BE_BOM = Buffer.from([0xfe, 0xff])

const LEGACY_CODEC_NAMES: Readonly<Partial<Record<TextEncoding, string>>> = {
  gb18030: 'gb18030',
  gbk: 'gbk',
  big5: 'big5',
  shiftjis: 'shift_jis',
  windows1252: 'windows-1252',
  iso88591: 'iso-8859-1'
}

export interface AutoDecodedText {
  content: string
  encoding: TextEncoding
  /** True when malformed bytes were replaced so the file can still be shown. */
  hadDecodingErrors: boolean
  /** True when the encoding came from a conservative content heuristic. */
  uncertain: boolean
}

function startsWith(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (bytes.byteLength < prefix.byteLength) return false
  for (let index = 0; index < prefix.byteLength; index += 1) {
    if (bytes[index] !== prefix[index]) return false
  }
  return true
}

/**
 * Guess BOM-less UTF-16 only for ASCII-like text with a strong NUL-byte lane.
 * This intentionally leaves short and ambiguous content as UTF-8. Pure CJK
 * UTF-16 commonly has no NULs and therefore cannot be identified safely.
 */
function detectBomlessUtf16(bytes: Uint8Array): TextEncoding | null {
  if (bytes.byteLength < 8 || bytes.byteLength % 2 !== 0) return null

  const pairCount = Math.min(bytes.byteLength / 2, 4_096)
  let evenNuls = 0
  let oddNuls = 0
  let evenAsciiLike = 0
  let oddAsciiLike = 0
  for (let pair = 0; pair < pairCount; pair += 1) {
    const even = bytes[pair * 2]
    const odd = bytes[pair * 2 + 1]
    if (even === 0) evenNuls += 1
    if (odd === 0) oddNuls += 1
    if (even === 0x09 || even === 0x0a || even === 0x0d || (even >= 0x20 && even <= 0x7e)) evenAsciiLike += 1
    if (odd === 0x09 || odd === 0x0a || odd === 0x0d || (odd >= 0x20 && odd <= 0x7e)) oddAsciiLike += 1
  }

  // A 60% expected NUL lane permits some non-ASCII text, while requiring the
  // other lane to be <= 5% avoids binary data with NULs in both lanes.
  const expectedNulMinimum = Math.ceil(pairCount * 0.6)
  const unexpectedNulMaximum = Math.floor(pairCount * 0.05)
  const asciiMinimum = Math.ceil(pairCount * 0.6)
  if (oddNuls >= expectedNulMinimum && evenNuls <= unexpectedNulMaximum && evenAsciiLike >= asciiMinimum) {
    return 'utf16le-nobom'
  }
  if (evenNuls >= expectedNulMinimum && oddNuls <= unexpectedNulMaximum && oddAsciiLike >= asciiMinimum) {
    return 'utf16be-nobom'
  }
  return null
}

/** Detect only byte-order-marked Unicode or cautiously recognisable UTF-16. */
export function detectTextEncoding(bytes: Uint8Array): TextEncoding {
  // BOMs always win over content heuristics. These three prefixes are checked
  // in longest-first order for clarity and future extensibility.
  if (startsWith(bytes, UTF8_BOM)) return 'utf8bom'
  if (startsWith(bytes, UTF16LE_BOM)) return 'utf16le'
  if (startsWith(bytes, UTF16BE_BOM)) return 'utf16be'
  return detectBomlessUtf16(bytes) ?? 'utf8'
}

function bomLengthFor(bytes: Uint8Array, encoding: TextEncoding): number {
  if (encoding === 'utf8bom' && startsWith(bytes, UTF8_BOM)) return UTF8_BOM.byteLength
  if (encoding === 'utf16le' && startsWith(bytes, UTF16LE_BOM)) return UTF16LE_BOM.byteLength
  if (encoding === 'utf16be' && startsWith(bytes, UTF16BE_BOM)) return UTF16BE_BOM.byteLength
  return 0
}

function unicodeDecoderLabel(encoding: TextEncoding): 'utf-8' | 'utf-16le' | 'utf-16be' | null {
  if (encoding === 'utf8' || encoding === 'utf8bom') return 'utf-8'
  if (encoding === 'utf16le' || encoding === 'utf16le-nobom') return 'utf-16le'
  if (encoding === 'utf16be' || encoding === 'utf16be-nobom') return 'utf-16be'
  return null
}

function decodeUnicode(bytes: Uint8Array, encoding: TextEncoding, fatal: boolean): string {
  const label = unicodeDecoderLabel(encoding)
  if (!label) throw new Error(`Unsupported Unicode encoding: ${encoding}`)
  const offset = bomLengthFor(bytes, encoding)
  const payload = bytes.subarray(offset)
  if (label !== 'utf-8' && payload.byteLength % 2 !== 0) {
    throw new Error(`Invalid ${textEncodingLabel(encoding)} data: the UTF-16 byte length is odd.`)
  }
  // ignoreBOM=true means TextDecoder preserves any BOM we did not explicitly
  // remove above. Thus a mismatched BOM is never silently stripped.
  return new TextDecoder(label, { fatal, ignoreBOM: true }).decode(payload)
}

/**
 * Decode bytes using an explicitly selected encoding. Malformed Unicode is an
 * error, and a BOM is removed only when it exactly matches that encoding.
 */
export function decodeTextBytes(bytes: Uint8Array, encoding: TextEncoding): string {
  const unicodeLabel = unicodeDecoderLabel(encoding)
  if (unicodeLabel) {
    try {
      return decodeUnicode(bytes, encoding, true)
    } catch (error) {
      if (error instanceof Error && /UTF-16 byte length is odd/.test(error.message)) throw error
      throw new Error(`Invalid ${textEncodingLabel(encoding)} data.`, { cause: error })
    }
  }

  const codec = LEGACY_CODEC_NAMES[encoding]
  if (!codec) throw new Error(`Unsupported text encoding: ${encoding as string}`)
  return iconv.decode(Buffer.from(bytes), codec, { stripBOM: false })
}

/** Alias kept convenient for callers that do not already have an encodeText. */
export const decodeText = decodeTextBytes

/**
 * Decode with a selected encoding for display while retaining a precise
 * warning when malformed or non-round-trippable bytes had to be replaced.
 * Explicit reopen, file watching, and conflict previews must still return the
 * current disk snapshot instead of turning a decode problem into an I/O error.
 */
export function decodeTextWithEncoding(bytes: Uint8Array, encoding: TextEncoding): AutoDecodedText {
  // The BOM-bearing IDs describe the physical bytes, not merely the decoder.
  // If the user selects one for a file without that BOM, retain the actual
  // no-BOM representation so the status bar and dirty baseline stay truthful.
  const physicalEncoding: TextEncoding = encoding === 'utf8bom' && !startsWith(bytes, UTF8_BOM)
    ? 'utf8'
    : encoding === 'utf16le' && !startsWith(bytes, UTF16LE_BOM)
      ? 'utf16le-nobom'
      : encoding === 'utf16be' && !startsWith(bytes, UTF16BE_BOM)
        ? 'utf16be-nobom'
        : encoding
  let content: string
  let hadDecodingErrors = false
  try {
    content = decodeTextBytes(bytes, encoding)
  } catch {
    const label = unicodeDecoderLabel(encoding)
    if (!label) throw new Error(`Invalid ${textEncodingLabel(encoding)} data.`)
    hadDecodingErrors = true
    const offset = bomLengthFor(bytes, encoding)
    const payload = bytes.subarray(offset)
    const complete = label === 'utf-8'
      ? payload
      : payload.subarray(0, payload.byteLength - (payload.byteLength % 2))
    content = new TextDecoder(label, { fatal: false, ignoreBOM: true }).decode(complete)
    if (payload.byteLength !== complete.byteLength) content += '\ufffd'
  }

  try {
    if (!encodeTextBytes(content, physicalEncoding).equals(Buffer.from(bytes))) hadDecodingErrors = true
  } catch {
    hadDecodingErrors = true
  }
  return { content, encoding: physicalEncoding, hadDecodingErrors, uncertain: false }
}

/**
 * Auto-decode BOM Unicode and conservatively detected BOM-less UTF-16. Bytes
 * without either are treated as UTF-8; malformed UTF-8 remains displayable but
 * is surfaced to callers for a "reopen with encoding" prompt.
 */
export function decodeTextAuto(bytes: Uint8Array): AutoDecodedText {
  const encoding = detectTextEncoding(bytes)
  const uncertain = encoding === 'utf16le-nobom' || encoding === 'utf16be-nobom'
  const decoded = decodeTextWithEncoding(bytes, encoding)
  return { ...decoded, uncertain }
}

/** Encode Unicode and legacy formats without silently replacing characters. */
export function encodeTextBytes(content: string, encoding: TextEncoding): Buffer {
  // JavaScript strings can contain isolated UTF-16 surrogate code units. Most
  // encoders replace them silently, so reject them before writing any format.
  for (let index = 0; index < content.length; index += 1) {
    const code = content.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff) {
      const low = content.charCodeAt(index + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        index += 1
        continue
      }
      throw new Error(`${textEncodingLabel(encoding)} cannot represent malformed Unicode text without data loss.`)
    }
    if (code >= 0xdc00 && code <= 0xdfff) {
      throw new Error(`${textEncodingLabel(encoding)} cannot represent malformed Unicode text without data loss.`)
    }
  }
  if (encoding === 'utf8') return Buffer.from(content, 'utf8')
  if (encoding === 'utf8bom') return Buffer.concat([UTF8_BOM, Buffer.from(content, 'utf8')])
  if (encoding === 'utf16le' || encoding === 'utf16le-nobom') {
    const body = Buffer.from(content, 'utf16le')
    return encoding === 'utf16le' ? Buffer.concat([UTF16LE_BOM, body]) : body
  }
  if (encoding === 'utf16be' || encoding === 'utf16be-nobom') {
    const body = Buffer.from(content, 'utf16le')
    body.swap16()
    return encoding === 'utf16be' ? Buffer.concat([UTF16BE_BOM, body]) : body
  }

  const codec = LEGACY_CODEC_NAMES[encoding]
  if (!codec) throw new Error(`Unsupported text encoding: ${encoding as string}`)
  const encoded = iconv.encode(content, codec)
  const roundTripped = iconv.decode(encoded, codec, { stripBOM: false })
  if (roundTripped !== content) {
    throw new Error(`${textEncodingLabel(encoding)} cannot represent every character in this document without data loss.`)
  }
  return encoded
}
