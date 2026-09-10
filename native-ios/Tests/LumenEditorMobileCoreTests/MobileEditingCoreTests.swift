import XCTest
@testable import LumenEditorMobileCore

final class MobileEditingCoreTests: XCTestCase {
    func testCursorStatusUsesUIKitUTF16Coordinates() {
        let status = MobileEditingCore.cursorStatus(
            in: "😀 first\n第二行x", selection: NSRange(location: 10, length: 3)
        )
        XCTAssertEqual(status, MobileCursorStatus(
            line: 2, column: 2, utf16Offset: 10, selectionLength: 3
        ))
    }

    func testCursorStatusFallsBackToConstantTimeOffsetBeyondScanLimit() {
        let status = MobileEditingCore.cursorStatus(
            in: "one\ntwo", selection: NSRange(location: 6, length: 1),
            maximumScannedUTF16Length: 4, knownUTF16Length: 7
        )
        XCTAssertEqual(status, MobileCursorStatus(
            line: nil, column: nil, utf16Offset: 6, selectionLength: 1
        ))
    }

    func testIndentSelectionDoesNotIndentTrailingUnselectedLine() {
        let result = MobileEditingCore.indent(
            "one\ntwo\nthree", selection: NSRange(location: 0, length: 8), unit: "  "
        )
        XCTAssertEqual(result.text, "  one\n  two\nthree")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 12))
    }

    func testOutdentHandlesTabsSpacesAndSelectionOffsets() {
        let result = MobileEditingCore.outdent(
            "\tone\n    two\nthree", selection: NSRange(location: 1, length: 12)
        )
        XCTAssertEqual(result.text, "one\ntwo\nthree")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 8))
    }

    func testDuplicateLastLinePreservesRelativeUTF16Selection() {
        let result = MobileEditingCore.duplicateLines(
            "first\n😀 last", selection: NSRange(location: 8, length: 2)
        )
        XCTAssertEqual(result.text, "first\n😀 last\n😀 last")
        XCTAssertEqual(result.selection, NSRange(location: 16, length: 2))
    }

    func testIndentAtCaretInsertsSpacesWithoutBreakingEmojiOffset() {
        let result = MobileEditingCore.indent(
            "😀x", selection: NSRange(location: 2, length: 0)
        )
        XCTAssertEqual(result.text, "😀    x")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testIndentSelectionStartingMidLineKeepsSelectedCharactersSelected() {
        let result = MobileEditingCore.indent(
            "one\ntwo", selection: NSRange(location: 1, length: 5), unit: "  "
        )
        XCTAssertEqual(result.text, "  one\n  two")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 7))
    }

    func testOutdentCaretInsideIndentPreservesLogicalPosition() {
        let result = MobileEditingCore.outdent(
            "    one", selection: NSRange(location: 2, length: 0)
        )
        XCTAssertEqual(result.text, "one")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    func testDuplicateMiddleLineKeepsFollowingText() {
        let result = MobileEditingCore.duplicateLines(
            "one\ntwo\nthree", selection: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(result.text, "one\ntwo\ntwo\nthree")
        XCTAssertEqual(result.selection, NSRange(location: 9, length: 0))
    }

    func testDuplicateEmptyDocumentIsNoOp() {
        let result = MobileEditingCore.duplicateLines(
            "", selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(result, MobileEditResult(
            text: "", selection: NSRange(location: 0, length: 0)
        ))
    }
}
