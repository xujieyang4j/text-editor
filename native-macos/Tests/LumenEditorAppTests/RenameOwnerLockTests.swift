import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class RenameOwnerLockTests: XCTestCase {
    func testRenameLocksTargetWhileUnrelatedDocumentRemainsEditable() throws {
        let fixture = makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.sessionURL) }
        let target = try XCTUnwrap(fixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/rename-target.swift"), content: "target"
        )))
        let unrelated = try XCTUnwrap(fixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/rename-unrelated.swift"), content: "other"
        )))
        let lockID = UUID()

        XCTAssertTrue(fixture.model.acquireRenameEditingLock(
            lockID, documents: [target]
        ))
        target.text = "blocked"
        unrelated.text = "editable"

        XCTAssertEqual(target.text, "target")
        XCTAssertEqual(unrelated.text, "editable")
        XCTAssertTrue(target.isEditingLocked)
        XCTAssertFalse(unrelated.isEditingLocked)

        fixture.model.releaseRenameEditingLock(lockID, documents: [target])
        XCTAssertFalse(target.isEditingLocked)
    }

    func testFinalRenameValidationRejectsTargetOpenedDuringPlanning() throws {
        let fixture = makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.sessionURL) }
        let targetURL = URL(fileURLWithPath: "/tmp/rename-late-open.swift")
        let lockID = UUID()

        XCTAssertTrue(fixture.model.acquireRenameEditingLock(
            lockID, documents: []
        ))
        XCTAssertTrue(fixture.model.validateRenameEditingLock(
            lockID, lockedDocuments: [],
            plannedBindings: [(targetURL, nil)]
        ))

        let lateDocument = try XCTUnwrap(fixture.model.open(openedFile: openedFile(
            at: targetURL, content: "late"
        )))
        XCTAssertFalse(lateDocument.isEditingLocked)
        XCTAssertFalse(fixture.model.validateRenameEditingLock(
            lockID, lockedDocuments: [],
            plannedBindings: [(targetURL, nil)]
        ))
    }

    func testRenameTerminationAndGitOwnersReleaseOnlyThemselves() throws {
        let fixture = makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.sessionURL) }
        let document = try XCTUnwrap(fixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/rename-owner.swift"), content: "clean"
        )))
        let renameID = UUID()
        let gitID = UUID()
        XCTAssertTrue(fixture.model.acquireRenameEditingLock(
            renameID, documents: [document]
        ))
        document.lockEditingForTermination()
        document.lockEditingForGitMutation(gitID)

        document.unlockEditingAfterTerminationCancellation()
        document.unlockEditingAfterGitMutation(gitID)
        document.unlockEditingAfterRenameMutation(UUID())
        XCTAssertTrue(document.isEditingLocked)

        document.lockEditingForTermination()
        document.lockEditingForGitMutation(gitID)
        fixture.model.releaseRenameEditingLock(renameID, documents: [document])
        XCTAssertTrue(document.isEditingLocked)
        document.unlockEditingAfterTerminationCancellation()
        XCTAssertTrue(document.isEditingLocked)
        document.unlockEditingAfterGitMutation(gitID)
        XCTAssertFalse(document.isEditingLocked)
    }

    func testRenameReconciliationRequiresMatchingOwnerToken() {
        let url = URL(fileURLWithPath: "/tmp/rename-token.swift")
        let document = EditorDocument(openedFile: openedFile(
            at: url, content: "before"
        ))
        let lockID = UUID()
        document.lockEditingForRenameMutation(lockID)
        let replacement = openedFile(at: url, content: "after", revision: "replacement")

        XCTAssertFalse(document.replaceWithDiskFile(
            replacement, renameMutationID: UUID()
        ))
        XCTAssertEqual(document.text, "before")
        XCTAssertTrue(document.replaceWithDiskFile(
            replacement, renameMutationID: lockID
        ))
        XCTAssertEqual(document.text, "after")
    }

    func testRenameWriteDispositionDoesNotClaimNoOpAndTracksResultFlags() {
        let artifact = URL(fileURLWithPath: "/tmp/.lumen-rename-recovery")
        let issue = RenameWriteCommitIssue(
            durabilityConfirmed: false, cleanupCompleted: false,
            recoveryArtifact: artifact
        )
        XCTAssertEqual(
            NativeFeatureCoordinator.renameWriteDisposition(FileWriteResult(
                revision: "external", wroteBytes: false
            )),
            .notWritten(actualRevision: "external")
        )
        XCTAssertEqual(
            NativeFeatureCoordinator.renameWriteDisposition(FileWriteResult(
                revision: "owned", wroteBytes: true,
                durabilityConfirmed: false, cleanupCompleted: false,
                recoveryArtifact: artifact
            )),
            .written(revision: "owned", issue: issue)
        )
        XCTAssertFalse(NativeFeatureCoordinator.renameWriteResultIsComplete(
            FileWriteResult(
                revision: "rollback", wroteBytes: true,
                durabilityConfirmed: true, cleanupCompleted: false
            )
        ))
    }

    func testGlobalLockInvalidatesInFlightOpenAndRejectsDirectOpen() throws {
        let fixture = makeModel()
        defer { try? FileManager.default.removeItem(at: fixture.sessionURL) }
        let existing = try XCTUnwrap(fixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/open-before-review.swift"),
            content: "existing"
        )))
        let lateFile = openedFile(
            at: URL(fileURLWithPath: "/tmp/open-during-review.swift"),
            content: "late"
        )
        let admission = try XCTUnwrap(
            fixture.model.prepareDocumentOpenAdmission()
        )
        let reviewed = [existing.id: existing.buffer.revision]

        XCTAssertTrue(fixture.model.beginApplicationCloseReview())
        XCTAssertNil(fixture.model.open(openedFile: lateFile))
        XCTAssertNil(fixture.model.completeDocumentOpen(
            lateFile, admission: admission
        ))
        XCTAssertEqual(fixture.model.documents.map(\.id), [existing.id])
        XCTAssertTrue(fixture.model.validateReviewedApplicationClose(
            documentRevisions: reviewed
        ))

        fixture.model.cancelApplicationCloseReview()
        XCTAssertNil(fixture.model.completeDocumentOpen(
            lateFile, admission: admission
        ))
        XCTAssertNotNil(fixture.model.open(openedFile: lateFile))
        XCTAssertTrue(fixture.model.beginApplicationCloseReview())
        fixture.model.commitValidatedApplicationClose(documentRevisions: [:])
        XCTAssertNil(fixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/open-after-commit.swift"),
            content: "committed"
        )))

        let gitFixture = makeModel()
        defer { try? FileManager.default.removeItem(at: gitFixture.sessionURL) }
        let gitAdmission = try XCTUnwrap(gitFixture.model.prepareDocumentOpenAdmission())
        let gitID = UUID()
        XCTAssertTrue(gitFixture.model.acquireGitEditingLock(gitID))
        XCTAssertNil(gitFixture.model.open(openedFile: openedFile(
            at: URL(fileURLWithPath: "/tmp/open-during-git.swift"),
            content: "git"
        )))
        gitFixture.model.releaseGitEditingLock(gitID)
        XCTAssertNil(gitFixture.model.completeDocumentOpen(
            openedFile(
                at: URL(fileURLWithPath: "/tmp/open-after-git.swift"),
                content: "stale"
            ),
            admission: gitAdmission
        ))
    }

    func testRenameRecoveryErrorsRetainArtifactLocationAndNilCleanupWarning() throws {
        let target = URL(fileURLWithPath: "/tmp/project/target.swift")
        let artifact = URL(
            fileURLWithPath: "/tmp/project/.lumen-atomic-write-recovery"
        )
        let stateError = NativeFeatureIntegrationError.renameStateIndeterminate(
            target: target, recoveryArtifact: artifact, rollbackFailure: nil
        )
        XCTAssertTrue(stateError.localizedDescription.contains(artifact.path))
        XCTAssertTrue(
            stateError.localizedDescription(for: .zhCN).contains(artifact.path)
        )

        let cleanupError = NativeFeatureIntegrationError.renameCommitIncomplete(
            target: target,
            issue: RenameWriteCommitIssue(
                durabilityConfirmed: true, cleanupCompleted: false,
                recoveryArtifact: nil
            ),
            rollbackFailure: nil
        )
        XCTAssertTrue(cleanupError.localizedDescription.contains(
            "no recovery artifact path is available"
        ))

        let enriched = try XCTUnwrap(
            NativeFeatureCoordinator.renameIntegrationError(
                stateError, addingRollbackFailure: "rollback conflict"
            )
        )
        XCTAssertTrue(enriched.localizedDescription.contains(artifact.path))
        XCTAssertTrue(enriched.localizedDescription.contains("rollback conflict"))
    }

    private func makeModel() -> (model: AppModel, sessionURL: URL) {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-rename-lock-\(UUID()).json")
        return (
            AppModel(
                sessionStore: SessionStore(sessionURL: sessionURL),
                createInitialDocument: false
            ),
            sessionURL
        )
    }

    private func openedFile(
        at url: URL, content: String, revision: String = "revision"
    ) -> OpenedTextFile {
        OpenedTextFile(
            url: url, content: content, encoding: .utf8, lineEnding: .lf,
            revision: revision, byteLength: Int64(content.utf8.count),
            isBinary: false, isTooLarge: false
        )
    }
}
