import assert from 'node:assert/strict'
import { maxEditableBytes, isBinaryBuffer } from '../../out-test/shared/filePolicy.js'
import { score, fuzzyFilter } from '../../out-test/renderer/src/fuzzy.js'
import { extractSymbols } from '../../out-test/renderer/src/symbols.js'
import { incrementalChanges, revertIncrementalChange } from '../../out-test/renderer/src/incrementalDiff.js'
import { createFromFile, createUntitled, nextUntitledName } from '../../out-test/renderer/src/documents.js'
import { JsonNumber, parseLosslessJson, stringifyLosslessJson } from '../../out-test/shared/losslessJson.js'

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
console.log('shared core tests passed')
