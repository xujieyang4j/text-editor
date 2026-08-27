import { EditorSelection, type EditorState, type StateCommand, type Transaction } from '@codemirror/state'
import { redoSelection, undoSelection } from '@codemirror/commands'
import { selectNextOccurrence } from '@codemirror/search'

function capture(command: StateCommand, state: EditorState): Transaction | null {
  let transaction: Transaction | null = null
  command({ state, dispatch: (next) => { transaction = next } })
  return transaction
}

/**
 * CodeMirror's selection-history commands may fall through to a text change.
 * Keep Lumen's explicit Selection commands selection-only by inspecting the
 * candidate transaction before it is dispatched.
 */
function selectionOnly(command: StateCommand): StateCommand {
  return ({ state, dispatch }) => {
    const transaction = capture(command, state)
    if (!transaction || !transaction.changes.empty) return false
    dispatch(transaction)
    return true
  }
}

export const undoSelectionOnly = selectionOnly(undoSelection)
export const redoSelectionOnly = selectionOnly(redoSelection)

/**
 * Add the next occurrence and make the newly added range the active range.
 * CodeMirror intentionally keeps the original range active, but Lumen needs
 * to identify the latest range for Skip Current Occurrence and Remove Last
 * Cursor, including after the search wraps around the end of the document.
 */
export const selectNextOccurrenceAsMain: StateCommand = ({ state, dispatch }) => {
  const transaction = capture(selectNextOccurrence, state)
  if (!transaction) return false

  const next = transaction.state.selection
  if (next.ranges.length === state.selection.ranges.length + 1) {
    const addedIndex = next.ranges.findIndex((range) =>
      !state.selection.ranges.some((previous) => previous.eq(range))
    )
    if (addedIndex >= 0) {
      dispatch(state.update({
        selection: EditorSelection.create(next.ranges, addedIndex),
        scrollIntoView: true,
        userEvent: 'select.next-occurrence'
      }))
      return true
    }
  }

  dispatch(transaction)
  return true
}

/** Return a selection with the active occurrence replaced by the next match. */
export function skipCurrentOccurrenceSelection(state: EditorState): EditorSelection | null {
  const { ranges, mainIndex } = state.selection
  if (ranges.some((range) => range.empty)) return null

  const current = ranges[mainIndex]
  const selected = state.sliceDoc(current.from, current.to)
  if (!selected || ranges.some((range) => state.sliceDoc(range.from, range.to) !== selected)) return null

  const mainWord = state.wordAt(current.from)
  const wholeWord = mainWord?.from === current.from && mainWord.to === current.to
  const text = state.doc.toString()
  const isSelected = (from: number, to: number): boolean =>
    ranges.some((range, index) => index !== mainIndex && from < range.to && to > range.from)
  const isWholeWord = (from: number, to: number): boolean => {
    if (!wholeWord) return true
    const word = state.wordAt(from)
    return word?.from === from && word.to === to
  }
  const findMatch = (from: number, to: number): number => {
    let found = text.indexOf(selected, from)
    while (found >= 0 && found + selected.length <= to) {
      const end = found + selected.length
      if (!isSelected(found, end) && isWholeWord(found, end)) return found
      found = text.indexOf(selected, found + Math.max(1, selected.length))
    }
    return -1
  }

  let found = findMatch(current.to, text.length)
  if (found < 0) found = findMatch(0, current.from)
  if (found < 0) return null
  return state.selection.replaceRange(EditorSelection.range(found, found + selected.length), mainIndex)
}

/** Remove the active range and activate its cyclic predecessor. */
export function removeMainSelection(selection: EditorSelection): EditorSelection | null {
  if (selection.ranges.length <= 1) return null
  const ranges = selection.ranges.filter((_range, index) => index !== selection.mainIndex)
  const mainIndex = selection.mainIndex === 0 ? ranges.length - 1 : selection.mainIndex - 1
  return EditorSelection.create(ranges, mainIndex)
}
