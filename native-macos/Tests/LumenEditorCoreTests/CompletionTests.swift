import Foundation
import XCTest
@testable import LumenEditorCore

final class CompletionTests: XCTestCase {
    func testQueryMatchesElectronASCIIWordTokenUsingUTF16Offsets() {
        let text = "😀 value_$2"
        let query = CompletionPlanner.query(
            documentID: "doc", viewID: "pane", revision: 4,
            text: text, cursorUTF16Offset: text.utf16.count
        )

        XCTAssertEqual(query?.token, "value_$2")
        XCTAssertEqual(query?.tokenRange, NSRange(location: 3, length: 8))
        XCTAssertEqual(query?.cursorUTF16Offset, 11)
    }

    func testQueryRequiresTwoCharactersAndRejectsInvalidStart() {
        XCTAssertNil(CompletionPlanner.query(
            documentID: "doc", viewID: "pane", revision: 0,
            text: "a", cursorUTF16Offset: 1
        ))
        XCTAssertNil(CompletionPlanner.query(
            documentID: "doc", viewID: "pane", revision: 0,
            text: "1a", cursorUTF16Offset: 2
        ))
        XCTAssertEqual(CompletionPlanner.query(
            documentID: "doc", viewID: "pane", revision: 0,
            text: "$a", cursorUTF16Offset: 2
        )?.token, "$a")
    }

    func testWordScannerMatchesElectronLengthAndCharacterRules() {
        let eightyOne = "a" + String(repeating: "b", count: 80)
        let tooLong = "c" + String(repeating: "d", count: 81)
        let words = CompletionPlanner.words(
            in: "a ab _x $y A1 \(eightyOne) \(tooLong) éz"
        )

        XCTAssertTrue(words.contains("ab"))
        XCTAssertTrue(words.contains("_x"))
        XCTAssertTrue(words.contains("$y"))
        XCTAssertTrue(words.contains("A1"))
        XCTAssertTrue(words.contains(eightyOne))
        XCTAssertFalse(words.contains(tooLong))
        XCTAssertFalse(words.contains("a"))
        XCTAssertFalse(words.contains("éz"))
    }

    func testWorkspaceFallbackUsesElectronSourceOrderDedupSortAndLimits() {
        let open = (0..<350).map { String(format: "pre%03d", $0) }.joined(separator: " " )
        let suggestions = CompletionPlanner.workspaceSuggestions(
            token: "pr",
            openBufferTexts: ["private prefix prefix", open],
            workspaceWords: ["protocol", "prefix", "other"],
            currentText: "print property"
        )

        XCTAssertEqual(suggestions.count, CompletionPlanner.maximumDisplayedSuggestions)
        XCTAssertEqual(suggestions.map(\.label), suggestions.map(\.label).sorted())
        XCTAssertEqual(Set(suggestions.map(\.label)).count, suggestions.count)
        XCTAssertTrue(suggestions.allSatisfy {
            $0.label.lowercased().hasPrefix("pr") && $0.source == .workspaceWord
        })
    }

    func testLanguageServerSuggestionsPreserveMetadataAndLimit() {
        let items = (0..<150).map { index in
            LanguageCompletionItem(
                label: "item\(index)", detail: "detail",
                documentation: "docs", insertText: "insert\(index)"
            )
        }
        let suggestions = CompletionPlanner.languageServerSuggestions(items)

        XCTAssertEqual(suggestions.count, CompletionPlanner.maximumDisplayedSuggestions)
        XCTAssertEqual(suggestions.first?.label, "item0")
        XCTAssertEqual(suggestions.first?.insertionText, "insert0")
        XCTAssertEqual(suggestions.first?.source, .languageServer)
    }

    func testInsertionIsOneRevisionPinnedTokenReplacement() throws {
        let query = try XCTUnwrap(CompletionPlanner.query(
            documentID: "doc", viewID: "pane", revision: 9,
            text: "let pri = 1", cursorUTF16Offset: 7
        ))
        let suggestion = CompletionSuggestion(
            id: "lsp:0:print", label: "print", detail: "function",
            insertionText: "print()", source: .languageServer
        )
        let transaction = try XCTUnwrap(CompletionPlanner.insertionTransaction(
            suggestion: suggestion, query: query
        ))

        XCTAssertEqual(transaction.expectedRevision, 9)
        XCTAssertEqual(transaction.edits, [TextEdit(from: 4, to: 7, insert: "print()")])
        XCTAssertEqual(transaction.selection, .cursor(at: 11))
        XCTAssertEqual(try transaction.applying(to: query.text), "let print() = 1")
    }
}
