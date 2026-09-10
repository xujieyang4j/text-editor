import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class TabLifecycleControllerTests: XCTestCase {
    func testCloseOtherTabsReviewsEveryDirtyTargetBeforeCommitting() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        XCTAssertTrue(model.selectDocument(documents[1], inPaneAt: 0))
        documents[0].text += " dirty"
        documents[2].text += " dirty"

        XCTAssertTrue(actions.canCloseOtherTabs)
        XCTAssertTrue(actions.requestCloseOtherTabs())
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[0].id)
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[2].id)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })

        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()

        XCTAssertFalse(actions.isClosingTabsInBulk)
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertEqual(model.documents.count, 1)
        XCTAssertTrue(model.documents[0] === documents[1])
        XCTAssertEqual(model.recentlyClosedTabCount, 2)
    }

    func testCloseAllCancellationLeavesReviewedTabsOpenAndPinnedTabsUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        XCTAssertTrue(model.selectDocument(documents[1], inPaneAt: 0))
        XCTAssertTrue(model.togglePin(documents[0]))
        documents[1].text += " dirty"
        documents[2].text += " dirty"

        XCTAssertTrue(actions.canCloseAllTabs)
        XCTAssertTrue(actions.requestCloseAllTabs())
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[1].id)
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[2].id)

        await actions.cancelPendingClose()

        XCTAssertFalse(actions.isClosingTabsInBulk)
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })
        XCTAssertEqual(model.recentlyClosedTabCount, 0)
        XCTAssertTrue(documents[0].pinned)
    }

    func testBulkCloseCancellationLeavesEveryReviewedDirtyTabOpen() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        XCTAssertTrue(model.selectDocument(documents[0], inPaneAt: 0))
        XCTAssertTrue(model.togglePin(documents[0]))
        documents[1].text += " dirty"
        documents[2].text += " dirty"

        XCTAssertTrue(actions.canCloseTabsToRight)
        XCTAssertTrue(actions.requestCloseTabsToRight())
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[1].id)
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[2].id)

        await actions.cancelPendingClose()

        XCTAssertFalse(actions.isClosingTabsInBulk)
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertTrue(documents.allSatisfy { document in
            model.documents.contains { $0 === document }
        })
        XCTAssertEqual(model.recentlyClosedTabCount, 0)
        XCTAssertFalse(actions.canReopenClosedTab)
    }

    func testBulkCloseCommitsOnlyAfterEveryDirtyTabIsReviewed() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        XCTAssertTrue(model.selectDocument(documents[0], inPaneAt: 0))
        XCTAssertTrue(model.togglePin(documents[0]))
        documents[1].text += " dirty"
        documents[2].text += " dirty"

        XCTAssertTrue(actions.requestCloseTabsToRight())
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertTrue(model.documents.contains { $0 === documents[1] })
        XCTAssertTrue(model.documents.contains { $0 === documents[2] })

        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()

        XCTAssertFalse(actions.isClosingTabsInBulk)
        XCTAssertTrue(model.documents.contains { $0 === documents[0] })
        XCTAssertFalse(model.documents.contains { $0 === documents[1] })
        XCTAssertFalse(model.documents.contains { $0 === documents[2] })
        XCTAssertEqual(model.recentlyClosedTabCount, 2)
        XCTAssertEqual(
            model.mostRecentlyClosedTab?.url,
            try XCTUnwrap(documents[2].fileURL)
        )
    }

    func testReopenClosedTabConsumesRuntimeStackInLIFOOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        model.requestClose(documents[0])
        model.requestClose(documents[1])
        let firstURL = try XCTUnwrap(documents[0].fileURL)
        let secondURL = try XCTUnwrap(documents[1].fileURL)

        XCTAssertEqual(model.mostRecentlyClosedTab?.url, secondURL)
        XCTAssertTrue(actions.canReopenClosedTab)
        await actions.reopenClosedTab()
        XCTAssertTrue(model.documents.contains { $0.fileURL == secondURL })
        XCTAssertEqual(model.mostRecentlyClosedTab?.url, firstURL)

        await actions.reopenClosedTab()
        XCTAssertTrue(model.documents.contains { $0.fileURL == firstURL })
        XCTAssertFalse(model.canReopenClosedTab)
    }

    func testFailedReopenKeepsTheTopEntryForRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let openedDocuments = try openThreeFiles(in: fixture.directory, model: model)
        let document = try XCTUnwrap(openedDocuments.first)
        let url = try XCTUnwrap(document.fileURL)
        model.requestClose(document)
        try FileManager.default.removeItem(at: url)
        let entryID = try XCTUnwrap(model.mostRecentlyClosedTab?.id)

        await actions.reopenClosedTab()

        XCTAssertEqual(model.mostRecentlyClosedTab?.id, entryID)
        XCTAssertEqual(actions.presentedIssue?.title, "Could Not Reopen Tab")
    }

    func testTransientPanelToggleClosesAndReplacesPanels() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        var dismissed: [EditorTransientPanel] = []
        actions.setTransientPanelDidDismiss { dismissed.append($0) }

        actions.toggleTransientPanel(.git)
        XCTAssertEqual(actions.transientPanel, .git)
        actions.toggleTransientPanel(.git)
        XCTAssertNil(actions.transientPanel)
        XCTAssertEqual(dismissed, [.git])

        actions.toggleTransientPanel(.build)
        actions.toggleTransientPanel(.terminal)
        XCTAssertEqual(actions.transientPanel, .terminal)
        XCTAssertEqual(dismissed, [.git, .build])
    }

    func testLanguageServerApprovalBrokerKeepsOwnerAndInvokesExactCallbacks() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let actions = EditorActionController(model: model)
        let request = LanguageServerApprovalRequest(configuration: try ToolExecutionConfiguration(
            kind: .languageServer, executable: "true", args: [], cwd: fixture.directory,
            authorizedRoot: fixture.directory,
            resolver: ToolExecutableResolver(allowedExecutables: [
                "true": URL(fileURLWithPath: "/usr/bin/true")
            ])
        ))
        let owner = UUID()
        var confirmed = 0
        var declined = 0

        actions.presentLanguageServerApproval(
            request, ownerID: owner,
            confirm: { confirmed += 1 }, decline: { declined += 1 }
        )
        XCTAssertEqual(actions.languageServerApproval?.ownerID, owner)
        XCTAssertTrue(actions.isAnyTransientPanelPresented)
        await actions.confirmLanguageServerApproval()
        XCTAssertNil(actions.languageServerApproval)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(declined, 0)

        actions.presentLanguageServerApproval(
            request, ownerID: owner,
            confirm: { confirmed += 1 }, decline: { declined += 1 }
        )
        actions.withdrawLanguageServerApproval(ownerID: UUID())
        XCTAssertNotNil(actions.languageServerApproval)
        actions.withdrawLanguageServerApproval(ownerID: owner)
        XCTAssertNil(actions.languageServerApproval)
        XCTAssertEqual(declined, 1)

        let competingOwner = UUID()
        actions.presentLanguageServerApproval(
            request, ownerID: owner,
            confirm: { confirmed += 1 }, decline: { declined += 1 }
        )
        XCTAssertFalse(actions.canPresentLanguageServerApproval(ownerID: competingOwner))
        actions.withdrawLanguageServerApproval(ownerID: competingOwner)
        XCTAssertEqual(actions.languageServerApproval?.ownerID, owner)
        actions.declineLanguageServerApproval()
    }

    func testPrepareForApplicationTerminationDoesNotRunIrreversibleTeardown() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()

        var completionValue: Bool?
        actions.setTransientPanelDidDismiss { _ in
            XCTFail("Termination review should not synthesize a panel dismissal here")
        }

        actions.prepareForApplicationTermination { allowed in
            completionValue = allowed
        }
        await drainMainActor()

        XCTAssertEqual(completionValue, true)
        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        XCTAssertTrue(model.isTextEditingLocked)
        XCTAssertTrue(model.documents.allSatisfy(\.isEditingLocked))
        XCTAssertTrue(actions.workspace.isApplicationTerminationPrepared)
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertNil(actions.presentedIssue)

        await actions.abortApplicationTerminationPreparation()
        XCTAssertFalse(actions.isClosingApplicationOrWindow)
        XCTAssertFalse(model.isTextEditingLocked)
        XCTAssertTrue(model.documents.allSatisfy { !$0.isEditingLocked })
        XCTAssertFalse(actions.workspace.isApplicationTerminationPrepared)
        XCTAssertTrue(actions.canExecuteRoutedCommand)
    }

    func testApplicationTerminationCancellationDoesNotPartiallyDiscardDirtyTabs() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        documents[0].text += " dirty"
        documents[1].text += " dirty"

        var completionValue: Bool?
        actions.prepareForApplicationTermination { completionValue = $0 }
        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[0].id)

        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(model.pendingCloseRequest?.documentID, documents[1].id)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })

        await actions.cancelPendingClose()

        XCTAssertEqual(completionValue, false)
        XCTAssertFalse(actions.isClosingApplicationOrWindow)
        XCTAssertFalse(model.isTextEditingLocked)
        XCTAssertTrue(documents.allSatisfy { !$0.isEditingLocked })
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })
    }

    func testApplicationTerminationDefersReviewedDiscardsUntilExplicitCommit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        documents[0].text += " dirty"
        documents[1].text += " dirty"

        var completionValue: Bool?
        actions.prepareForApplicationTermination { completionValue = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertNil(completionValue)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })

        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        await drainMainActor()

        XCTAssertEqual(completionValue, true)
        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        XCTAssertNil(model.pendingCloseRequest)
        XCTAssertTrue(documents.allSatisfy { candidate in
            model.documents.contains { $0 === candidate }
        })

        actions.commitApplicationTerminationPreparation()

        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        XCTAssertFalse(actions.canExecuteRoutedCommand)
        XCTAssertTrue(model.isTextEditingLocked)
        XCTAssertTrue(actions.workspace.isApplicationTerminationCommitted)
        XCTAssertFalse(model.documents.contains { $0 === documents[0] })
        XCTAssertFalse(model.documents.contains { $0 === documents[1] })
        XCTAssertTrue(model.documents.contains { $0 === documents[2] })
        let survivor = documents[2]
        let text = survivor.text
        let revision = survivor.buffer.revision
        let survivorPane = try XCTUnwrap(model.paneLayout.panes.firstIndex {
            $0.contains(survivor.sessionDocumentID)
        })
        survivor.text += " must be rejected"
        XCTAssertFalse(model.apply(
            try TextTransaction(
                edits: [TextEdit(from: 0, to: 0, insert: "rejected")],
                expectedRevision: revision
            ),
            to: survivor, inPaneAt: survivorPane
        ))
        XCTAssertFalse(model.undo(document: survivor))
        XCTAssertFalse(model.redo(document: survivor))
        XCTAssertEqual(survivor.text, text)
        XCTAssertEqual(survivor.buffer.revision, revision)
    }

    func testApplicationTerminationPersistenceFailureKeepsReviewedDiscardAndLease() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var shouldFailPersistence = false
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false,
            sessionWillPersist: {
                if shouldFailPersistence {
                    throw NSError(domain: "TerminationPreflight", code: 1)
                }
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        document.text += " dirty"
        var leaseReleaseCount = 0
        model.retainSecurityScopedAccess(
            SecurityScopedResourceLease(url: try XCTUnwrap(document.fileURL)) {
                leaseReleaseCount += 1
            },
            for: document
        )

        var prepared: Bool?
        actions.prepareForApplicationTermination { prepared = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(prepared, true)

        shouldFailPersistence = true
        XCTAssertFalse(actions.preflightApplicationTerminationPersistence())
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(leaseReleaseCount, 0)

        await actions.abortApplicationTerminationPreparation()
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertEqual(leaseReleaseCount, 0)
    }

    func testWindowClosePersistenceFailureKeepsReviewedDiscardAndLease() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var shouldFailPersistence = false
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false,
            sessionWillPersist: {
                if shouldFailPersistence {
                    throw NSError(domain: "WindowClosePreflight", code: 1)
                }
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        document.text += " dirty"
        var leaseReleaseCount = 0
        model.retainSecurityScopedAccess(
            SecurityScopedResourceLease(url: try XCTUnwrap(document.fileURL)) {
                leaseReleaseCount += 1
            },
            for: document
        )
        shouldFailPersistence = true

        var allowed: Bool?
        actions.prepareForWindowClose { allowed = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        await drainMainActor()

        XCTAssertEqual(allowed, false)
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(leaseReleaseCount, 0)
    }

    func testWindowCloseRegistryHookFailureKeepsDirtyCanonicalSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var failRegistryHook = false
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false,
            sessionDidPersist: {
                if failRegistryHook {
                    throw NSError(domain: "RegistryFailure", code: 1)
                }
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        document.text += " dirty"
        failRegistryHook = true

        var allowed: Bool?
        actions.prepareForWindowClose { allowed = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        await drainMainActor()

        XCTAssertEqual(allowed, false)
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.draft,
                       document.text)
    }

    func testWindowCloseProjectedWriteFailureKeepsDirtyCanonicalSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var failProjectedWrite = false
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false,
            applicationCloseSnapshotWillPersist: {
                if failProjectedWrite {
                    throw NSError(domain: "ProjectedWriteFailure", code: 1)
                }
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        document.text += " dirty"
        failProjectedWrite = true

        var allowed: Bool?
        actions.prepareForWindowClose { allowed = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        await drainMainActor()

        XCTAssertEqual(allowed, false)
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.draft,
                       document.text)
    }

    func testWindowCloseRevalidatesAfterProjectedWriteHook() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var documentToEdit: EditorDocument?
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false,
            applicationCloseSnapshotWillPersist: {
                guard let documentToEdit else { return }
                // Bypass the document-level close-review lock to simulate a
                // stale/re-entrant producer at the final validation boundary.
                _ = try documentToEdit.buffer.apply(TextTransaction(edits: [
                    TextEdit(from: 0, to: 0, insert: "changed in hook " )
                ]))
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        document.text += " dirty"
        documentToEdit = document

        var allowed: Bool?
        actions.prepareForWindowClose { allowed = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        await drainMainActor()

        XCTAssertEqual(allowed, false)
        XCTAssertTrue(model.documents.contains { $0 === document })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.draft,
                       "file 1 dirty")
    }

    func testApplicationTerminationValidationRejectsChangedReviewedRevision() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let documents = try openThreeFiles(in: fixture.directory, model: model)
        documents[0].text += " dirty"

        var completionValue: Bool?
        actions.prepareForApplicationTermination { completionValue = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()

        XCTAssertEqual(completionValue, true)
        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        // Production edits are frozen during review. Mutate the underlying
        // revision directly to retain coverage of the stale-review guard.
        _ = try documents[0].buffer.apply(TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "changed after review " )
        ]))

        XCTAssertFalse(actions.validateApplicationTerminationPreparation())
        await actions.abortApplicationTerminationPreparation()

        XCTAssertFalse(actions.isClosingApplicationOrWindow)
        XCTAssertTrue(model.documents.contains { $0 === documents[0] })
        XCTAssertTrue(documents[0].isDirty)
        XCTAssertEqual(actions.presentedIssue?.title, "Could Not Close Window")
    }

    func testApplicationTerminationCommitClosesReviewedDocumentFromEveryPane() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try openThreeFiles(in: fixture.directory, model: model)[0]
        XCTAssertTrue(model.selectDocument(document, inPaneAt: 0))
        document.text += " dirty"
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertEqual(model.referenceCount(for: document), 2)

        var prepared: Bool?
        actions.prepareForApplicationTermination { prepared = $0 }
        await actions.resolvePendingCloseByDiscarding()
        await drainMainActor()
        XCTAssertEqual(prepared, true)

        actions.commitApplicationTerminationPreparation()
        XCTAssertTrue(actions.isClosingApplicationOrWindow)
        XCTAssertFalse(actions.canExecuteRoutedCommand)
        XCTAssertFalse(model.documents.contains { $0 === document })
        XCTAssertTrue(model.paneLayout.panes.allSatisfy {
            !$0.contains(document.sessionDocumentID)
        })
    }

    private func openThreeFiles(
        in directory: URL,
        model: AppModel
    ) throws -> [EditorDocument] {
        try (1...3).map { number in
            let url = directory.appendingPathComponent("\(number).txt")
            try Data("file \(number)".utf8).write(to: url)
            return try XCTUnwrap(model.open(openedFile: TextFileCodec.read(from: url)))
        }
    }

    private func drainMainActor() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TabLifecycleControllerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return Fixture(
            directory: directory,
            store: SessionStore(
                sessionURL: directory.appendingPathComponent(SessionStore.sessionFileName)
            )
        )
    }

    private struct Fixture {
        let directory: URL
        let store: SessionStore

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
