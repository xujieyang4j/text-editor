import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class CompletionControllerTests: XCTestCase {
    private let viewID = EditorViewID("pane")

    func testLanguageServerResultsWinWithoutWorkspaceFallback() async {
        var snapshot = makeSnapshot(text: "pri", revision: 2, cursor: 3)
        var workspaceRequests = 0
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in [
                LanguageCompletionItem(
                    label: "print", detail: "function", insertText: "print()"
                )
            ] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { workspaceRequests += 1; return ["private"] },
            openBuffers: { ["private protocol"] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )

        controller.request()
        await drain()

        XCTAssertEqual(controller.presentation?.suggestions.map(\.label), ["print"] )
        XCTAssertEqual(controller.presentation?.suggestions.first?.source, .languageServer)
        XCTAssertEqual(workspaceRequests, 0)
        snapshot = makeSnapshot(text: "changed", revision: 3, cursor: 7)
    }

    func testNoLanguageServerSkipsRequestAndUsesOpenBuffers() async {
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        var lspRequests = 0
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in
                lspRequests += 1
                return [LanguageCompletionItem(label: "print")]
            },
            canRequestLanguageServer: { _, _ in false },
            workspaceWords: { [] }, openBuffers: { ["private protocol"] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )

        controller.request()
        await drain()

        XCTAssertEqual(lspRequests, 0)
        XCTAssertEqual(
            Set(controller.presentation?.suggestions.map(\.label) ?? []),
            Set(["private", "protocol"])
        )
    }

    func testEmptyLanguageServerFallsBackAndRefreshesWorkspaceCache() async {
        var now = Date(timeIntervalSince1970: 100)
        var requests = 0
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        let cache = WorkspaceCompletionCache(now: { now })
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { requests += 1; return ["protocol"] },
            openBuffers: { ["private"] },
            applyTransaction: { _, _ in false }, workspaceCache: cache
        )

        controller.request()
        await drain()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(
            Set(controller.presentation?.suggestions.map(\.label) ?? []),
            Set(["private", "protocol"])
        )

        now.addTimeInterval(30)
        controller.request()
        await drain()
        XCTAssertEqual(requests, 1, "A populated workspace index remains fresh for 60 seconds")

        now.addTimeInterval(31)
        controller.request()
        await drain()
        XCTAssertEqual(requests, 2)
    }

    func testLateResultIsDiscardedAfterRevisionChanges() async {
        let gate = CompletionResultGate()
        var snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in await gate.wait() },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await gate.waitUntilRequested()
        snapshot = makeSnapshot(text: "pri", revision: 2, cursor: 3)
        await gate.resume([LanguageCompletionItem(label: "print")])
        await drain()

        XCTAssertNil(controller.presentation)
        XCTAssertFalse(controller.isLoading)
    }

    func testAcceptAppliesExactlyOneCapturedTransactionAndRejectsStaleState() async {
        var snapshot = makeSnapshot(text: "pri", revision: 4, cursor: 3)
        var received: [TextTransaction] = []
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in [
                LanguageCompletionItem(label: "print", insertText: "print()")
            ] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { transaction, _ in received.append(transaction); return true }, workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await drain()
        XCTAssertTrue(controller.acceptSelection())
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.expectedRevision, 4)
        XCTAssertEqual(received.first?.edits, [TextEdit(from: 0, to: 3, insert: "print()")])

        controller.request()
        await drain()
        snapshot = makeSnapshot(text: "prix", revision: 5, cursor: 4)
        XCTAssertFalse(controller.acceptSelection())
        XCTAssertEqual(received.count, 1)
    }

    func testNativeEditorConsumeIsGuardedAndDoesNotInvokeSecondApplyPath() async {
        var snapshot = makeSnapshot(text: "pri", revision: 7, cursor: 3)
        var applied = 0
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in [
                LanguageCompletionItem(label: "print", insertText: "print()")
            ] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { _, _ in applied += 1; return true },
            workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await drain()

        let consumed = controller.consumeSelectionForNativeEditor()
        XCTAssertEqual(consumed?.0.label, "print")
        XCTAssertEqual(consumed?.1.revision, 7)
        XCTAssertEqual(applied, 0)
        XCTAssertNil(controller.presentation)

        controller.request()
        await drain()
        snapshot = makeSnapshot(text: "prix", revision: 8, cursor: 4)
        XCTAssertNil(controller.consumeSelectionForNativeEditor())
        XCTAssertEqual(applied, 0)
    }

    func testSelectionWrapsAndObserverReceivesUpdates() async {
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        var updates: [CompletionPresentation?] = []
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in [
                LanguageCompletionItem(label: "print"),
                LanguageCompletionItem(label: "private")
            ] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )
        controller.setPresentationObserver { updates.append($0) }
        controller.request()
        await drain()
        controller.moveSelection(by: -1)

        XCTAssertEqual(controller.presentation?.selectedIndex, 1)
        XCTAssertEqual(updates.last??.selectedIndex, 1)
    }

    func testSharedWorkspaceCacheDoesNotSharePanePresentation() async {
        let cache = WorkspaceCompletionCache()
        let firstSnapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        let secondSnapshot = CompletionDocumentSnapshot(
            documentID: "other", viewID: "other-pane", revision: 1,
            text: "ot", cursorUTF16Offset: 2, fileURL: nil,
            language: "Plain Text", project: nil, workspaceRoots: []
        )
        let first = CompletionController(
            snapshot: { firstSnapshot }, requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in false }, workspaceWords: { ["protocol"] },
            openBuffers: { ["private"] }, applyTransaction: { _, _ in false },
            workspaceCache: cache
        )
        let second = CompletionController(
            snapshot: { secondSnapshot }, requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in false }, workspaceWords: { ["otherWord"] },
            openBuffers: { ["otherWord"] }, applyTransaction: { _, _ in false },
            workspaceCache: cache
        )
        var firstUpdates = 0
        var secondUpdates = 0
        first.setPresentationObserver { if $0 != nil { firstUpdates += 1 } }
        second.setPresentationObserver { if $0 != nil { secondUpdates += 1 } }

        first.request()
        await drain()

        XCTAssertNotNil(first.presentation)
        XCTAssertNil(second.presentation)
        XCTAssertTrue(firstUpdates > 0)
        XCTAssertEqual(secondUpdates, 0)
    }

    func testPerPaneSnapshotProviderPreventsInactivePaneRequest() async {
        let active = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        var isActivePane = false
        var requests = 0
        let controller = CompletionController(
            snapshot: { isActivePane ? active : nil },
            requestLanguageServer: { _, _ in requests += 1; return [] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { ["private"] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )

        controller.request()
        await drain()
        XCTAssertEqual(requests, 0)
        XCTAssertNil(controller.presentation)

        isActivePane = true
        controller.request()
        await drain()
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(controller.presentation)
    }

    func testPaneIdentityRequiresExactDocumentViewAndPane() {
        let identity = CompletionPaneIdentity(
            documentID: "doc", viewID: "view-a", paneIndex: 1
        )
        XCTAssertTrue(identity.isActive(
            activeDocumentID: "doc", activeViewID: "view-a", activePaneIndex: 1
        ))
        XCTAssertFalse(identity.isActive(
            activeDocumentID: "doc", activeViewID: "view-b", activePaneIndex: 1
        ))
        XCTAssertFalse(identity.isActive(
            activeDocumentID: "other", activeViewID: "view-a", activePaneIndex: 1
        ))
        XCTAssertFalse(identity.isActive(
            activeDocumentID: "doc", activeViewID: "view-a", activePaneIndex: 0
        ))
    }

    func testWorkspaceCacheIsSharedButRefreshesOnlyEligiblePane() async {
        let cache = WorkspaceCompletionCache()
        let active = makeSnapshot(text: "wo", revision: 1, cursor: 2)
        let inactive = CompletionDocumentSnapshot(
            documentID: "other", viewID: "other-pane", revision: 1,
            text: "wo", cursorUTF16Offset: 2, fileURL: nil,
            language: "Plain Text", project: nil, workspaceRoots: []
        )
        var firstIsActive = true
        var secondIsActive = false
        let first = CompletionController(
            snapshot: { firstIsActive ? active : nil },
            requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in false },
            workspaceWords: { ["workspaceWord"] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: cache
        )
        let second = CompletionController(
            snapshot: { secondIsActive ? inactive : nil },
            requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in false },
            workspaceWords: { ["workspaceWord"] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: cache
        )

        first.request()
        await drain()
        XCTAssertEqual(first.presentation?.suggestions.map(\.label), ["workspaceWord"])
        XCTAssertNil(second.presentation)

        firstIsActive = false
        secondIsActive = true
        first.activeEditorDidChange()
        second.request()
        await drain()
        XCTAssertNil(first.presentation)
        XCTAssertEqual(second.presentation?.suggestions.map(\.label), ["workspaceWord"])
    }

    func testDismissCancelsLateRequestAndClearsLoadingState() async {
        let gate = CompletionResultGate()
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in await gate.wait() },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await gate.waitUntilRequested()
        controller.dismiss()
        await gate.resume([LanguageCompletionItem(label: "print")])
        await drain()

        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.presentation)
    }

    func testCursorMovementDismissesPublishedCompletion() async {
        var snapshot = makeSnapshot(text: "print", revision: 1, cursor: 2)
        let controller = CompletionController(
            snapshot: { snapshot }, requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in false }, workspaceWords: { [] },
            openBuffers: { ["private"] }, applyTransaction: { _, _ in false },
            workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await drain()
        XCTAssertNotNil(controller.presentation)

        snapshot = makeSnapshot(text: "print", revision: 1, cursor: 3)
        controller.editorContextDidChange()

        XCTAssertNil(controller.presentation)
    }

    func testWorkspaceChangeInvalidatesCachedWords() async {
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        var workspaceRequests = 0
        let cache = WorkspaceCompletionCache()
        let controller = CompletionController(
            snapshot: { snapshot }, requestLanguageServer: { _, _ in [] },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: {
                workspaceRequests += 1
                return [workspaceRequests == 1 ? "protocol" : "property"]
            },
            openBuffers: { [] }, applyTransaction: { _, _ in false },
            workspaceCache: cache
        )
        controller.request()
        await drain()
        XCTAssertEqual(workspaceRequests, 1)

        cache.invalidate()
        controller.request()
        await drain()

        XCTAssertEqual(workspaceRequests, 2)
    }

    func testSharedWorkspaceCacheUsesSixtySecondTTL() async {
        var now = Date(timeIntervalSince1970: 500)
        var calls = 0
        let cache = WorkspaceCompletionCache(now: { now })
        let provider: @MainActor () async -> [String]? = {
            calls += 1
            return ["workspaceWord"]
        }

        cache.refreshIfNeeded(using: provider)
        await cache.waitForRefreshForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(cache.isFreshForTesting())

        now.addTimeInterval(60)
        cache.refreshIfNeeded(using: provider)
        await cache.waitForRefreshForTesting()
        XCTAssertEqual(calls, 1)

        now.addTimeInterval(0.001)
        cache.refreshIfNeeded(using: provider)
        await cache.waitForRefreshForTesting()
        XCTAssertEqual(calls, 2)
    }

    func testIdenticalRequestWhileLoadingIsCoalesced() async {
        let gate = CompletionResultGate()
        let snapshot = makeSnapshot(text: "pr", revision: 1, cursor: 2)
        var requests = 0
        let controller = CompletionController(
            snapshot: { snapshot },
            requestLanguageServer: { _, _ in
                requests += 1
                return await gate.wait()
            },
            canRequestLanguageServer: { _, _ in true },
            workspaceWords: { [] }, openBuffers: { [] },
            applyTransaction: { _, _ in false }, workspaceCache: WorkspaceCompletionCache()
        )
        controller.request()
        await gate.waitUntilRequested()
        controller.request()
        XCTAssertEqual(requests, 1)
        await gate.resume([])
        await drain()
    }

    func testApprovalBrokerKeepsOriginatingControllerAndRejectsStaleReplay() async {
        var snapshot: CompletionDocumentSnapshot? = makeSnapshot(
            text: "pr", revision: 1, cursor: 2
        )
        let approval = LanguageServerApprovalRequest(configuration: try! ToolExecutionConfiguration(
            kind: .languageServer, executable: "true", args: [],
            cwd: URL(fileURLWithPath: "/tmp"), authorizedRoot: URL(fileURLWithPath: "/tmp"),
            resolver: ToolExecutableResolver(allowedExecutables: [
                "true": URL(fileURLWithPath: "/usr/bin/true")
            ])
        ))
        var currentApproval: LanguageServerApprovalRequest? = approval
        var replayed: [LanguageCompletionItem]?
        var confirmClosure: (@MainActor () async -> Void)?
        var declineClosure: (@MainActor () -> Void)?
        let controller = CompletionController(
            snapshot: { snapshot }, requestLanguageServer: { _, _ in nil },
            canRequestLanguageServer: { _, _ in true }, workspaceWords: { [] },
            openBuffers: { [] }, applyTransaction: { _, _ in false },
            workspaceCache: WorkspaceCompletionCache()
        )
        controller.setTestLanguageServerLifecycle(
            approval: { currentApproval },
            confirm: {
                currentApproval = nil
                replayed = [LanguageCompletionItem(label: "print")]
            },
            decline: { currentApproval = nil },
            replayed: { defer { replayed = nil }; return replayed },
            present: { _, confirm, decline in
                confirmClosure = confirm
                declineClosure = decline
            }
        )

        controller.request()
        await drain()
        XCTAssertNotNil(confirmClosure)
        snapshot = makeSnapshot(text: "prix", revision: 2, cursor: 4)
        await confirmClosure?()
        XCTAssertNil(controller.presentation, "A changed document must reject approval replay")
        declineClosure?()
    }

    private func makeSnapshot(
        text: String, revision: UInt64, cursor: Int
    ) -> CompletionDocumentSnapshot {
        CompletionDocumentSnapshot(
            documentID: "doc", viewID: viewID, revision: revision, text: text,
            cursorUTF16Offset: cursor, fileURL: URL(fileURLWithPath: "/tmp/File.swift"),
            language: "Swift", project: nil, workspaceRoots: []
        )
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private actor CompletionResultGate {
    private var continuation: CheckedContinuation<[LanguageCompletionItem]?, Never>?
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> [LanguageCompletionItem]? {
        requested = true
        waiters.forEach { $0.resume() }
        waiters = []
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume(_ value: [LanguageCompletionItem]?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
