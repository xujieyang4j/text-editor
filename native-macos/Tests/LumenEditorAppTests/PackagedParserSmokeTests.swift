import XCTest
@testable import LumenEditorApp

final class PackagedParserSmokeTests: XCTestCase {
    func testValidationRequiresBothParserKindsAndExpectedPayloads() {
        let javascriptText = "😀 const value = 1\n"
        let swiftText = "func run() {\n  let value = 1\n}\n"
        let javascript = analysis(
            text: javascriptText, language: "JavaScript", parserKind: .lezer,
            highlights: [.init(from: 3, to: 8, kind: .keyword)],
            indentationCount: 1
        )
        let swift = analysis(
            text: swiftText, language: "Swift", parserKind: .stream,
            highlights: [.init(from: 0, to: 4, kind: .keyword)],
            indentationCount: 4
        )

        XCTAssertTrue(PackagedParserSmoke.validate(
            javascript: javascript, javascriptText: javascriptText,
            swift: swift, swiftText: swiftText
        ))
        XCTAssertFalse(PackagedParserSmoke.validate(
            javascript: nil, javascriptText: javascriptText,
            swift: swift, swiftText: swiftText
        ))
        XCTAssertFalse(PackagedParserSmoke.validate(
            javascript: javascript, javascriptText: javascriptText + "x",
            swift: swift, swiftText: swiftText
        ))
    }

    private func analysis(
        text: String, language: String,
        parserKind: CodeMirrorParserResult.ParserKind,
        highlights: [CodeMirrorParserResult.Highlight],
        indentationCount: Int
    ) -> CodeMirrorParserAnalysis {
        CodeMirrorParserAnalysis(
            supported: true, parserKind: parserKind,
            requestedLanguage: language, resolvedLanguage: language,
            sourceUTF16Length: text.utf16.count, highlights: highlights,
            syntaxNodes: [], bracketPairs: [], folds: [], symbols: [],
            indentation: (0..<indentationCount).map {
                .init(lineFrom: $0, columns: 0)
            },
            truncated: .init(
                source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false,
                indentation: false
            )
        )
    }
}
