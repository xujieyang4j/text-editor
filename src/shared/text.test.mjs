import assert from 'node:assert/strict'
import { detectLineEnding, applyLineEnding, encodeText, textStatistics } from '../../out-test/shared/text.js'

assert.equal(detectLineEnding('a\r\nb'), 'CRLF')
assert.equal(detectLineEnding('a\rb'), 'CR')
assert.equal(detectLineEnding('a\nb'), 'LF')
assert.equal(applyLineEnding('a\nb\r\nc', 'CRLF'), 'a\r\nb\r\nc')
assert.deepEqual([...encodeText('hi', 'utf8bom', 'LF').subarray(0, 3)], [0xef, 0xbb, 0xbf])
assert.deepEqual([...encodeText('hi', 'utf16be', 'LF').subarray(0, 2)], [0xfe, 0xff])
assert.deepEqual(textStatistics('hello world\n你好世界'), { lines: 2, characters: 16, charactersExcludingWhitespace: 14, words: 4 })
assert.deepEqual(textStatistics('e\u0301🙂'), { lines: 1, characters: 2, charactersExcludingWhitespace: 2, words: 1 })
assert.deepEqual(textStatistics(''), { lines: 0, characters: 0, charactersExcludingWhitespace: 0, words: 0 })
console.log('shared text tests passed')
