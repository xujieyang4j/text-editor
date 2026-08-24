/** File-open policy shared by main process and unit tests. */
export function maxEditableBytes(maxFileSizeMB: number): number {
  const safeMB = Number.isFinite(maxFileSizeMB) ? Math.max(1, Math.min(200, maxFileSizeMB)) : 20
  return Math.round(safeMB * 1024 * 1024)
}

/** Distinguish a large text file from a binary-looking buffer without reading it all. */
export function isBinaryBuffer(buffer: Buffer, utf16 = false): boolean {
  if (utf16) return false
  return buffer.subarray(0, 8_192).includes(0)
}
