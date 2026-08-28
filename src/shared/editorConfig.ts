export type EditorConfigPathStyle = 'posix' | 'win32'
export type EditorConfigProperty = 'indent_style' | 'indent_size' | 'tab_width' | 'end_of_line'
export type EditorConfigIndentStyle = 'space' | 'tab'
export type EditorConfigIndentSize = number | 'tab'
export type EditorConfigEndOfLine = 'LF' | 'CRLF' | 'CR'
export type EditorConfigValue = EditorConfigIndentStyle | EditorConfigIndentSize | EditorConfigEndOfLine
export type EditorConfigAssignmentValue = EditorConfigValue | 'unset'

export interface EditorConfigProperties {
  indentStyle?: EditorConfigIndentStyle
  indentSize?: EditorConfigIndentSize
  tabWidth?: number
  endOfLine?: EditorConfigEndOfLine
}

export interface IndentationPreferences {
  indentSize: number
  tabWidth: number
  insertSpaces: boolean
}

export interface EditorConfigSection {
  pattern: string
  valid: boolean
  assignments: Partial<Record<EditorConfigProperty, EditorConfigAssignmentValue>>
}

export interface ParsedEditorConfig {
  /** False means the entire file must be ignored (currently, a lone CR). */
  valid: boolean
  /** Only a valid preamble `root = true` sets this flag. */
  root: boolean
  sections: EditorConfigSection[]
}

/** One config in an outermost-to-innermost cascade. */
export interface EditorConfigSource {
  /** Absolute path to the `.editorconfig` file. */
  path: string
  source: string
}

const properties = new Set<EditorConfigProperty>(['indent_style', 'indent_size', 'tab_width', 'end_of_line'])
const MAX_EDITOR_CONFIG_LINES = 4_096
const MAX_EDITOR_CONFIG_SECTIONS = 256
const MAX_EDITOR_CONFIG_GLOB_CHARS = 512

function assignment(key: EditorConfigProperty, rawValue: string): EditorConfigAssignmentValue | undefined {
  const value = rawValue.toLowerCase()
  if (value === 'unset') return 'unset'
  if (key === 'indent_style') return value === 'space' || value === 'tab' ? value : undefined
  if (key === 'end_of_line') {
    if (value === 'lf') return 'LF'
    if (value === 'crlf') return 'CRLF'
    if (value === 'cr') return 'CR'
    return undefined
  }
  if (key === 'indent_size' && value === 'tab') return 'tab'
  if (!/^(?:[1-9]|1[0-6])$/.test(value)) return undefined
  return Number(value)
}

/** Parse the dependency-free subset consumed by Lumen. Unknown pairs are ignored. */
export function parseEditorConfig(source: string): ParsedEditorConfig {
  let text = source.startsWith('\uFEFF') ? source.slice(1) : source
  text = text.replace(/\r\n/g, '\n')
  if (text.includes('\r')) return { valid: false, root: false, sections: [] }
  const lines = text.split('\n')
  if (lines.length > MAX_EDITOR_CONFIG_LINES) return { valid: false, root: false, sections: [] }

  const parsed: ParsedEditorConfig = { valid: true, root: false, sections: [] }
  let current: EditorConfigSection | null = null
  let inPreamble = true

  for (const originalLine of lines) {
    const line = originalLine.trim()
    if (!line || line.startsWith('#') || line.startsWith(';')) continue
    if (line.startsWith('[')) {
      inPreamble = false
      if (line.endsWith(']')) {
        const pattern = line.slice(1, -1)
        if (parsed.sections.length >= MAX_EDITOR_CONFIG_SECTIONS) return { valid: false, root: false, sections: [] }
        current = { pattern, valid: compileEditorConfigGlob(pattern) !== null, assignments: {} }
        parsed.sections.push(current)
      } else {
        // Pairs following a malformed header must not leak into the preceding section.
        current = null
      }
      continue
    }

    const equals = line.indexOf('=')
    if (equals < 0) continue
    const key = line.slice(0, equals).trim().toLowerCase()
    const value = line.slice(equals + 1).trim()
    if (inPreamble) {
      if (key === 'root' && value.toLowerCase() === 'true') parsed.root = true
      else if (key === 'root' && value.toLowerCase() === 'false') parsed.root = false
      continue
    }
    if (!current || !current.valid || !properties.has(key as EditorConfigProperty)) continue
    const property = key as EditorConfigProperty
    const parsedValue = assignment(property, value)
    if (parsedValue !== undefined) current.assignments[property] = parsedValue
  }
  return parsed
}

function escapeRegex(char: string): string {
  return /[\^$.*+?()[\]{}|]/.test(char) ? `\\${char}` : char
}

function escapeCharacterClassLiteral(char: string): string {
  return char === '\\' || char === ']' || char === '^' || char === '-' ? `\\${char}` : char
}

function compileCharacterClass(pattern: string, start: number): { source: string; end: number } | null {
  let cursor = start + 1
  let negate = false
  if (pattern[cursor] === '!') {
    negate = true
    cursor += 1
  }
  const members: Array<{ value: string; escaped: boolean }> = []
  let closed = false
  for (; cursor < pattern.length; cursor += 1) {
    const member = pattern[cursor]
    if (member === ']' && members.length > 0) {
      closed = true
      break
    }
    if (member === '\\') {
      cursor += 1
      if (cursor >= pattern.length) return null
      members.push({ value: pattern[cursor], escaped: true })
    } else {
      if (member === '/') return null
      members.push({ value: member, escaped: false })
    }
  }
  if (!closed || members.length === 0) return null
  const body = members.map((member, index) => {
    if (member.escaped) return escapeCharacterClassLiteral(member.value)
    if (member.value === '-') return index > 0 && index < members.length - 1 ? '-' : '\-'
    return member.value === '\\' || member.value === ']' || member.value === '^'
      ? escapeCharacterClassLiteral(member.value)
      : member.value
  }).join('')
  return { source: `[${negate ? '^' : ''}${body}]`, end: cursor }
}

function compileFragment(pattern: string, allowBrace: boolean): string | null {
  let result = ''
  for (let index = 0; index < pattern.length; index += 1) {
    const char = pattern[index]
    if (char === '\\') {
      if (++index >= pattern.length) return null
      result += escapeRegex(pattern[index])
      continue
    }
    if (char === '*') {
      if (pattern[index + 1] === '*') {
        index += 1
        while (pattern[index + 1] === '*') index += 1
        if (pattern[index + 1] === '/') {
          index += 1
          result += '(?:.*/)?'
        } else result += '.*'
      } else result += '[^/]*'
      continue
    }
    if (char === '?') {
      result += '[^/]'
      continue
    }
    if (char === '[') {
      const characterClass = compileCharacterClass(pattern, index)
      if (!characterClass) return null
      result += characterClass.source
      index = characterClass.end
      continue
    }
    if (char === '{') {
      if (!allowBrace) return null
      let cursor = index + 1
      let part = ''
      const parts: string[] = []
      let closed = false
      for (; cursor < pattern.length; cursor += 1) {
        const member = pattern[cursor]
        if (member === '{') return null
        if (member === '\\') {
          if (cursor + 1 >= pattern.length) return null
          part += member + pattern[++cursor]
        } else if (member === ',') {
          parts.push(part); part = ''
        } else if (member === '}') {
          parts.push(part); closed = true; break
        } else part += member
      }
      if (!closed || parts.length < 2 || parts.some((value) => value.length === 0)) return null
      const compiled = parts.map((value) => compileFragment(value, false))
      if (compiled.some((value) => value === null)) return null
      result += `(?:${compiled.join('|')})`
      index = cursor
      continue
    }
    if (char === ']' || char === '}') return null
    result += escapeRegex(char)
  }
  return result
}

/** Compile a section glob. Null means the section is invalid and never matches. */
export function compileEditorConfigGlob(pattern: string): RegExp | null {
  if (!pattern || pattern.length > MAX_EDITOR_CONFIG_GLOB_CHARS || pattern.endsWith('/')) return null
  const normalized = pattern.includes('/') ? pattern.replace(/^\//, '') : pattern
  const source = compileFragment(normalized, true)
  if (source === null) return null
  try { return new RegExp(`^${source}$`) } catch { return null }
}

interface NormalPath { root: string; parts: string[] }

function normalizePath(input: string, style: EditorConfigPathStyle): NormalPath | null {
  let value = style === 'win32' ? input.replace(/\\/g, '/') : input
  let root = ''
  if (style === 'win32') {
    const drive = /^([A-Za-z]:)(?:\/|$)/.exec(value)
    const unc = /^\/\/([^/]+)\/([^/]+)(?:\/|$)/.exec(value)
    if (drive) { root = drive[1].toLowerCase(); value = value.slice(drive[0].length) }
    else if (unc) { root = `//${unc[1].toLowerCase()}/${unc[2].toLowerCase()}`; value = value.slice(unc[0].length) }
    else return null
  } else {
    if (!value.startsWith('/')) return null
    root = '/'
    value = value.slice(1)
  }
  const parts: string[] = []
  for (const part of value.split('/')) {
    if (!part || part === '.') continue
    if (part === '..') { if (parts.length === 0) return null; parts.pop() }
    else parts.push(part)
  }
  return { root, parts }
}

/** Return a forward-slash path below a config directory, or null when unrelated. */
export function editorConfigRelativePath(
  directory: string,
  targetPath: string,
  style: EditorConfigPathStyle
): string | null {
  const base = normalizePath(directory, style)
  const target = normalizePath(targetPath, style)
  if (!base || !target || base.root !== target.root || target.parts.length <= base.parts.length) return null
  for (let index = 0; index < base.parts.length; index += 1) {
    const left = style === 'win32' ? base.parts[index].toLowerCase() : base.parts[index]
    const right = style === 'win32' ? target.parts[index].toLowerCase() : target.parts[index]
    if (left !== right) return null
  }
  return target.parts.slice(base.parts.length).join('/')
}

export function editorConfigGlobMatches(pattern: string, relativePath: string): boolean {
  const matcher = compileEditorConfigGlob(pattern)
  if (!matcher) return false
  // Relative paths produced above already use `/`. Keep a literal backslash
  // in POSIX file names intact rather than misreading it as a separator.
  const candidate = relativePath
  return matcher.test(pattern.includes('/') ? candidate : candidate.slice(candidate.lastIndexOf('/') + 1))
}

/** Apply one parsed file to an existing property set. */
export function applyEditorConfig(
  base: EditorConfigProperties,
  config: ParsedEditorConfig,
  relativePath: string
): EditorConfigProperties {
  const result = { ...base }
  if (!config.valid) return result
  for (const section of config.sections) {
    if (!section.valid || !editorConfigGlobMatches(section.pattern, relativePath)) continue
    for (const [key, value] of Object.entries(section.assignments) as Array<[EditorConfigProperty, EditorConfigAssignmentValue]>) {
      const outputKey = key === 'indent_style' ? 'indentStyle'
        : key === 'indent_size' ? 'indentSize'
          : key === 'tab_width' ? 'tabWidth' : 'endOfLine'
      if (value === 'unset') delete result[outputKey]
      else Object.assign(result, { [outputKey]: value })
    }
  }
  return result
}

/**
 * Resolve outermost-to-innermost config sources for one absolute target path.
 * A valid `root = true` discards properties contributed by earlier ancestors.
 */
export function applyEditorConfigChain(
  sources: readonly EditorConfigSource[],
  targetPath: string,
  style: EditorConfigPathStyle = 'posix'
): EditorConfigProperties {
  let result: EditorConfigProperties = {}
  const applicable = sources.flatMap((source) => {
    const config = parseEditorConfig(source.source)
    if (!config.valid) return []
    const slash = Math.max(source.path.lastIndexOf('/'), source.path.lastIndexOf('\\'))
    const directory = slash < 0
      ? source.path
      : slash === 0
        ? '/'
        : style === 'win32' && slash === 2 && /^[A-Za-z]:/.test(source.path)
          ? source.path.slice(0, 3)
          : source.path.slice(0, slash)
    const relative = editorConfigRelativePath(directory, targetPath, style)
    return relative === null ? [] : [{ config, relative }]
  }).sort((left, right) => {
    // More relative components means a more distant ancestor. Applying those
    // first makes the result independent of filesystem traversal order.
    const leftDepth = left.relative.split('/').length
    const rightDepth = right.relative.split('/').length
    return rightDepth - leftDepth
  })

  for (const { config, relative } of applicable) {
    if (config.root) result = {}
    result = applyEditorConfig(result, config, relative)
  }
  return result
}

/** Merge EditorConfig over detected indentation, one property at a time. */
export function resolveEditorConfigIndentation(
  config: EditorConfigProperties | undefined,
  detected: Pick<IndentationPreferences, 'indentSize' | 'insertSpaces'>,
  defaultTabWidth: number
): IndentationPreferences {
  const fallbackTabWidth = Math.max(1, Math.min(16, Math.round(defaultTabWidth)))
  const requestedIndentSize = typeof config?.indentSize === 'number'
    ? config.indentSize
    : config?.indentSize === 'tab'
      ? (config.tabWidth ?? fallbackTabWidth)
      : detected.indentSize
  const tabWidth = config?.tabWidth
    ?? (typeof config?.indentSize === 'number' ? config.indentSize : undefined)
    ?? (config?.indentSize === 'tab' ? fallbackTabWidth : detected.indentSize)
  const insertSpaces = config?.indentStyle === undefined ? detected.insertSpaces : config.indentStyle === 'space'
  return {
    // CodeMirror represents a hard-tab indent unit at the visual tab width.
    // When EditorConfig specifies unequal numeric indent/tab widths, retain
    // hard tabs (the explicit style) and use the configured tab width.
    indentSize: insertSpaces ? requestedIndentSize : tabWidth,
    tabWidth,
    insertSpaces
  }
}
