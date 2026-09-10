import XCTest
@testable import LumenEditorCore

final class NavigationCoreTests: XCTestCase {
    func testFuzzyMatchingAndStableOrdering() {
        let match = NavigationFuzzyMatcher.score(query: "mt", text: "src/main.ts")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.matches, [4, 9])
        XCTAssertNil(NavigationFuzzyMatcher.score(query: "xyz", text: "main.ts"))

        let values = ["same", "same"]
        XCTAssertEqual(
            NavigationFuzzyMatcher.filter(
                query: "sm",
                items: values,
                key: { $0 }
            ).map { $0.item },
            values
        )
    }

    func testSymbolExtractionUsesUTF16Offsets() {
        let source = "🙂\nclass App {}\nfunction run() {}\n# Heading"
        let symbols = SymbolExtractor.extract(from: source)
        XCTAssertEqual(symbols.map(\.label), ["App", "run", "# Heading"])
        XCTAssertEqual(symbols.map(\.line), [2, 3, 4])
        XCTAssertEqual(symbols[0].position, 3)
    }

    func testGotoLineSyntaxMatchesElectron() {
        XCTAssertEqual(resolve("42:8", 10, 100), GotoLineLocation(line: 42, column: 8))
        XCTAssertEqual(resolve("+10", 20, 100), GotoLineLocation(line: 30, column: 1))
        XCTAssertEqual(resolve("-50", 20, 100), GotoLineLocation(line: 1, column: 1))
        XCTAssertEqual(resolve("50%", 20, 101), GotoLineLocation(line: 51, column: 1))
        XCTAssertEqual(resolve("+10%", 20, 100), GotoLineLocation(line: 30, column: 1))
        XCTAssertEqual(resolve("999", 20, 100), GotoLineLocation(line: 100, column: 1))
        XCTAssertNil(resolve("12:0", 20, 100))
        XCTAssertNil(resolve("not-a-line", 20, 100))
    }

    @MainActor
    func testNavigationRoundTripBranchAndStaleTransactions() async throws {
        let history = NavigationHistory()
        let a = location("a", 1)
        let b = location("b", 2)
        let c = location("c", 3)
        let d = location("d", 4)
        history.recordSuccessfulJump(source: a, target: b)
        history.recordSuccessfulJump(source: b, target: c)
        XCTAssertEqual(history.backEntries, [a, b])

        let first = try XCTUnwrap(history.prepareTraversal(.back))
        let stale = try XCTUnwrap(history.prepareTraversal(.back))
        XCTAssertEqual(first.target, b)
        XCTAssertTrue(history.commitTraversal(first, current: c))
        XCTAssertFalse(history.commitTraversal(stale, current: b))
        XCTAssertEqual(history.backEntries, [a])
        XCTAssertEqual(history.forwardEntries, [c])

        history.recordSuccessfulJump(source: b, target: d)
        XCTAssertEqual(history.backEntries, [a, b])
        XCTAssertFalse(history.canGoForward)
    }

    @MainActor
    func testNavigationLifecycleAndCapacity() async throws {
        let history = try NavigationHistory(capacity: 2)
        history.recordSuccessfulJump(source: location("a", 1), target: location("b", 2))
        history.recordSuccessfulJump(source: location("b", 2), target: location("c", 3))
        history.recordSuccessfulJump(source: location("c", 3), target: location("d", 4))
        XCTAssertEqual(history.backEntries.map(\.documentID), ["b", "c"])

        let untitled = NavigationLocation(
            documentID: "untitled", path: nil, groupID: 2, line: 1, column: 1
        )
        history.recordSuccessfulJump(source: untitled, target: location("e", 5))
        history.updateDocumentPath(documentID: "untitled", path: "/workspace/saved.ts")
        XCTAssertEqual(history.backEntries.last?.path, "/workspace/saved.ts")
        history.removeDocument(documentID: "untitled")
        XCTAssertFalse(history.backEntries.contains { $0.documentID == "untitled" })
    }

    @MainActor
    func testNavigationIntentEpoch() async {
        let epoch = NavigationIntentEpoch()
        let snapshot = epoch.current
        XCTAssertTrue(epoch.isCurrent(snapshot))
        epoch.begin()
        XCTAssertFalse(epoch.isCurrent(snapshot))
    }

    private func resolve(_ input: String, _ current: Int, _ total: Int) -> GotoLineLocation? {
        GotoLineResolver.resolve(input, currentLine: current, totalLines: total)
    }

    private func location(_ id: String, _ line: Int) -> NavigationLocation {
        NavigationLocation(
            documentID: id, path: "/workspace/\(id).ts", groupID: 0,
            line: line, column: line
        )
    }
}
