import { EditorState } from "@codemirror/state"
import {
  IndentContext, StreamLanguage, StringStream, ensureSyntaxTree, foldable,
  getIndentUnit, getIndentation, indentUnit, syntaxTree
} from "@codemirror/language"
import { classHighlighter, highlightTree } from "@lezer/highlight"
import { NodeProp } from "@lezer/common"
import { angular } from "@codemirror/lang-angular"
import { cpp } from "@codemirror/lang-cpp"
import { css } from "@codemirror/lang-css"
import { go } from "@codemirror/lang-go"
import { html } from "@codemirror/lang-html"
import { java } from "@codemirror/lang-java"
import { javascript } from "@codemirror/lang-javascript"
import { jinja } from "@codemirror/lang-jinja"
import { json } from "@codemirror/lang-json"
import { less } from "@codemirror/lang-less"
import { liquid } from "@codemirror/lang-liquid"
import { markdown } from "@codemirror/lang-markdown"
import { php } from "@codemirror/lang-php"
import { python } from "@codemirror/lang-python"
import { rust } from "@codemirror/lang-rust"
import { sass } from "@codemirror/lang-sass"
import {
  Cassandra, MariaSQL, MSSQL, MySQL, PLSQL, PostgreSQL, SQLite, StandardSQL, sql
} from "@codemirror/lang-sql"
import { vue } from "@codemirror/lang-vue"
import { wast } from "@codemirror/lang-wast"
import { xml } from "@codemirror/lang-xml"
import { yaml } from "@codemirror/lang-yaml"
import {
  LANGUAGE_DESCRIPTORS, LEGACY_LANGUAGE_PARSERS
} from "./LegacyLanguageRegistry.generated.js"

const SCHEMA_VERSION = 2
// JavaScriptCore execution cannot be force-interrupted safely in-process. Keep
// the accepted source and line counts conservative so a trusted bundle cannot
// monopolize its serial queue on adversarial generated input. Larger files use
// the native visible-range lexical fallback.
const MAX_SOURCE_UTF16 = 128 * 1024
const MAX_SOURCE_LINES = 50_000
const MAX_RESULT_UTF8 = 1792 * 1024
const MAX_HIGHLIGHTS = 20_000
const MAX_NODES = 50_000
const MAX_DEPTH = 256
const MAX_BRACKET_PAIRS = 10_000
const MAX_FOLDS = 10_000
const MAX_SYMBOLS = 5_000
const MAX_INDENTATION = 100_000
const MAX_NEWLINE_PROBES = 8
const NEWLINE_TRANSITION_INSERTS = Object.freeze([
  "(", "[", "{", ":", ",", ">"
])
const MAX_TYPE_UTF16 = 128
const MAX_LABEL_UTF16 = 1024

const MODERN_LANGUAGE_FACTORIES = new Map([
  ["C", () => cpp()],
  ["C++", () => cpp()],
  ["CQL", () => sql({ dialect: Cassandra })],
  ["CSS", () => css()],
  ["Go", () => go()],
  ["HTML", () => html()],
  ["Java", () => java()],
  ["JavaScript", () => javascript()],
  ["Jinja", () => jinja()],
  ["JSON", () => json()],
  ["JSX", () => javascript({ jsx: true })],
  ["LESS", () => less()],
  ["Liquid", () => liquid()],
  ["MariaDB SQL", () => sql({ dialect: MariaSQL })],
  ["Markdown", () => markdown()],
  ["MS SQL", () => sql({ dialect: MSSQL })],
  ["MySQL", () => sql({ dialect: MySQL })],
  ["PHP", () => php()],
  ["PLSQL", () => sql({ dialect: PLSQL })],
  ["PostgreSQL", () => sql({ dialect: PostgreSQL })],
  ["Python", () => python()],
  ["Rust", () => rust()],
  ["Sass", () => sass({ indented: true })],
  ["SCSS", () => sass()],
  ["SQL", () => sql({ dialect: StandardSQL })],
  ["SQLite", () => sql({ dialect: SQLite })],
  ["TSX", () => javascript({ jsx: true, typescript: true })],
  ["TypeScript", () => javascript({ typescript: true })],
  ["WebAssembly", () => wast()],
  ["XML", () => xml()],
  ["YAML", () => yaml()],
  ["Vue", () => vue()],
  ["Angular Template", () => angular()]
])

const LANGUAGE_FACTORIES = new Map()
const usedModernLanguages = new Set()
const usedLegacyLanguages = new Set()
for (const descriptor of LANGUAGE_DESCRIPTORS) {
  let factory
  if (descriptor.parserKind === "stream") {
    const parser = LEGACY_LANGUAGE_PARSERS.get(descriptor.name)
    if (!parser) throw new Error(`Missing legacy parser for ${descriptor.name}`)
    const language = StreamLanguage.define(parser)
    factory = () => language
    usedLegacyLanguages.add(descriptor.name)
  } else {
    factory = MODERN_LANGUAGE_FACTORIES.get(descriptor.name)
    if (!factory) throw new Error(`Missing modern parser for ${descriptor.name}`)
    usedModernLanguages.add(descriptor.name)
  }
  const value = [descriptor.name, descriptor.parserKind, factory]
  for (const alias of descriptor.aliases) {
    const previous = LANGUAGE_FACTORIES.get(alias)
    if (previous && previous[0] !== descriptor.name) {
      throw new Error(`Language alias ${alias} is ambiguous`)
    }
    LANGUAGE_FACTORIES.set(alias, value)
  }
}
if (usedModernLanguages.size !== MODERN_LANGUAGE_FACTORIES.size
    || usedLegacyLanguages.size !== LEGACY_LANGUAGE_PARSERS.size) {
  throw new Error("Generated language registry and parser factories disagree")
}

function emptyTruncation() {
  return {
    source: false, highlights: false, syntaxNodes: false, bracketPairs: false,
    folds: false, symbols: false, indentation: false
  }
}

function emptyNewlineIndentation() {
  return []
}

function unsupported(requestedLanguage, sourceUTF16Length) {
  return {
    schemaVersion: SCHEMA_VERSION, supported: false, parserKind: "unsupported",
    requestedLanguage, resolvedLanguage: requestedLanguage, sourceUTF16Length,
    highlights: [], syntaxNodes: [], bracketPairs: [], folds: [], symbols: [],
    indentation: [], newlineIndentation: emptyNewlineIndentation(),
    newlineIndentationTransitions: [],
    truncated: emptyTruncation()
  }
}

function boundedInteger(value, fallback, minimum, maximum) {
  return Number.isSafeInteger(value) && value >= minimum && value <= maximum
    ? value : fallback
}

function highlightKind(classes) {
  const names = new Set(String(classes).split(/\s+/))
  if (names.has("tok-comment")) return "comment"
  if (names.has("tok-string") || names.has("tok-regexp")) return "string"
  if (names.has("tok-keyword")) return "keyword"
  if (names.has("tok-number")) return "number"
  if (names.has("tok-typeName") || names.has("tok-className")
      || names.has("tok-namespace")) return "type"
  if (names.has("tok-bool") || names.has("tok-atom")
      || names.has("tok-null")) return "constant"
  if (names.has("tok-heading") || names.has("tok-tagName")
      || names.has("tok-attributeName") || names.has("tok-link")
      || names.has("tok-emphasis") || names.has("tok-strong")) return "markup"
  return null
}

function collectHighlights(tree, truncated) {
  const values = []
  highlightTree(tree, classHighlighter, (from, to, classes) => {
    const kind = highlightKind(classes)
    if (!kind || from >= to) return
    if (values.length >= MAX_HIGHLIGHTS) { truncated.highlights = true; return }
    values.push({ from, to, kind })
  })
  return values
}

function isStringOrCommentStyle(style) {
  if (typeof style !== "string") return false
  return style.split(/\s+/).some(name =>
    /^(?:character|comment|string(?:-2)?|regexp)(?:\.|$)/.test(name)
      || name === "quote"
  )
}

function openingQuoteDelimiter(text) {
  for (const delimiter of ["\"\"\"", "'''", "\"", "'", "`"]) {
    if (text.startsWith(delimiter)) return delimiter
  }
  return null
}

function closesQuotedToken(text, delimiter, from, backslashEscapes) {
  for (let offset = from; offset + delimiter.length <= text.length; offset++) {
    if (backslashEscapes && text[offset] === "\\") {
      offset++
      continue
    }
    if (text.startsWith(delimiter, offset)) return true
  }
  return false
}

function collectNodes(tree, truncated) {
  const values = []
  if (tree.length !== tree.topNode.to) truncated.syntaxNodes = true
  const cursor = tree.cursor()
  const parentStack = []
  let depth = 0
  let done = false
  while (!done) {
    if (values.length >= MAX_NODES) { truncated.syntaxNodes = true; break }
    const type = String(cursor.name).slice(0, MAX_TYPE_UTF16) || "Unknown"
    const index = values.length
    values.push({
      from: cursor.from, to: cursor.to, type,
      parent: parentStack.length ? parentStack[parentStack.length - 1] : -1
    })
    if (depth < MAX_DEPTH - 1 && cursor.firstChild()) {
      parentStack.push(index)
      depth++
      continue
    }
    if (depth >= MAX_DEPTH - 1 && cursor.firstChild()) {
      truncated.syntaxNodes = true
      cursor.parent()
    }
    while (true) {
      if (cursor.nextSibling()) break
      if (!cursor.parent()) { done = true; break }
      parentStack.pop()
      depth--
    }
  }
  return values
}

function collectBracketPairs(nodes, text, truncated) {
  const stack = []
  const values = []
  const seen = new Set()
  const opens = new Map([["(", ")"], ["[", "]"], ["{", "}"]])
  const closes = new Map([[")", "("], ["]", "["], ["}", "{"]])
  for (const node of nodes) {
    if (node.to !== node.from + 1) continue
    const token = text.slice(node.from, node.to)
    // Error-recovery nodes may cover the same source character as their
    // concrete token. Only exact anonymous punctuation tokens participate.
    if (node.type !== token || seen.has(node.from)) continue
    seen.add(node.from)
    if (opens.has(token)) {
      stack.push({ token, offset: node.from })
    } else if (closes.has(token)) {
      const top = stack[stack.length - 1]
      if (top && top.token === closes.get(token)) {
        stack.pop()
        if (values.length < MAX_BRACKET_PAIRS) {
          values.push({ open: top.offset, close: node.from })
        } else {
          truncated.bracketPairs = true
        }
      } else {
        // Never pair across a mismatched recovery token. Losing an outer pair
        // in malformed code is safer than navigating through the wrong tree.
        stack.length = 0
      }
    }
  }
  if (truncated.syntaxNodes) truncated.bracketPairs = true
  values.sort((a, b) => a.open - b.open)
  return values
}

function collectStreamBracketPairs(state, language, truncated) {
  const stack = []
  const values = []
  const opens = new Map([["(", ")"], ["[", "]"], ["{", "}"]])
  const closes = new Map([[")", "("], ["]", "["], ["}", "{"]])
  const streamParser = language.streamParser
  const indentColumns = getIndentUnit(state)
  const parserState = streamParser.startState(indentColumns)
  let quotedToken = null
  function scanToken(text, base, from, to) {
    // JavaScript string indices and CodeMirror positions are both UTF-16 code
    // units. The source admission limit bounds this pass and its stack.
    for (let localOffset = from; localOffset < to; localOffset++) {
      const offset = base + localOffset
      const token = text[localOffset]
      if (opens.has(token)) {
        stack.push({ token, offset })
      } else if (closes.has(token)) {
        const top = stack[stack.length - 1]
        if (top && top.token === closes.get(token)) {
          stack.pop()
          if (values.length < MAX_BRACKET_PAIRS) {
            values.push({ open: top.offset, close: offset })
          } else {
            truncated.bracketPairs = true
          }
        } else {
          // A mismatched closer invalidates every pending opener. Resuming with
          // an empty stack avoids manufacturing a pair across malformed code.
          stack.length = 0
        }
      }
    }
  }
  for (let number = 1; number <= state.doc.lines; number++) {
    const line = state.doc.line(number)
    // Explicit LF separation preserves CRLF offsets by leaving CR in line.text.
    // Stream parsers must still receive a logical empty line for blankLine.
    const lineText = line.text.endsWith("\r")
      ? line.text.slice(0, -1) : line.text
    const stream = new StringStream(
      lineText, state.tabSize, indentColumns
    )
    if (stream.eol()) {
      streamParser.blankLine(parserState, indentColumns)
      continue
    }
    while (!stream.eol()) {
      stream.start = stream.pos
      let style
      for (let attempt = 0; attempt < 10; attempt++) {
        style = streamParser.token(stream, parserState)
        if (stream.pos > stream.start) break
      }
      if (stream.pos <= stream.start) throw new Error(
        "Stream parser failed to advance stream"
      )
      const tokenText = lineText.slice(stream.start, stream.pos)
      let excludesBrackets = isStringOrCommentStyle(style)
      if (quotedToken) {
        excludesBrackets = true
        if (closesQuotedToken(
          tokenText, quotedToken.delimiter, 0, quotedToken.backslashEscapes
        )) {
          quotedToken = null
        }
      } else if (!excludesBrackets) {
        const delimiter = openingQuoteDelimiter(tokenText)
        if (delimiter) {
          // EBNF quoted productions and TOML quoted keys are deliberately
          // styled as properties. Exclude any otherwise-unrecognized token
          // whose raw lexeme proves it starts with a quote; ordinary property
          // tokens remain eligible. Carry an unterminated delimiter across
          // line tokens so uncertainty fails closed.
          excludesBrackets = true
          const backslashEscapes = !(
            streamParser.name === "toml" && delimiter[0] === "'"
          )
          if (!closesQuotedToken(
            tokenText, delimiter, delimiter.length, backslashEscapes
          )) {
            quotedToken = { delimiter, backslashEscapes }
          }
        }
      }
      if (!excludesBrackets) {
        scanToken(lineText, line.from, stream.start, stream.pos)
      }
    }
  }
  values.sort((a, b) => a.open - b.open)
  return values
}

function collectFolds(state, truncated) {
  const values = []
  const seen = new Set()
  for (let lineNumber = 1; lineNumber <= state.doc.lines; lineNumber++) {
    const line = state.doc.line(lineNumber)
    const range = foldable(state, line.from, line.to)
    if (!range || range.from >= range.to) continue
    const endLine = state.doc.lineAt(Math.max(range.from, range.to - 1))
    if (endLine.number <= line.number) continue
    const separatorLength = line.to < state.doc.length ? state.lineBreak.length : 0
    const hiddenFrom = line.to + separatorLength
    const hiddenTo = Math.max(range.to, endLine.to)
    if (hiddenFrom >= hiddenTo) continue
    const key = `${line.from}:${hiddenTo}`
    if (seen.has(key)) continue
    seen.add(key)
    if (values.length >= MAX_FOLDS) { truncated.folds = true; break }
    values.push({
      fullFrom: line.from, fullTo: hiddenTo,
      from: hiddenFrom, to: hiddenTo,
      startLine: line.number, endLine: endLine.number
    })
  }
  values.sort((a, b) => a.fullFrom - b.fullFrom || b.fullTo - a.fullTo)
  return values
}

function symbolKind(type) {
  if (/Heading/.test(type)) return "heading"
  if (/^(?:MethodDeclaration|MethodDefinition)$/.test(type)) return "method"
  if (/^(?:FunctionDeclaration|FunctionDefinition|FunctionDecl|FunctionItem)$/.test(type)) return "function"
  if (/^(?:ClassDeclaration|InterfaceDeclaration|StructItem|EnumItem|TraitItem|TypeDecl)$/.test(type)) return "type"
  if (/^(?:VariableDeclaration|PropertyDeclaration|PropertyDefinition)$/.test(type)) return "variable"
  return null
}

function normalizeSymbolLabel(value) {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ")
    .replace(/\s+/g, " ").trim()
}

function collectSymbols(state, nodes, text, truncated) {
  const values = []
  const seen = new Set()
  function depthOf(index) {
    let level = 0, parent = nodes[index].parent
    while (parent >= 0 && level < MAX_DEPTH) {
      if (symbolKind(nodes[parent].type)) level++
      parent = nodes[parent].parent
    }
    return level
  }
  function labelNode(index) {
    for (let offset = index + 1; offset < nodes.length; offset++) {
      const candidate = nodes[offset]
      let ancestor = candidate.parent
      while (ancestor >= 0 && ancestor !== index) ancestor = nodes[ancestor].parent
      if (ancestor !== index) break
      if (/(?:VariableDefinition|TypeDefinition|PropertyDefinition|Definition|DefName|BoundIdentifier|TypeIdentifier|Identifier|Name)$/.test(candidate.type)
          && candidate.to > candidate.from) return candidate
    }
    return null
  }
  for (let index = 0; index < nodes.length; index++) {
    const node = nodes[index]
    const kind = symbolKind(node.type)
    if (!kind) continue
    let target = labelNode(index)
    let label
    if (kind === "heading") {
      target = node
      const raw = text.slice(node.from, node.to)
      if (/^\s*#+/.test(raw)) {
        label = normalizeSymbolLabel(raw)
          .replace(/\s+#+\s*$/, "")
          .replace(/^\s*#+(?:\s+|$)/, "").trim()
      } else {
        label = raw.split(/\r\n|\r|\n/, 1)[0].trim()
      }
    } else if (target) {
      label = text.slice(target.from, target.to).trim()
    }
    if (label) label = normalizeSymbolLabel(label)
    if (!target || !label || label.length > MAX_LABEL_UTF16) continue
    const identity = `${kind}:${target.from}:${target.to}:${label}`
    if (seen.has(identity)) continue
    seen.add(identity)
    if (values.length >= MAX_SYMBOLS) { truncated.symbols = true; break }
    values.push({
      label, kind, from: target.from, to: target.to,
      line: state.doc.lineAt(target.from).number,
      level: kind === "heading"
        ? Math.max(0, Math.min(MAX_DEPTH,
            (/^\s*(#+)/.exec(text.slice(node.from, node.to))?.[1].length
              || (/SetextHeading2/.test(node.type) ? 2 : 1)) - 1))
        : Math.min(MAX_DEPTH, depthOf(index))
    })
  }
  values.sort((a, b) => a.from - b.from || a.to - b.to)
  return values
}

function collectIndentation(state, truncated) {
  const values = []
  const computed = new Map()
  const context = new IndentContext(state, {
    overrideIndentation: start => computed.has(start) ? computed.get(start) : -1
  })
  for (let number = 1; number <= state.doc.lines; number++) {
    if (values.length >= MAX_INDENTATION) { truncated.indentation = true; break }
    const line = state.doc.line(number)
    let columns = getIndentation(context, line.from)
    if (columns != null) {
      columns = Math.max(0, Math.min(1_000_000, Math.trunc(columns)))
      computed.set(line.from, /\S/.test(line.text) ? columns : 0)
    }
    values.push({ lineFrom: line.from, columns: columns == null ? null : computed.get(line.from) })
  }
  return values
}

// Precompute the exact `insertNewlineAndIndent` indentation query at the
// bounded set of cursor positions supplied by the native editor. These are
// intentionally part of the ordinary analysis result: production still uses
// the same killable helper and synchronous input handling only reads cache.
function collectNewlineIndentation(state, requestedPositions) {
  if (!Array.isArray(requestedPositions)
      || requestedPositions.length > MAX_NEWLINE_PROBES) return []
  const positions = Array.from(new Set(requestedPositions))
  if (positions.some(position => !Number.isSafeInteger(position)
      || position < 0 || position > state.doc.length)) return []
  positions.sort((a, b) => a - b)
  return positions.map(position => {
    let columns = getIndentation(
      new IndentContext(state, { simulateBreak: position }), position
    )
    let doubleColumns = getIndentation(new IndentContext(state, {
      simulateBreak: position, simulateDoubleBreak: true
    }), position)
    if (columns != null) {
      columns = Math.max(0, Math.min(1_000_000, Math.trunc(columns)))
    }
    if (doubleColumns != null) {
      doubleColumns = Math.max(
        0, Math.min(1_000_000, Math.trunc(doubleColumns))
      )
    }
    return {
      position, columns: columns == null ? null : columns,
      doubleColumns: doubleColumns == null ? null : doubleColumns,
      explode: isExactBracketGap(state, position)
    }
  })
}

function collectNewlineIndentationTransitions(state, requestedPositions) {
  if (!Array.isArray(requestedPositions)
      || requestedPositions.length > MAX_NEWLINE_PROBES) return []
  const positions = Array.from(new Set(requestedPositions))
  if (positions.some(position => !Number.isSafeInteger(position)
      || position < 0 || position > state.doc.length)) return []
  positions.sort((a, b) => a - b)
  const values = []
  const deadline = Date.now() + 400
  for (const position of positions) {
    for (const insert of NEWLINE_TRANSITION_INSERTS) {
      if (Date.now() >= deadline) return []
      const next = state.update({ changes: { from: position, insert } }).state
      // State updates reuse the old tree and do bounded incremental parsing.
      // A missing full tree produces a null answer rather than stale syntax.
      const parsed = ensureSyntaxTree(next, next.doc.length, 8)
      if (Date.now() >= deadline) return []
      let columns = parsed == null || parsed.length < next.doc.length ? null : getIndentation(
        new IndentContext(next, { simulateBreak: position + 1 }), position + 1
      )
      let doubleColumns = parsed == null || parsed.length < next.doc.length ? null : getIndentation(
        new IndentContext(next, {
          simulateBreak: position + 1, simulateDoubleBreak: true
        }), position + 1
      )
      if (columns != null) {
        columns = Math.max(0, Math.min(1_000_000, Math.trunc(columns)))
      }
      if (doubleColumns != null) {
        doubleColumns = Math.max(
          0, Math.min(1_000_000, Math.trunc(doubleColumns))
        )
      }
      values.push({
        position, insert, columns: columns == null ? null : columns,
        doubleColumns: doubleColumns == null ? null : doubleColumns,
        explode: isExactBracketGap(next, position + 1)
      })
    }
  }
  return values
}

function isExactBracketGap(state, position) {
  if (position > 0 && /^(?:\(\)|\[\]|\{\})$/.test(
    state.sliceDoc(position - 1, position + 1)
  )) {
    return true
  }
  const context = syntaxTree(state).resolveInner(position)
  const before = context.childBefore(position)
  const after = context.childAfter(position)
  const closedBy = before?.type.prop(NodeProp.closedBy)
  return !!(before && after && before.to === position && after.from === position
    && closedBy && closedBy.includes(after.name)
    && state.doc.lineAt(before.to).from === state.doc.lineAt(after.from).from)
}

function utf8Length(value) {
  let length = 0
  for (const character of value) {
    const scalar = character.codePointAt(0)
    length += scalar <= 0x7f ? 1 : scalar <= 0x7ff ? 2 : scalar <= 0xffff ? 3 : 4
  }
  return length
}

function serializeBounded(result) {
  let json = JSON.stringify({ result })
  const order = [
    ["syntaxNodes", "syntaxNodes", 1], ["indentation", "indentation", 0],
    ["highlights", "highlights", 0], ["symbols", "symbols", 0],
    ["folds", "folds", 0], ["bracketPairs", "bracketPairs", 0]
  ]
  while (utf8Length(json) > MAX_RESULT_UTF8) {
    const item = order.find(([key, _flag, minimum]) => result[key].length > minimum)
    if (!item) throw new Error("Parser result cannot fit the output budget")
    const [key, flag, minimum] = item
    result[key] = result[key].slice(0, Math.max(minimum, Math.floor(result[key].length / 2)))
    result.truncated[flag] = true
    if (key === "syntaxNodes") {
      result.bracketPairs = []
      result.symbols = []
      result.truncated.bracketPairs = true
      result.truncated.symbols = true
    }
    json = JSON.stringify({ result })
  }
  return json
}

function analyze(requestJSON) {
  const request = JSON.parse(String(requestJSON))
  if (!request || typeof request.text !== "string"
      || typeof request.language !== "string"
      || request.language.length > 128 || request.text.length > MAX_SOURCE_UTF16) {
    throw new Error("Invalid parser request")
  }
  let lineBreaks = 0
  let sawLF = false
  let sawStandaloneCR = false
  for (let index = 0; index < request.text.length; index++) {
    const unit = request.text.charCodeAt(index)
    if (unit === 10) { sawLF = true; lineBreaks++ }
    else if (unit === 13 && request.text.charCodeAt(index + 1) !== 10) {
      sawStandaloneCR = true
      lineBreaks++
    }
    if (lineBreaks + 1 > MAX_SOURCE_LINES) throw new Error("Parser line budget exceeded")
  }
  if (sawLF && sawStandaloneCR) {
    return JSON.stringify({ result: unsupported(request.language, request.text.length) })
  }
  const requestedLanguage = request.language
  const descriptor = LANGUAGE_FACTORIES.get(requestedLanguage.trim().toLowerCase())
  if (!descriptor) return JSON.stringify({ result: unsupported(requestedLanguage, request.text.length) })
  const tabWidth = boundedInteger(request.tabWidth, 4, 1, 16)
  const indentWidth = boundedInteger(request.indentWidth, tabWidth, 1, 16)
  const insertSpaces = request.insertSpaces !== false
  const indentationUnit = insertSpaces ? " ".repeat(indentWidth) : "\t"
  const [resolvedLanguage, parserKind, factory] = descriptor
  const lineSeparator = request.text.includes("\n") ? "\n" : "\r"
  const language = factory()
  const state = EditorState.create({
    doc: request.text,
    extensions: [
      language, indentUnit.of(indentationUnit), EditorState.tabSize.of(tabWidth),
      // Explicit separators preserve raw UTF-16 positions. With CRLF the CR
      // remains whitespace before LF instead of being collapsed to one unit.
      EditorState.lineSeparator.of(lineSeparator)
    ]
  })
  const parsed = ensureSyntaxTree(state, request.text.length, 100)
  if (!parsed || parsed.length < request.text.length) {
    return JSON.stringify({ result: unsupported(requestedLanguage, request.text.length) })
  }
  const tree = parsed
  const truncated = emptyTruncation()
  const streamMode = parserKind === "stream"
  const syntaxNodes = streamMode
    ? [{ from: 0, to: request.text.length, type: "Document", parent: -1 }]
    : collectNodes(tree, truncated)
  if (!streamMode && syntaxNodes.length && syntaxNodes[0].to < request.text.length) {
    truncated.syntaxNodes = true
  }
  const result = {
    schemaVersion: SCHEMA_VERSION, supported: true, parserKind,
    requestedLanguage, resolvedLanguage, sourceUTF16Length: request.text.length,
    highlights: collectHighlights(tree, truncated), syntaxNodes,
    bracketPairs: streamMode
      ? collectStreamBracketPairs(state, language, truncated)
      : collectBracketPairs(syntaxNodes, request.text, truncated),
    folds: streamMode ? [] : collectFolds(state, truncated),
    symbols: streamMode ? [] : collectSymbols(state, syntaxNodes, request.text, truncated),
    indentation: collectIndentation(state, truncated),
    newlineIndentation: collectNewlineIndentation(
      state, request.newlineIndentationPositions
    ),
    newlineIndentationTransitions: collectNewlineIndentationTransitions(
      state, request.newlineIndentationPositions
    ),
    truncated
  }
  return serializeBounded(result)
}

globalThis.LumenCodeMirrorParser = Object.freeze({
  protocolVersion: SCHEMA_VERSION,
  supportedLanguages: Object.freeze(LANGUAGE_DESCRIPTORS.map(({ name }) => name).sort()),
  analyze
})
