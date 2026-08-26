/**
 * A tiny subsequence fuzzy matcher, in the spirit of Sublime's Goto Anything.
 *
 * `score` returns null when `query` is not a subsequence of `text`, otherwise a
 * numeric score (higher = better) plus the matched character indices so the UI
 * can highlight them. Consecutive matches, word-boundary matches and
 * earlier matches are rewarded, mirroring how fuzzy finders "feel" right.
 */

export interface FuzzyResult {
  score: number
  /** Indices into `text` that were matched, for highlight rendering. */
  matches: number[]
}

/** Characters that begin a "word" and therefore deserve a bonus when matched. */
function isBoundary(ch: string): boolean {
  return ch === '/' || ch === '\\' || ch === '_' || ch === '-' || ch === '.' || ch === ' '
}

/**
 * Score `query` against `text`. Case-insensitive. Returns null on no match.
 */
export function score(query: string, text: string): FuzzyResult | null {
  if (query.length === 0) return { score: 1, matches: [] }
  if (query.length > text.length) return null

  const q = query.toLowerCase()
  const t = text.toLowerCase()

  let qi = 0
  let ti = 0
  let total = 0
  let consecutive = 0
  const matches: number[] = []

  while (qi < q.length && ti < t.length) {
    if (q[qi] === t[ti]) {
      matches.push(ti)

      let bonus = 10
      // Reward consecutive runs progressively.
      bonus += consecutive * 5
      // Reward matches at the very start.
      if (ti === 0) bonus += 15
      // Reward matches right after a word boundary (e.g. after "/" or "_").
      else if (isBoundary(t[ti - 1])) bonus += 10
      // Reward camelCase humps (lowercase followed by the matched uppercase).
      else if (text[ti] >= 'A' && text[ti] <= 'Z') bonus += 8

      total += bonus
      consecutive += 1
      qi += 1
    } else {
      // Small penalty for each skipped character (prefers tighter matches).
      total -= 1
      consecutive = 0
    }
    ti += 1
  }

  // Not all query characters were consumed → no match.
  if (qi < q.length) return null

  // Prefer shorter texts overall (a full-name match beats a substring in a
  // very long path).
  total -= text.length * 0.1

  return { score: total, matches }
}

/** Convenience: filter + sort a list of items by their fuzzy score. */
export function fuzzyFilter<T>(
  query: string,
  items: T[],
  key: (item: T) => string
): Array<{ item: T; result: FuzzyResult }> {
  const scored: Array<{ item: T; result: FuzzyResult }> = []
  for (const item of items) {
    const result = score(query, key(item))
    if (result) scored.push({ item, result })
  }
  scored.sort((a, b) => b.result.score - a.result.score)
  return scored
}
