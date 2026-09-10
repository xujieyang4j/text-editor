import AppKit
import Foundation
import LumenEditorCore
import SwiftUI

/// App-layer localisation helpers used by SwiftUI views.
///
/// `LumenEditorCore.Localization` owns the shared Electron/native catalogue.
/// This file deliberately keeps presentation-only copy out of that parity
/// catalogue while giving every view one runtime locale source.
enum AppLocalizedCopy: Hashable, Sendable {
    case appName
    case systemAppName
    case confirmExternalLanguageTool
    case runLanguageTool
    case approvalCurrentWindowExactConfiguration
    case runLanguageServerPrompt
    case runLanguageServer
    case runPluginWorkerPrompt
    case approvalCurrentWindowExactWorkerConfiguration
    case installLocalPlugin
    case chooseLocalPluginDirectory
    case install
    case couldNotAuthorizePluginFolder
    case couldNotLoadPlugins
    case couldNotInstallPlugin
    case couldNotUpdatePlugin
    case couldNotUpdatePluginPermissions
    case couldNotRemovePlugin
    case noWorkspaceOpen
    case couldNotSaveMarketplaceSettings
    case couldNotLoadMarketplaceSettings
    case noMarketplaceSources
    case couldNotLoadMarketplace
    case couldNotInstallMarketplacePlugin
    case openWorkspaceBeforeManagingProjectPlugins
    case addHTTPSMarketplaceSourceFirst
    case couldNotLoadPluginWorker
    case couldNotRunPluginCommand
    case couldNotStartPluginWorker
    case couldNotRunPluginWorker
    case couldNotBuildPluginContext
    case pluginWorkerFailed
    case pluginWorkerExited
    case couldNotCheckForUpdates
    case couldNotSaveSettings
    case updateEndpointNotApproved
    case updateRedirectedUnexpectedly
    case updateInvalidResponse
    case updateResponseTooLarge(maximumBytes: Int)
    case updateMalformedReleaseMetadata
    case openFiles
    case openFolder
    case chooseWorkspaceFolder
    case addFolderToWorkspace
    case chooseAnotherWorkspaceFolder
    case add
    case moveItem(name: String)
    case chooseMoveDestination
    case move
    case openUsingEncoding(name: String)
    case chooseTextFilesToOpen
    case saveDocument(name: String)
    case chooseWhereToSaveDocument
    case save
    case importSublime(kindName: String)
    case chooseSublimeSource(fileExtension: String)
    case authorizeSublimeProjectFolder
    case confirmSublimeProjectFolder(path: String)
    case authorize
    case documentMinimap
    case couldNotOpenLanguageServerLocation
    case requestedLanguageServerLocationCouldNotOpen(path: String)
    case removeFolderFromProject
    case chooseFolderToRemove
    case remove
    case renameSymbol
    case enterNewSymbolName
    case newName
    case preview
    case applyRename
    case applyRenameEditCount(editCount: Int, fileCount: Int)
    case apply
    case aboutApp(appName: String)
    case services
    case hideApp(appName: String)
    case hideOthers
    case showAll
    case quitApp(appName: String)
    case windowMenu
    case minimize
    case zoom
    case toggleFullScreen
    case bringAllToFront
    case saveChangesToDocument(name: String)
    case reviewBeforeClosing
    case loseUnsavedChanges
    case reopenUsingEncoding(name: String)
    case discardUnsavedEditsAndReinterpret
    case reinterpretOriginalFileBytes
    case reloadDiskVersionPrompt
    case discardLocalDraftForDiskVersion
    case terminalExited(code: Int32)
    case commandPaletteUnavailable
    case commandPaletteUnsupported
    case commandPaletteNoChange
    case commandPaletteUnknownCommand
    case findInvalidRegularExpression(diagnostic: String)
    case findResultLimitMustBePositive
    case findTooManyMatchesToReplaceSafely
    case findZeroWidthRegularExpressionCannotBeReplaced
    case jsonUnexpectedTrailingContent(line: Int, column: Int)
    case jsonExpectedValue(line: Int, column: Int)
    case jsonExpectedObjectKey(line: Int, column: Int)
    case jsonInvalidString(line: Int, column: Int)
    case jsonControlCharacterInString(line: Int, column: Int)
    case jsonUnterminatedString(line: Int, column: Int)
    case jsonInvalidNumber(line: Int, column: Int)
    case jsonExpectedLiteral(value: String, line: Int, column: Int)
    case jsonExpectedToken(value: String, line: Int, column: Int)
    case jsonInputExceedsLimit(maximum: Int, line: Int, column: Int)
    case jsonNestingExceedsLimit(maximum: Int, line: Int, column: Int)
    case jsonNodeCountExceedsLimit(maximum: Int, line: Int, column: Int)
    case jsonOutputExceedsLimit(maximum: Int)
    case documentChangedBeforeJSONTransformApplied
    case jsonOutputUsesTooManyCodeUnits(actual: Int, maximum: Int)
    case jsonDepthExceedsMaximum(actual: Int, maximum: Int)
    case jsonNodeCountExceedsMaximum(actual: Int, maximum: Int)
    case jsonIndentExceedsMaximum(actual: Int, maximum: Int)
    case markdownExceedsPreviewLimit(maximum: Int)
    case markdownPreviewExceedsBlockLimit(maximum: Int)
    case jsonTreeChangedBeforeEditBegan
    case selectedJSONNodeNoLongerExists
    case jsonTreeChangedBeforeEditApplied
    case noEditableJSONTree
    case jsonTreeNotAttachedToEditorRevision
    case documentChangedAfterJSONTreeRendered
    case documentChangedBeforeJSONEditApplied
    case jsonPathDoesNotExist
    case jsonPathWrongContainer(expected: String)
    case jsonObjectKeyEmptyOrProtected
    case jsonObjectKeyAlreadyExists
    case jsonRootCannotBeRemoved
    case invalidUTF16EditRange(from: Int, to: Int)
    case overlappingUTF16Edits(firstFrom: Int, firstTo: Int, secondFrom: Int, secondTo: Int)
    case utf16EditOutsideDocument(from: Int, to: Int, length: Int)
    case utf16PositionOutsideDocument(position: Int, length: Int)
    case selectionOutsideDocument(viewID: String, length: Int)
    case unknownEditorView(viewID: String)
    case staleEditorRevision(expected: UInt64, actual: UInt64)
    case couldNotOpenBrowserPreview
    case systemBrowserRejectedHTMLPreviewURL
    case htmlPreviewRequiresHTMLDocument
    case htmlSourceNotAbsoluteLocalFile(url: String)
    case htmlPreviewTemporaryDirectoryUnsafe(path: String)
    case htmlPreviewTooLarge(actual: Int, maximum: Int)
    case htmlPreviewStoreShutDown
    case htmlPreviewCouldNotAllocatePrivateDirectory
    case htmlPreviewFileSystemFailure(operation: String, path: String, code: Int32)
    case browserPreviewCouldNotBeOpened
}

/// Persistent presentation state distinguishes localisable application copy
/// from system, tool, and other externally supplied text. Views resolve the
/// payload with their current environment locale instead of storing a string
/// produced under an earlier locale.
enum AppPresentationText: Equatable, Sendable {
    case app(AppLocalizedCopy)
    case fileSaveNotice(FileSaveNotice)
    case verbatim(String)
}

enum AppStatusPresentationPurpose: Equatable, Sendable {
    case visible
    case announcement
}

/// Errors that can preserve structured app-owned presentation copy while they
/// travel through generic command routing. Unknown errors intentionally do not
/// conform and therefore remain verbatim at the presentation boundary.
protocol AppPresentationError: Error {
    var presentationText: AppPresentationText { get }
}

extension EditorLocale {
    /// The Foundation locale installed into SwiftUI together with `appLocale`.
    /// This keeps system-provided labels, formatters, and accessibility speech in
    /// the same language as app-owned copy.
    var foundationLocale: Locale { Locale(identifier: rawValue) }

    var isSimplifiedChinese: Bool { self == .zhCN }

    var commandLocale: CommandLocale {
        isSimplifiedChinese ? .simplifiedChinese : .english
    }

    /// Localises view-specific copy that does not belong to the shared command
    /// catalogue. English is first so call sites remain easy to scan.
    func text(_ english: String, zh chinese: String) -> String {
        isSimplifiedChinese ? chinese : english
    }

    /// Resolves a key from the shared, type-safe catalogue.
    func localized(
        _ key: LocalizationKey,
        arguments: Localization.Arguments = [:]
    ) -> String {
        Localization.string(key, locale: self, arguments: arguments)
    }

    func localizedPresentation(_ content: AppPresentationText) -> String {
        switch content {
        case let .app(copy):
            localizedApp(copy)
        case let .fileSaveNotice(notice):
            localizedFileSaveNotice(notice)
        case let .verbatim(message):
            message
        }
    }

    func localizedAppModelIssueTitle(_ title: AppModelIssue.Title) -> String {
        switch title {
        case .updateSelection:
            return text("Could Not Update Selection", zh: "无法更新所选内容")
        case .editDocument:
            return text("Could Not Edit Document", zh: "无法编辑文档")
        case .openFile:
            return text("Could Not Open File", zh: "无法打开文件")
        case .reopenFile:
            return text("Could Not Reopen File", zh: "无法重新打开文件")
        case .chooseSaveLocation:
            return text("Choose a Save Location", zh: "请选择保存位置")
        case .saveFile:
            return text("Could Not Save File", zh: "无法保存文件")
        case .confirmEncoding:
            return text("Encoding Must Be Confirmed", zh: "必须确认编码")
        case .saveSession:
            return text("Could Not Save Session", zh: "无法保存会话")
        case .resolveExternalChange:
            return text("Resolve External Change", zh: "请先解决外部更改")
        case .saveDestinationChanged:
            return text("Save Destination Changed", zh: "保存目标已更改")
        case .binaryFile:
            return text("Binary File", zh: "二进制文件")
        case .fileTooLarge:
            return text("File Is Too Large", zh: "文件过大")
        }
    }

    func localizedAppModelIssue(_ content: AppModelIssue.Message) -> String {
        switch content {
        case let .app(issue):
            switch issue {
            case let .saveLocationRequired(displayName):
                return text(
                    "Select a destination before saving \(displayName).",
                    zh: "请先选择保存 \(displayName) 的目标位置。"
                )
            case .destinationAlreadyOpen:
                return text(
                    "That path is already open in another tab. Close that tab or choose a different destination.",
                    zh: "该路径已在另一个标签页中打开。请关闭该标签页，或选择其他目标位置。"
                )
            case .encodingRequiredForLocalVersion:
                return text(
                    "Reopen with the correct encoding or save the local version to a new file.",
                    zh: "请使用正确的编码重新打开，或将本地版本保存到新文件。"
                )
            case .destinationMustBeLocal:
                return text("The destination must be a local file.", zh: "目标位置必须是本地文件。")
            case .externalChangeMustBeResolved:
                return text(
                    "Reload, keep the local version, or save it to a different file before continuing.",
                    zh: "继续前，请重新载入、保留本地版本，或将其保存到其他文件。"
                )
            case .encodingRequiredForSave:
                return text(
                    "Reopen with the correct encoding, or save the displayed text to a different file.",
                    zh: "请使用正确的编码重新打开，或将当前显示的文本保存到其他文件。"
                )
            case .hardLinkedDestination:
                return text(
                    "The destination has multiple hard links and cannot be safely replaced.",
                    zh: "目标存在多个硬链接，无法安全替换。"
                )
            case .destinationChanged:
                return text(
                    "The selected destination changed before it could be replaced. Review it and try again.",
                    zh: "所选目标在替换前已发生变化。请检查后重试。"
                )
            case let .binaryFile(name):
                return text(
                    "\(name) does not appear to be a text file.",
                    zh: "\(name) 看起来不是文本文件。"
                )
            case let .fileTooLarge(name, maximum):
                return text(
                    "\(name) exceeds the configured editable size limit of \(maximum) MB. Adjust it in Settings > Files and Automation, then relaunch before opening the file again.",
                    zh: "\(name) 超出了已配置的 \(maximum) MB 可编辑大小限制。请在“设置 > 文件与自动化”中调整后重新启动，再打开该文件。"
                )
            }
        case let .editorTransaction(error, context):
            return contextualized(
                localizedEditorTransactionError(error), context: context
            )
        case let .textFileCodec(error, context):
            return contextualized(localizedTextFileCodecError(error), context: context)
        case let .sessionStore(error, context):
            return contextualized(localizedSessionStoreError(error), context: context)
        case let .fileWrite(error, context):
            return contextualized(localizedFileWriteFailure(error), context: context)
        case let .fileWriteCommit(error, context):
            return contextualized(
                localizedFileWriteCommitFailure(error), context: context
            )
        case let .verbatim(context, message):
            return contextualized(message, context: context)
        }
    }

    private func contextualized(_ message: String, context: String?) -> String {
        guard let context else { return message }
        return text("\(context): \(message)", zh: "\(context)：\(message)")
    }

    private func localizedEditorTransactionError(
        _ error: EditorTransactionError
    ) -> String {
        switch error {
        case let .invalidEditRange(edit):
            return localizedApp(.invalidUTF16EditRange(from: edit.from, to: edit.to))
        case let .overlappingEdits(first, second):
            return localizedApp(.overlappingUTF16Edits(
                firstFrom: first.from, firstTo: first.to,
                secondFrom: second.from, secondTo: second.to
            ))
        case let .editOutOfBounds(edit, length):
            return localizedApp(.utf16EditOutsideDocument(
                from: edit.from, to: edit.to, length: length
            ))
        case let .positionOutOfBounds(position, length):
            return localizedApp(.utf16PositionOutsideDocument(
                position: position, length: length
            ))
        case let .selectionOutOfBounds(viewID, length):
            return localizedApp(.selectionOutsideDocument(
                viewID: viewID.rawValue, length: length
            ))
        case let .unknownView(viewID):
            return localizedApp(.unknownEditorView(viewID: viewID.rawValue))
        case let .staleRevision(expected, actual):
            return localizedApp(.staleEditorRevision(expected: expected, actual: actual))
        }
    }

    private func localizedTextFileCodecError(_ error: TextFileCodecError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .notARegularFile: return "所选路径不是普通文件。"
        case .invalidMaximumByteCount: return "最大可编辑字节数不能为负数。"
        case .fileChangedDuringOpen: return "所选文件在打开期间发生了变化。"
        case let .invalidData(encoding): return "无效的 \(encoding.displayName) 数据。"
        case let .oddUTF16ByteCount(encoding):
            return "无效的 \(encoding.displayName) 数据：UTF-16 字节长度为奇数。"
        case let .unsupportedEncoding(encoding):
            return "当前 macOS 安装不支持 \(encoding.displayName)。"
        case let .cannotRepresent(encoding):
            return "\(encoding.displayName) 无法无损表示此文档中的所有字符。"
        }
    }

    private func localizedSessionStoreError(_ error: SessionStoreError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .tooManyTabs(actual, maximum):
            return "会话包含 \(actual) 个标签页；上限为 \(maximum) 个。"
        case let .draftDataTooLarge(actual, maximum):
            return "会话草稿使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case let .snapshotTooLarge(actual, maximum):
            return "会话快照使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case .invalidSnapshot: return "会话快照包含无效的文档状态。"
        case let .unsupportedFormatVersion(version):
            return "不支持会话格式版本 \(version)。"
        }
    }

    private func localizedFileWriteFailure(_ error: FileWriteFailure) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .conflict: return "文件自打开后已在磁盘上发生变化。"
        case .hardLinked: return "文件有多个硬链接，因此未被替换。"
        case .invalidExpectedRevision: return "预期的文件修订版本无效。"
        }
    }

    private func localizedFileWriteCommitFailure(
        _ error: FileWriteCommitFailure
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .cleanupFailedBeforeCommit:
            return "写入未提交，且临时文件未能完全清理。"
        case .stateIndeterminate:
            return "原子替换期间文件发生变化；恢复数据已尽可能保留。"
        }
    }

    func localizedTerminalIssueTitle(
        _ title: TerminalPresentationIssue.Title
    ) -> String {
        switch title {
        case .noWorkspaceOpen: return text("No Workspace Open", zh: "未打开工作区")
        case .notRunning: return text("Terminal Not Running", zh: "终端未运行")
        case .invalidInput: return text("Invalid Terminal Input", zh: "终端输入无效")
        case .inputFailed: return text("Terminal Input Failed", zh: "终端输入失败")
        case .interruptFailed:
            return text("Terminal Interrupt Failed", zh: "终端中断失败")
        case .couldNotStart: return text("Terminal Could Not Start", zh: "无法启动终端")
        case .sessionEnded: return text("Terminal Session Ended", zh: "终端会话已结束")
        case .invalidConfiguration:
            return text("Invalid Terminal Configuration", zh: "终端配置无效")
        case let .verbatim(value): return value
        }
    }

    func localizedTerminalIssue(
        _ content: TerminalPresentationIssue.Message
    ) -> String {
        switch content {
        case .openWorkspaceBeforeStarting:
            return text(
                "Open a workspace folder before starting the terminal.",
                zh: "请先打开工作区文件夹，再启动终端。"
            )
        case .startBeforeSendingInput:
            return text(
                "Start the project terminal before sending input.",
                zh: "请先启动项目终端，再发送输入。"
            )
        case let .inputByteLimit(maximum):
            return text(
                "Terminal input must be between 1 and \(maximum) UTF-8 bytes.",
                zh: "终端输入必须介于 1 和 \(maximum) 个 UTF-8 字节之间。"
            )
        case .inputDeliveryFailed:
            return text(
                "The input could not be delivered to the active terminal.",
                zh: "无法将输入发送到活动终端。"
            )
        case .interruptDeliveryFailed:
            return text(
                "SIGINT could not be delivered to the active terminal session.",
                zh: "无法向活动终端会话发送 SIGINT。"
            )
        case .approvedShellCouldNotStart:
            return text(
                "The approved project shell could not be started.",
                zh: "无法启动已授权的项目 shell。"
            )
        case .processEndedUnexpectedly:
            return text(
                "The terminal process ended unexpectedly.",
                zh: "终端进程意外结束。"
            )
        case .invalidOrUntrustedConfiguration:
            return text(
                "The project shell configuration is invalid or is not in the trusted executable allowlist.",
                zh: "项目 shell 配置无效，或不在受信任的可执行文件允许列表中。"
            )
        case let .verbatim(value): return value
        }
    }

    func localizedMacroSnippetIssueTitle(
        _ title: MacroSnippetPresentationIssue.Title
    ) -> String {
        switch title {
        case .snippetSessionEnded:
            return text("Snippet Session Ended", zh: "代码片段会话已结束")
        case .macroUnavailable:
            return text("Macro Unavailable", zh: "宏不可用")
        case .noWorkspaceOpen:
            return text("No Workspace Open", zh: "未打开工作区")
        case .macroCouldNotBeSaved:
            return text("Macro Could Not Be Saved", zh: "无法保存宏")
        case .savedMacrosCouldNotBeLoaded:
            return text("Saved Macros Could Not Be Loaded", zh: "无法载入已保存的宏")
        case .snippetUnavailable:
            return text("Snippet Unavailable", zh: "代码片段不可用")
        case .snippetCouldNotBeInserted:
            return text("Snippet Could Not Be Inserted", zh: "无法插入代码片段")
        case .macroCouldNotRun:
            return text("Macro Could Not Run", zh: "无法运行宏")
        case .macroRecordingStopped:
            return text("Macro Recording Stopped", zh: "宏录制已停止")
        case let .verbatim(value): return value
        }
    }

    func localizedMacroSnippetIssue(
        _ content: MacroSnippetPresentationIssue.Message
    ) -> String {
        switch content {
        case let .app(english, chinese): return text(english, zh: chinese)
        case let .verbatim(value): return value
        }
    }

    func localizedLanguageServerIssueTitle(
        _ title: LanguageServerPresentationIssue.Title
    ) -> String {
        switch title {
        case .couldNotStart:
            return text("Could Not Start Language Server", zh: "无法启动语言服务器")
        case .couldNotSynchronize:
            return text("Could Not Synchronize Document", zh: "无法同步文档")
        case .couldNotCloseDocument:
            return text(
                "Could Not Close Language Server Document",
                zh: "无法关闭语言服务器文档"
            )
        case .couldNotRestart:
            return text("Could Not Restart Language Server", zh: "无法重新启动语言服务器")
        case .couldNotPreviewRename:
            return text("Could Not Preview Rename", zh: "无法预览重命名")
        case .requestFailed:
            return text("Language Server Request Failed", zh: "语言服务器请求失败")
        case .invalidRequest:
            return text("Invalid Language Server Request", zh: "语言服务器请求无效")
        case let .verbatim(value): return value
        }
    }

    func localizedLanguageServerIssue(
        _ content: LanguageServerPresentationIssue.Message
    ) -> String {
        switch content {
        case let .app(english, chinese): return text(english, zh: chinese)
        case let .verbatim(value): return value
        }
    }

    func localizedFindStatus(
        _ status: FindBarStatus,
        queryIsEmpty: Bool,
        purpose: AppStatusPresentationPurpose
    ) -> String {
        switch status {
        case .idle:
            guard purpose == .visible else { return "" }
            return queryIsEmpty
                ? text("Enter text to find.", zh: "请输入要查找的文本。")
                : text("Ready to find.", zh: "已准备好查找。")
        case .searching:
            return purpose == .visible
                ? text("Finding matches…", zh: "正在查找匹配项…")
                : ""
        case let .matches(current, total, truncated):
            let position = current.map { index in
                purpose == .visible
                    ? text("\(index) of \(total)", zh: "第 \(index) 项，共 \(total) 项")
                    : text(
                        "Find result \(index) of \(total)",
                        zh: "查找结果第 \(index) 项，共 \(total) 项"
                    )
            } ?? text(
                "\(total) \(englishNoun(total, singular: "match", plural: "matches"))",
                zh: "\(total) 个匹配项"
            )
            return position + (truncated
                ? text(" (limit reached)", zh: "（已达到上限）")
                : "")
        case .noMatches:
            return text("No matches.", zh: "没有匹配项。")
        case let .replaced(count):
            return text(
                "Replaced \(count) \(englishNoun(count, singular: "match", plural: "matches")).",
                zh: "已替换 \(count) 个匹配项。"
            )
        case .unavailable:
            return purpose == .visible
                ? text("No active document.", zh: "没有活动文档。")
                : text("Find is unavailable.", zh: "查找不可用。")
        case let .invalidQuery(content):
            return localizedPresentation(content)
        }
    }

    private func englishNoun(
        _ count: Int, singular: String, plural: String
    ) -> String {
        count == 1 ? singular : plural
    }

    func localizedWorkspaceSearchStatus(
        _ status: WorkspaceSearchStatus,
        hasRoots: Bool,
        purpose: AppStatusPresentationPurpose
    ) -> String {
        switch status {
        case .idle:
            guard purpose == .visible else { return "" }
            return hasRoots
                ? text("Ready to search.", zh: "已准备好搜索。")
                : text(
                    "Open a workspace folder to search.",
                    zh: "请打开工作区文件夹以搜索。"
                )
        case .searching:
            return text("Searching workspace…", zh: "正在搜索工作区…")
        case let .matches(count, truncated):
            let prefix = purpose == .visible ? "" : "Found "
            let suffix = truncated
                ? text(" (limit reached)", zh: "（已达到上限）")
                : ""
            return text(
                "\(prefix)\(count) \(englishNoun(count, singular: "match", plural: "matches"))\(suffix)\(purpose == .visible ? "." : "")",
                zh: "找到 \(count) 个匹配项\(suffix)\(purpose == .visible ? "。" : "")"
            )
        case .previewing:
            return text("Preparing replacement preview…", zh: "正在准备替换预览…")
        case let .previewReady(files, replacements, truncated):
            let prefix = purpose == .visible ? "Preview: " : "Replacement preview contains "
            let base = text(
                "\(prefix)\(replacements) \(englishNoun(replacements, singular: "replacement", plural: "replacements")) in \(files) \(englishNoun(files, singular: "file", plural: "files"))",
                zh: purpose == .visible
                    ? "预览：\(files) 个文件中有 \(replacements) 处替换"
                    : "替换预览包含 \(files) 个文件中的 \(replacements) 处更改"
            )
            let limit = truncated
                ? text(
                    " The preview is limited to the first results.",
                    zh: " 预览仅包含最前面的结果。"
                )
                : ""
            return base + (purpose == .visible ? text(".", zh: "。") : "") + limit
        case .applying:
            return text("Applying replacement preview…", zh: "正在应用替换预览…")
        case let .applied(files, replacements):
            return text(
                "Replaced \(replacements) \(englishNoun(replacements, singular: "match", plural: "matches")) in \(files) \(englishNoun(files, singular: "file", plural: "files"))\(purpose == .visible ? "." : "")",
                zh: "已替换 \(files) 个文件中的 \(replacements) 个匹配项\(purpose == .visible ? "。" : "")"
            )
        case .undoing:
            return text("Undoing workspace replacement…", zh: "正在撤销工作区替换…")
        case let .undone(files):
            return text(
                "Restored \(files) \(englishNoun(files, singular: "file", plural: "files"))\(purpose == .visible ? "." : "")",
                zh: "已恢复 \(files) 个文件\(purpose == .visible ? "。" : "")"
            )
        case .cancelled:
            return text("Workspace search cancelled.", zh: "工作区搜索已取消。")
        }
    }

    /// Runtime-only UI copy that stays outside the shared command catalogue.
    func localizedApp(_ copy: AppLocalizedCopy) -> String {
        switch copy {
        case .appName:
            return text("Lumen Editor", zh: "Lumen Editor")
        case .systemAppName:
            return text("Lumen Editor Native", zh: "文本编辑器(徐洁阳) Native")
        case .confirmExternalLanguageTool:
            return text(
                "Confirm External Language Tool",
                zh: "确认外部语言工具"
            )
        case .runLanguageTool:
            return text("Run Language Tool", zh: "运行语言工具")
        case .approvalCurrentWindowExactConfiguration:
            return text(
                "Approval lasts only for this exact configuration in the current window session.",
                zh: "此授权仅在当前窗口会话中对这一准确配置有效。"
            )
        case .runLanguageServerPrompt:
            return text("Run Language Server?", zh: "运行语言服务器？")
        case .runLanguageServer:
            return text("Run Language Server", zh: "运行语言服务器")
        case .runPluginWorkerPrompt:
            return text("Run Plugin Worker?", zh: "运行插件 Worker？")
        case .approvalCurrentWindowExactWorkerConfiguration:
            return text(
                "Approval lasts only for this exact worker and permission set in the current window session.",
                zh: "此授权仅在当前窗口会话中对这一准确 Worker 和权限集有效。"
            )
        case .installLocalPlugin:
            return text("Install Local Plugin", zh: "安装本地插件")
        case .chooseLocalPluginDirectory:
            return text(
                "Choose a declarative plugin directory containing plugin.json.",
                zh: "选择包含 plugin.json 的声明式插件目录。"
            )
        case .install:
            return text("Install", zh: "安装")
        case .couldNotAuthorizePluginFolder:
            return text(
                "Could Not Authorize Plugin Folder",
                zh: "无法授权插件文件夹"
            )
        case .couldNotLoadPlugins:
            return text("Could Not Load Plugins", zh: "无法载入插件")
        case .couldNotInstallPlugin:
            return text("Could Not Install Plugin", zh: "无法安装插件")
        case .couldNotUpdatePlugin:
            return text("Could Not Update Plugin", zh: "无法更新插件")
        case .couldNotUpdatePluginPermissions:
            return text(
                "Could Not Update Plugin Permissions",
                zh: "无法更新插件权限"
            )
        case .couldNotRemovePlugin:
            return text("Could Not Remove Plugin", zh: "无法移除插件")
        case .noWorkspaceOpen:
            return text("No Workspace Open", zh: "未打开工作区")
        case .couldNotSaveMarketplaceSettings:
            return text(
                "Could Not Save Marketplace Settings",
                zh: "无法保存插件市场设置"
            )
        case .couldNotLoadMarketplaceSettings:
            return text(
                "Could Not Load Marketplace Settings",
                zh: "无法载入插件市场设置"
            )
        case .noMarketplaceSources:
            return text("No Marketplace Sources", zh: "没有插件市场来源")
        case .couldNotLoadMarketplace:
            return text("Could Not Load Marketplace", zh: "无法载入插件市场")
        case .couldNotInstallMarketplacePlugin:
            return text(
                "Could Not Install Marketplace Plugin",
                zh: "无法安装插件市场中的插件"
            )
        case .openWorkspaceBeforeManagingProjectPlugins:
            return text(
                "Open a workspace before managing project plugins.",
                zh: "请先打开工作区，再管理项目插件。"
            )
        case .addHTTPSMarketplaceSourceFirst:
            return text(
                "Add an HTTPS marketplace source for this project first.",
                zh: "请先为此项目添加 HTTPS 插件市场来源。"
            )
        case .couldNotLoadPluginWorker:
            return text("Could Not Load Plugin Worker", zh: "无法加载插件 Worker")
        case .couldNotRunPluginCommand:
            return text("Could Not Run Plugin Command", zh: "无法运行插件命令")
        case .couldNotStartPluginWorker:
            return text("Could Not Start Plugin Worker", zh: "无法启动插件 Worker")
        case .couldNotRunPluginWorker:
            return text("Could Not Run Plugin Worker", zh: "无法运行插件 Worker")
        case .couldNotBuildPluginContext:
            return text("Could Not Build Plugin Context", zh: "无法构建插件上下文")
        case .pluginWorkerFailed:
            return text("Plugin Worker Failed", zh: "插件 Worker 失败")
        case .pluginWorkerExited:
            return text("Plugin Worker Exited", zh: "插件 Worker 已退出")
        case .couldNotCheckForUpdates:
            return text("Could Not Check for Updates", zh: "无法检查更新")
        case .couldNotSaveSettings:
            return text("Could Not Save Settings", zh: "无法保存设置")
        case .updateEndpointNotApproved:
            return text(
                "The update endpoint is not an approved HTTPS URL.",
                zh: "更新端点不是已获准的 HTTPS 网址。"
            )
        case .updateRedirectedUnexpectedly:
            return text(
                "The update service redirected the request unexpectedly.",
                zh: "更新服务意外重定向了请求。"
            )
        case .updateInvalidResponse:
            return text(
                "The update service returned an invalid response.",
                zh: "更新服务返回了无效响应。"
            )
        case let .updateResponseTooLarge(maximumBytes):
            return text(
                "The update response exceeded \(maximumBytes) bytes.",
                zh: "更新响应超过 \(maximumBytes) 字节。"
            )
        case .updateMalformedReleaseMetadata:
            return text(
                "The update service returned malformed release metadata.",
                zh: "更新服务返回了格式错误的版本元数据。"
            )
        case .openFiles:
            return text("Open", zh: "打开")
        case .openFolder:
            return text("Open Folder", zh: "打开文件夹")
        case .chooseWorkspaceFolder:
            return text(
                "Choose a folder to use as the workspace.",
                zh: "选择一个文件夹作为工作区。"
            )
        case .addFolderToWorkspace:
            return text("Add Folder to Workspace", zh: "将文件夹添加到工作区")
        case .chooseAnotherWorkspaceFolder:
            return text(
                "Choose another folder to add to this workspace.",
                zh: "选择另一个要添加到此工作区的文件夹。"
            )
        case .add:
            return text("Add", zh: "添加")
        case let .moveItem(name):
            return text("Move \(name)", zh: "移动 \(name)")
        case .chooseMoveDestination:
            return text(
                "Choose the destination folder. Existing items are never overwritten.",
                zh: "选择目标文件夹。现有项目不会被覆盖。"
            )
        case .move:
            return text("Move", zh: "移动")
        case let .openUsingEncoding(name):
            return text("Open Using \(name)", zh: "使用 \(name) 打开")
        case .chooseTextFilesToOpen:
            return text(
                "Choose one or more text files to open.",
                zh: "选择一个或多个要打开的文本文件。"
            )
        case let .saveDocument(name):
            return text("Save \(name)", zh: "保存 \(name)")
        case .chooseWhereToSaveDocument:
            return text(
                "Choose where to save this document.",
                zh: "选择保存此文档的位置。"
            )
        case .save:
            return text("Save", zh: "保存")
        case let .importSublime(kindName):
            return text("Import Sublime \(kindName)", zh: "导入 Sublime \(kindName)")
        case let .chooseSublimeSource(fileExtension):
            return text(
                "Choose a .\(fileExtension) file to preview. Nothing is imported until you confirm.",
                zh: "选择一个 .\(fileExtension) 文件进行预览。确认前不会导入任何内容。"
            )
        case .authorizeSublimeProjectFolder:
            return text(
                "Authorize Sublime Project Folder",
                zh: "授权 Sublime 项目文件夹"
            )
        case let .confirmSublimeProjectFolder(path):
            return text(
                "Confirm access to the folder declared by the project: \(path)",
                zh: "确认访问项目声明的文件夹：\(path)"
            )
        case .authorize:
            return text("Authorize", zh: "授权")
        case .documentMinimap:
            return text("Document minimap", zh: "文档缩略图")
        case .couldNotOpenLanguageServerLocation:
            return text(
                "Could Not Open Language Server Location",
                zh: "无法打开语言服务器位置"
            )
        case let .requestedLanguageServerLocationCouldNotOpen(path):
            return text(
                "\(path): The requested location could not be opened.",
                zh: "\(path)：无法打开请求的位置。"
            )
        case .removeFolderFromProject:
            return text("Remove Folder from Project", zh: "从项目中移除文件夹")
        case .chooseFolderToRemove:
            return text(
                "Choose the folder to remove. Open file tabs are retained.",
                zh: "选择要移除的文件夹。已打开的文件标签页会保留。"
            )
        case .remove:
            return text("Remove", zh: "移除")
        case .renameSymbol:
            return text("Rename Symbol", zh: "重命名符号")
        case .enterNewSymbolName:
            return text(
                "Enter the new symbol name. The server will produce a reviewable preview before any file changes.",
                zh: "输入新的符号名称。服务器会在修改任何文件之前生成可审阅的预览。"
            )
        case .newName:
            return text("New name", zh: "新名称")
        case .preview:
            return text("Preview", zh: "预览")
        case .applyRename:
            return text("Apply Rename?", zh: "应用重命名？")
        case let .applyRenameEditCount(editCount, fileCount):
            return text(
                "Apply \(editCount) edits across \(fileCount) files? All files are revision-checked and completed writes are rolled back if a later write fails.",
                zh: "要在 \(fileCount) 个文件中应用 \(editCount) 处编辑吗？所有文件都会进行修订校验；如果稍后写入失败，已经完成的写入会回滚。"
            )
        case .apply:
            return text("Apply", zh: "应用")
        case let .aboutApp(appName):
            return text("About \(appName)", zh: "关于\(appName)")
        case .services:
            return text("Services", zh: "服务")
        case let .hideApp(appName):
            return text("Hide \(appName)", zh: "隐藏\(appName)")
        case .hideOthers:
            return text("Hide Others", zh: "隐藏其他")
        case .showAll:
            return text("Show All", zh: "全部显示")
        case let .quitApp(appName):
            return text("Quit \(appName)", zh: "退出\(appName)")
        case .windowMenu:
            return text("Window", zh: "窗口")
        case .minimize:
            return text("Minimize", zh: "最小化")
        case .zoom:
            return text("Zoom", zh: "缩放")
        case .toggleFullScreen:
            return text("Toggle Full Screen", zh: "切换全屏")
        case .bringAllToFront:
            return text("Bring All to Front", zh: "前置全部窗口")
        case let .saveChangesToDocument(name):
            return text(
                "Save changes to \(name)?",
                zh: "要保存对 \(name) 的更改吗？"
            )
        case .reviewBeforeClosing:
            return text(
                "Review this document before Lumen Editor closes.",
                zh: "请在 Lumen Editor 关闭前检查此文档。"
            )
        case .loseUnsavedChanges:
            return text(
                "Your changes will be lost if you don’t save them.",
                zh: "如果不保存，更改将会丢失。"
            )
        case let .reopenUsingEncoding(name):
            return text(
                "Reopen Using \(name)?",
                zh: "要使用 \(name) 重新打开吗？"
            )
        case .discardUnsavedEditsAndReinterpret:
            return text(
                "This discards unsaved edits and reinterprets the original file bytes.",
                zh: "这会丢弃未保存的编辑，并重新按原始文件字节解释内容。"
            )
        case .reinterpretOriginalFileBytes:
            return text(
                "The document will be reinterpreted from its original file bytes.",
                zh: "文档将根据其原始文件字节重新解释。"
            )
        case .reloadDiskVersionPrompt:
            return text(
                "Reload the Disk Version?",
                zh: "要重新载入磁盘版本吗？"
            )
        case .discardLocalDraftForDiskVersion:
            return text(
                "This discards the local draft and replaces it with the version currently on disk.",
                zh: "这会丢弃本地草稿，并用当前磁盘上的版本替换它。"
            )
        case let .terminalExited(code):
            if code == 0 {
                return text("Terminal exited.", zh: "终端已退出。")
            }
            return text(
                "Terminal exited with code \(code).",
                zh: "终端退出，代码为 \(code)。"
            )
        case .commandPaletteUnavailable:
            return text(
                "Unavailable in the current context",
                zh: "当前上下文不可用"
            )
        case .commandPaletteUnsupported:
            return text("Not implemented", zh: "尚未实现")
        case .commandPaletteNoChange:
            return text("The command made no change", zh: "命令未产生更改")
        case .commandPaletteUnknownCommand:
            return text("Unknown command", zh: "未知命令")
        case let .findInvalidRegularExpression(diagnostic):
            return text(
                "Invalid regular expression: \(diagnostic)",
                zh: "正则表达式无效：\(diagnostic)"
            )
        case .findResultLimitMustBePositive:
            return text(
                "The find result limit must be greater than zero.",
                zh: "查找结果上限必须大于零。"
            )
        case .findTooManyMatchesToReplaceSafely:
            return text(
                "Too many matches to replace safely.",
                zh: "匹配项过多，无法安全地全部替换。"
            )
        case .findZeroWidthRegularExpressionCannotBeReplaced:
            return text(
                "Zero-width regular expression matches cannot be replaced.",
                zh: "无法替换零宽度正则表达式匹配项。"
            )
        case let .jsonUnexpectedTrailingContent(line, column):
            return jsonError(
                "Unexpected trailing content.",
                zh: "存在意外的尾随内容。",
                line: line, column: column
            )
        case let .jsonExpectedValue(line, column):
            return jsonError(
                "Expected a JSON value.", zh: "此处应为 JSON 值。",
                line: line, column: column
            )
        case let .jsonExpectedObjectKey(line, column):
            return jsonError(
                "Expected an object key.", zh: "此处应为对象键。",
                line: line, column: column
            )
        case let .jsonInvalidString(line, column):
            return jsonError(
                "Invalid JSON string.", zh: "JSON 字符串无效。",
                line: line, column: column
            )
        case let .jsonControlCharacterInString(line, column):
            return jsonError(
                "Control character in JSON string.",
                zh: "JSON 字符串中包含控制字符。",
                line: line, column: column
            )
        case let .jsonUnterminatedString(line, column):
            return jsonError(
                "Unterminated JSON string.", zh: "JSON 字符串未结束。",
                line: line, column: column
            )
        case let .jsonInvalidNumber(line, column):
            return jsonError(
                "Invalid JSON number.", zh: "JSON 数字无效。",
                line: line, column: column
            )
        case let .jsonExpectedLiteral(value, line, column):
            return jsonError(
                "Expected \(value).", zh: "此处应为 \(value)。",
                line: line, column: column
            )
        case let .jsonExpectedToken(value, line, column):
            return jsonError(
                "Expected “\(value)”.", zh: "此处应为“\(value)”。",
                line: line, column: column
            )
        case let .jsonInputExceedsLimit(maximum, line, column):
            return jsonError(
                "JSON input exceeds the \(maximum)-UTF-16-code-unit limit.",
                zh: "JSON 输入超过 \(maximum) 个 UTF-16 代码单元的限制。",
                line: line, column: column
            )
        case let .jsonNestingExceedsLimit(maximum, line, column):
            return jsonError(
                "JSON nesting exceeds the depth limit of \(maximum).",
                zh: "JSON 嵌套超过 \(maximum) 层的深度限制。",
                line: line, column: column
            )
        case let .jsonNodeCountExceedsLimit(maximum, line, column):
            return jsonError(
                "JSON node count exceeds the limit of \(maximum).",
                zh: "JSON 节点数超过 \(maximum) 个的限制。",
                line: line, column: column
            )
        case let .jsonOutputExceedsLimit(maximum):
            return text(
                "JSON output exceeds the \(maximum)-UTF-16-code-unit limit.",
                zh: "JSON 输出超过 \(maximum) 个 UTF-16 代码单元的限制。"
            )
        case .documentChangedBeforeJSONTransformApplied:
            return text(
                "The document changed before the JSON transform could be applied.",
                zh: "应用 JSON 转换前文档已发生更改。"
            )
        case let .jsonOutputUsesTooManyCodeUnits(actual, maximum):
            return text(
                "JSON output uses \(actual) UTF-16 code units; the maximum is \(maximum).",
                zh: "JSON 输出使用 \(actual) 个 UTF-16 代码单元；上限为 \(maximum) 个。"
            )
        case let .jsonDepthExceedsMaximum(actual, maximum):
            return text(
                "JSON depth \(actual) exceeds the maximum of \(maximum).",
                zh: "JSON 深度为 \(actual) 层，超过 \(maximum) 层的上限。"
            )
        case let .jsonNodeCountExceedsMaximum(actual, maximum):
            return text(
                "JSON node count \(actual) exceeds the maximum of \(maximum).",
                zh: "JSON 节点数为 \(actual) 个，超过 \(maximum) 个的上限。"
            )
        case let .jsonIndentExceedsMaximum(actual, maximum):
            return text(
                "JSON indent \(actual) exceeds the maximum of \(maximum).",
                zh: "JSON 缩进为 \(actual) 个空格，超过 \(maximum) 个的上限。"
            )
        case let .markdownExceedsPreviewLimit(maximum):
            return text(
                "Markdown exceeds the \(maximum)-UTF-16-code-unit preview limit.",
                zh: "Markdown 超过 \(maximum) 个 UTF-16 代码单元的预览限制。"
            )
        case let .markdownPreviewExceedsBlockLimit(maximum):
            return text(
                "Markdown preview exceeds the \(maximum)-block limit.",
                zh: "Markdown 预览超过 \(maximum) 个块的限制。"
            )
        case .jsonTreeChangedBeforeEditBegan:
            return text(
                "The JSON tree changed before the edit could begin.",
                zh: "开始编辑前 JSON 树已发生更改。"
            )
        case .selectedJSONNodeNoLongerExists:
            return text(
                "The selected JSON node no longer exists.",
                zh: "所选 JSON 节点已不存在。"
            )
        case .jsonTreeChangedBeforeEditApplied:
            return text(
                "The JSON tree changed before the edit could be applied.",
                zh: "应用编辑前 JSON 树已发生更改。"
            )
        case .noEditableJSONTree:
            return text(
                "No editable JSON tree is available.",
                zh: "没有可编辑的 JSON 树。"
            )
        case .jsonTreeNotAttachedToEditorRevision:
            return text(
                "The JSON tree is not attached to an editor revision.",
                zh: "JSON 树未关联到编辑器修订版本。"
            )
        case .documentChangedAfterJSONTreeRendered:
            return text(
                "The document changed after this JSON tree was rendered.",
                zh: "此 JSON 树渲染后，文档已发生更改。"
            )
        case .documentChangedBeforeJSONEditApplied:
            return text(
                "The document changed before the JSON edit could be applied.",
                zh: "应用 JSON 编辑前文档已发生更改。"
            )
        case .jsonPathDoesNotExist:
            return text("The JSON path does not exist.", zh: "JSON 路径不存在。")
        case let .jsonPathWrongContainer(expected):
            let localizedContainer = isSimplifiedChinese
                ? (expected == "array" ? "数组" : "对象")
                : expected
            return text(
                "The JSON path does not identify an \(expected).",
                zh: "JSON 路径未指向\(localizedContainer)。"
            )
        case .jsonObjectKeyEmptyOrProtected:
            return text(
                "The object key is empty or protected.",
                zh: "对象键为空或属于受保护名称。"
            )
        case .jsonObjectKeyAlreadyExists:
            return text("The object key already exists.", zh: "对象键已存在。")
        case .jsonRootCannotBeRemoved:
            return text("The JSON root cannot be removed.", zh: "无法移除 JSON 根节点。")
        case let .invalidUTF16EditRange(from, to):
            return text(
                "Invalid UTF-16 edit range \(from)..<\(to).",
                zh: "UTF-16 编辑范围 \(from)..<\(to) 无效。"
            )
        case let .overlappingUTF16Edits(firstFrom, firstTo, secondFrom, secondTo):
            return text(
                "UTF-16 edits \(firstFrom)..<\(firstTo) and \(secondFrom)..<\(secondTo) overlap.",
                zh: "UTF-16 编辑 \(firstFrom)..<\(firstTo) 与 \(secondFrom)..<\(secondTo) 重叠。"
            )
        case let .utf16EditOutsideDocument(from, to, length):
            return text(
                "UTF-16 edit \(from)..<\(to) is outside a document of length \(length).",
                zh: "UTF-16 编辑 \(from)..<\(to) 超出长度为 \(length) 的文档范围。"
            )
        case let .utf16PositionOutsideDocument(position, length):
            return text(
                "UTF-16 position \(position) is outside a document of length \(length).",
                zh: "UTF-16 位置 \(position) 超出长度为 \(length) 的文档范围。"
            )
        case let .selectionOutsideDocument(viewID, length):
            return text(
                "Selection for view \(viewID) is outside a document of UTF-16 length \(length).",
                zh: "视图 \(viewID) 的选区超出 UTF-16 长度为 \(length) 的文档范围。"
            )
        case let .unknownEditorView(viewID):
            return text(
                "Editor view \(viewID) is not registered with this buffer.",
                zh: "编辑器视图 \(viewID) 未注册到此缓冲区。"
            )
        case let .staleEditorRevision(expected, actual):
            return text(
                "Transaction expected revision \(expected), but the buffer is at revision \(actual).",
                zh: "事务预期修订版本为 \(expected)，但缓冲区当前为 \(actual)。"
            )
        case .couldNotOpenBrowserPreview:
            return text(
                "Could Not Open Browser Preview",
                zh: "无法打开浏览器预览"
            )
        case .systemBrowserRejectedHTMLPreviewURL:
            return text(
                "The system browser did not accept the HTML preview URL.",
                zh: "系统浏览器未接受 HTML 预览 URL。"
            )
        case .htmlPreviewRequiresHTMLDocument:
            return text(
                "Open in Browser is available only for HTML documents.",
                zh: "仅 HTML 文档可使用“在浏览器中打开”。"
            )
        case let .htmlSourceNotAbsoluteLocalFile(url):
            return text(
                "The HTML source is not an absolute local file: \(url)",
                zh: "HTML 源不是绝对本地文件：\(url)"
            )
        case let .htmlPreviewTemporaryDirectoryUnsafe(path):
            return text(
                "The browser-preview temporary directory is unsafe: \(path)",
                zh: "浏览器预览临时目录不安全：\(path)"
            )
        case let .htmlPreviewTooLarge(actual, maximum):
            return text(
                "The HTML preview is \(actual) bytes; the limit is \(maximum) bytes.",
                zh: "HTML 预览为 \(actual) 字节；上限为 \(maximum) 字节。"
            )
        case .htmlPreviewStoreShutDown:
            return text(
                "The browser-preview store has already shut down.",
                zh: "浏览器预览存储已关闭。"
            )
        case .htmlPreviewCouldNotAllocatePrivateDirectory:
            return text(
                "Could not allocate a private browser-preview directory.",
                zh: "无法分配私有浏览器预览目录。"
            )
        case let .htmlPreviewFileSystemFailure(operation, path, code):
            return text(
                "Browser-preview operation ‘\(operation)’ failed for \(path) (errno \(code)).",
                zh: "浏览器预览操作“\(operation)”在 \(path) 失败（errno \(code)）。"
            )
        case .browserPreviewCouldNotBeOpened:
            return text(
                "The browser preview could not be opened.",
                zh: "无法打开浏览器预览。"
            )
        }
    }

    private func jsonError(
        _ englishReason: String,
        zh chineseReason: String,
        line: Int,
        column: Int
    ) -> String {
        text(
            "\(englishReason) Line \(line), column \(column).",
            zh: "\(chineseReason) 第 \(line) 行，第 \(column) 列。"
        )
    }

    func localizedPresentedTitle(_ title: String) -> String {
        guard isSimplifiedChinese else { return title }

        switch title {
        case "Outline Unavailable": return "大纲不可用"
        case "Nothing to Fold": return "没有可折叠内容"
        case "Nothing to Unfold": return "没有可展开内容"
        case "Markdown Preview Unavailable": return "Markdown 预览不可用"
        case "Document Statistics": return "文档统计"
        case "Could Not Install Plugin": return "无法安装插件"
        case "Could Not Update Selection":
            return "无法更新所选内容"
        case "Could Not Edit Document":
            return "无法编辑文档"
        case "Could Not Open File":
            return "无法打开文件"
        case "Could Not Reopen File":
            return "无法重新打开文件"
        case "Choose a Save Location":
            return "请选择保存位置"
        case "Could Not Save File":
            return "无法保存文件"
        case "Encoding Must Be Confirmed":
            return "必须确认编码"
        case "Could Not Save Session":
            return "无法保存会话"
        case "Resolve External Change":
            return "请先解决外部更改"
        case "Save Destination Changed":
            return "保存目标已更改"
        case "Binary File":
            return "二进制文件"
        case "File Is Too Large":
            return "文件过大"
        case "Could Not Reopen Tab":
            return "无法重新打开标签页"
        case "Could Not Authorize Save Location":
            return "无法授权保存位置"
        case "File Saved, Access Not Remembered":
            return "文件已保存，但访问权限未记住"
        case "Could Not Close Tabs":
            return "无法关闭标签页"
        case "Command Unavailable":
            return "命令不可用"
        case "Unknown Command":
            return "未知命令"
        case "Could Not Open Dropped Items":
            return "无法打开拖放的项目"
        case "Could Not Load Plugin Worker":
            return "无法加载插件 Worker"
        case "Could Not Run Plugin Command":
            return "无法运行插件命令"
        case "Could Not Start Plugin Worker":
            return "无法启动插件 Worker"
        case "Could Not Run Plugin Worker":
            return "无法运行插件 Worker"
        case "Could Not Build Plugin Context":
            return "无法构建插件上下文"
        case "Plugin Worker Failed":
            return "插件 Worker 失败"
        case "Plugin Worker Exited":
            return "插件 Worker 已退出"
        case "Could Not Save Settings":
            return "无法保存设置"
        default:
            guard let command = title.removingPrefix("Could Not Run ") else {
                return title
            }
            let localizedCommand = CommandCatalog.all.first(where: {
                $0.englishName == command
            })?.name(for: .simplifiedChinese) ?? command
            return "无法运行\(localizedCommand)"
        }
    }

    func localizedPresentedMessage(_ message: String) -> String {
        guard isSimplifiedChinese else { return message }

        switch message {
        case "No document is active.": return "当前没有活动文档。"
        case "No foldable region contains the cursor.": return "光标所在位置没有可折叠区域。"
        case "No folded region contains the cursor.": return "光标所在位置没有已折叠区域。"
        case "Save the file with a Markdown extension or select Markdown syntax first.":
            return "请先以 Markdown 扩展名保存文件，或选择 Markdown 语法。"
        case "The local plugin could not be installed.":
            return "无法安装本地插件。"
        case "The document could not be saved.":
            return "无法保存文档。"
        case "The document changed while it was being reopened. No edits were discarded.":
            return "重新打开期间文档已发生变化。未丢弃任何编辑。"
        case "Git status could not be refreshed.":
            return "无法刷新 Git 状态。"
        case "No merge conflicts were detected in the current repository.":
            return "当前仓库中未检测到合并冲突。"
        case "Place the cursor on a symbol name.":
            return "请将光标置于符号名称上。"
        case "No definition found.":
            return "未找到定义。"
        case "No references found.":
            return "未找到引用。"
        case "The primary workspace is not a Git repository.":
            return "主工作区不是 Git 仓库。"
        case "Open a workspace folder to use source control.":
            return "请打开工作区文件夹以使用源代码管理。"
        case "Select at least one changed file for this Git action.":
            return "请为此 Git 操作至少选择一个已更改文件。"
        case "Git could not be launched.": return "无法启动 Git。"
        case "The Git operation was cancelled.": return "Git 操作已取消。"
        case "This command is not supported.":
            return "此命令不受支持。"
        case "This command is unavailable right now.":
            return "此命令当前不可用。"
        case "That path is already open in another tab. Close that tab or choose a different destination.":
            return "该路径已在另一个标签页中打开。请关闭该标签页，或选择其他目标位置。"
        case "Reopen with the correct encoding or save the local version to a new file.":
            return "请使用正确的编码重新打开，或将本地版本保存到新文件。"
        case "The destination must be a local file.":
            return "目标位置必须是本地文件。"
        case "Reload, keep the local version, or save it to a different file before continuing.":
            return "继续前，请重新载入、保留本地版本，或将其保存到其他文件。"
        case "Reopen with the correct encoding, or save the displayed text to a different file.":
            return "请使用正确的编码重新打开，或将当前显示的文本保存到其他文件。"
        case "The destination has multiple hard links and cannot be safely replaced.":
            return "目标存在多个硬链接，无法安全替换。"
        case "The selected destination changed before it could be replaced. Review it and try again.":
            return "所选目标在替换前已发生变化。请检查后重试。"
        case "The tab set changed while it was being reviewed. No unreviewed changes were discarded.":
            return "在审查期间标签页集合已发生变化。未审查的更改均未被丢弃。"
        case "The isolated plugin worker host is unavailable.":
            return "隔离的插件 Worker 主机不可用。"
        case "The plugin worker returned an invalid message.":
            return "插件 Worker 返回了无效消息。"
        case "The active document changed before the plugin result arrived.":
            return "插件结果返回前，活动文档已发生变化。"
        default:
            break
        }

        if let value = message.removingPrefix("Select a destination before saving "),
           let name = value.removingSuffix(".") {
            return "请先选择保存 \(name) 的目标位置。"
        }
        if let value = message.removingPrefix("No command named "),
           let command = value.removingSuffix(" is available.") {
            return "没有名为 \(command) 的可用命令。"
        }
        if let value = message.removingPrefix("This command requires additional editor context ("),
           let requirements = value.removingSuffix(").") {
            return "此命令需要额外的编辑器上下文（\(requirements)）。"
        }
        if let value = message.removingPrefix("The plugin was not granted ‘"),
           let permission = value.removingSuffix("’ permission.") {
            return "插件未被授予“\(permission)”权限。"
        }
        if let value = message.removingPrefix("Plugin worker ‘"),
           let pluginID = value.removingSuffix("’ is unavailable.") {
            return "插件 Worker “\(pluginID)”不可用。"
        }
        if let value = message.removingPrefix("Plugin command ‘"),
           let commandID = value.removingSuffix("’ is unavailable.") {
            return "插件命令“\(commandID)”不可用。"
        }
        if let value = message.removingPrefix("The plugin worker exited with status "),
           let status = value.removingSuffix(".") {
            return "插件 Worker 已退出，状态为 \(status)。"
        }
        if let value = message.removingPrefix("The plugin worker exited with status "),
           let parts = value.splitOnce(separator: ": ") {
            return "插件 Worker 已退出，状态为 \(parts.0)：\(parts.1)"
        }
        if let value = message.removingPrefix("The file was saved, but macOS access could not be persisted: ") {
            return "文件已保存，但无法持久化 macOS 访问权限：\(value)"
        }
        if let value = message.removingSuffix(" does not appear to be a text file.") {
            return "\(value) 看起来不是文本文件。"
        }
        if let value = message.removingSuffix(" exceeds the configured editable size limit.") {
            return "\(value) 超出了已配置的可编辑大小限制。"
        }
        if let components = message.splitOnce(
            separator: " exceeds the configured editable size limit of "
        ),
           let limit = String(components.1).removingSuffix(" MB. Adjust it in Settings > Files and Automation, then relaunch before opening the file again.") {
            return "\(components.0) 超出了已配置的 \(limit) MB 可编辑大小限制。请在“设置 > 文件与自动化”中调整后重新启动，再打开该文件。"
        }
        if let value = message.removingPrefix(
            "Could not open all conflicted files (opened "
        ), let count = value.removingSuffix(").") {
            return "无法打开所有冲突文件（已打开 \(count) 个）。"
        }
        if let value = message.removingPrefix("Finish saving "),
           let name = value.removingSuffix(" before discarding its Git changes.") {
            return "请等待 \(name) 保存完成，再丢弃其 Git 更改。"
        }
        if let value = message.removingPrefix("Save or close the dirty tab "),
           let name = value.removingSuffix(" before discarding its Git changes.") {
            return "请先保存或关闭有未保存更改的标签页 \(name)，再丢弃其 Git 更改。"
        }
        if let value = message.removingPrefix("Resolve the external change conflict for "),
           let name = value.removingSuffix(" before discarding its Git changes.") {
            return "请先解决 \(name) 的外部更改冲突，再丢弃其 Git 更改。"
        }
        if message == "Finish the current document operation before discarding Git changes." {
            return "请等待当前文档操作完成，再丢弃 Git 更改。"
        }
        if let value = message.removingPrefix("No indexed definition found for "),
           let name = value.removingSuffix(".") {
            return "未找到 \(name) 的索引定义。"
        }
        if message.contains(" succeeded")
            || message.contains(" rejected")
            || message.contains(" truncated")
            || message.contains(" files opened")
            || message.contains(" folders added")
            || message.contains(" drop items could not be parsed") {
            return localizedDropFeedback(message)
        }
        if message.hasPrefix("Document\nLines: ") {
            return localizedDocumentStatistics(message)
        }
        return message
    }

    func localizedGitIssue(_ content: GitPresentationIssue.Message) -> String {
        switch content {
        case let .app(issue):
            switch issue {
            case .noWorkspace:
                return text(
                    "Open a workspace folder to use source control.",
                    zh: "请打开工作区文件夹以使用源代码管理。"
                )
            case .launchFailed:
                return text("Git could not be launched.", zh: "无法启动 Git。")
            case .cancelled:
                return text("The Git operation was cancelled.", zh: "Git 操作已取消。")
            case .statusRefreshFailed:
                return text("Git status could not be refreshed.", zh: "无法刷新 Git 状态。")
            case let .openAllConflictsFailed(openedCount):
                return text(
                    "Could not open all conflicted files (opened \(openedCount)).",
                    zh: "无法打开所有冲突文件（已打开 \(openedCount) 个）。"
                )
            }
        case let .input(issue):
            guard isSimplifiedChinese else { return issue.englishMessage }
            switch issue {
            case .currentHunkToStage: return "请选择当前 Git 区块进行暂存。"
            case .changedFilesFromStatus: return "请从当前仓库状态中选择已更改文件。"
            case .changedFileToDiscard: return "请至少选择一个要丢弃更改的文件。"
            case .validHunkToDiscard: return "请选择有效的 Git 区块以丢弃更改。"
            case .changedFileForAction: return "请为此 Git 操作至少选择一个已更改文件。"
            case .commitMessageRequired: return "请输入提交信息。"
            case .branchNameRequired: return "请输入分支名称。"
            case .confirmationOutOfDate:
                return "确认前 Git 状态已发生变化。请检查此操作后重试。"
            }
        case let .discardPreflight(error):
            guard isSimplifiedChinese else { return error.message }
            switch error {
            case let .savingDocument(name):
                return "请等待 \(name) 保存完成，再丢弃其 Git 更改。"
            case let .externalConflict(name):
                return "请先解决 \(name) 的外部更改冲突，再丢弃其 Git 更改。"
            case let .dirtyDocument(name):
                return "请先保存或关闭有未保存更改的标签页 \(name)，再丢弃其 Git 更改。"
            case .workspaceBusy:
                return "请等待当前文档操作完成，再丢弃 Git 更改。"
            case let .verbatim(message):
                return message
            }
        case let .branchPreflight(error):
            guard isSimplifiedChinese else { return error.englishMessage }
            switch error {
            case let .savingDocument(name):
                return "请等待 \(name) 保存完成，再更改分支。"
            case let .dirtyDocument(name):
                return "请先保存或关闭有未保存更改的标签页 \(name)，再更改分支。"
            case let .externalConflict(name):
                return "请先解决 \(name) 的外部更改冲突，再更改分支。"
            case .workspaceBusy:
                return "请等待当前文档操作完成，再更改分支。"
            }
        case let .conflictedFile(path):
            return text(
                "Could not open conflicted file \(path).",
                zh: "无法打开冲突文件 \(path)。"
            )
        case let .operationFailure(failure):
            return failure.localizedMessage(locale: self)
        case let .verbatim(message):
            return localizedPresentedMessage(message)
        }
    }

    func localizedGitIssueTitle(_ title: GitPresentationIssue.Title) -> String {
        switch title {
        case .unavailable:
            return text("Git Unavailable", zh: "Git 不可用")
        case .actionUnavailable:
            return text("Git Action Unavailable", zh: "Git 操作不可用")
        case .operationFailed:
            return text("Git Operation Failed", zh: "Git 操作失败")
        case .openConflicts:
            return text("Could Not Open Git Conflicts", zh: "无法打开 Git 冲突")
        case .discardBlocked:
            return text("Discard Blocked", zh: "无法丢弃更改")
        case .branchChangeBlocked:
            return text("Branch Change Blocked", zh: "无法更改分支")
        }
    }

    /// Localises only application-owned workspace-search failures. Typed Core
    /// errors are handled exhaustively; unknown/system error text stays
    /// verbatim and paths carried by Core errors are never interpolated.
    func localizedWorkspaceSearchIssue(
        _ content: WorkspaceSearchPresentationIssue.Message
    ) -> String {
        switch content {
        case let .app(issue):
            switch issue {
            case .missingWorkspace:
                return text(
                    "Open a workspace folder before searching in files.",
                    zh: "请先打开工作区文件夹，再搜索文件。"
                )
            case .missingQuery:
                return text("Enter a search term first.", zh: "请先输入搜索词。")
            }
        case let .searchError(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case .emptyQuery:
                return "在文件中查找需要搜索词。"
            case .invalidRegularExpression:
                return "搜索表达式无效。"
            case let .tooManyRoots(maximum):
                return "工作区搜索最多支持 \(maximum) 个根目录。"
            case .previewFromAnotherWorkspace:
                return "此替换预览属于另一个工作区搜索会话。"
            case .previewAlreadyApplied:
                return "此替换预览已应用。"
            case .projectExclusionsChanged:
                return "项目排除设置已更改。请创建新的替换预览。"
            case .fileChanged:
                return "预览中的文件已在磁盘上发生变化。请创建新的替换预览。"
            case .fileBecameIneligible:
                return "预览中的文件已不再适合安全地自动替换。"
            case .couldNotRead:
                return "无法读取预览中的文件。"
            case .couldNotWrite:
                return "无法写入工作区替换。"
            case .rollbackFailed:
                return "工作区替换失败，并且一个或多个已完成文件无法回滚。"
            case .receiptFromAnotherWorkspace:
                return "此替换收据属于另一个工作区搜索会话。"
            case .receiptAlreadyUsed:
                return "此工作区替换收据已使用。"
            }
        case let .verbatim(message):
            return message
        }
    }

    func localizedWorkspaceSearchIssueTitle(
        _ title: WorkspaceSearchPresentationIssue.Title
    ) -> String {
        switch title {
        case .search:
            return text("Could Not Search Workspace", zh: "无法搜索工作区")
        case .previewReplacement:
            return text("Could Not Preview Replacement", zh: "无法预览替换")
        case .applyReplacement:
            return text("Could Not Apply Workspace Replacement", zh: "无法应用工作区替换")
        case .undoReplacement:
            return text("Could Not Undo Workspace Replacement", zh: "无法撤销工作区替换")
        }
    }

    func localizedWorkspaceSearchIssueAnnouncement(
        _ issue: WorkspaceSearchPresentationIssue
    ) -> String {
        "\(localizedWorkspaceSearchIssueTitle(issue.titleContent)). \(localizedWorkspaceSearchIssue(issue.content))"
    }

    func localizedLanguageToolIssueTitle(
        _ title: LanguageToolPresentationIssue.Title
    ) -> String {
        switch title {
        case .noWorkspace:
            return localizedApp(.noWorkspaceOpen)
        case .saveLanguageTool:
            return text("Could Not Save Language Tool", zh: "无法保存语言工具")
        case .selectLanguageTool:
            return text("Could Not Select Language Tool", zh: "无法选择语言工具")
        case .languageServerFormattingFailed:
            return text("Language Server Formatting Failed", zh: "语言服务器格式化失败")
        case .languageToolFailed:
            return text("Language Tool Failed", zh: "语言工具失败")
        case .formattingResultNotApplied:
            return text("Formatting Result Not Applied", zh: "未应用格式化结果")
        }
    }

    /// Localises only typed language-tool failures. Formatter stderr, LSP
    /// response details, paths, and unknown integration failures remain exact.
    func localizedLanguageToolIssue(
        _ content: LanguageToolPresentationIssue.Message
    ) -> String {
        switch content {
        case let .app(issue):
            switch issue {
            case .missingWorkspace:
                return text(
                    "Open a workspace before configuring a language tool.",
                    zh: "请先打开工作区，再配置语言工具。"
                )
            case .staleFormattingResult:
                return text(
                    "The document, pane, or workspace changed while formatting was in progress. No formatter output was applied.",
                    zh: "格式化进行期间，文档、窗格或工作区已发生变化。未应用任何格式化输出。"
                )
            }
        case let .draft(error):
            return localizedLanguageToolDraftError(error)
        case let .languageTool(error):
            return localizedLanguageToolError(error)
        case let .languageServer(error):
            return localizedLanguageServerClientError(error)
        case let .toolExecution(error):
            return localizedToolExecutionError(error)
        case let .toolProcess(error):
            return localizedToolProcessError(error)
        case let .composition(error):
            switch error {
            case let .projectSettingsSaveFailed(content):
                return content.map(localizedProjectSettingsIssue) ?? text(
                    "The language-tool project setting could not be saved.",
                    zh: "无法保存语言工具的项目设置。"
                )
            case .invalidLanguageServerEdit:
                return text(
                    "The language server returned an invalid or overlapping formatting edit.",
                    zh: "语言服务器返回了无效或重叠的格式化编辑。"
                )
            }
        case let .securityScope(error):
            return localizedSecurityScopedAccessError(error)
        case let .verbatim(message):
            return message
        }
    }

    private func localizedLanguageToolDraftError(
        _ error: LanguageToolDraftError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .invalidLanguage:
            return "请选择有效的文档语言。"
        case .invalidArguments:
            return "参数必须是最多包含 50 个字符串的 JSON 数组。"
        case .invalidEnvironment:
            return "环境变量必须是键和值均为安全字符串的 JSON 对象。"
        case .shellArgumentsNotAllowed:
            return "启用 shell 模式时，请在“命令”中填写完整命令；不允许使用单独参数。"
        case .commandTooLong:
            return "语言工具命令过长。"
        case .workingDirectoryTooLong:
            return "工作目录过长。"
        }
    }

    private func localizedLanguageToolError(_ error: LanguageToolError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .approvalRequired:
            return "运行此语言工具需要批准其准确配置。"
        case .fileOutsideWorkspace:
            return "文档位于语言工具已授权的工作区之外。"
        case let .invalidUTF8(stream):
            let localizedStream = switch stream {
            case .standardOutput: "标准输出"
            case .standardError: "标准错误"
            }
            return "语言工具在\(localizedStream)中返回了无效的 UTF-8。"
        case let .nonzeroExit(code, detail):
            return detail.isEmpty
                ? "语言工具退出，代码为 \(code)。"
                : "语言工具退出，代码为 \(code)：\(detail)"
        case .executableSelectionUnavailable:
            return "此语言工具服务使用自定义执行策略，无法添加可执行文件选择。"
        case .invalidExecutableSelection:
            return "请选择绝对路径、本地且可执行的语言工具文件。"
        case let .tooManyExecutableSelections(maximum):
            return "一个会话最多可授权 \(maximum) 个语言工具可执行文件。"
        }
    }

    private func localizedLanguageServerClientError(
        _ error: LanguageServerClientError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .approvalRequired:
            return "此语言服务器命令需要当前会话授权。"
        case .invalidRoot:
            return "语言服务器工作区根目录无效。"
        case let .fileOutsideRoot(path):
            return "语言服务器文档位于其工作区之外：\(path)"
        case .notRunning:
            return "语言服务器未运行。"
        case .operationInProgress:
            return "已有语言服务器生命周期操作正在进行。"
        case .stopped:
            return "语言服务器已停止。"
        case let .staleDocumentVersion(current, received):
            return "文档版本 \(received) 不晚于版本 \(current)。"
        case .documentVersionExhausted:
            return "语言服务器文档版本已耗尽。"
        case let .requestTimedOut(method):
            return "语言服务器请求“\(method)”超时。"
        case let .requestCancelled(method):
            return "语言服务器请求“\(method)”已取消。"
        case let .responseError(code, message):
            return "语言服务器错误 \(code)：\(message)"
        case let .invalidResponse(method):
            return "语言服务器返回了无效的 \(method) 响应。"
        case let .processTerminated(detail):
            return "语言服务器进程已终止：\(detail)"
        case let .inputQueueOverflow(maximum):
            return "语言服务器输入超过 \(maximum) 字节的队列上限。"
        }
    }

    private func localizedSecurityScopedAccessError(
        _ error: SecurityScopedAccessError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .invalidURL(value):
            return "所选项目不是绝对本地 URL：\(value)"
        case let .missingBookmark(path):
            return "必须重新授权访问 \(path)。"
        case let .resolvedURLInvalid(path):
            return "保存的访问授权解析到了预期本地路径之外：\(path)"
        case let .accessDenied(path):
            return "macOS 未授予对 \(path) 的安全作用域访问权限。"
        }
    }

    func localizedSecurityScopedAccessIssue(
        _ error: SecurityScopedAccessError, context: String?
    ) -> String {
        contextualized(localizedSecurityScopedAccessError(error), context: context)
    }

    func localizedEditorConfigIssueTitle(
        _ title: EditorConfigPresentationIssue.Title
    ) -> String {
        switch title {
        case .resolve:
            return text("Could Not Resolve EditorConfig", zh: "无法解析 EditorConfig")
        }
    }

    /// Core and workspace capability errors are app-owned and typed. POSIX,
    /// filesystem, and injected resolver failures are carried as verbatim text.
    func localizedEditorConfigIssue(
        _ content: EditorConfigPresentationIssue.Message
    ) -> String {
        switch content {
        case let .resolution(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case .invalidFileURL:
                return "EditorConfig 路径必须是绝对文件 URL。"
            case .targetOutsideWorkspace:
                return "EditorConfig 目标位于请求的工作区根目录之外。"
            case .symbolicLinkEscapesWorkspace:
                return "EditorConfig 目标解析到了请求的工作区根目录之外。"
            }
        case let .workspace(error):
            return localizedWorkspaceServiceError(error)
        case let .verbatim(message):
            return message
        }
    }

    /// Localises typed workspace-service failures at render time. Dynamic
    /// context such as a file or folder name is carried separately so runtime
    /// locale changes do not depend on parsing an English prefix. Unknown and
    /// system failures enter this formatter as `.verbatim` and remain unchanged.
    func localizedWorkspaceIssue(
        _ content: WorkspacePresentationIssue.Message
    ) -> String {
        switch content {
        case let .workspaceError(error, context):
            let message = localizedWorkspaceServiceError(error)
            guard let context else { return message }
            return text("\(context): \(message)", zh: "\(context)：\(message)")
        case let .app(english, chinese):
            return text(english, zh: chinese)
        case let .verbatim(message):
            return message
        }
    }

    func localizedWorkspaceIssueTitle(
        _ title: WorkspacePresentationIssue.Title
    ) -> String {
        switch title {
        case let .app(english, chinese): return text(english, zh: chinese)
        case let .verbatim(value): return value
        }
    }

    /// Localises only errors whose type establishes that their grammar is owned
    /// by the app. Arbitrary transport, filesystem, and plugin-supplied text is
    /// represented by `.verbatim` and is never guessed from its English text.
    func localizedPluginIssue(_ content: PluginPresentationIssue.Message) -> String {
        switch content {
        case let .app(copy):
            return localizedApp(copy)
        case let .marketplaceClient(error):
            return localizedMarketplaceClientError(error)
        case let .marketplaceFailures(reasons):
            return reasons.map(localizedMarketplaceFailure).joined(separator: "\n")
        case let .pluginStore(error):
            return localizedPluginStoreError(error)
        case let .manifestValidation(error):
            return localizedPluginManifestValidationError(error)
        case let .verbatim(message):
            return message
        }
    }

    func localizedMarketplaceFailure(_ reason: MarketplaceCatalogFailure.Reason) -> String {
        switch reason {
        case let .marketplaceClient(error):
            return localizedMarketplaceClientError(error)
        case let .manifestValidation(error):
            return localizedPluginManifestValidationError(error)
        case let .verbatim(message):
            return message
        }
    }

    func localizedPluginWorkerIssue(_ content: PluginWorkerRuntimeIssue.Message) -> String {
        switch content {
        case let .runtime(error):
            return localizedPluginWorkerRuntimeError(error)
        case let .protocolError(error):
            return localizedPluginWorkerProtocolError(error)
        case let .package(error):
            return localizedPluginWorkerPackageError(error)
        case let .pluginStore(error):
            return localizedPluginStoreError(error)
        case let .manifestValidation(error):
            return localizedPluginManifestValidationError(error)
        case let .toolExecution(error):
            return localizedToolExecutionError(error)
        case let .toolProcess(error):
            return localizedToolProcessError(error)
        case let .toolSession(error):
            return localizedPluginWorkerToolSessionError(error)
        case let .verbatim(message):
            return message
        }
    }

    func localizedSublimeImportIssueTitle(
        _ title: SublimeImportPresentationIssue.Title
    ) -> String {
        switch title {
        case .noWorkspaceOpen:
            return localizedApp(.noWorkspaceOpen)
        case .confirmationUnavailable:
            return text(
                "Import Confirmation Unavailable",
                zh: "导入确认不可用"
            )
        case let .couldNotRead(kind):
            return text(
                "Could Not Read Sublime \(kind.displayName)",
                zh: "无法读取 Sublime \(localizedSublimeImportKind(kind))"
            )
        case let .couldNotApply(kind):
            return text(
                "Could Not Apply Sublime \(kind.displayName)",
                zh: "无法应用 Sublime \(localizedSublimeImportKind(kind))"
            )
        }
    }

    func localizedRecentIssueTitle(
        _ title: RecentItemsPresentationIssue.Title
    ) -> String {
        switch title {
        case let .couldNotRemove(kind):
            return text(
                "Could Not Remove Recent \(recentItemNoun(kind))",
                zh: "无法移除最近\(recentItemNoun(kind, chinese: true))"
            )
        case let .unavailable(kind):
            return text(
                "Recent \(recentItemNoun(kind)) Unavailable",
                zh: "最近\(recentItemNoun(kind, chinese: true))不可用"
            )
        case let .opened(kind):
            return text(
                "Recent \(recentItemNoun(kind)) Opened",
                zh: "最近\(recentItemNoun(kind, chinese: true))已打开"
            )
        case let .couldNotOpen(kind):
            return text(
                "Could Not Open Recent \(recentItemNoun(kind))",
                zh: "无法打开最近\(recentItemNoun(kind, chinese: true))"
            )
        case let .couldNotRecord(kind):
            return text(
                "Could Not Record Recent \(recentItemNoun(kind))",
                zh: "无法记录最近\(recentItemNoun(kind, chinese: true))"
            )
        }
    }

    func localizedRecentIssue(
        _ content: RecentItemsPresentationIssue.Message
    ) -> String {
        switch content {
        case let .noOpenHandler(kind):
            return text(
                "No application handler is configured to open this \(recentItemNoun(kind).lowercased()).",
                zh: "未配置用于打开此\(recentItemNoun(kind, chinese: true))的应用处理程序。"
            )
        case let .wrongKind(kind):
            return text(
                "The selected item is not a recent \(recentItemNoun(kind).lowercased()).",
                zh: "所选项目不是最近\(recentItemNoun(kind, chinese: true))。"
            )
        case let .missingFromStore(kind):
            return text(
                "The selected \(recentItemNoun(kind).lowercased()) is no longer in the recent-items store.",
                zh: "所选\(recentItemNoun(kind, chinese: true))已不在最近使用记录中。"
            )
        case let .couldNotOpen(kind):
            return text(
                "The selected \(recentItemNoun(kind).lowercased()) could not be opened.",
                zh: "无法打开所选\(recentItemNoun(kind, chinese: true))。"
            )
        case let .openedButCouldNotRecord(kind, cause):
            return text(
                "The \(recentItemNoun(kind).lowercased()) opened, but its recent-item timestamp could not be updated: \(localizedRecentCause(cause))",
                zh: "\(recentItemNoun(kind, chinese: true))已打开，但无法更新其最近打开时间：\(localizedRecentCause(cause))"
            )
        case let .openFailure(kind, cause, removed, removalFailure):
            var message = cause.map(localizedRecentCause)
                ?? localizedRecentIssue(.couldNotOpen(kind))
            if removed {
                message += text(
                    " The unavailable item was removed from the recent list.",
                    zh: " 不可用项目已从最近使用列表中移除。"
                )
            } else if let removalFailure {
                message += text(
                    " It could not be removed: \(localizedRecentCause(removalFailure))",
                    zh: " 无法将其移除：\(localizedRecentCause(removalFailure))"
                )
            }
            return message
        case let .store(error):
            return localizedRecentItemsStoreError(error)
        case let .verbatim(message):
            return message
        }
    }

    private func recentItemNoun(
        _ kind: RecentItemKind, chinese: Bool = false
    ) -> String {
        if chinese { return kind == .file ? "文件" : "项目" }
        return kind == .file ? "File" : "Project"
    }

    private func localizedRecentItemsStoreError(
        _ error: RecentItemsStoreError
    ) -> String {
        switch error {
        case let .invalidAbsolutePath(path):
            return text(
                "Recent-item paths must be absolute file-system paths: \(path)",
                zh: "最近打开项路径必须是绝对文件系统路径：\(path)"
            )
        case let .invalidWindowSessionID(id):
            return text(
                "Window session IDs may contain only ASCII letters, digits, and hyphens: \(id)",
                zh: "窗口会话 ID 只能包含 ASCII 字母、数字和连字符：\(id)"
            )
        case .invalidWindowBounds:
            return text(
                "Window bounds must contain finite coordinates and positive dimensions.",
                zh: "窗口边界必须包含有限坐标和正数尺寸。"
            )
        case let .serializedDataTooLarge(actual, maximum):
            return text(
                "Recent-item data uses \(actual) bytes; the maximum is \(maximum) bytes.",
                zh: "最近打开项数据占用 \(actual) 字节；上限为 \(maximum) 字节。"
            )
        }
    }

    private func localizedRecentCause(
        _ cause: RecentItemsPresentationIssue.Cause
    ) -> String {
        switch cause {
        case let .store(error): localizedRecentItemsStoreError(error)
        case let .verbatim(message): message
        }
    }

    func localizedNavigationIssueTitle(
        _ title: NavigationPresentationIssue.Title
    ) -> String {
        switch title {
        case .locationUnavailable:
            return text("Location Unavailable", zh: "位置不可用")
        case .navigationFailed:
            return text("Navigation Failed", zh: "导航失败")
        case .couldNotListWorkspaceFiles:
            return text(
                "Could Not List Workspace Files",
                zh: "无法列出工作区文件"
            )
        case .couldNotLoadProjectSymbols:
            return text(
                "Could Not Load Project Symbols",
                zh: "无法加载项目符号"
            )
        case .noNavigationLocation:
            return text("No Navigation Location", zh: "没有导航位置")
        case .staleNavigation:
            return text("Stale Navigation", zh: "导航记录已过期")
        }
    }

    func localizedNavigationIssue(
        _ content: NavigationPresentationIssue.Message
    ) -> String {
        switch content {
        case .selectedLocationCouldNotOpen:
            return text(
                "The selected navigation location could not be opened.",
                zh: "无法打开所选导航位置。"
            )
        case .noEarlierLocation:
            return text(
                "There is no earlier navigation location.",
                zh: "没有更早的导航位置。"
            )
        case .noLaterLocation:
            return text(
                "There is no later navigation location.",
                zh: "没有更晚的导航位置。"
            )
        case .locationHasNoOpenDocumentOrURL:
            return text(
                "The navigation location no longer has an open document or file URL.",
                zh: "该导航位置不再有关联的已打开文档或文件 URL。"
            )
        case .historyLocationCouldNotBeRestored:
            return text(
                "The navigation history location could not be restored.",
                zh: "无法恢复导航历史位置。"
            )
        case .historyChangedBeforeJumpCompleted:
            return text(
                "The navigation history changed before this jump completed.",
                zh: "跳转完成前导航历史已发生变化。"
            )
        case let .workspace(error):
            return localizedWorkspaceServiceError(error)
        case let .verbatim(message):
            return message
        }
    }

    /// Localises every application-owned Sublime import failure from its typed
    /// source. Unknown parser, system, or injected errors enter as `verbatim`
    /// and are deliberately not translated by matching their English text.
    func localizedSublimeImportIssue(
        _ content: SublimeImportPresentationIssue.Message
    ) -> String {
        switch content {
        case let .controller(error):
            return localizedSublimeImportControllerError(error)
        case let .parser(error):
            return localizedSublimeImportParserError(error)
        case let .production(error):
            return localizedSublimeImportProductionError(error)
        case let .projectSettingsStore(error):
            return localizedSublimeProjectSettingsStoreError(error)
        case let .workspace(error):
            return localizedWorkspaceServiceError(error)
        case let .securityScopedAccess(error):
            return localizedSublimeSecurityScopedAccessError(error)
        case let .verbatim(message):
            return message
        }
    }

    func localizedCommandPresentation(_ presentation: CommandPresentation) -> String {
        switch presentation {
        case let .app(content):
            return localizedPresentation(content)
        case let .appModel(issue):
            return localizedAppModelIssue(issue.content)
        case let .workspace(content):
            return localizedWorkspaceIssue(content)
        case let .workspaceSearch(content):
            return localizedWorkspaceSearchIssue(content)
        case let .navigation(issue):
            return localizedNavigationIssue(issue.content)
        case let .git(issue):
            return localizedGitIssue(issue.content)
        case let .languageTool(issue):
            return localizedLanguageToolIssue(issue.content)
        case let .languageServer(issue):
            return localizedLanguageServerIssue(issue.content)
        case let .securityScope(error, context):
            return localizedSecurityScopedAccessIssue(error, context: context)
        case let .plugin(content):
            return localizedPluginIssue(content)
        case let .pluginWorker(content):
            return localizedPluginWorkerIssue(content)
        case let .sublimeImport(content):
            return localizedSublimeImportIssue(content)
        }
    }

    private func localizedSublimeImportKind(_ kind: SublimeImportKind) -> String {
        guard isSimplifiedChinese else { return kind.displayName }
        return switch kind {
        case .project: "项目"
        case .settings: "设置"
        case .keymap: "快捷键映射"
        case .snippet: "代码片段"
        case .build: "构建系统"
        }
    }

    private func localizedSublimeImportControllerError(
        _ error: SublimeImportControllerError
    ) -> String {
        switch error {
        case let .workspaceRequired(kind):
            return text(
                "Open a workspace before importing a Sublime \(kind.displayName.lowercased()).",
                zh: "请先打开工作区，再导入 Sublime \(localizedSublimeImportKind(kind))。"
            )
        case .noPendingConfirmation:
            return text(
                "There is no Sublime import awaiting confirmation.",
                zh: "没有等待确认的 Sublime 导入。"
            )
        case .invalidConfirmationToken:
            return text(
                "The Sublime import confirmation token is invalid.",
                zh: "Sublime 导入确认令牌无效。"
            )
        case .confirmationExpired:
            return text(
                "The Sublime import preview has expired. Select the file again.",
                zh: "Sublime 导入预览已过期。请重新选择文件。"
            )
        case let .mismatchedPreview(expected, actual):
            return text(
                "The parser returned a \(actual.displayName.lowercased()) preview while importing \(expected.displayName.lowercased()).",
                zh: "导入 \(localizedSublimeImportKind(expected))时，解析器返回了\(localizedSublimeImportKind(actual))预览。"
            )
        case let .applyHandlerUnavailable(kind):
            return text(
                "The application cannot apply a Sublime \(kind.displayName.lowercased()) import.",
                zh: "应用程序无法应用 Sublime \(localizedSublimeImportKind(kind))导入。"
            )
        case .applyInProgress:
            return text(
                "Another Sublime import is already being applied.",
                zh: "正在应用另一项 Sublime 导入。"
            )
        }
    }

    private func localizedSublimeImportParserError(
        _ error: SublimeImportError
    ) -> String {
        switch error {
        case let .inputTooLarge(actual, maximum):
            return text(
                "The selected Sublime file uses \(actual) bytes; the maximum is \(maximum) bytes.",
                zh: "所选 Sublime 文件占用 \(actual) 字节；上限为 \(maximum) 字节。"
            )
        case .invalidJSON:
            return text(
                "The selected Sublime file is not valid JSON.",
                zh: "所选 Sublime 文件不是有效的 JSON。"
            )
        case .expectedObject:
            return text(
                "The selected Sublime file must contain a JSON object.",
                zh: "所选 Sublime 文件必须包含 JSON 对象。"
            )
        case .missingBuildCommand:
            return text(
                "The selected .sublime-build file must declare a non-empty cmd or shell_cmd.",
                zh: "所选 .sublime-build 文件必须声明非空的 cmd 或 shell_cmd。"
            )
        case .expectedKeymapArray:
            return text(
                "The selected .sublime-keymap file must contain a JSON array.",
                zh: "所选 .sublime-keymap 文件必须包含 JSON 数组。"
            )
        case .invalidSourceURL:
            return text(
                "A Sublime import source must be an absolute local file URL.",
                zh: "Sublime 导入来源必须是绝对本地文件 URL。"
            )
        case .noProjectFolders:
            return text(
                "No folders were declared in the selected .sublime-project.",
                zh: "所选 .sublime-project 中未声明任何文件夹。"
            )
        case .missingSnippetContent:
            return text(
                "The selected Sublime snippet does not contain non-empty content.",
                zh: "所选 Sublime 代码片段不包含非空内容。"
            )
        case .snippetContentTooLarge:
            return text(
                "The Sublime snippet content exceeds 10,000 UTF-16 code units.",
                zh: "Sublime 代码片段内容超过 10,000 个 UTF-16 代码单元。"
            )
        }
    }

    private func localizedSublimeImportProductionError(
        _ error: SublimeImportProductionError
    ) -> String {
        switch error {
        case .pickerAlreadyPresented:
            return text(
                "Another Sublime import file picker is already open.",
                zh: "另一个 Sublime 导入文件选择器已打开。"
            )
        case .invalidSourceURL:
            return text(
                "A Sublime import source must be an absolute local file URL.",
                zh: "Sublime 导入来源必须是绝对本地文件 URL。"
            )
        case let .sourceOpenFailed(code):
            return text(
                "The selected Sublime file could not be opened (errno \(code)).",
                zh: "无法打开所选 Sublime 文件（errno \(code)）。"
            )
        case let .sourceInspectionFailed(code):
            return text(
                "The selected Sublime file could not be inspected (errno \(code)).",
                zh: "无法检查所选 Sublime 文件（errno \(code)）。"
            )
        case .sourceIsNotRegularFile:
            return text(
                "The selected Sublime source must be a regular file, not a folder or symbolic link.",
                zh: "所选 Sublime 来源必须是常规文件，不能是文件夹或符号链接。"
            )
        case let .sourceTooLarge(actual, maximum):
            return text(
                "The selected Sublime file uses \(actual) bytes; the maximum is \(maximum) bytes.",
                zh: "所选 Sublime 文件占用 \(actual) 字节；上限为 \(maximum) 字节。"
            )
        case let .sourceReadFailed(code):
            return text(
                "The selected Sublime file could not be read (errno \(code)).",
                zh: "无法读取所选 Sublime 文件（errno \(code)）。"
            )
        case .sourceChangedDuringRead:
            return text(
                "The selected Sublime file changed while it was being read. Select it again.",
                zh: "所选 Sublime 文件在读取期间发生了变化。请重新选择。"
            )
        case let .workspaceRequired(kind):
            return text(
                "Open a workspace before importing a Sublime \(kind.displayName.lowercased()).",
                zh: "请先打开工作区，再导入 Sublime \(localizedSublimeImportKind(kind))。"
            )
        case .projectSettingsHavePendingChanges:
            return text(
                "Save or discard the open project-settings draft before importing Sublime data.",
                zh: "导入 Sublime 数据前，请保存或丢弃已打开的项目设置草稿。"
            )
        case let .projectRootSelectionCancelled(url):
            return text(
                "Authorization was cancelled for project folder: \(url.path)",
                zh: "已取消对项目文件夹的授权：\(url.path)"
            )
        case let .projectRootSelectionMismatch(expected, selected):
            return text(
                "The selected folder (\(selected.path)) does not match the project folder awaiting authorization (\(expected.path)).",
                zh: "所选文件夹（\(selected.path)）与等待授权的项目文件夹（\(expected.path)）不匹配。"
            )
        case let .projectRootAuthorizationFailed(url):
            return text(
                "The project folder could not be authorised: \(url.path)",
                zh: "无法授权项目文件夹：\(url.path)"
            )
        case let .projectRollbackFailed(original, rollback):
            return text(
                "The import failed (\(original)), and its workspace authorization could not be fully rolled back (\(rollback)).",
                zh: "导入失败（\(original)），且无法完整回滚其工作区授权（\(rollback)）。"
            )
        case .settingsPersistenceFailed:
            return text(
                "The imported settings could not be persisted; the previous settings were restored.",
                zh: "无法持久化导入的设置；已恢复先前的设置。"
            )
        }
    }

    private func localizedSublimeProjectSettingsStoreError(
        _ error: ProjectSettingsStoreError
    ) -> String {
        switch error {
        case let .invalidWorkspace(url):
            return text(
                "The project workspace is not a safe local directory: \(url.path)",
                zh: "项目工作区不是安全的本地目录：\(url.path)"
            )
        case let .workspaceChanged(url):
            return text(
                "The project workspace path no longer identifies the authorised directory: \(url.path)",
                zh: "项目工作区路径已不再指向获授权的目录：\(url.path)"
            )
        case .symbolicLinkEncountered:
            return text(
                ".lumen-project.json must not be a symbolic link.",
                zh: ".lumen-project.json 不能是符号链接。"
            )
        case .notARegularFile:
            return text(
                ".lumen-project.json must be a regular file.",
                zh: ".lumen-project.json 必须是常规文件。"
            )
        case .hardLinkedFile:
            return text(
                ".lumen-project.json must not have multiple hard links.",
                zh: ".lumen-project.json 不能有多个硬链接。"
            )
        case let .fileTooLarge(actual, maximum):
            return text(
                "Project settings use \(actual) bytes; the maximum is \(maximum) bytes.",
                zh: "项目设置占用 \(actual) 字节；上限为 \(maximum) 字节。"
            )
        case .changedDuringRead:
            return text(
                "Project settings changed while they were being read.",
                zh: "项目设置在读取期间发生了变化。"
            )
        case let .invalidContents(reason, _):
            switch reason {
            case let .inputTooLarge(actual, maximum):
                return text(
                    "Project settings use \(actual) bytes; the maximum is \(maximum) bytes.",
                    zh: "项目设置占用 \(actual) 字节；上限为 \(maximum) 字节。"
                )
            case .invalidJSON:
                return text(
                    "The project settings file is not valid JSON.",
                    zh: "项目设置文件不是有效的 JSON。"
                )
            case .expectedObject:
                return text(
                    "Project settings must contain a JSON object.",
                    zh: "项目设置必须包含 JSON 对象。"
                )
            }
        case .conflict:
            return text(
                "Project settings changed on disk after they were loaded.",
                zh: "项目设置载入后已在磁盘上发生变化。"
            )
        case .invalidExpectedRevision:
            return text(
                "The expected project-settings revision is invalid.",
                zh: "预期的项目设置修订版本无效。"
            )
        case let .fileSystem(operation, code):
            return text(
                "Project settings file operation ‘\(operation)’ failed (errno \(code)).",
                zh: "项目设置文件操作“\(operation)”失败（errno \(code)）。"
            )
        }
    }

    private func localizedSublimeSecurityScopedAccessError(
        _ error: SecurityScopedAccessError
    ) -> String {
        switch error {
        case let .invalidURL(value):
            return text(
                "The selected item is not an absolute local URL: \(value)",
                zh: "所选项目不是绝对本地 URL：\(value)"
            )
        case let .missingBookmark(path):
            return text(
                "Access to \(path) must be authorised again.",
                zh: "必须重新授权访问 \(path)。"
            )
        case let .resolvedURLInvalid(path):
            return text(
                "The saved access grant resolved outside its expected local path: \(path)",
                zh: "保存的访问授权解析到了预期本地路径之外：\(path)"
            )
        case let .accessDenied(path):
            return text(
                "macOS did not grant security-scoped access to \(path).",
                zh: "macOS 未授予对 \(path) 的安全范围访问权限。"
            )
        }
    }

    private func localizedPluginWorkerRuntimeError(
        _ error: PluginWorkerRuntimeError
    ) -> String {
        switch error {
        case .hostUnavailable:
            return text(
                "The isolated plugin worker host is unavailable.",
                zh: "隔离的插件 Worker 主机不可用。"
            )
        case let .pluginUnavailable(id):
            return text(
                "Plugin worker ‘\(id)’ is unavailable.",
                zh: "插件 Worker“\(id)”不可用。"
            )
        case let .commandUnavailable(id):
            return text(
                "Plugin command ‘\(id)’ is unavailable.",
                zh: "插件命令“\(id)”不可用。"
            )
        case .invalidHostMessage:
            return text(
                "The plugin worker returned an invalid message.",
                zh: "插件 Worker 返回了无效消息。"
            )
        case .requestMismatch:
            return text(
                "The active document changed before the plugin result arrived.",
                zh: "插件结果返回前，活动文档已发生变化。"
            )
        case let .permissionDenied(permission):
            return text(
                "The plugin was not granted ‘\(permission.rawValue)’ permission.",
                zh: "插件未被授予“\(permission.rawValue)”权限。"
            )
        case let .workerExited(code, standardError):
            guard !standardError.isEmpty else {
                return text(
                    "The plugin worker exited with status \(code).",
                    zh: "插件 Worker 已退出，状态为 \(code)。"
                )
            }
            let prefix = text(
                "The plugin worker exited with status \(code): ",
                zh: "插件 Worker 已退出，状态为 \(code)："
            )
            return prefix + standardError
        }
    }

    private func localizedPluginWorkerProtocolError(
        _ error: PluginWorkerProtocolError
    ) -> String {
        switch error {
        case let .messageTooLarge(maximum):
            return text(
                "Plugin IPC messages may use at most \(maximum) bytes.",
                zh: "插件 IPC 消息最多可使用 \(maximum) 个字节。"
            )
        case let .sourceTooLarge(maximum):
            return text(
                "Plugin worker source may use at most \(maximum) bytes.",
                zh: "插件 Worker 源代码最多可使用 \(maximum) 个字节。"
            )
        case let .documentTooLarge(maximum):
            return text(
                "Plugin document context may use at most \(maximum) UTF-8 bytes.",
                zh: "插件文档上下文最多可使用 \(maximum) 个 UTF-8 字节。"
            )
        case let .replacementTooLarge(maximum):
            return text(
                "Plugin document replacements may use at most \(maximum) UTF-8 bytes.",
                zh: "插件文档替换内容最多可使用 \(maximum) 个 UTF-8 字节。"
            )
        case let .responseTooLarge(maximum):
            return text(
                "A plugin request may return at most \(maximum) encoded bytes.",
                zh: "插件请求最多可返回 \(maximum) 个编码后字节。"
            )
        case .invalidMessage:
            return text(
                "The plugin worker sent an invalid JSON message.",
                zh: "插件 Worker 发送了无效的 JSON 消息。"
            )
        case let .unsupportedVersion(version):
            return text(
                "Plugin worker protocol version \(version) is unsupported.",
                zh: "不支持插件 Worker 协议版本 \(version)。"
            )
        case .invalidRequest:
            return text(
                "The plugin worker request is incomplete or inconsistent.",
                zh: "插件 Worker 请求不完整或不一致。"
            )
        case let .workerFailure(message):
            return message
        case let .tooManyMessages(maximum):
            return text(
                "A plugin request may emit at most \(maximum) messages.",
                zh: "插件请求最多可发送 \(maximum) 条消息。"
            )
        }
    }

    private func localizedPluginWorkerPackageError(
        _ error: PluginWorkerPackageError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .workerUnavailable: return "此插件未声明可执行 Worker。"
        case .manifestChanged: return "已安装的插件清单在加载后发生了变化。"
        case .invalidWorkerEncoding: return "插件 Worker 必须包含有效的 UTF-8 JavaScript。"
        }
    }

    private func localizedToolExecutionError(
        _ error: ToolExecutionError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .invalidExecutableAlias:
            return "可执行文件允许列表别名必须是简单命令名称。"
        case .invalidExecutableURL:
            return "允许列表中的可执行文件必须是绝对本地文件 URL。"
        case .executableNotAllowed:
            return "配置的可执行文件不在受信任的允许列表中。"
        case .relativeExecutablePathNotAllowed:
            return "包含斜杠的可执行文件路径必须是绝对路径并明确加入允许列表。"
        case .shellExecutableNotAllowed:
            return "固定 shell 可执行文件也必须在可执行文件允许列表中。"
        case .shellExecutableUnavailable:
            return "此执行策略未配置固定 shell 可执行文件。"
        case let .shellNotAllowed(kind):
            return "工具用途“\(kind.rawValue)”不能通过 shell 执行。"
        case .shellArgumentsNotAllowed:
            return "shell 命令不能接收项目参数；请将受信任语法放入已批准命令，或直接执行 argv。"
        case .invalidAuthorizedRoot:
            return "已授权的工具根目录必须是绝对本地文件 URL。"
        case .invalidWorkingDirectory:
            return "工具工作目录必须是绝对本地文件 URL。"
        case .workingDirectoryOutsideAuthorizedRoot:
            return "工具工作目录必须位于其已授权的工作区根目录内。"
        case let .workingDirectoryPathTooLong(maximum):
            return "工具工作目录设置最多可使用 \(maximum) 个 UTF-16 代码单元。"
        case .emptyExecutable:
            return "请配置非空的工具可执行文件。"
        case .executableContainsNull:
            return "工具可执行文件不能包含空字节。"
        case let .executableTooLong(maximum):
            return "工具可执行文件最多可使用 \(maximum) 个 UTF-16 代码单元。"
        case let .tooManyArguments(maximum):
            return "工具最多可有 \(maximum) 个参数。"
        case let .argumentContainsNull(index):
            return "工具参数 \(index) 不能包含空字节。"
        case let .argumentTooLong(index, maximum):
            return "工具参数 \(index) 最多可使用 \(maximum) 个 UTF-16 代码单元。"
        case let .tooManyEnvironmentVariables(maximum):
            return "工具最多可添加 \(maximum) 个环境变量。"
        case let .invalidEnvironmentKey(key):
            return "工具环境变量键“\(key)”无效。"
        case let .unsafeEnvironmentKey(key):
            return "工具环境变量键“\(key)”可能向子进程注入代码，因此不允许使用。"
        case let .environmentValueContainsNull(key):
            return "工具环境变量键“\(key)”的值不能包含空字节。"
        case let .environmentValueTooLong(key, maximum):
            return "工具环境变量键“\(key)”的值最多可使用 \(maximum) 个 UTF-16 代码单元。"
        case .invalidProcessLimits:
            return "工具进程限制必须为有限且大于零的值。"
        case let .standardInputTooLarge(actual, maximum):
            return "工具标准输入使用 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case let .timedOut(seconds): return "工具未能在 \(seconds) 秒内完成。"
        case let .outputLimitExceeded(stream, maximum):
            return "工具 \(stream.rawValue) 超过 \(maximum) 字节上限。"
        case .cancelled: return "工具操作已取消。"
        }
    }

    private func localizedToolProcessError(
        _ error: ToolProcessRunnerError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .invalidCommand: return "工具进程命令或其限制无效。"
        case let .launchFailed(detail): return "无法启动工具进程：\(detail)"
        case let .processQueueOverflow(maximum):
            return "工具进程队列中已有 \(maximum) 个待处理命令。"
        case let .outputDeliveryQueueOverflow(maximumBytes, maximumChunks):
            return "工具输出传递超过 \(maximumBytes) 个待处理字节或 \(maximumChunks) 个待处理分块。"
        case .standardInputWriteFailed: return "无法完整写入一次性工具标准输入。"
        }
    }

    private func localizedPluginWorkerToolSessionError(
        _ error: ToolProcessSessionError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .writeTooLarge(actual, maximum):
            return "工具标准输入写入使用 \(actual) 个字节；每次最多可使用 \(maximum) 个字节。"
        case let .queueOverflow(maximum): return "工具标准输入队列超过 \(maximum) 字节上限。"
        case .interruptFailed: return "无法向工具进程会话发送 SIGINT。"
        case .resizeFailed: return "无法调整伪终端会话的窗口大小。"
        case .closed: return "工具进程标准输入已关闭。"
        }
    }

    private func localizedMarketplaceClientError(_ error: MarketplaceClientError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .unexpectedResponse:
            return "插件市场返回了非 HTTP 响应。"
        case .authenticationRejected:
            return "插件市场不支持身份验证；未提供凭据。"
        case let .transport(code):
            return "插件市场请求失败（URL 错误 \(code.rawValue)）。"
        case let .manifestIdentityMismatch(expected, actual):
            return "下载的清单 ID“\(actual)”与插件市场目录 ID“\(expected)”不匹配。"
        case .marketplaceWorkerUnavailable:
            return "插件市场 Worker 声明需要同源 HTTPS URL 和 SHA-256 完整性信息。"
        }
    }

    private func localizedPluginStoreError(_ error: PluginStoreError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .invalidWorkspace(url):
            return "插件工作区不是实际的本地目录：\(url.path)"
        case let .invalidSource(url):
            return "插件来源不是实际的本地目录：\(url.path)"
        case let .sourceOverlapsPluginStorage(url):
            return "插件来源与工作区插件存储位置重叠：\(url.path)"
        case let .unsafePluginStorage(url):
            return "工作区插件存储位置不是安全目录：\(url.path)"
        case .missingManifest:
            return "所选目录不包含常规的 plugin.json 文件。"
        case let .pluginAlreadyInstalled(id):
            return "插件“\(id)”已安装。"
        case let .pluginNotInstalled(id):
            return "插件“\(id)”未安装。"
        case let .manifestIDDoesNotMatchDirectory(expected, actual):
            return "插件目录“\(expected)”包含清单 ID“\(actual)”。"
        case let .symbolicLinkEncountered(path):
            return "插件包不能包含符号链接：\(path)"
        case let .unsupportedFileType(path):
            return "插件包只能包含目录和常规文件：\(path)"
        case .copyLimitExceeded:
            return "插件包超过原生应用的安装大小限制。"
        case .sourceChangedDuringInstallation:
            return "插件清单在安装过程中发生了变化。"
        case let .workerFileMissing(path):
            return "声明的 Worker 缺失或不安全：\(path)"
        case .invalidMarketplacePackage:
            return "已验证的插件市场包不一致。"
        case let .unsupportedStateVersion(version):
            return "不支持插件项目状态版本 \(version)。"
        case .stateTooLarge:
            return "插件项目状态超过支持的大小限制。"
        case let .fileSystem(operation, path, code):
            return "插件文件操作“\(operation)”在 \(path) 失败（errno \(code)）。"
        }
    }

    private func localizedPluginManifestValidationError(
        _ error: PluginManifestValidationError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .invalidJSON:
            return "插件数据不是有效的 JSON。"
        case .invalidManifest:
            return "插件清单无效。"
        case let .manifestByteCountOutOfRange(count):
            return "插件清单字节数超出允许范围：\(count)。"
        case let .invalidHTTPSURL(value):
            return "插件市场 URL 必须是绝对 HTTPS URL：\(value)"
        case let .invalidWorkerPath(value):
            return "扩展 Worker 路径无效：\(value)"
        case .incompleteMarketplaceWorkerMetadata:
            return "插件市场 Worker 必须同时提供 HTTPS URL 和 SHA-256 完整性值。"
        case .marketplaceWorkerOriginMismatch:
            return "插件市场 Worker 必须与其清单具有相同的 HTTPS 来源。"
        case .redirectedResource:
            return "插件市场不允许重定向。"
        case let .unsuccessfulHTTPStatus(status):
            return "插件市场资源返回了 HTTP 状态 \(status)。"
        case .missingWorkerData:
            return "插件市场 Worker 响应没有正文。"
        case let .workerByteCountOutOfRange(count):
            return "扩展 Worker 字节数超出允许范围：\(count)。"
        case .workerIntegrityMismatch:
            return "插件市场 Worker 未通过 SHA-256 完整性检查。"
        }
    }

    private func localizedWorkspaceServiceError(_ error: WorkspaceServiceError) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case .invalidFileURL:
            return "工作区路径必须是绝对文件 URL。"
        case .rootIsNotDirectory:
            return "工作区根目录必须是现有目录。"
        case .rootAlreadyRegistered:
            return "此工作区根目录已注册。"
        case .rootNotRegistered:
            return "此工作区根目录已不再注册。"
        case .rootChanged:
            return "已授权的工作区根目录已在磁盘上被替换。"
        case .rootReplacementInProgress:
            return "另一个工作区根目录替换仍在完成中。"
        case .rootReplacementRollbackFailed:
            return "无法安全回滚工作区根目录替换。"
        case let .tooManyRoots(maximum):
            return "一个工作区最多支持 \(maximum) 个根目录。"
        case let .tooManyRetainedFiles(maximum):
            return "移除根目录时，最多可为 \(maximum) 个打开的文件保留访问权限。"
        case let .tooManyDirectFileAuthorizations(maximum):
            return "最多可为 \(maximum) 个文件授予直接访问权限。"
        case .unauthorized:
            return "此路径尚未获得工作区授权。"
        case .symbolicLinkEscapesWorkspace:
            return "符号链接解析到所有已授权工作区根目录之外。"
        case .notADirectory:
            return "请求的路径不是目录。"
        case .notAFile:
            return "请求的路径不是常规文件。"
        case .itemNotFound:
            return "请求的工作区项目已不存在。"
        case .cannotEnumerateDirectory:
            return "无法列出此目录。"
        case .invalidName:
            return "请使用不含路径分隔符的简单文件或文件夹名称。"
        case .itemAlreadyExists:
            return "已存在同名项目。"
        case .cannotMutateWorkspaceRoot:
            return "无法重命名、移动已注册的工作区根目录或将其移到废纸篓。"
        case .moveIntoDescendant:
            return "无法将目录移动到其子目录中。"
        case .crossVolumeMoveUnsupported:
            return "无法在不复制的情况下跨存储卷移动此项目。原项目未发生更改。"
        case .externalSpecialItemMoveUnsupported:
            return "只有常规文件和目录可以移出工作区。"
        case .directDirectoryTrashUnsupported:
            return "无法安全地将已移出工作区的项目移到废纸篓。"
        case let .moveRollbackFailed(_, _, _, outcome):
            switch outcome {
            case .committedAtTarget:
                return "项目已移动，但验证失败后的恢复操作也失败。"
            case .indeterminate:
                return "项目移动验证和恢复均失败，磁盘位置目前无法确定。"
            }
        }
    }

    private func localizedDocumentStatistics(_ message: String) -> String {
        message
            .replacingOccurrences(of: "Document\n", with: "文档\n")
            .replacingOccurrences(of: "\n\nSelection\n", with: "\n\n选区\n")
            .replacingOccurrences(of: "Lines: ", with: "行数：")
            .replacingOccurrences(of: "Characters: ", with: "字符数：")
            .replacingOccurrences(
                of: "Characters (excluding whitespace): ",
                with: "字符数（不含空白）："
            )
            .replacingOccurrences(of: "Words / tokens: ", with: "单词 / 标记：")
    }

    /// Renders the typed SettingsController persistence payload. Unknown
    /// filesystem and system failures remain verbatim while the app-owned
    /// recovery explanation can still follow the active runtime locale.
    func localizedSettingsPersistenceIssue(
        _ content: SettingsPersistenceIssue.Message
    ) -> String {
        switch content {
        case .applicationTerminationCommitted:
            return text(
                "Settings are locked while the application is terminating.",
                zh: "应用正在退出，设置已锁定。"
            )
        case let .saveFailed(cause):
            return localizedSettingsPersistenceCause(cause)
        case let .sessionOnly(cause, destinationPath):
            return text(
                "\(localizedSettingsPersistenceCause(cause)) Your changes remain active for this session but were not written to \(destinationPath).",
                zh: "\(localizedSettingsPersistenceCause(cause)) 你的更改在当前会话中仍然生效，但未写入 \(destinationPath)。"
            )
        }
    }

    /// Renders a typed encoding notice at display time so the locale can change
    /// between notice creation and banner presentation.
    func localizedEncodingNotice(_ notice: EncodingNotice) -> String {
        switch notice {
        case let .invalidBytesAfterOpen(_, encoding):
            return text(
                "The file cannot be decoded losslessly as \(encoding.displayName). Reopen with the correct encoding before overwriting it.",
                zh: "文件无法按 \(encoding.displayName) 无损解码；请以正确编码重新打开，覆盖保存已禁用。"
            )
        case let .uncertainEncodingAfterOpen(_, encoding):
            return text(
                "Detected \(encoding.displayName) heuristically; reopen with another encoding if the text looks wrong.",
                zh: "已推测为 \(encoding.displayName)；如显示异常，请以其他编码重新打开。"
            )
        case let .reopenSuccess(_, requestedEncoding, actualEncoding, displayName):
            let requestedLabel = requestedEncoding?.displayName
                ?? text("Auto Detect", zh: "自动检测")
            return text(
                "Reopened “\(displayName)” using \(requestedLabel) (\(actualEncoding.displayName)).",
                zh: "已使用\(requestedLabel)重新打开“\(displayName)”（\(actualEncoding.displayName)）。"
            )
        case let .invalidBytesAfterReopen(_, requestedEncoding):
            let requestedLabel = requestedEncoding?.displayName
                ?? text("Auto Detect", zh: "自动检测")
            return text(
                "Reopened using \(requestedLabel), but some bytes cannot round-trip; saving is disabled.",
                zh: "已使用\(requestedLabel)打开，但检测到不能无损往返的字节；保存已禁用。"
            )
        case let .invalidBytesAfterExternalReload(_, encoding):
            return text(
                "The disk file cannot be decoded losslessly as \(encoding.displayName). Reopen with the correct encoding before saving.",
                zh: "磁盘文件无法按 \(encoding.displayName) 无损解码；请以正确编码重新打开，覆盖保存已禁用。"
            )
        }
    }

    func localizedFileSaveNotice(_ notice: FileSaveNotice) -> String {
        switch notice {
        case let .durabilityUnconfirmed(_, displayName, artifact):
            let base = text(
                "\(displayName) contains the requested bytes, but macOS could not confirm the directory update on disk. Keep the document open and retry saving.",
                zh: "\(displayName) 已包含请求保存的内容，但 macOS 无法确认目录更新已持久化到磁盘。请保持文档打开并重试保存。"
            )
            guard let artifact else { return base }
            return base + text(
                " A complete recovery copy remains at \(artifact.path).",
                zh: " 完整恢复副本保留在 \(artifact.path)。"
            )
        case let .cleanupIncomplete(_, displayName, artifact):
            let base = text(
                "\(displayName) was saved, but a temporary recovery item could not be completely removed.",
                zh: "\(displayName) 已保存，但临时恢复项未能完全清理。"
            )
            guard let artifact else { return base }
            return base + text(
                " A complete recovery copy remains at \(artifact.path).",
                zh: " 完整恢复副本保留在 \(artifact.path)。"
            )
        }
    }

    /// Localises the app-owned labels in execution approval summaries while
    /// preserving commands, paths, environment entries, and identity digests.
    func localizedApprovalDescription(_ description: String) -> String {
        guard isSimplifiedChinese else { return description }
        return description.components(separatedBy: "\n").map { line in
            if line == "Environment: none" { return "环境变量：无" }
            let prefixes: [(String, String)] = [
                ("Language: ", "语言："),
                ("Plugin: ", "插件："),
                ("Purpose: ", "用途："),
                ("Workspace: ", "工作区："),
                ("Command: ", "命令："),
                ("Resolved executable: ", "解析后的可执行文件："),
                ("Working directory: ", "工作目录："),
                ("Host: ", "宿主程序："),
                ("Worker digest: ", "Worker 摘要："),
                ("Identity: ", "标识："),
                ("Environment:", "环境变量：")
            ]
            for (english, chinese) in prefixes where line.hasPrefix(english) {
                return chinese + line.dropFirst(english.count)
            }
            for (english, chinese) in [
                ("Uses shell command parsing: ", "使用 shell 命令解析："),
                ("Uses shell: ", "使用 shell：")
            ] where line.hasPrefix(english) {
                let rawValue = String(line.dropFirst(english.count))
                let value = switch rawValue {
                case "yes": "是"
                case "no": "否"
                default: rawValue
                }
                return chinese + value
            }
            return line
        }.joined(separator: "\n")
    }

    func localizedProjectSettingsIssueTitle(
        _ title: ProjectSettingsPresentationIssue.Title
    ) -> String {
        switch title {
        case .load:
            return text("Could Not Load Project Settings", zh: "无法载入项目设置")
        case .reload:
            return text("Could Not Reload Project Settings", zh: "无法重新载入项目设置")
        case .save:
            return text("Could Not Save Project Settings", zh: "无法保存项目设置")
        case .saveLanguageTool:
            return text("Could Not Save Language Tool", zh: "无法保存语言工具")
        case .authorizeLanguageServerExecutable:
            return text(
                "Could Not Authorize Language Server Executable",
                zh: "无法授权语言服务器可执行文件"
            )
        case .saveBuildCommand:
            return text("Could Not Save Build Command", zh: "无法保存构建命令")
        case .rollbackBuildCommand:
            return text("Could Not Roll Back Build Command", zh: "无法回滚构建命令")
        case .noWorkspace:
            return text("No Workspace Open", zh: "未打开工作区")
        }
    }

    /// Localises only typed application-owned project-settings failures.
    /// Unknown system, picker and integration failures stay byte-for-byte
    /// verbatim even when their copy collides with an English app message.
    func localizedProjectSettingsIssue(
        _ content: ProjectSettingsPresentationIssue.Message
    ) -> String {
        switch content {
        case let .app(issue):
            switch issue {
            case .storeWorkspaceMismatch:
                return text(
                    "The project settings store does not belong to the authorised workspace.",
                    zh: "项目设置存储不属于已授权的工作区。"
                )
            case .noWorkspace:
                return text(
                    "Open a workspace before configuring project settings.",
                    zh: "请先打开工作区，再配置项目设置。"
                )
            }
        case let .draft(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case let .invalidJSONObject(section):
                return "\(localizedProjectSettingsSection(section))必须是有效的 JSON 对象。"
            case let .invalidJSONArray(section):
                return "\(localizedProjectSettingsSection(section))必须是有效的 JSON 数组。"
            case let .draftTooLarge(maximum):
                return "项目设置最多可使用 \(maximum) 个 UTF-8 字节。"
            }
        case let .buildCommand(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case let .workspaceUnavailable(workspace):
                return "\(workspace.path) 的项目设置尚未就绪。"
            case let .workspaceMismatch(expected, actual):
                return "项目设置属于 \(actual.path)，而不是已批准的构建工作区 \(expected.path)。"
            case .rollbackStateChanged:
                return "构建命令回滚完成前，项目设置已发生变化。"
            }
        case let .store(error):
            return localizedProjectSettingsStoreError(error)
        case let .parse(error):
            return localizedProjectSettingsParseError(error)
        case let .languageServerAuthorization(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case .unavailable:
                return "此语言服务器管理器使用自定义执行策略，无法添加可执行文件选择。"
            case .invalidSelection:
                return "请选择现有的语言服务器可执行文件。"
            case let .tooManySelections(maximum):
                return "一个会话最多可授权 \(maximum) 个语言服务器可执行文件。"
            }
        case let .securityScope(error):
            return localizedSecurityScopedAccessError(error)
        case let .verbatim(message):
            return message
        }
    }

    private func localizedProjectSettingsStoreError(
        _ error: ProjectSettingsStoreError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .invalidWorkspace(url):
            return "项目工作区不是安全的本地目录：\(url.path)"
        case let .workspaceChanged(url):
            return "项目工作区路径已不再指向已授权的目录：\(url.path)"
        case .symbolicLinkEncountered:
            return ".lumen-project.json 不能是符号链接。"
        case .notARegularFile:
            return ".lumen-project.json 必须是普通文件。"
        case .hardLinkedFile:
            return ".lumen-project.json 不能有多个硬链接。"
        case let .fileTooLarge(actual, maximum):
            return "项目设置使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case .changedDuringRead:
            return "读取项目设置时其内容发生了变化。"
        case let .invalidContents(reason, _):
            return localizedProjectSettingsParseError(reason)
        case .conflict:
            return "项目设置在载入后已在磁盘上发生变化。"
        case .invalidExpectedRevision:
            return "预期的项目设置修订版本无效。"
        case let .fileSystem(operation, code):
            return "项目设置文件操作“\(operation)”失败（errno \(code)）。"
        }
    }

    private func localizedProjectSettingsParseError(
        _ error: ProjectSettingsParseError
    ) -> String {
        guard isSimplifiedChinese else { return error.localizedDescription }
        switch error {
        case let .inputTooLarge(actual, maximum):
            return "项目设置使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case .invalidJSON:
            return "项目设置文件不是有效的 JSON。"
        case .expectedObject:
            return "项目设置必须包含 JSON 对象。"
        }
    }

    private func localizedProjectSettingsSection(_ section: String) -> String {
        switch section {
        case "Key bindings": "快捷键绑定"
        case "Plugin permissions": "插件权限"
        case "Language tools": "语言工具"
        case "Language servers": "语言服务器"
        case "Build systems": "构建系统"
        case "Key binding rules": "快捷键规则"
        case "Snippets": "代码片段"
        default: section
        }
    }

    private func localizedSettingsPersistenceCause(
        _ cause: SettingsPersistenceIssue.Cause
    ) -> String {
        switch cause {
        case let .store(error):
            guard isSimplifiedChinese else { return error.localizedDescription }
            switch error {
            case let .unsupportedFormatVersion(version):
                return "不支持设置格式版本 \(version)。"
            case .snapshotTooLarge:
                return "设置文件超出支持的大小限制。"
            }
        case let .verbatim(message):
            return message
        }
    }

    @MainActor
    func localizeMainMenu(
        _ mainMenu: NSMenu? = NSApp.mainMenu,
        servicesMenu: NSMenu? = NSApp.servicesMenu,
        windowsMenu: NSMenu? = NSApp.windowsMenu
    ) {
        let appName = localizedApp(.systemAppName)

        for item in mainMenu?.items ?? [] {
            if item.submenu === windowsMenu {
                item.title = localizedApp(.windowMenu)
            }
            if item.submenu === servicesMenu {
                item.title = localizedApp(.services)
            }
            localize(menu: item.submenu, appName: appName, servicesMenu: servicesMenu)
        }
    }

    @MainActor
    private func localize(
        menu: NSMenu?,
        appName: String,
        servicesMenu: NSMenu?
    ) {
        for item in menu?.items ?? [] {
            if item.submenu === servicesMenu {
                item.title = localizedApp(.services)
            }
            switch item.action {
            case #selector(NSApplication.orderFrontStandardAboutPanel(_:)):
                item.title = localizedApp(.aboutApp(appName: appName))
            case #selector(NSApplication.hide(_:)):
                item.title = localizedApp(.hideApp(appName: appName))
            case #selector(NSApplication.hideOtherApplications(_:)):
                item.title = localizedApp(.hideOthers)
            case #selector(NSApplication.unhideAllApplications(_:)):
                item.title = localizedApp(.showAll)
            case #selector(NSApplication.terminate(_:)):
                item.title = localizedApp(.quitApp(appName: appName))
            case #selector(NSWindow.performMiniaturize(_:)):
                item.title = localizedApp(.minimize)
            case #selector(NSWindow.performZoom(_:)):
                item.title = localizedApp(.zoom)
            case #selector(NSWindow.toggleFullScreen(_:)):
                item.title = localizedApp(.toggleFullScreen)
            case #selector(NSApplication.arrangeInFront(_:)):
                item.title = localizedApp(.bringAllToFront)
            default:
                break
            }
            localize(menu: item.submenu, appName: appName, servicesMenu: servicesMenu)
        }
    }

    private func localizedDropFeedback(_ message: String) -> String {
        let trimmed = message.removingSuffix(".")
        let segments = trimmed.split(separator: ",").map {
            localizedDropFeedbackSegment($0.trimmingCharacters(in: .whitespaces))
        }
        return segments.joined(separator: "，") + "。"
    }

    private func localizedDropFeedbackSegment(_ segment: String) -> String {
        if let value = segment.removingSuffix(" succeeded") {
            return "\(value) 个成功"
        }
        if let value = segment.removingSuffix(" rejected") {
            return "\(value) 个已拒绝"
        }
        if let value = segment.removingSuffix(" truncated") {
            return "\(value) 个已截断"
        }
        if let value = segment.removingSuffix(" folders added") {
            return "已添加 \(value) 个文件夹"
        }
        if let value = segment.removingSuffix(" folders failed") {
            return "\(value) 个文件夹添加失败"
        }
        if let value = segment.removingSuffix(" files opened") {
            return "已打开 \(value) 个文件"
        }
        if let value = segment.removingSuffix(" files missing") {
            return "\(value) 个文件缺失"
        }
        if let value = segment.removingSuffix(" files invalid") {
            return "\(value) 个文件无效"
        }
        if let value = segment.removingSuffix(" files failed to open") {
            return "\(value) 个文件打开失败"
        }
        if let value = segment.removingSuffix(" drop items could not be parsed") {
            return "\(value) 个拖放项目无法解析"
        }
        return segment
    }
}

private struct AppLocaleEnvironmentKey: EnvironmentKey {
    /// Settings also default to Simplified Chinese, so previews and isolated
    /// views behave exactly like a fresh application installation.
    static let defaultValue = EditorLocale.zhCN
}

extension EnvironmentValues {
    var appLocale: EditorLocale {
        get { self[AppLocaleEnvironmentKey.self] }
        set { self[AppLocaleEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Installs the app locale and SwiftUI's matching Foundation locale as one
    /// operation. Applying this at a scene/window root makes locale changes
    /// invalidate all descendant views immediately.
    func appLocale(_ locale: EditorLocale) -> some View {
        environment(\.appLocale, locale)
            .environment(\.locale, locale.foundationLocale)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    func removingSuffix(_ suffix: String) -> String? {
        guard hasSuffix(suffix) else { return nil }
        return String(dropLast(suffix.count))
    }

    func splitOnce(separator: String) -> (Substring, Substring)? {
        guard let range = range(of: separator) else { return nil }
        return (self[..<range.lowerBound], self[range.upperBound...])
    }
}
