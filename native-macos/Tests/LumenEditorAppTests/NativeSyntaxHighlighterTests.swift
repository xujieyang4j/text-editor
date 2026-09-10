import Foundation
import XCTest
@testable import LumenEditorApp

final class NativeSyntaxHighlighterTests: XCTestCase {
    func testSwiftTokensUseUTF16RangesAndIgnoreKeywordsInsideStringsAndComments() {
        let source = "let emoji = \"🙂 if\" // return\nreturn 42"
        let plan = NativeSyntaxHighlighter.plan(
            text: source, language: "Swift",
            visibleRange: NSRange(location: 0, length: source.utf16.count)
        )
        let tokens = plan.spans.map { span in
            ((source as NSString).substring(with: span.range), span.kind)
        }

        XCTAssertTrue(tokens.contains { $0.0 == "let" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "\"🙂 if\"" && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "// return" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "return" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "42" && $0.1 == .number })
        XCTAssertEqual(tokens.filter { $0.0 == "if" }.count, 0)
    }

    func testPlainTextProducesNoSpansAndMarkupRecognizesTagsAndAttributes() {
        XCTAssertTrue(NativeSyntaxHighlighter.plan(
            text: "let x = 1", language: "Plain Text",
            visibleRange: NSRange(location: 0, length: 9)
        ).spans.isEmpty)

        let source = "<!-- note --><p title=\"hi\">value</p>"
        let plan = NativeSyntaxHighlighter.plan(
            text: source, language: "HTML",
            visibleRange: NSRange(location: 0, length: source.utf16.count)
        )
        XCTAssertTrue(plan.spans.contains {
            $0.kind == .comment && (source as NSString).substring(with: $0.range) == "<!-- note -->"
        })
        XCTAssertTrue(plan.spans.contains {
            $0.kind == .string && (source as NSString).substring(with: $0.range) == "\"hi\""
        })
    }

    func testWorkIsBoundedAndReturnedSpansStayInsideVisibleRange() {
        let source = String(repeating: "let value = 123 // comment\n", count: 50_000)
        let visible = NSRange(location: source.utf16.count - 500, length: 400)
        let plan = NativeSyntaxHighlighter.plan(
            text: source, language: "JavaScript", visibleRange: visible
        )

        XCTAssertLessThanOrEqual(plan.scannedRange.length, NativeSyntaxHighlighter.maximumScanUTF16Length)
        XCTAssertLessThanOrEqual(plan.spans.count, NativeSyntaxHighlighter.maximumSpans)
        XCTAssertTrue(plan.spans.allSatisfy {
            NSIntersectionRange($0.range, visible) == $0.range
        })
    }

    func testRubyProfileHighlightsKeywordsConstantsAndComments() {
        let source = "class Greeter\n  def run\n    true # end\n  end\nend"
        let plan = NativeSyntaxHighlighter.plan(
            text: source, language: "rb",
            visibleRange: NSRange(location: 0, length: source.utf16.count)
        )
        let tokens = plan.spans.map { span in
            ((source as NSString).substring(with: span.range), span.kind)
        }

        XCTAssertTrue(tokens.contains { $0.0 == "class" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "def" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "true" && $0.1 == .constant })
        XCTAssertTrue(tokens.contains { $0.0 == "# end" && $0.1 == .comment })
    }

    func testPythonAndRProfilesRecognizeCommonTokens() {
        let python = "def run(value: str) -> None:\n    return True"
        let pythonPlan = NativeSyntaxHighlighter.plan(
            text: python, language: "py",
            visibleRange: NSRange(location: 0, length: python.utf16.count)
        )
        let pythonTokens = pythonPlan.spans.map { span in
            ((python as NSString).substring(with: span.range), span.kind)
        }
        XCTAssertTrue(pythonTokens.contains { $0.0 == "def" && $0.1 == .keyword })
        XCTAssertTrue(pythonTokens.contains { $0.0 == "str" && $0.1 == .type })
        XCTAssertTrue(pythonTokens.contains { $0.0 == "None" && $0.1 == .constant })

        let r = "if (TRUE) {\n  value <- NA\n}\n# done"
        let rPlan = NativeSyntaxHighlighter.plan(
            text: r, language: "R",
            visibleRange: NSRange(location: 0, length: r.utf16.count)
        )
        let rTokens = rPlan.spans.map { span in
            ((r as NSString).substring(with: span.range), span.kind)
        }
        XCTAssertTrue(rTokens.contains { $0.0 == "if" && $0.1 == .keyword })
        XCTAssertTrue(rTokens.contains { $0.0 == "TRUE" && $0.1 == .constant })
        XCTAssertTrue(rTokens.contains { $0.0 == "NA" && $0.1 == .constant })
        XCTAssertTrue(rTokens.contains { $0.0 == "# done" && $0.1 == .comment })
    }

    func testExactParserSnapshotWinsAndStaleOrTruncatedSnapshotFallsBack() {
        let source = "return value"
        let parsed = NativeSyntaxHighlighter.ParsedSnapshot(
            sourceUTF16Length: source.utf16.count, documentID: "document",
            language: "JavaScript",
            documentRevision: 7,
            spans: [.init(range: NSRange(location: 7, length: 5), kind: .type)],
            wasTruncated: false
        )
        let exact = NativeSyntaxHighlighter.plan(
            text: source, language: "JavaScript",
            visibleRange: NSRange(location: 0, length: source.utf16.count),
            documentID: "document", documentRevision: 7, parsedSnapshot: parsed
        )
        XCTAssertEqual(exact.spans, parsed.spans)

        let stale = NativeSyntaxHighlighter.plan(
            text: source, language: "JavaScript",
            visibleRange: NSRange(location: 0, length: source.utf16.count),
            documentID: "document", documentRevision: 8, parsedSnapshot: parsed
        )
        XCTAssertTrue(stale.spans.contains { $0.kind == .keyword && $0.range.location == 0 })

        let truncated = NativeSyntaxHighlighter.ParsedSnapshot(
            sourceUTF16Length: source.utf16.count, documentID: "document",
            language: "JavaScript",
            documentRevision: 7, spans: parsed.spans, wasTruncated: true
        )
        XCTAssertTrue(NativeSyntaxHighlighter.plan(
            text: source, language: "JavaScript",
            visibleRange: NSRange(location: 0, length: source.utf16.count),
            documentID: "document", documentRevision: 7, parsedSnapshot: truncated
        ).spans.contains { $0.kind == .keyword && $0.range.location == 0 })
    }
}
