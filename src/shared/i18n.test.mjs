import assert from 'node:assert/strict'
import { commandLabel, commandTitle, translate, workspaceOperationErrorMessage } from '../../out-test/shared/i18n.js'
import {
  MAX_WORKSPACE_IPC_STRING_LENGTH,
  MAX_WORKSPACE_MATCH_STRING_LENGTH,
  MAX_WORKSPACE_MATCH_TOTAL_STRING_LENGTH,
  MAX_WORKSPACE_MATCHES,
  MAX_WORKSPACE_UNDO_TOKEN_LENGTH,
  compileWorkspaceSearchRegExp,
  isWorkspaceMatch,
  isWorkspaceMatchArray,
  isWorkspaceOperationError,
  isWorkspaceReplaceApplyResultPayload,
  isWorkspaceReplacePreview,
  isWorkspaceReplacePreviewPayload,
  isWorkspaceReplaceResult,
  isWorkspaceReplaceUndoResultPayload,
  isWorkspaceSearchResultPayload,
  normalizeWorkspaceOperationResult,
  truncateWorkspaceIpcString,
  verbatimWorkspaceOperationError,
  workspaceSearchResultLimit
} from '../../out-test/shared/ipc.js'
import { COMMANDS } from '../../out-test/renderer/src/commands.js'

assert.equal(translate('zh-CN', 'openFile'), '打开文件…')
assert.equal(translate('en-US', 'openFile'), 'Open File…')
assert.equal(translate('zh-CN', 'encodingActionPickerPlaceholder'), '选择编码操作…')
assert.equal(translate('en-US', 'encodingActionPickerPlaceholder'), 'Choose an encoding action…')
assert.equal(commandLabel('zh-CN', 'convert-indent-spaces', 'Convert Indentation to Spaces'), '将缩进转换为空格')
assert.equal(commandLabel('zh-CN', 'convert-indent-tabs', 'Convert Indentation to Tabs'), '将缩进转换为制表符')
assert.equal(commandTitle('zh-CN', 'save-as', 'File: Save As…'), '文件：另存为…')
assert.equal(commandTitle('en-US', 'save-as', 'File: Save As…'), 'File: Save As…')
assert.equal(
  workspaceOperationErrorMessage('zh-CN', { kind: 'app', code: 'invalid-regex' }),
  '搜索正则表达式无效。'
)
assert.equal(
  workspaceOperationErrorMessage('en-US', { kind: 'app', code: 'invalid-regex' }),
  'The search regular expression is invalid.'
)
assert.equal(
  workspaceOperationErrorMessage('zh-CN', {
    kind: 'app', code: 'too-many-roots', params: { maximum: 12 }
  }),
  '工作区搜索最多支持 12 个根目录。'
)
assert.equal(
  workspaceOperationErrorMessage('zh-CN', {
    kind: 'app', code: 'undo-file-changed', params: { path: '/tmp/原文.txt' }
  }),
  '无法撤销 /tmp/原文.txt 中的替换，因为该文件之后已更改。'
)
const externalWorkspaceFailure = 'External regex engine: DO NOT TRANSLATE\n原始详情 Ω /tmp/private'
const externalPayload = verbatimWorkspaceOperationError(
  new Error(externalWorkspaceFailure)
)
assert.deepEqual(externalPayload, {
  kind: 'verbatim', message: externalWorkspaceFailure
})
assert.equal(
  workspaceOperationErrorMessage('zh-CN', externalPayload),
  externalWorkspaceFailure
)
assert.equal(
  workspaceOperationErrorMessage('en-US', externalPayload),
  externalWorkspaceFailure
)
assert.deepEqual(compileWorkspaceSearchRegExp({
  root: '/workspace',
  query: '[',
  caseSensitive: false,
  wholeWord: false,
  useRegex: true
}), { ok: false, error: { kind: 'app', code: 'invalid-regex' } })
assert.equal(isWorkspaceOperationError({ kind: 'app', code: 'invalid-regex' }), true)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'too-many-roots', params: { maximum: 12 }
}), true)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'too-many-roots', params: { maximum: '12' }
}), false)
assert.equal(isWorkspaceOperationError({ kind: 'verbatim', message: externalWorkspaceFailure }), true)
assert.equal(workspaceSearchResultLimit(undefined), MAX_WORKSPACE_MATCHES)
assert.equal(workspaceSearchResultLimit(Number.NaN), MAX_WORKSPACE_MATCHES)
assert.equal(workspaceSearchResultLimit(Number.POSITIVE_INFINITY), MAX_WORKSPACE_MATCHES)
assert.equal(workspaceSearchResultLimit(Number.MAX_SAFE_INTEGER + 1), MAX_WORKSPACE_MATCHES)
assert.equal(workspaceSearchResultLimit(0), 1)
assert.equal(workspaceSearchResultLimit(-100), 1)
assert.equal(workspaceSearchResultLimit(17), 17)
assert.equal(workspaceSearchResultLimit(MAX_WORKSPACE_MATCHES + 1), MAX_WORKSPACE_MATCHES)

const validWorkspaceMatch = {
  path: '/workspace/原文.txt',
  line: 3,
  column: 5,
  lineText: 'const answer = Ω',
  matchText: 'answer'
}
assert.equal(isWorkspaceMatch(validWorkspaceMatch), true)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, line: 0 }), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, column: 1.5 }), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, line: Number.POSITIVE_INFINITY }), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, column: Number.MAX_SAFE_INTEGER + 1 }), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, path: '' }), false)
assert.equal(isWorkspaceMatch({
  ...validWorkspaceMatch, path: 'p'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH + 1)
}), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, lineText: 42 }), false)
assert.equal(isWorkspaceMatch({ ...validWorkspaceMatch, unexpected: 'do not forward' }), false)
assert.equal(isWorkspaceMatch({
  ...validWorkspaceMatch,
  path: 'p'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH),
  lineText: 'l'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH),
  matchText: 'm'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH)
}), true)
assert.equal(isWorkspaceMatch({
  ...validWorkspaceMatch,
  lineText: 'x'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH + 1)
}), false)
assert.equal(isWorkspaceMatch({
  ...validWorkspaceMatch,
  matchText: 'x'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH + 1)
}), false)
assert.equal(isWorkspaceMatch(Object.assign(Object.create({ inherited: true }), validWorkspaceMatch)), false)

const accessorMatch = { ...validWorkspaceMatch }
Object.defineProperty(accessorMatch, 'lineText', {
  enumerable: true,
  get() { throw new Error('workspace validator invoked an accessor') }
})
assert.doesNotThrow(() => isWorkspaceMatch(accessorMatch))
assert.equal(isWorkspaceMatch(accessorMatch), false)
assert.equal(isWorkspaceMatch(new Proxy({}, { ownKeys() { throw new Error('hostile proxy') } })), false)

assert.equal(isWorkspaceMatchArray([validWorkspaceMatch]), true)
assert.equal(isWorkspaceMatchArray(new Array(1)), false)
const arrayWithExtraData = [validWorkspaceMatch]
arrayWithExtraData.payload = 'x'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH + 1)
assert.equal(isWorkspaceMatchArray(arrayWithExtraData), false)
assert.equal(
  isWorkspaceMatchArray(Array(MAX_WORKSPACE_MATCHES + 1).fill(validWorkspaceMatch)),
  false
)
assert.equal(isWorkspaceMatchArray(Array(MAX_WORKSPACE_MATCHES).fill(validWorkspaceMatch)), true)
const aggregateBudgetMatch = {
  ...validWorkspaceMatch,
  path: 'p'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH),
  lineText: 'l'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH),
  matchText: 'm'.repeat(MAX_WORKSPACE_MATCH_STRING_LENGTH)
}
const aggregateBudgetCount = Math.floor(
  MAX_WORKSPACE_MATCH_TOTAL_STRING_LENGTH
    / (MAX_WORKSPACE_MATCH_STRING_LENGTH * 3)
)
assert.equal(
  isWorkspaceMatchArray(Array(aggregateBudgetCount).fill(aggregateBudgetMatch)),
  true
)
assert.equal(
  isWorkspaceMatchArray(Array(aggregateBudgetCount + 1).fill(aggregateBudgetMatch)),
  false
)
assert.deepEqual(
  normalizeWorkspaceOperationResult(null, isWorkspaceSearchResultPayload),
  { ok: false, error: { kind: 'app', code: 'invalid-response' } }
)
assert.deepEqual(
  normalizeWorkspaceOperationResult('malicious', isWorkspaceSearchResultPayload),
  { ok: false, error: { kind: 'app', code: 'invalid-response' } }
)

const validReplaceResult = { files: 2, replacements: 7, undoToken: 'undo-123' }
assert.equal(isWorkspaceReplaceResult(validReplaceResult), true)
assert.equal(isWorkspaceReplaceResult({ files: 0, replacements: 0 }), true)
assert.equal(isWorkspaceReplaceResult({ ...validReplaceResult, files: -1 }), false)
assert.equal(isWorkspaceReplaceResult({ ...validReplaceResult, replacements: Number.NaN }), false)
assert.equal(isWorkspaceReplaceResult({ ...validReplaceResult, replacements: 1.25 }), false)
assert.equal(isWorkspaceReplaceResult({ ...validReplaceResult, undoToken: '' }), false)
assert.equal(isWorkspaceReplaceResult({
  ...validReplaceResult, undoToken: 'u'.repeat(MAX_WORKSPACE_UNDO_TOKEN_LENGTH)
}), true)
assert.equal(isWorkspaceReplaceResult({
  ...validReplaceResult, undoToken: 'u'.repeat(MAX_WORKSPACE_UNDO_TOKEN_LENGTH + 1)
}), false)
assert.equal(isWorkspaceReplaceResult({ ...validReplaceResult, extra: true }), false)

const validReplacePreview = { files: 1, replacements: 1, matches: [validWorkspaceMatch] }
assert.equal(isWorkspaceReplacePreview(validReplacePreview), true)
assert.equal(isWorkspaceReplacePreview({ ...validReplacePreview, files: '1' }), false)
assert.equal(isWorkspaceReplacePreview({ ...validReplacePreview, matches: [{}] }), false)
assert.equal(isWorkspaceReplacePreview({ ...validReplacePreview, extra: 'not allowed' }), false)
assert.equal(isWorkspaceSearchResultPayload([validWorkspaceMatch]), true)
assert.equal(isWorkspaceReplaceApplyResultPayload(validReplaceResult), true)
assert.equal(isWorkspaceReplaceApplyResultPayload({ files: 2, replacements: 1 }), false)
assert.equal(isWorkspaceReplacePreviewPayload(validReplacePreview), true)
assert.equal(isWorkspaceReplacePreviewPayload({ ...validReplacePreview, replacements: 2 }), false)
assert.equal(isWorkspaceReplacePreviewPayload({ ...validReplacePreview, files: 0 }), false)
assert.equal(isWorkspaceReplaceUndoResultPayload({ files: 1, replacements: 0 }), true)
assert.equal(isWorkspaceReplaceUndoResultPayload(validReplaceResult), false)
assert.equal(isWorkspaceReplaceUndoResultPayload({ files: 1, replacements: 1 }), false)

for (const validError of [
  { kind: 'app', code: 'missing-query' },
  { kind: 'app', code: 'invalid-regex' },
  { kind: 'app', code: 'undo-expired' },
  { kind: 'app', code: 'invalid-response' },
  { kind: 'app', code: 'too-many-roots', params: { maximum: 12 } },
  { kind: 'app', code: 'undo-file-changed', params: { path: '/tmp/原文.txt' } },
  { kind: 'verbatim', message: '外部错误 Ω' }
]) assert.equal(isWorkspaceOperationError(validError), true)

assert.equal(isWorkspaceOperationError({
  kind: 'verbatim', message: 'x'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH + 1)
}), false)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'undo-file-changed',
  params: { path: 'x'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH + 1) }
}), false)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'undo-file-changed', params: { path: '/tmp/a', hidden: 'large' }
}), false)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'invalid-regex', extra: 'not allowed'
}), false)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'too-many-roots', params: { maximum: 0 }
}), false)
assert.equal(isWorkspaceOperationError({
  kind: 'app', code: 'too-many-roots', params: { maximum: Number.POSITIVE_INFINITY }
}), false)

const exactUnicodeBoundary = `${'a'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH - 2)}😀`
assert.equal(exactUnicodeBoundary.length, MAX_WORKSPACE_IPC_STRING_LENGTH)
assert.equal(truncateWorkspaceIpcString(exactUnicodeBoundary), exactUnicodeBoundary)
assert.equal(verbatimWorkspaceOperationError(new Error(exactUnicodeBoundary)).message, exactUnicodeBoundary)
const splitUnicodeBoundary = `${'a'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH - 1)}😀tail`
assert.equal(
  truncateWorkspaceIpcString(splitUnicodeBoundary),
  'a'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH - 1)
)
assert.equal(truncateWorkspaceIpcString('ab😀tail', 4), 'ab😀')
assert.equal(truncateWorkspaceIpcString('abc😀tail', 4), 'abc')
assert.equal(truncateWorkspaceIpcString('😀', 1), '')
assert.equal(truncateWorkspaceIpcString('abc', 0), '')
const truncatedUnicodeError = verbatimWorkspaceOperationError(new Error(splitUnicodeBoundary))
assert.equal(truncatedUnicodeError.message, 'a'.repeat(MAX_WORKSPACE_IPC_STRING_LENGTH - 1))
assert.equal(truncatedUnicodeError.message.length <= MAX_WORKSPACE_IPC_STRING_LENGTH, true)
assert.equal(/[\uD800-\uDBFF]$/.test(truncatedUnicodeError.message), false)

for (const [payload, validator] of [
  [[validWorkspaceMatch], isWorkspaceSearchResultPayload],
  [validReplaceResult, isWorkspaceReplaceApplyResultPayload],
  [validReplacePreview, isWorkspaceReplacePreviewPayload],
  [{ files: 1, replacements: 0 }, isWorkspaceReplaceUndoResultPayload]
]) {
  assert.deepEqual(
    normalizeWorkspaceOperationResult(payload, validator),
    { ok: true, value: payload }
  )
  assert.deepEqual(
    normalizeWorkspaceOperationResult({ ok: true, value: payload }, validator),
    { ok: true, value: payload }
  )
}
const typedWorkspaceFailure = {
  ok: false, error: { kind: 'app', code: 'undo-file-changed', params: { path: '/tmp/a' } }
}
assert.deepEqual(
  normalizeWorkspaceOperationResult(typedWorkspaceFailure, isWorkspaceReplaceResult),
  typedWorkspaceFailure
)
const invalidWorkspaceResponse = { ok: false, error: { kind: 'verbatim', message: 42 } }
const expectedInvalidWorkspaceResponse = {
  ok: false, error: { kind: 'app', code: 'invalid-response' }
}
assert.deepEqual(
  normalizeWorkspaceOperationResult(invalidWorkspaceResponse, isWorkspaceReplaceResult),
  expectedInvalidWorkspaceResponse
)
assert.deepEqual(
  normalizeWorkspaceOperationResult(
    { ok: true, value: validReplaceResult, extra: 'not allowed' },
    isWorkspaceReplaceResult
  ),
  expectedInvalidWorkspaceResponse
)
assert.deepEqual(
  normalizeWorkspaceOperationResult(
    { ...validReplaceResult, ok: 'pretend this is bare success' },
    isWorkspaceReplaceResult
  ),
  expectedInvalidWorkspaceResponse
)
for (const command of COMMANDS) {
  assert.notEqual(
    commandLabel('zh-CN', command.id, '__missing_translation__'),
    '__missing_translation__',
    `missing Simplified Chinese command label for ${command.id}`
  )
}

console.log('i18n tests passed')
