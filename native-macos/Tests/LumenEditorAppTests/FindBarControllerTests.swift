import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class FindBarControllerTests: XCTestCase {
    func testShowUsesSelectionQueryAndDismissInvalidatesPresentation() async {
        let fixture = Fixture(text: "zero needle one", selection: NSRange(location: 5, length: 6))
        let controller = fixture.controller()

        controller.showFind()
        await controller.waitForCurrentSearch()

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .find)
        XCTAssertEqual(controller.query, "needle")
        XCTAssertEqual(controller.matches.map(\.range), [NSRange(location: 5, length: 6)])
        XCTAssertGreaterThan(controller.focusGeneration, 0)

        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.dismissalGeneration, 1)
    }

    func testNextPreviousWrapAndTargetExactPaneSnapshot() async {
        let fixture = Fixture(text: "one 🙂 one", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        controller.query = "one"

        let foundNext = await controller.findNext()
        XCTAssertTrue(foundNext)
        XCTAssertEqual(fixture.selectionRequests.last?.identity.documentID, "document")
        XCTAssertEqual(fixture.selectionRequests.last?.identity.viewID, "pane-b")
        XCTAssertEqual(fixture.selectionRequests.last?.identity.paneIndex, 1)
        XCTAssertEqual(fixture.selectionRequests.last?.selectedRange, NSRange(location: 0, length: 3))

        let foundPrevious = await controller.findPrevious()
        XCTAssertTrue(foundPrevious)
        XCTAssertEqual(fixture.selectionRequests.last?.selectedRange, NSRange(location: 7, length: 3))
        XCTAssertEqual(controller.status, .matches(current: 2, total: 2, truncated: false))
    }

    func testFindDoesNotPublishWhenShellRejectsStaleSelection() async {
        let fixture = Fixture(text: "one two one", selection: NSRange(location: 0, length: 0))
        fixture.acceptSelection = false
        let controller = fixture.controller()
        controller.query = "one"

        let found = await controller.findNext()
        XCTAssertFalse(found)
        XCTAssertNil(controller.selectedMatchIndex)
        XCTAssertEqual(controller.revealGeneration, 0)
    }

    func testLateSearchFromOldInputCannotOverwriteNewQuery() async {
        let fixture = Fixture(text: "first second", selection: NSRange(location: 0, length: 0))
        let search = ControlledSearch()
        let controller = fixture.controller(search: { text, query, limit in
            try await search.run(text: text, query: query, limit: limit)
        })
        controller.query = "first"
        controller.showFind()
        await search.waitForCall("first")
        controller.query = "second"
        await search.waitForCall("second")

        await search.resume(key: "second", returning: FindScanResult(
            matches: [FindMatch(range: NSRange(location: 6, length: 6))],
            isTruncated: false
        ))
        await controller.waitForCurrentSearch()
        await search.resume(key: "first", returning: FindScanResult(
            matches: [FindMatch(range: NSRange(location: 0, length: 5))],
            isTruncated: false
        ))
        await Task.yield()

        XCTAssertEqual(controller.query, "second")
        XCTAssertEqual(controller.matches.map(\.range), [NSRange(location: 6, length: 6)])
    }

    func testChangingPaneWhileSearchRunsDropsResult() async {
        let fixture = Fixture(text: "needle", selection: NSRange(location: 0, length: 0))
        let search = ControlledSearch()
        let controller = fixture.controller(search: { text, query, limit in
            try await search.run(text: text, query: query, limit: limit)
        })
        controller.showFind()
        controller.query = "needle"
        await search.waitForCall("needle")

        fixture.paneIndex = 0
        fixture.viewID = "pane-a"
        await search.resume(key: "needle", returning: FindScanResult(
            matches: [FindMatch(range: NSRange(location: 0, length: 6))],
            isTruncated: false
        ))
        await controller.waitForCurrentSearch()

        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertNil(controller.highlightSnapshot)
    }

    func testHighlightSnapshotRequiresExactDocumentViewPaneAndRevision() async throws {
        let fixture = Fixture(
            text: "alpha beta alpha", selection: NSRange(location: 0, length: 5)
        )
        let controller = fixture.controller()
        controller.query = "alpha"
        controller.showFind()
        await controller.waitForCurrentSearch()

        let snapshot = try XCTUnwrap(controller.highlightSnapshot(
            documentID: "document", viewID: "pane-b", paneIndex: 1,
            documentRevision: 7
        ))
        XCTAssertEqual(snapshot.matches.map(\.range), [
            NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)
        ])
        XCTAssertEqual(snapshot.selectedMatchIndex, 0)
        XCTAssertNil(controller.highlightSnapshot(
            documentID: "other", viewID: "pane-b", paneIndex: 1,
            documentRevision: 7
        ))
        XCTAssertNil(controller.highlightSnapshot(
            documentID: "document", viewID: "pane-a", paneIndex: 1,
            documentRevision: 7
        ))
        XCTAssertNil(controller.highlightSnapshot(
            documentID: "document", viewID: "pane-b", paneIndex: 0,
            documentRevision: 7
        ))
        XCTAssertNil(controller.highlightSnapshot(
            documentID: "document", viewID: "pane-b", paneIndex: 1,
            documentRevision: 8
        ))
    }

    func testHighlightSnapshotUsesExactRegexCaseAndWholeWordResults() async throws {
        let fixture = Fixture(
            text: "Cat cat catalog CAT", selection: NSRange(location: 0, length: 0)
        )
        let controller = fixture.controller()
        controller.query = "c.t"
        controller.usesRegularExpression = true
        controller.isCaseSensitive = true
        controller.isWholeWord = true
        controller.showFind()
        await controller.waitForCurrentSearch()

        let snapshot = try XCTUnwrap(controller.highlightSnapshot(
            documentID: fixture.documentID, viewID: fixture.viewID,
            paneIndex: fixture.paneIndex, documentRevision: fixture.revision
        ))
        XCTAssertEqual(snapshot.matches.map(\.range), [NSRange(location: 4, length: 3)])
        XCTAssertNil(snapshot.selectedMatchIndex)
    }

    func testHighlightSnapshotClearsOnDismissAndContextChange() async throws {
        let fixture = Fixture(text: "one one", selection: NSRange(location: 0, length: 3))
        let controller = fixture.controller()
        controller.query = "one"
        controller.showFind()
        await controller.waitForCurrentSearch()
        XCTAssertNotNil(controller.highlightSnapshot)

        controller.dismiss()
        XCTAssertNil(controller.highlightSnapshot)
        XCTAssertTrue(controller.matches.isEmpty)

        controller.showFind()
        await controller.waitForCurrentSearch()
        XCTAssertNotNil(controller.highlightSnapshot)
        fixture.revision += 1
        fixture.text += " changed"
        controller.documentContextDidChange()
        XCTAssertNil(controller.highlightSnapshot)
        await controller.waitForCurrentSearch()
        XCTAssertEqual(controller.highlightSnapshot?.documentRevision, fixture.revision)
    }

    func testProductionFindSnapshotTracksActiveDocumentViewPaneAndRevision() throws {
        let model = AppModel()
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "alpha beta"
        let paneIndex = model.paneLayout.activePaneIndex
        let viewID = model.paneLayout.panes[paneIndex].viewID
        _ = model.setSelection(
            .single(anchor: 0, head: 5),
            for: document.sessionDocumentID, viewID: viewID
        )
        XCTAssertEqual(
            model.selection(for: document.sessionDocumentID, viewID: viewID).main.range,
            NSRange(location: 0, length: 5)
        )

        let snapshot = try XCTUnwrap(NativeFeatureCoordinator.findSnapshot(model: model))
        XCTAssertEqual(snapshot.documentID, document.sessionDocumentID)
        XCTAssertEqual(snapshot.viewID, viewID)
        XCTAssertEqual(snapshot.paneIndex, paneIndex)
        XCTAssertEqual(snapshot.bufferRevision, document.buffer.revision)
        XCTAssertEqual(snapshot.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(snapshot.text, "alpha beta")
    }

    func testReplaceNextFirstSelectsThenAppliesAtomicRevisionPinnedEdit() async throws {
        let fixture = Fixture(text: "one two one", selection: NSRange(location: 4, length: 0))
        let controller = fixture.controller()
        controller.showReplace()
        controller.query = "one"
        controller.replacement = "three"

        let selected = await controller.replaceNext()
        XCTAssertTrue(selected)
        XCTAssertTrue(fixture.editRequests.isEmpty)
        XCTAssertEqual(fixture.selectionRequests.last?.selectedRange, NSRange(location: 8, length: 3))

        let replaced = await controller.replaceNext()
        XCTAssertTrue(replaced)
        let request = try XCTUnwrap(fixture.editRequests.last)
        XCTAssertEqual(request.identity.viewID, "pane-b")
        XCTAssertEqual(request.expectedBufferRevision, 7)
        XCTAssertEqual(request.edits, [TextEdit(from: 8, to: 11, insert: "three")])
        XCTAssertEqual(request.selectionAfter, NSRange(location: 0, length: 3))
        XCTAssertEqual(fixture.text, "one two three")
    }

    func testRegexReplaceAllIsSingleAtomicRequestWithUTF16Coordinates() async throws {
        let fixture = Fixture(text: "🙂 a1 a2", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        controller.showReplace()
        controller.query = #"a(\d)"#
        controller.replacement = #"x$1"#
        controller.usesRegularExpression = true

        let replaced = await controller.replaceAll()
        XCTAssertTrue(replaced)
        let request = try XCTUnwrap(fixture.editRequests.last)
        XCTAssertEqual(request.edits, [
            TextEdit(from: 3, to: 5, insert: "x1"),
            TextEdit(from: 6, to: 8, insert: "x2")
        ])
        XCTAssertNil(request.selectionAfter)
        XCTAssertEqual(fixture.text, "🙂 x1 x2")
        XCTAssertEqual(controller.status, .replaced(2))
    }

    func testZeroWidthRegexReplacementIsBoundedAndDoesNotMutate() async {
        let fixture = Fixture(text: "abc", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        controller.showReplace()
        controller.query = "(?=.)"
        controller.usesRegularExpression = true

        let replaced = await controller.replaceAll()

        XCTAssertFalse(replaced)
        XCTAssertEqual(fixture.text, "abc")
        XCTAssertTrue(fixture.editRequests.isEmpty)
        guard case .invalidQuery = controller.status else {
            return XCTFail("Zero-width replacements should be rejected")
        }
    }

    func testInvalidRegexIsExposedWithoutSelectionOrEdit() async {
        let fixture = Fixture(text: "anything", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        controller.query = "["
        controller.usesRegularExpression = true

        let found = await controller.findNext()
        XCTAssertFalse(found)
        guard case .invalidQuery = controller.status else {
            return XCTFail("Invalid regex should be reported")
        }
        XCTAssertTrue(fixture.selectionRequests.isEmpty)
        XCTAssertTrue(fixture.editRequests.isEmpty)
    }

    func testFindNextCommandWithoutQueryOpensAndFocusesBar() async {
        let fixture = Fixture(text: "anything", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()

        let found = await controller.findNextOrShow()

        XCTAssertFalse(found)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .find)
        XCTAssertGreaterThan(controller.focusGeneration, 0)
        XCTAssertTrue(fixture.selectionRequests.isEmpty)
    }

    func testRejectedEditDoesNotPublishReplacementSuccess() async {
        let fixture = Fixture(text: "one", selection: NSRange(location: 0, length: 3))
        fixture.acceptEdits = false
        let controller = fixture.controller()
        controller.showReplace()
        controller.query = "one"
        controller.replacement = "two"

        let replaced = await controller.replaceNext()

        XCTAssertFalse(replaced)
        XCTAssertEqual(fixture.text, "one")
        XCTAssertEqual(controller.revealGeneration, 0)
    }

    func testHistoryProvidersAndSuccessfulFindRecordQuery() async {
        let fixture = Fixture(text: "needle", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        var recordedSearch: String?
        var recordedReplacement: String?
        controller.setHistoryProviders(
            search: { ["recent", "older"] },
            replace: { ["replacement", ""] }
        )
        controller.setHistoryRecorder { search, replacement in
            recordedSearch = search
            recordedReplacement = replacement
        }

        controller.showFind()
        XCTAssertEqual(controller.searchHistory, ["recent", "older"])
        XCTAssertEqual(controller.replaceHistory, ["replacement", ""])
        controller.query = "needle"
        let found = await controller.findNext()
        XCTAssertTrue(found)
        XCTAssertEqual(recordedSearch, "needle")
        XCTAssertNil(recordedReplacement)
    }

    func testSuccessfulReplaceRecordsBothValuesButRejectedEditDoesNot() async {
        let fixture = Fixture(text: "one", selection: NSRange(location: 0, length: 3))
        let controller = fixture.controller()
        var recorded: [(String, String)] = []
        controller.setHistoryRecorder { search, replacement in
            recorded.append((search, replacement ?? "<nil>"))
        }
        controller.showReplace()
        controller.query = "one"
        controller.replacement = "two"
        fixture.acceptEdits = false

        let rejected = await controller.replaceNext()
        XCTAssertFalse(rejected)
        XCTAssertTrue(recorded.isEmpty)

        fixture.acceptEdits = true
        let replaced = await controller.replaceNext()
        XCTAssertTrue(replaced)
        XCTAssertEqual(recorded.map { $0.0 }, ["one"])
        XCTAssertEqual(recorded.map { $0.1 }, ["two"])
    }

    func testCommandRegistrationContractAndAccessibilityLabels() async throws {
        let fixture = Fixture(text: "one", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)
        XCTAssertEqual(tokens.map(\.commandID), FindBarController.commandIDs)

        let context = CommandRoutingContext(hasDocument: true)
        let findResult = await router.execute("find", context: context)
        XCTAssertTrue(findResult.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .find)
        let replaceResult = await router.execute("replace", context: context)
        XCTAssertTrue(replaceResult.didExecuteSuccessfully)
        XCTAssertEqual(controller.mode, .replace)

        controller.query = "missing"
        let noMatch = await router.execute("find-next", context: context)
        guard case .noChange(commandID: "find-next") = noMatch else {
            return XCTFail("A routed find with no match must report no change")
        }

        controller.query = ""
        controller.dismiss()
        let presented = await router.execute("find-next", context: context)
        XCTAssertTrue(presented.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .find)

        XCTAssertEqual(FindBarView.Accessibility.bar, "Find and Replace")
        XCTAssertEqual(FindBarView.Accessibility.query, "Find Text")
        XCTAssertEqual(FindBarView.Accessibility.searchHistoryID, "panel.find.searchHistory")
        XCTAssertEqual(FindBarView.Accessibility.replaceHistoryID, "panel.find.replaceHistory")
        XCTAssertEqual(FindBarView.Accessibility.previous, "Find Previous Match")
        XCTAssertEqual(FindBarView.Accessibility.close, "Close Find Bar")
    }

    func testPartialCommandRegistrationRollsBackOwnership() throws {
        let fixture = Fixture(text: "one", selection: NSRange(location: 0, length: 0))
        let controller = fixture.controller()
        let router = CommandRouter()
        _ = try router.register("replace") { _ in }

        XCTAssertThrowsError(try controller.registerCommands(on: router))
        XCTAssertEqual(
            router.status(for: "find", context: CommandRoutingContext(hasDocument: true)),
            .unsupported
        )
        XCTAssertEqual(
            router.status(for: "replace", context: CommandRoutingContext(hasDocument: true)),
            .enabled
        )
    }
}

@MainActor
private final class Fixture {
    var text: String
    var selection: NSRange
    var documentID = "document"
    var viewID: EditorViewID = "pane-b"
    var paneIndex = 1
    var revision: UInt64 = 7
    var acceptSelection = true
    var acceptEdits = true
    var selectionRequests: [FindSelectionRequest] = []
    var editRequests: [FindEditRequest] = []

    init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }

    func controller(
        search: @escaping FindBarController.SearchAction = { text, query, limit in
            try FindCore.scan(text, query: query, limit: limit)
        }
    ) -> FindBarController {
        FindBarController(
            snapshot: { [weak self] in self?.snapshot },
            selectMatch: { [weak self] request in
                guard let self else { return false }
                self.selectionRequests.append(request)
                guard self.acceptSelection, request.identity == self.snapshot.identity,
                      request.expectedBufferRevision == self.revision else { return false }
                self.selection = request.selectedRange
                return true
            },
            applyEdits: { [weak self] request in
                guard let self else { return false }
                self.editRequests.append(request)
                guard self.acceptEdits, request.identity == self.snapshot.identity,
                      request.expectedBufferRevision == self.revision,
                      let transaction = try? TextTransaction(
                        edits: request.edits, expectedRevision: request.expectedBufferRevision
                      ),
                      let updated = try? transaction.applying(to: self.text)
                else { return false }
                self.text = updated
                self.revision &+= 1
                if let next = request.selectionAfter { self.selection = next }
                return true
            },
            search: search
        )
    }

    var snapshot: FindDocumentSnapshot {
        FindDocumentSnapshot(
            documentID: documentID,
            viewID: viewID,
            paneIndex: paneIndex,
            text: text,
            selectedRange: selection,
            bufferRevision: revision
        )
    }
}

private actor ControlledSearch {
    private var continuations: [String: CheckedContinuation<FindScanResult, any Error>] = [:]
    private var queued: [String: Result<FindScanResult, any Error>] = [:]
    private var calls: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run(text: String, query: FindQuery, limit: Int) async throws -> FindScanResult {
        _ = text
        _ = limit
        let key = query.search
        calls.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        if let queued = queued.removeValue(forKey: key) {
            return try queued.get()
        }
        return try await withCheckedThrowingContinuation { continuations[key] = $0 }
    }

    func waitForCall(_ key: String) async {
        guard !calls.contains(key) else { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func resume(key: String, returning value: FindScanResult) {
        let result: Result<FindScanResult, any Error> = .success(value)
        if let continuation = continuations.removeValue(forKey: key) {
            continuation.resume(with: result)
        } else {
            queued[key] = result
        }
    }
}
