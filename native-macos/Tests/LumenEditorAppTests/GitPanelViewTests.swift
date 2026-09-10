import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class GitPanelViewTests: XCTestCase {
    @MainActor
    func testGitInputIssuesAreLocalizedInEnglishAndChinese() {
        let cases: [(GitInputIssue, String, String)] = [
            (
                .currentHunkToStage,
                "Choose a current Git hunk to stage.",
                "请选择当前 Git 区块进行暂存。"
            ),
            (
                .changedFilesFromStatus,
                "Choose changed files from the current repository status.",
                "请从当前仓库状态中选择已更改文件。"
            ),
            (
                .changedFileToDiscard,
                "Select at least one changed file to discard.",
                "请至少选择一个要丢弃更改的文件。"
            ),
            (
                .validHunkToDiscard,
                "Choose a valid Git hunk to discard.",
                "请选择有效的 Git 区块以丢弃更改。"
            ),
            (
                .changedFileForAction,
                "Select at least one changed file for this Git action.",
                "请为此 Git 操作至少选择一个已更改文件。"
            ),
            (
                .commitMessageRequired,
                "Enter a commit message.",
                "请输入提交信息。"
            ),
            (
                .branchNameRequired,
                "Enter a branch name.",
                "请输入分支名称。"
            ),
            (
                .confirmationOutOfDate,
                "Git status changed before confirmation. Review the action and try again.",
                "确认前 Git 状态已发生变化。请检查此操作后重试。"
            )
        ]

        for (issue, english, chinese) in cases {
            XCTAssertEqual(
                EditorLocale.enUS.localizedGitIssue(.input(issue)),
                english
            )
            XCTAssertEqual(
                EditorLocale.zhCN.localizedGitIssue(.input(issue)),
                chinese
            )
        }
    }

    @MainActor
    func testMutationConfirmationPresentationLocalizesSnapshotDetails() {
        let cases: [(GitMutationConfirmation.Target, String, String)] = [
            (
                .stagePaths(["one.swift", "two.swift"]),
                "Stage 2 selected files?",
                "要对所选的 2 个文件执行“暂存”吗？"
            ),
            (
                .unstagePaths(["one.swift"]),
                "Unstage 1 selected file?",
                "要对所选的 1 个文件执行“取消暂存”吗？"
            ),
            (
                .stageHunk(GitHunk(
                    path: "Sources/File.swift", header: "@@ -1 +1 @@", patch: "patch"
                )),
                "Stage selected hunk in “Sources/File.swift”?",
                "要暂存“Sources/File.swift”中所选的更改区块吗？"
            ),
            (
                .commit(message: "Fix native Git"),
                "Create commit with message:\n\nFix native Git",
                "要使用以下信息创建提交吗：\n\nFix native Git"
            ),
            (
                .checkoutBranch(name: "feature/native"),
                "Switch to branch “feature/native”?",
                "要切换到分支“feature/native”吗？"
            ),
            (
                .createBranch(name: "feature/native"),
                "Create and switch to branch “feature/native”?",
                "要创建并切换到分支“feature/native”吗？"
            )
        ]

        for (target, english, chinese) in cases {
            XCTAssertEqual(
                GitMutationConfirmationPresentation(target: target, locale: .enUS).detail,
                english
            )
            XCTAssertEqual(
                GitMutationConfirmationPresentation(target: target, locale: .zhCN).detail,
                chinese
            )
        }
    }

    @MainActor
    func testBranchPreflightIssuesAreTypedAndLocalized() {
        let cases: [(GitBranchPreflightError, String, String)] = [
            (
                .savingDocument(name: "File.swift"),
                "Finish saving File.swift before changing branches.",
                "请等待 File.swift 保存完成，再更改分支。"
            ),
            (
                .dirtyDocument(name: "File.swift"),
                "Save or close the dirty tab File.swift before changing branches.",
                "请先保存或关闭有未保存更改的标签页 File.swift，再更改分支。"
            ),
            (
                .externalConflict(name: "File.swift"),
                "Resolve the external change conflict for File.swift before changing branches.",
                "请先解决 File.swift 的外部更改冲突，再更改分支。"
            ),
            (
                .workspaceBusy,
                "Finish the current document operation before changing branches.",
                "请等待当前文档操作完成，再更改分支。"
            )
        ]
        for (error, english, chinese) in cases {
            XCTAssertEqual(EditorLocale.enUS.localizedGitIssue(.branchPreflight(error)), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedGitIssue(.branchPreflight(error)), chinese)
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.branchChangeBlocked),
            "无法更改分支"
        )
    }

    @MainActor
    func testGitTitlesAndDiscardPreflightStayTypedAcrossRuntimeLocaleChanges() {
        let issue = GitPresentationIssue(
            title: .discardBlocked,
            content: .discardPreflight(.dirtyDocument(name: "File.swift"))
        )

        XCTAssertEqual(issue.title, "Discard Blocked")
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(issue.titleContent),
            "无法丢弃更改"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedGitIssue(issue.content),
            "Save or close the dirty tab File.swift before discarding its Git changes."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(issue.content),
            "请先保存或关闭有未保存更改的标签页 File.swift，再丢弃其 Git 更改。"
        )
    }

    @MainActor
    func testUnknownGitTextThatMatchesAppCopyRemainsVerbatim() {
        let collision = "Git status could not be refreshed."
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(.verbatim(collision)), collision
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(.app(.statusRefreshFailed)),
            "无法刷新 Git 状态。"
        )
    }

    @MainActor
    func testGitConfirmationAccessibilityIdentifiersAreStableAndLocaleIndependent() {
        XCTAssertEqual(
            AppAccessibility.id("git mutation confirmation"),
            "lumen.git.mutation.confirmation"
        )
        XCTAssertEqual(
            AppAccessibility.id("git confirmation cancel"),
            "lumen.git.confirmation.cancel"
        )
        XCTAssertEqual(
            AppAccessibility.id("git confirmation confirm"),
            "lumen.git.confirmation.confirm"
        )
        XCTAssertEqual(
            AppAccessibility.id("git discard confirmation cancel"),
            "lumen.git.discard.confirmation.cancel"
        )
        XCTAssertEqual(
            AppAccessibility.id("git discard confirmation confirm"),
            "lumen.git.discard.confirmation.confirm"
        )
    }

    @MainActor
    func testConflictedFileLocalizationPreservesPath() {
        let path = "Sources/冲突 file.swift"

        XCTAssertEqual(
            EditorLocale.enUS.localizedGitIssue(.conflictedFile(path: path)),
            "Could not open conflicted file Sources/冲突 file.swift."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(.conflictedFile(path: path)),
            "无法打开冲突文件 Sources/冲突 file.swift。"
        )
    }

    @MainActor
    func testGitOperationFailuresLocalizeWhilePreservingParameters() {
        let path = "Sources/Feature.swift"
        let operation = GitControllerOperation.loadingDiff(path)
        let generic = GitOperationFailure.generic(operation: operation)
        let processExited = GitOperationFailure.processExited(
            status: -37,
            operation: .loadingHistory(path)
        )

        XCTAssertEqual(
            EditorLocale.enUS.localizedGitIssue(.operationFailure(generic)),
            "Loading Git diff could not be completed."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(.operationFailure(generic)),
            "无法完成载入 Git 差异。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedGitIssue(.operationFailure(processExited)),
            "Git exited with status -37 while loading git history."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(.operationFailure(processExited)),
            "Git 在载入 Git 历史时退出，状态码为 -37。"
        )
    }

    @MainActor
    func testGitOperationDescriptionsAreLocalized() {
        let path = "Sources/Feature.swift"
        let cases: [(GitControllerOperation, String, String)] = [
            (.refreshing, "Refreshing Git status", "正在刷新 Git 状态"),
            (.loadingDiff(path), "Loading Git diff", "正在载入 Git 差异"),
            (.loadingHunks(path), "Loading Git hunks", "正在载入 Git 区块"),
            (.loadingHistory(path), "Loading Git history", "正在载入 Git 历史"),
            (.loadingBlame(path), "Loading Git blame", "正在载入 Git 追溯"),
            (.loadingConflicts, "Loading Git conflicts", "正在载入 Git 冲突"),
            (.action(.stage), "Staging files", "正在暂存文件"),
            (.action(.unstage), "Unstaging files", "正在取消暂存文件"),
            (.action(.discard), "Discarding file changes", "正在丢弃文件更改"),
            (.action(.stageHunk), "Staging hunk", "正在暂存区块"),
            (.action(.discardHunk), "Discarding hunk", "正在丢弃区块"),
            (.action(.commit), "Creating commit", "正在创建提交"),
            (.action(.checkoutBranch), "Switching branch", "正在切换分支"),
            (.action(.createBranch), "Creating branch", "正在创建分支")
        ]

        for (operation, english, chinese) in cases {
            XCTAssertEqual(operation.localizedDescription(locale: .enUS), english)
            XCTAssertEqual(operation.localizedDescription(locale: .zhCN), chinese)
        }
    }

    @MainActor
    func testConfirmationProgressDescriptionsAreLocalizedAndAccessible() {
        let cases: [(GitConfirmationProgress, String, String)] = [
            (
                .checkingBranchDocuments,
                "Checking open documents before switching branches",
                "正在切换分支前检查打开的文档"
            ),
            (
                .checkingDiscardDocuments,
                "Checking open documents before discarding changes",
                "正在丢弃更改前检查打开的文档"
            ),
            (
                .reconcilingBranchDocuments,
                "Reloading open documents after switching branches",
                "正在切换分支后重新载入打开的文档"
            ),
            (
                .reconcilingDiscardDocuments,
                "Reloading open documents after discarding changes",
                "正在丢弃更改后重新载入打开的文档"
            )
        ]
        for (progress, english, chinese) in cases {
            XCTAssertEqual(progress.localizedDescription(locale: .enUS), english)
            XCTAssertEqual(progress.localizedDescription(locale: .zhCN), chinese)
        }
        XCTAssertEqual(
            AppAccessibility.id("git confirmation progress"),
            "lumen.git.confirmation.progress"
        )
    }

    @MainActor
    func testSameFetchAndPushAddressUsesOneCompactRow() throws {
        let safeURL = "https://example.com/org/repo.git"
        let presentation = GitRemotePresentation(GitRemote(
            name: "origin",
            fetchUrl: safeURL,
            pushUrl: safeURL
        ))

        XCTAssertEqual(presentation.addresses.count, 1)
        let address = try XCTUnwrap(presentation.addresses.first)
        XCTAssertEqual(address.kind, .fetchAndPush)
        XCTAssertEqual(address.value, safeURL)
        XCTAssertEqual(address.kind.label(locale: .enUS), "Fetch / Push")
        XCTAssertEqual(address.kind.label(locale: .zhCN), "拉取/推送")
        XCTAssertEqual(
            presentation.accessibilityLabel(locale: .enUS),
            "Git remote origin, fetch and push URL https://example.com/org/repo.git"
        )
        XCTAssertEqual(
            presentation.accessibilityLabel(locale: .zhCN),
            "Git 远程仓库 origin，拉取和推送地址 https://example.com/org/repo.git"
        )
    }

    @MainActor
    func testDistinctAndMissingAddressesUseOnlyAvailableRows() {
        let distinct = GitRemotePresentation(GitRemote(
            name: "origin",
            fetchUrl: "https://example.com/read.git",
            pushUrl: "ssh://example.com/write.git"
        ))
        XCTAssertEqual(distinct.addresses.map(\.kind), [.fetch, .push])
        XCTAssertEqual(
            distinct.addresses.map(\.value),
            ["https://example.com/read.git", "ssh://example.com/write.git"]
        )
        XCTAssertEqual(
            distinct.accessibilityLabel(locale: .enUS),
            "Git remote origin, fetch URL https://example.com/read.git, "
                + "push URL ssh://example.com/write.git"
        )

        let fetchOnly = GitRemotePresentation(GitRemote(
            name: "upstream",
            fetchUrl: "https://example.com/upstream.git"
        ))
        XCTAssertEqual(fetchOnly.addresses.map(\.kind), [.fetch])
        XCTAssertEqual(fetchOnly.addresses.map(\.value), ["https://example.com/upstream.git"])

        let pushOnly = GitRemotePresentation(GitRemote(
            name: "mirror",
            pushUrl: "ssh://example.com/mirror.git"
        ))
        XCTAssertEqual(pushOnly.addresses.map(\.kind), [.push])
        XCTAssertEqual(pushOnly.addresses.map(\.value), ["ssh://example.com/mirror.git"])

        let nameOnly = GitRemotePresentation(GitRemote(name: "backup"))
        XCTAssertTrue(nameOnly.addresses.isEmpty)
        XCTAssertEqual(nameOnly.accessibilityLabel(locale: .zhCN), "Git 远程仓库 backup")
    }

    @MainActor
    func testPresentationNeverPublishesCredentialBearingContent() throws {
        let raw = "https://credential-user:secret-token@example.com/repo.git?token=secret-token"
        let presentation = GitRemotePresentation(GitRemote(
            name: "origin", fetchUrl: raw, pushUrl: raw
        ))
        let renderedContent = ([presentation.name] + presentation.addresses.map(\.value) + [
            presentation.accessibilityLabel(locale: .enUS),
            presentation.accessibilityLabel(locale: .zhCN)
        ]).joined(separator: " ")

        XCTAssertTrue(renderedContent.contains("https://example.com/repo.git"))
        XCTAssertFalse(renderedContent.contains("credential-user"))
        XCTAssertFalse(renderedContent.contains("secret-token"))
    }

    @MainActor
    func testPresentationBoundsUnexpectedDirectURLInput() throws {
        let oversized = "https://example.com/" + String(repeating: "a", count: 8_192)
        let presentation = GitRemotePresentation(GitRemote(
            name: "origin", fetchUrl: oversized
        ))
        let address = try XCTUnwrap(presentation.addresses.first)

        XCTAssertLessThanOrEqual(
            address.value.utf16.count,
            GitServiceLimits.default.maximumRemoteURLUTF16Units
        )
    }
}
