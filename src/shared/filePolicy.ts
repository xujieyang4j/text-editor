/** File-open policy shared by main process and unit tests. */
export const DEFAULT_MAX_EDITABLE_FILE_SIZE_MB = 200
export const MAX_EDITABLE_FILE_SIZE_MB = 200
export const LEGACY_DEFAULT_MAX_EDITABLE_FILE_SIZE_MB = 20
export const CURRENT_FILE_SIZE_SETTINGS_FORMAT_VERSION = 2

/**
 * Preserve an explicit modern limit while upgrading the old, unversioned
 * product default. Electron did not record a settings version before this
 * migration, so version 1 represents the prior schema.
 */
export function migrateMaximumFileSizeMB(
  value: unknown, storedFormatVersion: unknown
): number {
  const maximum = typeof value === 'number' && Number.isFinite(value)
    ? Math.max(1, Math.min(MAX_EDITABLE_FILE_SIZE_MB, Math.round(value)))
    : DEFAULT_MAX_EDITABLE_FILE_SIZE_MB
  const version = typeof storedFormatVersion === 'number'
    && Number.isSafeInteger(storedFormatVersion)
    ? storedFormatVersion
    : 1
  return version < CURRENT_FILE_SIZE_SETTINGS_FORMAT_VERSION
    && maximum === LEGACY_DEFAULT_MAX_EDITABLE_FILE_SIZE_MB
    ? DEFAULT_MAX_EDITABLE_FILE_SIZE_MB
    : maximum
}

export function maxEditableBytes(maxFileSizeMB: number): number {
  const safeMB = Number.isFinite(maxFileSizeMB)
    ? Math.max(1, Math.min(MAX_EDITABLE_FILE_SIZE_MB, maxFileSizeMB))
    : DEFAULT_MAX_EDITABLE_FILE_SIZE_MB
  return Math.round(safeMB * 1024 * 1024)
}

/** Distinguish a large text file from a binary-looking buffer without reading it all. */
export function isBinaryBuffer(buffer: Buffer, utf16 = false): boolean {
  if (utf16) return false
  return buffer.subarray(0, 8_192).includes(0)
}
