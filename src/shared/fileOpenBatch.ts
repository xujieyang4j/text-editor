/**
 * Produce a bounded, order-preserving file-open batch after platform code has
 * already canonicalised each selected path. Keeping this policy outside the
 * Electron main process makes the multi-file contract testable on every OS.
 */
export function planFileOpenBatch(
  paths: readonly string[], maximum: number
): { accepted: string[]; rejected: string[] } {
  const limit = Number.isSafeInteger(maximum) ? Math.max(0, maximum) : 0
  const accepted: string[] = []
  const rejected: string[] = []
  const seen = new Set<string>()

  for (const path of paths) {
    if (seen.has(path)) continue
    seen.add(path)
    if (accepted.length < limit) accepted.push(path)
    else rejected.push(path)
  }
  return { accepted, rejected }
}
