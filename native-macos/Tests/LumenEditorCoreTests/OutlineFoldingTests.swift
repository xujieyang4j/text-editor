import Foundation
import XCTest
@testable import LumenEditorCore

final class OutlineFoldingTests: XCTestCase {
    func testOutlineMatchesElectronSymbolsAndUTF16Offsets() {
        let source = "🙂\nclass App {\n  run() {\n  }\n}\n# Heading"
        let model = OutlineFoldingAnalyzer.analyze(
            text: source, language: "JavaScript"
        )

        XCTAssertEqual(model.symbols.map(\.label), ["App", "run", "# Heading"])
        XCTAssertEqual(model.symbols.map(\.line), [2, 3, 6])
        XCTAssertEqual(model.symbols.first?.utf16Offset, 3)
        XCTAssertEqual(model.symbols.map(\.kind), [.type, .method, .heading])
        XCTAssertFalse(model.sourceWasTruncated)
    }

    func testBraceFoldsIgnoreStringsAndCommentsAndPreferInnermostAtCursor() throws {
        let source = """
        function outer() {
          const ignored = "{ not a block }"
          // { ignored too
          if (ready) {
            work()
          }
        }
        """
        let model = OutlineFoldingAnalyzer.analyze(
            text: source, language: "JavaScript"
        )

        XCTAssertEqual(model.foldRegions.count, 2)
        let inner = try XCTUnwrap(model.foldRegions.first { $0.startLine == 4 })
        let cursor = (source as NSString).range(of: "work()").location
        XCTAssertEqual(
            OutlineFoldingAnalyzer.foldRegion(
                in: model.foldRegions, atUTF16Offset: cursor
            ),
            inner
        )
        XCTAssertEqual(
            (source as NSString).substring(with: inner.hiddenRange),
            "    work()\n  }\n"
        )
    }

    func testPythonIndentationCreatesNestedRegions() throws {
        let source = """
        def outer():
            if ready:
                work()
            finish()
        after()
        """
        let model = OutlineFoldingAnalyzer.analyze(text: source, language: "Python")

        XCTAssertEqual(model.foldRegions.count, 2)
        let outer = try XCTUnwrap(model.foldRegions.first { $0.startLine == 1 })
        let inner = try XCTUnwrap(model.foldRegions.first { $0.startLine == 2 })
        XCTAssertEqual(outer.endLine, 4)
        XCTAssertEqual(inner.endLine, 3)
        XCTAssertTrue(outer.fullRange.length > inner.fullRange.length)
    }

    func testMarkdownFoldsStopAtSameOrHigherHeading() throws {
        let source = """
        # One
        intro
        ## Child
        child body
        # Two
        final
        """
        let model = OutlineFoldingAnalyzer.analyze(text: source, language: "Markdown")

        let first = try XCTUnwrap(model.foldRegions.first { $0.startLine == 1 })
        let child = try XCTUnwrap(model.foldRegions.first { $0.startLine == 3 })
        XCTAssertEqual(first.endLine, 4)
        XCTAssertEqual(child.endLine, 4)
        XCTAssertEqual(model.symbols.map(\.level), [0, 1, 0])
    }

    func testBoundsAreUTF16SafeAndReportTruncation() {
        let source = "🙂\n# One\n# Two\n# Three"
        let model = OutlineFoldingAnalyzer.analyze(
            text: source,
            language: "Markdown",
            limits: OutlineLimits(
                maximumSourceUTF16Count: 14,
                maximumSymbols: 1,
                maximumFoldRegions: 1,
                maximumNestingDepth: 8
            )
        )

        XCTAssertTrue(model.sourceWasTruncated)
        XCTAssertEqual(model.symbols.count, 1)
        XCTAssertTrue(model.symbolsWereTruncated)
        XCTAssertLessThanOrEqual(
            model.foldRegions.first.map { NSMaxRange($0.fullRange) } ?? 0,
            14
        )
    }

    func testFoldingStateIsViewLocalAndProducesNonOverlappingTextKitRanges() {
        let source = """
        function outer() {
          if (ready) {
            work()
          }
        }
        """
        let regions = OutlineFoldingAnalyzer.analyze(
            text: source, language: "JavaScript"
        ).foldRegions
        let cursor = (source as NSString).range(of: "work()").location
        var left = TextFoldingState(regions: regions)
        var right = TextFoldingState(regions: regions)

        XCTAssertTrue(left.foldAll())
        XCTAssertEqual(left.foldedRegionIDs.count, 2)
        XCTAssertEqual(left.textKitHiddenRanges.count, 1)
        XCTAssertTrue(left.unfoldCurrent(atUTF16Offset: cursor))
        XCTAssertEqual(left.foldedRegionIDs.count, 1)
        XCTAssertEqual(left.textKitHiddenRanges.count, 1)
        XCTAssertTrue(right.foldCurrent(atUTF16Offset: cursor))
        XCTAssertEqual(right.foldedRegionIDs.count, 1)
        XCTAssertNotEqual(left, right)
        XCTAssertTrue(right.unfoldCurrent(atUTF16Offset: cursor))
        XCTAssertFalse(right.unfoldCurrent(atUTF16Offset: cursor))
    }

    func testUpdatingRegionsDropsStaleFoldIdentifiers() {
        let first = OutlineFoldingAnalyzer.analyze(
            text: "if (a) {\n  work()\n}\n", language: "JavaScript"
        )
        let second = OutlineFoldingAnalyzer.analyze(
            text: "plain\ntext\n", language: "Plain Text"
        )
        var state = TextFoldingState(regions: first.foldRegions)
        XCTAssertTrue(state.foldAll())

        state.update(regions: second.foldRegions)

        XCTAssertTrue(state.foldedRegionIDs.isEmpty)
        XCTAssertTrue(state.textKitHiddenRanges.isEmpty)
    }

    func testBraceDepthLimitDoesNotPairIgnoredNestedCloserWithTrackedParent() {
        let source = """
        if (outer) {
          if (ignored) {
            work()
          }
        }
        """
        let model = OutlineFoldingAnalyzer.analyze(
            text: source,
            language: "JavaScript",
            limits: OutlineLimits(
                maximumSourceUTF16Count: 1_000,
                maximumSymbols: 100,
                maximumFoldRegions: 100,
                maximumNestingDepth: 1
            )
        )

        XCTAssertEqual(model.foldRegions.count, 1)
        XCTAssertEqual(model.foldRegions.first?.startLine, 1)
        XCTAssertEqual(model.foldRegions.first?.endLine, 5)
    }

    func testUnterminatedSingleQuotedStringDoesNotPoisonLaterLines() {
        let source = """
        let bad = "unterminated
        if (ready) {
          work()
        }
        """
        let model = OutlineFoldingAnalyzer.analyze(
            text: source, language: "JavaScript"
        )

        XCTAssertEqual(model.foldRegions.count, 1)
        XCTAssertEqual(model.foldRegions.first?.startLine, 2)
    }

    func testRubyKeywordFoldsCoverClassDefAndDoEnd() throws {
        let source = """
        class Greeter
          def run
            items.each do |item|
              puts item
            end
          end
        end
        """
        let model = OutlineFoldingAnalyzer.analyze(text: source, language: "Ruby")

        XCTAssertEqual(model.foldRegions.count, 3)
        XCTAssertEqual(
            Set(model.foldRegions.map { "\($0.startLine):\($0.endLine)" }),
            Set(["1:7", "2:6", "3:5"])
        )
    }

    func testRubyAndHashCommentBraceFoldsIgnorePseudoBraces() throws {
        let source = """
        def render
          template = "{ not a block }"
          # { ignored too
          values.each do |value|
            puts(value)
          end
        end
        """
        let model = OutlineFoldingAnalyzer.analyze(text: source, language: "Ruby")

        XCTAssertEqual(model.foldRegions.count, 2)
        XCTAssertEqual(
            Set(model.foldRegions.map { "\($0.startLine):\($0.endLine)" }),
            Set(["1:7", "4:6"])
        )
    }

    func testRubyKeywordDepthLimitDoesNotCloseTrackedParentWithIgnoredEnd() {
        let source = """
        class Outer
          def inner
            work
          end
        end
        """
        let model = OutlineFoldingAnalyzer.analyze(
            text: source,
            language: "Ruby",
            limits: OutlineLimits(
                maximumSourceUTF16Count: 1_000,
                maximumSymbols: 100,
                maximumFoldRegions: 100,
                maximumNestingDepth: 1
            )
        )

        XCTAssertEqual(model.foldRegions.count, 1)
        XCTAssertEqual(model.foldRegions.first?.startLine, 1)
        XCTAssertEqual(model.foldRegions.first?.endLine, 5)
    }

    func testRubyElseAndElsifBranchesDoNotConsumeKeywordNesting() {
        let source = """
        if first
          one
        elsif second
          two
        else
          three
        end
        """
        let model = OutlineFoldingAnalyzer.analyze(text: source, language: "Ruby")

        XCTAssertEqual(model.foldRegions.count, 1)
        XCTAssertEqual(model.foldRegions.first?.startLine, 1)
        XCTAssertEqual(model.foldRegions.first?.endLine, 7)
    }
}
