import assert from 'node:assert/strict'
import { detectLineEnding, applyLineEnding, encodeText } from '../../out-test/text.js'

assert.equal(detectLineEnding('a\r\nb'), 'CRLF')
assert.equal(detectLineEnding('a\rb'), 'CR')
assert.equal(detectLineEnding('a\nb'), 'LF')
assert.equal(applyLineEnding('a\nb\r\nc', 'CRLF'), 'a\r\nb\r\nc')
assert.deepEqual([...encodeText('hi', 'utf8bom', 'LF').subarray(0, 3)], [0xef, 0xbb, 0xbf])
assert.deepEqual([...encodeText('hi', 'utf16be', 'LF').subarray(0, 2)], [0xfe, 0xff])
console.log('shared text tests passed')
