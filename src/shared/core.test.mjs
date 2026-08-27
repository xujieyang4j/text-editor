import assert from 'node:assert/strict'
import { maxEditableBytes, isBinaryBuffer } from '../../out-test/shared/filePolicy.js'
import { score, fuzzyFilter } from '../../out-test/renderer/src/fuzzy.js'
import { extractSymbols } from '../../out-test/renderer/src/symbols.js'
import { incrementalChanges, revertIncrementalChange } from '../../out-test/renderer/src/incrementalDiff.js'
import { createFromFile, createFromSession, createUntitled, isCurrentDocumentSaveConflict, isDirty, nextUntitledName } from '../../out-test/renderer/src/documents.js'
import { JsonNumber, parseLosslessJson, stringifyLosslessJson } from '../../out-test/shared/losslessJson.js'
import { parseGitRemoteLines, parseGitTracking, sanitizeGitRemoteUrl } from '../../out-test/shared/git.js'
import {
  LspProtocolError,
  MAX_LSP_HEADER_BYTES,
  MAX_LSP_PAYLOAD_BYTES,
  createLspMessageReader,
  encodeLspMessage
} from '../../out-test/shared/lspProtocol.js'
import { EditorSelection, EditorState } from '@codemirror/state'
import { history } from '@codemirror/commands'
import {
  redoSelectionOnly,
  removeMainSelection,
  selectNextOccurrenceAsMain,
  skipCurrentOccurrenceSelection,
  undoSelectionOnly
} from '../../out-test/renderer/src/selectionCommands.js'

assert.equal(maxEditableBytes(1), 1024 * 1024)
assert.equal(maxEditableBytes(0), 1024 * 1024)
assert.equal(maxEditableBytes(300), 200 * 1024 * 1024)
assert.equal(isBinaryBuffer(Buffer.from([0, 1])), true)
assert.equal(isBinaryBuffer(Buffer.from([0, 1]), true), false)
assert.ok(score('mt', 'src/main.ts'))
assert.equal(fuzzyFilter('xyz', ['main.ts'], (item) => item).length, 0)
assert.deepEqual(
  extractSymbols('class App {}\nfunction run() {}\n# Heading').map((symbol) => symbol.label),
  ['App', 'run', '# Heading']
)
const changes = incrementalChanges('one\ntwo\nfour', 'one\nthree\nfour\nfive')
assert.deepEqual(changes.map((change) => [change.kind, change.line, change.lineCount]), [['modified', 2, 1], ['added', 4, 1]])
assert.equal(revertIncrementalChange('one\nthree\nfour\nfive', changes[0]), 'one\ntwo\nfour\nfive')
assert.deepEqual(incrementalChanges('one\ntwo', 'one').map((change) => [change.kind, change.line]), [['deleted', 2]])
const restoredFile = createFromFile('/tmp/example.ts', 'export {}', 'utf16be', 'CRLF')
assert.equal(restoredFile.savedEncoding, 'utf16be')
assert.equal(restoredFile.savedEol, 'CRLF')
assert.equal(restoredFile.diskRevision, null)
assert.equal(isDirty(restoredFile), false)
restoredFile.encoding = 'utf8'
assert.equal(isDirty(restoredFile), true)
restoredFile.encoding = restoredFile.savedEncoding
restoredFile.eol = 'LF'
assert.equal(isDirty(restoredFile), true)
restoredFile.eol = restoredFile.savedEol
assert.equal(isDirty(restoredFile), false)
const untitled = createUntitled()
assert.equal(untitled.savedEncoding, 'utf8')
assert.equal(untitled.savedEol, 'LF')
assert.equal(untitled.requiresSave, false)
assert.equal(isDirty(untitled), false)
const sessionDraft = createFromSession('disk text', {
  path: '/tmp/draft.txt',
  name: 'draft.txt',
  language: 'Plain Text',
  languageLocked: false,
  draft: 'draft text',
  encoding: 'utf16le',
  eol: 'CRLF'
}, { encoding: 'utf8bom', eol: 'CR' })
assert.equal(sessionDraft.encoding, 'utf16le')
assert.equal(sessionDraft.eol, 'CRLF')
assert.equal(sessionDraft.savedEncoding, 'utf8bom')
assert.equal(sessionDraft.savedEol, 'CR')
assert.equal(isDirty(sessionDraft), true)
const recoveredMetadataDraft = createFromSession('latest disk text', {
  path: '/tmp/metadata-only.txt',
  name: 'metadata-only.txt',
  language: 'Plain Text',
  languageLocked: false,
  formatDirty: true,
  encoding: 'utf16le',
  eol: 'CRLF'
}, { encoding: 'utf8', eol: 'LF' })
assert.equal(recoveredMetadataDraft.content, 'latest disk text')
assert.equal(recoveredMetadataDraft.content, recoveredMetadataDraft.savedContent)
assert.equal(recoveredMetadataDraft.encoding, 'utf16le')
assert.equal(recoveredMetadataDraft.eol, 'CRLF')
assert.equal(recoveredMetadataDraft.savedEncoding, 'utf8')
assert.equal(recoveredMetadataDraft.savedEol, 'LF')
assert.equal(isDirty(recoveredMetadataDraft), true)
const cleanSessionFile = createFromSession('disk text', {
  path: '/tmp/clean.txt',
  name: 'clean.txt',
  language: 'Plain Text',
  languageLocked: false,
  encoding: 'utf16le',
  eol: 'CRLF'
}, { encoding: 'utf8bom', eol: 'CR' })
assert.equal(cleanSessionFile.encoding, 'utf8bom')
assert.equal(cleanSessionFile.eol, 'CR')
assert.equal(cleanSessionFile.savedEncoding, 'utf8bom')
assert.equal(cleanSessionFile.savedEol, 'CR')
assert.equal(isDirty(cleanSessionFile), false)
const textOnlyDraft = createFromSession('new disk text', {
  path: '/tmp/text-only.txt',
  name: 'text-only.txt',
  language: 'Plain Text',
  languageLocked: false,
  draft: 'local draft',
  formatDirty: false,
  encoding: 'utf16le',
  eol: 'CRLF'
}, { encoding: 'utf8bom', eol: 'CR' })
assert.equal(textOnlyDraft.content, 'local draft')
assert.equal(textOnlyDraft.encoding, 'utf16le')
assert.equal(textOnlyDraft.eol, 'CRLF')
assert.equal(textOnlyDraft.savedEncoding, 'utf8bom')
assert.equal(textOnlyDraft.savedEol, 'CR')
assert.equal(isDirty(textOnlyDraft), true)
const offlineConflict = createFromSession('external text', {
  path: '/tmp/offline-conflict.txt',
  name: 'offline-conflict.txt',
  language: 'Plain Text',
  languageLocked: false,
  draft: 'local draft',
  formatDirty: false,
  baseRevision: 'sha256:' + 'a'.repeat(64),
  encoding: 'utf8',
  eol: 'LF'
}, { encoding: 'utf8', eol: 'LF', revision: 'sha256:' + 'b'.repeat(64) })
assert.equal(offlineConflict.content, 'local draft')
assert.equal(offlineConflict.diskRevision, 'sha256:' + 'a'.repeat(64))
assert.equal(offlineConflict.externalChange?.content, 'external text')
assert.equal(offlineConflict.externalChange?.revision, 'sha256:' + 'b'.repeat(64))
assert.equal(isDirty(offlineConflict), true)
const recoveredEmptyDraft = createFromSession('', {
  path: null,
  name: 'deleted-empty.txt (recovered)',
  language: 'Plain Text',
  languageLocked: false,
  draft: '',
  formatDirty: false,
  encoding: 'utf16le',
  eol: 'CRLF'
}, { encoding: 'utf16le', eol: 'CRLF', revision: null })
assert.equal(recoveredEmptyDraft.requiresSave, true)
assert.equal(isDirty(recoveredEmptyDraft), true)
assert.equal(isCurrentDocumentSaveConflict(false, '/tmp/source.txt', '/tmp/source.txt', '/tmp/source.txt'), true)
assert.equal(isCurrentDocumentSaveConflict(true, '/tmp/source.txt', '/tmp/source.txt', '/tmp/target.txt'), false)
assert.equal(isCurrentDocumentSaveConflict(false, null, null, '/tmp/target.txt'), false)
assert.equal(isCurrentDocumentSaveConflict(false, '/tmp/source.txt', '/tmp/moved.txt', '/tmp/source.txt'), false)
assert.equal(createUntitled([restoredFile.name]).name, 'Untitled-1')
assert.equal(nextUntitledName(['Untitled-1', 'notes.txt', 'Untitled-3']), 'Untitled-2')
assert.equal(createUntitled(['Untitled-1', 'Untitled-2']).name, 'Untitled-3')
assert.equal(/<content>([\s\S]*?)<\/content>/i.exec('<snippet><content>line 1\nline 2</content></snippet>')?.[1], 'line 1\nline 2')
assert.equal(JSON.stringify(JSON.parse('{"a":1,"list":[true,null]}'), null, 2), '{\n  "a": 1,\n  "list": [\n    true,\n    null\n  ]\n}')
const lossless = parseLosslessJson('{"id":7651669476812652838,"small":42,"decimal":1.2300e+10}')
assert.ok(lossless.id instanceof JsonNumber)
assert.equal(lossless.id.raw, '7651669476812652838')
assert.equal(stringifyLosslessJson(lossless, 2), '{\n  "id": 7651669476812652838,\n  "small": 42,\n  "decimal": 1.2300e+10\n}')
assert.equal(sanitizeGitRemoteUrl('https://alice:secret@example.com/org/repo.git'), 'https://example.com/org/repo.git')
assert.equal(sanitizeGitRemoteUrl('git@example.com:org/repo.git'), 'example.com:org/repo.git')
assert.equal(sanitizeGitRemoteUrl('ssh://git@example.com/org/repo.git'), 'ssh://example.com/org/repo.git')
assert.equal(sanitizeGitRemoteUrl('https://example.com/repo.git?token=secret#private'), 'https://example.com/repo.git')
assert.equal(sanitizeGitRemoteUrl('alice:secret@example.com:org/repo.git'), 'example.com:org/repo.git')
assert.equal(sanitizeGitRemoteUrl('foo::https://alice:secret@example.com/org/repo.git'), 'foo::https://example.com/org/repo.git')
assert.equal(sanitizeGitRemoteUrl('ext::https://alice:secret@example.com/org/repo.git'), 'ext::[redacted]')
assert.equal(sanitizeGitRemoteUrl('ext::sh -c token=secret'), 'ext::[redacted]')
assert.deepEqual(parseGitRemoteLines([
  'remote.upstream.url https://token@example.com/org/主仓库.git',
  'remote.origin.url git@example.com:org/repo.git',
  'remote.origin.pushurl ssh://git:secret@example.com/org/repo.git'
].join('\n')), [
  { name: 'origin', fetchUrl: 'example.com:org/repo.git', pushUrl: 'ssh://example.com/org/repo.git' },
  { name: 'upstream', fetchUrl: 'https://example.com/org/主仓库.git' }
])
assert.deepEqual(parseGitTracking('origin/main\n', '3\t2\n', 'origin', 'refs/heads/main'), {
  upstream: 'origin/main', remote: 'origin', remoteBranch: 'main', ahead: 3, behind: 2
})
assert.deepEqual(parseGitTracking('', 'bad values'), {})

const lspFrame = (payload) => Buffer.concat([
  Buffer.from(`Content-Length: ${payload.length}\r\n\r\n`, 'ascii'),
  payload
])
const lspHarness = () => {
  const messages = []
  const errors = []
  return {
    messages,
    errors,
    read: createLspMessageReader(
      (message) => messages.push(message),
      (error) => errors.push(error)
    )
  }
}
const assertProtocolError = (error, fatal, pattern) => {
  assert.ok(error instanceof LspProtocolError)
  assert.equal(error.fatal, fatal)
  assert.match(error.message, pattern)
}

const chunkedLsp = lspHarness()
const unicodeFrame = encodeLspMessage({ jsonrpc: '2.0', id: 1, result: '你好🙂' })
for (let index = 0; index < unicodeFrame.length; index += 1) {
  chunkedLsp.read(unicodeFrame.subarray(index, index + 1))
}
assert.deepEqual(chunkedLsp.messages, [{ jsonrpc: '2.0', id: 1, result: '你好🙂' }])
assert.equal(chunkedLsp.errors.length, 0)

const lowerCasePayload = Buffer.from('{"jsonrpc":"2.0","method":"ready"}')
const lowerCaseFrame = Buffer.concat([
  Buffer.from(`content-length: ${lowerCasePayload.length}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n`),
  lowerCasePayload
])
const consecutiveLsp = lspHarness()
consecutiveLsp.read(Buffer.concat([
  lowerCaseFrame,
  encodeLspMessage({ jsonrpc: '2.0', id: 2, result: null })
]))
assert.deepEqual(consecutiveLsp.messages, [
  { jsonrpc: '2.0', method: 'ready' },
  { jsonrpc: '2.0', id: 2, result: null }
])
assert.equal(consecutiveLsp.errors.length, 0)

// Once framing is untrustworthy, no bytes (including an embedded fake frame)
// are scanned for a new Content-Length marker and the reader stays stopped.
const ignoredMessage = encodeLspMessage({ jsonrpc: '2.0', id: 'ignored' })
const fatalFrames = [
  { bytes: Buffer.from('Content-Length: nope\r\n\r\n'), pattern: /Content-Length/ },
  { bytes: Buffer.from('Content-Length: +2\r\n\r\n'), pattern: /Content-Length/ },
  { bytes: Buffer.from('Content-Length: 2.0\r\n\r\n'), pattern: /Content-Length/ },
  { bytes: Buffer.from('Content-Length: 9007199254740992\r\n\r\n'), pattern: /Content-Length/ },
  { bytes: Buffer.from('Content-Type: application/json\r\n\r\n'), pattern: /Missing.*Content-Length/ },
  { bytes: Buffer.from('Content-Length: 2\r\ncontent-length: 2\r\n\r\n'), pattern: /Duplicate/ },
  { bytes: Buffer.from('Not-A-Header\r\n\r\n'), pattern: /Malformed/ },
  {
    bytes: Buffer.from(`Content-Length: ${MAX_LSP_PAYLOAD_BYTES + 1}\r\n\r\n`),
    pattern: /payload exceeds/
  },
  { bytes: Buffer.alloc(MAX_LSP_HEADER_BYTES + 1, 120), pattern: /header exceeds/ },
  {
    bytes: Buffer.concat([
      Buffer.from('Content-Length: 2\r\nX-Non-Ascii: ', 'ascii'),
      Buffer.from([0xff]),
      Buffer.from('\r\n\r\n', 'ascii')
    ]),
    pattern: /ASCII/
  }
]
for (const { bytes, pattern } of fatalFrames) {
  const fatalLsp = lspHarness()
  fatalLsp.read(Buffer.concat([bytes, ignoredMessage]))
  fatalLsp.read(ignoredMessage)
  assert.deepEqual(fatalLsp.messages, [])
  assert.equal(fatalLsp.errors.length, 1)
  assertProtocolError(fatalLsp.errors[0], true, pattern)
}

// Exactly MAX_LSP_HEADER_BYTES before the delimiter is valid.
const objectPayload = Buffer.from('{}', 'utf8')
const exactHeaderPrefix = Buffer.from(
  `Content-Length: ${objectPayload.length}\r\nX-Padding: `,
  'ascii'
)
const exactHeader = Buffer.concat([
  exactHeaderPrefix,
  Buffer.alloc(MAX_LSP_HEADER_BYTES - exactHeaderPrefix.length, 120)
])
assert.equal(exactHeader.length, MAX_LSP_HEADER_BYTES)
const headerBoundaryLsp = lspHarness()
headerBoundaryLsp.read(Buffer.concat([
  exactHeader,
  Buffer.from('\r\n\r\n', 'ascii'),
  objectPayload
]))
assert.deepEqual(headerBoundaryLsp.messages, [{}])
assert.deepEqual(headerBoundaryLsp.errors, [])

// Invalid payload content has a known boundary, so it is nonfatal and the next
// complete frame is still parsed. This includes strict UTF-8 decoding.
const payloadRecoveryLsp = lspHarness()
payloadRecoveryLsp.read(Buffer.concat([
  lspFrame(Buffer.from([0xc3, 0x28])),
  lspFrame(Buffer.from('{"incomplete":', 'utf8')),
  lspFrame(Buffer.from('null', 'utf8')),
  lspFrame(Buffer.from('[1,2,3]', 'utf8')),
  lspFrame(Buffer.from('"string"', 'utf8')),
  lspFrame(Buffer.alloc(0)),
  encodeLspMessage({ jsonrpc: '2.0', id: 3, result: 'recovered' })
]))
assert.deepEqual(payloadRecoveryLsp.messages, [
  { jsonrpc: '2.0', id: 3, result: 'recovered' }
])
assert.equal(payloadRecoveryLsp.errors.length, 6)
assertProtocolError(payloadRecoveryLsp.errors[0], false, /UTF-8/)
assertProtocolError(payloadRecoveryLsp.errors[1], false, /Invalid JSON/)
for (const error of payloadRecoveryLsp.errors.slice(2, 5)) {
  assertProtocolError(error, false, /JSON object/)
}
assertProtocolError(payloadRecoveryLsp.errors[5], false, /Invalid JSON/)

// Exercise large, irregularly chunked input and both inclusive payload limits.
const emptyDataBytes = Buffer.byteLength(JSON.stringify({ data: '' }), 'utf8')
const maximumMessage = { data: 'x'.repeat(MAX_LSP_PAYLOAD_BYTES - emptyDataBytes) }
const maximumFrame = encodeLspMessage(maximumMessage)
const maximumPayloadStart = maximumFrame.indexOf('\r\n\r\n') + 4
assert.equal(maximumFrame.length - maximumPayloadStart, MAX_LSP_PAYLOAD_BYTES)
const maximumLsp = lspHarness()
for (let offset = 0; offset < maximumFrame.length; offset += 65_537) {
  maximumLsp.read(maximumFrame.subarray(offset, offset + 65_537))
}
assert.equal(maximumLsp.messages.length, 1)
assert.equal(maximumLsp.messages[0].data.length, maximumMessage.data.length)
assert.equal(maximumLsp.errors.length, 0)
assert.throws(
  () => encodeLspMessage({ data: `${maximumMessage.data}x` }),
  /payload exceeds/
)

for (const value of [undefined, null, true, 1, 'message', []]) {
  assert.throws(() => encodeLspMessage(value), /non-null JSON object/)
}
const circularMessage = {}
circularMessage.self = circularMessage
for (const value of [
  circularMessage,
  { value: 1n },
  { toJSON: () => undefined },
  { toJSON: () => [] }
]) {
  assert.throws(() => encodeLspMessage(value), {
    name: 'TypeError',
    message: 'LSP message is not JSON serializable.'
  })
}

const runStateCommand = (box, command) => command({
  state: box.state,
  dispatch: (transaction) => { box.state = transaction.state }
})
const occurrenceBox = {
  state: EditorState.create({
    doc: 'foo foo foo',
    selection: EditorSelection.range(0, 3),
    extensions: [EditorState.allowMultipleSelections.of(true), history()]
  })
}
assert.equal(runStateCommand(occurrenceBox, selectNextOccurrenceAsMain), true)
assert.equal(occurrenceBox.state.selection.main.from, 4)
assert.equal(runStateCommand(occurrenceBox, selectNextOccurrenceAsMain), true)
assert.equal(occurrenceBox.state.selection.main.from, 8)
const withoutLast = removeMainSelection(occurrenceBox.state.selection)
assert.ok(withoutLast)
assert.deepEqual(withoutLast.ranges.map((range) => range.from), [0, 4])
assert.equal(withoutLast.main.from, 4)

const wrappedBox = {
  state: EditorState.create({
    doc: 'foo foo foo',
    selection: EditorSelection.range(4, 7),
    extensions: [EditorState.allowMultipleSelections.of(true), history()]
  })
}
assert.equal(runStateCommand(wrappedBox, selectNextOccurrenceAsMain), true)
assert.equal(wrappedBox.state.selection.main.from, 8)
assert.equal(runStateCommand(wrappedBox, selectNextOccurrenceAsMain), true)
assert.equal(wrappedBox.state.selection.main.from, 0)
const afterWrappedRemoval = removeMainSelection(wrappedBox.state.selection)
assert.ok(afterWrappedRemoval)
assert.equal(afterWrappedRemoval.main.from, 8)
const skipped = skipCurrentOccurrenceSelection(EditorState.create({
  doc: 'foo foo foo foo',
  selection: EditorSelection.create([
    EditorSelection.range(0, 3),
    EditorSelection.range(4, 7)
  ], 1),
  extensions: EditorState.allowMultipleSelections.of(true)
}))
assert.ok(skipped)
assert.deepEqual(skipped.ranges.map((range) => range.from), [0, 8])
assert.equal(skipped.main.from, 8)
const wholeWordSkipped = skipCurrentOccurrenceSelection(EditorState.create({
  doc: 'foo foobar foo',
  selection: EditorSelection.create([
    EditorSelection.range(0, 3),
    EditorSelection.range(11, 14)
  ], 0),
  extensions: EditorState.allowMultipleSelections.of(true)
}))
assert.equal(wholeWordSkipped, null)

const selectionHistoryBox = { state: EditorState.create({ doc: 'abc', extensions: history() }) }
selectionHistoryBox.state = selectionHistoryBox.state.update({ selection: { anchor: 1 }, userEvent: 'select.keyboard' }).state
assert.equal(runStateCommand(selectionHistoryBox, undoSelectionOnly), true)
assert.equal(selectionHistoryBox.state.selection.main.head, 0)
assert.equal(runStateCommand(selectionHistoryBox, redoSelectionOnly), true)
assert.equal(selectionHistoryBox.state.selection.main.head, 1)
selectionHistoryBox.state = selectionHistoryBox.state.update({ changes: { from: 1, insert: 'X' }, userEvent: 'input.type' }).state
const editedText = selectionHistoryBox.state.doc.toString()
assert.equal(runStateCommand(selectionHistoryBox, undoSelectionOnly), false)
assert.equal(selectionHistoryBox.state.doc.toString(), editedText)
console.log('shared core tests passed')
