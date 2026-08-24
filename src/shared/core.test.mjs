import assert from 'node:assert/strict'
import { maxEditableBytes, isBinaryBuffer } from '../../out-test/shared/filePolicy.js'
import { score, fuzzyFilter } from '../../out-test/renderer/src/fuzzy.js'
import { extractSymbols } from '../../out-test/renderer/src/symbols.js'

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
console.log('shared core tests passed')
