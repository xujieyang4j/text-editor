import { randomBytes } from 'crypto'

export const MAX_WORKSPACE_UNDO_SNAPSHOT_BYTES = 64 * 1024 * 1024
export const MAX_WORKSPACE_UNDO_SNAPSHOT_FILES = 5_000

export interface WorkspaceUndoAuthorization {
  ownerId: number
  roots: ReadonlySet<string>
  expiresAt: number
  files: ReadonlyMap<string, unknown>
}

/** Return an opaque, cryptographically strong capability token. */
export function createWorkspaceUndoToken(): string {
  return randomBytes(32).toString('base64url')
}

/** Keep one in-memory undo capability from retaining an unbounded workspace. */
export function canRetainWorkspaceUndoSnapshot(
  currentBytes: number,
  currentFiles: number,
  nextFileBytes: number
): boolean {
  return Number.isSafeInteger(currentBytes) && currentBytes >= 0
    && Number.isSafeInteger(currentFiles) && currentFiles >= 0
    && Number.isSafeInteger(nextFileBytes) && nextFileBytes >= 0
    && currentFiles < MAX_WORKSPACE_UNDO_SNAPSHOT_FILES
    && currentBytes <= MAX_WORKSPACE_UNDO_SNAPSHOT_BYTES - nextFileBytes
}

/**
 * Decide whether a transaction capability is usable by the current sender.
 * This intentionally returns one boolean for every rejection case so callers
 * cannot turn missing, foreign, expired, or revoked tokens into an oracle.
 */
export function isWorkspaceUndoAuthorized(
  transaction: WorkspaceUndoAuthorization | undefined,
  senderId: number,
  currentRoots: ReadonlySet<string> | undefined,
  isFileAuthorized: (file: string) => boolean,
  now = Date.now()
): boolean {
  if (!transaction || transaction.ownerId !== senderId || transaction.expiresAt <= now || !currentRoots) return false
  try {
    for (const root of transaction.roots) if (!currentRoots.has(root)) return false
    for (const file of transaction.files.keys()) if (!isFileAuthorized(file)) return false
    return true
  } catch {
    return false
  }
}
