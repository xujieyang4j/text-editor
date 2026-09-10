import Foundation
import XCTest
@testable import LumenEditorCore

final class FindCoreTests: XCTestCase {
    func testLiteralSearchUsesUTF16OffsetsAndElectronEscapes() throws {
        let source = "🙂 one\none two ONE"
        let newlineQuery = FindQuery(search: #"one\none"#)
        XCTAssertEqual(
            try FindCore.matches(in: source, query: newlineQuery).map(\.range),
            [NSRange(location: 3, length: 7)]
        )

        let emoji = try FindCore.matches(
            in: source,
            query: FindQuery(search: "🙂", options: FindOptions(isCaseSensitive: true))
        )
        XCTAssertEqual(emoji.map(\.range), [NSRange(location: 0, length: 2)])
    }

    func testCaseSensitivityAndWholeWordMatchCodeMirrorBoundaries() throws {
        let source = "cat scatter CAT _cat cat_ 猫猫 猫"
        XCTAssertEqual(
            try FindCore.matches(
                in: source,
                query: FindQuery(search: "cat", options: FindOptions(isWholeWord: true))
            ).map(\.range),
            [NSRange(location: 0, length: 3), NSRange(location: 12, length: 3)]
        )
        XCTAssertEqual(
            try FindCore.matches(
                in: source,
                query: FindQuery(
                    search: "CAT",
                    options: FindOptions(isCaseSensitive: true, isWholeWord: true)
                )
            ).map(\.range),
            [NSRange(location: 12, length: 3)]
        )
        XCTAssertEqual(
            try FindCore.matches(
                in: source,
                query: FindQuery(search: "猫", options: FindOptions(isWholeWord: true))
            ).map(\.range),
            [NSRange(location: 29, length: 1)]
        )
    }

    func testNextPreviousWrapAndSkipCurrentMatch() throws {
        let text = "one two one"
        let query = FindQuery(search: "one")
        XCTAssertEqual(
            try FindCore.nextMatch(
                in: text, query: query, selection: NSRange(location: 0, length: 3)
            )?.range,
            NSRange(location: 8, length: 3)
        )
        XCTAssertEqual(
            try FindCore.nextMatch(
                in: text, query: query, selection: NSRange(location: 8, length: 3)
            )?.range,
            NSRange(location: 0, length: 3)
        )
        XCTAssertEqual(
            try FindCore.previousMatch(
                in: text, query: query, selection: NSRange(location: 0, length: 3)
            )?.range,
            NSRange(location: 8, length: 3)
        )
        XCTAssertNil(try FindCore.nextMatch(
            in: "one", query: query, selection: NSRange(location: 0, length: 3)
        ))
    }

    func testRegularExpressionCapturesAndReplacementSyntax() throws {
        let text = "item-12 next-7"
        let query = FindQuery(
            search: #"([a-z]+)-(\d+)"#,
            replacement: #"$2:$1:$&:$$:$99"#,
            options: FindOptions(isCaseSensitive: true, usesRegularExpression: true)
        )
        let matches = try FindCore.matches(in: text, query: query)
        XCTAssertEqual(matches.map(\.range), [
            NSRange(location: 0, length: 7),
            NSRange(location: 8, length: 6)
        ])
        XCTAssertEqual(
            FindCore.replacementText(for: matches[0], in: text, query: query),
            "12:item:item-12:$:$99"
        )
    }

    func testRegexWholeWordChecksOnlyWordEdges() throws {
        XCTAssertEqual(
            try FindCore.matches(
                in: "x- -y",
                query: FindQuery(
                    search: "-",
                    options: FindOptions(isWholeWord: true, usesRegularExpression: true)
                )
            ).map(\.range),
            [NSRange(location: 1, length: 1), NSRange(location: 3, length: 1)]
        )
    }

    func testInvalidRegexAndBoundedZeroWidthSearchAreSafe() throws {
        XCTAssertThrowsError(try FindCore.scan(
            "text",
            query: FindQuery(
                search: "[",
                options: FindOptions(usesRegularExpression: true)
            )
        )) { error in
            guard case FindCoreError.invalidRegularExpression = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let result = try FindCore.scan(
            "abc",
            query: FindQuery(
                search: "(?=.)",
                options: FindOptions(usesRegularExpression: true)
            ),
            limit: 2
        )
        XCTAssertEqual(result.matches.map(\.range), [
            NSRange(location: 0, length: 0),
            NSRange(location: 1, length: 0)
        ])
        XCTAssertTrue(result.isTruncated)

        let bounded = try FindCore.scan(
            "a a a", query: FindQuery(search: "a"), limit: 2
        )
        XCTAssertEqual(bounded.matches.count, 2)
        XCTAssertTrue(bounded.isTruncated)
    }

    func testLiteralBackslashEscapesAndReplacementPlan() throws {
        let text = "a\tb a\tb"
        let query = FindQuery(search: #"a\tb"#, replacement: #"x\ny"#)
        let replacements = try FindCore.replacements(in: text, query: query)
        XCTAssertEqual(replacements.map { $0.match.range }, [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ])
        XCTAssertEqual(replacements.map(\.replacement), ["x\ny", "x\ny"])
    }
}
