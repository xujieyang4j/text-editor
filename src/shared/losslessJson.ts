/**
 * JSON parser/serializer that keeps number tokens as text instead of converting
 * them to JavaScript `Number`. This is essential for IDs larger than
 * Number.MAX_SAFE_INTEGER, which must remain JSON numbers rather than strings.
 */
export class JsonNumber {
  constructor(readonly raw: string) {}
}

export interface LosslessJsonObject {
  [key: string]: LosslessJsonValue
}
export interface LosslessJsonArray extends Array<LosslessJsonValue> {}
export type LosslessJsonValue = null | boolean | string | JsonNumber | LosslessJsonArray | LosslessJsonObject

export function isJsonNumber(value: LosslessJsonValue): value is JsonNumber {
  return value instanceof JsonNumber
}

export function isLosslessJsonObject(value: LosslessJsonValue): value is LosslessJsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && !isJsonNumber(value)
}

class Parser {
  private position = 0

  constructor(private readonly source: string) {}

  parse(): LosslessJsonValue {
    this.whitespace()
    const value = this.value()
    this.whitespace()
    if (this.position !== this.source.length) this.error('Unexpected trailing content.')
    return value
  }

  private value(): LosslessJsonValue {
    this.whitespace()
    const char = this.source[this.position]
    if (char === '{') return this.object()
    if (char === '[') return this.array()
    if (char === '"') return this.string()
    if (char === 't') return this.literal('true', true)
    if (char === 'f') return this.literal('false', false)
    if (char === 'n') return this.literal('null', null)
    if (char === '-' || (char >= '0' && char <= '9')) return this.number()
    this.error('Expected a JSON value.')
  }

  private object(): LosslessJsonObject {
    this.expect('{')
    const result = Object.create(null) as LosslessJsonObject
    this.whitespace()
    if (this.source[this.position] === '}') { this.position += 1; return result }
    while (true) {
      this.whitespace()
      if (this.source[this.position] !== '"') this.error('Expected an object key.')
      const key = this.string()
      this.whitespace()
      this.expect(':')
      const value = this.value()
      Object.defineProperty(result, key, { value, enumerable: true, configurable: true, writable: true })
      this.whitespace()
      const char = this.source[this.position]
      if (char === '}') { this.position += 1; return result }
      this.expect(',')
    }
  }

  private array(): LosslessJsonValue[] {
    this.expect('[')
    const result: LosslessJsonValue[] = []
    this.whitespace()
    if (this.source[this.position] === ']') { this.position += 1; return result }
    while (true) {
      result.push(this.value())
      this.whitespace()
      const char = this.source[this.position]
      if (char === ']') { this.position += 1; return result }
      this.expect(',')
    }
  }

  private string(): string {
    const start = this.position
    this.expect('"')
    while (this.position < this.source.length) {
      const char = this.source[this.position]
      if (char === '"') {
        this.position += 1
        try { return JSON.parse(this.source.slice(start, this.position)) as string }
        catch { this.error('Invalid JSON string.') }
      }
      if (char === '\\') {
        this.position += 2
        continue
      }
      if (char < ' ') this.error('Control character in JSON string.')
      this.position += 1
    }
    this.error('Unterminated JSON string.')
  }

  private number(): JsonNumber {
    const rest = this.source.slice(this.position)
    const match = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(rest)
    if (!match) this.error('Invalid JSON number.')
    this.position += match[0].length
    return new JsonNumber(match[0])
  }

  private literal<T extends null | boolean>(source: string, value: T): T {
    if (!this.source.startsWith(source, this.position)) this.error(`Expected ${source}.`)
    this.position += source.length
    return value
  }

  private whitespace(): void {
    while (this.position < this.source.length && /[ \t\n\r]/.test(this.source[this.position])) this.position += 1
  }

  private expect(char: string): void {
    this.whitespace()
    if (this.source[this.position] !== char) this.error(`Expected “${char}”.`)
    this.position += 1
  }

  private error(message: string): never {
    throw new Error(`${message} Line ${this.source.slice(0, this.position).split('\n').length}, column ${this.position - this.source.lastIndexOf('\n', this.position - 1)}.`)
  }
}

export function parseLosslessJson(source: string): LosslessJsonValue {
  return new Parser(source).parse()
}

export function stringifyLosslessJson(value: LosslessJsonValue, indent = 0): string {
  const pretty = indent > 0
  const newline = pretty ? '\n' : ''
  const padding = (depth: number): string => pretty ? ' '.repeat(depth * indent) : ''
  const stringify = (current: LosslessJsonValue, depth: number): string => {
    if (current === null) return 'null'
    if (typeof current === 'boolean') return current ? 'true' : 'false'
    if (typeof current === 'string') return JSON.stringify(current)
    if (isJsonNumber(current)) return current.raw
    if (Array.isArray(current)) {
      if (current.length === 0) return '[]'
      const body = current.map((item) => `${padding(depth + 1)}${stringify(item, depth + 1)}`).join(`,${newline}`)
      return pretty ? `[${newline}${body}${newline}${padding(depth)}]` : `[${body}]`
    }
    const entries = Object.entries(current)
    if (entries.length === 0) return '{}'
    const body = entries.map(([key, item]) => `${padding(depth + 1)}${JSON.stringify(key)}${pretty ? ': ' : ':'}${stringify(item, depth + 1)}`).join(`,${newline}`)
    return pretty ? `{${newline}${body}${newline}${padding(depth)}}` : `{${body}}`
  }
  return stringify(value, 0)
}

export function cloneLosslessJson(value: LosslessJsonValue): LosslessJsonValue {
  return parseLosslessJson(stringifyLosslessJson(value))
}
