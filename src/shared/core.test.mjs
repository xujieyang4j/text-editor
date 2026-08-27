import assert from 'node:assert/strict'
import { maxEditableBytes, isBinaryBuffer } from '../../out-test/shared/filePolicy.js'
import { score, fuzzyFilter } from '../../out-test/renderer/src/fuzzy.js'
import { extractSymbols } from '../../out-test/renderer/src/symbols.js'
import { incrementalChanges, revertIncrementalChange } from '../../out-test/renderer/src/incrementalDiff.js'
import { createFromFile, createUntitled, nextUntitledName } from '../../out-test/renderer/src/documents.js'
import { JsonNumber, parseLosslessJson, stringifyLosslessJson } from '../../out-test/shared/losslessJson.js'
import { parseGitRemoteLines, parseGitTracking, sanitizeGitRemoteUrl } from '../../out-test/shared/git.js'
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
const restoredFile = createFromFile('/tmp/example.ts', 'export {}')
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
