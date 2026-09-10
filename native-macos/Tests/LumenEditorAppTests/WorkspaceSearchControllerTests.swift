import Combine
import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class WorkspaceSearchControllerTests: XCTestCase {
    func testFindBuildsAllOptionsFromExplicitRootCapabilitiesAndPublishesResults() async throws {
        let firstRoot = WorkspaceRoot.ID()
        let secondRoot = WorkspaceRoot.ID()
        let match = sampleMatch(path: "/project/File.swift")
        var captured: WorkspaceSearchRequest?
        let controller = makeController(
            rootIDs: [firstRoot, secondRoot, firstRoot],
            search: { request in
                captured = request
                return WorkspaceSearchResult(matches: [match], isTruncated: true)
            }
        )
        controller.query = "Needle"
        controller.includePattern = "**/*.swift"
        controller.excludePattern = "**/Tests/**"
        controller.isCaseSensitive = true
        controller.isWholeWord = true
        controller.usesRegularExpression = true

        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(captured?.rootIDs, [firstRoot, secondRoot])
        XCTAssertEqual(captured?.query, "Needle")
        XCTAssertEqual(captured?.include, "**/*.swift")
        XCTAssertEqual(captured?.exclude, "**/Tests/**")
        XCTAssertEqual(captured?.caseSensitive, true)
        XCTAssertEqual(captured?.wholeWord, true)
        XCTAssertEqual(captured?.useRegex, true)
        XCTAssertEqual(controller.matches, [match])
        XCTAssertEqual(controller.selectedResultIndex, 0)
        XCTAssertEqual(controller.status, .matches(count: 1, truncated: true))
        XCTAssertFalse(controller.isBusy)
    }

    func testHistoryProvidersPopulatePanelAndSuccessfulSearchRecordsQuery() async {
        let root = WorkspaceRoot.ID()
        let controller = makeController(rootIDs: [root])
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

        controller.show(mode: .find)
        XCTAssertEqual(controller.searchHistory, ["recent", "older"])
        XCTAssertEqual(controller.replaceHistory, ["replacement", ""])
        controller.query = "needle"
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(recordedSearch, "needle")
        XCTAssertNil(recordedReplacement)
    }

    func testLiteralWholeWordResultsConfigureAndStartReferenceSearch() async {
        let root = WorkspaceRoot.ID()
        var captured: WorkspaceSearchRequest?
        let controller = makeController(rootIDs: [root], search: { request in
            captured = request
            return WorkspaceSearchResult(matches: [], isTruncated: false)
        })
        controller.mode = .replace
        controller.query = "stale"
        controller.replacement = "replacement"
        controller.includePattern = "**/*.swift"
        controller.excludePattern = "old"
        controller.isCaseSensitive = false
        controller.isWholeWord = false
        controller.usesRegularExpression = true

        XCTAssertTrue(controller.showLiteralWholeWordResults(
            for: "HTTPClient", caseSensitive: true,
            excludePattern: "**/Generated/**,**/Vendor/**"
        ))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .find)
        await controller.waitForCurrentOperation()

        XCTAssertEqual(captured, WorkspaceSearchRequest(
            rootIDs: [root], query: "HTTPClient",
            caseSensitive: true, wholeWord: true, useRegex: false,
            include: "", exclude: "**/Generated/**,**/Vendor/**"
        ))
        XCTAssertEqual(controller.replacement, "")
        XCTAssertEqual(controller.includePattern, "")
        XCTAssertEqual(controller.status, .matches(count: 0, truncated: false))
    }

    func testProductionWiringTracksWorkspaceControllerRootCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-search-ui-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("needle".utf8).write(to: directory.appendingPathComponent("file.txt"))
        let generated = directory.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("needle".utf8).write(to: generated.appendingPathComponent("hidden.txt"))
        let workspace = WorkspaceController(service: WorkspaceService(), openFile: { _ in })
        workspace.setProjectExclusions(["Generated/**"])
        let controller = WorkspaceSearchController(
            workspaceController: workspace,
            navigateToMatch: { _ in true }
        )
        controller.query = "needle"
        XCTAssertFalse(controller.canSearch)

        let added = await workspace.addRoot(directory)
        XCTAssertTrue(added)
        await Task.yield()

        XCTAssertEqual(controller.rootIDs, workspace.roots.map(\.id))
        XCTAssertTrue(controller.canSearch)
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(controller.matches.count, 1)
        XCTAssertEqual(controller.matches.first?.url.lastPathComponent, "file.txt")
    }

    func testEmptyRootsAndQueryReportAccessibleErrorsWithoutCallingCore() async {
        var calls = 0
        let controller = makeController(rootIDs: [], search: { _ in
            calls += 1
            return WorkspaceSearchResult(matches: [], isTruncated: false)
        })
        controller.query = "needle"

        XCTAssertFalse(controller.search())
        XCTAssertEqual(controller.issue?.titleContent, .search)
        XCTAssertEqual(controller.issue?.title, "Could Not Search Workspace")
        XCTAssertTrue(controller.issue?.message.contains("Open a workspace folder") == true)
        XCTAssertEqual(calls, 0)

        controller.dismissIssue()
        XCTAssertNil(controller.issue)

        let queryController = makeController(rootIDs: [WorkspaceRoot.ID()], search: { _ in
            calls += 1
            return WorkspaceSearchResult(matches: [], isTruncated: false)
        })
        XCTAssertFalse(queryController.search())
        XCTAssertTrue(queryController.issue?.message.contains("Enter a search term") == true)
        XCTAssertEqual(calls, 0)
    }

    func testWorkspaceSearchErrorsHaveTypedEnglishAndChineseMessages() {
        let file = URL(fileURLWithPath: "/private/secret/workspace/file.txt")
        let rollbackFile = URL(fileURLWithPath: "/private/secret/workspace/rollback.txt")
        let cases: [(WorkspaceSearchError, String, String)] = [
            (
                .emptyQuery,
                "Find in Files needs a search term.",
                "在文件中查找需要搜索词。"
            ),
            (
                .invalidRegularExpression,
                "The search expression is invalid.",
                "搜索表达式无效。"
            ),
            (
                .tooManyRoots(maximum: 12),
                "A workspace search supports at most 12 roots.",
                "工作区搜索最多支持 12 个根目录。"
            ),
            (
                .previewFromAnotherWorkspace,
                "This replacement preview belongs to another workspace search session.",
                "此替换预览属于另一个工作区搜索会话。"
            ),
            (
                .previewAlreadyApplied,
                "This replacement preview has already been applied.",
                "此替换预览已应用。"
            ),
            (
                .projectExclusionsChanged,
                "Project exclusions changed. Create a new replacement preview.",
                "项目排除设置已更改。请创建新的替换预览。"
            ),
            (
                .fileChanged(file),
                "A previewed file changed on disk. Create a new replacement preview.",
                "预览中的文件已在磁盘上发生变化。请创建新的替换预览。"
            ),
            (
                .fileBecameIneligible(file),
                "A previewed file is no longer safe for unattended replacement.",
                "预览中的文件已不再适合安全地自动替换。"
            ),
            (
                .couldNotRead(file),
                "A previewed file could not be read.",
                "无法读取预览中的文件。"
            ),
            (
                .couldNotWrite(file),
                "A workspace replacement could not be written.",
                "无法写入工作区替换。"
            ),
            (
                .rollbackFailed([rollbackFile]),
                "A workspace replacement failed and one or more completed files could not be rolled back.",
                "工作区替换失败，并且一个或多个已完成文件无法回滚。"
            ),
            (
                .receiptFromAnotherWorkspace,
                "This replacement receipt belongs to another workspace search session.",
                "此替换收据属于另一个工作区搜索会话。"
            ),
            (
                .receiptAlreadyUsed,
                "This workspace replacement receipt has already been used.",
                "此工作区替换收据已使用。"
            ),
        ]

        for (error, english, chinese) in cases {
            let content = WorkspaceSearchPresentationIssue.Message.searchError(error)
            XCTAssertEqual(EditorLocale.enUS.localizedWorkspaceSearchIssue(content), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedWorkspaceSearchIssue(content), chinese)
        }
    }

    func testWorkspaceSearchErrorMessagesDoNotExposePathsAndUnknownErrorsStayVerbatim() {
        let secretPath = "/private/secret/workspace/credentials.txt"
        let secretURL = URL(fileURLWithPath: secretPath)
        let pathErrors: [WorkspaceSearchError] = [
            .fileChanged(secretURL),
            .fileBecameIneligible(secretURL),
            .couldNotRead(secretURL),
            .couldNotWrite(secretURL),
            .rollbackFailed([secretURL]),
        ]

        for locale in [EditorLocale.enUS, .zhCN] {
            for error in pathErrors {
                let content = WorkspaceSearchPresentationIssue.Message.searchError(error)
                XCTAssertFalse(
                    locale.localizedWorkspaceSearchIssue(content).contains(secretPath),
                    "Typed workspace-search errors must not expose their associated path"
                )
            }

            let unknown = "Unrecognised failure at /private/keep-this-detail.txt"
            XCTAssertEqual(
                locale.localizedWorkspaceSearchIssue(.verbatim(unknown)),
                unknown
            )
        }
    }

    func testSearchFailurePreservesTypedWorkspaceSearchErrorContent() async {
        let root = WorkspaceRoot.ID()
        let expected = WorkspaceSearchError.invalidRegularExpression
        let controller = makeController(rootIDs: [root], search: { _ in throw expected })
        controller.query = "("

        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.issue?.content, .searchError(expected))
        XCTAssertEqual(controller.issue?.message, expected.localizedDescription)
    }

    func testPreviewRequiresExplicitConfirmationBeforeApplyAndPublishesReceipt() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = fixture.root.id
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [root], query: "old", replacement: "new"
        ))
        let coreResult = try await fixture.core.apply(preview)
        let receipt = try XCTUnwrap(coreResult.receipt)
        var applyCalls = 0
        var changes: [([URL], WorkspaceSearchFileChangeKind)] = []
        var recorded: [(String, String)] = []
        let controller = makeController(
            rootIDs: [root],
            mode: .replace,
            preview: { _ in preview },
            apply: { received in
                XCTAssertEqual(received.id, preview.id)
                applyCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 1, receipt: receipt)
            },
            filesChanged: { urls, kind in changes.append((urls, kind)) }
        )
        controller.query = "old"
        controller.replacement = "new"
        controller.setHistoryRecorder { search, replacement in
            recorded.append((search, replacement ?? "<nil>"))
        }

        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(controller.status, .previewReady(files: 1, replacements: 1, truncated: false))
        XCTAssertEqual(applyCalls, 0)
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.isApplyConfirmationPresented)
        controller.cancelApplyConfirmation()
        XCTAssertEqual(applyCalls, 0)

        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(applyCalls, 1)
        XCTAssertEqual(controller.status, .applied(files: 1, replacements: 1))
        XCTAssertTrue(controller.canUndo)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0, [fixture.file])
        XCTAssertEqual(changes[0].1, .replacement)
        XCTAssertEqual(recorded.map { $0.0 }, ["old"])
        XCTAssertEqual(recorded.map { $0.1 }, ["new"])
    }

    func testChangingAnySearchInputInvalidatesPreviewAndApplyConfirmation() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = fixture.root.id
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [root], query: "old", replacement: "new"
        ))
        var applyCalls = 0
        let controller = makeController(
            rootIDs: [root],
            mode: .replace,
            preview: { _ in preview },
            apply: { _ in
                applyCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 1)
            }
        )
        controller.query = "old"
        controller.replacement = "new"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())

        controller.excludePattern = "**/*.generated"

        XCTAssertFalse(controller.canApplyPreview)
        XCTAssertFalse(controller.isApplyConfirmationPresented)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertFalse(controller.confirmApplyPreview())
        XCTAssertEqual(applyCalls, 0)
    }

    func testCancellationStopsBusyStateAndLateCompletionCannotPublish() async {
        let root = WorkspaceRoot.ID()
        let gate = ContinuationGate<WorkspaceSearchResult>()
        let match = sampleMatch(path: "/project/late.txt")
        let controller = makeController(rootIDs: [root], search: { _ in
            try await gate.wait()
        })
        controller.query = "needle"

        XCTAssertTrue(controller.search())
        XCTAssertEqual(controller.status, .searching)
        XCTAssertTrue(controller.isCancelable)
        controller.cancel()
        XCTAssertEqual(controller.status, .cancelled)
        XCTAssertFalse(controller.isBusy)
        gate.resume(returning: WorkspaceSearchResult(matches: [match], isTruncated: false))
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertEqual(controller.status, .cancelled)
    }

    func testEditingWhileSearchRunsCancelsStaleGeneration() async {
        let root = WorkspaceRoot.ID()
        let gate = ContinuationGate<WorkspaceSearchResult>()
        let controller = makeController(rootIDs: [root], search: { _ in try await gate.wait() })
        controller.query = "first"
        XCTAssertTrue(controller.search())

        controller.query = "second"
        gate.resume(returning: WorkspaceSearchResult(
            matches: [sampleMatch(path: "/project/stale.txt")],
            isTruncated: false
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertEqual(controller.status, .idle)
    }

    func testProjectExclusionChangeCancelsSearchAndLateCompletionCannotPublish() async {
        let root = WorkspaceRoot.ID()
        let exclusions = ProjectExclusionSource()
        let gate = ContinuationGate<WorkspaceSearchResult>()
        let lateMatch = sampleMatch(path: "/project/Generated/late.txt")
        var capturedSnapshot: WorkspaceProjectExclusionSnapshot?
        let controller = makeController(
            rootIDs: [root],
            exclusions: exclusions,
            searchWithScope: { _, snapshot in
                capturedSnapshot = snapshot
                return try await gate.wait()
            }
        )
        controller.query = "needle"

        XCTAssertTrue(controller.search())
        await gate.waitUntilBlocked()
        exclusions.update(["Generated/**"])

        XCTAssertEqual(capturedSnapshot?.exclusions, [])
        XCTAssertEqual(capturedSnapshot?.generation, 0)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.matches.isEmpty)

        gate.resume(returning: WorkspaceSearchResult(
            matches: [lateMatch], isTruncated: false
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertNil(controller.selectedResultIndex)
        XCTAssertEqual(controller.status, .idle)
    }

    func testRootChangeDuringProviderCannotPublishStaleResults() async {
        let firstRoot = WorkspaceRoot.ID()
        let secondRoot = WorkspaceRoot.ID()
        let roots = WorkspaceSearchRootSource([firstRoot])
        let gate = ContinuationGate<WorkspaceSearchResult>()
        let controller = makeController(
            rootIDs: [firstRoot], roots: roots,
            search: { _ in try await gate.wait() }
        )
        controller.query = "needle"

        XCTAssertTrue(controller.search())
        await gate.waitUntilBlocked()
        roots.updateWithoutNotifying([secondRoot])
        gate.resume(returning: WorkspaceSearchResult(
            matches: [sampleMatch(path: "/old/stale.txt")],
            isTruncated: false
        ))
        await controller.waitForCurrentOperation()

        XCTAssertEqual(controller.rootIDs, [secondRoot])
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertEqual(controller.status, .idle)
    }

    func testProjectExclusionChangeCancelsPreviewAndLateCompletionCannotPublish() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [fixture.root.id], query: "old", replacement: "new"
        ))
        let exclusions = ProjectExclusionSource()
        let gate = ContinuationGate<WorkspaceReplacePreview>()
        var capturedSnapshot: WorkspaceProjectExclusionSnapshot?
        let controller = makeController(
            rootIDs: [fixture.root.id],
            mode: .replace,
            exclusions: exclusions,
            previewWithScope: { _, snapshot in
                capturedSnapshot = snapshot
                return try await gate.wait()
            }
        )
        controller.query = "old"
        controller.replacement = "new"

        XCTAssertTrue(controller.previewReplacement())
        await gate.waitUntilBlocked()
        exclusions.update(["Vendor/**"])

        XCTAssertEqual(capturedSnapshot?.generation, 0)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.currentPreview)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertNil(controller.selectedResultIndex)
        XCTAssertFalse(controller.isApplyConfirmationPresented)

        gate.resume(returning: preview)
        await Task.yield()
        await Task.yield()

        XCTAssertNil(controller.currentPreview)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertEqual(controller.status, .idle)
    }

    func testProjectExclusionChangeDismissesApplyConfirmationAndRejectsOldPreview() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [fixture.root.id], query: "old", replacement: "new"
        ))
        let exclusions = ProjectExclusionSource()
        var applyCalls = 0
        let controller = makeController(
            rootIDs: [fixture.root.id],
            mode: .replace,
            exclusions: exclusions,
            preview: { _ in preview },
            apply: { _ in
                applyCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 1)
            }
        )
        controller.query = "old"
        controller.replacement = "new"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())

        exclusions.update(["Generated/**"])

        XCTAssertFalse(controller.isApplyConfirmationPresented)
        XCTAssertNil(controller.currentPreview)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertFalse(controller.canApplyPreview)
        XCTAssertFalse(controller.confirmApplyPreview())
        XCTAssertEqual(applyCalls, 0)
    }

    func testApplyCannotBeCancelledAndFailureKeepsPreviewRetryable() async throws {
        struct ApplyFailure: Error, LocalizedError {
            var errorDescription: String? { "write failed" }
        }
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = fixture.root.id
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [root], query: "old", replacement: "new"
        ))
        let gate = ContinuationGate<WorkspaceReplaceResult>()
        let controller = makeController(
            rootIDs: [root],
            mode: .replace,
            preview: { _ in preview },
            apply: { _ in try await gate.wait() }
        )
        controller.query = "old"
        controller.show(mode: .replace)
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        XCTAssertEqual(controller.status, .applying)
        XCTAssertTrue(controller.isMutatingFiles)
        XCTAssertFalse(controller.isCancelable)

        controller.cancel()
        XCTAssertEqual(controller.status, .applying)
        controller.dismiss()
        XCTAssertTrue(controller.isPresented)
        gate.resume(throwing: ApplyFailure())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(controller.issue?.title, "Could Not Apply Workspace Replacement")
        XCTAssertEqual(controller.issue?.titleContent, .applyReplacement)
        XCTAssertEqual(controller.issue?.message, "write failed")
        XCTAssertTrue(controller.canApplyPreview)
    }

    func testUndoSuccessNotifiesShellAndConsumesReceipt() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = fixture.root.id
        let file = fixture.file
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [root], query: "old", replacement: "new"
        ))
        let coreResult = try await fixture.core.apply(preview)
        let receipt = try XCTUnwrap(coreResult.receipt)
        var undoCalls = 0
        var changes: [([URL], WorkspaceSearchFileChangeKind)] = []
        let controller = makeController(
            rootIDs: [root],
            mode: .replace,
            preview: { _ in preview },
            apply: { _ in WorkspaceReplaceResult(files: 1, replacements: 1, receipt: receipt) },
            undo: { received in
                XCTAssertEqual(received.id, receipt.id)
                undoCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 0)
            },
            filesChanged: { urls, kind in changes.append((urls, kind)) }
        )
        controller.query = "old"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        await controller.waitForCurrentOperation()

        XCTAssertTrue(controller.undoLastReplacement())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(undoCalls, 1)
        XCTAssertEqual(controller.status, .undone(files: 1))
        XCTAssertFalse(controller.canUndo)
        XCTAssertEqual(changes.map { $0.1 }, [.replacement, .undo])
        XCTAssertEqual(changes.last?.0, [file])
        XCTAssertFalse(controller.undoLastReplacement())
    }

    func testExclusionChangeDuringApplyInvalidatesPreviewButPreservesNewUndoReceipt() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [fixture.root.id], query: "old", replacement: "new"
        ))
        let coreResult = try await fixture.core.apply(preview)
        let receipt = try XCTUnwrap(coreResult.receipt)
        let exclusions = ProjectExclusionSource()
        let gate = ContinuationGate<WorkspaceReplaceResult>()
        var appliedSnapshot: WorkspaceProjectExclusionSnapshot?
        var undoCalls = 0
        let controller = makeController(
            rootIDs: [fixture.root.id],
            mode: .replace,
            exclusions: exclusions,
            preview: { _ in preview },
            applyWithScope: { received, snapshot in
                XCTAssertEqual(received.id, preview.id)
                appliedSnapshot = snapshot
                return try await gate.wait()
            },
            undo: { received in
                XCTAssertEqual(received.id, receipt.id)
                undoCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 0)
            }
        )
        controller.query = "old"
        controller.replacement = "new"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        await gate.waitUntilBlocked()

        exclusions.update(["Generated/**"])
        XCTAssertEqual(controller.status, .applying)
        XCTAssertFalse(controller.isCancelable)

        gate.resume(returning: WorkspaceReplaceResult(
            files: 1, replacements: 1, receipt: receipt
        ))
        await controller.waitForCurrentOperation()

        XCTAssertEqual(appliedSnapshot?.generation, 0)
        XCTAssertEqual(appliedSnapshot?.exclusions, [])
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.currentPreview)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertTrue(controller.canUndo)

        XCTAssertTrue(controller.undoLastReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(undoCalls, 1)
        XCTAssertFalse(controller.canUndo)
    }

    func testExclusionChangeDuringUndoDoesNotRestoreConsumedReceipt() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [fixture.root.id], query: "old", replacement: "new"
        ))
        let coreResult = try await fixture.core.apply(preview)
        let receipt = try XCTUnwrap(coreResult.receipt)
        let exclusions = ProjectExclusionSource()
        let undoGate = ContinuationGate<WorkspaceReplaceResult>()
        var undoCalls = 0
        let controller = makeController(
            rootIDs: [fixture.root.id],
            mode: .replace,
            exclusions: exclusions,
            preview: { _ in preview },
            apply: { _ in
                WorkspaceReplaceResult(files: 1, replacements: 1, receipt: receipt)
            },
            undo: { _ in
                undoCalls += 1
                return try await undoGate.wait()
            }
        )
        controller.query = "old"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.undoLastReplacement())
        await undoGate.waitUntilBlocked()

        exclusions.update(["Vendor/**"])
        XCTAssertEqual(controller.status, .undoing)
        undoGate.resume(returning: WorkspaceReplaceResult(files: 1, replacements: 0))
        await controller.waitForCurrentOperation()

        XCTAssertEqual(undoCalls, 1)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.undoLastReplacement())
    }

    func testExclusionChangeAfterCompletedApplyPreservesUndoReceipt() async throws {
        let fixture = try await makeCoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await fixture.core.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [fixture.root.id], query: "old", replacement: "new"
        ))
        let coreResult = try await fixture.core.apply(preview)
        let receipt = try XCTUnwrap(coreResult.receipt)
        let exclusions = ProjectExclusionSource()
        var undoCalls = 0
        let controller = makeController(
            rootIDs: [fixture.root.id],
            mode: .replace,
            exclusions: exclusions,
            preview: { _ in preview },
            apply: { _ in
                WorkspaceReplaceResult(files: 1, replacements: 1, receipt: receipt)
            },
            undo: { received in
                XCTAssertEqual(received.id, receipt.id)
                undoCalls += 1
                return WorkspaceReplaceResult(files: 1, replacements: 0)
            }
        )
        controller.query = "old"
        XCTAssertTrue(controller.previewReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.requestApplyPreview())
        XCTAssertTrue(controller.confirmApplyPreview())
        await controller.waitForCurrentOperation()
        XCTAssertTrue(controller.canUndo)

        exclusions.update(["Generated/**"])

        XCTAssertTrue(controller.canUndo)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertTrue(controller.undoLastReplacement())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(undoCalls, 1)
    }

    func testResultSelectionWrapsAndNavigationCallbackReceivesSelectedMatch() async {
        let root = WorkspaceRoot.ID()
        let first = sampleMatch(path: "/project/a.txt", line: 1)
        let second = sampleMatch(path: "/project/b.txt", line: 3)
        var navigated: [WorkspaceMatch] = []
        let controller = makeController(
            rootIDs: [root],
            search: { _ in WorkspaceSearchResult(matches: [first, second], isTruncated: false) },
            navigateToMatch: { navigated.append($0); return true }
        )
        controller.query = "needle"
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()

        XCTAssertEqual(controller.moveResult(by: -1), second)
        let selectedNavigation = await controller.navigateToSelectedResult()
        XCTAssertTrue(selectedNavigation)
        XCTAssertEqual(navigated, [second])
        let indexedNavigation = await controller.navigate(to: 0)
        XCTAssertTrue(indexedNavigation)
        XCTAssertEqual(navigated, [second, first])
    }

    func testResultNavigationReportsInvalidIndexAndCallbackFailure() async {
        let root = WorkspaceRoot.ID()
        let match = sampleMatch(path: "/project/a.txt")
        let controller = makeController(
            rootIDs: [root],
            search: { _ in WorkspaceSearchResult(matches: [match], isTruncated: false) },
            navigateToMatch: { _ in false }
        )
        controller.query = "needle"
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()

        let invalidNavigation = await controller.navigate(to: 99)
        XCTAssertFalse(invalidNavigation)
        let failedNavigation = await controller.navigateToSelectedResult()
        XCTAssertFalse(failedNavigation)
    }

    func testResultNavigationSynchronouslyRejectsNewerExclusionSnapshot() async {
        let root = WorkspaceRoot.ID()
        let exclusions = ProjectExclusionSource()
        let match = sampleMatch(path: "/project/Generated/old.txt")
        var navigated: [WorkspaceMatch] = []
        let controller = makeController(
            rootIDs: [root],
            exclusions: exclusions,
            search: { _ in
                WorkspaceSearchResult(matches: [match], isTruncated: false)
            },
            navigateToMatch: { navigated.append($0); return true }
        )
        controller.query = "needle"
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(controller.matches, [match])

        // Model the production turn where WorkspaceController has committed
        // the new snapshot but the queued Combine delivery has not run yet.
        exclusions.updateWithoutNotifying(["Generated/**"])

        let didNavigate = await controller.navigateToSelectedResult()
        XCTAssertFalse(didNavigate)
        XCTAssertTrue(navigated.isEmpty)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertNil(controller.selectedResultIndex)
    }

    func testResultNavigationSynchronouslyRejectsNewerRootSnapshot() async {
        let firstRoot = WorkspaceRoot.ID()
        let secondRoot = WorkspaceRoot.ID()
        let roots = WorkspaceSearchRootSource([firstRoot])
        let match = sampleMatch(path: "/old/result.txt")
        var navigated: [WorkspaceMatch] = []
        let controller = makeController(
            rootIDs: [firstRoot], roots: roots,
            search: { _ in
                WorkspaceSearchResult(matches: [match], isTruncated: false)
            },
            navigateToMatch: { navigated.append($0); return true }
        )
        controller.query = "needle"
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(controller.matches, [match])

        roots.updateWithoutNotifying([secondRoot])

        let didNavigate = await controller.navigateToSelectedResult()
        XCTAssertFalse(didNavigate)
        XCTAssertTrue(navigated.isEmpty)
        XCTAssertEqual(controller.rootIDs, [secondRoot])
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertNil(controller.selectedResultIndex)
    }

    func testCoreFailureIsSurfacedAndDismissIsBlockedDuringMutation() async throws {
        struct SearchFailure: Error, LocalizedError {
            var errorDescription: String? { "invalid expression" }
        }
        let root = WorkspaceRoot.ID()
        let controller = makeController(rootIDs: [root], search: { _ in throw SearchFailure() })
        controller.query = "["
        XCTAssertTrue(controller.search())
        await controller.waitForCurrentOperation()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.issue?.message, "invalid expression")

        controller.show(mode: .replace)
        XCTAssertTrue(controller.isPresented)
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
    }

    func testPanelPublishesStableAccessibilityLabels() {
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.panel, "Find and Replace in Files")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.query, "Search Query")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.replacement, "Replacement Text")
        XCTAssertEqual(
            WorkspaceSearchPanelView.Accessibility.searchHistory,
            "Recent Workspace Searches"
        )
        XCTAssertEqual(
            WorkspaceSearchPanelView.Accessibility.replaceHistory,
            "Recent Workspace Replacements"
        )
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.results, "Workspace Search Results")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.progress, "Workspace Search Busy")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.cancel, "Cancel Workspace Search")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.applyPreview, "Apply Replacement Preview")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.undo, "Undo Last Workspace Replacement")
        XCTAssertEqual(WorkspaceSearchPanelView.Accessibility.dismissError, "Dismiss Workspace Search Error")
    }

    // MARK: - Helpers

    private func makeController(
        rootIDs: [WorkspaceRoot.ID],
        mode: WorkspaceSearchMode = .find,
        roots: WorkspaceSearchRootSource? = nil,
        exclusions: ProjectExclusionSource? = nil,
        search: @escaping WorkspaceSearchController.SearchAction = { _ in
            WorkspaceSearchResult(matches: [], isTruncated: false)
        },
        preview: @escaping WorkspaceSearchController.PreviewAction = { request in
            try await WorkspaceSearchControllerTests.unexpectedPreview(for: request)
        },
        apply: @escaping WorkspaceSearchController.ApplyAction = { _ in
            XCTFail("Unexpected apply")
            return WorkspaceReplaceResult(files: 0, replacements: 0)
        },
        undo: @escaping WorkspaceSearchController.UndoAction = { _ in
            XCTFail("Unexpected undo")
            return WorkspaceReplaceResult(files: 0, replacements: 0)
        },
        searchWithScope: WorkspaceSearchController.ScopedSearchAction? = nil,
        previewWithScope: WorkspaceSearchController.ScopedPreviewAction? = nil,
        applyWithScope: WorkspaceSearchController.ScopedApplyAction? = nil,
        navigateToMatch: @escaping WorkspaceSearchController.NavigateToMatch = { _ in true },
        filesChanged: @escaping WorkspaceSearchController.FilesChanged = { _, _ in }
    ) -> WorkspaceSearchController {
        let exclusionProvider: WorkspaceSearchController.ProjectExclusionSnapshotProvider?
        let exclusionObserver: WorkspaceSearchController.ProjectExclusionObserver?
        let rootProvider: WorkspaceSearchController.RootSnapshotProvider?
        let rootObserver: WorkspaceSearchController.RootObserver?
        if let roots {
            rootProvider = { roots.rootIDs }
            rootObserver = { observer in roots.observe(observer) }
        } else {
            rootProvider = nil
            rootObserver = nil
        }
        if let exclusions {
            exclusionProvider = { exclusions.snapshot }
            exclusionObserver = { observer in exclusions.observe(observer) }
        } else {
            exclusionProvider = nil
            exclusionObserver = nil
        }
        return WorkspaceSearchController(
            rootIDs: rootIDs,
            mode: mode,
            search: search,
            preview: preview,
            apply: apply,
            undo: undo,
            navigateToMatch: navigateToMatch,
            filesChanged: filesChanged,
            projectExclusionSnapshot: exclusions?.snapshot ?? .init(
                exclusions: [], generation: 0
            ),
            rootSnapshotProvider: rootProvider,
            observeRoots: rootObserver,
            projectExclusionSnapshotProvider: exclusionProvider,
            observeProjectExclusions: exclusionObserver,
            searchWithScope: searchWithScope,
            previewWithScope: previewWithScope,
            applyWithScope: applyWithScope
        )
    }

    private func sampleMatch(
        path: String,
        line: Int = 1,
        column: Int = 1
    ) -> WorkspaceMatch {
        WorkspaceMatch(
            url: URL(fileURLWithPath: path),
            line: line,
            column: column,
            lineText: "needle",
            matchText: "needle",
            utf16Range: NSRange(location: 0, length: 6)
        )
    }

    private func makeCoreFixture() async throws -> (
        directory: URL,
        file: URL,
        root: WorkspaceRoot,
        core: WorkspaceSearch
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-search-ui-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: file)
        let workspace = WorkspaceService()
        let root = try await workspace.addRoot(directory)
        let core = WorkspaceSearch(workspace: workspace)
        return (directory, file, root, core)
    }

    private static func unexpectedPreview(
        for request: WorkspaceReplaceRequest
    ) async throws -> WorkspaceReplacePreview {
        throw TestConstructionError.unexpectedPreview
    }

    private enum TestConstructionError: Error {
        case unexpectedPreview
    }
}

@MainActor
private final class WorkspaceSearchRootSource {
    private var current: [WorkspaceRoot.ID]
    private var observers: [@MainActor ([WorkspaceRoot.ID]) -> Void] = []

    init(_ rootIDs: [WorkspaceRoot.ID]) { current = rootIDs }

    var rootIDs: [WorkspaceRoot.ID] { current }

    func updateWithoutNotifying(_ rootIDs: [WorkspaceRoot.ID]) {
        current = rootIDs
    }

    func observe(
        _ observer: @escaping @MainActor ([WorkspaceRoot.ID]) -> Void
    ) -> AnyCancellable {
        observers.append(observer)
        observer(current)
        return AnyCancellable {}
    }
}

@MainActor
private final class ProjectExclusionSource {
    private var current: WorkspaceProjectExclusionSnapshot
    private var observers: [
        @MainActor (WorkspaceProjectExclusionSnapshot) -> Void
    ] = []

    init(exclusions: [String] = [], generation: UInt64 = 0) {
        current = .init(
            exclusions: exclusions, generation: generation
        )
    }

    var snapshot: WorkspaceProjectExclusionSnapshot { current }

    func update(_ exclusions: [String]) {
        current = .init(
            exclusions: exclusions, generation: current.generation &+ 1
        )
        for observer in observers { observer(current) }
    }

    func updateWithoutNotifying(_ exclusions: [String]) {
        current = .init(
            exclusions: exclusions, generation: current.generation &+ 1
        )
    }

    func observe(
        _ observer: @escaping @MainActor (WorkspaceProjectExclusionSnapshot) -> Void
    ) -> AnyCancellable {
        observers.append(observer)
        observer(current)
        return AnyCancellable {}
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?
    private var didBeginWaiting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            didBeginWaiting = true
            if let pending {
                self.pending = nil
                let waiters = self.waiters
                self.waiters = []
                lock.unlock()
                continuation.resume(with: pending)
                for waiter in waiters { waiter.resume() }
            } else {
                self.continuation = continuation
                let waiters = self.waiters
                self.waiters = []
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didBeginWaiting {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    func resume(throwing error: any Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Value, any Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }
}
