import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class OutlineControllerTests: XCTestCase {
    func testAnalysisPublishesSymbolsActiveItemAndFilter() async {
        var snapshot = makeSnapshot(
            text: "class App {\n  run() {\n  }\n}",
            cursor: 17
        )
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()

        XCTAssertEqual(controller.symbols.map(\.label), ["App", "run"])
        XCTAssertEqual(controller.activeSymbolID, controller.symbols.last?.id)
        controller.query = "app"
        XCTAssertEqual(controller.filteredSymbols.map(\.label), ["App"])
        XCTAssertEqual(controller.resultSummary, "1")
        _ = snapshot
    }

    func testStaleAnalysisCompletionCannotOverwriteNewDocument() async {
        var snapshot = makeSnapshot(documentID: "first", text: "class First {}")
        let gate = AnalysisGate()
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: { text, language, _, _, _, _, limits in
                await gate.analyze(text: text, language: language, limits: limits)
            },
            navigate: { _ in true }
        )
        await waitUntil { gate.requests.count == 1 }

        snapshot = makeSnapshot(documentID: "second", text: "class Second {}")
        controller.synchronize()
        await waitUntil { gate.requests.count == 2 }
        gate.complete(index: 1)
        await controller.waitForCurrentAnalysis()
        XCTAssertEqual(controller.symbols.map(\.label), ["Second"])

        gate.complete(index: 0)
        await drainMainActor()
        XCTAssertEqual(controller.symbols.map(\.label), ["Second"])
    }

    func testVisibilityChangesAreReportedAndHiddenControllerStillSynchronizes() async {
        var changes: [Bool] = []
        let controller = OutlineController(
            snapshot: { self.makeSnapshot(text: "class App {}") },
            analyze: immediateAnalyzer,
            navigate: { _ in true },
            visibilityChanged: { changes.append($0) }
        )
        XCTAssertTrue(controller.symbols.isEmpty)

        controller.toggleVisibility()
        await controller.waitForCurrentAnalysis()
        controller.setVisible(false)

        XCTAssertEqual(changes, [true, false])
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.symbols.map(\.label), ["App"])
    }

    func testSelectRevealsFoldAndNavigatesWithPaneIdentity() async throws {
        let snapshot = makeSnapshot(
            documentID: "doc", viewID: "right",
            text: "function outer() {\n  function inner() {}\n}", cursor: 0
        )
        var requests: [OutlineNavigationRequest] = []
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { request in requests.append(request); return true }
        )
        await controller.waitForCurrentAnalysis()
        let didFoldAllBeforeSelection = await controller.foldAll()
        XCTAssertTrue(didFoldAllBeforeSelection)
        let symbol = try XCTUnwrap(controller.symbols.last)

        let didSelect = await controller.select(symbol)
        XCTAssertTrue(didSelect)
        XCTAssertEqual(requests, [OutlineNavigationRequest(
            documentID: "doc", documentRevision: 1, viewID: "right",
            utf16Offset: symbol.utf16Offset, line: symbol.line
        )])
        XCTAssertTrue(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 1
        ).hiddenRanges.isEmpty)
    }

    func testFoldingIsIndependentPerViewAndDoesNotInvokeNavigation() async {
        var snapshot = makeSnapshot(
            documentID: "doc", viewID: "left",
            text: "function outer() {\n  work()\n}", cursor: 5
        )
        var navigationCount = 0
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { _ in navigationCount += 1; return true }
        )
        await controller.waitForCurrentAnalysis()
        let didFoldCurrent = await controller.foldCurrent()
        XCTAssertTrue(didFoldCurrent)
        let left = controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "left", documentRevision: 1
        )
        XCTAssertEqual(left.hiddenRanges.count, 1)

        snapshot = makeSnapshot(
            documentID: "doc", viewID: "right",
            text: snapshot.text, cursor: 5
        )
        controller.synchronize()
        await controller.waitForCurrentAnalysis()
        let rightBefore = controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 1
        )
        XCTAssertTrue(rightBefore.hiddenRanges.isEmpty)
        let didFoldAllInRightPane = await controller.foldAll()
        XCTAssertTrue(didFoldAllInRightPane)
        XCTAssertEqual(navigationCount, 0)
        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 1
        ).hiddenRanges.count, 1)
        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "left", documentRevision: 1
        ).hiddenRanges, left.hiddenRanges)
    }

    func testDocumentRevisionChangeDropsStaleFolds() async {
        var snapshot = makeSnapshot(
            text: "function outer() {\n  work()\n}", revision: 1, cursor: 5
        )
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        let didFoldAllBeforeRevisionChange = await controller.foldAll()
        XCTAssertTrue(didFoldAllBeforeRevisionChange)

        snapshot = makeSnapshot(text: "plain\ntext", revision: 2, cursor: 0)
        controller.synchronize()
        await controller.waitForCurrentAnalysis()

        XCTAssertTrue(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID,
            viewID: snapshot.viewID,
            documentRevision: snapshot.documentRevision
        ).hiddenRanges.isEmpty)
    }

    func testGutterToggleUsesExactRegionAndRejectsStaleRevision() async throws {
        let snapshot = makeSnapshot(
            documentID: "doc", viewID: "right",
            text: "function outer() {\n  work()\n}", revision: 9, cursor: 0
        )
        let controller = OutlineController(
            isVisible: true, snapshot: { snapshot },
            analyze: immediateAnalyzer, navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        let initial = controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 9
        )
        let marker = try XCTUnwrap(initial.markers.first)
        XCTAssertFalse(marker.isFolded)

        XCTAssertFalse(controller.toggleFoldMarker(
            documentID: "doc", viewID: "right", documentRevision: 8,
            regionID: marker.id
        ))
        XCTAssertFalse(controller.toggleFoldMarker(
            documentID: "doc", viewID: "right", documentRevision: 9,
            regionID: "stale-region"
        ))
        XCTAssertTrue(controller.toggleFoldMarker(
            documentID: "doc", viewID: "right", documentRevision: 9,
            regionID: marker.id
        ))

        let folded = controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 9
        )
        XCTAssertEqual(folded.markers.first?.isFolded, true)
        XCTAssertEqual(folded.hiddenRanges, [marker.hiddenRange])
        XCTAssertGreaterThan(folded.presentationRevision, initial.presentationRevision)
        XCTAssertTrue(controller.toggleFoldMarker(
            documentID: "doc", viewID: "right", documentRevision: 9,
            regionID: marker.id
        ))
        XCTAssertTrue(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "right", documentRevision: 9
        ).hiddenRanges.isEmpty)
    }

    func testDocumentRevisionChangePreservesStructurallyEquivalentFold() async {
        var snapshot = makeSnapshot(
            text: "function outer() {\n  work()\n}", revision: 1, cursor: 5
        )
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        XCTAssertTrue(await controller.foldAll())

        snapshot = makeSnapshot(
            text: "// header\nfunction outer() {\n  work()\n}",
            revision: 2, cursor: 15
        )
        controller.synchronize()
        await controller.waitForCurrentAnalysis()

        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID,
            viewID: snapshot.viewID,
            documentRevision: snapshot.documentRevision
        ).hiddenRanges.count, 1)
    }

    func testUndoAndRedoReconcileFoldStateForEachExactRevision() async {
        let original = "function outer() {\n  work()\n}"
        let edited = "// header\n" + original
        var snapshot = makeSnapshot(text: original, revision: 1, cursor: 5)
        let controller = OutlineController(
            isVisible: true, snapshot: { snapshot },
            analyze: immediateAnalyzer, navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        XCTAssertTrue(await controller.foldAll())

        snapshot = makeSnapshot(text: edited, revision: 2, cursor: 15)
        controller.synchronize()
        await controller.waitForCurrentAnalysis()
        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID, viewID: snapshot.viewID,
            documentRevision: 2
        ).hiddenRanges.count, 1)

        // Undo restores the original bytes at a new, monotonically increasing
        // revision. Fold reconciliation must use that exact analysis rather
        // than an earlier same-text revision.
        snapshot = makeSnapshot(text: original, revision: 3, cursor: 5)
        controller.synchronize()
        await controller.waitForCurrentAnalysis()
        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID, viewID: snapshot.viewID,
            documentRevision: 3
        ).hiddenRanges.count, 1)

        snapshot = makeSnapshot(text: edited, revision: 4, cursor: 15)
        controller.synchronize()
        await controller.waitForCurrentAnalysis()
        XCTAssertEqual(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID, viewID: snapshot.viewID,
            documentRevision: 4
        ).hiddenRanges.count, 1)
    }

    func testCursorOnlySynchronizationUsesCachedAnalysis() async {
        var snapshot = makeSnapshot(
            text: "class App {\n  run() {}\n}", cursor: 0
        )
        let analyses = OutlineLockedCounter()
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: { text, language, _, _, _, _, limits in
                analyses.increment()
                return OutlineFoldingAnalyzer.analyze(
                    text: text, language: language, limits: limits
                )
            },
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        snapshot = makeSnapshot(text: snapshot.text, cursor: 18)

        controller.synchronize()

        XCTAssertEqual(analyses.value, 1)
        XCTAssertEqual(controller.activeSymbolID, controller.symbols.last?.id)
    }

    func testIndentationSettingsChangeInvalidatesOutlineAnalysisCache() async {
        var snapshot = makeSnapshot(text: "class App {}")
        let analyses = OutlineLockedCounter()
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: { text, language, _, _, _, _, limits in
                analyses.increment()
                return OutlineFoldingAnalyzer.analyze(
                    text: text, language: language, limits: limits
                )
            },
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        snapshot = makeSnapshot(
            text: snapshot.text, tabWidth: 8, indentWidth: 2,
            insertSpaces: false
        )

        controller.synchronize()
        await controller.waitForCurrentAnalysis()

        XCTAssertEqual(analyses.value, 2)
    }

    func testCommandsRegisterExecuteAndRollbackOnCollision() async throws {
        let snapshot = makeSnapshot(
            text: "function outer() {\n  work()\n}", cursor: 5
        )
        let controller = OutlineController(
            isVisible: true,
            snapshot: { snapshot },
            analyze: immediateAnalyzer,
            navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)
        XCTAssertEqual(Set(tokens.map(\.commandID)), OutlineController.commandIDs)

        let context = CommandRoutingContext(hasDocument: true)
        let foldResult = await router.execute("fold-current", context: context)
        XCTAssertTrue(foldResult.didExecuteSuccessfully)
        XCTAssertFalse(controller.textKitFoldSnapshot(
            documentID: snapshot.documentID, viewID: snapshot.viewID,
            documentRevision: snapshot.documentRevision
        ).hiddenRanges.isEmpty)
        let unfoldResult = await router.execute("unfold-all", context: context)
        XCTAssertTrue(unfoldResult.didExecuteSuccessfully)

        let second = OutlineController(
            isVisible: true, snapshot: { snapshot },
            analyze: immediateAnalyzer, navigate: { _ in true }
        )
        XCTAssertThrowsError(try second.registerCommands(on: router))
        let freshRouter = CommandRouter()
        _ = try freshRouter.register("fold-current") { _ in }
        XCTAssertThrowsError(try second.registerCommands(on: freshRouter))
        XCTAssertEqual(
            freshRouter.status(for: "toggle-outline", context: context),
            .unsupported
        )
    }

    func testRetainLiveStatePrunesClosedPaneFolds() async {
        let snapshot = makeSnapshot(
            documentID: "doc", viewID: "left",
            text: "function outer() {\n  work()\n}", cursor: 5
        )
        let controller = OutlineController(
            isVisible: true, snapshot: { snapshot },
            analyze: immediateAnalyzer, navigate: { _ in true }
        )
        await controller.waitForCurrentAnalysis()
        let didFoldAllBeforePrune = await controller.foldAll()
        XCTAssertTrue(didFoldAllBeforePrune)
        XCTAssertFalse(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "left", documentRevision: 1
        ).hiddenRanges.isEmpty)

        controller.retainLiveState(
            documentIDs: Set(["doc"]),
            viewIDs: Set([EditorViewID("right")])
        )

        XCTAssertTrue(controller.textKitFoldSnapshot(
            documentID: "doc", viewID: "left", documentRevision: 1
        ).hiddenRanges.isEmpty)
    }

    private var immediateAnalyzer: OutlineController.Analyzer {
        { text, language, _, _, _, _, limits in
            OutlineFoldingAnalyzer.analyze(
                text: text, language: language, limits: limits
            )
        }
    }

    private func makeSnapshot(
        documentID: String = "document",
        viewID: EditorViewID = .default,
        text: String,
        language: String = "JavaScript",
        revision: UInt64 = 1,
        cursor: Int = 0,
        tabWidth: Int = 4,
        indentWidth: Int = 4,
        insertSpaces: Bool = true
    ) -> OutlineEditorSnapshot {
        OutlineEditorSnapshot(
            documentID: documentID,
            displayName: "Example",
            text: text,
            language: language,
            documentRevision: revision,
            viewID: viewID,
            selections: .cursor(at: cursor),
            tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces
        )
    }

    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

private final class OutlineLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class AnalysisGate {
    struct Request {
        let text: String
        let language: String
        let limits: OutlineLimits
        let continuation: CheckedContinuation<OutlineDocumentModel, Never>
    }

    private(set) var requests: [Request?] = []

    func analyze(
        text: String,
        language: String,
        limits: OutlineLimits
    ) async -> OutlineDocumentModel {
        await withCheckedContinuation { continuation in
            requests.append(Request(
                text: text, language: language, limits: limits,
                continuation: continuation
            ))
        }
    }

    func complete(index: Int) {
        guard requests.indices.contains(index), let request = requests[index] else { return }
        requests[index] = nil
        request.continuation.resume(returning: OutlineFoldingAnalyzer.analyze(
            text: request.text, language: request.language, limits: request.limits
        ))
    }
}
