import assert from 'node:assert/strict'
import { EditorSelection, EditorState } from '@codemirror/state'
import { maxEditableBytes, isBinaryBuffer } from '../../out-test/shared/filePolicy.js'
import { score, fuzzyFilter } from '../../out-test/renderer/src/fuzzy.js'
import { extractSymbols } from '../../out-test/renderer/src/symbols.js'
import { incrementalChanges, revertIncrementalChange } from '../../out-test/renderer/src/incrementalDiff.js'
import { caseTransformSpec, transformCaseText } from '../../out-test/renderer/src/caseTransforms.js'
import {
  reverseLines,
  removeBlankLines,
  lineTransformEdits,
  planLineTransform,
  sortLinesAscending,
  sortLinesDescending,
  transformLines,
  uniqueLines,
  wouldTransformLines
} from '../../out-test/renderer/src/lineTransforms.js'
import { NavigationHistory, NavigationIntentEpoch, resolveGotoLine } from '../../out-test/renderer/src/navigationHistory.js'
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

assert.equal(transformCaseText('aBc 123!', 'swap'), 'AbC 123!')
assert.equal(transformCaseText('Straße', 'swap'), 'sTRASSE')
assert.equal(transformCaseText('İIıi', 'swap'), 'i̇iII')
assert.equal(transformCaseText('ǅ中🙂', 'swap'), 'ǆ中🙂')
assert.equal(transformCaseText('Straße', 'upper'), 'STRASSE')
assert.equal(transformCaseText('İ', 'lower'), 'i̇')

const applyCaseTransform = (state, kind) => {
  const spec = caseTransformSpec(state, kind)
  return spec ? state.update({ ...spec, userEvent: 'input.case' }).state : state
}
const reverseCaseState = EditorState.create({
  doc: 'xStraße!',
  selection: EditorSelection.range(7, 1),
  extensions: EditorState.allowMultipleSelections.of(true)
})
const reverseCaseResult = applyCaseTransform(reverseCaseState, 'swap')
assert.equal(reverseCaseResult.doc.toString(), 'xsTRASSE!')
assert.deepEqual(reverseCaseResult.selection.main.toJSON(), { anchor: 8, head: 1 })

for (const [source, ranges, expectedText, expectedRanges] of [
  ['1ß', [[0, 1], [1, 2]], '1SS', [[0, 1], [1, 3]]],
  ['ßx', [[0, 1], [1, 2]], 'SSX', [[0, 2], [2, 3]]]
]) {
  const state = EditorState.create({
    doc: source,
    selection: EditorSelection.create(
      ranges.map(([anchor, head]) => EditorSelection.range(anchor, head)),
      1
    ),
    extensions: EditorState.allowMultipleSelections.of(true)
  })
  const result = applyCaseTransform(state, 'swap')
  assert.equal(result.doc.toString(), expectedText)
  assert.deepEqual(result.selection.ranges.map(({ anchor, head }) => [anchor, head]), expectedRanges)
  assert.equal(result.selection.mainIndex, 1)
}

const multiCaseState = EditorState.create({
  doc: 'ab xx CD',
  selection: EditorSelection.create([
    EditorSelection.range(0, 2),
    EditorSelection.cursor(4),
    EditorSelection.range(8, 6)
  ], 2),
  extensions: EditorState.allowMultipleSelections.of(true)
})
const multiCaseResult = applyCaseTransform(multiCaseState, 'swap')
assert.equal(multiCaseResult.doc.toString(), 'AB xx cd')
assert.deepEqual(multiCaseResult.selection.ranges.map(({ anchor, head }) => ({ anchor, head })), [
  { anchor: 0, head: 2 },
  { anchor: 4, head: 4 },
  { anchor: 8, head: 6 }
])
assert.equal(multiCaseResult.selection.mainIndex, 2)

const wholeCaseState = EditorState.create({
  doc: 'aBß',
  selection: EditorSelection.create([EditorSelection.cursor(1), EditorSelection.cursor(2)], 1),
  extensions: EditorState.allowMultipleSelections.of(true)
})
const wholeCaseResult = applyCaseTransform(wholeCaseState, 'swap')
assert.equal(wholeCaseResult.doc.toString(), 'AbSS')
assert.deepEqual(wholeCaseResult.selection.main.toJSON(), { anchor: 0, head: 4 })
assert.equal(caseTransformSpec(EditorState.create({ doc: '123🙂' }), 'swap'), null)

assert.equal(sortLinesAscending('delta\nalpha\ncharlie\nbravo'), 'alpha\nbravo\ncharlie\ndelta')
assert.equal(sortLinesDescending('alpha\ndelta\nbravo\ncharlie'), 'delta\ncharlie\nbravo\nalpha')
assert.equal(transformLines('beta\nalpha', 'sort-ascending'), 'alpha\nbeta')
assert.equal(transformLines('alpha\nbeta', 'sort-descending'), 'beta\nalpha')

// Ordering and de-duplication use exact string values: composed and decomposed
// Unicode remain distinct, and ordering does not depend on the host locale.
const unicodeLines = `é\né\n中\n🙂\né`
assert.equal(sortLinesAscending(unicodeLines), `é\né\né\n中\n🙂`)
assert.equal(sortLinesDescending(unicodeLines), `🙂\n中\né\né\né`)
assert.equal(uniqueLines(`é\né\né\nÉ`), `é\né\nÉ`)

assert.equal(uniqueLines('red\n\nblue\nred\n\nblue\n'), 'red\n\nblue\n')
assert.equal(uniqueLines('\n\n'), '\n')
assert.equal(reverseLines('first\n\nlast\n'), 'last\n\nfirst\n')
assert.equal(transformLines('one\ntwo\nthree', 'reverse'), 'three\ntwo\none')
assert.equal(transformLines('x\ny\nx', 'unique'), 'x\ny')
assert.equal(removeBlankLines('alpha\n\n \n\t\nbeta\n'), 'alpha\nbeta\n')
assert.equal(removeBlankLines('alpha\n \nbeta'), 'alpha\nbeta')
assert.equal(removeBlankLines(' \n\t\n'), '')
assert.equal(removeBlankLines(' \nkeep\n'), ' \nkeep\n')

// A final LF is document structure, not an extra sortable/deduplicated line.
assert.equal(sortLinesAscending('beta\nalpha\n'), 'alpha\nbeta\n')
assert.equal(sortLinesAscending('beta\nalpha'), 'alpha\nbeta')
assert.equal(sortLinesDescending('alpha\nbeta\n'), 'beta\nalpha\n')
assert.equal(sortLinesDescending('alpha\nbeta'), 'beta\nalpha')

for (const mode of ['sort-ascending', 'sort-descending', 'reverse', 'unique', 'remove-blank']) {
  assert.equal(transformLines('', mode), '')
  assert.equal(wouldTransformLines('', mode), false)
  assert.equal(transformLines('only line', mode), 'only line')
  assert.equal(wouldTransformLines('only line', mode), false)
}
assert.equal(wouldTransformLines('alpha\nbeta', 'sort-ascending'), false)
assert.equal(wouldTransformLines('beta\nalpha', 'sort-ascending'), true)
assert.equal(wouldTransformLines('alpha\nbeta', 'unique'), false)
assert.deepEqual(lineTransformEdits('b\na\nkeep\nd\nc\n', [
  { anchor: 0, head: 4 },
  { anchor: 13, head: 9 }
], 'sort-ascending'), [
  { from: 0, to: 4, insert: 'a\nb\n' },
  { from: 9, to: 13, insert: 'c\nd\n' }
])
assert.deepEqual(lineTransformEdits('b\na\nkeep\n', [{ anchor: 0, head: 4 }], 'sort-descending'), [])
assert.deepEqual(lineTransformEdits('b\na\nkeep\n', [{ anchor: 0, head: 3 }], 'sort-ascending'), [
  { from: 0, to: 4, insert: 'a\nb\n' }
])
assert.deepEqual(lineTransformEdits('\nb\na\n', [{ anchor: 0, head: 3 }], 'reverse'), [
  { from: 0, to: 3, insert: 'b\n\n' }
])
assert.deepEqual(lineTransformEdits('b\na', [{ anchor: 0, head: 0 }], 'sort-ascending'), [
  { from: 0, to: 3, insert: 'a\nb' }
])

// CodeMirror maps all selections through the independent edits while keeping
// their direction and main-selection identity. An untouched cursor between
// the two selected blocks must survive as well.
const lineTransformState = EditorState.create({
  doc: 'b\na\nkeep\nd\nc\n',
  selection: EditorSelection.create([
    EditorSelection.range(4, 0),
    EditorSelection.cursor(7),
    EditorSelection.range(13, 9)
  ], 2),
  extensions: [EditorState.allowMultipleSelections.of(true)]
})
const mappedLineTransformPlan = planLineTransform(
  lineTransformState.doc.toString(),
  lineTransformState.selection.ranges,
  'sort-ascending'
)
const mappedLineTransformState = lineTransformState.update({
  changes: mappedLineTransformPlan.changes,
  selection: EditorSelection.create(
    mappedLineTransformPlan.ranges.map(({ anchor, head }) => EditorSelection.range(anchor, head)),
    lineTransformState.selection.mainIndex
  )
}).state
assert.equal(mappedLineTransformState.doc.toString(), 'a\nb\nkeep\nc\nd\n')
assert.equal(mappedLineTransformState.selection.mainIndex, 2)
assert.deepEqual(
  mappedLineTransformState.selection.ranges.map(({ anchor, head }) => ({ anchor, head })),
  [
    { anchor: 4, head: 0 },
    { anchor: 7, head: 7 },
    { anchor: 13, head: 9 }
  ]
)

const interiorSelectionPlan = planLineTransform('bax\nabc\n', [
  { anchor: 1, head: 6 }
], 'sort-ascending')
assert.deepEqual(interiorSelectionPlan.changes, [
  { from: 0, to: 8, insert: 'abc\nbax\n' }
])
assert.deepEqual(interiorSelectionPlan.ranges, [
  { anchor: 0, head: 8 }
])
assert.deepEqual(planLineTransform('bax\nabc\n', [
  { anchor: 6, head: 1 }
], 'sort-ascending').ranges, [
  { anchor: 8, head: 0 }
])

const cursorOnlyPlan = planLineTransform('b\na', [
  { anchor: 1, head: 1 },
  { anchor: 2, head: 2 }
], 'sort-ascending')
assert.deepEqual(cursorOnlyPlan.ranges, [
  { anchor: 3, head: 3 },
  { anchor: 0, head: 0 }
])
const cursorOnlySelection = EditorSelection.create(
  cursorOnlyPlan.ranges.map(({ anchor, head }) => EditorSelection.range(anchor, head)),
  1
)
assert.equal(cursorOnlySelection.ranges.length, 2)
assert.equal(cursorOnlySelection.mainIndex, 0)
assert.equal(cursorOnlySelection.main.head, 0)

const mixedSelectionPlan = planLineTransform('bax\nabc\n', [
  { anchor: 0, head: 0 },
  { anchor: 1, head: 5 }
], 'sort-ascending')
assert.deepEqual(mixedSelectionPlan.ranges, [
  { anchor: 4, head: 4 },
  { anchor: 0, head: 8 }
])

const uniqueSelectionPlan = planLineTransform('keep\ndup\ndup\ntail\n', [
  { anchor: 6, head: 6 },
  { anchor: 10, head: 10 },
  { anchor: 14, head: 14 },
  { anchor: 18, head: 18 }
], 'unique')
assert.equal(uniqueSelectionPlan.changes[0].insert, 'keep\ndup\ntail\n')
assert.deepEqual(uniqueSelectionPlan.ranges, [
  { anchor: 6, head: 6 },
  { anchor: 6, head: 6 },
  { anchor: 10, head: 10 },
  { anchor: 14, head: 14 }
])
const normalizedUniqueSelection = EditorSelection.create(
  uniqueSelectionPlan.ranges.map(({ head }) => EditorSelection.cursor(head)),
  1
)
assert.deepEqual(normalizedUniqueSelection.ranges.map(({ head }) => head), [6, 10, 14])
assert.equal(normalizedUniqueSelection.main.head, 6)
assert.deepEqual(planLineTransform('b\na', [{ anchor: 3, head: 3 }], 'sort-ascending').ranges, [
  { anchor: 1, head: 1 }
])
assert.deepEqual(planLineTransform('b\na\n', [{ anchor: 4, head: 4 }], 'sort-ascending').ranges, [
  { anchor: 4, head: 4 }
])

const disjointUniquePlan = planLineTransform('b\nb\nkeep\nd\nd\n', [
  { anchor: 1, head: 4 },
  { anchor: 7, head: 7 },
  { anchor: 12, head: 9 }
], 'unique')
assert.deepEqual(disjointUniquePlan.changes, [
  { from: 0, to: 4, insert: 'b\n' },
  { from: 9, to: 13, insert: 'd\n' }
])
assert.deepEqual(disjointUniquePlan.ranges, [
  { anchor: 0, head: 2 },
  { anchor: 5, head: 5 },
  { anchor: 9, head: 7 }
])

const noOpLineTransformPlan = planLineTransform('a\nb\n', [{ anchor: 1, head: 3 }], 'sort-ascending')
assert.deepEqual(noOpLineTransformPlan.changes, [])
assert.deepEqual(noOpLineTransformPlan.ranges, [{ anchor: 1, head: 3 }])

const mixedNoOpAndChangedPlan = planLineTransform('a\nb\nkeep\nd\nc\n', [
  { anchor: 1, head: 3 },
  { anchor: 12, head: 10 }
], 'sort-ascending')
assert.deepEqual(mixedNoOpAndChangedPlan.changes, [
  { from: 9, to: 13, insert: 'c\nd\n' }
])
assert.deepEqual(mixedNoOpAndChangedPlan.ranges, [
  { anchor: 0, head: 4 },
  { anchor: 13, head: 9 }
])

const removeBlankSelectionPlan = planLineTransform('a\n \nkeep\nb\n\t\nend\n', [
  { anchor: 2, head: 3 },
  { anchor: 6, head: 6 },
  { anchor: 12, head: 11 }
], 'remove-blank')
assert.deepEqual(removeBlankSelectionPlan.changes, [
  { from: 2, to: 4, insert: '' },
  { from: 11, to: 13, insert: '' }
])
assert.deepEqual(removeBlankSelectionPlan.ranges, [
  { anchor: 2, head: 2 },
  { anchor: 4, head: 4 },
  { anchor: 9, head: 9 }
])

const removeBlankCursorPlan = planLineTransform('a\n \nb', [
  { anchor: 2, head: 2 },
  { anchor: 4, head: 4 }
], 'remove-blank')
assert.deepEqual(removeBlankCursorPlan.changes, [{ from: 2, to: 4, insert: '' }])
assert.deepEqual(removeBlankCursorPlan.ranges, [
  { anchor: 2, head: 2 },
  { anchor: 2, head: 2 }
])
assert.deepEqual(planLineTransform('a\n ', [{ anchor: 2, head: 3 }], 'remove-blank'), {
  changes: [{ from: 1, to: 3, insert: '' }],
  ranges: [{ anchor: 1, head: 1 }]
})
assert.deepEqual(planLineTransform('a\n ', [{ anchor: 3, head: 2 }], 'remove-blank'), {
  changes: [{ from: 1, to: 3, insert: '' }],
  ranges: [{ anchor: 1, head: 1 }]
})
assert.deepEqual(planLineTransform('a\n \n ', [
  { anchor: 2, head: 3 },
  { anchor: 4, head: 5 }
], 'remove-blank').changes, [{ from: 1, to: 5, insert: '' }])

const navigationLocation = (docId, path, line = 1, column = 1, groupId = 0) => ({ docId, path, groupId, line, column })
const navA = navigationLocation('doc-a', '/workspace/a.ts', 1, 1)
const navB = navigationLocation('doc-b', '/workspace/b.ts', 2, 3)
const navC = navigationLocation('doc-c', '/workspace/c.ts', 4, 5)
const navD = navigationLocation('doc-d', '/workspace/d.ts', 6, 7)

// A -> B -> C can be traversed all the way back and forward without losing
// either destination while it is merely being prepared.
const roundTripNavigation = new NavigationHistory()
roundTripNavigation.recordSuccessfulJump(navA, navB)
roundTripNavigation.recordSuccessfulJump(navB, navC)
assert.deepEqual(roundTripNavigation.backEntries, [navA, navB])
let navigationTraversal = roundTripNavigation.prepareTraversal('back')
assert.deepEqual(navigationTraversal?.target, navB)
assert.equal(roundTripNavigation.commitTraversal(navigationTraversal, navC), true)
navigationTraversal = roundTripNavigation.prepareTraversal('back')
assert.deepEqual(navigationTraversal?.target, navA)
assert.equal(roundTripNavigation.commitTraversal(navigationTraversal, navB), true)
assert.equal(roundTripNavigation.canGoBack, false)
assert.deepEqual(roundTripNavigation.forwardEntries, [navC, navB])
navigationTraversal = roundTripNavigation.prepareTraversal('forward')
assert.deepEqual(navigationTraversal?.target, navB)
assert.equal(roundTripNavigation.commitTraversal(navigationTraversal, navA), true)
navigationTraversal = roundTripNavigation.prepareTraversal('forward')
assert.deepEqual(navigationTraversal?.target, navC)
assert.equal(roundTripNavigation.commitTraversal(navigationTraversal, navB), true)
assert.deepEqual(roundTripNavigation.backEntries, [navA, navB])
assert.equal(roundTripNavigation.canGoForward, false)

// A new successful branch from B records B and clears the old forward C.
const branchedNavigation = new NavigationHistory()
branchedNavigation.recordSuccessfulJump(navA, navB)
branchedNavigation.recordSuccessfulJump(navB, navC)
navigationTraversal = branchedNavigation.prepareTraversal('back')
assert.ok(navigationTraversal)
assert.equal(branchedNavigation.commitTraversal(navigationTraversal, navC), true)
assert.deepEqual(branchedNavigation.forwardEntries, [navC])
branchedNavigation.recordSuccessfulJump(navB, navD)
assert.deepEqual(branchedNavigation.backEntries, [navA, navB])
assert.deepEqual(branchedNavigation.forwardEntries, [])

// No-op destinations and duplicate consecutive sources do not add entries.
const deduplicatedNavigation = new NavigationHistory()
deduplicatedNavigation.recordSuccessfulJump(navA, navA)
assert.deepEqual(deduplicatedNavigation.backEntries, [])
deduplicatedNavigation.recordSuccessfulJump(navA, { ...navA, path: '/workspace/a-renamed.ts' })
assert.deepEqual(deduplicatedNavigation.backEntries, [])
deduplicatedNavigation.recordSuccessfulJump(navA, { ...navA, groupId: 2 })
assert.deepEqual(deduplicatedNavigation.backEntries, [navA])
deduplicatedNavigation.recordSuccessfulJump(navA, navB)
deduplicatedNavigation.recordSuccessfulJump(navA, navC)
assert.deepEqual(deduplicatedNavigation.backEntries, [navA])

// The default bound is exactly 100, retaining the most recent locations.
const cappedNavigation = new NavigationHistory()
for (let index = 0; index <= 100; index += 1) {
  cappedNavigation.recordSuccessfulJump(
    navigationLocation(`cap-${index}`, `/workspace/${index}.ts`),
    navigationLocation(`cap-${index + 1}`, `/workspace/${index + 1}.ts`)
  )
}
assert.equal(cappedNavigation.backEntries.length, 100)
assert.equal(cappedNavigation.backEntries[0].docId, 'cap-1')
assert.equal(cappedNavigation.backEntries[99].docId, 'cap-100')

// A failed resolution/jump simply abandons the prepared transaction. Both
// stacks remain byte-for-byte equivalent, and the target is available again.
const failedNavigation = new NavigationHistory()
failedNavigation.recordSuccessfulJump(navA, navB)
failedNavigation.recordSuccessfulJump(navB, navC)
navigationTraversal = failedNavigation.prepareTraversal('back')
assert.ok(navigationTraversal)
assert.equal(failedNavigation.commitTraversal(navigationTraversal, navC), true)
const backBeforeFailure = failedNavigation.backEntries
const forwardBeforeFailure = failedNavigation.forwardEntries
const failedTraversal = failedNavigation.prepareTraversal('back')
assert.deepEqual(failedTraversal?.target, navA)
assert.deepEqual(failedNavigation.backEntries, backBeforeFailure)
assert.deepEqual(failedNavigation.forwardEntries, forwardBeforeFailure)
assert.deepEqual(failedNavigation.prepareTraversal('back')?.target, navA)
const staleTraversal = failedNavigation.prepareTraversal('forward')
assert.ok(staleTraversal)
failedNavigation.recordSuccessfulJump(navB, navD)
assert.equal(failedNavigation.commitTraversal(staleTraversal, navB), false)
assert.equal(failedNavigation.commitTraversal({ direction: 'back', target: navA }, navB), false)
// A second traversal prepared before the first commits becomes stale instead
// of popping the same target twice or losing the reverse location. The App
// additionally serialises user Back/Forward input so each request is replayed.
const concurrentNavigation = new NavigationHistory()
concurrentNavigation.recordSuccessfulJump(navA, navB)
concurrentNavigation.recordSuccessfulJump(navB, navC)
const firstConcurrentBack = concurrentNavigation.prepareTraversal('back')
const secondConcurrentBack = concurrentNavigation.prepareTraversal('back')
assert.ok(firstConcurrentBack && secondConcurrentBack)
assert.equal(concurrentNavigation.commitTraversal(firstConcurrentBack, navC), true)
assert.equal(concurrentNavigation.commitTraversal(secondConcurrentBack, navB), false)
assert.deepEqual(concurrentNavigation.backEntries, [navA])
assert.deepEqual(concurrentNavigation.forwardEntries, [navC])

// Untitled buffers are navigable by stable document id without a disk path.
const untitledA = navigationLocation('untitled-a', null, 3, 2)
const untitledB = navigationLocation('untitled-b', null, 8, 4)
const untitledNavigation = new NavigationHistory()
untitledNavigation.recordSuccessfulJump(untitledA, untitledB)
navigationTraversal = untitledNavigation.prepareTraversal('back')
assert.deepEqual(navigationTraversal?.target, untitledA)
assert.equal(untitledNavigation.commitTraversal(navigationTraversal, untitledB), true)
assert.deepEqual(untitledNavigation.prepareTraversal('forward')?.target, untitledB)

const lifecycleNavigation = new NavigationHistory()
lifecycleNavigation.recordSuccessfulJump(
  navigationLocation('renamed', '/workspace/src/old.ts'),
  navigationLocation('untitled', null, 2, 1, 1)
)
lifecycleNavigation.recordSuccessfulJump(
  navigationLocation('untitled', null, 2, 1, 1),
  navigationLocation('saved-target', '/workspace/target.ts')
)
lifecycleNavigation.updateDocumentPath('untitled', '/workspace/saved.ts')
lifecycleNavigation.rewritePathPrefix('/workspace/src', '/workspace/lib')
assert.deepEqual(lifecycleNavigation.backEntries, [
  navigationLocation('renamed', '/workspace/lib/old.ts'),
  navigationLocation('untitled', '/workspace/saved.ts', 2, 1, 1)
])
assert.deepEqual(lifecycleNavigation.prepareTraversal('back')?.target.path, '/workspace/saved.ts')
lifecycleNavigation.removePathPrefix('/workspace/lib')
assert.deepEqual(lifecycleNavigation.backEntries, [navigationLocation('untitled', '/workspace/saved.ts', 2, 1, 1)])
lifecycleNavigation.removeDocument('untitled')
assert.equal(lifecycleNavigation.canGoBack, false)
const boundaryNavigation = new NavigationHistory()
boundaryNavigation.recordSuccessfulJump(
  navigationLocation('boundary', '/workspace/src-copy/file.ts'),
  navigationLocation('elsewhere', '/workspace/elsewhere.ts')
)
boundaryNavigation.rewritePathPrefix('/workspace/src', '/workspace/lib')
assert.equal(boundaryNavigation.backEntries[0].path, '/workspace/src-copy/file.ts')

assert.deepEqual(resolveGotoLine('42:8', 10, 100), { line: 42, column: 8 })
assert.deepEqual(resolveGotoLine('+10', 20, 100), { line: 30, column: 1 })
assert.deepEqual(resolveGotoLine('-50', 20, 100), { line: 1, column: 1 })
assert.deepEqual(resolveGotoLine('50%', 20, 101), { line: 51, column: 1 })
assert.deepEqual(resolveGotoLine('+10%', 20, 100), { line: 30, column: 1 })
assert.deepEqual(resolveGotoLine('999', 20, 100), { line: 100, column: 1 })
assert.equal(resolveGotoLine('12:0', 20, 100), null)
assert.equal(resolveGotoLine('not-a-line', 20, 100), null)
const navigationIntent = new NavigationIntentEpoch()
const queuedHistoryBatch = navigationIntent.current
assert.equal(navigationIntent.isCurrent(queuedHistoryBatch), true)
assert.equal(navigationIntent.isCurrent(queuedHistoryBatch), true)
navigationIntent.begin()
assert.equal(navigationIntent.isCurrent(queuedHistoryBatch), false)

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
