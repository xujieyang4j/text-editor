import Foundation
import XCTest
@testable import LumenEditorCore

final class IncrementalDiffTests: XCTestCase {
    func testClassifiesAddedModifiedAndDeletedHunksInCurrentCoordinates() throws {
        let result = try IncrementalDiff.compare(
            baseline: "one\ntwo\nthree\nfour\nsix",
            current: "zero\none\nTWO\nthree\nsix"
        )

        XCTAssertEqual(result.hunks, [
            IncrementalDiffHunk(
                kind: .added, baselineStartLine: 1, currentStartLine: 1,
                baselineLines: [], currentLines: ["zero"]
            ),
            IncrementalDiffHunk(
                kind: .modified, baselineStartLine: 2, currentStartLine: 3,
                baselineLines: ["two"], currentLines: ["TWO"]
            ),
            IncrementalDiffHunk(
                kind: .deleted, baselineStartLine: 4, currentStartLine: 5,
                baselineLines: ["four"], currentLines: []
            )
        ])
        XCTAssertEqual(result.markers, [
            IncrementalDiffMarker(kind: .added, line: 1, lineCount: 1),
            IncrementalDiffMarker(kind: .modified, line: 3, lineCount: 1),
            IncrementalDiffMarker(kind: .deleted, line: 5, lineCount: 1)
        ])
    }

    func testEmptyDocumentsAndFinalNewlineRemainDistinct() throws {
        let insertion = try IncrementalDiff.compare(baseline: "", current: "text")
        XCTAssertEqual(insertion.hunks.first?.kind, .added)
        XCTAssertEqual(insertion.hunks.first?.currentStartLine, 1)

        let appendNewline = try IncrementalDiff.compare(
            baseline: "text", current: "text\n"
        )
        XCTAssertEqual(appendNewline.hunks.first?.currentStartLine, 2)
        XCTAssertEqual(appendNewline.hunks.first?.currentLines, [""])
        XCTAssertEqual(
            try IncrementalDiff.reverting(
                XCTUnwrap(appendNewline.hunks.first), in: "text\n"
            ),
            "text"
        )

        let removeNewline = try IncrementalDiff.compare(
            baseline: "text\n", current: "text"
        )
        XCTAssertEqual(removeNewline.hunks.first?.kind, .deleted)
        XCTAssertEqual(removeNewline.hunks.first?.currentStartLine, 2)
        XCTAssertEqual(removeNewline.markers, [
            IncrementalDiffMarker(kind: .deleted, line: 1, lineCount: 1)
        ])
        XCTAssertEqual(
            try IncrementalDiff.reverting(
                XCTUnwrap(removeNewline.hunks.first), in: "text"
            ),
            "text\n"
        )
    }

    func testNavigationUsesStrictLinesAndWraps() throws {
        let result = try IncrementalDiff.compare(
            baseline: "a\nb\nc\nd\ne",
            current: "A\nb\nc\nD\ne"
        )

        XCTAssertEqual(result.hunk(from: 1, direction: .next)?.currentStartLine, 4)
        XCTAssertEqual(result.hunk(from: 4, direction: .next)?.currentStartLine, 1)
        XCTAssertEqual(result.hunk(from: 4, direction: .previous)?.currentStartLine, 1)
        XCTAssertEqual(result.hunk(from: 1, direction: .previous)?.currentStartLine, 4)
        XCTAssertEqual(result.currentHunk(at: 4)?.currentStartLine, 4)
        XCTAssertEqual(result.currentHunk(at: 3)?.currentStartLine, 1)
    }

    func testRevertTransactionUsesUTF16OffsetsMapsSelectionAndPinsRevision() throws {
        let current = "🙂 alpha\nNEW\nomega"
        let result = try IncrementalDiff.compare(
            baseline: "🙂 alpha\nold\nomega", current: current
        )
        let hunk = try XCTUnwrap(result.hunks.first)
        let originalSelection = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 0, head: 2),
                DirectedSelection(anchor: current.utf16.count, head: current.utf16.count)
            ],
            mainIndex: 1
        )

        let transaction = try IncrementalDiff.revertTransaction(
            current: current, hunk: hunk, selection: originalSelection,
            expectedRevision: 41
        )

        XCTAssertEqual(transaction.expectedRevision, 41)
        XCTAssertEqual(transaction.edits, [
            TextEdit(
                from: "🙂 alpha\n".utf16.count,
                to: "🙂 alpha\nNEW".utf16.count,
                insert: "old"
            )
        ])
        XCTAssertEqual(try transaction.applying(to: current), "🙂 alpha\nold\nomega")
        XCTAssertEqual(transaction.selection?.ranges[0], originalSelection.ranges[0])
        XCTAssertEqual(
            transaction.selection?.main.head,
            "🙂 alpha\nold\nomega".utf16.count
        )
    }

    func testRevertRejectsAHunkFromAnOlderCurrentText() throws {
        let result = try IncrementalDiff.compare(baseline: "a\nb", current: "a\nB")
        let hunk = try XCTUnwrap(result.hunks.first)

        XCTAssertThrowsError(try IncrementalDiff.reverting(hunk, in: "a\nnew B")) { error in
            XCTAssertEqual(error as? IncrementalDiffError, .staleHunk)
        }
    }

    func testLineConversionsUseUTF16AndClamp() {
        let text = "🙂 one\ntwo\nthree"
        XCTAssertEqual(IncrementalDiff.lineNumber(atUTF16Offset: 1, in: text), 1)
        XCTAssertEqual(
            IncrementalDiff.lineNumber(
                atUTF16Offset: "🙂 one\n".utf16.count, in: text
            ),
            2
        )
        XCTAssertEqual(IncrementalDiff.utf16Offset(forLine: 2, in: text), 7)
        XCTAssertEqual(
            IncrementalDiff.lineAndColumn(atUTF16Offset: 1, in: text).column,
            2
        )
        XCTAssertEqual(
            IncrementalDiff.utf16Offset(forLine: 99, in: text),
            text.utf16.count
        )
    }

    func testCanonicallyEquivalentButByteDistinctLinesAreModified() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)

        let result = try IncrementalDiff.compare(
            baseline: composed, current: decomposed
        )

        XCTAssertEqual(result.hunks.count, 1)
        XCTAssertEqual(result.hunks.first?.kind, .modified)
        XCTAssertFalse(IncrementalDiff.exactlyEqual(composed, decomposed))
    }

    func testEveryExpensiveDimensionIsBoundedBeforeDiffing() {
        XCTAssertThrowsError(try IncrementalDiff.compare(
            baseline: "123", current: "",
            limits: IncrementalDiffLimits(maximumTextUTF16Length: 2)
        )) { error in
            XCTAssertEqual(
                error as? IncrementalDiffError,
                .textTooLarge(side: .baseline, actual: 3, maximum: 2)
            )
        }

        XCTAssertThrowsError(try IncrementalDiff.compare(
            baseline: "a\nb", current: "",
            limits: IncrementalDiffLimits(
                maximumTextUTF16Length: 100, maximumLineCount: 1
            )
        )) { error in
            XCTAssertEqual(
                error as? IncrementalDiffError,
                .tooManyLines(side: .baseline, actual: 2, maximum: 1)
            )
        }

        XCTAssertThrowsError(try IncrementalDiff.compare(
            baseline: "a\nb", current: "c\nd",
            limits: IncrementalDiffLimits(
                maximumTextUTF16Length: 100, maximumLineCount: 10,
                maximumMatrixCellCount: 8
            )
        )) { error in
            XCTAssertEqual(
                error as? IncrementalDiffError,
                .matrixTooLarge(actual: 9, maximum: 8)
            )
        }

        XCTAssertThrowsError(try IncrementalDiff.compare(
            baseline: "a\nb\nc", current: "A\nb\nC",
            limits: IncrementalDiffLimits(
                maximumTextUTF16Length: 100, maximumLineCount: 10,
                maximumMatrixCellCount: 100, maximumHunkCount: 1
            )
        )) { error in
            XCTAssertEqual(
                error as? IncrementalDiffError,
                .tooManyHunks(actual: 2, maximum: 1)
            )
        }
    }
}
