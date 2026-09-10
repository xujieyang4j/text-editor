import XCTest
@testable import LumenEditorMobileCore

final class MobileFindCoreTests: XCTestCase {
    func testSearchUsesUIKitUTF16Offsets() throws {
        let text = "😀 alpha ALPHA"
        let query = MobileFindQuery(search: "alpha")
        let matches = try MobileFindCore.scan(text, query: query).matches
        XCTAssertEqual(matches.map(\.range), [
            NSRange(location: 3, length: 5),
            NSRange(location: 9, length: 5)
        ])
    }

    func testFindNextWrapsAndRegexReplacementUsesCaptures() throws {
        let text = "one=1 two=2"
        let query = MobileFindQuery(
            search: "([a-z]+)=([0-9]+)", replacement: "$2:$1",
            options: MobileFindOptions(isCaseSensitive: true, usesRegularExpression: true)
        )
        let match = try XCTUnwrap(MobileFindCore.match(
            in: text, query: query, selection: NSRange(location: 20, length: 0), direction: .next
        ))
        XCTAssertEqual(match.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(try MobileFindCore.replacingAll(in: text, query: query).text, "1:one 2:two")
    }

    func testZeroWidthReplacementIsRefused() throws {
        let query = MobileFindQuery(
            search: "^", replacement: "x",
            options: MobileFindOptions(usesRegularExpression: true)
        )
        XCTAssertThrowsError(try MobileFindCore.replacingAll(in: "hello", query: query)) { error in
            XCTAssertEqual(error as? MobileFindError, .zeroWidthReplacement)
        }
    }

    func testReplacementOutputIsRejectedBeforeConstructionExceedsLimit() throws {
        let query = MobileFindQuery(search: "a", replacement: "1234")
        let match = try XCTUnwrap(MobileFindCore.scan(
            "a a", query: query
        ).matches.first)
        XCTAssertThrowsError(try MobileFindCore.replacing(
            match, in: "a a", query: query, maximumOutputUTF16Length: 5
        )) { error in
            XCTAssertEqual(error as? MobileFindError, .replacementExceedsLimit)
        }
        XCTAssertThrowsError(try MobileFindCore.replacingAll(
            in: "a a", query: query, maximumOutputUTF16Length: 8
        )) { error in
            XCTAssertEqual(error as? MobileFindError, .replacementExceedsLimit)
        }
        XCTAssertEqual(try MobileFindCore.replacing(
            MobileFindMatch(range: NSRange(location: Int.max, length: 1)),
            in: "small", query: query, maximumOutputUTF16Length: 10
        ).text, "small")
        XCTAssertEqual(try MobileFindCore.replacingAll(
            in: "a a", query: query, maximumOutputUTF16Length: 9
        ).text, "1234 1234")
        XCTAssertEqual(try MobileFindCore.replacingAll(
            in: "untouched", query: query, maximumOutputUTF16Length: 0
        ).text, "untouched")
        let mixedQuery = MobileFindQuery(
            search: "(a)|(b+)", replacement: "$1xxx",
            options: MobileFindOptions(
                isCaseSensitive: true, usesRegularExpression: true
            )
        )
        XCTAssertEqual(try MobileFindCore.replacingAll(
            in: "abbbbbbbbbb", query: mixedQuery, maximumOutputUTF16Length: 7
        ).text, "axxxxxx")
        let captureExpansion = MobileFindQuery(
            search: "(.+)", replacement: "$&$&",
            options: MobileFindOptions(
                isCaseSensitive: true, usesRegularExpression: true
            )
        )
        XCTAssertThrowsError(try MobileFindCore.replacingAll(
            in: "0123456789", query: captureExpansion,
            maximumOutputUTF16Length: 19
        )) { error in
            XCTAssertEqual(error as? MobileFindError, .replacementExceedsLimit)
        }
    }

    func testRegexReplacementTemplateIsUnicodeSafeAndMatchesPreflightLength() throws {
        let text = "name=7"
        let query = MobileFindQuery(
            search: "([a-z]+)=([0-9]+)",
            replacement: "😀$$|$&|$2|$1|$20|$99|$x|tail🚀",
            options: MobileFindOptions(
                isCaseSensitive: true, usesRegularExpression: true
            )
        )
        let match = try XCTUnwrap(MobileFindCore.scan(text, query: query).matches.first)
        let expected = "😀$|name=7|7|name|70|$99|$x|tail🚀"

        XCTAssertEqual(
            MobileFindCore.replacementText(for: match, in: text, query: query),
            expected
        )
        XCTAssertEqual(try MobileFindCore.replacing(
            match, in: text, query: query,
            maximumOutputUTF16Length: expected.utf16.count
        ).text, expected)
        XCTAssertThrowsError(try MobileFindCore.replacing(
            match, in: text, query: query,
            maximumOutputUTF16Length: expected.utf16.count - 1
        )) { error in
            XCTAssertEqual(error as? MobileFindError, .replacementExceedsLimit)
        }
        XCTAssertEqual(try MobileFindCore.replacingAll(
            in: "name=7 name=8", query: query
        ).text, expected + " " + expected.replacingOccurrences(of: "7", with: "8"))
    }

    func testLongRunningFindCanBeCancelled() {
        XCTAssertThrowsError(try MobileFindCore.scan(
            String(repeating: "match ", count: 1_000),
            query: MobileFindQuery(search: "match"),
            shouldCancel: { true }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFallbackOutlineIsBoundedAndUTF16Based() {
        let items = MobileOutline.items(in: "# 标题\n😀\nfunc work() {}\n")
        XCTAssertEqual(items.map(\.title), ["标题", "work"])
        XCTAssertEqual(items[1].location, 8)
    }
}
