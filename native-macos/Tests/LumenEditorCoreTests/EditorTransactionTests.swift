import XCTest
@testable import LumenEditorCore

final class EditorTransactionTests: XCTestCase {
    func testSelectionSetNormalizesRangesWithoutLosingDirectionOrMainRange() {
        let selection = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 8, head: 6),
                DirectedSelection(anchor: 1, head: 3),
                DirectedSelection(anchor: 2, head: 4),
                DirectedSelection(anchor: 4, head: 5)
            ],
            mainIndex: 1
        )

        XCTAssertEqual(selection.ranges, [
            DirectedSelection(anchor: 1, head: 4),
            DirectedSelection(anchor: 4, head: 5),
            DirectedSelection(anchor: 8, head: 6)
        ])
        XCTAssertEqual(selection.mainIndex, 0)
        XCTAssertEqual(selection.main, DirectedSelection(anchor: 1, head: 4))
        XCTAssertTrue(selection.ranges[2].isBackward)
    }

    func testSelectionSetMergesCollidingCursorsAndTracksMainIdentity() {
        let selection = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 6, head: 6),
                DirectedSelection(anchor: 2, head: 2),
                DirectedSelection(anchor: 6, head: 6)
            ],
            mainIndex: 2
        )

        XCTAssertEqual(selection.ranges, [
            DirectedSelection(anchor: 2, head: 2),
            DirectedSelection(anchor: 6, head: 6)
        ])
        XCTAssertEqual(selection.mainIndex, 1)
    }

    func testTransactionUsesUTF16OffsetsAndAppliesOriginalEditsBackwards() throws {
        let transaction = try TextTransaction(edits: [
            TextEdit(from: 4, to: 4, insert: "!"),
            TextEdit(from: 1, to: 3, insert: "é")
        ])

        XCTAssertEqual(try transaction.applying(to: "A🙂B"), "AéB!")
        XCTAssertEqual(transaction.edits.map(\.from), [1, 4])
    }

    func testSamePointInsertionsHaveStableOrder() throws {
        let transaction = try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X"),
            TextEdit(from: 1, to: 1, insert: "Y")
        ])

        XCTAssertEqual(try transaction.applying(to: "ab"), "aXYb")
        XCTAssertEqual(transaction.mapPosition(1, association: .before), 1)
        XCTAssertEqual(transaction.mapPosition(1, association: .after), 3)
    }

    func testRejectsOverlappingInvalidAndOutOfBoundsEdits() throws {
        let first = TextEdit(from: 1, to: 4, insert: "x")
        let second = TextEdit(from: 3, to: 5, insert: "y")
        XCTAssertThrowsError(try TextTransaction(edits: [first, second])) { error in
            XCTAssertEqual(
                error as? EditorTransactionError,
                .overlappingEdits(first, second)
            )
        }

        let interiorInsertion = TextEdit(from: 2, to: 2, insert: "!")
        XCTAssertThrowsError(try TextTransaction(edits: [first, interiorInsertion]))
        XCTAssertNoThrow(try TextTransaction(edits: [
            first,
            TextEdit(from: 2, to: 2, insert: "")
        ]))
        XCTAssertThrowsError(
            try TextTransaction(edits: [TextEdit(from: -1, to: 0, insert: "")])
        )

        let outOfBounds = TextEdit(from: 1, to: 4, insert: "")
        let transaction = try TextTransaction(edits: [outOfBounds])
        XCTAssertThrowsError(try transaction.applying(to: "abc")) { error in
            XCTAssertEqual(
                error as? EditorTransactionError,
                .editOutOfBounds(outOfBounds, documentUTF16Length: 3)
            )
        }
    }

    func testMapPositionMakesInsertionAndReplacementAssociationExplicit() throws {
        let insertion = try TextTransaction(edits: [
            TextEdit(from: 2, to: 2, insert: "🙂")
        ])
        XCTAssertEqual(insertion.mapPosition(2, association: .before), 2)
        XCTAssertEqual(insertion.mapPosition(2, association: .after), 4)
        XCTAssertEqual(insertion.mapPosition(3, association: .before), 5)

        let replacement = try TextTransaction(edits: [
            TextEdit(from: 1, to: 4, insert: "XY")
        ])
        XCTAssertEqual(replacement.mapPosition(1, association: .after), 1)
        XCTAssertEqual(replacement.mapPosition(2, association: .before), 1)
        XCTAssertEqual(replacement.mapPosition(2, association: .after), 3)
        XCTAssertEqual(replacement.mapPosition(4, association: .before), 3)
        XCTAssertEqual(
            try replacement.mapPosition(5, originalUTF16Length: 5),
            4
        )
        XCTAssertThrowsError(
            try replacement.mapPosition(6, originalUTF16Length: 5)
        )
    }

    func testMapSelectionUsesInwardEdgesAndPreservesBackwardsDirection() throws {
        let transaction = try TextTransaction(edits: [
            TextEdit(from: 2, to: 2, insert: "XX"),
            TextEdit(from: 5, to: 5, insert: "Y")
        ])
        let backwards = DirectedSelection(anchor: 5, head: 2)

        XCTAssertEqual(
            transaction.mapSelection(backwards),
            DirectedSelection(anchor: 7, head: 4)
        )
        XCTAssertEqual(
            transaction.mapSelection(DirectedSelection(anchor: 2, head: 2)),
            DirectedSelection(anchor: 2, head: 2)
        )
        XCTAssertEqual(
            transaction.mapSelection(
                DirectedSelection(anchor: 2, head: 2),
                cursorAssociation: .after
            ),
            DirectedSelection(anchor: 4, head: 4)
        )

        let replacement = try TextTransaction(edits: [
            TextEdit(from: 1, to: 4, insert: "XY")
        ])
        XCTAssertEqual(
            replacement.mapSelection(DirectedSelection(anchor: 3, head: 2)),
            DirectedSelection(anchor: 3, head: 1)
        )
    }

    @MainActor
    func testMultipleEditsAreOneUndoAndRestoreExplicitPostEditSelection() async throws {
        let initialSelection = SelectionSet.single(anchor: 4, head: 1)
        let buffer = DocumentBuffer(text: "A🙂B", selection: initialSelection)
        let finalSelection = SelectionSet(ranges: [
            DirectedSelection(anchor: 0, head: 0),
            DirectedSelection(anchor: 4, head: 2)
        ], mainIndex: 1)
        let transaction = try TextTransaction(
            edits: [
                TextEdit(from: 1, to: 3, insert: "xy"),
                TextEdit(from: 4, to: 4, insert: "!")
            ],
            selection: finalSelection,
            expectedRevision: 0
        )

        XCTAssertEqual(try buffer.apply(transaction), 1)
        XCTAssertEqual(buffer.text, "AxyB!")
        XCTAssertEqual(buffer.selection, finalSelection)
        XCTAssertEqual(buffer.undoDepth, 1)

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.text, "A🙂B")
        XCTAssertEqual(buffer.selection, initialSelection)
        XCTAssertEqual(buffer.revision, 2)
        XCTAssertFalse(buffer.canUndo)

        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.text, "AxyB!")
        XCTAssertEqual(buffer.selection, finalSelection)
        XCTAssertEqual(buffer.revision, 3)
    }

    @MainActor
    func testUndoRedoRestoresEveryPaneSelection() async throws {
        let left: EditorViewID = "left"
        let right: EditorViewID = "right"
        let buffer = try DocumentBuffer(
            text: "abcd",
            viewSelections: [
                left: .cursor(at: 1),
                right: .single(anchor: 4, head: 2)
            ]
        )
        let leftAfter = SelectionSet.cursor(at: 2)
        let transaction = try TextTransaction(
            edits: [TextEdit(from: 1, to: 1, insert: "X")],
            selection: leftAfter
        )

        try buffer.apply(transaction, for: left)
        XCTAssertEqual(buffer.selection(for: left), leftAfter)
        XCTAssertEqual(
            buffer.selection(for: right),
            .single(anchor: 5, head: 3)
        )

        XCTAssertTrue(buffer.undo(for: left))
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 1))
        XCTAssertEqual(buffer.selection(for: right), .single(anchor: 4, head: 2))

        XCTAssertTrue(buffer.redo(for: left))
        XCTAssertEqual(buffer.selection(for: left), leftAfter)
        XCTAssertEqual(buffer.selection(for: right), .single(anchor: 5, head: 3))
    }

    @MainActor
    func testUndoAndRedoMapSelectionForPaneOpenedAfterTransaction() async throws {
        let later: EditorViewID = "later"
        let buffer = DocumentBuffer(text: "abc")
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X")
        ]))
        try buffer.registerView(later, selection: .cursor(at: 2))

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.selection(for: later), .cursor(at: 1))
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.selection(for: later), .cursor(at: 2))
    }

    @MainActor
    func testUndoRedoDoesNotOwnPaneLifetime() async throws {
        let left: EditorViewID = "left"
        let right: EditorViewID = "right"
        let later: EditorViewID = "later"
        let buffer = try DocumentBuffer(
            text: "abc",
            viewSelections: [
                left: .cursor(at: 1),
                right: .cursor(at: 2)
            ]
        )
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X")
        ]), for: left)

        try buffer.registerView(later, selection: .cursor(at: 4))
        buffer.removeView(right)
        XCTAssertTrue(buffer.undo(for: left))
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 1))
        XCTAssertEqual(buffer.selection(for: later), .cursor(at: 3))
        XCTAssertNil(buffer.selection(for: right))

        XCTAssertTrue(buffer.redo(for: left))
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 1))
        XCTAssertEqual(buffer.selection(for: later), .cursor(at: 4))
        XCTAssertNil(buffer.selection(for: right))
    }

    @MainActor
    func testSelectionOnlyTransactionDoesNotEnterTextHistoryOrClearRedo() async throws {
        let buffer = DocumentBuffer(text: "abc", selection: .cursor(at: 1))
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X")
        ]))
        XCTAssertTrue(buffer.undo())
        let revision = buffer.revision

        try buffer.apply(try TextTransaction(
            edits: [],
            selection: .cursor(at: 2)
        ))
        XCTAssertEqual(buffer.selection, .cursor(at: 2))
        XCTAssertEqual(buffer.revision, revision)
        XCTAssertEqual(buffer.undoDepth, 0)
        XCTAssertEqual(buffer.redoDepth, 1)
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.text, "aXbc")
    }

    @MainActor
    func testReusingAViewIDDoesNotRestoreTheRetiredPanesSelection() async throws {
        let pane: EditorViewID = "reusable-pane"
        let buffer = DocumentBuffer(text: "abcd")
        try buffer.registerView(pane, selection: .cursor(at: 1))
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "X")
        ]), for: pane)

        buffer.removeView(pane)
        try buffer.registerView(pane, selection: .cursor(at: 4))

        XCTAssertFalse(buffer.undo(for: pane))
        XCTAssertEqual(buffer.selection(for: pane), .cursor(at: 4))
        XCTAssertFalse(buffer.redo(for: pane))
        XCTAssertEqual(buffer.selection(for: pane), .cursor(at: 4))
    }

    @MainActor
    func testResetAtomicallyReplacesStateClearsHistoryAndAdvancesRevision() async throws {
        let left: EditorViewID = "left"
        let retired: EditorViewID = "retired"
        let added: EditorViewID = "added"
        let buffer = try DocumentBuffer(
            text: "abc",
            viewSelections: [
                left: .cursor(at: 1),
                retired: .cursor(at: 2)
            ]
        )
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X")
        ]), for: left)
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "Y")
        ]), for: left)
        XCTAssertTrue(buffer.undo(for: left))
        XCTAssertTrue(buffer.canUndo(for: left))
        XCTAssertTrue(buffer.canRedo(for: left))
        XCTAssertEqual(buffer.revision, 3)

        XCTAssertEqual(try buffer.reset(
            text: "🙂z",
            viewSelections: [
                left: .cursor(at: 2),
                added: .single(anchor: 3, head: 0)
            ]
        ), 4)
        XCTAssertEqual(buffer.text, "🙂z")
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 2))
        XCTAssertEqual(buffer.selection(for: added), .single(anchor: 3, head: 0))
        XCTAssertNil(buffer.selection(for: retired))
        XCTAssertEqual(buffer.selection, .cursor(at: 0))
        XCTAssertFalse(buffer.canUndo)
        XCTAssertFalse(buffer.canRedo)
    }

    @MainActor
    func testInvalidResetLeavesTextSelectionsRevisionAndHistoryUntouched() async throws {
        let buffer = DocumentBuffer(text: "abc", selection: .cursor(at: 1))
        try buffer.apply(try TextTransaction(edits: [
            TextEdit(from: 1, to: 1, insert: "X")
        ]))
        let selections = buffer.selections

        XCTAssertThrowsError(try buffer.reset(
            text: "z",
            viewSelections: [.default: .cursor(at: 2)]
        ))
        XCTAssertEqual(buffer.text, "aXbc")
        XCTAssertEqual(buffer.selections, selections)
        XCTAssertEqual(buffer.revision, 1)
        XCTAssertTrue(buffer.canUndo)
        XCTAssertFalse(buffer.canRedo)
    }

    @MainActor
    func testApplyRejectsUnknownPaneConsistently() async throws {
        let buffer = DocumentBuffer(text: "abc")
        let unknown: EditorViewID = "unknown"
        let edit = try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "X")
        ])
        XCTAssertThrowsError(try buffer.apply(edit, for: unknown)) { error in
            XCTAssertEqual(error as? EditorTransactionError, .unknownView(unknown))
        }

        let selection = try TextTransaction(
            edits: [],
            selection: .cursor(at: 1)
        )
        XCTAssertThrowsError(try buffer.apply(selection, for: unknown))
        XCTAssertEqual(buffer.text, "abc")
        XCTAssertNil(buffer.selection(for: unknown))
    }

    @MainActor
    func testFailedTransactionIsAtomicAndNewEditClearsRedoBranch() async throws {
        let buffer = DocumentBuffer(text: "abc", selection: .cursor(at: 1))
        let first = try TextTransaction(
            edits: [TextEdit(from: 1, to: 1, insert: "X")],
            expectedRevision: 0
        )
        try buffer.apply(first)
        XCTAssertTrue(buffer.undo())
        XCTAssertTrue(buffer.canRedo)

        let stale = try TextTransaction(
            edits: [TextEdit(from: 0, to: 0, insert: "!")],
            expectedRevision: 0
        )
        XCTAssertThrowsError(try buffer.apply(stale)) { error in
            XCTAssertEqual(
                error as? EditorTransactionError,
                .staleRevision(expected: 0, actual: 2)
            )
        }
        XCTAssertEqual(buffer.text, "abc")
        XCTAssertEqual(buffer.revision, 2)
        XCTAssertTrue(buffer.canRedo)

        let branch = try TextTransaction(
            edits: [TextEdit(from: 3, to: 3, insert: "!")],
            expectedRevision: 2
        )
        try buffer.apply(branch)
        XCTAssertEqual(buffer.text, "abc!")
        XCTAssertEqual(buffer.revision, 3)
        XCTAssertFalse(buffer.canRedo)
    }

    @MainActor
    func testInvalidExplicitSelectionDoesNotPartiallyApplyTransaction() async throws {
        let originalSelection = SelectionSet.cursor(at: 1)
        let buffer = DocumentBuffer(text: "abc", selection: originalSelection)
        let transaction = try TextTransaction(
            edits: [TextEdit(from: 1, to: 2, insert: "X")],
            selection: .cursor(at: 10)
        )

        XCTAssertThrowsError(try buffer.apply(transaction))
        XCTAssertEqual(buffer.text, "abc")
        XCTAssertEqual(buffer.selection, originalSelection)
        XCTAssertEqual(buffer.revision, 0)
        XCTAssertFalse(buffer.canUndo)
    }

    @MainActor
    func testInterleavedPaneHistoryUndoesOnlyTheOwningView() async throws {
        let left: EditorViewID = "left"
        let right: EditorViewID = "right"
        let buffer = try DocumentBuffer(
            text: "abcd",
            viewSelections: [
                left: .cursor(at: 1),
                right: .cursor(at: 3)
            ]
        )

        try buffer.apply(try TextTransaction(
            edits: [TextEdit(from: 1, to: 1, insert: "L")],
            selection: .cursor(at: 2)
        ), for: left)
        try buffer.apply(try TextTransaction(
            edits: [TextEdit(from: 4, to: 4, insert: "R")],
            selection: .cursor(at: 5)
        ), for: right)

        XCTAssertEqual(buffer.text, "aLbcRd")
        XCTAssertEqual(buffer.undoDepth(for: left), 1)
        XCTAssertEqual(buffer.undoDepth(for: right), 1)

        XCTAssertTrue(buffer.undo(for: left))
        XCTAssertEqual(buffer.text, "abcRd")
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 1))
        XCTAssertEqual(buffer.selection(for: right), .cursor(at: 4))
        XCTAssertEqual(buffer.redoDepth(for: left), 1)
        XCTAssertEqual(buffer.undoDepth(for: right), 1)

        XCTAssertTrue(buffer.undo(for: right))
        XCTAssertEqual(buffer.text, "abcd")
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 1))
        XCTAssertEqual(buffer.selection(for: right), .cursor(at: 3))

        XCTAssertTrue(buffer.redo(for: right))
        XCTAssertEqual(buffer.text, "abcRd")
        XCTAssertEqual(buffer.selection(for: right), .cursor(at: 4))
        XCTAssertTrue(buffer.redo(for: left))
        XCTAssertEqual(buffer.text, "aLbcRd")
        XCTAssertEqual(buffer.selection(for: left), .cursor(at: 2))
        XCTAssertEqual(buffer.selection(for: right), .cursor(at: 5))
    }

    @MainActor
    func testNewEditClearsRedoOnlyForTheOwningViewBranch() async throws {
        let left: EditorViewID = "left"
        let right: EditorViewID = "right"
        let buffer = try DocumentBuffer(
            text: "abcd",
            viewSelections: [
                left: .cursor(at: 1),
                right: .cursor(at: 3)
            ]
        )

        try buffer.apply(try TextTransaction(
            edits: [TextEdit(from: 1, to: 1, insert: "L")],
            selection: .cursor(at: 2)
        ), for: left)
        try buffer.apply(try TextTransaction(
            edits: [TextEdit(from: 4, to: 4, insert: "R")],
            selection: .cursor(at: 5)
        ), for: right)

        XCTAssertTrue(buffer.undo(for: left))
        XCTAssertEqual(buffer.text, "abcRd")
        XCTAssertTrue(buffer.canRedo(for: left))
        XCTAssertFalse(buffer.canRedo(for: right))

        try buffer.apply(try TextTransaction(
            edits: [TextEdit(from: 0, to: 0, insert: "!")],
            selection: .cursor(at: 1)
        ), for: right)

        XCTAssertEqual(buffer.text, "!abcRd")
        XCTAssertTrue(buffer.canRedo(for: left))
        XCTAssertEqual(buffer.undoDepth(for: right), 2)
        XCTAssertTrue(buffer.undo(for: right))
        XCTAssertEqual(buffer.text, "abcRd")
        XCTAssertTrue(buffer.undo(for: right))
        XCTAssertEqual(buffer.text, "abcd")
        XCTAssertTrue(buffer.canRedo(for: left))
        XCTAssertTrue(buffer.redo(for: left))
        XCTAssertEqual(buffer.text, "aLbcd")
    }

    @MainActor
    func testPerViewHistoryIsBounded() async throws {
        let buffer = DocumentBuffer(text: "")
        for index in 0 ... DocumentBuffer.maximumHistoryEntriesPerView {
            try buffer.apply(try TextTransaction(edits: [
                TextEdit(from: index, to: index, insert: "x")
            ]))
        }

        XCTAssertEqual(
            buffer.undoDepth, DocumentBuffer.maximumHistoryEntriesPerView
        )
    }
}
