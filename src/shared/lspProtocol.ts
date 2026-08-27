/** Maximum number of bytes accepted before an LSP header delimiter. */
export const MAX_LSP_HEADER_BYTES = 16 * 1024

/** Maximum JSON payload size accepted from an LSP peer. */
export const MAX_LSP_PAYLOAD_BYTES = 8 * 1024 * 1024

export type LspMessage = Record<string, unknown>

/** A framing or payload error reported by an incremental LSP reader. */
export class LspProtocolError extends Error {
  readonly fatal: boolean

  constructor(message: string, fatal: boolean, options?: ErrorOptions) {
    super(message, options)
    this.name = 'LspProtocolError'
    this.fatal = fatal
  }
}

const headerSeparatorLength = 4
const headerBufferSize = MAX_LSP_HEADER_BYTES + headerSeparatorLength
const headerNamePattern = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
const headerValuePattern = /^[\t\x20-\x7e]*$/
const contentLengthPattern = /^[\t ]*([0-9]+)[\t ]*$/

type ParsedHeader =
  | { ok: true; length: number }
  | { ok: false; error: string }

function endsWithHeaderSeparator(buffer: Buffer, length: number): boolean {
  return length >= headerSeparatorLength &&
    buffer[length - 4] === 13 &&
    buffer[length - 3] === 10 &&
    buffer[length - 2] === 13 &&
    buffer[length - 1] === 10
}

function trailingHeaderSeparatorPrefixLength(buffer: Buffer, length: number): number {
  if (length >= 3 &&
      buffer[length - 3] === 13 &&
      buffer[length - 2] === 10 &&
      buffer[length - 1] === 13) {
    return 3
  }
  if (length >= 2 && buffer[length - 2] === 13 && buffer[length - 1] === 10) {
    return 2
  }
  return length >= 1 && buffer[length - 1] === 13 ? 1 : 0
}

function parseHeader(header: Buffer): ParsedHeader {
  if (header.length === 0) {
    return { ok: false, error: 'Missing LSP Content-Length header.' }
  }

  let contentLength: number | undefined
  for (const line of header.toString('ascii').split('\r\n')) {
    const colon = line.indexOf(':')
    if (colon < 1) return { ok: false, error: 'Malformed LSP header.' }

    const name = line.slice(0, colon)
    const value = line.slice(colon + 1)
    if (!headerNamePattern.test(name) || !headerValuePattern.test(value)) {
      return { ok: false, error: 'Malformed LSP header.' }
    }
    if (name.toLowerCase() !== 'content-length') continue
    if (contentLength !== undefined) {
      return { ok: false, error: 'Duplicate LSP Content-Length header.' }
    }

    const match = contentLengthPattern.exec(value)
    if (!match) return { ok: false, error: 'Invalid LSP Content-Length header.' }
    const length = Number(match[1])
    if (!Number.isSafeInteger(length)) {
      return { ok: false, error: 'Invalid LSP Content-Length header.' }
    }
    if (length > MAX_LSP_PAYLOAD_BYTES) {
      return {
        ok: false,
        error: `LSP payload exceeds the ${MAX_LSP_PAYLOAD_BYTES}-byte limit.`
      }
    }
    contentLength = length
  }

  return contentLength === undefined
    ? { ok: false, error: 'Missing LSP Content-Length header.' }
    : { ok: true, length: contentLength }
}

function protocolError(message: string, fatal: boolean, cause?: unknown): LspProtocolError {
  return cause === undefined
    ? new LspProtocolError(message, fatal)
    : new LspProtocolError(message, fatal, { cause })
}

/**
 * Create an incremental reader for Content-Length framed LSP JSON-RPC messages.
 *
 * Header/framing errors are fatal because they leave no trustworthy next-frame
 * boundary. Once one occurs, the reader permanently ignores further input.
 * Payload errors are recoverable only after the declared payload has been fully
 * consumed, so payload bytes are never scanned for a possible frame marker.
 */
export function createLspMessageReader(
  onMessage: (message: LspMessage) => void,
  onError?: (error: LspProtocolError) => void
): (chunk: Uint8Array) => void {
  type ReaderState = 'header' | 'payload' | 'stopped'

  const header = Buffer.allocUnsafe(headerBufferSize)
  let headerLength = 0
  let payload: Buffer | undefined
  let payloadLength = 0
  let state: ReaderState = 'header'

  const fail = (message: string, cause?: unknown): void => {
    state = 'stopped'
    payload = undefined
    payloadLength = 0
    onError?.(protocolError(message, true, cause))
  }

  const report = (message: string, cause?: unknown): void => {
    onError?.(protocolError(message, false, cause))
  }

  const completePayload = (): void => {
    const completed = payload
    payload = undefined
    payloadLength = 0
    state = 'header'
    if (!completed) return

    let json: string
    try {
      json = new TextDecoder('utf-8', { fatal: true }).decode(completed)
    } catch (error) {
      report('Invalid UTF-8 in LSP payload.', error)
      return
    }

    let message: unknown
    try {
      message = JSON.parse(json) as unknown
    } catch (error) {
      report('Invalid JSON in LSP payload.', error)
      return
    }
    if (message === null || typeof message !== 'object' || Array.isArray(message)) {
      report('LSP payload must be a JSON object.')
      return
    }
    onMessage(message as LspMessage)
  }

  return (chunk: Uint8Array): void => {
    if (state === 'stopped' || chunk.byteLength === 0) return

    let offset = 0
    while (offset < chunk.byteLength) {
      if (state === 'header') {
        const byte = chunk[offset]
        offset += 1
        if (byte > 0x7f) {
          fail('LSP header must contain only ASCII bytes.')
          return
        }

        if (headerLength === header.length) {
          fail(`LSP header exceeds the ${MAX_LSP_HEADER_BYTES}-byte limit.`)
          return
        }
        header[headerLength] = byte
        headerLength += 1
        if (endsWithHeaderSeparator(header, headerLength)) {
          const parsed = parseHeader(
            header.subarray(0, headerLength - headerSeparatorLength)
          )
          headerLength = 0
          if (parsed.ok === false) {
            fail(parsed.error)
            return
          }

          payload = Buffer.allocUnsafe(parsed.length)
          payloadLength = 0
          state = 'payload'
          if (parsed.length === 0) completePayload()
          continue
        }
        if (headerLength - trailingHeaderSeparatorPrefixLength(header, headerLength) >
            MAX_LSP_HEADER_BYTES) {
          fail(`LSP header exceeds the ${MAX_LSP_HEADER_BYTES}-byte limit.`)
          return
        }
        continue
      }

      const target = payload
      if (!target) {
        fail('Invalid internal LSP reader state.')
        return
      }
      const copied = Math.min(target.length - payloadLength, chunk.byteLength - offset)
      target.set(chunk.subarray(offset, offset + copied), payloadLength)
      payloadLength += copied
      offset += copied
      if (payloadLength === target.length) completePayload()
    }
  }
}

function serializationError(cause?: unknown): TypeError {
  return cause === undefined
    ? new TypeError('LSP message is not JSON serializable.')
    : new TypeError('LSP message is not JSON serializable.', { cause })
}

/** Encode one JSON object using the Content-Length framing required by LSP. */
export function encodeLspMessage(message: unknown): Buffer {
  if (message === null || typeof message !== 'object' || Array.isArray(message)) {
    throw new TypeError('LSP message must be a non-null JSON object.')
  }

  let json: string | undefined
  try {
    json = JSON.stringify(message)
  } catch (error) {
    throw serializationError(error)
  }
  // A custom toJSON method can turn an object into undefined or a primitive.
  if (json === undefined || json[0] !== '{') throw serializationError()

  const payloadLength = Buffer.byteLength(json, 'utf8')
  if (payloadLength > MAX_LSP_PAYLOAD_BYTES) {
    throw new RangeError(`LSP payload exceeds the ${MAX_LSP_PAYLOAD_BYTES}-byte limit.`)
  }
  const payload = Buffer.from(json, 'utf8')
  return Buffer.concat([
    Buffer.from(`Content-Length: ${payloadLength}\r\n\r\n`, 'ascii'),
    payload
  ])
}
