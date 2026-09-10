import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class GitControllerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/lumen-git-controller-tests", isDirectory: true)
    private let changedURL = URL(fileURLWithPath: "/tmp/lumen-git-controller-tests/changed.swift")
    private let fileURL = URL(fileURLWithPath: "/tmp/lumen-git-controller-tests/file.swift")

    @MainActor
    func testContextRefreshPublishesSanitizedRemoteURLsWithoutCredentials() async throws {
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success("UU conflicted.swift\0 M changed.swift\0"),
            .success(
                """
                remote.origin.url https://credential-user:fetch-token@example.com/repo.git?auth=fetch-token#private
                remote.origin.pushurl https://push-user:push-token@example.com/write.git?auth=push-token#private
                """
            ),
            .success("refs/heads/main\n"),
            .success("origin\n"),
            .success("origin/main\n"),
            .success("3 2\n"),
            .success("conflicted.swift\0"),
            .success("ours\n"),
            .success("theirs\n")
        ])
        let controller = try makeController(runner: runner)

        await controller.updateContext(
            rootURL: root,
            selectedFileURL: root.appendingPathComponent("changed.swift")
        )

        XCTAssertEqual(controller.status?.branch, "main")
        XCTAssertEqual(controller.status?.entries.map(\.path), ["conflicted.swift", "changed.swift"])
        XCTAssertEqual(controller.status?.tracking?.ahead, 3)
        XCTAssertEqual(controller.status?.tracking?.behind, 2)
        XCTAssertEqual(controller.status?.remotes, [GitRemote(
            name: "origin",
            fetchUrl: "https://example.com/repo.git",
            pushUrl: "https://example.com/write.git"
        )])
        let observableStatus = String(
            decoding: try JSONEncoder().encode(try XCTUnwrap(controller.status)),
            as: UTF8.self
        )
        for credential in [
            "credential-user", "fetch-token", "push-user", "push-token", "auth"
        ] {
            XCTAssertFalse(observableStatus.contains(credential))
        }
        XCTAssertEqual(
            controller.conflicts,
            [GitConflict(path: "conflicted.swift", ours: "Ours", theirs: "Theirs")]
        )
        XCTAssertEqual(controller.selectedRelativePath, "changed.swift")
        XCTAssertEqual(controller.selectedPaths, ["changed.swift"])
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testDiffHunksHistoryAndBlameLoadForSelectedFile() async throws {
        let patch = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            ""
        ].joined(separator: "\n")
        let history = [
            "0123456789abcdef",
            "abc1234",
            "Ada",
            "2026-08-31T12:00:00Z",
            "Change file",
            ""
        ].joined(separator: "\0")
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success(" M file.swift\0"),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success(patch),
            .success(history),
            .success("abc1234 (Ada 2026-08-31 1) let value = 1\n")
        ])
        let controller = try makeController(runner: runner)
        await controller.updateContext(
            rootURL: root,
            selectedFileURL: root.appendingPathComponent("file.swift")
        )

        await controller.loadDiffAndHunks(for: "file.swift")
        XCTAssertEqual(controller.diff, GitDiff(path: "file.swift", diff: patch))
        XCTAssertEqual(controller.hunks.count, 1)
        XCTAssertEqual(controller.selectedHunk?.header, "@@ -1 +1 @@")

        await controller.loadHistory(for: "file.swift")
        XCTAssertEqual(controller.detailKind, .history)
        XCTAssertEqual(controller.history.first?.shortId, "abc1234")
        XCTAssertEqual(controller.history.first?.subject, "Change file")

        await controller.loadBlame(for: "file.swift")
        XCTAssertEqual(controller.detailKind, .blame)
        XCTAssertEqual(controller.blame?.path, "file.swift")
        XCTAssertTrue(controller.blame?.blame.contains("Ada") == true)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testRefreshReturnsFalseWhenBusyAndTrueOnSuccess() async throws {
        let runner = ControllableRefreshGitControllerRunner()
        let controller = GitController(serviceFactory: { rootURL in
            try GitService(rootURL: rootURL, runner: runner)
        })
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let refreshTask = Task { @MainActor in
            await controller.refresh()
        }
        await runner.waitForConflictList()
        let secondRefresh = await controller.refresh()
        XCTAssertFalse(secondRefresh)
        await runner.releaseConflictList()
        let firstRefresh = await refreshTask.value
        XCTAssertTrue(firstRefresh)
    }

    @MainActor
    func testDiscardRequiresExplicitConfirmationBeforeCommandRuns() async throws {
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success("")]
                + statusResults(entries: "", includeConflicts: false)
                + statusResults(entries: "")
        )
        let controller = try makeController(runner: runner)
        await controller.updateContext(
            rootURL: root,
            selectedFileURL: root.appendingPathComponent("file.swift")
        )
        let countBeforeRequest = await runner.receivedCommands().count

        controller.requestDiscard(paths: ["file.swift"])

        XCTAssertEqual(
            controller.pendingDiscard?.target,
            .paths(["file.swift"])
        )
        let countAfterRequest = await runner.receivedCommands().count
        XCTAssertEqual(countAfterRequest, countBeforeRequest)

        let didDiscard = await controller.confirmDiscard()
        XCTAssertTrue(didDiscard)
        XCTAssertNil(controller.pendingDiscard)
        XCTAssertEqual(controller.status?.entries, [])

        let commands = await runner.receivedCommands()
        XCTAssertEqual(commands.count, countBeforeRequest + 7)
        let restore = try XCTUnwrap(commands.dropFirst(countBeforeRequest).first)
        XCTAssertEqual(Array(restore.arguments.suffix(4)), ["restore", "--worktree", "--", "file.swift"])
    }

    @MainActor
    func testDiscardBlocksWhenPreflightRejectsDirtyOpenTab() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: " M file.swift\0"))
        let controller = try makeController(
            runner: runner,
            discardPreflight: { urls in
                XCTAssertEqual(urls, [self.fileURL])
                return .failure(.dirtyDocument(name: "file.swift"))
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)

        controller.requestDiscard(paths: ["file.swift"])
        let didDiscard = await controller.confirmDiscard()

        XCTAssertFalse(didDiscard)
        XCTAssertEqual(controller.issue?.title, "Discard Blocked")
        XCTAssertTrue(controller.issue?.message.contains("dirty tab") == true)
        let commands = await runner.receivedCommands()
        XCTAssertEqual(commands.count, 7)
    }

    @MainActor
    func testDiscardRefreshesOpenCleanDocumentUsingRefreshToken() async throws {
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success("")]
                + statusResults(entries: "", includeConflicts: false)
                + statusResults(entries: "")
        )
        let token = GitDiscardRefreshToken(
            url: fileURL,
            documentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            documentRevision: 12,
            diskRevision: "sha256:abc"
        )
        let refreshRecorder = RefreshRecorder()
        let controller = try makeController(
            runner: runner,
            discardPreflight: { _ in .success(GitDiscardPreflightResult(refreshTokens: [token])) },
            completeDiscardPreflight: { preflight, didDiscard in
                if didDiscard { await refreshRecorder.record(preflight.refreshTokens) }
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)

        controller.requestDiscard(paths: ["file.swift"])
        let didDiscard = await controller.confirmDiscard()

        XCTAssertTrue(didDiscard)
        let refreshedTokens = await refreshRecorder.tokens
        XCTAssertEqual(refreshedTokens, [token])
        let commands = await runner.receivedCommands()
        XCTAssertEqual(commands.count, 14)
    }

    @MainActor
    func testDiscardHunkRequiresConfirmationAndUsesFreshPatchValidation() async throws {
        let patchText = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            ""
        ].joined(separator: "\n")
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success(patchText), .success(patchText), .success("")]
                + statusResults(entries: "", includeConflicts: false)
        )
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        await controller.loadDiffAndHunks(for: "file.swift")
        let hunk = try XCTUnwrap(controller.selectedHunk)
        let commandCountBeforeRequest = await runner.receivedCommands().count

        controller.requestDiscard(hunk: hunk)

        let commandCountAfterRequest = await runner.receivedCommands().count
        XCTAssertEqual(commandCountAfterRequest, commandCountBeforeRequest)
        XCTAssertEqual(controller.pendingDiscard?.affectedPaths, ["file.swift"])

        let didDiscard = await controller.confirmDiscard()
        XCTAssertTrue(didDiscard)
        let commands = await runner.receivedCommands()
        let apply = try XCTUnwrap(commands.first(where: { $0.arguments.contains("apply") }))
        XCTAssertEqual(Array(apply.arguments.suffix(3)), ["apply", "--reverse", "-"])
        XCTAssertEqual(apply.standardInput, Data(hunk.patch.utf8))
    }

    @MainActor
    func testCancelDiscardLeavesRepositoryUntouched() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(
            entries: " M file.swift\0"
        ))
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        let countBeforeRequest = await runner.receivedCommands().count

        controller.requestDiscard(paths: ["file.swift"])
        controller.cancelDiscard()

        XCTAssertNil(controller.pendingDiscard)
        let didDiscard = await controller.confirmDiscard()
        let countAfterCancellation = await runner.receivedCommands().count
        XCTAssertFalse(didDiscard)
        XCTAssertEqual(countAfterCancellation, countBeforeRequest)
    }

    @MainActor
    func testStageCommitAndBranchActionsUseValidatedServiceRequests() async throws {
        var results = statusResults(entries: " M file.swift\0")
        results += [.success("")] + statusResults(entries: "M  file.swift\0", includeConflicts: false)
        results += [.success("")] + statusResults(entries: " M file.swift\0", includeConflicts: false)
        results += [.success("")] + statusResults(entries: "", includeConflicts: false)
        results += [.success("")] + statusResults(branch: "feature/native", entries: "", includeConflicts: false)
        let runner = QueueGitControllerRunner(results: results)
        let controller = try makeController(runner: runner)
        await controller.updateContext(
            rootURL: root,
            selectedFileURL: root.appendingPathComponent("file.swift")
        )

        XCTAssertTrue(controller.requestStage(paths: ["file.swift"]))
        let didStage = await controller.confirmPendingMutation()
        XCTAssertTrue(controller.requestUnstage(paths: ["file.swift"]))
        let didUnstage = await controller.confirmPendingMutation()
        XCTAssertTrue(controller.requestCommit(message: "Native Git UI"))
        let didCommit = await controller.confirmPendingMutation()
        XCTAssertTrue(controller.requestCreateBranch("feature/native"))
        let didCreateBranch = await controller.confirmPendingMutation()
        XCTAssertTrue(didStage)
        XCTAssertTrue(didUnstage)
        XCTAssertTrue(didCommit)
        XCTAssertTrue(didCreateBranch)

        let receivedCommands = await runner.receivedCommands()
        let commands = receivedCommands.map(\.arguments)
        XCTAssertTrue(commands.contains(where: {
            Array($0.suffix(3)) == ["add", "--", "file.swift"]
        }))
        XCTAssertTrue(commands.contains(where: {
            Array($0.suffix(4)) == ["restore", "--staged", "--", "file.swift"]
        }))
        XCTAssertTrue(commands.contains(where: {
            Array($0.suffix(3)) == ["commit", "-m", "Native Git UI"]
        }))
        XCTAssertTrue(commands.contains(where: {
            Array($0.suffix(3)) == ["switch", "-c", "feature/native"]
        }))
        XCTAssertEqual(controller.status?.branch, "feature/native")
    }

    @MainActor
    func testMutationRequestsSnapshotInputsAndRequireConfirmation() async throws {
        var results = statusResults(entries: " M file.swift\0")
        results += [.success("")] + statusResults(
            entries: "M  file.swift\0", includeConflicts: false
        )
        let runner = QueueGitControllerRunner(results: results)
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        let commandCount = await runner.receivedCommands().count

        XCTAssertTrue(controller.requestStage(paths: ["file.swift"]))
        XCTAssertEqual(controller.pendingConfirmation?.target, .stagePaths(["file.swift"]))
        let commandsAfterRequest = await runner.receivedCommands()
        XCTAssertEqual(commandsAfterRequest.count, commandCount)

        let confirmed = await controller.confirmPendingMutation()
        XCTAssertTrue(confirmed)
        XCTAssertNil(controller.pendingConfirmation)
        let commandsAfterConfirm = await runner.receivedCommands()
        XCTAssertTrue(commandsAfterConfirm.contains(where: {
            Array($0.arguments.suffix(3)) == ["add", "--", "file.swift"]
        }))
    }

    @MainActor
    func testStageHunkRequiresConfirmationAndUsesSnapshotPatch() async throws {
        let patch = [
            "diff --git a/file.swift b/file.swift", "--- a/file.swift",
            "+++ b/file.swift", "@@ -1 +1 @@", "-old", "+new", ""
        ].joined(separator: "\n")
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success(patch), .success(patch), .success("")]
                + statusResults(entries: "M  file.swift\0", includeConflicts: false)
        )
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        await controller.loadDiffAndHunks(for: "file.swift")
        let hunk = try XCTUnwrap(controller.selectedHunk)
        let commandCount = await runner.receivedCommands().count

        XCTAssertTrue(controller.requestStage(hunk: hunk))
        XCTAssertEqual(controller.pendingConfirmation?.target, .stageHunk(hunk))
        let commandsAfterRequest = await runner.receivedCommands()
        XCTAssertEqual(commandsAfterRequest.count, commandCount)

        let didConfirm = await controller.confirmPendingMutation()
        XCTAssertTrue(didConfirm)
        let commands = await runner.receivedCommands()
        let apply = try XCTUnwrap(commands.first(where: { $0.arguments.contains("apply") }))
        XCTAssertEqual(Array(apply.arguments.suffix(3)), ["apply", "--cached", "-"])
        XCTAssertEqual(apply.standardInput, Data(hunk.patch.utf8))
    }

    @MainActor
    func testRefreshCannotInvalidateVisibleConfirmationBehindUser() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: " M file.swift\0"))
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        XCTAssertTrue(controller.requestStage(paths: ["file.swift"]))

        let didRefresh = await controller.refresh()

        XCTAssertFalse(didRefresh)
        XCTAssertEqual(controller.pendingConfirmation?.target, .stagePaths(["file.swift"]))
    }

    @MainActor
    func testCancelConfirmationDoesNotMutateRepository() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: " M file.swift\0"))
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        let commandCount = await runner.receivedCommands().count

        XCTAssertTrue(controller.requestCommit(message: "  snapshot message  "))
        XCTAssertEqual(
            controller.pendingConfirmation?.target, .commit(message: "snapshot message")
        )
        controller.cancelConfirmation()

        let confirmed = await controller.confirmPendingMutation()
        let commandsAfterCancel = await runner.receivedCommands()
        XCTAssertFalse(confirmed)
        XCTAssertEqual(commandsAfterCancel.count, commandCount)
    }

    @MainActor
    func testBranchPreflightFailureBlocksMutationWithTypedIssue() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = try makeController(
            runner: runner,
            branchPreflight: { rootURL in
                XCTAssertEqual(rootURL, self.root)
                return .failure(.externalConflict(name: "file.swift"))
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        let commandCount = await runner.receivedCommands().count

        XCTAssertTrue(controller.requestCheckoutBranch(" feature/native "))
        XCTAssertEqual(
            controller.pendingConfirmation?.target,
            .checkoutBranch(name: "feature/native")
        )
        let confirmed = await controller.confirmPendingMutation()
        XCTAssertFalse(confirmed)

        XCTAssertEqual(
            controller.issue?.content,
            .branchPreflight(.externalConflict(name: "file.swift"))
        )
        let commandsAfterPreflight = await runner.receivedCommands()
        XCTAssertEqual(commandsAfterPreflight.count, commandCount)
    }

    @MainActor
    func testBranchWorkspacePreflightScopesDocumentsAndCapturesCleanTokens() throws {
        let clean = EditorDocument(
            id: UUID(), fileURL: fileURL, displayName: "file.swift",
            text: "clean", savedText: "clean", diskRevision: "disk-clean"
        )
        let outside = EditorDocument(
            fileURL: URL(fileURLWithPath: "/tmp/outside.swift"),
            displayName: "outside.swift", text: "dirty", savedText: "saved"
        )
        let untitled = EditorDocument(untitledName: "Untitled")
        untitled.text = "dirty but not in worktree"

        let result = GitBranchWorkspacePreflight.evaluate(
            rootURL: root, documents: [outside, untitled, clean]
        )
        guard case let .success(preflight) = result else {
            return XCTFail("Expected branch preflight to accept clean worktree documents")
        }
        let tokens = preflight.refreshTokens

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.url, fileURL)
        XCTAssertEqual(tokens.first?.documentID, clean.id)
        XCTAssertEqual(tokens.first?.documentRevision, clean.buffer.revision)
        XCTAssertEqual(tokens.first?.diskRevision, "disk-clean")
    }

    @MainActor
    func testBranchWorkspaceContainmentUsesCanonicalPathComponents() throws {
        XCTAssertTrue(GitBranchWorkspacePreflight.contains(
            rootURL: root, candidateURL: root
        ))
        XCTAssertTrue(GitBranchWorkspacePreflight.contains(
            rootURL: root, candidateURL: root.appendingPathComponent("Sources/File.swift")
        ))
        XCTAssertFalse(GitBranchWorkspacePreflight.contains(
            rootURL: root,
            candidateURL: URL(fileURLWithPath: root.path + "-sibling/File.swift")
        ))

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-git-preflight-symlink-\(UUID())", isDirectory: true)
        let physicalRoot = temporaryRoot.appendingPathComponent("physical", isDirectory: true)
        let logicalRoot = temporaryRoot.appendingPathComponent("logical", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalRoot, withIntermediateDirectories: true
        )
        do {
            try FileManager.default.createSymbolicLink(
                at: logicalRoot, withDestinationURL: physicalRoot
            )
        } catch {
            throw XCTSkip("Symbolic links are unavailable in this test environment: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertTrue(GitBranchWorkspacePreflight.contains(
            rootURL: logicalRoot,
            candidateURL: physicalRoot.appendingPathComponent("File.swift")
        ))

        let externalRoot = temporaryRoot.appendingPathComponent("external", isDirectory: true)
        let linkedFile = logicalRoot.appendingPathComponent("external-link.swift")
        try FileManager.default.createDirectory(
            at: externalRoot, withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(
            to: externalRoot.appendingPathComponent("File.swift")
        )
        try FileManager.default.createSymbolicLink(
            at: linkedFile,
            withDestinationURL: externalRoot.appendingPathComponent("File.swift")
        )
        XCTAssertTrue(GitBranchWorkspacePreflight.contains(
            rootURL: logicalRoot, candidateURL: linkedFile
        ))
    }

    @MainActor
    func testBranchWorkspacePreflightBlocksSavingDirtyAndExternalConflict() {
        let saving = EditorDocument(
            fileURL: fileURL, displayName: "saving.swift", text: "same", savedText: "same"
        )
        saving.setSaving(true)
        XCTAssertEqual(branchPreflightFailure(for: [saving]), .savingDocument(name: "saving.swift"))

        let dirty = EditorDocument(
            fileURL: fileURL, displayName: "dirty.swift", text: "new", savedText: "old"
        )
        XCTAssertEqual(branchPreflightFailure(for: [dirty]), .dirtyDocument(name: "dirty.swift"))

        let conflicted = EditorDocument(
            fileURL: fileURL, displayName: "conflicted.swift", text: "same",
            savedText: "same",
            externalConflict: ExternalConflict(kind: .modified, url: fileURL)
        )
        XCTAssertEqual(
            branchPreflightFailure(for: [conflicted]),
            .externalConflict(name: "conflicted.swift")
        )
    }

    @MainActor
    func testBranchPreflightChecksDiskOnlyForCurrentWorktreeDocuments() async {
        let inside = EditorDocument(
            fileURL: fileURL, displayName: "inside.swift", text: "same", savedText: "same"
        )
        let outside = EditorDocument(
            fileURL: URL(fileURLWithPath: "/tmp/outside.swift"),
            displayName: "outside.swift", text: "same", savedText: "same"
        )
        let untitled = EditorDocument(untitledName: "Untitled")
        var checked: [UUID] = []

        _ = await GitBranchWorkspacePreflight.evaluateAfterCheckingDisk(
            rootURL: root, documents: [outside, untitled, inside],
            checkExternalChange: { checked.append($0.id) }
        )

        XCTAssertEqual(checked, [inside.id])
    }


    @MainActor
    func testBranchPreflightLockClosesEditRaceAndCanBeReleased() throws {
        let document = EditorDocument(
            fileURL: fileURL, displayName: "file.swift", text: "clean",
            savedText: "clean", diskRevision: "disk-clean"
        )
        let result = GitBranchWorkspacePreflight.evaluate(
            rootURL: root, documents: [document]
        )
        guard case let .success(preflight) = result else {
            return XCTFail("Expected clean branch preflight")
        }
        let lockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: preflight.refreshTokens, documents: [document]
        ))
        XCTAssertTrue(document.isEditingLocked)

        document.text = "attempted edit"
        XCTAssertEqual(document.text, "clean")

        GitBranchWorkspacePreflight.unlock(
            tokens: preflight.refreshTokens, lockID: lockID, documents: [document]
        )
        XCTAssertFalse(document.isEditingLocked)
        document.text = "edit after unlock"
        XCTAssertEqual(document.text, "edit after unlock")
    }

    @MainActor
    func testGitAndTerminationEditingLocksReleaseOnlyTheirOwner() throws {
        let document = EditorDocument(
            fileURL: fileURL, displayName: "file.swift", text: "clean",
            savedText: "clean", diskRevision: "disk-clean"
        )
        let result = GitBranchWorkspacePreflight.evaluate(rootURL: root, documents: [document])
        guard case let .success(preflight) = result else {
            return XCTFail("Expected clean branch preflight")
        }

        let gitLockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: preflight.refreshTokens, documents: [document]
        ))
        document.lockEditingForTermination()
        GitBranchWorkspacePreflight.unlock(
            tokens: preflight.refreshTokens, lockID: gitLockID, documents: [document]
        )
        XCTAssertTrue(document.isEditingLocked)

        document.unlockEditingAfterTerminationCancellation()
        XCTAssertFalse(document.isEditingLocked)

        document.lockEditingForTermination()
        let secondGitLockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: preflight.refreshTokens, documents: [document]
        ))
        document.unlockEditingAfterTerminationCancellation()
        XCTAssertTrue(document.isEditingLocked)
        GitBranchWorkspacePreflight.unlock(
            tokens: preflight.refreshTokens, lockID: secondGitLockID, documents: [document]
        )
        XCTAssertFalse(document.isEditingLocked)

        // A committed termination lock is permanent and a Git release must
        // never clear it.
        let commitSessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-git-commit-lock-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: commitSessionURL) }
        let commitModel = AppModel(
            sessionStore: SessionStore(sessionURL: commitSessionURL),
            createInitialDocument: false
        )
        let committedDocument = try XCTUnwrap(commitModel.open(openedFile: OpenedTextFile(
            url: fileURL, content: "clean", encoding: .utf8, lineEnding: .lf,
            revision: "disk-clean", byteLength: 5, isBinary: false, isTooLarge: false
        )))
        let commitResult = GitBranchWorkspacePreflight.evaluate(
            rootURL: root, documents: commitModel.documents
        )
        guard case let .success(commitPreflight) = commitResult else {
            return XCTFail("Expected clean branch preflight")
        }
        let commitGitLockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: commitPreflight.refreshTokens, documents: commitModel.documents
        ))
        XCTAssertTrue(commitModel.beginApplicationCloseReview())
        commitModel.commitValidatedApplicationClose(documentRevisions: [:])

        GitBranchWorkspacePreflight.unlock(
            tokens: commitPreflight.refreshTokens, lockID: commitGitLockID,
            documents: commitModel.documents
        )
        XCTAssertTrue(committedDocument.isEditingLocked)
        committedDocument.text = "must stay locked"
        XCTAssertEqual(committedDocument.text, "clean")

        // Cancellation releases only termination's owner; Git stays locked
        // until its own token is released.
        let cancelSessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-git-lock-session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cancelSessionURL) }
        let cancelModel = AppModel(
            sessionStore: SessionStore(sessionURL: cancelSessionURL),
            createInitialDocument: false
        )
        let cancelDocument = try XCTUnwrap(cancelModel.open(openedFile: OpenedTextFile(
            url: fileURL, content: "clean", encoding: .utf8, lineEnding: .lf,
            revision: "disk-clean", byteLength: 5, isBinary: false, isTooLarge: false
        )))
        let cancelResult = GitBranchWorkspacePreflight.evaluate(
            rootURL: root, documents: cancelModel.documents
        )
        guard case let .success(cancelPreflight) = cancelResult else {
            return XCTFail("Expected clean branch preflight")
        }
        let cancelGitLockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: cancelPreflight.refreshTokens, documents: cancelModel.documents
        ))
        XCTAssertTrue(cancelModel.acquireGitEditingLock(cancelGitLockID))
        XCTAssertTrue(cancelModel.beginApplicationCloseReview())

        GitBranchWorkspacePreflight.unlock(
            tokens: cancelPreflight.refreshTokens, lockID: cancelGitLockID,
            documents: cancelModel.documents
        )
        XCTAssertTrue(cancelDocument.isEditingLocked)
        XCTAssertTrue(cancelModel.isTextEditingLocked)

        cancelModel.cancelApplicationCloseReview()
        XCTAssertTrue(cancelModel.isTextEditingLocked)
        cancelModel.releaseGitEditingLock(cancelGitLockID)
        XCTAssertFalse(cancelDocument.isEditingLocked)
        XCTAssertFalse(cancelModel.isTextEditingLocked)
    }

    @MainActor
    func testGitBranchReopenRetainsOwnerLockDuringReadAndReleasesAfterward() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-git-reopen-\(UUID())", isDirectory: true)
        let url = directory.appendingPathComponent("file.swift")
        let sessionURL = directory.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("before".utf8).write(to: url)
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: sessionURL), createInitialDocument: false
        )
        let document = try XCTUnwrap(model.open(openedFile: TextFileCodec.read(from: url)))
        let result = GitBranchWorkspacePreflight.evaluate(
            rootURL: directory, documents: model.documents
        )
        guard case let .success(preflight) = result else {
            return XCTFail("Expected clean branch preflight")
        }
        let lockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: preflight.refreshTokens, documents: model.documents
        ))
        XCTAssertTrue(model.acquireGitEditingLock(lockID))
        try Data("after".utf8).write(to: url)

        let reopened = await model.reopenAfterGitMutation(
            document, lockID: lockID, using: nil
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(document.text, "after")
        XCTAssertFalse(document.isEditingLocked)
        model.releaseGitEditingLock(lockID)
        XCTAssertFalse(model.isTextEditingLocked)

        // A post-switch read failure is surfaced as an explicit conflict; the
        // old branch buffer is never left looking clean and current.
        let secondResult = GitBranchWorkspacePreflight.evaluate(
            rootURL: directory, documents: model.documents
        )
        guard case let .success(secondPreflight) = secondResult else {
            return XCTFail("Expected second clean branch preflight")
        }
        let secondLockID = try XCTUnwrap(GitBranchWorkspacePreflight.lock(
            tokens: secondPreflight.refreshTokens, documents: model.documents
        ))
        try FileManager.default.removeItem(at: url)
        let missingReopen = await model.reopenAfterGitMutation(
            document, lockID: secondLockID, using: nil
        )
        XCTAssertFalse(missingReopen)
        XCTAssertEqual(document.externalConflict?.kind, .missing)
        XCTAssertNotNil(model.presentedIssue)
        XCTAssertFalse(document.isEditingLocked)
    }

    @MainActor
    private func branchPreflightFailure(
        for documents: [EditorDocument]
    ) -> GitBranchPreflightError? {
        switch GitBranchWorkspacePreflight.evaluate(rootURL: root, documents: documents) {
        case .success: return nil
        case let .failure(error): return error
        }
    }

    @MainActor
    func testBranchSuccessRefreshesOnlyPreflightSnapshotTokens() async throws {
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 9, diskRevision: "rev"
        )
        var results = statusResults(entries: "")
        results += [.success("")] + statusResults(
            branch: "feature/native", entries: "", includeConflicts: false
        )
        let runner = QueueGitControllerRunner(results: results)
        let recorder = RefreshRecorder()
        let controller = try makeController(
            runner: runner,
            branchPreflight: { _ in .success(.init(refreshTokens: [token])) },
            completeBranchPreflight: { preflight, _ in
                await recorder.record(preflight.refreshTokens)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        XCTAssertTrue(controller.requestCheckoutBranch("feature/native"))
        let confirmed = await controller.confirmPendingMutation()
        XCTAssertTrue(confirmed)

        let refreshedTokens = await recorder.tokens
        let commands = await runner.receivedCommands()
        XCTAssertEqual(refreshedTokens, [token])
        XCTAssertTrue(commands.contains(where: {
            Array($0.arguments.suffix(2)) == ["switch", "feature/native"]
        }))
    }

    @MainActor
    func testBranchFailureStillCompletesPreflightAndReleasesLock() async throws {
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 1, diskRevision: "rev"
        )
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: "") + [.failure(code: 1, error: "switch failed")]
        )
        let completion = BranchCompletionRecorder()
        let controller = try makeController(
            runner: runner,
            branchPreflight: { _ in .success(.init(refreshTokens: [token], lockID: UUID())) },
            completeBranchPreflight: { result, didChange in
                await completion.record(result, didChange: didChange)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCheckoutBranch("feature/native"))

        let confirmed = await controller.confirmPendingMutation()

        let didChange = await completion.didChange
        let completedTokens = await completion.tokens
        XCTAssertFalse(confirmed)
        XCTAssertFalse(didChange)
        XCTAssertEqual(completedTokens, [token])
    }

    @MainActor
    func testBranchCommandSuccessStillReconcilesWhenStatusRefreshIsCancelled() async throws {
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 3, diskRevision: "rev"
        )
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: "") + [.success(""), .thrown(.cancelled)]
        )
        let completion = BranchCompletionRecorder()
        let controller = try makeController(
            runner: runner,
            branchPreflight: { _ in .success(.init(refreshTokens: [token])) },
            completeBranchPreflight: { result, didChange in
                await completion.record(result, didChange: didChange)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCheckoutBranch("feature/native"))

        let confirmed = await controller.confirmPendingMutation()
        let didChange = await completion.didChange
        let completedTokens = await completion.tokens

        XCTAssertTrue(confirmed)
        XCTAssertTrue(didChange)
        XCTAssertEqual(completedTokens, [token])
    }

    @MainActor
    func testDiscardCommandSuccessStillReconcilesWhenStatusRefreshFails() async throws {
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 4, diskRevision: "rev"
        )
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success(""), .failure(code: 128, error: "status failed")]
        )
        let completion = DiscardCompletionRecorder()
        let controller = try makeController(
            runner: runner,
            discardPreflight: { _ in .success(.init(refreshTokens: [token])) },
            completeDiscardPreflight: { result, didDiscard in
                await completion.record(result, didDiscard: didDiscard)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        controller.requestDiscard(paths: ["file.swift"])

        let confirmed = await controller.confirmDiscard()
        let didDiscard = await completion.didDiscard
        let completedTokens = await completion.tokens

        XCTAssertTrue(confirmed)
        XCTAssertTrue(didDiscard)
        XCTAssertEqual(completedTokens, [token])
        XCTAssertEqual(controller.issue?.title, "Git Operation Failed")
    }

    @MainActor
    func testRootSwitchDuringRunningBranchMutationReconcilesIndeterminateDiskState() async throws {
        let nextRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-indeterminate-next",
            isDirectory: true
        )
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 5, diskRevision: "rev"
        )
        let oldRunner = DestructiveCancellationGitControllerRunner()
        let nextRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let completion = BranchCompletionRecorder()
        let controller = GitController(
            serviceFactory: { rootURL in
                try GitService(
                    rootURL: rootURL, runner: rootURL == self.root ? oldRunner : nextRunner
                )
            },
            branchPreflight: { _ in .success(.init(refreshTokens: [token])) },
            completeBranchPreflight: { result, requiresReconciliation in
                await completion.record(result, didChange: requiresReconciliation)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCheckoutBranch("feature/native"))
        let confirmation = Task { @MainActor in await controller.confirmPendingMutation() }
        await oldRunner.waitUntilMutationStarted()

        let rootSwitch = Task { @MainActor in
            await controller.updateContext(rootURL: nextRoot, selectedFileURL: nil)
        }
        await oldRunner.waitUntilCancellationRequested()
        await oldRunner.finishCancellation()
        await rootSwitch.value
        let confirmed = await confirmation.value
        let reconciled = await completion.didChange
        let completedTokens = await completion.tokens

        XCTAssertFalse(confirmed)
        XCTAssertTrue(reconciled)
        XCTAssertEqual(completedTokens, [token])
        XCTAssertEqual(controller.rootURL, nextRoot)
    }

    @MainActor
    func testShutdownWaitsForBranchCompletionCallback() async throws {
        let token = GitDiscardRefreshToken(
            url: fileURL, documentID: UUID(), documentRevision: 1, diskRevision: "rev"
        )
        var results = statusResults(entries: "")
        results += [.success("")] + statusResults(
            branch: "feature/native", entries: "", includeConflicts: false
        )
        let runner = QueueGitControllerRunner(results: results)
        let completion = ControllableBranchCompletion()
        let controller = try makeController(
            runner: runner,
            branchPreflight: { _ in .success(.init(refreshTokens: [token])) },
            completeBranchPreflight: { result, didChange in
                await completion.complete(result, didChange: didChange)
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCheckoutBranch("feature/native"))
        let confirmation = Task { @MainActor in await controller.confirmPendingMutation() }
        await completion.waitUntilCalled()

        let shutdown = Task { @MainActor in await controller.shutdown() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.isConfirmingMutation)

        await completion.release()
        await shutdown.value
        _ = await confirmation.value
        XCTAssertFalse(controller.isConfirmingMutation)
        XCTAssertNil(controller.pendingConfirmation)
    }

    @MainActor
    func testRootSwitchClearsPendingMutationConfirmation() async throws {
        let nextRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-confirmation-next",
            isDirectory: true
        )
        let firstRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let nextRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = GitController(serviceFactory: { rootURL in
            try GitService(
                rootURL: rootURL, runner: rootURL == self.root ? firstRunner : nextRunner
            )
        })
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCommit(message: "old root"))

        await controller.updateContext(rootURL: nextRoot, selectedFileURL: nil)

        XCTAssertNil(controller.pendingConfirmation)
        XCTAssertFalse(controller.isConfirmingMutation)
        let didConfirm = await controller.confirmPendingMutation()
        XCTAssertFalse(didConfirm)
    }

    @MainActor
    func testShutdownClearsPendingMutationConfirmation() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCreateBranch("feature/native"))

        await controller.shutdown()

        XCTAssertNil(controller.pendingConfirmation)
        XCTAssertFalse(controller.isConfirmingMutation)
        let didConfirm = await controller.confirmPendingMutation()
        XCTAssertFalse(didConfirm)
    }

    @MainActor
    func testRootSwitchDuringBranchPreflightCannotRunStaleTarget() async throws {
        let nextRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-preflight-next",
            isDirectory: true
        )
        let firstRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let nextRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let preflight = ControllableBranchPreflight()
        let controller = GitController(
            serviceFactory: { rootURL in
                try GitService(
                    rootURL: rootURL, runner: rootURL == self.root ? firstRunner : nextRunner
                )
            },
            branchPreflight: { rootURL in await preflight.check(rootURL) }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCheckoutBranch("stale-target"))
        let confirmation = Task { @MainActor in
            await controller.confirmPendingMutation()
        }
        await preflight.waitUntilCalled()
        XCTAssertTrue(controller.isConfirmingMutation)

        let rootSwitch = Task { @MainActor in
            await controller.updateContext(rootURL: nextRoot, selectedFileURL: nil)
        }
        await preflight.release()
        await rootSwitch.value
        let didConfirm = await confirmation.value

        XCTAssertFalse(didConfirm)
        XCTAssertNil(controller.pendingConfirmation)
        XCTAssertFalse(controller.isConfirmingMutation)
        let firstCommands = await firstRunner.receivedCommands()
        let nextCommands = await nextRunner.receivedCommands()
        XCTAssertFalse(firstCommands.contains(where: { $0.arguments.contains("stale-target") }))
        XCTAssertFalse(nextCommands.contains(where: { $0.arguments.contains("stale-target") }))
    }

    @MainActor
    func testShutdownDuringBranchPreflightCannotRunStaleTarget() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let preflight = ControllableBranchPreflight()
        let controller = try makeController(
            runner: runner, branchPreflight: { rootURL in await preflight.check(rootURL) }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        XCTAssertTrue(controller.requestCreateBranch("stale-target"))
        let confirmation = Task { @MainActor in
            await controller.confirmPendingMutation()
        }
        await preflight.waitUntilCalled()

        let shutdown = Task { @MainActor in await controller.shutdown() }
        await preflight.release()
        await shutdown.value
        let didConfirm = await confirmation.value

        XCTAssertFalse(didConfirm)
        XCTAssertNil(controller.pendingConfirmation)
        XCTAssertFalse(controller.isConfirmingMutation)
        let commands = await runner.receivedCommands()
        XCTAssertFalse(commands.contains(where: { $0.arguments.contains("stale-target") }))
    }

    @MainActor
    func testDiscardPreflightBlocksConcurrentRefreshAndNewConfirmation() async throws {
        let preflight = ControllableDiscardPreflight()
        let runner = QueueGitControllerRunner(results:
            statusResults(entries: " M file.swift\0")
                + [.success("")]
                + statusResults(entries: "", includeConflicts: false)
                + statusResults(entries: "")
        )
        let controller = try makeController(
            runner: runner,
            discardPreflight: { urls in await preflight.check(urls) }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        controller.requestDiscard(paths: ["file.swift"])
        let request = controller.pendingDiscard
        let confirmation = Task { @MainActor in await controller.confirmDiscard() }
        await preflight.waitUntilCalled()

        XCTAssertTrue(controller.isConfirmingMutation)
        XCTAssertEqual(controller.pendingDiscard, request)
        let didRefresh = await controller.refresh()
        XCTAssertFalse(didRefresh)
        XCTAssertFalse(controller.requestStage(paths: ["file.swift"]))
        XCTAssertEqual(controller.pendingDiscard, request)

        await preflight.release()
        let didConfirm = await confirmation.value
        XCTAssertTrue(didConfirm)
        XCTAssertFalse(controller.isConfirmingMutation)
        XCTAssertNil(controller.pendingDiscard)
    }

    @MainActor
    func testRootSwitchDuringDiscardPreflightCannotRunStaleTarget() async throws {
        let nextRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-discard-next",
            isDirectory: true
        )
        let firstRunner = QueueGitControllerRunner(
            results: statusResults(entries: " M file.swift\0")
        )
        let nextRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let preflight = ControllableDiscardPreflight()
        let controller = GitController(
            serviceFactory: { rootURL in
                try GitService(
                    rootURL: rootURL, runner: rootURL == self.root ? firstRunner : nextRunner
                )
            },
            discardPreflight: { urls in await preflight.check(urls) }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        controller.requestDiscard(paths: ["file.swift"])
        let confirmation = Task { @MainActor in await controller.confirmDiscard() }
        await preflight.waitUntilCalled()

        let rootSwitch = Task { @MainActor in
            await controller.updateContext(rootURL: nextRoot, selectedFileURL: nil)
        }
        await preflight.release()
        await rootSwitch.value
        let didConfirm = await confirmation.value

        XCTAssertFalse(didConfirm)
        XCTAssertNil(controller.pendingDiscard)
        XCTAssertFalse(controller.isConfirmingMutation)
        let firstCommands = await firstRunner.receivedCommands()
        let nextCommands = await nextRunner.receivedCommands()
        XCTAssertFalse(firstCommands.contains(where: { $0.arguments.contains("restore") }))
        XCTAssertFalse(nextCommands.contains(where: { $0.arguments.contains("restore") }))
    }

    @MainActor
    func testInvalidSelectedURLCannotEscapeRoot() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: " M file.swift\0"))
        let controller = try makeController(runner: runner)

        await controller.updateContext(
            rootURL: root,
            selectedFileURL: URL(fileURLWithPath: "/tmp/outside.swift")
        )

        XCTAssertNil(controller.selectedRelativePath)
        XCTAssertNil(controller.fileURL(for: "../outside.swift"))
        XCTAssertNil(controller.fileURL(for: "/tmp/outside.swift"))
    }

    @MainActor
    func testOpenFileUsesInjectedWorktreeOpener() async throws {
        let runner = QueueGitControllerRunner(results: statusResults(entries: " M file.swift\0"))
        let opened = URLRecorder()
        let controller = try makeController(
            runner: runner,
            openWorktreeFile: { url in
                await opened.record(url)
                return true
            }
        )

        await controller.updateContext(rootURL: root, selectedFileURL: fileURL)
        let didOpen = await controller.openFile("file.swift")

        XCTAssertTrue(didOpen)
        let openedURLs = await opened.urls
        XCTAssertEqual(openedURLs, [fileURL])
    }

    @MainActor
    func testProcessFailureDoesNotExposePotentiallySensitiveStderr() async throws {
        let runner = QueueGitControllerRunner(results: [
            .failure(code: 1, error: "https://user:super-secret@example.com/repo.git failed")
        ])
        let controller = try makeController(runner: runner)

        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        XCTAssertEqual(controller.issue?.title, "Git Operation Failed")
        XCTAssertFalse(controller.issue?.message.contains("super-secret") == true)
        XCTAssertTrue(controller.issue?.message.contains("status 1") == true)
    }

    @MainActor
    func testNonRepositoryStatusDoesNotRequestConflicts() async throws {
        let runner = QueueGitControllerRunner(results: [
            .failure(code: 128, error: "fatal: not a git repository")
        ])
        let controller = try makeController(runner: runner)

        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        XCTAssertEqual(controller.status, GitStatus(available: false, entries: []))
        XCTAssertEqual(controller.conflicts, [])
        XCTAssertNil(controller.issue)
        let commands = await runner.receivedCommands()
        XCTAssertEqual(commands.count, 1)
    }

    @MainActor
    func testLoadConflictsReturnsFalseWhenBusyAndTrueOnSuccess() async throws {
        let runner = ControllableRefreshGitControllerRunner()
        let controller = GitController(serviceFactory: { rootURL in
            try GitService(rootURL: rootURL, runner: runner)
        })
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let refreshTask = Task { @MainActor in
            await controller.refresh()
        }
        await runner.waitForConflictList()
        let loadWhileBusy = await controller.loadConflicts()
        XCTAssertFalse(loadWhileBusy)
        await runner.releaseConflictList()
        _ = await refreshTask.value

        let loadAfterIdle = await controller.loadConflicts()
        XCTAssertTrue(loadAfterIdle)
    }

    @MainActor
    func testOpenConflictCompareBuildsSideSnapshotsThroughController() async throws {
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success("UU conflicted.swift\0"),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("conflicted.swift\0"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("ours\n"),
            .success("theirs\n")
        ])
        let presented = ConflictOpenRecorder()
        let controller = GitController(
            serviceFactory: { rootURL in
                try GitService(rootURL: rootURL, runner: runner)
            },
            presentConflict: { request in
                await presented.record(request)
                return true
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let conflict = try XCTUnwrap(controller.conflictPresentations.first)
        let didOpen = await controller.openConflict(.compare, conflict: conflict)

        XCTAssertTrue(didOpen)
        let presentedRequest = await presented.lastRequest
        let request = try XCTUnwrap(presentedRequest)
        XCTAssertEqual(request.target, .compare)
        XCTAssertEqual(request.path, "conflicted.swift")
        XCTAssertEqual(request.ours?.content, "ours\n")
        XCTAssertEqual(request.theirs?.content, "theirs\n")
    }

    @MainActor
    func testOpenAllWorktreeConflictsReturnsNoChangeWhenRepositoryHasNoConflicts() async throws {
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success(" M file.swift\0"),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("")
        ])
        let controller = try makeController(runner: runner)
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let result = await controller.openAllWorktreeConflicts()

        XCTAssertEqual(result, .noChange)
    }

    @MainActor
    func testOpenAllWorktreeConflictsOpensEachConflictUntilComplete() async throws {
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success("UU first.swift\0UU second.swift\0"),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("first.swift\0second.swift\0"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("first.swift\0second.swift\0"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("ours\n"),
            .success("theirs\n")
        ])
        let opened = OpenedConflictRecorder()
        let controller = try makeController(
            runner: runner,
            presentConflict: { request in
                await opened.record(request)
                return true
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let result = await controller.openAllWorktreeConflicts()

        XCTAssertEqual(result, .opened(count: 2))
        let openedPaths = await opened.paths
        XCTAssertEqual(openedPaths, ["first.swift", "second.swift"])
    }

    @MainActor
    func testOpenAllWorktreeConflictsStopsOnFirstOpenFailureAndKeepsIssue() async throws {
        let runner = QueueGitControllerRunner(results: [
            .success("main\n"),
            .success("UU first.swift\0UU second.swift\0"),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("first.swift\0second.swift\0"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("first.swift\0second.swift\0"),
            .success("ours\n"),
            .success("theirs\n"),
            .success("ours\n"),
            .success("theirs\n")
        ])
        let attempts = OpenedConflictRecorder()
        let controller = try makeController(
            runner: runner,
            presentConflict: { request in
                await attempts.record(request)
                return request.path == "first.swift"
            }
        )
        await controller.updateContext(rootURL: root, selectedFileURL: nil)

        let result = await controller.openAllWorktreeConflicts()

        XCTAssertEqual(result, .failed(openedCount: 1))
        let attemptedPaths = await attempts.paths
        XCTAssertEqual(attemptedPaths, ["first.swift", "second.swift"])
        XCTAssertEqual(controller.issue?.title, "Git Operation Failed")
        XCTAssertTrue(controller.issue?.message.contains("second.swift") == true)
    }

    @MainActor
    func testStaleDetailResultIsIgnoredAfterSelectionChanges() async throws {
        let runner = ControllableGitControllerRunner()
        let controller = GitController(serviceFactory: { rootURL in
            try GitService(rootURL: rootURL, runner: runner)
        })
        await controller.updateContext(
            rootURL: root,
            selectedFileURL: root.appendingPathComponent("first.swift")
        )

        let loadTask = Task { @MainActor in
            await controller.loadDiff(for: "first.swift")
        }
        await runner.waitForDiff()
        controller.updateSelectedFile(root.appendingPathComponent("second.swift"))
        await runner.releaseDiff(with: "stale secret diff")
        await loadTask.value

        XCTAssertEqual(controller.activePath, "second.swift")
        XCTAssertNil(controller.diff)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testRootSwitchWaitsForOldServiceShutdownBeforeStartingNewRoot() async throws {
        let oldRoot = root
        let newRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-tests-new",
            isDirectory: true
        )
        let oldRunner = BlockingShutdownGitControllerRunner()
        let newRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = GitController(serviceFactory: { rootURL in
            if rootURL == oldRoot {
                return try GitService(rootURL: rootURL, runner: oldRunner)
            }
            return try GitService(rootURL: rootURL, runner: newRunner)
        })
        let initial = Task { @MainActor in
            await controller.updateContext(rootURL: oldRoot, selectedFileURL: nil)
        }
        await oldRunner.waitUntilCommandStarts()

        let switched = Task { @MainActor in
            await controller.updateContext(rootURL: newRoot, selectedFileURL: nil)
        }
        await oldRunner.waitUntilCancellationRequested()
        let commandsBeforeTeardown = await newRunner.receivedCommands()
        XCTAssertEqual(commandsBeforeTeardown.count, 0)

        await oldRunner.finishCancellation()
        await initial.value
        await switched.value

        XCTAssertEqual(controller.rootURL, newRoot)
        XCTAssertEqual(controller.status?.branch, "main")
        let commandsAfterSwitch = await newRunner.receivedCommands()
        XCTAssertGreaterThan(commandsAfterSwitch.count, 0)
    }

    @MainActor
    func testShutdownDuringRootReclamationJoinsOldServiceAndNeverCreatesNewOne() async throws {
        let oldRoot = root
        let newRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-shutdown-race",
            isDirectory: true
        )
        let oldRunner = BlockingShutdownGitControllerRunner()
        let newRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = GitController(serviceFactory: { rootURL in
            if rootURL == oldRoot {
                return try GitService(rootURL: rootURL, runner: oldRunner)
            }
            return try GitService(rootURL: rootURL, runner: newRunner)
        })
        let initial = Task { @MainActor in
            await controller.updateContext(rootURL: oldRoot, selectedFileURL: nil)
        }
        await oldRunner.waitUntilCommandStarts()
        let switched = Task { @MainActor in
            await controller.updateContext(rootURL: newRoot, selectedFileURL: nil)
        }
        await oldRunner.waitUntilCancellationRequested()

        let completion = GitControllerCompletionRecorder()
        let shutdown = Task { @MainActor in
            await controller.shutdown()
            await completion.recordCompletion()
        }
        for _ in 0..<10 { await Task.yield() }
        let completedBeforeReclamation = await completion.isCompleted
        XCTAssertFalse(completedBeforeReclamation)
        let prematureNewCommands = await newRunner.receivedCommands()
        XCTAssertEqual(prematureNewCommands.count, 0)

        await oldRunner.finishCancellation()
        await initial.value
        await switched.value
        await shutdown.value

        let finalNewCommands = await newRunner.receivedCommands()
        XCTAssertEqual(finalNewCommands.count, 0)
        XCTAssertNil(controller.rootURL)
        XCTAssertNil(controller.status)
    }

    @MainActor
    func testConsecutiveRootSwitchesJoinEveryPriorReclamation() async throws {
        let firstRoot = root
        let secondRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-second",
            isDirectory: true
        )
        let thirdRoot = URL(
            fileURLWithPath: "/tmp/lumen-git-controller-third",
            isDirectory: true
        )
        let firstRunner = BlockingShutdownGitControllerRunner()
        let secondRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let thirdRunner = QueueGitControllerRunner(results: statusResults(entries: ""))
        let controller = GitController(serviceFactory: { rootURL in
            switch rootURL {
            case firstRoot:
                return try GitService(rootURL: rootURL, runner: firstRunner)
            case secondRoot:
                return try GitService(rootURL: rootURL, runner: secondRunner)
            default:
                return try GitService(rootURL: rootURL, runner: thirdRunner)
            }
        })
        let initial = Task { @MainActor in
            await controller.updateContext(rootURL: firstRoot, selectedFileURL: nil)
        }
        await firstRunner.waitUntilCommandStarts()
        let secondSwitch = Task { @MainActor in
            await controller.updateContext(rootURL: secondRoot, selectedFileURL: nil)
        }
        await firstRunner.waitUntilCancellationRequested()
        let thirdSwitch = Task { @MainActor in
            await controller.updateContext(rootURL: thirdRoot, selectedFileURL: nil)
        }
        for _ in 0..<100 where controller.rootURL != thirdRoot {
            await Task.yield()
        }
        XCTAssertEqual(controller.rootURL, thirdRoot)
        let prematureSecondCommands = await secondRunner.receivedCommands()
        let prematureThirdCommands = await thirdRunner.receivedCommands()
        XCTAssertEqual(prematureSecondCommands.count, 0)
        XCTAssertEqual(prematureThirdCommands.count, 0)

        await firstRunner.finishCancellation()
        await initial.value
        await secondSwitch.value
        await thirdSwitch.value

        let finalSecondCommands = await secondRunner.receivedCommands()
        let finalThirdCommands = await thirdRunner.receivedCommands()
        XCTAssertEqual(finalSecondCommands.count, 0)
        XCTAssertGreaterThan(finalThirdCommands.count, 0)
        XCTAssertEqual(controller.rootURL, thirdRoot)
        XCTAssertEqual(controller.status?.branch, "main")
    }

    @MainActor
    func testShutdownIsJoinableAndPreventsLaterGitWork() async throws {
        let runner = BlockingShutdownGitControllerRunner()
        let controller = GitController(serviceFactory: { rootURL in
            try GitService(rootURL: rootURL, runner: runner)
        })
        let initial = Task { @MainActor in
            await controller.updateContext(rootURL: root, selectedFileURL: nil)
        }
        await runner.waitUntilCommandStarts()

        let firstShutdown = Task { @MainActor in await controller.shutdown() }
        await runner.waitUntilCancellationRequested()
        let secondShutdown = Task { @MainActor in await controller.shutdown() }
        let returnedBeforeTeardown = await runner.hasReturnedFromCancelAll()
        XCTAssertFalse(returnedBeforeTeardown)
        await runner.finishCancellation()
        await firstShutdown.value
        await secondShutdown.value
        await initial.value

        let countAfterShutdown = await runner.commandCount()
        await controller.updateContext(rootURL: root, selectedFileURL: nil)
        let finalCommandCount = await runner.commandCount()
        XCTAssertEqual(finalCommandCount, countAfterShutdown)
        XCTAssertNil(controller.rootURL)
        XCTAssertNil(controller.status)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    private func makeController(
        runner: QueueGitControllerRunner,
        openWorktreeFile: @escaping GitController.OpenWorktreeFile = { _ in false },
        discardPreflight: @escaping GitController.DiscardPreflight = { _ in
            .success(.init(refreshTokens: []))
        },
        completeDiscardPreflight: @escaping GitController.CompleteDiscardPreflight = { _, _ in },
        branchPreflight: @escaping GitController.BranchPreflight = { _ in
            .success(.init(refreshTokens: []))
        },
        completeBranchPreflight: @escaping GitController.CompleteBranchPreflight = { _, _ in },
        presentConflict: @escaping GitController.PresentConflict = { _ in false }
    ) throws -> GitController {
        GitController(
            serviceFactory: { rootURL in
                try GitService(rootURL: rootURL, runner: runner)
            },
            openWorktreeFile: openWorktreeFile,
            discardPreflight: discardPreflight,
            completeDiscardPreflight: completeDiscardPreflight,
            branchPreflight: branchPreflight,
            completeBranchPreflight: completeBranchPreflight,
            presentConflict: presentConflict
        )
    }

    nonisolated private func statusResults(
        branch: String = "main",
        entries: String,
        includeConflicts: Bool = true
    ) -> [QueueGitControllerRunner.Stub] {
        var results: [QueueGitControllerRunner.Stub] = [
            .success("\(branch)\n"),
            .success(entries),
            .success(""),
            .success(""),
            .success(""),
            .success("")
        ]
        if includeConflicts { results.append(.success("")) }
        return results
    }
}

private actor RefreshRecorder {
    private(set) var tokens: [GitDiscardRefreshToken] = []

    func record(_ value: [GitDiscardRefreshToken]) {
        tokens = value
    }
}

private actor BranchCompletionRecorder {
    private(set) var tokens: [GitDiscardRefreshToken] = []
    private(set) var didChange = true

    func record(_ result: GitBranchPreflightResult, didChange: Bool) {
        tokens = result.refreshTokens
        self.didChange = didChange
    }
}

private actor DiscardCompletionRecorder {
    private(set) var tokens: [GitDiscardRefreshToken] = []
    private(set) var didDiscard = false

    func record(_ result: GitDiscardPreflightResult, didDiscard: Bool) {
        tokens = result.refreshTokens
        self.didDiscard = didDiscard
    }
}

private actor ControllableBranchCompletion {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var wasCalled = false

    func complete(_ result: GitBranchPreflightResult, didChange: Bool) async {
        wasCalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ControllableBranchPreflight {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var wasCalled = false

    func check(_ rootURL: URL) async -> Result<GitBranchPreflightResult, GitBranchPreflightError> {
        wasCalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        return .success(.init(refreshTokens: []))
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ControllableDiscardPreflight {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var wasCalled = false

    func check(_ urls: [URL]) async
        -> Result<GitDiscardPreflightResult, GitDiscardPreflightError> {
        wasCalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        return .success(.init(refreshTokens: []))
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GitControllerCompletionRecorder {
    private(set) var isCompleted = false

    func recordCompletion() { isCompleted = true }
}

private actor ConflictOpenRecorder {
    private(set) var lastRequest: GitConflictOpenRequest?

    func record(_ request: GitConflictOpenRequest) {
        lastRequest = request
    }
}

private actor OpenedConflictRecorder {
    private(set) var paths: [String] = []

    func record(_ request: GitConflictOpenRequest) {
        paths.append(request.path)
    }
}

private actor URLRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}

private actor QueueGitControllerRunner: GitCommandRunning {
    enum Stub: Sendable {
        case success(String)
        case failure(code: Int32, error: String)
        case thrown(GitServiceError)
    }

    private var stubs: [Stub]
    private var commands: [GitCommand] = []

    init(results: [Stub]) {
        stubs = results
    }

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        commands.append(command)
        guard !stubs.isEmpty else {
            throw GitServiceError.launchFailed("Unexpected Git command: \(command.arguments)")
        }
        switch stubs.removeFirst() {
        case let .success(output):
            return GitProcessResult(
                standardOutput: Data(output.utf8),
                standardError: Data(),
                exitCode: 0
            )
        case let .failure(code, error):
            return GitProcessResult(
                standardOutput: Data(),
                standardError: Data(error.utf8),
                exitCode: code
            )
        case let .thrown(error):
            throw error
        }
    }

    func receivedCommands() -> [GitCommand] { commands }
}

/// Simulates a destructive command that has started (and may already have
/// changed disk) when root teardown cancels it.
private actor DestructiveCancellationGitControllerRunner: GitCommandRunning {
    private var mutationContinuation: CheckedContinuation<GitProcessResult, Error>?
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRequested = false

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        if command.arguments.contains("switch") {
            let waiters = mutationWaiters
            mutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                mutationContinuation = continuation
            }
        }
        if command.arguments.contains("--show-current") {
            return result("main\n")
        }
        return result("")
    }

    func cancelAll() async {
        cancellationRequested = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilMutationStarted() async {
        guard mutationContinuation == nil else { return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    func waitUntilCancellationRequested() async {
        guard !cancellationRequested else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func finishCancellation() {
        mutationContinuation?.resume(throwing: GitServiceError.cancelled)
        mutationContinuation = nil
    }

    private func result(_ output: String) -> GitProcessResult {
        GitProcessResult(
            standardOutput: Data(output.utf8), standardError: Data(), exitCode: 0
        )
    }
}

private actor BlockingShutdownGitControllerRunner: GitCommandRunning {
    private var commandContinuation: CheckedContinuation<GitProcessResult, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelFinishContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var cancelAllReturned = false
    private var commands: [GitCommand] = []

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        commands.append(command)
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            commandContinuation = continuation
        }
    }

    func cancelAll() async {
        cancellationRequested = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            cancelFinishContinuation = continuation
        }
        commandContinuation?.resume(throwing: GitServiceError.cancelled)
        commandContinuation = nil
        cancelAllReturned = true
    }

    func waitUntilCommandStarts() async {
        guard commandContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationRequested() async {
        guard !cancellationRequested else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    func finishCancellation() {
        cancelFinishContinuation?.resume()
        cancelFinishContinuation = nil
    }

    func hasReturnedFromCancelAll() -> Bool { cancelAllReturned }
    func commandCount() -> Int { commands.count }
}

private actor ControllableGitControllerRunner: GitCommandRunning {
    private var diffContinuation: CheckedContinuation<GitProcessResult, Never>?
    private var diffWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        if command.arguments.contains("--show-current") {
            return result("main\n")
        }
        if command.arguments.contains("status") {
            return result(" M first.swift\0 M second.swift\0")
        }
        if command.arguments.contains("config")
            || command.arguments.contains("rev-parse")
            || command.arguments.contains("--diff-filter=U") {
            return result("")
        }
        if command.arguments.contains("diff") {
            let waiters = diffWaiters
            diffWaiters = []
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                diffContinuation = continuation
            }
        }
        return result("")
    }

    func waitForDiff() async {
        guard diffContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            diffWaiters.append(continuation)
        }
    }

    func releaseDiff(with output: String) {
        diffContinuation?.resume(returning: result(output))
        diffContinuation = nil
    }

    private func result(_ output: String) -> GitProcessResult {
        GitProcessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            exitCode: 0
        )
    }
}

private actor ControllableRefreshGitControllerRunner: GitCommandRunning {
    private var conflictContinuation: CheckedContinuation<GitProcessResult, Never>?
    private var conflictWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusCount = 0
    private var conflictCount = 0

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        if command.arguments.contains("--show-current") {
            return result("main\n")
        }
        if command.arguments.contains("status") {
            statusCount += 1
            return result(statusCount == 1 ? "UU blocked.swift\0" : "")
        }
        if command.arguments.contains("config")
            || command.arguments.contains("rev-parse") {
            return result("")
        }
        if command.arguments.contains("--diff-filter=U") {
            conflictCount += 1
            guard conflictCount == 2 else { return result("blocked.swift\0") }
            let waiters = conflictWaiters
            conflictWaiters = []
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                conflictContinuation = continuation
            }
        }
        if command.arguments.contains("show") {
            return result(command.arguments.last?.contains(":2:") == true ? "ours\n" : "theirs\n")
        }
        return result("")
    }

    func waitForConflictList() async {
        guard conflictContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            conflictWaiters.append(continuation)
        }
    }

    func releaseConflictList() {
        conflictContinuation?.resume(returning: result("blocked.swift\0"))
        conflictContinuation = nil
    }

    private func result(_ output: String) -> GitProcessResult {
        GitProcessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            exitCode: 0
        )
    }
}
