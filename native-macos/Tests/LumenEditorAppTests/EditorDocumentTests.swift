import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class EditorDocumentTests: XCTestCase {
    @MainActor
    func testDocumentBufferProvidesSharedTextAndIndependentSelections() throws {
        let document = EditorDocument(
            sessionDocumentID: "stable-document",
            fileURL: nil,
            displayName: "Draft",
            text: "hello",
            savedText: "",
            selectionSet: .cursor(at: 1)
        )
        try document.registerView("right", selection: .cursor(at: 4))

        XCTAssertTrue(try document.applyReplacingUTF16Range(
            NSRange(location: 1, length: 2),
            replacement: "ey",
            viewID: .default,
            selectionsAfter: .cursor(at: 3)
        ))

        XCTAssertEqual(document.sessionDocumentID, "stable-document")
        XCTAssertEqual(document.text, "heylo")
        XCTAssertEqual(document.selectionSet(for: .default), .cursor(at: 3))
        XCTAssertEqual(document.selectionSet(for: "right"), .cursor(at: 4))
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.text, "hello")
        XCTAssertEqual(document.selectionSet(for: .default), .cursor(at: 1))
        XCTAssertEqual(document.selectionSet(for: "right"), .cursor(at: 4))
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.text, "heylo")
    }

    @MainActor
    func testEncodingOnlyChangeMakesUnchangedTextDirty() {
        let document = makeCleanDocument()

        XCTAssertFalse(document.isDirty)

        document.chooseEncodingForSave(.utf16leNoBom)

        XCTAssertFalse(document.hasTextChanges)
        XCTAssertTrue(document.hasFormatChanges)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.encoding, .utf16leNoBom)
        XCTAssertEqual(document.savedEncoding, .utf8)
    }

    @MainActor
    func testLineEndingOnlyChangeMakesUnchangedTextDirty() {
        let document = makeCleanDocument()

        XCTAssertFalse(document.isDirty)

        document.chooseLineEndingForSave(.crlf)

        XCTAssertFalse(document.hasTextChanges)
        XCTAssertTrue(document.hasFormatChanges)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertEqual(document.savedLineEnding, .lf)
    }

    @MainActor
    func testEditorConfigEOLIsSuggestionAndDoesNotMarkDocumentDirty() {
        let document = makeCleanDocument()
        let config = ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf),
            sources: [URL(fileURLWithPath: "/tmp/.editorconfig")]
        )

        document.setEditorConfig(config)

        XCTAssertEqual(document.lineEnding, .lf)
        XCTAssertEqual(document.savedLineEnding, .lf)
        XCTAssertEqual(document.effectiveLineEnding, .crlf)
        XCTAssertFalse(document.isDirty)

        document.chooseLineEndingForSave(.cr)
        XCTAssertEqual(document.effectiveLineEnding, .cr)
        XCTAssertTrue(document.isDirty)
    }

    @MainActor
    func testSuccessfulConfiguredEOLSaveUpdatesDiskBaselineWithoutExplicitOverride() {
        let document = makeCleanDocument()
        let url = document.fileURL!
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))

        document.recordSuccessfulSave(
            to: url,
            text: document.text,
            encoding: document.encoding,
            lineEnding: document.effectiveLineEnding,
            startedEOLOverride: document.eolOverride,
            revision: "sha256:\(String(repeating: "a", count: 64))"
        )

        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertEqual(document.savedLineEnding, .crlf)
        XCTAssertNil(document.eolOverride)
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    private func makeCleanDocument() -> EditorDocument {
        EditorDocument(
            fileURL: URL(fileURLWithPath: "/tmp/example.txt"),
            displayName: "example.txt",
            text: "unchanged\n",
            savedText: "unchanged\n",
            encoding: .utf8,
            savedEncoding: .utf8,
            lineEnding: .lf,
            savedLineEnding: .lf
        )
    }
}
