import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class IncrementalDiffControllerTests: XCTestCase {
    @MainActor
    func testNextPreviousNavigateStrictlyWrapAndUseUTF16LineStart() async {
        let fixture = Fixture(
            baseline: "🙂 old\nb\nc\nd",
            current: "🙂 NEW\nb\nc\nD",
            cursorUTF16Offset: 0
        )

        let firstNext = await fixture.controller.nextChange()
        XCTAssertTrue(firstNext)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 4)
        XCTAssertEqual(
            fixture.navigationRequests.last?.targetUTF16Offset,
            "🙂 NEW\nb\nc\n".utf16.count
        )

        fixture.cursorUTF16Offset = "🙂 NEW\nb\nc\n".utf16.count
        let wrappedNext = await fixture.controller.nextChange()
        XCTAssertTrue(wrappedNext)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 1)
        let previous = await fixture.controller.previousChange()
        XCTAssertTrue(previous)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 4)

        fixture.cursorUTF16Offset = 0
        let wrappedPrevious = await fixture.controller.previousChange()
        XCTAssertTrue(wrappedPrevious)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 4)
    }

    @MainActor
    func testNoChangesAndUnavailableDocumentsDoNotNavigate() async {
        let fixture = Fixture(baseline: "same", current: "same")
        let unchangedNext = await fixture.controller.nextChange()
        XCTAssertFalse(unchangedNext)
        XCTAssertEqual(fixture.controller.status, .noChanges)
        XCTAssertTrue(fixture.navigationRequests.isEmpty)

        fixture.fileURL = nil
        let unavailablePrevious = await fixture.controller.previousChange()
        XCTAssertFalse(unavailablePrevious)
        XCTAssertEqual(fixture.controller.status, .unavailable)
    }

    @MainActor
    func testRevertBuildsOneRevisionPinnedTransactionAndMapsSelection() throws {
        let current = "🙂 alpha\nNEW\nomega"
        let fixture = Fixture(
            baseline: "🙂 alpha\nold\nomega",
            current: current,
            cursorUTF16Offset: "🙂 alpha\nNEW".utf16.count,
            revision: 17
        )

        XCTAssertTrue(fixture.controller.revertCurrentChange())
        let request = try XCTUnwrap(fixture.revertRequests.first)
        XCTAssertEqual(request.snapshot.bufferRevision, 17)
        XCTAssertEqual(request.transaction.expectedRevision, 17)
        XCTAssertEqual(
            try request.transaction.applying(to: current),
            "🙂 alpha\nold\nomega"
        )
        XCTAssertEqual(
            request.transaction.selection?.main.head,
            "🙂 alpha\nold".utf16.count
        )
        XCTAssertEqual(fixture.controller.status, .reverted(request.hunk))
    }

    @MainActor
    func testRevertUsesPrecedingHunkWhenCursorIsBetweenChanges() throws {
        let fixture = Fixture(
            baseline: "a\nb\nc\nd\ne",
            current: "A\nb\nc\nd\nE",
            cursorUTF16Offset: 2
        )

        XCTAssertTrue(fixture.controller.revertCurrentChange())
        let request = try XCTUnwrap(fixture.revertRequests.first)
        XCTAssertEqual(request.hunk.currentStartLine, 1)
        XCTAssertEqual(
            try request.transaction.applying(to: fixture.current),
            "a\nb\nc\nd\nE"
        )
    }

    @MainActor
    func testConflictDisablesMarkersNavigationAndRevert() async {
        let fixture = Fixture(baseline: "old", current: "new")
        fixture.hasExternalConflict = true

        XCTAssertTrue(fixture.controller.markers().isEmpty)
        let conflictedNext = await fixture.controller.nextChange()
        XCTAssertFalse(conflictedNext)
        XCTAssertEqual(fixture.controller.status, .conflict)
        XCTAssertFalse(fixture.controller.revertCurrentChange())
        XCTAssertEqual(fixture.controller.status, .conflict)
        XCTAssertTrue(fixture.navigationRequests.isEmpty)
        XCTAssertTrue(fixture.revertRequests.isEmpty)
    }

    @MainActor
    func testBoundedFailureIsReportedWithoutCallbacks() async {
        let fixture = Fixture(
            baseline: "a\nb\nc", current: "A\nB\nC",
            limits: IncrementalDiffLimits(
                maximumTextUTF16Length: 100, maximumLineCount: 10,
                maximumMatrixCellCount: 15
            )
        )

        let boundedNext = await fixture.controller.nextChange()
        XCTAssertFalse(boundedNext)
        guard case let .limited(message) = fixture.controller.status else {
            return XCTFail("Expected a bounded diff status")
        }
        XCTAssertTrue(message.contains("matrix cells"))
        XCTAssertTrue(fixture.navigationRequests.isEmpty)
    }

    @MainActor
    func testCallbacksReceiveImmutableRevisionPinnedSnapshots() async {
        let fixture = Fixture(baseline: "old", current: "new", revision: 3)
        fixture.mutateBeforeNavigationAccept = true
        let staleNext = await fixture.controller.nextChange()
        XCTAssertFalse(staleNext)
        XCTAssertEqual(fixture.navigationRequests.first?.snapshot.bufferRevision, 3)

        fixture.revision = 8
        fixture.mutateBeforeRevertAccept = true
        XCTAssertFalse(fixture.controller.revertCurrentChange())
        XCTAssertEqual(fixture.revertRequests.last?.transaction.expectedRevision, 8)
    }

    @MainActor
    func testCommandRegistrationExecutesAllRoutesAndDisablesUnsafeStates() async throws {
        let fixture = Fixture(
            baseline: "a\nb\nc", current: "A\nb\nC",
            cursorUTF16Offset: 0
        )
        let router = CommandRouter()
        let tokens = try fixture.controller.registerCommands(on: router)
        let context = CommandRoutingContext(
            hasDocument: true, hasSavedDocument: true, hasWorkspace: true,
            hasGitRepository: true
        )

        XCTAssertEqual(tokens.map(\.commandID), IncrementalDiffController.commandIDs)
        XCTAssertEqual(router.status(for: "next-change", context: context), .enabled)
        let nextResult = await router.execute("next-change", context: context)
        XCTAssertTrue(nextResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 3)
        let previousResult = await router.execute("prev-change", context: context)
        XCTAssertTrue(previousResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.navigationRequests.last?.targetLine, 1)
        let revertResult = await router.execute(
            "revert-current-change", context: context
        )
        XCTAssertTrue(revertResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.revertRequests.count, 1)

        fixture.hasExternalConflict = true
        XCTAssertEqual(
            router.status(for: "revert-current-change", context: context),
            .disabled(.handler(reason: "Resolve the external file conflict first"))
        )
        fixture.hasExternalConflict = false
        fixture.fileURL = nil
        XCTAssertEqual(
            router.status(for: "next-change", context: context),
            .disabled(.handler(reason: "Save the document first"))
        )
    }

    @MainActor
    func testPartialRegistrationRollsBackAndReplaceTakesOwnership() throws {
        let fixture = Fixture(baseline: "a", current: "b")
        let router = CommandRouter()
        let old = try router.register("prev-change") { _ in }

        XCTAssertThrowsError(try fixture.controller.registerCommands(on: router))
        let context = CommandRoutingContext(
            hasDocument: true, hasSavedDocument: true, hasWorkspace: true,
            hasGitRepository: true
        )
        XCTAssertEqual(router.status(for: "next-change", context: context), .unsupported)
        XCTAssertEqual(router.status(for: "prev-change", context: context), .enabled)
        XCTAssertEqual(
            router.status(for: "revert-current-change", context: context),
            .unsupported
        )

        let tokens = try fixture.controller.registerCommands(
            on: router, replaceExisting: true
        )
        XCTAssertEqual(tokens.map(\.commandID), IncrementalDiffController.commandIDs)
        XCTAssertFalse(router.unregister(old))
    }

    @MainActor
    func testProductionAdapterUsesSavedBaselineActivePaneAndRejectsStaleRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IncrementalDiffControllerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: directory.appendingPathComponent(
                    SessionStore.sessionFileName
                )
            ),
            createInitialDocument: false
        )
        let opened = OpenedTextFile(
            url: URL(fileURLWithPath: "/workspace/example.txt"),
            content: "old\nsecond", encoding: .utf8, lineEnding: .lf,
            revision: "sha256:baseline", byteLength: 10, isBinary: false,
            isTooLarge: false
        )
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.text = "NEW\nsecond"
        let controller = IncrementalDiffController(model: model)

        XCTAssertEqual(controller.markers(), [
            IncrementalDiffMarker(kind: .modified, line: 1, lineCount: 1)
        ])
        let navigated = await controller.nextChange()
        XCTAssertTrue(navigated)
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 0))

        let stale = try XCTUnwrap(IncrementalDiffController.snapshot(model: model))
        let staleHunk = try XCTUnwrap(try IncrementalDiff.compare(
            baseline: stale.baselineText, current: stale.currentText
        ).hunks.first)
        document.text += "!"
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.text, stale.currentText)
        let staleTransaction = try IncrementalDiff.revertTransaction(
            current: stale.currentText, hunk: staleHunk,
            selection: stale.selection, expectedRevision: stale.bufferRevision
        )
        XCTAssertNotEqual(document.buffer.revision, staleTransaction.expectedRevision)
        XCTAssertThrowsError(try document.apply(staleTransaction)) { error in
            guard case let EditorTransactionError.staleRevision(expected, actual) = error else {
                return XCTFail("Expected revision rejection, got \(error)")
            }
            XCTAssertEqual(expected, stale.bufferRevision)
            XCTAssertEqual(actual, document.buffer.revision)
        }

        XCTAssertTrue(controller.revertCurrentChange())
        XCTAssertEqual(document.text, "old\nsecond")
    }

    @MainActor
    func testProductionNavigationRecordsSuccessfulJumpInSharedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IncrementalDiffHistoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: directory.appendingPathComponent(
                    SessionStore.sessionFileName
                )
            ),
            createInitialDocument: false
        )
        let opened = OpenedTextFile(
            url: URL(fileURLWithPath: "/workspace/history.txt"),
            content: "a\nb\nc", encoding: .utf8, lineEnding: .lf,
            revision: "sha256:history", byteLength: 5, isBinary: false,
            isTooLarge: false
        )
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.text = "A\nb\nC"
        let navigation = NavigationController(
            snapshot: {
                let pane = model.paneLayout.panes[0]
                return NavigationAppSnapshot(
                    documents: [NavigationDocumentSnapshot(
                        documentID: document.sessionDocumentID,
                        url: document.fileURL, displayName: document.displayName,
                        text: document.text
                    )],
                    panes: [NavigationPaneSnapshot(
                        groupID: 0, activeDocumentID: document.sessionDocumentID,
                        cursorUTF16Offset: model.selection(
                            for: document.sessionDocumentID, viewID: pane.viewID
                        ).main.head
                    )],
                    activeGroupID: 0
                )
            },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )
        let controller = IncrementalDiffController(
            model: model, navigation: navigation
        )

        let navigated = await controller.nextChange()
        XCTAssertTrue(navigated)
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 4))
        XCTAssertEqual(navigation.backEntries.first?.line, 1)
        XCTAssertEqual(navigation.backEntries.first?.column, 1)
    }
}

@MainActor
private final class Fixture {
    var documentID = "document"
    var fileURL: URL? = URL(fileURLWithPath: "/workspace/document.txt")
    var paneIndex = 0
    var viewID: EditorViewID = "pane"
    var baseline: String
    var current: String
    var cursorUTF16Offset: Int
    var revision: UInt64
    var hasExternalConflict = false
    var acceptsNavigation = true
    var acceptsRevert = true
    var mutateBeforeNavigationAccept = false
    var mutateBeforeRevertAccept = false
    var navigationRequests: [IncrementalDiffNavigationRequest] = []
    var revertRequests: [IncrementalDiffRevertRequest] = []

    lazy var controller = IncrementalDiffController(
        limits: limits,
        snapshot: { [unowned self] in self.snapshot },
        navigate: { [unowned self] request in
            self.navigationRequests.append(request)
            if self.mutateBeforeNavigationAccept { self.revision &+= 1 }
            let accepted = self.acceptsNavigation && request.snapshot == self.snapshot
            if accepted { self.cursorUTF16Offset = request.targetUTF16Offset }
            return accepted
        },
        revert: { [unowned self] request in
            self.revertRequests.append(request)
            if self.mutateBeforeRevertAccept { self.revision &+= 1 }
            return self.acceptsRevert && request.snapshot == self.snapshot
        }
    )
    private let limits: IncrementalDiffLimits

    init(
        baseline: String,
        current: String,
        cursorUTF16Offset: Int = 0,
        revision: UInt64 = 0,
        limits: IncrementalDiffLimits = .standard
    ) {
        self.baseline = baseline
        self.current = current
        self.cursorUTF16Offset = cursorUTF16Offset
        self.revision = revision
        self.limits = limits
    }

    private var snapshot: IncrementalDiffSnapshot {
        IncrementalDiffSnapshot(
            documentID: documentID, fileURL: fileURL, paneIndex: paneIndex,
            viewID: viewID, baselineText: baseline, currentText: current,
            selection: .cursor(at: min(current.utf16.count, cursorUTF16Offset)),
            bufferRevision: revision, hasExternalConflict: hasExternalConflict
        )
    }
}
