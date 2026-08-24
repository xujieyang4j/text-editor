import type { WorkspaceSymbol } from './ipc.js'

/** Patterns shared by per-file and workspace symbol navigation. */
const PATTERNS: RegExp[] = [
  /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/,
  /^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/,
  /^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(?[^=]*\)?\s*=>/,
  /^\s*(?:public|private|protected|static|\s)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/,
  /^\s*def\s+([A-Za-z_]\w*)/,
  /^\s*class\s+([A-Za-z_]\w*)/,
  /^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)/,
  /^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)/,
  /^(#{1,6})\s+(.*)$/
]

/** Extract project-indexable symbols from text without loading a language server. */
export function extractWorkspaceSymbols(path: string, text: string): WorkspaceSymbol[] {
  const symbols: WorkspaceSymbol[] = []
  const lines = text.split(/\r\n|\r|\n/)
  for (let index = 0; index < lines.length; index += 1) {
    const source = lines[index]
    for (const pattern of PATTERNS) {
      const match = pattern.exec(source)
      if (!match) continue
      const label = match[2] !== undefined ? `${'#'.repeat(match[1].length)} ${match[2].trim()}` : match[1]
      symbols.push({ path, label: label.trim(), line: index + 1, column: Math.max(1, match.index + 1) })
      break
    }
  }
  return symbols
}
