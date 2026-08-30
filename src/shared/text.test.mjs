import assert from 'node:assert/strict'
import {
  SUPPORTED_TEXT_ENCODINGS,
  TEXT_ENCODING_LABELS,
  applyLineEnding,
  detectLineEnding,
  encodeText,
  isTextEncoding,
  jsonStringUtf8ByteLength,
  normalizeLineEndings,
  textEncodingLabel,
  textEncodingNeedsExplicitRead,
  textStatistics
} from '../../out-test/shared/text.js'

assert.deepEqual(SUPPORTED_TEXT_ENCODINGS, [
  'utf8', 'utf8bom', 'utf16le', 'utf16be', 'utf16le-nobom', 'utf16be-nobom',
  'gb18030', 'gbk', 'big5', 'shiftjis', 'windows1252', 'iso88591'
])
for (const encoding of SUPPORTED_TEXT_ENCODINGS) {
  assert.equal(isTextEncoding(encoding), true)
  assert.equal(typeof textEncodingLabel(encoding), 'string')
  assert.equal(textEncodingLabel(encoding), TEXT_ENCODING_LABELS[encoding])
}
for (const value of ['UTF-8', 'shift_jis', 'windows-1252', '', null, 42, {}]) {
  assert.equal(isTextEncoding(value), false)
}
assert.equal(textEncodingLabel('utf16le-nobom'), 'UTF-16 LE (no BOM)')
assert.equal(textEncodingLabel('windows1252'), 'Windows-1252')
assert.equal(textEncodingNeedsExplicitRead('gb18030'), true)
assert.equal(textEncodingNeedsExplicitRead('utf16le-nobom'), true)
assert.equal(textEncodingNeedsExplicitRead('utf8'), false)

assert.equal(detectLineEnding('a\r\nb'), 'CRLF')
assert.equal(detectLineEnding('a\rb'), 'CR')
assert.equal(detectLineEnding('a\nb'), 'LF')
assert.equal(normalizeLineEndings('a\r\nb\rc\nd'), 'a\nb\nc\nd')
assert.equal(jsonStringUtf8ByteLength('abc'), Buffer.byteLength(JSON.stringify('abc'), 'utf8'))
for (const value of ['quote\"slash\\', 'line\nfeed', '中🙂', String.fromCharCode(0, 31), String.fromCharCode(0xd800)]) {
  assert.equal(jsonStringUtf8ByteLength(value), Buffer.byteLength(JSON.stringify(value), 'utf8'))
}
assert.equal(jsonStringUtf8ByteLength('abcdef', 3) > 3, true)
const budgetParts = ['ASCII', '中文', '🙂', '\n', '\\', '"']
assert.equal(
  budgetParts.reduce((total, value) => total + jsonStringUtf8ByteLength(value), 0),
  budgetParts.reduce((total, value) => total + Buffer.byteLength(JSON.stringify(value), 'utf8'), 0)
)
assert.equal(applyLineEnding('a\nb\r\nc', 'CRLF'), 'a\r\nb\r\nc')
assert.deepEqual([...encodeText('hi', 'utf8bom', 'LF').subarray(0, 3)], [0xef, 0xbb, 0xbf])
assert.deepEqual([...encodeText('hi', 'utf16be', 'LF').subarray(0, 2)], [0xfe, 0xff])
const unicodeText = 'A中🙂\nB'
assert.deepEqual(encodeText(unicodeText, 'utf8', 'LF'), Buffer.from(unicodeText, 'utf8'))
assert.deepEqual(
  encodeText(unicodeText, 'utf8bom', 'CR'),
  Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('A中🙂\rB', 'utf8')])
)
assert.deepEqual(
  encodeText(unicodeText, 'utf16le', 'CRLF'),
  Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('A中🙂\r\nB', 'utf16le')])
)
assert.deepEqual(encodeText(unicodeText, 'utf16le-nobom', 'LF'), Buffer.from(unicodeText, 'utf16le'))
const utf16beBody = Buffer.from(unicodeText, 'utf16le')
utf16beBody.swap16()
assert.deepEqual(
  encodeText(unicodeText, 'utf16be', 'LF'),
  Buffer.concat([Buffer.from([0xfe, 0xff]), utf16beBody])
)
assert.deepEqual(encodeText(unicodeText, 'utf16be-nobom', 'LF'), utf16beBody)
assert.equal(encodeText('', 'utf8', 'LF').length, 0)
assert.equal(encodeText('', 'utf8bom', 'LF').length, 3)
assert.equal(encodeText('', 'utf16le', 'LF').length, 2)
assert.equal(encodeText('', 'utf16be', 'LF').length, 2)
assert.equal(encodeText('', 'utf16le-nobom', 'LF').length, 0)
assert.equal(encodeText('', 'utf16be-nobom', 'LF').length, 0)
assert.throws(
  () => encodeText('中文', 'gb18030', 'LF'),
  /GB18030 must be encoded by the main-process text codec/
)
assert.deepEqual(textStatistics('hello world\n你好世界'), { lines: 2, characters: 16, charactersExcludingWhitespace: 14, words: 4 })
assert.deepEqual(textStatistics('e\u0301🙂'), { lines: 1, characters: 2, charactersExcludingWhitespace: 2, words: 1 })
assert.deepEqual(textStatistics(''), { lines: 0, characters: 0, charactersExcludingWhitespace: 0, words: 0 })
console.log('shared text tests passed')
