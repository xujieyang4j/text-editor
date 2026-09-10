import assert from 'node:assert/strict'
import {
  MAX_WORKSPACE_UNDO_SNAPSHOT_BYTES,
  MAX_WORKSPACE_UNDO_SNAPSHOT_FILES,
  canRetainWorkspaceUndoSnapshot,
  createWorkspaceUndoToken,
  isWorkspaceUndoAuthorized
} from '../../out-test/main/workspaceUndo.js'

const firstToken = createWorkspaceUndoToken()
const secondToken = createWorkspaceUndoToken()
assert.match(firstToken, /^[A-Za-z0-9_-]{43}$/)
assert.match(secondToken, /^[A-Za-z0-9_-]{43}$/)
assert.notEqual(firstToken, secondToken)
assert.equal(canRetainWorkspaceUndoSnapshot(0, 0, 1), true)
assert.equal(canRetainWorkspaceUndoSnapshot(
  MAX_WORKSPACE_UNDO_SNAPSHOT_BYTES - 1,
  MAX_WORKSPACE_UNDO_SNAPSHOT_FILES - 1,
  1
), true)
assert.equal(canRetainWorkspaceUndoSnapshot(
  MAX_WORKSPACE_UNDO_SNAPSHOT_BYTES,
  0,
  1
), false)
assert.equal(canRetainWorkspaceUndoSnapshot(
  0,
  MAX_WORKSPACE_UNDO_SNAPSHOT_FILES,
  1
), false)
assert.equal(canRetainWorkspaceUndoSnapshot(0, 0, Number.NaN), false)

const files = new Map([['/workspace/a.txt', {}], ['/workspace/b.txt', {}]])
const transaction = {
  ownerId: 17,
  roots: new Set(['/workspace']),
  expiresAt: 2_000,
  files
}
const currentRoots = new Set(['/workspace'])
const allFilesGranted = (file) => files.has(file)

assert.equal(
  isWorkspaceUndoAuthorized(transaction, 17, currentRoots, allFilesGranted, 1_999),
  true
)
assert.equal(isWorkspaceUndoAuthorized(undefined, 17, currentRoots, allFilesGranted, 1_999), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 18, currentRoots, allFilesGranted, 1_999), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 17, undefined, allFilesGranted, 1_999), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 17, new Set(), allFilesGranted, 1_999), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 17, currentRoots, () => false, 1_999), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 17, currentRoots, allFilesGranted, 2_000), false)
assert.equal(isWorkspaceUndoAuthorized(transaction, 17, currentRoots, () => {
  throw new Error('hostile authorizer')
}, 1_999), false)

console.log('workspace undo authorization tests passed')
