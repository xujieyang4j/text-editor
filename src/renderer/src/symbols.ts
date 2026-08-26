/**
 * Lightweight symbol extraction for "Goto Symbol" (@) mode.
 *
 * We deliberately avoid a full parser: a regex-per-language-family scan is fast,
 * dependency-free, and good enough for jumping around a file the way Sublime's
 * `@` overlay does. Each symbol carries the document offset to jump to.
 */

export interface Symbol {
  /** Display name, e.g. "function foo" or "class Bar". */
  label: string
  /** Absolute document offset of the symbol's line start. */
  pos: number
  /** 1-based line number, shown as a hint. */
  line: number
}

/** Patterns that tend to introduce a named symbol across common languages. */
const PATTERNS: RegExp[] = [
  // JS/TS: function decl, class, method, arrow assigned to const/let
  /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/,
  /^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/,
  /^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(?[^=]*\)?\s*=>/,
  /^\s*(?:public|private|protected|static|\s)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/,
  // Python
  /^\s*def\s+([A-Za-z_]\w*)/,
  /^\s*class\s+([A-Za-z_]\w*)/,
  // Go / Rust / Java-ish
  /^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)/,
  /^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)/,
  // Markdown headings
  /^(#{1,6})\s+(.*)$/
]

/**
 * Scan document text and return the list of symbols found.
 * Runs line-by-line; O(lines) with a handful of regex tests each.
 */
export function extractSymbols(text: string): Symbol[] {
  const symbols: Symbol[] = []
  const lines = text.split('\n')
  let offset = 0

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]
    for (const re of PATTERNS) {
      const m = re.exec(raw)
      if (m) {
        // Markdown heading: level in m[1], text in m[2].
        const label = m[2] !== undefined ? `${'#'.repeat(m[1].length)} ${m[2].trim()}` : m[1]
        symbols.push({ label: label.trim(), pos: offset, line: i + 1 })
        break // one symbol per line is enough
      }
    }
    offset += raw.length + 1 // +1 for the newline we split on
  }

  return symbols
}
