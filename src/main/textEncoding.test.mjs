import assert from 'node:assert/strict'
import {
  decodeText,
  decodeTextAuto,
  decodeTextBytes,
  decodeTextWithEncoding,
  detectTextEncoding,
  encodeTextBytes
} from '../../out-test/main/textEncoding.js'

const utf8Bom = Buffer.from([0xef, 0xbb, 0xbf])
const utf16leBom = Buffer.from([0xff, 0xfe])
const utf16beBom = Buffer.from([0xfe, 0xff])

function utf16be(text) {
  const bytes = Buffer.from(text, 'utf16le')
  bytes.swap16()
  return bytes
}

// BOMs take priority over both UTF-16 heuristics and malformed payloads.
assert.equal(detectTextEncoding(Buffer.concat([utf8Bom, Buffer.from([0, 65, 0, 66, 0, 67, 0, 68])])), 'utf8bom')
assert.equal(detectTextEncoding(Buffer.concat([utf16leBom, Buffer.from([0xff])])), 'utf16le')
assert.equal(detectTextEncoding(Buffer.concat([utf16beBom, Buffer.from([0xff])])), 'utf16be')
assert.equal(detectTextEncoding(Buffer.alloc(0)), 'utf8')

// BOM-less UTF-16 is recognised only with a sufficiently strong NUL lane.
const bomlessText = 'hello world 中文'
const bomlessLe = Buffer.from(bomlessText, 'utf16le')
const bomlessBe = utf16be(bomlessText)
assert.equal(detectTextEncoding(bomlessLe), 'utf16le-nobom')
assert.equal(detectTextEncoding(bomlessBe), 'utf16be-nobom')
assert.deepEqual(decodeTextAuto(bomlessLe), {
  content: bomlessText,
  encoding: 'utf16le-nobom',
  hadDecodingErrors: false,
  uncertain: true
})
assert.deepEqual(decodeTextAuto(bomlessBe), {
  content: bomlessText,
  encoding: 'utf16be-nobom',
  hadDecodingErrors: false,
  uncertain: true
})
assert.equal(detectTextEncoding(Buffer.from([65, 0, 66, 0])), 'utf8') // Too short to guess.
assert.equal(detectTextEncoding(Buffer.alloc(16)), 'utf8') // NULs in both lanes are ambiguous/binary.
assert.equal(detectTextEncoding(Buffer.from('中文字符', 'utf16le')), 'utf8') // No reliable NUL lane.

// UTF-8 is strict when selected explicitly; automatic opening remains usable
// and carries a precise signal that lets the UI offer another encoding.
const validUtf8 = Buffer.from('Hello 中🙂', 'utf8')
assert.deepEqual(decodeTextAuto(validUtf8), {
  content: 'Hello 中🙂',
  encoding: 'utf8',
  hadDecodingErrors: false,
  uncertain: false
})
for (const malformed of [
  Buffer.from([0xc0, 0xaf]), // Overlong encoding.
  Buffer.from([0xed, 0xa0, 0x80]), // UTF-8 encoded surrogate.
  Buffer.from([0xf4, 0x90, 0x80, 0x80]), // Above U+10FFFF.
  Buffer.from([0xf0, 0x9f, 0x98]) // Truncated sequence.
]) {
  assert.throws(() => decodeTextBytes(malformed, 'utf8'), /Invalid UTF-8 data/)
  const automatic = decodeTextAuto(malformed)
  assert.equal(automatic.encoding, 'utf8')
  assert.equal(automatic.hadDecodingErrors, true)
  assert.equal(automatic.uncertain, false)
  assert.match(automatic.content, /�/)
}

// Explicit decoding strips only a matching BOM.
assert.equal(decodeTextBytes(Buffer.concat([utf8Bom, Buffer.from('A')]), 'utf8bom'), 'A')
assert.equal(decodeText(Buffer.concat([utf8Bom, Buffer.from('A')]), 'utf8'), '\ufeffA')
assert.equal(decodeTextBytes(Buffer.from('A'), 'utf8bom'), 'A')
assert.equal(decodeTextBytes(Buffer.concat([utf16leBom, Buffer.from('A', 'utf16le')]), 'utf16le'), 'A')
assert.equal(decodeTextBytes(Buffer.concat([utf16leBom, Buffer.from('A', 'utf16le')]), 'utf16le-nobom'), '\ufeffA')
assert.equal(decodeTextBytes(Buffer.concat([utf16beBom, utf16be('A')]), 'utf16be'), 'A')
assert.equal(decodeTextBytes(Buffer.concat([utf16beBom, utf16be('A')]), 'utf16be-nobom'), '\ufeffA')
assert.equal(decodeTextBytes(Buffer.concat([utf16beBom, utf16be('A')]), 'utf16le').charCodeAt(0), 0xfffe)
assert.equal(decodeTextBytes(Buffer.concat([utf8Bom, Buffer.from('A')]), 'windows1252'), 'ï»¿A')

// UTF-16 odd byte counts and malformed surrogate pairs are never silently
// truncated. Auto mode substitutes U+FFFD and reports the problem.
const oddUtf16 = Buffer.from([0xff, 0xfe, 0x41, 0x00, 0x42])
assert.throws(() => decodeTextBytes(oddUtf16, 'utf16le'), /UTF-16 byte length is odd/)
assert.deepEqual(decodeTextAuto(oddUtf16), {
  content: 'A�',
  encoding: 'utf16le',
  hadDecodingErrors: true,
  uncertain: false
})
const loneSurrogate = Buffer.from([0xff, 0xfe, 0x00, 0xd8])
assert.throws(() => decodeTextBytes(loneSurrogate, 'utf16le'), /Invalid UTF-16 LE data/)
assert.deepEqual(decodeTextAuto(loneSurrogate), {
  content: '�',
  encoding: 'utf16le',
  hadDecodingErrors: true,
  uncertain: false
})
assert.deepEqual(decodeTextAuto(utf8Bom), {
  content: '', encoding: 'utf8bom', hadDecodingErrors: false, uncertain: false
})
assert.deepEqual(decodeTextWithEncoding(Buffer.from([0xf0, 0x9f, 0x98]), 'utf8'), {
  content: '�', encoding: 'utf8', hadDecodingErrors: true, uncertain: false
})
assert.deepEqual(decodeTextWithEncoding(oddUtf16, 'utf16le'), {
  content: 'A�', encoding: 'utf16le', hadDecodingErrors: true, uncertain: false
})
assert.deepEqual(decodeTextWithEncoding(Buffer.from('plain'), 'utf8bom'), {
  content: 'plain', encoding: 'utf8', hadDecodingErrors: false, uncertain: false
})
assert.deepEqual(decodeTextWithEncoding(Buffer.from('plain', 'utf16le'), 'utf16le'), {
  content: 'plain', encoding: 'utf16le-nobom', hadDecodingErrors: false, uncertain: false
})

// Unicode writers preserve the BOM distinction, including empty files.
assert.deepEqual(encodeTextBytes('A中🙂', 'utf8'), Buffer.from('A中🙂', 'utf8'))
assert.deepEqual(encodeTextBytes('A', 'utf8bom'), Buffer.concat([utf8Bom, Buffer.from('A')]))
assert.deepEqual(encodeTextBytes('A中🙂', 'utf16le'), Buffer.concat([utf16leBom, Buffer.from('A中🙂', 'utf16le')]))
assert.deepEqual(encodeTextBytes('A中🙂', 'utf16le-nobom'), Buffer.from('A中🙂', 'utf16le'))
assert.deepEqual(encodeTextBytes('A中🙂', 'utf16be'), Buffer.concat([utf16beBom, utf16be('A中🙂')]))
assert.deepEqual(encodeTextBytes('A中🙂', 'utf16be-nobom'), utf16be('A中🙂'))
assert.equal(encodeTextBytes('', 'utf8bom').length, 3)
assert.equal(encodeTextBytes('', 'utf16le').length, 2)
assert.equal(encodeTextBytes('', 'utf16be').length, 2)
assert.equal(encodeTextBytes('', 'utf16le-nobom').length, 0)
assert.equal(encodeTextBytes('', 'utf16be-nobom').length, 0)
const supportedEncodings = [
  'utf8',
  'utf8bom',
  'utf16le',
  'utf16be',
  'utf16le-nobom',
  'utf16be-nobom',
  'gb18030',
  'gbk',
  'big5',
  'shiftjis',
  'windows1252',
  'iso88591'
]
for (const encoding of supportedEncodings) {
  for (const malformed of [
    String.fromCharCode(0xd800), // Isolated high surrogate.
    String.fromCharCode(0xdc00), // Isolated low surrogate.
    `before${String.fromCharCode(0xdfff)}after`
  ]) {
    assert.throws(
      () => encodeTextBytes(malformed, encoding),
      (error) => error instanceof Error
        && error.message.includes('malformed Unicode text')
        && error.message.includes('without data loss')
    )
  }
}

// Legacy encodings use their canonical codec and must round-trip exactly.
const representable = [
  ['gb18030', '中文😀€', 'd6d0cec49439fc36a2e3'],
  ['gbk', '中文€', 'd6d0cec480'],
  ['big5', '中文€', 'a4a4a4e5a3e1'],
  ['shiftjis', '日本語', '93fa967b8cea'],
  ['windows1252', '“café”—€', '93636166e9949780'],
  ['iso88591', 'café£', '636166e9a3']
]
for (const [encoding, content, hex] of representable) {
  const encoded = encodeTextBytes(content, encoding)
  assert.equal(encoded.toString('hex'), hex)
  assert.equal(decodeTextBytes(encoded, encoding), content)
}
assert.equal(decodeTextBytes(Buffer.from([0x80]), 'windows1252'), '€')
assert.equal(decodeTextBytes(Buffer.from([0x80]), 'iso88591'), '\u0080')
assert.equal(decodeTextBytes(Buffer.from([0x81]), 'windows1252'), '�')
assert.equal(decodeTextBytes(Buffer.from([0x81]), 'big5'), '�')
assert.equal(decodeTextBytes(Buffer.from([0x82]), 'shiftjis'), '�')

for (const [encoding, content, label] of [
  ['gbk', '😀', 'GBK'],
  ['big5', '😀', 'Big5'],
  ['shiftjis', '😀', 'Shift JIS'],
  ['shiftjis', '¥', 'Shift JIS'], // Would silently round-trip as backslash.
  ['windows1252', '中文', 'Windows-1252'],
  ['iso88591', '€', 'ISO-8859-1']
]) {
  assert.throws(
    () => encodeTextBytes(content, encoding),
    (error) => error instanceof Error && error.message.includes(label) && error.message.includes('without data loss')
  )
}

console.log('main text encoding tests passed')
