import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LumenEditorApp
@testable import LumenEditorCore

final class AppLocalizationTests: XCTestCase {
    func testOutlineFeedbackIsLocalized() {
        XCTAssertEqual(EditorLocale.zhCN.localizedPresentedTitle("Outline Unavailable"), "大纲不可用")
        XCTAssertEqual(EditorLocale.zhCN.localizedPresentedTitle("Nothing to Fold"), "没有可折叠内容")
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "No folded region contains the cursor."
            ),
            "光标所在位置没有已折叠区域。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedTitle("Markdown Preview Unavailable"),
            "Markdown 预览不可用"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "The document changed while it was being reopened. No edits were discarded."
            ),
            "重新打开期间文档已发生变化。未丢弃任何编辑。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Document\nLines: 2\nCharacters: 3\nCharacters (excluding whitespace): 2\nWords / tokens: 1"
            ),
            "文档\n行数：2\n字符数：3\n字符数（不含空白）：2\n单词 / 标记：1"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedTitle("Could Not Install Plugin"),
            "无法安装插件"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Save the file with a Markdown extension or select Markdown syntax first."
            ),
            "请先以 Markdown 扩展名保存文件，或选择 Markdown 语法。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "The local plugin could not be installed."
            ),
            "无法安装本地插件。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.operationFailed),
            "Git 操作失败"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "No merge conflicts were detected in the current repository."
            ),
            "当前仓库中未检测到合并冲突。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Could not open all conflicted files (opened 2)."
            ),
            "无法打开所有冲突文件（已打开 2 个）。"
        )
    }

    func testGitFallbackTitlesAndMessagesAreLocalized() {
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.unavailable),
            "Git 不可用"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.actionUnavailable),
            "Git 操作不可用"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.operationFailed),
            "Git 操作失败"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.openConflicts),
            "无法打开 Git 冲突"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(.discardBlocked),
            "无法丢弃更改"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Git status could not be refreshed."
            ),
            "无法刷新 Git 状态。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "No merge conflicts were detected in the current repository."
            ),
            "当前仓库中未检测到合并冲突。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Could not open all conflicted files (opened 17)."
            ),
            "无法打开所有冲突文件（已打开 17 个）。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "The primary workspace is not a Git repository."
            ),
            "主工作区不是 Git 仓库。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Open a workspace folder to use source control."
            ),
            "请打开工作区文件夹以使用源代码管理。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Select at least one changed file for this Git action."
            ),
            "请为此 Git 操作至少选择一个已更改文件。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Git could not be launched."
            ),
            "无法启动 Git。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "The Git operation was cancelled."
            ),
            "Git 操作已取消。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Finish saving Draft.swift before discarding its Git changes."
            ),
            "请等待 Draft.swift 保存完成，再丢弃其 Git 更改。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Save or close the dirty tab Draft.swift before discarding its Git changes."
            ),
            "请先保存或关闭有未保存更改的标签页 Draft.swift，再丢弃其 Git 更改。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentedMessage(
                "Git status could not be refreshed."
            ),
            "Git status could not be refreshed."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "Place the cursor on a symbol name."
            ),
            "请将光标置于符号名称上。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage("No definition found."),
            "未找到定义。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage("No references found."),
            "未找到引用。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "No indexed definition found for HTTPClient."
            ),
            "未找到 HTTPClient 的索引定义。"
        )
    }
    func testViewCopySwitchesAtRuntime() {
        XCTAssertEqual(EditorLocale.enUS.text("Settings", zh: "设置"), "Settings")
        XCTAssertEqual(EditorLocale.zhCN.text("Settings", zh: "设置"), "设置")
    }

    func testSharedCatalogUsesTheSameLocaleSource() {
        XCTAssertEqual(EditorLocale.enUS.localized(.findAll), "Find All")
        XCTAssertEqual(EditorLocale.zhCN.localized(.findAll), "查找全部")
        XCTAssertEqual(
            EditorLocale.enUS.localized(.encodingChanged, arguments: ["value": "UTF-8"]),
            "Save encoding as UTF-8"
        )
    }

    func testCommandLocaleTracksAppLocale() {
        XCTAssertEqual(EditorLocale.enUS.commandLocale, .english)
        XCTAssertEqual(EditorLocale.zhCN.commandLocale, .simplifiedChinese)
    }

    func testFoundationLocaleTracksStoredIdentifier() {
        XCTAssertEqual(EditorLocale.enUS.foundationLocale, Locale(identifier: "en-US"))
        XCTAssertEqual(EditorLocale.zhCN.foundationLocale, Locale(identifier: "zh-CN"))
    }

    func testRuntimeDialogCopyUsesTheSameLocaleSource() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.confirmExternalLanguageTool),
            "Confirm External Language Tool"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.confirmExternalLanguageTool),
            "确认外部语言工具"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.runLanguageServerPrompt),
            "Run Language Server?"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.runLanguageServerPrompt),
            "运行语言服务器？"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.approvalCurrentWindowExactConfiguration),
            "Approval lasts only for this exact configuration in the current window session."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.approvalCurrentWindowExactWorkerConfiguration),
            "此授权仅在当前窗口会话中对这一准确 Worker 和权限集有效。"
        )
    }

    func testStructuredAppOwnedCopyUsesRuntimeLocaleAndPreservesArguments() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.terminalExited(code: 0)),
            "Terminal exited."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.terminalExited(code: 0)),
            "终端已退出。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.terminalExited(code: 137)),
            "Terminal exited with code 137."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.terminalExited(code: 137)),
            "终端退出，代码为 137。"
        )

        let conflictPath = "Sources/冲突 file.swift"
        let conflict = GitPresentationIssue.Message.conflictedFile(path: conflictPath)
        XCTAssertEqual(
            EditorLocale.enUS.localizedGitIssue(conflict),
            "Could not open conflicted file Sources/冲突 file.swift."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(conflict),
            "无法打开冲突文件 Sources/冲突 file.swift。"
        )

        let external = "外部工具: Terminal exited with code 7. /tmp/原文"
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceSearchIssue(.verbatim(external)),
            external
        )
    }

    @MainActor
    func testStoredPanelIssuesRerenderAndExternalCollisionsStayVerbatim() {
        let terminal = TerminalPresentationIssue(
            title: .invalidInput, message: .inputByteLimit(maximum: 65_536)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedTerminalIssue(terminal.content),
            "Terminal input must be between 1 and 65536 UTF-8 bytes."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssue(terminal.content),
            "终端输入必须介于 1 和 65536 个 UTF-8 字节之间。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedTerminalIssueTitle(terminal.titleContent),
            "Invalid Terminal Input"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssueTitle(terminal.titleContent),
            "终端输入无效"
        )

        let macro = MacroSnippetController.presentationMessage(
            for: MacroSnippetControllerError.replayOperationLimit(maximum: 99)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedMacroSnippetIssue(macro),
            "Macro replay exceeded the 99-operation limit."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssue(macro),
            "宏重放超过 99 项操作的上限。"
        )

        let workspace = WorkspacePresentationIssue(
            title: .fileNotVisible,
            message: .app(
                english: "Draft.swift is missing or excluded from the file tree.",
                chinese: "Draft.swift 不存在或已从文件树中排除。"
            )
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssueTitle(workspace.titleContent),
            "File Is Not Visible in the Workspace"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssueTitle(workspace.titleContent),
            "文件在工作区中不可见"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssue(workspace.content),
            "Draft.swift is missing or excluded from the file tree."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(workspace.content),
            "Draft.swift 不存在或已从文件树中排除。"
        )

        let collision = "The terminal process ended unexpectedly."
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssue(.verbatim(collision)),
            collision
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssue(.verbatim(collision)),
            collision
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssue(.verbatim(collision)),
            collision
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssueTitle(.verbatim(
                "Invalid Terminal Input"
            )),
            "Invalid Terminal Input"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssueTitle(.verbatim(
                "Language Server Request Failed"
            )),
            "Language Server Request Failed"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssueTitle(.verbatim(
                "Could Not Open File"
            )),
            "Could Not Open File"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(.verbatim(collision)),
            collision
        )
    }

    func testPreviewAndBrowserPayloadsRerenderForRuntimeLocale() {
        let json = AppPresentationText.app(
            .jsonExpectedValue(line: 3, column: 7)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(json),
            "Expected a JSON value. Line 3, column 7."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(json),
            "此处应为 JSON 值。 第 3 行，第 7 列。"
        )

        let limit = AppPresentationText.app(
            .htmlPreviewTooLarge(actual: 12, maximum: 10)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(limit),
            "The HTML preview is 12 bytes; the limit is 10 bytes."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(limit),
            "HTML 预览为 12 字节；上限为 10 字节。"
        )
    }

    func testPresentationPayloadKeepsExternalErrorsVerbatimAcrossLocales() {
        let external = "外部浏览器 failure: /tmp/私密路径"
        let payload = AppPresentationText.verbatim(external)

        XCTAssertEqual(EditorLocale.enUS.localizedPresentation(payload), external)
        XCTAssertEqual(EditorLocale.zhCN.localizedPresentation(payload), external)
    }

    @MainActor
    func testFindInvalidQueryPayloadUsesOneRuntimeLocaleFormatter() {
        let regex = FindBarController.presentationText(
            for: FindCoreError.invalidRegularExpression("fixture [ at offset 7")
        )
        XCTAssertEqual(
            regex,
            .app(.findInvalidRegularExpression(diagnostic: "fixture [ at offset 7"))
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(regex),
            "Invalid regular expression: fixture [ at offset 7"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(regex),
            "正则表达式无效：fixture [ at offset 7"
        )

        let appOwned: [(AppLocalizedCopy, String, String)] = [
            (
                .findResultLimitMustBePositive,
                "The find result limit must be greater than zero.",
                "查找结果上限必须大于零。"
            ),
            (
                .findTooManyMatchesToReplaceSafely,
                "Too many matches to replace safely.",
                "匹配项过多，无法安全地全部替换。"
            ),
            (
                .findZeroWidthRegularExpressionCannotBeReplaced,
                "Zero-width regular expression matches cannot be replaced.",
                "无法替换零宽度正则表达式匹配项。"
            )
        ]
        for (copy, english, chinese) in appOwned {
            XCTAssertEqual(EditorLocale.enUS.localizedPresentation(.app(copy)), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedPresentation(.app(copy)), chinese)
        }

        struct ExternalFindFailure: LocalizedError {
            let errorDescription: String? = "外部 regex 诊断 /tmp/private"
        }
        let external = FindBarController.presentationText(for: ExternalFindFailure())
        XCTAssertEqual(external, .verbatim("外部 regex 诊断 /tmp/private"))
        XCTAssertEqual(EditorLocale.enUS.localizedPresentation(external), "外部 regex 诊断 /tmp/private")
        XCTAssertEqual(EditorLocale.zhCN.localizedPresentation(external), "外部 regex 诊断 /tmp/private")
    }

    func testWorkspaceLimitsUseTypedParameterizedRuntimeLocalization() {
        let cases: [(WorkspaceServiceError, String, String)] = [
            (
                .tooManyRoots(maximum: 7),
                "A workspace supports at most 7 roots.",
                "一个工作区最多支持 7 个根目录。"
            ),
            (
                .tooManyRetainedFiles(maximum: 11),
                "At most 11 open files may retain access when a root is removed.",
                "移除根目录时，最多可为 11 个打开的文件保留访问权限。"
            ),
            (
                .tooManyDirectFileAuthorizations(maximum: 13),
                "At most 13 files may have direct access.",
                "最多可为 13 个文件授予直接访问权限。"
            )
        ]

        for (error, english, chinese) in cases {
            let content = WorkspacePresentationIssue.Message.workspaceError(
                error, context: nil
            )
            XCTAssertEqual(EditorLocale.enUS.localizedWorkspaceIssue(content), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedWorkspaceIssue(content), chinese)
        }

        let contextual = WorkspacePresentationIssue.Message.workspaceError(
            .tooManyRoots(maximum: 2), context: "项目 A"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssue(contextual),
            "项目 A: A workspace supports at most 2 roots."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(contextual),
            "项目 A：一个工作区最多支持 2 个根目录。"
        )

        let external = WorkspacePresentationIssue.Message.verbatim(
            "system workspace failure: /tmp/private"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssue(external),
            "system workspace failure: /tmp/private"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(external),
            "system workspace failure: /tmp/private"
        )
    }

    func testPluginAndMarketplaceTitlesUseRuntimeLocale() {
        let cases: [(AppLocalizedCopy, String, String)] = [
            (.couldNotLoadPlugins, "Could Not Load Plugins", "无法载入插件"),
            (
                .couldNotSaveMarketplaceSettings,
                "Could Not Save Marketplace Settings",
                "无法保存插件市场设置"
            ),
            (
                .couldNotLoadMarketplaceSettings,
                "Could Not Load Marketplace Settings",
                "无法载入插件市场设置"
            ),
            (.noMarketplaceSources, "No Marketplace Sources", "没有插件市场来源"),
            (
                .couldNotLoadMarketplace,
                "Could Not Load Marketplace",
                "无法载入插件市场"
            ),
            (
                .couldNotInstallMarketplacePlugin,
                "Could Not Install Marketplace Plugin",
                "无法安装插件市场中的插件"
            ),
            (.noWorkspaceOpen, "No Workspace Open", "未打开工作区")
        ]

        for (copy, english, chinese) in cases {
            XCTAssertEqual(EditorLocale.enUS.localizedApp(copy), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedApp(copy), chinese)
        }
    }

    func testTypedPluginErrorsLocalizeGrammarAndPreserveParameters() {
        let marketplace = PluginPresentationIssue.Message.marketplaceClient(
            .manifestIdentityMismatch(expected: "catalog-id", actual: "下载-id")
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPluginIssue(marketplace),
            "The downloaded manifest ID ‘下载-id’ does not match catalog ID ‘catalog-id’."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginIssue(marketplace),
            "下载的清单 ID“下载-id”与插件市场目录 ID“catalog-id”不匹配。"
        )

        let store = PluginPresentationIssue.Message.pluginStore(
            .fileSystem(operation: "renameatx_np", path: "/tmp/插件", code: 13)
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginIssue(store),
            "插件文件操作“renameatx_np”在 /tmp/插件 失败（errno 13）。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPluginIssue(store),
            "Plugin file operation ‘renameatx_np’ failed for /tmp/插件 (errno 13)."
        )

        let manifest = PluginPresentationIssue.Message.manifestValidation(
            .unsuccessfulHTTPStatus(503)
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginIssue(manifest),
            "插件市场资源返回了 HTTP 状态 503。"
        )
    }

    func testPluginExternalFailuresRemainVerbatimAcrossRuntimeLocales() {
        let external = "stderr 原文\nunknown system failure: /tmp/private"
        let issue = PluginPresentationIssue.Message.verbatim(external)
        XCTAssertEqual(EditorLocale.enUS.localizedPluginIssue(issue), external)
        XCTAssertEqual(EditorLocale.zhCN.localizedPluginIssue(issue), external)

        let failures: [MarketplaceCatalogFailure.Reason] = [
            .marketplaceClient(.transport(.timedOut)),
            .verbatim(external)
        ]
        let english = EditorLocale.enUS.localizedPluginIssue(
            .marketplaceFailures(failures)
        )
        let chinese = EditorLocale.zhCN.localizedPluginIssue(
            .marketplaceFailures(failures)
        )
        XCTAssertEqual(
            english,
            "The marketplace request failed (URL error -1001).\n" + external
        )
        XCTAssertEqual(
            chinese,
            "插件市场请求失败（URL 错误 -1001）。\n" + external
        )
    }

    func testPluginWorkerRuntimeErrorsRerenderWithDynamicValues() {
        let titleCases: [(AppLocalizedCopy, String, String)] = [
            (.couldNotLoadPluginWorker, "Could Not Load Plugin Worker", "无法加载插件 Worker"),
            (.couldNotRunPluginCommand, "Could Not Run Plugin Command", "无法运行插件命令"),
            (.couldNotStartPluginWorker, "Could Not Start Plugin Worker", "无法启动插件 Worker"),
            (.couldNotRunPluginWorker, "Could Not Run Plugin Worker", "无法运行插件 Worker"),
            (.couldNotBuildPluginContext, "Could Not Build Plugin Context", "无法构建插件上下文"),
            (.pluginWorkerFailed, "Plugin Worker Failed", "插件 Worker 失败"),
            (.pluginWorkerExited, "Plugin Worker Exited", "插件 Worker 已退出")
        ]
        for (copy, english, chinese) in titleCases {
            XCTAssertEqual(EditorLocale.enUS.localizedApp(copy), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedApp(copy), chinese)
        }

        let cases: [(PluginWorkerRuntimeError, String, String)] = [
            (
                .hostUnavailable,
                "The isolated plugin worker host is unavailable.",
                "隔离的插件 Worker 主机不可用。"
            ),
            (
                .pluginUnavailable("plug-甲"),
                "Plugin worker ‘plug-甲’ is unavailable.",
                "插件 Worker“plug-甲”不可用。"
            ),
            (
                .commandUnavailable("plugin-worker:plug:run"),
                "Plugin command ‘plugin-worker:plug:run’ is unavailable.",
                "插件命令“plugin-worker:plug:run”不可用。"
            ),
            (
                .invalidHostMessage,
                "The plugin worker returned an invalid message.",
                "插件 Worker 返回了无效消息。"
            ),
            (
                .requestMismatch,
                "The active document changed before the plugin result arrived.",
                "插件结果返回前，活动文档已发生变化。"
            ),
            (
                .permissionDenied(.documentEdit),
                "The plugin was not granted ‘document-edit’ permission.",
                "插件未被授予“document-edit”权限。"
            )
        ]

        for (error, english, chinese) in cases {
            let content = PluginWorkerRuntimeIssue.Message.runtime(error)
            XCTAssertEqual(EditorLocale.enUS.localizedPluginWorkerIssue(content), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedPluginWorkerIssue(content), chinese)
        }
    }

    func testEveryPluginWorkerProtocolErrorUsesTypedRuntimeLocalization() {
        let cases: [(PluginWorkerProtocolError, String, String)] = [
            (.messageTooLarge(maximumBytes: 10), "Plugin IPC messages may use at most 10 bytes.", "插件 IPC 消息最多可使用 10 个字节。"),
            (.sourceTooLarge(maximumBytes: 11), "Plugin worker source may use at most 11 bytes.", "插件 Worker 源代码最多可使用 11 个字节。"),
            (.documentTooLarge(maximumBytes: 12), "Plugin document context may use at most 12 UTF-8 bytes.", "插件文档上下文最多可使用 12 个 UTF-8 字节。"),
            (.replacementTooLarge(maximumBytes: 13), "Plugin document replacements may use at most 13 UTF-8 bytes.", "插件文档替换内容最多可使用 13 个 UTF-8 字节。"),
            (.responseTooLarge(maximumBytes: 14), "A plugin request may return at most 14 encoded bytes.", "插件请求最多可返回 14 个编码后字节。"),
            (.invalidMessage, "The plugin worker sent an invalid JSON message.", "插件 Worker 发送了无效的 JSON 消息。"),
            (.unsupportedVersion(99), "Plugin worker protocol version 99 is unsupported.", "不支持插件 Worker 协议版本 99。"),
            (.invalidRequest, "The plugin worker request is incomplete or inconsistent.", "插件 Worker 请求不完整或不一致。"),
            (.tooManyMessages(maximum: 15), "A plugin request may emit at most 15 messages.", "插件请求最多可发送 15 条消息。")
        ]

        for (error, english, chinese) in cases {
            let content = PluginWorkerRuntimeIssue.Message.protocolError(error)
            XCTAssertEqual(EditorLocale.enUS.localizedPluginWorkerIssue(content), english)
            XCTAssertEqual(EditorLocale.zhCN.localizedPluginWorkerIssue(content), chinese)
        }
    }

    func testPluginWorkerExternalTextCollisionAndStderrRemainVerbatim() {
        let collision = "The isolated plugin worker host is unavailable."
        let workerFailure = PluginWorkerRuntimeIssue.Message.protocolError(
            .workerFailure(collision)
        )
        XCTAssertEqual(EditorLocale.enUS.localizedPluginWorkerIssue(workerFailure), collision)
        XCTAssertEqual(EditorLocale.zhCN.localizedPluginWorkerIssue(workerFailure), collision)

        let standardError = "Plugin command ‘fake’ is unavailable.: 中文\nstack:line:7\n"
        let exited = PluginWorkerRuntimeIssue.Message.runtime(
            .workerExited(64, standardError)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPluginWorkerIssue(exited),
            "The plugin worker exited with status 64: " + standardError
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginWorkerIssue(exited),
            "插件 Worker 已退出，状态为 64：" + standardError
        )
        XCTAssertTrue(EditorLocale.zhCN.localizedPluginWorkerIssue(exited).hasSuffix(standardError))

        let unknown = PluginWorkerRuntimeIssue.Message.verbatim(collision)
        XCTAssertEqual(EditorLocale.zhCN.localizedPluginWorkerIssue(unknown), collision)

        let launchDetail = "Plugin Worker Failed\n系统 launch detail"
        let launch = PluginWorkerRuntimeIssue.Message.toolProcess(
            .launchFailed(launchDetail)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPluginWorkerIssue(launch),
            "The tool process could not be launched: " + launchDetail
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginWorkerIssue(launch),
            "无法启动工具进程：" + launchDetail
        )
    }

    func testSearchStatusFormattersShareCorrectSingularAndPluralGrammar() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedFindStatus(
                .matches(current: nil, total: 1, truncated: false),
                queryIsEmpty: false,
                purpose: .visible
            ),
            "1 match"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedFindStatus(
                .replaced(1), queryIsEmpty: false, purpose: .announcement
            ),
            "Replaced 1 match."
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedFindStatus(
                .replaced(2), queryIsEmpty: false, purpose: .announcement
            ),
            "Replaced 2 matches."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedFindStatus(
                .replaced(1), queryIsEmpty: false, purpose: .announcement
            ),
            "已替换 1 个匹配项。"
        )

        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceSearchStatus(
                .previewReady(files: 1, replacements: 1, truncated: false),
                hasRoots: true,
                purpose: .announcement
            ),
            "Replacement preview contains 1 replacement in 1 file"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceSearchStatus(
                .applied(files: 2, replacements: 2),
                hasRoots: true,
                purpose: .announcement
            ),
            "Replaced 2 matches in 2 files"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceSearchStatus(
                .undone(files: 1), hasRoots: true, purpose: .announcement
            ),
            "Restored 1 file"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceSearchStatus(
                .previewReady(files: 1, replacements: 1, truncated: false),
                hasRoots: true,
                purpose: .announcement
            ),
            "替换预览包含 1 个文件中的 1 处更改"
        )
    }

    func testWorkspaceSearchIssueAnnouncementAndPrimaryActionUseCurrentModeAndLocale() {
        let issue = WorkspaceSearchPresentationIssue(
            title: .search,
            error: WorkspaceSearchError.invalidRegularExpression
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceSearchIssueAnnouncement(issue),
            "Could Not Search Workspace. The search expression is invalid."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceSearchIssueAnnouncement(issue),
            "无法搜索工作区。 搜索表达式无效。"
        )
        XCTAssertEqual(
            WorkspaceSearchPanelView.primaryActionAccessibilityLabel(
                mode: .find, locale: .enUS
            ),
            "Run Workspace Search"
        )
        XCTAssertEqual(
            WorkspaceSearchPanelView.primaryActionAccessibilityLabel(
                mode: .replace, locale: .enUS
            ),
            "Preview Workspace Replacement"
        )
        XCTAssertEqual(
            WorkspaceSearchPanelView.primaryActionAccessibilityLabel(
                mode: .replace, locale: .zhCN
            ),
            "预览工作区替换"
        )
    }

    @MainActor
    func testMenuAndKeyboardCommandFailuresKeepTypedRuntimePresentation() {
        let model = AppModel(createInitialDocument: false)
        let actions = EditorActionController(model: model)
        let content = WorkspacePresentationIssue.Message.workspaceError(
            .tooManyRoots(maximum: 2), context: "second-root"
        )

        actions.handleCommandExecutionResult(.failed(
            commandID: "open-folder",
            error: CommandHandlerSignal.failed(.workspace(content))
        ))

        guard let issue = actions.presentedIssue,
              case let .command(presentation) = issue.content else {
            return XCTFail("Expected a structured command presentation")
        }
        XCTAssertEqual(
            EditorLocale.enUS.localizedCommandPresentation(presentation),
            "second-root: A workspace supports at most 2 roots."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedCommandPresentation(presentation),
            "second-root：一个工作区最多支持 2 个根目录。"
        )

        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "Too many matches to replace safely."
        }
        actions.handleCommandExecutionResult(.failed(
            commandID: "save", error: ExternalFailure()
        ))
        guard let externalIssue = actions.presentedIssue,
              case let .command(externalPresentation) = externalIssue.content else {
            return XCTFail("Expected an explicit verbatim command presentation")
        }
        XCTAssertEqual(
            EditorLocale.enUS.localizedCommandPresentation(externalPresentation),
            "Too many matches to replace safely."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedCommandPresentation(externalPresentation),
            "Too many matches to replace safely."
        )
    }

    @MainActor
    func testGitCommandFailureKeepsTypedTitleAndMessage() {
        let model = AppModel(createInitialDocument: false)
        let actions = EditorActionController(model: model)
        let gitIssue = GitPresentationIssue(
            title: .discardBlocked,
            content: .discardPreflight(.dirtyDocument(name: "File.swift"))
        )

        actions.handleCommandExecutionResult(.failed(
            commandID: "refresh-git",
            error: CommandHandlerSignal.failed(.git(gitIssue))
        ))

        guard let issue = actions.presentedIssue,
              case let .git(title) = issue.titleContent,
              case let .command(.git(content)) = issue.content else {
            return XCTFail("Expected typed Git title and command payload")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssueTitle(title), "无法丢弃更改"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedGitIssue(content.content),
            "请先保存或关闭有未保存更改的标签页 File.swift，再丢弃其 Git 更改。"
        )
    }

    @MainActor
    func testAppModelCommandFailureKeepsTypedTitleAndMessage() {
        let model = AppModel(createInitialDocument: false)
        let actions = EditorActionController(model: model)
        let appModelIssue = AppModelIssue(
            title: .saveFile, error: FileWriteFailure.invalidExpectedRevision,
            context: "main.swift"
        )

        actions.handleCommandExecutionResult(.failed(
            commandID: "save",
            error: CommandHandlerSignal.failed(.appModel(appModelIssue))
        ))

        guard let issue = actions.presentedIssue,
              case let .appModel(title) = issue.titleContent,
              case let .command(.appModel(content)) = issue.content else {
            return XCTFail("Expected typed AppModel command feedback")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedAppModelIssueTitle(title), "无法保存文件"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedAppModelIssue(content.content),
            "main.swift：预期的文件修订版本无效。"
        )
    }

    @MainActor
    func testLanguageToolCommandFailureKeepsTypedTitleAndMessage() {
        let model = AppModel(createInitialDocument: false)
        let actions = EditorActionController(model: model)
        let languageToolIssue = LanguageToolPresentationIssue(
            title: .languageServerFormattingFailed,
            error: LanguageServerClientError.notRunning
        )

        actions.handleCommandExecutionResult(.failed(
            commandID: "format-document",
            error: CommandHandlerSignal.failed(.languageTool(languageToolIssue))
        ))

        guard let issue = actions.presentedIssue,
              case let .languageTool(title) = issue.titleContent,
              case let .command(.languageTool(content)) = issue.content else {
            return XCTFail("Expected typed language-tool command feedback")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageToolIssueTitle(title),
            "语言服务器格式化失败"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageToolIssue(content.content),
            "语言服务器未运行。"
        )
    }

    @MainActor
    func testNavigationLanguageServerAndSecurityFailuresStayTyped() {
        let model = AppModel(createInitialDocument: false)
        let actions = EditorActionController(model: model)
        let navigationIssue = NavigationPresentationIssue(
            title: .couldNotLoadProjectSymbols,
            content: .workspace(.tooManyRoots(maximum: 4))
        )
        actions.handleCommandExecutionResult(.failed(
            commandID: "goto-definition",
            error: CommandHandlerSignal.failed(.navigation(navigationIssue))
        ))
        guard let navigationActionIssue = actions.presentedIssue,
              case let .navigation(title) = navigationActionIssue.titleContent,
              case let .command(.navigation(content)) = navigationActionIssue.content else {
            return XCTFail("Expected typed navigation command feedback")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedNavigationIssueTitle(title),
            "无法加载项目符号"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedNavigationIssue(content.content),
            "一个工作区最多支持 4 个根目录。"
        )

        let languageServerIssue = LanguageServerPresentationIssue(
            title: .requestFailed,
            message: .app(english: "Language server is not running.",
                          chinese: "语言服务器未运行。")
        )
        actions.presentIssue(languageServerIssue)
        guard let languageServerActionIssue = actions.presentedIssue,
              case let .languageServer(serverTitle) =
                languageServerActionIssue.titleContent,
              case let .command(.languageServer(serverContent)) =
                languageServerActionIssue.content else {
            return XCTFail("Expected typed language-server feedback")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssueTitle(serverTitle),
            "语言服务器请求失败"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssue(serverContent.content),
            "语言服务器未运行。"
        )

        let security = CommandPresentation.securityScope(
            .accessDenied("/tmp/example.swift"), context: "example.swift"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedCommandPresentation(security),
            "example.swift：macOS 未授予对 /tmp/example.swift 的安全作用域访问权限。"
        )
    }

    func testRuntimeDialogCopyFormatsDynamicPrefixesPerLocale() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(
                .requestedLanguageServerLocationCouldNotOpen(path: "/tmp/demo.swift")
            ),
            "/tmp/demo.swift: The requested location could not be opened."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(
                .requestedLanguageServerLocationCouldNotOpen(path: "/tmp/demo.swift")
            ),
            "/tmp/demo.swift：无法打开请求的位置。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(
                .applyRenameEditCount(editCount: 3, fileCount: 2)
            ),
            "Apply 3 edits across 2 files? All files are revision-checked and completed writes are rolled back if a later write fails."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(
                .applyRenameEditCount(editCount: 3, fileCount: 2)
            ),
            "要在 2 个文件中应用 3 处编辑吗？所有文件都会进行修订校验；如果稍后写入失败，已经完成的写入会回滚。"
        )
    }

    func testNativePanelCopySwitchesAtRuntime() {
        struct Case {
            let copy: AppLocalizedCopy
            let english: String
            let chinese: String
        }
        let cases: [Case] = [
            .init(copy: .openFiles, english: "Open", chinese: "打开"),
            .init(
                copy: .openUsingEncoding(name: "UTF-8"),
                english: "Open Using UTF-8", chinese: "使用 UTF-8 打开"
            ),
            .init(
                copy: .chooseTextFilesToOpen,
                english: "Choose one or more text files to open.",
                chinese: "选择一个或多个要打开的文本文件。"
            ),
            .init(
                copy: .saveDocument(name: "Draft.txt"),
                english: "Save Draft.txt", chinese: "保存 Draft.txt"
            ),
            .init(
                copy: .chooseWhereToSaveDocument,
                english: "Choose where to save this document.",
                chinese: "选择保存此文档的位置。"
            ),
            .init(copy: .save, english: "Save", chinese: "保存"),
            .init(
                copy: .chooseSublimeSource(fileExtension: "sublime-project"),
                english: "Choose a .sublime-project file to preview. Nothing is imported until you confirm.",
                chinese: "选择一个 .sublime-project 文件进行预览。确认前不会导入任何内容。"
            ),
            .init(
                copy: .authorizeSublimeProjectFolder,
                english: "Authorize Sublime Project Folder",
                chinese: "授权 Sublime 项目文件夹"
            ),
            .init(
                copy: .confirmSublimeProjectFolder(path: "/tmp/Demo"),
                english: "Confirm access to the folder declared by the project: /tmp/Demo",
                chinese: "确认访问项目声明的文件夹：/tmp/Demo"
            ),
            .init(copy: .authorize, english: "Authorize", chinese: "授权"),
            .init(
                copy: .documentMinimap,
                english: "Document minimap", chinese: "文档缩略图"
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                EditorLocale.enUS.localizedApp(testCase.copy),
                testCase.english
            )
            XCTAssertEqual(
                EditorLocale.zhCN.localizedApp(testCase.copy),
                testCase.chinese
            )
        }
    }

    func testSettingsPersistenceIssueUsesCentralLocalization() {
        let unsupported = SettingsPersistenceIssue.Message.sessionOnly(
            cause: .store(.unsupportedFormatVersion(99)),
            destinationPath: "/tmp/settings.json"
        )
        let oversized = SettingsPersistenceIssue.Message.sessionOnly(
            cause: .store(.snapshotTooLarge),
            destinationPath: "/tmp/settings.json"
        )

        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedTitle("Could Not Save Settings"),
            "无法保存设置"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedSettingsPersistenceIssue(unsupported),
            "Settings format version 99 is not supported. Your changes remain active for this session but were not written to /tmp/settings.json."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSettingsPersistenceIssue(unsupported),
            "不支持设置格式版本 99。你的更改在当前会话中仍然生效，但未写入 /tmp/settings.json。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSettingsPersistenceIssue(oversized),
            "设置文件超出支持的大小限制。你的更改在当前会话中仍然生效，但未写入 /tmp/settings.json。"
        )
        let collision = "Settings format version 99 is not supported."
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSettingsPersistenceIssue(
                .saveFailed(.verbatim(collision))
            ),
            collision
        )
    }

    func testEditorFilePanelCopyLocalizesEveryField() {
        let cases: [(EditorLocale, TextEncoding?, EditorFilePanelCopy)] = [
            (
                .enUS, nil,
                .init(
                    title: "Open",
                    message: "Choose one or more text files to open.",
                    prompt: "Open"
                )
            ),
            (
                .zhCN, .utf8,
                .init(
                    title: "使用 UTF-8 打开",
                    message: "选择一个或多个要打开的文本文件。",
                    prompt: "打开"
                )
            )
        ]

        for (locale, encoding, expected) in cases {
            XCTAssertEqual(
                EditorFilePanelCopy.open(
                    locale: locale, forcedEncoding: encoding
                ),
                expected
            )
        }

        XCTAssertEqual(
            EditorFilePanelCopy.save(
                locale: .zhCN, documentName: "Draft.txt"
            ),
            .init(
                title: "保存 Draft.txt",
                message: "选择保存此文档的位置。",
                prompt: "保存"
            )
        )
    }

    func testDocumentOpenPanelAlwaysAllowsMultipleFiles() {
        XCTAssertEqual(
            EditorOpenPanelConfiguration.documentOpen,
            EditorOpenPanelConfiguration(
                canChooseFiles: true,
                canChooseDirectories: false,
                allowsMultipleSelection: true,
                resolvesAliases: true
            )
        )
    }

    func testWorkspaceFolderPanelCopyLocalizesEveryField() {
        XCTAssertEqual(
            WorkspaceFolderPanelCopy.open(locale: .zhCN),
            .init(
                title: "打开文件夹",
                message: "选择一个文件夹作为工作区。",
                prompt: "打开"
            )
        )
        XCTAssertEqual(
            WorkspaceFolderPanelCopy.add(locale: .enUS),
            .init(
                title: "Add Folder to Workspace",
                message: "Choose another folder to add to this workspace.",
                prompt: "Add"
            )
        )
        XCTAssertEqual(
            WorkspaceFolderPanelCopy.move(itemName: "Draft.txt", locale: .zhCN),
            .init(
                title: "移动 Draft.txt",
                message: "选择目标文件夹。现有项目不会被覆盖。",
                prompt: "移动"
            )
        )
    }

    func testWorkspaceIssueCopyLocalizesWatcherAndMutationFailures() {
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssueTitle(
                .couldNotMonitorFolder
            ),
            "无法监控文件夹"
        )
        let mutation = WorkspacePresentationIssue.Message.app(
            english: "Save or close affected documents before changing this item.",
            chinese: "请先保存或关闭受影响的文档，再更改此项目。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(mutation),
            "请先保存或关闭受影响的文档，再更改此项目。"
        )
        let watcher = WorkspacePresentationIssue.Message.app(
            english: "/tmp/Demo: The recursive workspace event stream could not be started.",
            chinese: "/tmp/Demo：无法启动递归工作区事件流。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(watcher),
            "/tmp/Demo：无法启动递归工作区事件流。"
        )
    }

    @MainActor
    func testAutomaticReopenEncodingNameUsesRuntimeLocale() {
        let request = ReopenEncodingRequest(
            document: EditorDocument(untitledName: "draft.txt"), encoding: nil
        )
        XCTAssertEqual(request.encodingName(locale: .enUS), "Auto Detect")
        XCTAssertEqual(request.encodingName(locale: .zhCN), "自动检测")
    }

    @MainActor
    func testEditorActionControllerAcceptsEnglishBeforeFirstPanel() {
        let actions = EditorActionController(
            model: AppModel(), locale: .enUS
        )
        XCTAssertEqual(actions.locale, .enUS)

        actions.updateLocale(.zhCN)
        XCTAssertEqual(actions.locale, .zhCN)
    }

    func testSystemMenuAndAlertCopySwitchesWithRuntimeLocale() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.aboutApp(appName: "Lumen Editor Native")),
            "About Lumen Editor Native"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.aboutApp(appName: "文本编辑器(徐洁阳) Native")),
            "关于文本编辑器(徐洁阳) Native"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.quitApp(appName: "Lumen Editor Native")),
            "Quit Lumen Editor Native"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.quitApp(appName: "文本编辑器(徐洁阳) Native")),
            "退出文本编辑器(徐洁阳) Native"
        )
        XCTAssertEqual(EditorLocale.zhCN.localizedApp(.windowMenu), "窗口")
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.toggleFullScreen),
            "Toggle Full Screen"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.toggleFullScreen),
            "切换全屏"
        )
        XCTAssertEqual(EditorLocale.enUS.localizedApp(.services), "Services")
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.saveChangesToDocument(name: "README.md")),
            "要保存对 README.md 的更改吗？"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApp(.reloadDiskVersionPrompt),
            "Reload the Disk Version?"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedApp(.discardLocalDraftForDiskVersion),
            "这会丢弃本地草稿，并用当前磁盘上的版本替换它。"
        )
    }

    @MainActor
    func testSystemMenuLocalizationSwitchesWithoutReplacingMenuItems() {
        let fixture = makeSystemMenuFixture()
        let originalActions = fixture.localizedItems.map {
            $0.action.map { NSStringFromSelector($0) }
        }
        let originalIdentifiers = fixture.localizedItems.map(\.identifier)
        let originalKeyEquivalents = fixture.actionItems.map(\.keyEquivalent)
        let originalModifierMasks = fixture.actionItems.map(\.keyEquivalentModifierMask)

        EditorLocale.zhCN.localizeMainMenu(
            fixture.mainMenu,
            servicesMenu: fixture.servicesMenu,
            windowsMenu: fixture.windowsMenu
        )
        XCTAssertEqual(fixture.about.title, "关于文本编辑器(徐洁阳) Native")
        XCTAssertEqual(fixture.services.title, "服务")
        XCTAssertEqual(fixture.hide.title, "隐藏文本编辑器(徐洁阳) Native")
        XCTAssertEqual(fixture.hideOthers.title, "隐藏其他")
        XCTAssertEqual(fixture.showAll.title, "全部显示")
        XCTAssertEqual(fixture.quit.title, "退出文本编辑器(徐洁阳) Native")
        XCTAssertEqual(fixture.windowRoot.title, "窗口")
        XCTAssertEqual(fixture.minimize.title, "最小化")
        XCTAssertEqual(fixture.zoom.title, "缩放")
        XCTAssertEqual(fixture.toggleFullScreen.title, "切换全屏")
        XCTAssertEqual(fixture.bringAllToFront.title, "前置全部窗口")

        EditorLocale.enUS.localizeMainMenu(
            fixture.mainMenu,
            servicesMenu: fixture.servicesMenu,
            windowsMenu: fixture.windowsMenu
        )
        XCTAssertEqual(fixture.about.title, "About Lumen Editor Native")
        XCTAssertEqual(fixture.services.title, "Services")
        XCTAssertEqual(fixture.hide.title, "Hide Lumen Editor Native")
        XCTAssertEqual(fixture.hideOthers.title, "Hide Others")
        XCTAssertEqual(fixture.showAll.title, "Show All")
        XCTAssertEqual(fixture.quit.title, "Quit Lumen Editor Native")
        XCTAssertEqual(fixture.windowRoot.title, "Window")
        XCTAssertEqual(fixture.minimize.title, "Minimize")
        XCTAssertEqual(fixture.zoom.title, "Zoom")
        XCTAssertEqual(fixture.toggleFullScreen.title, "Toggle Full Screen")
        XCTAssertEqual(fixture.bringAllToFront.title, "Bring All to Front")

        XCTAssertEqual(
            fixture.localizedItems.map {
                $0.action.map { NSStringFromSelector($0) }
            },
            originalActions
        )
        for (index, item) in fixture.actionItems.enumerated() {
            XCTAssertTrue(item.target === fixture.target)
            XCTAssertEqual(item.keyEquivalent, originalKeyEquivalents[index])
            XCTAssertEqual(
                item.keyEquivalentModifierMask, originalModifierMasks[index]
            )
        }
        XCTAssertEqual(fixture.localizedItems.map(\.identifier), originalIdentifiers)
    }

    @MainActor
    func testApplicationDelegateLocalizesAtLaunchAndWithOnlySettingsAlive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppLocalizationTests-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSystemMenuFixture()
        let delegate = LumenApplicationDelegate(
            mainMenuProvider: { fixture.mainMenu },
            servicesMenuProvider: { fixture.servicesMenu },
            windowsMenuProvider: { fixture.windowsMenu }
        )
        let settings = SettingsController(
            store: SettingsStore(
                settingsURL: directory.appendingPathComponent("settings.json")
            ),
            saveDebounceNanoseconds: 0
        )
        delegate.bindMenuLocalization(to: settings)

        // Simulate SwiftUI replacing a system-owned title while constructing
        // the final command menu. The launch callback must repair it before
        // the first visible frame.
        fixture.about.title = "About"
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(fixture.about.title, "关于文本编辑器(徐洁阳) Native")

        // No editor window is connected. The application-scoped subscription
        // still observes a language change originating in Settings.
        settings.set(.enUS, for: \.locale)
        XCTAssertEqual(fixture.about.title, "About Lumen Editor Native")
        XCTAssertEqual(fixture.windowRoot.title, "Window")
        XCTAssertTrue(settings.flush())
    }

    func testPresentedIssueLocalizationMapsRepresentativeTitlesAndMessages() {
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedTitle("Could Not Save File"),
            "无法保存文件"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedTitle("Could Not Run Toggle Sidebar"),
            "无法运行切换侧边栏"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "That path is already open in another tab. Close that tab or choose a different destination."
            ),
            "该路径已在另一个标签页中打开。请关闭该标签页，或选择其他目标位置。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "No command named plugin.run is available."
            ),
            "没有名为 plugin.run 的可用命令。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentedMessage(
                "3 succeeded, 1 rejected, 2 files opened."
            ),
            "3 个成功，1 个已拒绝，已打开 2 个文件。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentedMessage("This command is unavailable right now."),
            "This command is unavailable right now."
        )
    }

    func testLanguageToolAndEditorConfigTypedErrorsAreLocalized() {
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageToolIssue(.draft(.invalidLanguage)),
            "请选择有效的文档语言。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageToolIssue(
                .composition(.invalidLanguageServerEdit)
            ),
            "语言服务器返回了无效或重叠的格式化编辑。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEditorConfigIssue(
                .resolution(.targetOutsideWorkspace(URL(fileURLWithPath: "/tmp/outside")))
            ),
            "EditorConfig 目标位于请求的工作区根目录之外。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedLanguageToolIssue(.draft(.invalidLanguage)),
            "Choose a valid document language."
        )
    }

    func testUnknownLanguageToolAndEditorConfigErrorsAreNeverReverseLocalized() {
        let languageToolCollision = "Choose a valid document language."
        let editorConfigCollision =
            "The EditorConfig target is outside the requested workspace root."

        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageToolIssue(
                .verbatim(languageToolCollision)
            ),
            languageToolCollision
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEditorConfigIssue(
                .verbatim(editorConfigCollision)
            ),
            editorConfigCollision
        )
    }

    func testAppModelTypedIssuesUseRuntimeLocaleAndPreserveUnknownText() {
        let saveIssue = AppModelIssue.Message.app(
            .saveLocationRequired(displayName: "草稿.txt")
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedAppModelIssue(saveIssue),
            "Select a destination before saving 草稿.txt."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedAppModelIssue(saveIssue),
            "请先选择保存 草稿.txt 的目标位置。"
        )

        let typed = AppModelIssue.Message.textFileCodec(
            .fileChangedDuringOpen, context: "main.swift"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedAppModelIssue(typed),
            "main.swift：所选文件在打开期间发生了变化。"
        )

        let collision = "The destination must be a local file."
        XCTAssertEqual(
            EditorLocale.zhCN.localizedAppModelIssue(
                .verbatim(context: "remote", message: collision)
            ),
            "remote：The destination must be a local file."
        )
    }

    func testApprovalDescriptionLocalizesLabelsButPreservesValues() {
        let english = """
        Language: Swift
        Purpose: language-tool
        Workspace: /tmp/Project
        Command: /usr/bin/swift-format -i
        Working directory: /tmp/Project
        Uses shell command parsing: no
        Environment: none
        Identity: abc123
        """
        let chinese = """
        语言：Swift
        用途：language-tool
        工作区：/tmp/Project
        命令：/usr/bin/swift-format -i
        工作目录：/tmp/Project
        使用 shell 命令解析：否
        环境变量：无
        标识：abc123
        """

        XCTAssertEqual(
            EditorLocale.zhCN.localizedApprovalDescription(english), chinese
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedApprovalDescription(english), english
        )
    }

    func testProjectSettingsTypedIssuesUseRuntimeLocale() {
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .draft(.invalidJSONObject("Language servers"))
            ),
            "语言服务器必须是有效的 JSON 对象。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .draft(.invalidJSONArray("Build systems"))
            ),
            "构建系统必须是有效的 JSON 数组。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .draft(.draftTooLarge(maximumBytes: 1024))
            ),
            "项目设置最多可使用 1024 个 UTF-8 字节。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .store(.fileTooLarge(actualBytes: 2048, maximumBytes: 1024))
            ),
            "项目设置使用了 2048 个字节；上限为 1024 个字节。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .store(.fileSystem(operation: "rename", code: 13))
            ),
            "项目设置文件操作“rename”失败（errno 13）。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .languageServerAuthorization(.invalidSelection(URL(fileURLWithPath: "/tmp/lsp")))
            ),
            "请选择现有的语言服务器可执行文件。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(
                .languageServerAuthorization(.tooManySelections(maximum: 128))
            ),
            "一个会话最多可授权 128 个语言服务器可执行文件。"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssueTitle(.saveBuildCommand),
            "无法保存构建命令"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedProjectSettingsIssueTitle(.saveBuildCommand),
            "Could Not Save Build Command"
        )

        let collision = "Choose an existing executable file for the language server."
        XCTAssertEqual(
            EditorLocale.zhCN.localizedProjectSettingsIssue(.verbatim(collision)),
            collision
        )
    }

    func testInfoPlistLocalizationResourcesExistForEnglishAndChinese() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let english = repoRoot.appendingPathComponent(
            "Packaging/en.lproj/InfoPlist.strings"
        )
        let chinese = repoRoot.appendingPathComponent(
            "Packaging/zh_CN.lproj/InfoPlist.strings"
        )

        let englishContents = try String(contentsOf: english, encoding: .utf8)
        let chineseContents = try String(contentsOf: chinese, encoding: .utf8)

        XCTAssertTrue(englishContents.contains("\"CFBundleDisplayName\" = \"Lumen Editor Native\";"))
        XCTAssertTrue(englishContents.contains("\"CFBundleTypeName\" = \"Text document\";"))
        XCTAssertTrue(chineseContents.contains("\"CFBundleDisplayName\" = \"文本编辑器(徐洁阳) Native\";"))
        XCTAssertTrue(chineseContents.contains("\"CFBundleTypeName\" = \"文本文档\";"))
    }

    func testAccessibilityIdentifiersAreStableAndLocaleIndependent() {
        XCTAssertEqual(AppAccessibility.id("Find Query"), "lumen.find.query")
        XCTAssertEqual(AppAccessibility.id("find-query"), "lumen.find.query")
        XCTAssertEqual(AppAccessibility.id("JSON/tree row"), "lumen.json.tree.row")
        XCTAssertEqual(AppAccessibility.id("---"), "lumen")
    }

    func testEveryProductionViewIdentifierIsLocaleIndependent() {
        let components = [
            "workspace sidebar", "find query", "navigation results",
            "recent items", "settings locale", "snippet picker",
            "preview close", "json tree", "project settings save",
            "workspace search primary action", "outline filter",
            "build run", "terminal input", "git refresh",
            "software update", "command palette", "language palette",
            "color scheme", "marketplace search", "language server diagnostics"
        ]
        let identifiers = components.map(AppAccessibility.id)

        XCTAssertEqual(Set(identifiers).count, components.count)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("lumen.") })
        XCTAssertTrue(identifiers.allSatisfy { !$0.contains(" ") })
    }

    func testCommandLabelsUseTheRuntimeLocale() {
        XCTAssertEqual(
            Localization.commandLabel(
                for: "toggle-sidebar",
                locale: EditorLocale.zhCN,
                fallback: "Toggle Sidebar"
            ),
            "切换侧边栏"
        )
        XCTAssertEqual(
            Localization.commandLabel(
                for: "toggle-sidebar",
                locale: EditorLocale.enUS,
                fallback: "Toggle Sidebar"
            ),
            "Toggle Sidebar"
        )
    }

    func testAccessibilityPreferencesChangePresentationPolicy() {
        XCTAssertNil(AppAccessibility.animation(reduceMotion: true))
        XCTAssertNotNil(AppAccessibility.animation(reduceMotion: false))
        XCTAssertGreaterThan(
            AppAccessibility.selectionOpacity(for: .increased),
            AppAccessibility.selectionOpacity(for: .standard)
        )
        XCTAssertGreaterThan(
            AppAccessibility.separatorOpacity(for: .increased),
            AppAccessibility.separatorOpacity(for: .standard)
        )
    }
}

@MainActor
private struct SystemMenuFixture {
    let mainMenu: NSMenu
    let servicesMenu: NSMenu
    let windowsMenu: NSMenu
    let target: NSObject
    let about: NSMenuItem
    let services: NSMenuItem
    let hide: NSMenuItem
    let hideOthers: NSMenuItem
    let showAll: NSMenuItem
    let quit: NSMenuItem
    let windowRoot: NSMenuItem
    let minimize: NSMenuItem
    let zoom: NSMenuItem
    let toggleFullScreen: NSMenuItem
    let bringAllToFront: NSMenuItem

    var actionItems: [NSMenuItem] {
        [about, hide, hideOthers, showAll, quit, minimize, zoom,
         toggleFullScreen, bringAllToFront]
    }

    var localizedItems: [NSMenuItem] {
        [about, services, hide, hideOthers, showAll, quit,
         windowRoot, minimize, zoom, toggleFullScreen, bringAllToFront]
    }
}

@MainActor
private func makeSystemMenuFixture() -> SystemMenuFixture {
    let target = NSObject()
    var nextIdentifier = 0

    func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: action, keyEquivalent: keyEquivalent
        )
        item.target = target
        item.identifier = NSUserInterfaceItemIdentifier(
            "app-localization-test-\(nextIdentifier)"
        )
        item.keyEquivalentModifierMask = [.command, .option]
        nextIdentifier += 1
        return item
    }

    let mainMenu = NSMenu(title: "Main")
    let applicationRoot = NSMenuItem(title: "Application", action: nil, keyEquivalent: "")
    applicationRoot.identifier = NSUserInterfaceItemIdentifier(
        "app-localization-test-application"
    )
    let applicationMenu = NSMenu(title: "Application")
    applicationRoot.submenu = applicationMenu
    mainMenu.addItem(applicationRoot)

    let about = item(
        "About",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: "a"
    )
    let servicesMenu = NSMenu(title: "Services")
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.identifier = NSUserInterfaceItemIdentifier(
        "app-localization-test-services"
    )
    services.submenu = servicesMenu
    let hide = item(
        "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
    )
    let hideOthers = item(
        "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "o"
    )
    let showAll = item(
        "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: "s"
    )
    let quit = item(
        "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    [about, services, hide, hideOthers, showAll, quit].forEach {
        applicationMenu.addItem($0)
    }

    let windowsMenu = NSMenu(title: "Window")
    let windowRoot = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowRoot.identifier = NSUserInterfaceItemIdentifier(
        "app-localization-test-window"
    )
    windowRoot.submenu = windowsMenu
    mainMenu.addItem(windowRoot)

    let minimize = item(
        "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
    )
    let zoom = item(
        "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "z"
    )
    let toggleFullScreen = item(
        "Toggle Full Screen",
        action: #selector(NSWindow.toggleFullScreen(_:)),
        keyEquivalent: "f"
    )
    let bringAllToFront = item(
        "Bring All to Front",
        action: #selector(NSApplication.arrangeInFront(_:)),
        keyEquivalent: "f"
    )
    [minimize, zoom, toggleFullScreen, bringAllToFront].forEach {
        windowsMenu.addItem($0)
    }

    return SystemMenuFixture(
        mainMenu: mainMenu, servicesMenu: servicesMenu, windowsMenu: windowsMenu,
        target: target, about: about, services: services, hide: hide,
        hideOthers: hideOthers, showAll: showAll, quit: quit,
        windowRoot: windowRoot, minimize: minimize, zoom: zoom,
        toggleFullScreen: toggleFullScreen,
        bringAllToFront: bringAllToFront
    )
}

// MARK: - EncodingNotice localization

extension AppLocalizationTests {
    func testFileSaveNoticesAreLocalizedWithoutChangingRecoveryPath() {
        let documentID = UUID()
        let artifact = URL(fileURLWithPath: "/tmp/恢复 recovery copy")
        let durability = FileSaveNotice.durabilityUnconfirmed(
            documentID: documentID, displayName: "notes.txt",
            recoveryArtifact: artifact
        )
        let cleanup = FileSaveNotice.cleanupIncomplete(
            documentID: documentID, displayName: "notes.txt",
            recoveryArtifact: nil
        )

        XCTAssertTrue(
            EditorLocale.enUS.localizedFileSaveNotice(durability)
                .contains(artifact.path)
        )
        XCTAssertTrue(
            EditorLocale.zhCN.localizedFileSaveNotice(durability)
                .contains(artifact.path)
        )
        XCTAssertTrue(
            EditorLocale.zhCN.localizedFileSaveNotice(cleanup)
                .contains("临时恢复项未能完全清理")
        )
    }

    func testEncodingNoticeForInitialOpenIsLocalized() {
        let documentID = UUID()
        XCTAssertEqual(
            EditorLocale.enUS.localizedEncodingNotice(
                .invalidBytesAfterOpen(documentID: documentID, encoding: .utf8)
            ),
            "The file cannot be decoded losslessly as UTF-8. Reopen with the correct encoding before overwriting it."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEncodingNotice(
                .uncertainEncodingAfterOpen(
                    documentID: documentID, encoding: .utf16leNoBom
                )
            ),
            "已推测为 UTF-16 LE (no BOM)；如显示异常，请以其他编码重新打开。"
        )
    }

    func testEncodingNoticeReopenSuccessEnglish() {
        let documentID = UUID()
        let notice = EncodingNotice.reopenSuccess(
            documentID: documentID, requestedEncoding: .utf8,
            actualEncoding: .utf8,
            displayName: "config.json"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedEncodingNotice(notice),
            "Reopened “config.json” using UTF-8 (UTF-8)."
        )
    }

    func testEncodingNoticeReopenSuccessChinese() {
        let documentID = UUID()
        let notice = EncodingNotice.reopenSuccess(
            documentID: documentID, requestedEncoding: .utf8,
            actualEncoding: .utf8,
            displayName: "config.json"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEncodingNotice(notice),
            "已使用UTF-8重新打开“config.json”（UTF-8）。"
        )
    }

    func testEncodingNoticeInvalidBytesAfterReopenEnglish() {
        let documentID = UUID()
        let notice = EncodingNotice.invalidBytesAfterReopen(
            documentID: documentID, requestedEncoding: .gb18030
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedEncodingNotice(notice),
            "Reopened using GB 18030, but some bytes cannot round-trip; saving is disabled."
        )
    }

    func testEncodingNoticeInvalidBytesAfterReopenChinese() {
        let documentID = UUID()
        let notice = EncodingNotice.invalidBytesAfterReopen(
            documentID: documentID, requestedEncoding: .gb18030
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEncodingNotice(notice),
            "已使用GB 18030打开，但检测到不能无损往返的字节；保存已禁用。"
        )
    }

    func testEncodingNoticeInvalidBytesAfterExternalReloadEnglish() {
        let documentID = UUID()
        let notice = EncodingNotice.invalidBytesAfterExternalReload(
            documentID: documentID, encoding: .windows1252
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedEncodingNotice(notice),
            "The disk file cannot be decoded losslessly as Windows-1252. Reopen with the correct encoding before saving."
        )
    }

    func testEncodingNoticeInvalidBytesAfterExternalReloadChinese() {
        let documentID = UUID()
        let notice = EncodingNotice.invalidBytesAfterExternalReload(
            documentID: documentID, encoding: .windows1252
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedEncodingNotice(notice),
            "磁盘文件无法按 Windows-1252 无损解码；请以正确编码重新打开，覆盖保存已禁用。"
        )
    }
}
