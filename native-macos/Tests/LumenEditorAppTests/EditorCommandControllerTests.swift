import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class EditorCommandControllerTests: XCTestCase {
    @MainActor
    func testDispatchCapturesFreshSnapshotAndAppliesOneTransaction() throws {
        var text = "a  \nb  "
        var selection = SelectionSet.cursor(at: 0)
        var revision: UInt64 = 11
        var applied: [TextTransaction] = []
        let controller = EditorCommandController(
            snapshot: {
                EditingCommandSnapshot(
                    text: text,
                    selection: selection,
                    expectedRevision: revision
                )
            },
            apply: { transaction in
                applied.append(transaction)
                guard let next = try? transaction.applying(to: text) else { return false }
                text = next
                selection = transaction.selection ?? selection
                revision += 1
                return true
            }
        )

        XCTAssertEqual(controller.dispatch(commandID: "trim-trailing-whitespace"), .applied)
        XCTAssertEqual(text, "a\nb")
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].expectedRevision, 11)
        XCTAssertEqual(controller.dispatch(commandID: "trim-trailing-whitespace"), .noChange)
        XCTAssertEqual(applied.count, 1)
    }

    @MainActor
    func testSelectionHistoryDispatchesSelectionOnlyTransactions() {
        var snapshot = EditingCommandSnapshot(
            text: "one two",
            selection: .cursor(at: 1),
            expectedRevision: 3
        )
        var transactions: [TextTransaction] = []
        let controller = EditorCommandController(
            snapshot: { snapshot },
            apply: { transaction in
                transactions.append(transaction)
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )

        XCTAssertEqual(controller.dispatch(commandID: "select-next-occurrence"), .applied)
        XCTAssertEqual(snapshot.selection.main, DirectedSelection(anchor: 0, head: 3))
        XCTAssertTrue(controller.canUndoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .applied)
        XCTAssertTrue(transactions.last?.edits.isEmpty == true)
        XCTAssertEqual(snapshot.selection, .cursor(at: 1))
        XCTAssertTrue(controller.canRedoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "redo-selection"), .applied)
        XCTAssertEqual(snapshot.selection.main, DirectedSelection(anchor: 0, head: 3))
    }

    @MainActor
    func testManualSelectionChangesEnterCurrentViewHistory() {
        let viewID = EditorViewID(rawValue: "left")
        var snapshot = EditingCommandSnapshot(
            text: "one two", selection: .cursor(at: 1), expectedRevision: 3
        )
        let controller = EditorCommandController(
            snapshot: { snapshot },
            selectionHistoryKey: { .init(documentID: "doc", viewID: viewID) },
            apply: { transaction in
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )
        let moved = SelectionSet.cursor(at: 7)
        controller.recordSelectionChange(
            documentID: "doc", viewID: viewID, documentRevision: 3,
            from: snapshot.selection, to: moved
        )
        snapshot.selection = moved

        XCTAssertTrue(controller.canUndoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .applied)
        XCTAssertEqual(snapshot.selection, .cursor(at: 1))
        XCTAssertTrue(controller.canRedoSelection)
    }

    @MainActor
    func testManualSelectionUndoRedoPreservesBackwardDirection() {
        let viewID = EditorViewID(rawValue: "left")
        let forward = SelectionSet.single(anchor: 2, head: 7)
        let backward = SelectionSet.single(anchor: 7, head: 2)
        var snapshot = EditingCommandSnapshot(
            text: "0123456789", selection: backward, expectedRevision: 3
        )
        let controller = EditorCommandController(
            snapshot: { snapshot },
            selectionHistoryKey: { .init(documentID: "doc", viewID: viewID) },
            apply: { transaction in
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )
        controller.recordSelectionChange(
            documentID: "doc", viewID: viewID, documentRevision: 3,
            from: forward, to: backward
        )

        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .applied)
        XCTAssertEqual(snapshot.selection, forward)
        XCTAssertEqual(controller.dispatch(commandID: "redo-selection"), .applied)
        XCTAssertEqual(snapshot.selection, backward)
    }

    @MainActor
    func testSelectionHistoryIsIsolatedByDocumentAndView() {
        let left = EditorViewID(rawValue: "left")
        let right = EditorViewID(rawValue: "right")
        var documentID = "a"
        var viewID = left
        var snapshot = EditingCommandSnapshot(
            text: "0123456789", selection: .cursor(at: 1), expectedRevision: 4
        )
        let controller = EditorCommandController(
            snapshot: { snapshot },
            selectionHistoryKey: { .init(documentID: documentID, viewID: viewID) },
            apply: { transaction in
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )
        controller.recordSelectionChange(
            documentID: documentID, viewID: viewID, documentRevision: 4,
            from: .cursor(at: 1), to: .cursor(at: 8)
        )
        snapshot.selection = .cursor(at: 8)

        documentID = "b"
        snapshot = EditingCommandSnapshot(
            text: "xy", selection: .cursor(at: 2), expectedRevision: 1
        )
        XCTAssertFalse(controller.canUndoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .noChange)

        documentID = "a"
        viewID = right
        snapshot = EditingCommandSnapshot(
            text: "0123456789", selection: .cursor(at: 5), expectedRevision: 4
        )
        XCTAssertFalse(controller.canUndoSelection)

        viewID = left
        snapshot.selection = .cursor(at: 8)
        XCTAssertTrue(controller.canUndoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .applied)
        XCTAssertEqual(snapshot.selection, .cursor(at: 1))
    }

    @MainActor
    func testExternalTextRevisionInvalidatesOnlyMatchingViewHistory() {
        let left = EditorViewID(rawValue: "left")
        var revision: UInt64 = 2
        var selection = SelectionSet.cursor(at: 4)
        let controller = EditorCommandController(
            snapshot: { EditingCommandSnapshot(
                text: revision == 2 ? "hello" : "hello!",
                selection: selection, expectedRevision: revision
            ) },
            selectionHistoryKey: { .init(documentID: "doc", viewID: left) },
            apply: { transaction in
                if let next = transaction.selection { selection = next }
                return true
            }
        )
        controller.recordSelectionChange(
            documentID: "doc", viewID: left, documentRevision: revision,
            from: .cursor(at: 1), to: selection
        )
        revision = 3

        XCTAssertFalse(controller.canUndoSelection)
        XCTAssertEqual(controller.dispatch(commandID: "undo-selection"), .noChange)
    }

    @MainActor
    func testExpansionHistoryIsIsolatedByView() {
        let left = EditorViewID(rawValue: "left")
        let right = EditorViewID(rawValue: "right")
        var viewID = left
        var snapshot = EditingCommandSnapshot(
            text: "one two", selection: .cursor(at: 1), expectedRevision: 5
        )
        let controller = EditorCommandController(
            snapshot: { snapshot },
            selectionHistoryKey: { .init(documentID: "doc", viewID: viewID) },
            apply: { transaction in
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )

        XCTAssertEqual(controller.dispatch(commandID: "expand-selection"), .applied)
        let expanded = snapshot.selection
        viewID = right
        snapshot.selection = .cursor(at: 5)
        XCTAssertEqual(controller.dispatch(commandID: "shrink-selection"), .noChange)

        viewID = left
        snapshot.selection = expanded
        XCTAssertEqual(controller.dispatch(commandID: "shrink-selection"), .applied)
        XCTAssertEqual(snapshot.selection, .cursor(at: 1))
    }

    @MainActor
    func testTextCommandClearsOnlyItsViewSelectionHistory() {
        let left = EditorViewID(rawValue: "left")
        let right = EditorViewID(rawValue: "right")
        var viewID = left
        var snapshot = EditingCommandSnapshot(
            text: "a  \nb  ", selection: .cursor(at: 1), expectedRevision: 7
        )
        let controller = EditorCommandController(
            snapshot: { snapshot },
            selectionHistoryKey: { .init(documentID: "doc", viewID: viewID) },
            apply: { transaction in
                guard let text = try? transaction.applying(to: snapshot.text) else { return false }
                snapshot.text = text
                if let selection = transaction.selection { snapshot.selection = selection }
                if !transaction.edits.isEmpty {
                    snapshot.expectedRevision = (snapshot.expectedRevision ?? 0) + 1
                }
                return true
            }
        )
        controller.recordSelectionChange(
            documentID: "doc", viewID: left, documentRevision: 7,
            from: .cursor(at: 0), to: .cursor(at: 1)
        )
        controller.recordSelectionChange(
            documentID: "doc", viewID: right, documentRevision: 7,
            from: .cursor(at: 2), to: .cursor(at: 3)
        )

        XCTAssertEqual(controller.dispatch(commandID: "trim-trailing-whitespace"), .applied)
        XCTAssertFalse(controller.canUndoSelection)

        viewID = right
        // The shared buffer revision invalidates the other view's stale history
        // instead of applying old offsets to the new document revision.
        snapshot.selection = .cursor(at: 3)
        XCTAssertFalse(controller.canUndoSelection)
    }

    @MainActor
    func testSelectionChangeCallbackIdentifiesTheAppliedCommand() {
        var snapshot = EditingCommandSnapshot(
            text: "(value)",
            selection: .cursor(at: 0),
            expectedRevision: 7
        )
        var callbacks: [(String, EditingCommandSnapshot, SelectionSet)] = []
        let controller = EditorCommandController(
            snapshot: { snapshot },
            apply: { transaction in
                guard let selection = transaction.selection else { return false }
                snapshot.selection = selection
                return true
            },
            successfulSelectionChange: { commandID, before, after in
                callbacks.append((commandID, before, after))
            }
        )

        XCTAssertEqual(controller.dispatch(commandID: "goto-matching-bracket"), .applied)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks[0].0, "goto-matching-bracket")
        XCTAssertEqual(callbacks[0].1.selection, .cursor(at: 0))
        XCTAssertEqual(callbacks[0].2, .cursor(at: 7))
    }

    @MainActor
    func testUnavailableUnsupportedAndRejectedResultsAreDistinct() {
        let unavailable = EditorCommandController(snapshot: { nil }, apply: { _ in true })
        XCTAssertEqual(unavailable.dispatch(commandID: "select-line"), .unavailable)
        XCTAssertEqual(unavailable.dispatch(commandID: "not-a-command"), .unsupported)

        let supportedNoChange = EditorCommandController(
            snapshot: { EditingCommandSnapshot(text: "x", selection: .cursor(at: 0)) },
            apply: { _ in true }
        )
        XCTAssertEqual(
            supportedNoChange.dispatch(commandID: "select-parent-syntax"),
            .noChange
        )

        let rejected = EditorCommandController(
            snapshot: { EditingCommandSnapshot(text: "x", selection: .cursor(at: 0)) },
            apply: { _ in false }
        )
        XCTAssertEqual(rejected.dispatch(commandID: "select-line"), .noChange)
    }

    @MainActor
    func testResourceFailureDoesNotCallApply() {
        var applyCount = 0
        let controller = EditorCommandController(
            limits: EditingCommandLimits(
                maximumDocumentUTF16Length: 1,
                maximumSelections: 10,
                maximumEdits: 10
            ),
            snapshot: {
                EditingCommandSnapshot(text: "😀", selection: .cursor(at: 0))
            },
            apply: { _ in applyCount += 1; return true }
        )

        guard case let .failed(message) = controller.dispatch(commandID: "select-line") else {
            return XCTFail("Expected a bounded planning failure")
        }
        XCTAssertTrue(message.contains("maximum"))
        XCTAssertEqual(applyCount, 0)
    }

    @MainActor
    func testRouterRegistrationCoversAllRecognizedCommands() async throws {
        var snapshot = EditingCommandSnapshot(text: "one", selection: .cursor(at: 1))
        let controller = EditorCommandController(
            snapshot: { snapshot },
            apply: { transaction in
                if let selection = transaction.selection { snapshot.selection = selection }
                return true
            }
        )
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)

        XCTAssertEqual(tokens.count, EditorCommandController.commandIDs.count)
        XCTAssertEqual(
            router.status(
                for: "select-line",
                context: CommandRoutingContext(hasDocument: true)
            ),
            .enabled
        )
        XCTAssertEqual(
            router.status(
                for: "select-parent-syntax",
                context: CommandRoutingContext(hasDocument: true)
            ),
            .enabled
        )
        let result = await router.execute(
            "select-line",
            context: CommandRoutingContext(hasDocument: true)
        )
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertEqual(snapshot.selection.main, DirectedSelection(anchor: 0, head: 3))

        let noChange = await router.execute(
            "select-parent-syntax",
            context: CommandRoutingContext(hasDocument: true)
        )
        guard case .noChange(commandID: "select-parent-syntax") = noChange else {
            return XCTFail("A no-op editor plan must not report executed")
        }
        XCTAssertFalse(noChange.didExecuteSuccessfully)
    }

    @MainActor
    func testRouterPropagatesPlanningFailure() async throws {
        let controller = EditorCommandController(
            limits: EditingCommandLimits(
                maximumDocumentUTF16Length: 1,
                maximumSelections: 10,
                maximumEdits: 10
            ),
            snapshot: { EditingCommandSnapshot(text: "😀", selection: .cursor(at: 0)) },
            apply: { _ in true }
        )
        let router = CommandRouter()
        _ = try controller.registerCommands(on: router)

        let result = await router.execute(
            "select-line", context: CommandRoutingContext(hasDocument: true)
        )
        guard case let .failed(commandID, error) = result else {
            return XCTFail("Expected the planner failure to reach the router")
        }
        XCTAssertEqual(commandID, "select-line")
        XCTAssertTrue(error.localizedDescription.contains("maximum"))
    }

    @MainActor
    func testParserAwareDispatchPreparesThenRecapturesExactSnapshot() async throws {
        let text = "(value)"
        var revision: UInt64 = 7
        var parsed: ParsedSyntaxSnapshot?
        var prepareCount = 0
        var applied: TextTransaction?
        let controller = EditorCommandController(
            snapshot: {
                EditingCommandSnapshot(
                    text: text, selection: .cursor(at: 0), language: "JavaScript",
                    expectedRevision: revision, parsedSyntax: parsed
                )
            },
            apply: { applied = $0; return true },
            prepareParsedSyntax: { snapshot in
                prepareCount += 1
                guard let revision = snapshot.expectedRevision else { return }
                parsed = ParsedSyntaxSnapshot(
                    sourceUTF16Length: snapshot.text.utf16.count, nodes: [],
                    bracketPairs: [.init(open: 0, close: 6)], indentation: [],
                    expectedRevision: revision
                )
            }
        )

        let result = await controller.dispatchPrepared(commandID: "goto-matching-bracket")
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(applied?.selection?.main, .cursor(at: 7))

        revision = 8
        _ = await controller.dispatchPrepared(commandID: "select-line")
        XCTAssertEqual(prepareCount, 1, "Non-structural commands must not wait for parser work")
    }
}
