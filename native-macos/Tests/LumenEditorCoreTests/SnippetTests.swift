import Foundation
import XCTest
@testable import LumenEditorCore

final class SnippetTests: XCTestCase {
    func testParserMatchesElectronPlaceholderSubsetAndUTF16Offsets() throws {
        let parsed = try SnippetEngine.parse(
            "😀 ${2:two} ${1:one} $2 ${0} tail"
        )

        XCTAssertEqual(parsed.text, "😀 two one   tail")
        XCTAssertEqual(parsed.placeholders.map(\.index), [1, 2, 2])
        XCTAssertEqual(parsed.placeholders.map(\.range), [
            NSRange(location: 7, length: 3),
            NSRange(location: 3, length: 3),
            NSRange(location: 11, length: 0)
        ])
        XCTAssertEqual(parsed.finalOffset, 12)
    }

    func testNoFinalMarkerFallsBackToInsertedTextEnd() throws {
        let parsed = try SnippetEngine.parse("let ${1:name} = 1")

        XCTAssertEqual(parsed.text, "let name = 1")
        XCTAssertEqual(parsed.finalOffset, 12)
    }

    func testInsertionPlanReplacesSelectionAsOneTransactionAndSelectsFirstPlaceholder() throws {
        let plan = try SnippetEngine.insertionPlan(
            template: "(${1:value})${0}",
            documentUTF16Length: 5,
            selection: .single(anchor: 4, head: 1),
            expectedRevision: 7
        )

        XCTAssertEqual(plan.transaction.edits, [
            TextEdit(from: 1, to: 4, insert: "(value)")
        ])
        XCTAssertEqual(plan.transaction.expectedRevision, 7)
        XCTAssertEqual(plan.transaction.selection, .single(anchor: 2, head: 7))
        XCTAssertEqual(plan.placeholders, [
            SnippetPlaceholder(index: 1, range: NSRange(location: 2, length: 5))
        ])
        XCTAssertEqual(plan.finalPosition, 8)
        XCTAssertEqual(try plan.transaction.applying(to: "abcde"), "a(value)e")
    }

    func testInsertionWithoutPlaceholdersPlacesCursorAtFinalPosition() throws {
        let plan = try SnippetEngine.insertionPlan(
            template: "xyz", documentUTF16Length: 2,
            selection: .cursor(at: 1)
        )

        XCTAssertEqual(plan.transaction.selection, .cursor(at: 4))
        XCTAssertTrue(plan.placeholders.isEmpty)
    }

    func testTriggerExpansionReplacesTriggerAndSnippetInOneUndoUnit() throws {
        let plan = try SnippetEngine.triggerExpansionPlan(
            trigger: "log", template: "print(${1:value})",
            documentText: "say log", cursor: 7, expectedRevision: 4
        )

        XCTAssertEqual(plan.replacedTriggerRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(plan.transaction.edits, [
            TextEdit(from: 4, to: 7, insert: "print(value)")
        ])
        XCTAssertEqual(plan.transaction.expectedRevision, 4)
        XCTAssertEqual(try plan.transaction.applying(to: "say log"), "say print(value)")
        XCTAssertEqual(plan.transaction.selection, .single(anchor: 10, head: 15))
        XCTAssertEqual(
            SnippetEngine.triggerBeforeCursor(in: "say foo-bar", cursor: 11),
            "foo-bar"
        )
        XCTAssertNil(SnippetEngine.triggerBeforeCursor(in: "say ", cursor: 4))
        XCTAssertThrowsError(try SnippetEngine.triggerExpansionPlan(
            trigger: "nope", template: "x", documentText: "say log", cursor: 7
        ))
    }

    func testParserEnforcesTemplatePlaceholderAndIndexLimits() {
        XCTAssertThrowsError(try SnippetEngine.parse(
            "1234",
            limits: SnippetLimits(maximumTemplateUTF16Length: 3)
        )) { error in
            XCTAssertEqual(
                error as? SnippetError,
                .templateTooLarge(actual: 4, maximum: 3)
            )
        }
        XCTAssertThrowsError(try SnippetEngine.parse(
            "$1 $2",
            limits: SnippetLimits(maximumPlaceholders: 1)
        ))
        XCTAssertThrowsError(try SnippetEngine.parse(
            "$11",
            limits: SnippetLimits(maximumPlaceholderIndex: 10)
        ))
    }

    func testInsertionRejectsAnOutOfBoundsSelection() {
        XCTAssertThrowsError(try SnippetEngine.insertionPlan(
            template: "x", documentUTF16Length: 2,
            selection: .cursor(at: 3)
        )) { error in
            XCTAssertEqual(error as? SnippetError, .invalidSelection)
        }
    }

    func testSessionNavigatesForwardBackwardThenToFinalStop() {
        var session = SnippetSession(
            documentID: "doc",
            placeholders: [
                SnippetPlaceholder(index: 1, range: NSRange(location: 2, length: 3)),
                SnippetPlaceholder(index: 2, range: NSRange(location: 8, length: 1))
            ],
            finalPosition: 12
        )

        XCTAssertEqual(session.activePlaceholder?.index, 1)
        XCTAssertEqual(
            session.navigate(.previous),
            .selection(.single(anchor: 8, head: 9))
        )
        XCTAssertEqual(
            session.navigate(.previous),
            .selection(.single(anchor: 2, head: 5))
        )
        XCTAssertEqual(
            session.navigate(.next),
            .selection(.single(anchor: 8, head: 9))
        )
        XCTAssertEqual(session.navigate(.next), .final(.cursor(at: 12)))
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.navigate(.next), .inactive)
    }

    func testSessionBuildsOneAtomicTransactionForRepeatedPlaceholderMirror() throws {
        let original = "foo + foo; z"
        var session = SnippetSession(
            documentID: "doc",
            placeholders: [
                SnippetPlaceholder(index: 1, range: NSRange(location: 0, length: 3)),
                SnippetPlaceholder(index: 1, range: NSRange(location: 6, length: 3)),
                SnippetPlaceholder(index: 2, range: NSRange(location: 11, length: 1))
            ],
            finalPosition: 12
        )
        let userEdit = try TextTransaction(
            edits: [TextEdit(from: 0, to: 3, insert: "value")],
            selection: .cursor(at: 5), expectedRevision: 2
        )

        let combined = try session.incorporatingUserTransaction(userEdit, in: original)

        XCTAssertEqual(combined.edits, [
            TextEdit(from: 0, to: 3, insert: "value"),
            TextEdit(from: 6, to: 9, insert: "value")
        ])
        XCTAssertEqual(try combined.applying(to: original), "value + value; z")
        XCTAssertEqual(combined.expectedRevision, 2)
        XCTAssertEqual(combined.selection, .cursor(at: 5))
        XCTAssertEqual(session.placeholders.map(\.range), [
            NSRange(location: 0, length: 5),
            NSRange(location: 8, length: 5),
            NSRange(location: 15, length: 1)
        ])
        XCTAssertEqual(session.finalPosition, 16)
    }

    func testSessionMirrorsInsertionInsideRepeatedPlaceholderAtomically() throws {
        let original = "foo + foo"
        var session = SnippetSession(
            documentID: "doc",
            placeholders: [
                SnippetPlaceholder(index: 1, range: NSRange(location: 0, length: 3)),
                SnippetPlaceholder(index: 1, range: NSRange(location: 6, length: 3))
            ],
            finalPosition: 9
        )
        let userEdit = try TextTransaction(
            edits: [TextEdit(from: 1, to: 1, insert: "X")],
            selection: .cursor(at: 2), expectedRevision: 1
        )

        let combined = try session.incorporatingUserTransaction(userEdit, in: original)

        XCTAssertEqual(combined.edits, [
            TextEdit(from: 1, to: 1, insert: "X"),
            TextEdit(from: 6, to: 9, insert: "fXoo")
        ])
        XCTAssertEqual(try combined.applying(to: original), "fXoo + fXoo")
        XCTAssertEqual(combined.selection, .cursor(at: 2))
        XCTAssertEqual(session.placeholders.map(\.range), [
            NSRange(location: 0, length: 4),
            NSRange(location: 7, length: 4)
        ])
        XCTAssertEqual(session.finalPosition, 11)
    }

    func testSessionMapsUnrelatedEditsAndCancelsOnDocumentChange() throws {
        var session = SnippetSession(
            documentID: "doc",
            placeholders: [SnippetPlaceholder(
                index: 1, range: NSRange(location: 3, length: 2)
            )],
            finalPosition: 6
        )
        let transaction = try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "XX")
        ])

        let mapped = try session.incorporatingUserTransaction(
            transaction, in: "abcdez"
        )
        XCTAssertEqual(mapped, transaction)
        XCTAssertEqual(session.activePlaceholder?.range, NSRange(location: 5, length: 2))
        XCTAssertEqual(session.finalPosition, 8)

        session.documentDidChange(to: "other")
        XCTAssertFalse(session.isActive)
    }

    func testSessionRejectsBoundaryCrossingEditAndMirrorFanoutOverLimit() throws {
        var boundary = SnippetSession(
            documentID: "doc",
            placeholders: [SnippetPlaceholder(
                index: 1, range: NSRange(location: 2, length: 2)
            )],
            finalPosition: 5
        )
        XCTAssertThrowsError(try boundary.incorporatingUserTransaction(
            TextTransaction(edits: [TextEdit(from: 1, to: 3, insert: "x")]),
            in: "abcde"
        )) { error in
            XCTAssertEqual(error as? SnippetSessionError, .editCannotBeMapped)
        }
        XCTAssertFalse(boundary.isActive)

        var bounded = SnippetSession(
            documentID: "doc",
            placeholders: [
                SnippetPlaceholder(index: 1, range: NSRange(location: 0, length: 1)),
                SnippetPlaceholder(index: 1, range: NSRange(location: 2, length: 1)),
                SnippetPlaceholder(index: 1, range: NSRange(location: 4, length: 1))
            ],
            finalPosition: 5
        )
        XCTAssertThrowsError(try bounded.incorporatingUserTransaction(
            TextTransaction(edits: [TextEdit(from: 0, to: 1, insert: "z")]),
            in: "a a a", maximumMirrorEdits: 1
        )) { error in
            XCTAssertEqual(
                error as? SnippetSessionError,
                .mirrorLimitExceeded(actual: 2, maximum: 1)
            )
        }
    }
}
