import AppKit
import LumenEditorCore
import SwiftUI

@MainActor
enum GitBranchWorkspacePreflight {
    static func evaluateAfterCheckingDisk(
        rootURL: URL,
        documents: [EditorDocument],
        checkExternalChange: @MainActor (EditorDocument) async -> Void
    ) async -> Result<GitBranchPreflightResult, GitBranchPreflightError> {
        let scoped = scopedDocuments(rootURL: rootURL, documents: documents)
        for document in scoped {
            await checkExternalChange(document)
        }
        return evaluate(rootURL: rootURL, documents: scoped)
    }

    static func evaluate(
        rootURL: URL, documents: [EditorDocument]
    ) -> Result<GitBranchPreflightResult, GitBranchPreflightError> {
        let worktreeDocuments = scopedDocuments(rootURL: rootURL, documents: documents)
        for document in worktreeDocuments {
            if document.isSaving {
                return .failure(.savingDocument(name: document.displayName))
            }
            if document.externalConflict != nil {
                return .failure(.externalConflict(name: document.displayName))
            }
            if document.isDirty {
                return .failure(.dirtyDocument(name: document.displayName))
            }
        }
        return .success(GitBranchPreflightResult(
            refreshTokens: worktreeDocuments.compactMap { document in
                guard let url = document.fileURL?.standardizedFileURL else { return nil }
                return GitDiscardRefreshToken(
                    url: url, documentID: document.id,
                    documentRevision: document.buffer.revision,
                    diskRevision: document.diskRevision
                )
            },
            lockID: nil
        ))
    }

    static func evaluateDiscardAfterCheckingDisk(
        urls: [URL],
        documents: [EditorDocument],
        checkExternalChange: @MainActor (EditorDocument) async -> Void
    ) async -> Result<GitDiscardPreflightResult, GitDiscardPreflightError> {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let targetURLs = Set(standardizedURLs)
        let targets = documents.filter { document in
            guard let url = document.fileURL?.standardizedFileURL else { return false }
            return targetURLs.contains(url)
        }
        for document in targets { await checkExternalChange(document) }

        var tokens: [GitDiscardRefreshToken] = []
        tokens.reserveCapacity(targets.count)
        for url in standardizedURLs {
            guard let document = documents.first(where: {
                $0.fileURL?.standardizedFileURL == url
            }) else { continue }
            if document.isSaving {
                return .failure(.savingDocument(name: document.displayName))
            }
            if document.externalConflict != nil {
                return .failure(.externalConflict(name: document.displayName))
            }
            if document.isDirty {
                return .failure(.dirtyDocument(name: document.displayName))
            }
            tokens.append(GitDiscardRefreshToken(
                url: url, documentID: document.id,
                documentRevision: document.buffer.revision,
                diskRevision: document.diskRevision
            ))
        }
        return .success(GitDiscardPreflightResult(refreshTokens: tokens))
    }

    static func scopedDocuments(
        rootURL: URL, documents: [EditorDocument]
    ) -> [EditorDocument] {
        documents.filter { document in
            guard let documentURL = document.fileURL else { return false }
            return contains(rootURL: rootURL, candidateURL: documentURL)
        }
    }

    static func contains(rootURL: URL, candidateURL: URL) -> Bool {
        contains(
            rootComponents: lexicalComponents(of: rootURL),
            candidateComponents: lexicalComponents(of: candidateURL)
        ) || contains(
            rootComponents: canonicalComponents(of: rootURL),
            candidateComponents: canonicalComponents(of: candidateURL)
        )
    }

    static func currentDocument(
        for token: GitDiscardRefreshToken, documents: [EditorDocument]
    ) -> EditorDocument? {
        guard let document = documents.first(where: {
            $0.id == token.documentID
                && $0.fileURL?.standardizedFileURL == token.url
        }) else { return nil }
        guard !document.isSaving, !document.isDirty,
              document.externalConflict == nil,
              document.buffer.revision == token.documentRevision,
              document.diskRevision == token.diskRevision else { return nil }
        return document
    }

    static func lock(
        tokens: [GitDiscardRefreshToken], documents: [EditorDocument]
    ) -> UUID? {
        let targets = tokens.compactMap { token in
            currentDocument(for: token, documents: documents)
        }
        // Owner locks are composable: termination and Git may overlap, while
        // token validation below still rejects edits/saves that happened before
        // this transaction acquired its own owner. Each completion releases only
        // the UUID it acquired.
        guard targets.count == tokens.count else { return nil }
        let lockID = UUID()
        for document in targets { document.lockEditingForGitMutation(lockID) }
        return lockID
    }

    static func unlock(
        tokens: [GitDiscardRefreshToken], lockID: UUID?, documents: [EditorDocument]
    ) {
        guard let lockID else { return }
        let tokenIDs = Set(tokens.map(\.documentID))
        for document in documents where tokenIDs.contains(document.id) {
            document.unlockEditingAfterGitMutation(lockID)
        }
    }

    private static func canonicalComponents(of url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    private static func lexicalComponents(of url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }

    private static func contains(
        rootComponents: [String], candidateComponents: [String]
    ) -> Bool {
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { $0.0 == $0.1 }
    }

}

@MainActor
final class EditorWindowComposition: ObservableObject {
    let session: WindowSessionComposition
    let model: AppModel
    let actions: EditorActionController
    let settings: SettingsController
    let workspace: WorkspaceController
    let commandRouter: CommandRouter
    let workspaceSearch: WorkspaceSearchController
    let gitController: GitController
    let buildController: BuildController
    let terminalController: TerminalController
    let findController: FindBarController
    let navigationController: NavigationController
    let previewController: PreviewController
    let languageServerController: LanguageServerController
    let pluginController: PluginController
    let htmlBrowserController: HTMLBrowserController
    let autoSaveController: AutoSaveController
    let recentItemsController: RecentItemsController
    let projectSettingsController: ProjectSettingsController
    let macroSnippetController: MacroSnippetController
    let documentFormatController: DocumentFormatController
    let updateController: UpdateController
    let colorSchemeController: ColorSchemeController
    let codeMirrorParserService: CodeMirrorParserService
    let codeMirrorParserCoordinator: CodeMirrorParserCoordinator
    let outlineController: OutlineController
    let languageToolsController: LanguageToolsController
    let incrementalDiffController: IncrementalDiffController
    let sublimeImportComposition: SublimeImportComposition

    let editorCommandController: EditorCommandController
    let bookmarkController: BookmarkController
    let languageController: LanguageController
    let keyboardController: CommandKeyboardController
    private let newWindowRelay: NewWindowRelay
    private let workspaceMutationRelay: WorkspaceMutationRelay
    let runtimeSettingsBridge: RuntimeSettingsBridge
    private(set) var commandTokens: [CommandHandlerToken] = []
    private var finalizationTask: Task<Void, Never>?

    func setOpenWindowAction(_ action: @escaping () -> Void) {
        newWindowRelay.action = action
    }

    func openNewWindow() { newWindowRelay.perform() }

    /// Irreversibly tears down this window only after AppKit has committed the
    /// close, or after every window accepted application termination.
    func finalizeTermination() async {
        if let finalizationTask {
            await finalizationTask.value
            return
        }
        let task = Task { @MainActor [self] in
            keyboardController.stop()
            workspaceSearch.dismiss()
            buildController.declinePendingBuild()
            terminalController.declinePendingStart()
            pluginController.declinePendingWorkerApproval()
            sublimeImportComposition.controller.cancel()
            outlineController.shutdown()
            await codeMirrorParserCoordinator.shutdown()
            autoSaveController.shutdown()

            await gitController.shutdown()
            await buildController.cancel()
            await terminalController.close()
            await pluginController.deactivateWorkers()
            await languageToolsController.cancel()
            await languageServerController.shutdown()
            await projectSettingsController.releaseLanguageServerExecutableAccess()

            htmlBrowserController.shutdown()
            workspace.shutdown()
            languageToolsController.releaseSecurityScopedAccess()
            model.releaseAllSecurityScopedAccess()
            commandRouter.setExecutionObserver(nil)
            commandRouter.removeAllHandlers()
        }
        finalizationTask = task
        await task.value
    }

    init(
        session: WindowSessionComposition,
        settings: SettingsController,
        chooseLanguageServerExecutable: @escaping LanguageToolsComposition.ChooseExecutable = {
            await LanguageToolExecutablePicker.chooseLanguageServer(locale: $0)
        },
        languageServerSecurityScopedAccess: SecurityScopedAccessController = .shared
    ) {
        self.session = session
        let toolApprovals = ToolApprovalStore()
        let toolScope = ToolApprovalScope(
            windowID: session.id.rawValue,
            sessionID: UUID().uuidString.lowercased()
        )
        self.settings = settings
        let codeMirrorParserService = CodeMirrorParserService()
        self.codeMirrorParserService = codeMirrorParserService
        let codeMirrorParserCoordinator = CodeMirrorParserCoordinator(
            service: codeMirrorParserService
        )
        self.codeMirrorParserCoordinator = codeMirrorParserCoordinator
        let maximumEditableByteCount = Int64(settings.settings.maxFileSizeMB)
            * 1_024 * 1_024
        // Session restoration owns creation of the first untitled document. Starting
        // empty prevents a transient tab from being persisted over the hot-exit state.
        let model = session.makeAppModel(
            maximumEditableByteCount: maximumEditableByteCount,
            createInitialDocument: false
        )
        self.model = model
        let newWindowRelay = NewWindowRelay()
        self.newWindowRelay = newWindowRelay
        let workspaceMutationRelay = WorkspaceMutationRelay(model: model)
        self.workspaceMutationRelay = workspaceMutationRelay
        let commandRouter = CommandRouter()
        self.commandRouter = commandRouter
        let keyBindingRelay = CommandKeyboardRelay()
        let workspace = WorkspaceController(
            maximumEditableByteCount: maximumEditableByteCount,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { openedFile in
                _ = model.open(openedFile: openedFile)
            },
            authorizeMutation: { event in
                guard model.canApplyWorkspaceMutation(event) else {
                    throw WorkspaceMutationAuthorizationError.rejected(
                        "Save or close affected documents before changing this item."
                    )
                }
            },
            prepareMutation: { event in
                try model.prepareWorkspaceMutation(event)
            },
            didMutate: { event in
                try workspaceMutationRelay.apply(event)
            }
        )
        self.workspace = workspace
        let actions = EditorActionController(
            model: model, workspace: workspace, locale: settings.locale
        )
        actions.setPreflightClose { true }
        self.actions = actions
        let navigationController = NativeFeatureCoordinator.makeNavigationController(
            model: model, workspace: workspace, actions: actions
        )
        self.navigationController = navigationController
        workspaceMutationRelay.navigationController = navigationController
        let workspaceSearch = WorkspaceSearchController(
            workspaceController: workspace,
            navigateToMatch: { match in
                await navigationController.goToFile(
                    match.url,
                    utf16Offset: match.utf16Range.location,
                    selectionUTF16Length: match.utf16Range.length
                )
            },
            filesChanged: { urls, _ in
                workspace.refreshWorkspace()
                if urls.contains(where: { $0.lastPathComponent == ".editorconfig" }) {
                    await actions.refreshEditorConfigs()
                }
                for url in urls {
                    guard let document = model.documents.first(where: {
                        $0.fileURL?.standardizedFileURL == url.standardizedFileURL
                    }) else { continue }
                    await model.checkForExternalChange(document)
                }
            }
        )
        self.workspaceSearch = workspaceSearch
        let gitController = GitController(
            openWorktreeFile: { url in
                await navigationController.goToFile(url)
            },
            discardPreflight: { urls in
                let result = await GitBranchWorkspacePreflight.evaluateDiscardAfterCheckingDisk(
                    urls: urls, documents: model.documents,
                    checkExternalChange: { await model.checkForExternalChange($0) }
                )
                guard case let .success(preflight) = result else { return result }
                let tokens = preflight.refreshTokens
                guard let lockID = GitBranchWorkspacePreflight.lock(
                    tokens: tokens, documents: model.documents
                ) else {
                    return .failure(.workspaceBusy)
                }
                guard model.acquireGitEditingLock(lockID) else {
                    GitBranchWorkspacePreflight.unlock(
                        tokens: tokens, lockID: lockID, documents: model.documents
                    )
                    return .failure(.workspaceBusy)
                }
                return .success(GitDiscardPreflightResult(
                    refreshTokens: tokens, lockID: lockID
                ))
            },
            completeDiscardPreflight: { preflight, requiresReconciliation in
                guard let lockID = preflight.lockID else { return }
                defer { model.releaseGitEditingLock(lockID) }
                guard requiresReconciliation else {
                    GitBranchWorkspacePreflight.unlock(
                        tokens: preflight.refreshTokens, lockID: lockID,
                        documents: model.documents
                    )
                    return
                }
                for token in preflight.refreshTokens {
                    guard let document = model.documents.first(where: {
                        $0.id == token.documentID
                            && $0.fileURL?.standardizedFileURL == token.url
                    }) else {
                        GitBranchWorkspacePreflight.unlock(
                            tokens: [token], lockID: lockID, documents: model.documents
                        )
                        continue
                    }
                    _ = await model.reopenAfterGitMutation(
                        document, lockID: lockID,
                        using: document.encodingLocked ? document.savedEncoding : nil
                    )
                }
            },
            branchPreflight: { rootURL in
                let result = await GitBranchWorkspacePreflight.evaluateAfterCheckingDisk(
                    rootURL: rootURL, documents: model.documents,
                    checkExternalChange: { await model.checkForExternalChange($0) }
                )
                guard case let .success(preflight) = result else { return result }
                guard let lockID = GitBranchWorkspacePreflight.lock(
                    tokens: preflight.refreshTokens, documents: model.documents
                ) else { return .failure(.workspaceBusy) }
                guard model.acquireGitEditingLock(lockID) else {
                    GitBranchWorkspacePreflight.unlock(
                        tokens: preflight.refreshTokens, lockID: lockID,
                        documents: model.documents
                    )
                    return .failure(.workspaceBusy)
                }
                return .success(GitBranchPreflightResult(
                    refreshTokens: preflight.refreshTokens, lockID: lockID
                ))
            },
            completeBranchPreflight: { preflight, requiresReconciliation in
                guard let lockID = preflight.lockID else { return }
                defer { model.releaseGitEditingLock(lockID) }
                guard requiresReconciliation else {
                    GitBranchWorkspacePreflight.unlock(
                        tokens: preflight.refreshTokens, lockID: lockID,
                        documents: model.documents
                    )
                    return
                }
                for token in preflight.refreshTokens {
                    guard let document = model.documents.first(where: {
                        $0.id == token.documentID
                            && $0.fileURL?.standardizedFileURL == token.url
                    }) else {
                        GitBranchWorkspacePreflight.unlock(
                            tokens: [token], lockID: lockID, documents: model.documents
                        )
                        continue
                    }
                    _ = await model.reopenAfterGitMutation(
                        document, lockID: lockID,
                        using: document.encodingLocked ? document.savedEncoding : nil
                    )
                }
            },
            presentConflict: { request in
                if request.target != .worktree { actions.dismissGitPanel() }
                switch request.target {
                case .worktree:
                    guard let worktreeURL = request.worktreeURL else { return false }
                    return await navigationController.goToFile(worktreeURL)
                case .ours:
                    guard let ours = request.ours else { return false }
                    let paneIndex = model.paneLayout.activePaneIndex
                    let document = model.openComparisonSnapshot(
                        displayName: request.path + " (Ours)", text: ours.content,
                        languageHintURL: request.worktreeURL, encoding: ours.encoding,
                        lineEnding: ours.lineEnding
                    )
                    return model.selectDocument(document, inPaneAt: paneIndex)
                case .theirs:
                    guard let theirs = request.theirs else { return false }
                    if model.paneLayout.panes.count < 2 { _ = model.setLayout(.columns2) }
                    let activePane = model.paneLayout.activePaneIndex
                    let paneIndex = min(
                        activePane + 1,
                        max(0, model.paneLayout.panes.count - 1)
                    )
                    _ = model.focusPane(at: paneIndex)
                    let document = model.openComparisonSnapshot(
                        displayName: request.path + " (Theirs)", text: theirs.content,
                        languageHintURL: request.worktreeURL, encoding: theirs.encoding,
                        lineEnding: theirs.lineEnding
                    )
                    return model.selectDocument(document, inPaneAt: paneIndex)
                case .compare:
                    guard request.ours != nil || request.theirs != nil else { return false }
                    if model.paneLayout.panes.count < 2 { _ = model.setLayout(.columns2) }
                    let leftPane = model.paneLayout.activePaneIndex
                    let rightPane = min(leftPane + 1, max(0, model.paneLayout.panes.count - 1))
                    var opened = false
                    _ = model.focusPane(at: leftPane)
                    if let ours = request.ours {
                        let oursDocument = model.openComparisonSnapshot(
                            displayName: request.path + " (Ours)", text: ours.content,
                            languageHintURL: request.worktreeURL, encoding: ours.encoding,
                            lineEnding: ours.lineEnding
                        )
                        opened = model.selectDocument(oursDocument, inPaneAt: leftPane) || opened
                    }
                    _ = model.focusPane(at: rightPane)
                    if let theirs = request.theirs {
                        let theirsDocument = model.openComparisonSnapshot(
                            displayName: request.path + " (Theirs)", text: theirs.content,
                            languageHintURL: request.worktreeURL, encoding: theirs.encoding,
                            lineEnding: theirs.lineEnding
                        )
                        opened = model.selectDocument(theirsDocument, inPaneAt: rightPane) || opened
                    }
                    return opened
                }
            }
        )
        self.gitController = gitController
        let buildController = BuildController(
            approvals: toolApprovals,
            scope: toolScope,
            saveBeforeBuild: { [weak actions] in
                guard let actions else { return false }
                actions.dismissBuildPanel()
                await Task.yield()
                return await actions.saveAllDocuments()
            }
        )
        self.buildController = buildController
        let terminalController = TerminalController(
            approvals: toolApprovals, scope: toolScope
        )
        self.terminalController = terminalController
        let findController = NativeFeatureCoordinator.makeFindController(model: model)
        self.findController = findController
        let previewController = NativeFeatureCoordinator.makePreviewController(model: model)
        self.previewController = previewController
        let languageServerManager = LanguageServerManager(
            approvals: toolApprovals, approvalScope: toolScope
        )
        let languageServerController = LanguageServerController(
            manager: LanguageServerManagerAdapter(manager: languageServerManager),
            coordinateRenamePreview: { preview in
                guard !workspace.isApplicationTerminationPrepared,
                      !model.isTextEditingLocked else {
                    throw CancellationError()
                }
                try await NativeFeatureCoordinator.applyRenamePreview(
                    preview,
                    model: model,
                    workspace: workspace,
                    locale: settings.settings.locale
                )
            }
        )
        self.languageServerController = languageServerController
        let pluginController = PluginController.production(
            model: model, approvals: toolApprovals, scope: toolScope
        )
        self.pluginController = pluginController
        let htmlBrowserController = HTMLBrowserController()
        self.htmlBrowserController = htmlBrowserController
        let autoSaveController = AutoSaveController.connected(
            settings: settings, model: model
        )
        self.autoSaveController = autoSaveController
        let recentItemsController = RecentItemsController(
            openFile: { url in
                await actions.openAuthorizedSnapshot(at: url)
            },
            openProject: { url in
                await workspace.restoreRoots([url], primaryURL: url)
                return workspace.roots.contains {
                    $0.url.standardizedFileURL == url.standardizedFileURL
                }
            }
        )
        self.recentItemsController = recentItemsController
        let projectSettingsController = ProjectSettingsController(
            chooseLanguageServerExecutable: { [weak settings] in
                await chooseLanguageServerExecutable(settings?.settings.locale ?? .zhCN)
            },
            authorizeLanguageServerExecutable: { url in
                try await languageServerController.authorizeExecutable(url)
            },
            revokeLanguageServerExecutables: {
                await languageServerController.revokeAllExecutableAuthorizations()
            },
            securityScopedAccess: languageServerSecurityScopedAccess,
            exclusionsDidChange: { exclusions in
                workspace.setProjectExclusions(exclusions)
            },
            didCommit: { project, root in
                model.configureSessionWorkspace(
                    folders: workspace.roots.map { $0.url.path },
                    primaryFolder: root.path,
                    project: try? project.sessionProject()
                )
                pluginController.setMarketplaceSources(project.marketplaceUrls)
                keyBindingRelay.setOverrides(
                    SublimeImportProjectSettingsMerge.keyBindingOverrides(
                        from: project.keyBindingRules
                    )
                )
            }
        )
        self.projectSettingsController = projectSettingsController
        let languageToolsController = LanguageToolsComposition.makeController(
            model: model, workspace: workspace,
            projectSettings: projectSettingsController,
            approvals: toolApprovals, approvalScope: toolScope,
            languageServers: languageServerController,
            locale: { [weak settings] in settings?.settings.locale ?? .zhCN },
            chooseExecutable: LanguageToolExecutablePicker.choose(locale:)
        )
        self.languageToolsController = languageToolsController
        let sublimeImportComposition = SublimeImportComposition.production(
            settings: settings, workspace: workspace,
            projectSettings: projectSettingsController,
            currentKeyBindings: { commandRouter.keyBindingOverrides },
            applyKeyBindings: { keyBindingRelay.setOverrides($0) },
            synchronizeWorkspaceSession: { [weak actions] in
                actions?.synchronizeWorkspaceSession()
            }
        )
        self.sublimeImportComposition = sublimeImportComposition
        let editorCommands = EditorCommandController(
            model: model, settings: { settings.settings },
            parsedSyntax: {
                text, language, revision, tabWidth, indentWidth, insertSpaces in
                codeMirrorParserCoordinator.cachedParsedSyntaxSnapshot(
                    text: text, language: language, revision: revision,
                    tabWidth: tabWidth, indentWidth: indentWidth,
                    insertSpaces: insertSpaces
                )
            },
            prepareParsedSyntax: { snapshot in
                guard let revision = snapshot.expectedRevision else { return }
                _ = await codeMirrorParserCoordinator.analyze(
                    text: snapshot.text, language: snapshot.language,
                    revision: revision, tabWidth: snapshot.tabWidth,
                    indentWidth: snapshot.indentWidth, insertSpaces: snapshot.insertSpaces
                )
            },
            successfulSelectionChange: { commandID, before, after in
                guard commandID == "goto-matching-bracket" else { return }
                guard let document = model.selectedDocument else { return }
                let source = NativeFeatureCoordinator.navigationLocation(
                    model: model, document: document, utf16Offset: before.selection.main.head
                )
                let target = NativeFeatureCoordinator.navigationLocation(
                    model: model, document: document, utf16Offset: after.main.head
                )
                if source != target {
                    navigationController.recordSuccessfulJump(
                        source: source, target: target
                    )
                }
            }
        )
        editorCommandController = editorCommands
        let bookmarks = BookmarkController(model: model, navigation: navigationController)
        bookmarkController = bookmarks
        let languages = LanguageController(model: model)
        languageController = languages
        let macroSnippetController = MacroSnippetController.connected(
            model: model,
            workspace: { workspace.roots.first(where: \.isPrimary)?.url },
            dispatchCommand: { command in
                let context = actions.commandRoutingContext(
                    hasFindResults: workspaceSearch.hasResults,
                    hasGitRepository: gitController.isRepositoryAvailable,
                    hasNavigationHistory: navigationController.canGoBack
                        || navigationController.canGoForward,
                    hasLanguageService: languageServerController.runningServerCount > 0
                )
                return await commandRouter.execute(
                    command.commandID, context: context
                ).didExecuteSuccessfully
            },
            projectSnippets: { projectSettingsController.settings.snippets },
            pluginSnippets: { pluginController.snippetRoutes }
        )
        self.macroSnippetController = macroSnippetController
        runtimeSettingsBridge = RuntimeSettingsBridge(
            settings: settings, build: buildController, find: findController,
            workspaceSearch: workspaceSearch, projectSettings: projectSettingsController
        )
        let documentFormatController = DocumentFormatController(
            activeDocument: { model.selectedDocument },
            openUsingEncoding: { [weak actions] encoding in
                await actions?.openDocuments(forcedEncoding: encoding)
            },
            applySaveEncoding: { [weak actions] document, encoding in
                actions?.chooseEncodingForSave(encoding, document: document) == true
            },
            applyLineEnding: { [weak actions] document, lineEnding in
                actions?.chooseLineEndingForSave(lineEnding, document: document) == true
            },
            requestReopen: { [weak actions] document, encoding in
                actions?.requestReopen(document, using: encoding) == true
            }
        )
        self.documentFormatController = documentFormatController
        let updateController = UpdateController()
        self.updateController = updateController
        let colorSchemeController = ColorSchemeController(settings: settings)
        self.colorSchemeController = colorSchemeController
        let outlineController = OutlineController.connected(
            model: model, settings: settings,
            analyze: {
                text, language, revision, tabWidth, indentWidth, insertSpaces, limits in
                await codeMirrorParserCoordinator.outlineDocumentModel(
                    text: text, language: language, revision: revision,
                    tabWidth: tabWidth, indentWidth: indentWidth,
                    insertSpaces: insertSpaces, limits: limits
                )
            },
            navigate: { request in
                guard let paneIndex = model.paneLayout.panes.firstIndex(where: {
                    $0.viewID == request.viewID
                }),
                      model.paneLayout.panes[paneIndex].contains(request.documentID),
                      let document = model.document(
                          sessionDocumentID: request.documentID
                      ),
                      document.buffer.revision == request.documentRevision,
                      request.utf16Offset <= document.buffer.utf16Length
                else { return false }
                return await navigationController.navigate(to: NavigationDestination(
                    target: .document(id: request.documentID),
                    groupID: paneIndex,
                    line: request.line,
                    column: 1,
                    utf16Offset: request.utf16Offset
                ))
            },
            feedback: { [weak actions] feedback in
                switch feedback {
                case .noActiveDocument:
                    actions?.presentIssue(title: "Outline Unavailable", message: "No document is active.")
                case .noFoldableRegion:
                    actions?.presentIssue(title: "Nothing to Fold", message: "No foldable region contains the cursor.")
                case .noFoldedRegion:
                    actions?.presentIssue(title: "Nothing to Unfold", message: "No folded region contains the cursor.")
                }
            }
        )
        self.outlineController = outlineController
        let incrementalDiffController = IncrementalDiffController(
            model: model, navigation: navigationController
        )
        self.incrementalDiffController = incrementalDiffController
        commandRouter.setExecutionObserver {
            [weak macroSnippetController] commandID, observation in
            macroSnippetController?.observeRoutedCommand(
                commandID, observation: observation
            )
        }
        actions.setTransientPanelDidDismiss {
            [weak workspaceSearch, weak navigationController,
             weak recentItemsController, weak projectSettingsController,
             weak languages, weak macroSnippetController,
             weak documentFormatController, weak updateController,
             weak colorSchemeController, weak languageToolsController,
             weak buildController,
             weak sublimeImportController = sublimeImportComposition.controller] panel in
            switch panel {
            case .workspaceSearch: workspaceSearch?.dismiss()
            case .navigation: navigationController?.dismiss()
            case .recentItems: recentItemsController?.dismiss()
            case .projectSettings: projectSettingsController?.dismiss()
            case .languageSelection: languages?.dismiss()
            case .macroSnippet: macroSnippetController?.dismissPresentation()
            case .documentFormat: documentFormatController?.dismiss()
            case .softwareUpdate: updateController?.dismiss()
            case .colorScheme: colorSchemeController?.dismiss()
            case .languageTools: languageToolsController?.dismissConfiguration()
            case .sublimeImport: sublimeImportController?.cancel()
            case .buildSystem: buildController?.dismissBuildSystemPalette()
            default: break
            }
        }
        actions.setAdditionalBlockingInteraction(
            { [weak workspaceSearch, weak gitController, weak macroSnippetController,
               weak updateController, weak languageToolsController,
               weak pluginController,
               weak sublimeImportController = sublimeImportComposition.controller] in
                workspaceSearch?.isBusy == true
                    || gitController?.isBusy == true
                    || macroSnippetController?.isReplaying == true
                    || updateController?.isChecking == true
                    || languageToolsController?.isRunning == true
                    || pluginController?.pendingWorkerApproval != nil
                    || pluginController?.isWorkerRunning == true
                    || sublimeImportController?.isBusy == true
            },
            shutdownBlocker: {
                [weak workspaceSearch, weak gitController, weak macroSnippetController,
                 weak languageToolsController,
                 weak languageServerController,
                 weak pluginController,
                 weak sublimeImportController = sublimeImportComposition.controller] in
                workspaceSearch?.isMutatingFiles == true
                    || gitController?.isBusy == true
                    || macroSnippetController?.isReplaying == true
                    || languageToolsController?.isRunning == true
                    || languageServerController?.isInteractiveRequestRunning == true
                    || pluginController?.pendingWorkerApproval != nil
                    || pluginController?.isWorkerRunning == true
                    || sublimeImportController?.isBusy == true
            }
        )

        installApplicationCommandHandlers(
            on: commandRouter,
            model: model,
            actions: actions,
            workspace: workspace,
            settings: settings,
            workspaceSearch: workspaceSearch,
            navigation: navigationController,
            git: gitController,
            build: buildController,
            terminal: terminalController,
            preview: previewController,
            languageServers: languageServerController,
            plugins: pluginController,
            projectSettings: projectSettingsController,
            newWindow: { newWindowRelay.perform() }
        )
        var tokens: [CommandHandlerToken] = []
        do {
            tokens += try editorCommands.registerCommands(on: commandRouter)
            tokens += try findController.registerCommands(on: commandRouter)
            tokens += try navigationController.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                presentPalette: { [weak actions] in
                    actions?.presentTransientPanel(.navigation)
                }
            )
            tokens += try bookmarks.registerCommands(
                on: commandRouter, replaceExisting: true
            )
            tokens += try languages.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                }
            )
            tokens += try macroSnippetController.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                }
            )
            tokens += try recentItemsController.registerCommands(
                on: commandRouter, replaceExisting: true
            )
            tokens += try documentFormatController.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                presentPalette: { [weak actions] in
                    actions?.presentTransientPanel(.documentFormat)
                }
            )
            tokens.append(try updateController.registerCommand(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                presentPanel: { [weak actions] in
                    actions?.presentTransientPanel(.softwareUpdate)
                }
            ))
            tokens.append(try colorSchemeController.registerCommand(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                presentPanel: { [weak actions] in
                    actions?.presentTransientPanel(.colorScheme)
                }
            ))
            tokens += try outlineController.registerCommands(
                on: commandRouter, replaceExisting: true
            )
            tokens += try incrementalDiffController.registerCommands(
                on: commandRouter, replaceExisting: true
            )
            tokens += try languageToolsController.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                }
            )
            tokens += try sublimeImportComposition.registerCommands(
                on: commandRouter, replaceExisting: true,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                present: { [weak actions] in
                    actions?.transitionToTransientPanel(.sublimeImport)
                }
            )
            tokens.append(try htmlBrowserController.registerCommandHandler(
                on: commandRouter, model: model,
                prepareForCommand: { [weak actions] in
                    await actions?.prepareForRoutedCommand()
                },
                additionalEnablement: { [weak actions] _ in
                    (actions?.canExecutePanelCommand ?? false)
                        ? .enabled
                        : .disabled(reason: "Finish the current interaction first.")
                }
            ))
        } catch {
            actions.presentIssue(
                title: "Could Not Configure Commands",
                message: error.localizedDescription
            )
        }
        commandTokens = tokens
        let keyboardController = CommandKeyboardController(
            router: commandRouter,
            context: { [weak actions, weak workspaceSearch, weak gitController,
                         weak navigationController, weak languageServerController] in
                actions?.commandRoutingContext(
                    hasFindResults: workspaceSearch.hasResults,
                    hasGitRepository: gitController.isRepositoryAvailable,
                    hasNavigationHistory: navigationController.canGoBack
                        || navigationController.canGoForward,
                    hasLanguageService: languageServerController.runningServerCount > 0
                ) ?? .init()
            },
            isAvailable: { [weak actions, weak findController, weak navigationController] in
                EditorWindowInteractionPlan.keyboardRoutingIsAvailable(
                    hasTransientPanel: actions?.isAnyTransientPanelPresented ?? true,
                    findIsPresented: findController?.isPresented ?? false,
                    navigationIsPresented: navigationController?.isPresented ?? false
                )
            },
            resultHandler: { [weak actions] result in
                actions?.handleCommandExecutionResult(result)
            }
        )
        self.keyboardController = keyboardController
        keyBindingRelay.controller = keyboardController
    }

}

@MainActor
private struct EditorWindowScene: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var composition: EditorWindowComposition
    @ObservedObject var settings: SettingsController
    let applicationDelegate: LumenApplicationDelegate
    let sessionCoordinator: WindowSessionCoordinator
    @State private var didAppear = false

    private var sessionID: WindowSessionID { composition.session.id }
    private var model: AppModel { composition.model }
    private var actions: EditorActionController { composition.actions }

    var body: some View {
            EditorWindowView(
                model: composition.model,
                actions: composition.actions,
                settings: composition.settings,
                workspace: composition.workspace,
                commandRouter: composition.commandRouter,
                workspaceSearch: composition.workspaceSearch,
                gitController: composition.gitController,
                buildController: composition.buildController,
                terminalController: composition.terminalController,
                findController: composition.findController,
                navigationController: composition.navigationController,
                previewController: composition.previewController,
                languageServerController: composition.languageServerController,
                pluginController: composition.pluginController,
                recentItemsController: composition.recentItemsController,
                projectSettingsController: composition.projectSettingsController,
                languageController: composition.languageController,
                macroSnippetController: composition.macroSnippetController,
                documentFormatController: composition.documentFormatController,
                updateController: composition.updateController,
                colorSchemeController: composition.colorSchemeController,
                outlineController: composition.outlineController,
                codeMirrorParserCoordinator: composition.codeMirrorParserCoordinator,
                editorCommandController: composition.editorCommandController,
                incrementalDiffController: composition.incrementalDiffController,
                languageToolsController: composition.languageToolsController,
                sublimeImportController: composition.sublimeImportComposition.controller,
                editorConfigController: composition.actions.editorConfigController,
                windowSession: composition.session,
                windowDidBecomeKey: {
                    composition.keyboardController.start()
                    applicationDelegate.windowDidBecomeKey(sessionID)
                },
                windowDidResignKey: {
                    composition.keyboardController.stop()
                    composition.autoSaveController.windowDidResignKey()
                },
                windowWillClose: { presentation in
                    if let presentation {
                        try? composition.session.updatePresentation(presentation)
                    }
                    // This callback is the AppKit close commit. Consume the
                    // standalone close marker synchronously here; waiting for
                    // async service teardown would wrongly resurrect a window
                    // after a crash that happened after it visibly closed.
                    try? composition.session.close(.preserve)
                    Task { @MainActor [composition, applicationDelegate] in
                        await composition.finalizeTermination()
                        applicationDelegate.disconnect(windowID: sessionID)
                    }
                }
            )
                .frame(minWidth: 720, minHeight: 480)
                .appLocale(settings.settings.locale)
                .preferredColorScheme(settings.preferredColorScheme)
                .acceptsWorkspaceFileDrops { urls in
                    await actions.handleDroppedURLs(urls)
                }
                .onAppear {
                    composition.setOpenWindowAction {
                        applicationDelegate.requestNewWindow()
                    }
                    guard !didAppear else { return }
                    didAppear = true
                    applicationDelegate.connect(
                        windowID: sessionID,
                        openURLs: { urls in
                            actions.enqueueExternalURLs(urls)
                        },
                        flushSession: {
                            actions.synchronizeWorkspaceSession()
                            return model.flushSession()
                        },
                        preflightTerminationPersistence: {
                            actions.synchronizeWorkspaceSession()
                            return actions.preflightApplicationTerminationPersistence()
                        },
                        prepareToTerminate: { completion in
                            actions.prepareForApplicationTermination(completion: completion)
                        },
                        validateTerminationPreparation: {
                            actions.validateApplicationTerminationPreparation()
                        },
                        commitTerminationPreparation: {
                            actions.commitApplicationTerminationPreparation()
                        },
                        abortTerminationPreparation: {
                            await actions.abortApplicationTerminationPreparation()
                        },
                        finalizeTermination: {
                            await composition.finalizeTermination()
                        }
                    )
                }
                .onOpenURL { url in
                    // SwiftUI receives this route in some launch configurations, while
                    // a packaged app normally arrives through NSApplicationDelegate.
                    // The controller serialises and de-duplicates both routes.
                    actions.enqueueExternalURLs([url])
                }
                .onDisappear {
                    composition.keyboardController.stop()
                }
                .focusedSceneValue(\.editorWindowComposition, composition)
    }
}

@main
@MainActor
struct LumenEditorApplication: App {
    @NSApplicationDelegateAdaptor(LumenApplicationDelegate.self)
    private var applicationDelegate

    private let sessionCoordinator: WindowSessionCoordinator
    @StateObject private var startupRecovery: StartupRecoveryController
    @StateObject private var settings: SettingsController
    @StateObject private var settingsOnlyUpdateController: UpdateController

    init() {
        let coordinator = WindowSessionCoordinator()
        let settings = SettingsController()
        sessionCoordinator = coordinator
        _startupRecovery = StateObject(wrappedValue: StartupRecoveryController(
            coordinator: coordinator
        ))
        _settings = StateObject(wrappedValue: settings)
        _settingsOnlyUpdateController = StateObject(
            wrappedValue: UpdateController()
        )
        applicationDelegate.bindMenuLocalization(to: settings)
        applicationDelegate.flushGlobalState = { settings.flush() }
        applicationDelegate.prepareGlobalStateTerminationCommit = {
            settings.flushAndLockForApplicationTermination()
        }
        applicationDelegate.abortGlobalStateTerminationCommit = {
            settings.unlockAfterFailedApplicationTermination()
        }
        applicationDelegate.terminationCommitStateDidChange = { committed in
            if committed { coordinator.markApplicationTerminationCommitted() }
        }
    }

    var body: some Scene {
        WindowGroup(
            settings.settings.locale.localizedApp(.systemAppName),
            for: WindowSessionSceneValue.self
        ) { $sceneValue in
            if let plan = startupRecovery.plan, let sceneValue,
               plan.all.contains(where: { $0.id == sceneValue.id })
                    || sessionCoordinator.isReserved(sceneValue.id) {
                EditorWindowSceneHost(
                    sceneValue: sceneValue,
                    startupPlan: plan,
                    startupRecovery: startupRecovery,
                    coordinator: sessionCoordinator,
                    settings: settings,
                    applicationDelegate: applicationDelegate
                )
            } else {
                StartupRecoveryView(
                    controller: startupRecovery, settings: settings
                )
            }
        } defaultValue: {
            startupRecovery.plan?.primary
                ?? WindowSessionSceneValue(id: .legacy)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1_080, height: 720)
        .commands {
            FocusedEditorCommands(
                coordinator: sessionCoordinator, settings: settings,
                settingsOnlyUpdateController: settingsOnlyUpdateController
            )
        }

        Settings {
            SettingsWindowRoot(
                controller: settings, updateController: settingsOnlyUpdateController,
                applicationDelegate: applicationDelegate
            )
                .preferredColorScheme(settings.preferredColorScheme)
        }
        .commands {
            FocusedEditorCommands(
                coordinator: sessionCoordinator, settings: settings,
                settingsOnlyUpdateController: settingsOnlyUpdateController
            )
        }
    }
}

@MainActor
final class StartupRecoveryController: ObservableObject {
    @Published private(set) var plan: WindowSessionStartupPlan?
    @Published private(set) var error: (any Error)?
    @Published private(set) var preservedArchiveURL: URL?
    private let coordinator: WindowSessionCoordinator
    private let loadPlan: @MainActor () throws -> WindowSessionStartupPlan

    init(
        coordinator: WindowSessionCoordinator,
        startImmediately: Bool = true,
        initialError: (any Error)? = nil,
        loadPlan: (@MainActor () throws -> WindowSessionStartupPlan)? = nil
    ) {
        self.coordinator = coordinator
        self.error = initialError
        self.loadPlan = loadPlan ?? { try coordinator.retryStartupPlan() }
        if startImmediately { retry() }
    }

    func retry() {
        do {
            plan = try loadPlan()
            error = nil
        } catch {
            plan = nil
            self.error = error
        }
    }

    func preserveTransactionAndUseCanonicalSnapshots() {
        do {
            let recovery = try coordinator
                .preserveFailedTerminationAndUseCanonicalSnapshots()
            preservedArchiveURL = recovery.archiveURL
            plan = recovery.plan
            error = nil
        } catch {
            plan = nil
            self.error = error
        }
    }

    var hasFailedCommittedTransaction: Bool {
        plan == nil && error != nil
            && coordinator.hasActiveTerminationRecoveryArtifacts()
    }
}

@MainActor
private struct StartupRecoveryView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: StartupRecoveryController
    @ObservedObject var settings: SettingsController
    var compositionError: (any Error)?
    var retryComposition: (() -> Void)?

    init(
        controller: StartupRecoveryController,
        settings: SettingsController,
        compositionError: (any Error)? = nil,
        retryComposition: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.settings = settings
        self.compositionError = compositionError
        self.retryComposition = retryComposition
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text(locale.text(
                "Session Recovery Required", zh: "需要恢复会话"
            )).font(.title2.bold())
            Text(recoveryMessage)
                .accessibilityIdentifier(AppAccessibility.id(
                    "startup recovery error"
                ))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack {
                Button(locale.text("Retry", zh: "重试")) {
                    if let retryComposition { retryComposition() }
                    else {
                        controller.retry()
                        openRecoveredWindows()
                    }
                }
                .accessibilityIdentifier(AppAccessibility.id(
                    "startup recovery retry"
                ))
                if compositionError == nil,
                   controller.hasFailedCommittedTransaction {
                    Button(locale.text(
                        "Preserve Recovery Data and Use Previous Snapshots",
                        zh: "保留恢复数据并使用上一版快照"
                    )) {
                        controller.preserveTransactionAndUseCanonicalSnapshots()
                        retryComposition?()
                        openRecoveredWindows()
                    }
                    .accessibilityIdentifier(AppAccessibility.id(
                        "startup recovery canonical"
                    ))
                }
            }
            if controller.plan != nil {
                Button(locale.text(
                    "Open Recovered Windows", zh: "打开已恢复窗口"
                ), action: openRecoveredWindows)
            }
            if let url = controller.preservedArchiveURL {
                Text(locale.text(
                    "Recovery artifacts preserved at \(url.path)",
                    zh: "恢复资料已保留在 \(url.path)"
                ))
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 320)
    }

    private var locale: EditorLocale { settings.locale }

    private func openRecoveredWindows() {
        guard let plan = controller.plan else { return }
        for value in plan.all { openWindow(value: value) }
    }

    private var recoveryMessage: String {
        if let compositionError {
            if compositionError as? WindowSessionCoordinatorError
                != .terminationRecoveryFailed {
                return compositionError.localizedDescription
            }
            return locale.text(
                "The editor window could not be opened safely. Retry, or preserve the recovery data and use the previous snapshots.",
                zh: "无法安全打开编辑器窗口。请重试，或保留恢复数据并使用上一版快照。"
            )
        }
        if controller.error as? WindowSessionCoordinatorError
            == .terminationRecoveryFailed {
            return locale.text(
                "The committed session could not be recovered safely. Retry, or preserve the recovery data and use the previous snapshots.",
                zh: "无法安全恢复已提交的会话。请重试，或保留恢复数据并使用上一版快照。"
            )
        }
        if let error = controller.error { return error.localizedDescription }
        return locale.text(
            "The committed session could not be recovered safely. Retry, or preserve the recovery data and use the previous snapshots.",
            zh: "无法安全恢复已提交的会话。请重试，或保留恢复数据并使用上一版快照。"
        )
    }
}

@MainActor
private struct SettingsWindowRoot: View {
    @ObservedObject var controller: SettingsController
    @ObservedObject var updateController: UpdateController
    let applicationDelegate: LumenApplicationDelegate

    var body: some View {
        SettingsView(controller: controller)
            .onAppear {
                applicationDelegate.bindMenuLocalization(to: controller)
            }
            .onChange(of: controller.locale, initial: true) { _, locale in
                applicationDelegate.updateMenuLocale(locale)
            }
            .sheet(isPresented: updatePresentationBinding) {
                UpdateView(controller: updateController) {
                    updateController.dismiss()
                }
                .appLocale(controller.locale)
                .preferredColorScheme(controller.preferredColorScheme)
            }
            .onDisappear { updateController.dismiss() }
    }

    private var updatePresentationBinding: Binding<Bool> {
        Binding(
            get: { updateController.isPresented },
            set: { if !$0 { updateController.dismiss() } }
        )
    }
}

@MainActor
private final class EditorWindowSceneOwner: ObservableObject {
    @Published private(set) var composition: EditorWindowComposition?
    @Published private(set) var error: (any Error)?
    private let sceneValue: WindowSessionSceneValue
    private let coordinator: WindowSessionCoordinator
    private let settings: SettingsController

    init(
        sceneValue: WindowSessionSceneValue,
        coordinator: WindowSessionCoordinator,
        settings: SettingsController
    ) {
        self.sceneValue = sceneValue
        self.coordinator = coordinator
        self.settings = settings
        retry()
    }

    func retry() {
        do {
            let session = try coordinator.composition(for: sceneValue)
            composition = EditorWindowComposition(
                session: session, settings: settings
            )
            error = nil
        } catch {
            composition = nil
            self.error = error
        }
    }
}

@MainActor
private struct EditorWindowSceneHost: View {
    @Environment(\.openWindow) private var openWindow
    let applicationDelegate: LumenApplicationDelegate
    let coordinator: WindowSessionCoordinator
    let settings: SettingsController
    let startupPlan: WindowSessionStartupPlan
    @ObservedObject var startupRecovery: StartupRecoveryController
    let startupAdditional: [WindowSessionSceneValue]
    @StateObject private var owner: EditorWindowSceneOwner
    @State private var didRestoreAdditionalWindows = false

    init(
        sceneValue: WindowSessionSceneValue,
        startupPlan: WindowSessionStartupPlan,
        startupRecovery: StartupRecoveryController,
        coordinator: WindowSessionCoordinator,
        settings: SettingsController,
        applicationDelegate: LumenApplicationDelegate
    ) {
        self.applicationDelegate = applicationDelegate
        self.coordinator = coordinator
        self.settings = settings
        self.startupPlan = startupPlan
        self.startupRecovery = startupRecovery
        startupAdditional = sceneValue.id == startupPlan.primary.id
            ? startupPlan.additional : []
        _owner = StateObject(wrappedValue: EditorWindowSceneOwner(
            sceneValue: sceneValue,
            coordinator: coordinator,
            settings: settings
        ))
    }

    var body: some View {
        Group {
            if let composition = owner.composition {
                EditorWindowScene(
                    composition: composition,
                    settings: composition.settings,
                    applicationDelegate: applicationDelegate,
                    sessionCoordinator: coordinator
                )
            } else {
                StartupRecoveryView(
                    controller: startupRecovery,
                    settings: settings,
                    compositionError: owner.error,
                    retryComposition: { owner.retry() }
                )
            }
        }
        .onAppear {
            configureIfReady()
        }
        .onChange(of: owner.composition != nil) { _, _ in
            configureIfReady()
        }
    }

    private func configureIfReady() {
        guard owner.composition != nil else { return }
        applicationDelegate.bindMenuLocalization(to: settings)
        applicationDelegate.openNewWindow = {
            guard let value = try? coordinator.newSceneValue() else { return }
            openWindow(value: value)
        }
        applicationDelegate.beginTerminationPersistenceTransaction = { ids in
            coordinator.beginTerminationTransaction(expectedWindowIDs: ids)
        }
        applicationDelegate.commitTerminationPersistenceTransaction = {
            coordinator.commitTerminationTransaction()
        }
        applicationDelegate.abortTerminationPersistenceTransaction = {
            coordinator.abortTerminationTransaction()
        }
        applicationDelegate.finalizeTerminationPersistenceTransaction = {
            coordinator.finalizeCommittedTerminationTransaction()
        }
        guard !didRestoreAdditionalWindows else { return }
        didRestoreAdditionalWindows = true
        for value in startupAdditional { openWindow(value: value) }
    }
}

private struct EditorWindowCompositionKey: FocusedValueKey {
    typealias Value = EditorWindowComposition
}

private extension FocusedValues {
    var editorWindowComposition: EditorWindowComposition? {
        get { self[EditorWindowCompositionKey.self] }
        set { self[EditorWindowCompositionKey.self] = newValue }
    }
}

@MainActor
private struct FocusedEditorCommands: Commands {
    @FocusedValue(\.editorWindowComposition) private var composition
    let coordinator: WindowSessionCoordinator
    @ObservedObject var settings: SettingsController
    @ObservedObject var settingsOnlyUpdateController: UpdateController

    var body: some Commands {
        if let composition {
            EditorCommands(
                newWindow: {
                    composition.openNewWindow()
                },
                model: composition.model,
                actions: composition.actions,
                settings: composition.settings,
                workspace: composition.workspace,
                router: composition.commandRouter,
                workspaceSearch: composition.workspaceSearch,
                git: composition.gitController,
                build: composition.buildController,
                terminal: composition.terminalController,
                navigation: composition.navigationController,
                languageServers: composition.languageServerController
            )
        } else {
            SettingsOnlyCommands(
                coordinator: coordinator, settings: settings,
                updateController: settingsOnlyUpdateController
            )
        }
    }
}

/// The application-level menu that remains usable when a Settings or update
/// window is focused and there is no focused editor composition. AppKit keeps
/// ownership of the Services submenu; the surrounding standard application
/// actions are explicit so replacing the focused editor command tree cannot
/// make them disappear. Editor/document routes are intentionally absent.
@MainActor
struct SettingsOnlyCommands: Commands {
    static let newWindowCommandID = "new-window"
    static let openSettingsCommandID = "open-settings"
    static let checkUpdatesCommandID = "check-for-updates"
    static let simplifiedChineseCommandID = "set-ui-language-zh"
    static let englishCommandID = "set-ui-language-en"

    /// Testable allow-list for the commands exposed without an editor.
    static let commandIDs = [
        newWindowCommandID, openSettingsCommandID, checkUpdatesCommandID,
        simplifiedChineseCommandID, englishCommandID
    ]

    /// `.systemServices` must remain untouched so AppKit continues to manage
    /// the Services submenu and its dynamically supplied service items.
    static let preservesSystemServices = true
    static let replacesSettingsPlacement = true

    static let standardApplicationActions: [Selector] = [
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        #selector(NSApplication.hide(_:)),
        #selector(NSApplication.hideOtherApplications(_:)),
        #selector(NSApplication.unhideAllApplications(_:)),
        #selector(NSApplication.terminate(_:))
    ]
    static let standardWindowActions: [Selector] = [
        #selector(NSWindow.performMiniaturize(_:)),
        #selector(NSWindow.performZoom(_:)),
        EditorCommands.toggleFullScreenAction,
        #selector(NSApplication.arrangeInFront(_:))
    ]

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let coordinator: WindowSessionCoordinator
    @ObservedObject var settings: SettingsController
    @ObservedObject var updateController: UpdateController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(commandTitle(Self.newWindowCommandID), action: openNewWindow)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(settings.isApplicationTerminationCommitted)
                .accessibilityIdentifier(AppAccessibility.id("menu command new-window"))
        }

        CommandGroup(replacing: .appSettings) {
            Button(commandTitle(Self.openSettingsCommandID)) { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(settings.isApplicationTerminationCommitted)
                .accessibilityIdentifier(AppAccessibility.id("menu command open-settings"))

            Menu(settings.locale.text("Interface Language", zh: "界面语言")) {
                localeButton(.zhCN, commandID: Self.simplifiedChineseCommandID)
                localeButton(.enUS, commandID: Self.englishCommandID)
            }
            .disabled(settings.isApplicationTerminationCommitted)
            .accessibilityIdentifier(AppAccessibility.id("menu interface language"))
        }

        CommandGroup(after: .help) {
            Button(commandTitle(Self.checkUpdatesCommandID), action: checkForUpdates)
                .disabled(
                    updateController.isChecking
                        || settings.isApplicationTerminationCommitted
                )
                .accessibilityIdentifier(AppAccessibility.id(
                    "menu command check-for-updates"
                ))
        }

        CommandGroup(replacing: .appInfo) {
            Button(settings.locale.localizedApp(.aboutApp(appName: appName))) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu about app"))
        }

        // Do not replace `.systemServices`: AppKit owns NSApp.servicesMenu and
        // populates its contents according to the current first responder.
        CommandGroup(replacing: .appVisibility) {
            Button(settings.locale.localizedApp(.hideApp(appName: appName))) {
                NSApp.hide(nil)
            }
            .keyboardShortcut("h", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu hide app"))

            Button(settings.locale.localizedApp(.hideOthers)) {
                NSApp.hideOtherApplications(nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .accessibilityIdentifier(AppAccessibility.id("menu hide others"))

            Button(settings.locale.localizedApp(.showAll)) {
                NSApp.unhideAllApplications(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu show all"))
        }

        CommandGroup(replacing: .appTermination) {
            Button(settings.locale.localizedApp(.quitApp(appName: appName))) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu quit app"))
        }

        CommandGroup(replacing: .windowArrangement) {
            Button(settings.locale.localizedApp(.minimize)) {
                NSApp.keyWindow?.performMiniaturize(nil)
            }
            .keyboardShortcut("m", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu window minimize"))

            Button(settings.locale.localizedApp(.zoom)) {
                NSApp.keyWindow?.performZoom(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu window zoom"))

            Button(settings.locale.localizedApp(.toggleFullScreen)) {
                NSApp.sendAction(
                    EditorCommands.toggleFullScreenAction, to: nil, from: nil
                )
            }
            .keyboardShortcut(EditorCommands.toggleFullScreenShortcut)
            .disabled(!canToggleFullScreen)
            .accessibilityIdentifier(AppAccessibility.id(
                "menu window toggle full screen"
            ))

            Divider()

            Button(settings.locale.localizedApp(.bringAllToFront)) {
                NSApp.arrangeInFront(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id(
                "menu window arrange in front"
            ))
        }
    }

    static func commandTitle(_ commandID: String, locale: EditorLocale) -> String {
        CommandCatalog.command(id: commandID)?.name(for: locale.commandLocale)
            ?? commandID
    }

    private var appName: String {
        settings.locale.localizedApp(.systemAppName)
    }

    private var canToggleFullScreen: Bool {
        let action = EditorCommands.toggleFullScreenAction
        return EditorCommands.systemActionIsEnabled(
            action, target: NSApp.target(forAction: action)
        )
    }

    private func commandTitle(_ commandID: String) -> String {
        Self.commandTitle(commandID, locale: settings.locale)
    }

    private func openNewWindow() {
        guard let value = try? coordinator.newSceneValue() else { return }
        openWindow(value: value)
    }

    private func checkForUpdates() {
        openSettings()
        Task { await updateController.presentAndCheck() }
    }

    @ViewBuilder
    private func localeButton(
        _ locale: EditorLocale, commandID: String
    ) -> some View {
        Button {
            settings.set(locale, for: \.locale)
        } label: {
            Label(
                commandTitle(commandID),
                systemImage: settings.locale == locale ? "checkmark" : "circle"
            )
        }
        .disabled(settings.locale == locale)
        .accessibilityIdentifier(AppAccessibility.id("menu command \(commandID)"))
    }

}

@MainActor
final class NewWindowRelay {
    var action: (() -> Void)?

    func perform() { action?() }
}

@MainActor
final class WorkspaceMutationRelay {
    private let model: AppModel
    weak var navigationController: NavigationController?

    init(model: AppModel) {
        self.model = model
    }

    func apply(_ event: WorkspaceMutationEvent) throws {
        var coordinationError: (any Error)?
        do {
            try model.applyWorkspaceMutation(event)
        } catch {
            coordinationError = error
        }
        switch event {
        case let .renamed(from, to), let .moved(from, to):
            navigationController?.pathDidMove(from: from, to: to)
        case .created, .trashed:
            break
        }
        if let coordinationError { throw coordinationError }
    }
}

@MainActor
private final class CommandKeyboardRelay {
    weak var controller: CommandKeyboardController?

    func setOverrides(_ overrides: [KeyBindingOverride]) {
        controller?.setOverrides(overrides)
    }
}

@MainActor
private func installApplicationCommandHandlers(
    on router: CommandRouter,
    model: AppModel,
    actions: EditorActionController,
    workspace: WorkspaceController,
    settings: SettingsController,
    workspaceSearch: WorkspaceSearchController,
    navigation: NavigationController,
    git: GitController,
    build: BuildController,
    terminal: TerminalController,
    preview: PreviewController,
    languageServers: LanguageServerController,
    plugins: PluginController,
    projectSettings: ProjectSettingsController,
    newWindow: @escaping @MainActor () -> Void
) {

    func register(
        _ commandID: String,
        preparesTransientUI: Bool = true,
        enablement: @escaping CommandRouter.Enablement = { _ in .enabled },
        handler: @escaping CommandRouter.Handler
    ) {
        do {
            _ = try router.register(
                commandID,
                enablement: enablement,
                handler: { invocation in
                    if preparesTransientUI { await actions.prepareForRoutedCommand() }
                    try await handler(invocation)
                }
            )
        } catch {
            actions.presentIssue(
                title: "Could Not Configure Commands",
                message: "\(commandID): \(error.localizedDescription)"
            )
        }
    }

    func commandSignal(for outcome: EditorActionOutcome) throws {
        switch outcome {
        case .completed:
            return
        case .cancelled:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            throw CommandHandlerSignal.failed(message)
        case let .failedPresentation(content):
            if case .appModel = content { model.clearPresentedIssue() }
            throw CommandHandlerSignal.failed(content)
        }
    }

    func commandSignalForVisiblePanel(
        _ outcome: EditorActionOutcome
    ) throws {
        switch outcome {
        case .completed:
            throw CommandHandlerSignal.visiblePanel
        case .cancelled:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            throw CommandHandlerSignal.failed(message)
        case let .failedPresentation(content):
            if case .appModel = content { model.clearPresentedIssue() }
            throw CommandHandlerSignal.failed(content)
        }
    }

    let documentIsIdle: CommandRouter.Enablement = { _ in
        guard let document = model.selectedDocument, !document.isSaving else {
            return .disabled(reason: "No editable document is active.")
        }
        return !actions.canExecutePanelCommand
            ? .disabled(reason: "Finish the current interaction first.")
            : .enabled
    }
    let applicationIsIdle: CommandRouter.Enablement = { _ in
        actions.canExecuteRoutedCommand
            ? .enabled
            : .disabled(reason: "Finish the current interaction first.")
    }
    let nonModalCommandIsIdle: CommandRouter.Enablement = { _ in
        actions.canExecuteRoutedCommand
            ? .enabled
            : .disabled(reason: "Finish the current interaction first.")
    }

    register("new-file", enablement: applicationIsIdle) { _ in
        actions.newDocument()
    }
    do {
        _ = try router.register(
            "new-window", replaceExisting: true, enablement: applicationIsIdle
        ) { _ in
            newWindow()
        }
    } catch {
        actions.presentIssue(
            title: "Could Not Configure Commands",
            message: "new-window: \(error.localizedDescription)"
        )
    }
    register("open-file", enablement: applicationIsIdle) { _ in
        guard await actions.openDocuments() else {
            if let issue = model.presentedIssue {
                model.clearPresentedIssue()
                throw CommandHandlerSignal.failed(.appModel(issue))
            }
            if let issue = actions.presentedIssue {
                let presentation: CommandPresentation
                if case let .command(content) = issue.content {
                    presentation = content
                } else {
                    presentation = CommandPresentation(issue.message)
                }
                actions.dismissActionIssue()
                throw CommandHandlerSignal.failed(presentation)
            }
            throw CommandHandlerSignal.noChange
        }
    }
    register("open-folder", enablement: applicationIsIdle) { _ in
        guard await actions.openWorkspaceFolder() else {
            if let issue = workspace.issue {
                throw CommandHandlerSignal.failed(.workspace(issue.content))
            }
            throw CommandHandlerSignal.noChange
        }
    }
    register("add-folder-to-project", enablement: { context in
        guard !workspace.roots.isEmpty else {
            return .disabled(reason: "Open a workspace before adding another folder.")
        }
        return applicationIsIdle(context)
    }) { _ in
        guard await actions.addWorkspaceFolder() else {
            if let issue = workspace.issue {
                throw CommandHandlerSignal.failed(.workspace(issue.content))
            }
            throw CommandHandlerSignal.noChange
        }
    }
    register("remove-folder-from-project", enablement: { context in
        guard !workspace.roots.isEmpty else {
            return .disabled(reason: "There is no project folder to remove.")
        }
        return applicationIsIdle(context)
    }) { _ in
        let locale = settings.settings.locale
        let alert = NSAlert()
        alert.messageText = locale.localizedApp(.removeFolderFromProject)
        alert.informativeText = locale.localizedApp(.chooseFolderToRemove)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for root in workspace.roots { popup.addItem(withTitle: root.url.path) }
        alert.accessoryView = popup
        alert.addButton(withTitle: locale.localizedApp(.remove))
        alert.addButton(withTitle: locale.localized(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn,
              workspace.roots.indices.contains(popup.indexOfSelectedItem) else {
            throw CommandHandlerSignal.noChange
        }
        guard await workspace.removeRoot(
            workspace.roots[popup.indexOfSelectedItem]
        ) else {
            if let issue = workspace.issue {
                throw CommandHandlerSignal.failed(.workspace(issue.content))
            }
            throw CommandHandlerSignal.noChange
        }
        actions.synchronizeWorkspaceSession()
    }
    register("save", enablement: documentIsIdle) { _ in
        try commandSignal(for: await actions.saveCurrentDocumentOutcome())
    }
    register("save-as", enablement: documentIsIdle) { _ in
        try commandSignal(for: await actions.saveCurrentDocumentAsOutcome())
    }
    register("save-all", enablement: { _ in
        guard actions.canExecutePanelCommand else {
            return .disabled(reason: "Finish the current interaction first.")
        }
        return model.hasDirtyDocuments
            ? .enabled
            : .disabled(reason: "There are no unsaved documents.")
    }) { _ in
        try commandSignal(for: await actions.saveAllDocumentsOutcome())
    }
    register("close-tab", enablement: documentIsIdle) { _ in
        guard actions.requestCloseCurrentDocument() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("toggle-pin-tab", enablement: documentIsIdle) { _ in
        guard actions.togglePinForCurrentTab() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("close-other-tabs", enablement: { context in
        guard actions.canCloseOtherTabs else {
            return .disabled(reason: "There are no other tabs to close.")
        }
        return documentIsIdle(context)
    }) { _ in
        guard actions.requestCloseOtherTabs() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("close-tabs-to-right", enablement: { context in
        guard actions.canCloseTabsToRight else {
            return .disabled(reason: "There are no tabs to the right.")
        }
        return documentIsIdle(context)
    }) { _ in
        guard actions.requestCloseTabsToRight() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("close-all-tabs", enablement: { context in
        guard actions.canCloseAllTabs else {
            return .disabled(reason: "There are no tabs to close.")
        }
        return documentIsIdle(context)
    }) { _ in
        guard actions.requestCloseAllTabs() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("reopen-tab", enablement: { context in
        guard model.canReopenClosedTab else {
            return .disabled(reason: "There is no recently closed tab.")
        }
        return applicationIsIdle(context)
    }) { _ in
        guard await actions.reopenClosedTab() else {
            throw CommandHandlerSignal.noChange
        }
    }
    // DocumentFormatController is the sole owner of the four interactive
    // encoding/line-ending palettes. Registering fallback handlers here would
    // silently turn them into fixed-UTF-8 or no-op commands if composition
    // ordering ever changed.
    for (commandID, lineEnding) in [
        ("convert-eol-lf", LineEnding.lf),
        ("convert-eol-crlf", LineEnding.crlf),
        ("convert-eol-cr", LineEnding.cr)
    ] {
        register(commandID, enablement: documentIsIdle) { _ in
            guard let document = model.selectedDocument else {
                throw CommandHandlerSignal.unavailable(
                    reason: "No editable document is active."
                )
            }
            guard actions.chooseLineEndingForSave(
                lineEnding, document: document
            ) else { throw CommandHandlerSignal.noChange }
        }
    }
    register("copy-file-path", enablement: { context in
        guard model.selectedDocument?.fileURL != nil else {
            return .disabled(reason: "The active document has no file path.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        guard let path = model.selectedDocument?.fileURL?.path else {
            throw CommandHandlerSignal.unavailable(
                reason: "The active document has no file path."
            )
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(path, forType: .string) else {
            throw CommandHandlerSignal.failed("The file path could not be copied.")
        }
    }
    register("copy-relative-file-path", enablement: { context in
        guard let url = model.selectedDocument?.fileURL,
              workspace.roots.contains(where: {
                url.standardizedFileURL.path == $0.url.standardizedFileURL.path
                    || url.standardizedFileURL.path.hasPrefix(
                        $0.url.standardizedFileURL.path + "/"
                    )
              }) else {
            return .disabled(reason: "The active file is outside the workspace.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        guard let url = model.selectedDocument?.fileURL else {
            throw CommandHandlerSignal.unavailable(
                reason: "The active document has no file path."
            )
        }
        guard await workspace.copyPath(url, relativeToWorkspace: true) else {
            throw CommandHandlerSignal.noChange
        }
    }

    register("command-palette", enablement: { context in
        if actions.isAnyTransientPanelPresented {
            return .disabled(reason: "The command palette is already open.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        actions.presentCommandPalette()
    }
    register("toggle-sidebar", enablement: nonModalCommandIsIdle) { _ in
        workspace.toggleSidebar()
    }
    register("reveal-active-file-in-sidebar", enablement: nonModalCommandIsIdle) { _ in
        guard await workspace.revealActiveFile(
            model.selectedDocument?.fileURL,
            prepareSidebar: { runtimeSettingsBridge.prepareSidebarReveal() }
        ) else {
            if let issue = workspace.issue {
                throw CommandHandlerSignal.failed(.workspace(issue.content))
            }
            if settings.persistenceIssue != nil {
                throw CommandHandlerSignal.failed(
                    "Distraction-free mode could not be disabled because settings could not be saved."
                )
            }
            throw CommandHandlerSignal.noChange
        }
    }

    register("layout-single", enablement: nonModalCommandIsIdle) { _ in
        guard model.setLayout(.single) else { throw CommandHandlerSignal.noChange }
    }
    register("layout-columns2", enablement: nonModalCommandIsIdle) { _ in
        guard model.setLayout(.columns2) else { throw CommandHandlerSignal.noChange }
    }
    register("layout-columns3", enablement: nonModalCommandIsIdle) { _ in
        guard model.setLayout(.columns3) else { throw CommandHandlerSignal.noChange }
    }
    register("layout-grid4", enablement: nonModalCommandIsIdle) { _ in
        guard model.setLayout(.grid4) else { throw CommandHandlerSignal.noChange }
    }
    register("split-editor", enablement: documentIsIdle) { _ in
        guard model.toggleSplit() else { throw CommandHandlerSignal.noChange }
    }
    register("split-selected-tabs", enablement: documentIsIdle) { _ in
        guard model.splitSelectedTabs() else { throw CommandHandlerSignal.noChange }
    }
    register("move-file-next-group", enablement: documentIsIdle) { _ in
        guard model.moveActiveDocumentToNextPane() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("clone-file-next-group", enablement: documentIsIdle) { _ in
        guard model.cloneActiveDocumentToNextPane() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("focus-next-group", enablement: nonModalCommandIsIdle) { _ in
        guard model.focusNextPane() else { throw CommandHandlerSignal.noChange }
    }
    register("focus-prev-group", enablement: nonModalCommandIsIdle) { _ in
        guard model.focusPreviousPane() else { throw CommandHandlerSignal.noChange }
    }
    register("next-tab", enablement: documentIsIdle) { _ in
        let before = model.selectedDocument?.sessionDocumentID
        guard let after = model.cycleActiveDocument(by: 1),
              after.sessionDocumentID != before else { throw CommandHandlerSignal.noChange }
    }
    register("prev-tab", enablement: documentIsIdle) { _ in
        let before = model.selectedDocument?.sessionDocumentID
        guard let after = model.cycleActiveDocument(by: -1),
              after.sessionDocumentID != before else { throw CommandHandlerSignal.noChange }
    }

    let workspacePanelIsIdle: CommandRouter.Enablement = { context in
        guard !workspaceSearch.isPresented, !workspaceSearch.isBusy else {
            return .disabled(reason: "Workspace search is already open.")
        }
        return nonModalCommandIsIdle(context)
    }
    register("find-in-files", enablement: workspacePanelIsIdle) { _ in
        actions.presentTransientPanel(.workspaceSearch)
        workspaceSearch.show(mode: .find)
    }
    register("replace-in-files", enablement: workspacePanelIsIdle) { _ in
        actions.presentTransientPanel(.workspaceSearch)
        workspaceSearch.show(mode: .replace)
    }
    register("undo-replace-in-files", enablement: { context in
        guard workspaceSearch.canUndo else {
            return .disabled(reason: "There is no workspace replacement to undo.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        guard workspaceSearch.undoLastReplacement() else {
            throw CommandHandlerSignal.noChange
        }
        await workspaceSearch.waitForCurrentOperation()
        guard case .undone = workspaceSearch.status else {
            if let issue = workspaceSearch.issue {
                throw CommandHandlerSignal.failed(.workspaceSearch(issue.content))
            }
            throw CommandHandlerSignal.noChange
        }
    }
    register("find-results-next", enablement: applicationIsIdle) { _ in
        guard workspaceSearch.moveResult(by: 1) != nil,
              await workspaceSearch.navigateToSelectedResult() else {
            throw CommandHandlerSignal.noChange
        }
    }
    register("find-results-prev", enablement: applicationIsIdle) { _ in
        guard workspaceSearch.moveResult(by: -1) != nil,
              await workspaceSearch.navigateToSelectedResult() else {
            throw CommandHandlerSignal.noChange
        }
    }

    register("toggle-git", preparesTransientUI: false, enablement: { context in
        return nonModalCommandIsIdle(context)
    }) { _ in
        actions.toggleTransientPanel(.git)
        if actions.isGitPanelPresented, !(await git.refresh()), let issue = git.issue {
            throw CommandHandlerSignal.failed(.git(issue))
        }
    }
    let gitIsIdle: CommandRouter.Enablement = { context in
        guard git.isRepositoryAvailable else {
            return .disabled(reason: "The primary workspace is not a Git repository.")
        }
        return applicationIsIdle(context)
    }
    register("refresh-git", enablement: gitIsIdle) { _ in
        guard await git.refresh() else {
            let issue = git.issue ?? GitPresentationIssue(
                title: .operationFailed, content: .app(.statusRefreshFailed)
            )
            throw CommandHandlerSignal.failed(.git(issue))
        }
    }
    register("open-git-conflicts", enablement: gitIsIdle) { _ in
        switch await git.openAllWorktreeConflicts() {
        case .opened:
            actions.presentGitPanel()
            throw CommandHandlerSignal.visiblePanel
        case .noChange:
            actions.presentNotice(
                "No merge conflicts were detected in the current repository."
            )
            throw CommandHandlerSignal.noChange
        case let .failed(openedCount):
            let issue = git.issue ?? GitPresentationIssue(
                title: .openConflicts,
                content: .app(.openAllConflictsFailed(openedCount: openedCount))
            )
            throw CommandHandlerSignal.failed(.git(issue))
        }
    }

    register("build", enablement: { context in
        guard build.canRunPrimaryAction else {
            return .disabled(reason: "A workspace build is unavailable right now.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        actions.presentBuildPanel()
        await Task.yield()
        switch await build.runPrimaryAction() {
        case .started, .awaitingApproval:
            throw CommandHandlerSignal.visiblePanel
        case .unavailable:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            throw CommandHandlerSignal.failed(message)
        }
    }
    register("select-build-system", enablement: { context in
        guard build.workspaceRoot != nil else {
            return .disabled(reason: "Open a workspace before selecting a build system.")
        }
        guard !NativeFeatureCoordinator.buildSystems(
            from: projectSettings.settings
        ).isEmpty else {
            return .disabled(reason: "No build systems are configured.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        let systems = NativeFeatureCoordinator.buildSystems(
            from: projectSettings.settings
        )
        guard build.presentBuildSystemPalette(buildSystems: systems) else {
            throw CommandHandlerSignal.noChange
        }
        actions.presentBuildSystemPalette()
    }
    register("toggle-problems", preparesTransientUI: false, enablement: { context in
        return nonModalCommandIsIdle(context)
    }) { _ in
        actions.toggleTransientPanel(.build)
    }
    register("toggle-terminal", preparesTransientUI: false, enablement: { context in
        guard terminal.workspaceRoot != nil else {
            return .disabled(reason: "Open a workspace before using the terminal.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        let shouldStart = !actions.isTerminalPanelPresented && terminal.canStart
        actions.toggleTransientPanel(.terminal)
        if shouldStart { await terminal.requestStart() }
    }

    register("toggle-line-numbers", enablement: nonModalCommandIsIdle) { _ in
        settings.toggleLineNumbers()
    }
    register("toggle-word-wrap", enablement: nonModalCommandIsIdle) { _ in
        settings.toggleWordWrap()
    }
    register("toggle-theme", enablement: nonModalCommandIsIdle) { _ in
        settings.toggleTheme()
    }
    register("toggle-spell-check", enablement: nonModalCommandIsIdle) { _ in
        settings.set(!settings.settings.spellCheck, for: \.spellCheck)
    }
    register("toggle-minimap", enablement: nonModalCommandIsIdle) { _ in
        settings.set(!settings.settings.showMinimap, for: \.showMinimap)
    }
    register("toggle-whitespace", enablement: nonModalCommandIsIdle) { _ in
        settings.set(!settings.settings.showWhitespace, for: \.showWhitespace)
    }
    register("toggle-outline", enablement: nonModalCommandIsIdle) { _ in
        settings.set(!settings.settings.showOutline, for: \.showOutline)
    }
    register("toggle-distraction-free", enablement: nonModalCommandIsIdle) { _ in
        settings.set(!settings.settings.distractionFree, for: \.distractionFree)
    }
    register("cycle-auto-save", enablement: nonModalCommandIsIdle) { _ in
        let next: AutoSaveMode
        switch settings.settings.autoSave {
        case .off: next = .afterDelay
        case .afterDelay: next = .onFocusChange
        case .onFocusChange: next = .off
        }
        settings.set(next, for: \.autoSave)
    }
    register("set-ui-language-zh", enablement: nonModalCommandIsIdle) { _ in
        settings.set(.zhCN, for: \.locale)
    }
    register("set-ui-language-en", enablement: nonModalCommandIsIdle) { _ in
        settings.set(.enUS, for: \.locale)
    }
    register("open-settings", enablement: applicationIsIdle) { _ in
        NotificationCenter.default.post(name: .lumenOpenSettings, object: nil)
    }

    let previewAvailable: CommandRouter.Enablement = { _ in
        guard model.selectedDocument != nil else {
            return .disabled(reason: "No active document.")
        }
        return actions.canExecutePanelCommand
            ? .enabled : .disabled(reason: "Finish the current interaction first.")
    }
    register("toggle-preview", enablement: previewAvailable) { _ in
        guard let document = model.selectedDocument else {
            throw CommandHandlerSignal.unavailable(reason: "No active document.")
        }
        guard NativeFeatureCoordinator.isMarkdown(document) || preview.isMarkdownPreviewVisible else {
            actions.presentIssue(
                title: "Markdown Preview Unavailable",
                message: "Save the file with a Markdown extension or select Markdown syntax first."
            )
            throw CommandHandlerSignal.noChange
        }
        _ = preview.toggleMarkdownPreview(source: document.buffer.text)
    }
    let jsonAvailable: CommandRouter.Enablement = { _ in
        guard let document = model.selectedDocument,
              NativeFeatureCoordinator.isJSON(document) else {
            return .disabled(reason: "The active document is not JSON.")
        }
        return actions.canExecutePanelCommand
            ? .enabled : .disabled(reason: "Finish the current interaction first.")
    }
    register("toggle-json-view", enablement: jsonAvailable) { _ in
        guard let document = model.selectedDocument else {
            throw CommandHandlerSignal.unavailable(reason: "No active document.")
        }
        _ = preview.toggleJSONView(source: document.buffer.text)
    }
    register("format-json", enablement: jsonAvailable) { _ in
        guard let document = model.selectedDocument else {
            throw CommandHandlerSignal.unavailable(reason: "No active document.")
        }
        guard preview.formatJSON(
            source: document.buffer.text, expectedRevision: document.buffer.revision
        ) else { throw CommandHandlerSignal.noChange }
    }
    register("compact-json", enablement: jsonAvailable) { _ in
        guard let document = model.selectedDocument else {
            throw CommandHandlerSignal.unavailable(reason: "No active document.")
        }
        guard preview.compactJSON(
            source: document.buffer.text, expectedRevision: document.buffer.revision
        ) else { throw CommandHandlerSignal.noChange }
    }

    register("document-statistics", enablement: documentIsIdle) { _ in
        guard let document = model.selectedDocument else {
            throw CommandHandlerSignal.unavailable(reason: "No active document.")
        }
        let whole = TextTransforms.textStatistics(document.buffer.text)
        let selection = model.selection(
            for: document.sessionDocumentID, viewID: model.paneLayout.activeViewID
        ).main
        let selectedText = selection.isEmpty ? nil : (document.buffer.text as NSString)
            .substring(with: selection.range)
        let selected = selectedText.map(TextTransforms.textStatistics)
        let describe: (TextStatistics) -> String = { value in
            "Lines: \(value.lines)\nCharacters: \(value.characters)\n"
                + "Characters (excluding whitespace): \(value.charactersExcludingWhitespace)\n"
                + "Words / tokens: \(value.words)"
        }
        actions.presentIssue(
            title: "Document Statistics",
            message: "Document\n\(describe(whole))"
                + (selected.map { "\n\nSelection\n" + describe($0) } ?? "")
        )
    }

    let workspacePluginsAvailable: CommandRouter.Enablement = { context in
        guard plugins.workspaceURL != nil else {
            return .disabled(reason: "Open a workspace first.")
        }
        return nonModalCommandIsIdle(context)
    }
    register("manage-plugins", enablement: workspacePluginsAvailable) { _ in
        actions.presentTransientPanel(.plugins)
    }
    register("install-plugin", enablement: workspacePluginsAvailable) { _ in
        let outcome = await actions.installLocalPlugin(
            using: plugins, locale: settings.settings.locale
        )
        switch outcome {
        case .completed:
            actions.presentTransientPanel(.plugins)
            throw CommandHandlerSignal.visiblePanel
        case .cancelled:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            if let issue = plugins.issue, issue.message == message {
                throw CommandHandlerSignal.failed(.plugin(issue.content))
            }
            throw CommandHandlerSignal.failed(message)
        case let .failedPresentation(content):
            throw CommandHandlerSignal.failed(content)
        }
    }
    register("open-marketplace", enablement: workspacePluginsAvailable) { _ in
        actions.presentTransientPanel(.marketplace)
    }
    register("toggle-language-servers", preparesTransientUI: false, enablement: { context in
        guard !workspace.roots.isEmpty else {
            return .disabled(reason: "Open a workspace first.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        actions.toggleTransientPanel(.languageServers)
    }
    register("project-settings", enablement: { context in
        guard !workspace.roots.isEmpty else {
            return .disabled(reason: "Open a workspace first.")
        }
        return nonModalCommandIsIdle(context)
    }) { _ in
        projectSettings.present()
        actions.presentTransientPanel(.projectSettings)
    }
    let lspAvailable: CommandRouter.Enablement = { _ in
        guard let document = model.selectedDocument, document.fileURL != nil,
              NativeFeatureCoordinator.languageServerConfig(
                for: document, project: model.sessionProject
              ) != nil else {
            return .disabled(reason: "No language server is configured for this document.")
        }
        return actions.canExecutePanelCommand
            ? .enabled : .disabled(reason: "Finish the current interaction first.")
    }
    let symbolNavigationAvailable: CommandRouter.Enablement = { _ in
        guard model.selectedDocument?.fileURL != nil, !workspace.roots.isEmpty else {
            return .disabled(
                reason: "Open a saved file in a workspace before using symbol navigation."
            )
        }
        return actions.canExecutePanelCommand
            ? .enabled : .disabled(reason: "Finish the current interaction first.")
    }
    func selectedIdentifier() -> String? {
        guard let document = model.selectedDocument else { return nil }
        let selection = model.selection(
            for: document.sessionDocumentID,
            viewID: model.paneLayout.activeViewID
        )
        return NativeFeatureCoordinator.selectedIdentifier(
            in: document.buffer.text, selection: selection
        )
    }
    func runIndexedDefinition() async throws {
        guard let document = model.selectedDocument,
              let fileURL = document.fileURL,
              let identifier = selectedIdentifier() else {
            actions.presentNotice("Place the cursor on a symbol name.")
            throw CommandHandlerSignal.noChange
        }
        if let symbol = NativeFeatureCoordinator.localDefinition(
            named: identifier, in: document.buffer.text
        ) {
            guard await navigation.goToFile(
                fileURL, line: symbol.line, column: 1,
                utf16Offset: symbol.position
            ) else { throw CommandHandlerSignal.noChange }
            return
        }
        let outcome: NavigationExactSymbolOutcome
        do {
            outcome = try await navigation.openExactProjectSymbol(named: identifier)
        } catch {
            throw CommandHandlerSignal.failed(.navigation(
                NavigationPresentationIssue(
                    title: .couldNotLoadProjectSymbols, error: error
                )
            ))
        }
        switch outcome {
        case .navigated:
            return
        case let .presented(matchCount):
            guard matchCount > 1 else { throw CommandHandlerSignal.noChange }
            actions.presentTransientPanel(.navigation)
            throw CommandHandlerSignal.visiblePanel
        case .notFound:
            actions.presentNotice("No indexed definition found for \(identifier).")
            throw CommandHandlerSignal.noChange
        }
    }
    func runIndexedReferences() throws {
        guard let identifier = selectedIdentifier() else {
            actions.presentNotice("Place the cursor on a symbol name.")
            throw CommandHandlerSignal.noChange
        }
        let exclusions = model.sessionProject.map {
            ProjectSettingsSanitizer.sanitize($0)
        }?.exclude.joined(separator: ",") ?? ""
        actions.presentTransientPanel(.workspaceSearch)
        guard workspaceSearch.showLiteralWholeWordResults(
            for: identifier,
            caseSensitive: NativeFeatureCoordinator
                .isCaseSensitiveReferenceIdentifier(identifier),
            excludePattern: exclusions
        ) else {
            actions.dismissTransientPanel(.workspaceSearch)
            throw CommandHandlerSignal.noChange
        }
        throw CommandHandlerSignal.visiblePanel
    }
    func handleLanguageServerPendingOutcome() throws {
        if languageServers.pendingApproval != nil {
            actions.transitionToTransientPanel(.languageServers)
            throw CommandHandlerSignal.visiblePanel
        }
        throw CommandHandlerSignal.noChange
    }
    register("lsp-hover", enablement: lspAvailable) { _ in
        guard let request = NativeFeatureCoordinator.languageServerRequest(
            method: .hover, model: model, workspace: workspace
        ) else { throw CommandHandlerSignal.noChange }
        switch await languageServers.hoverOutcome(request) {
        case .completed(.some):
            actions.presentTransientPanel(.languageServers)
            throw CommandHandlerSignal.visiblePanel
        case .completed(.none), .cancelled:
            throw CommandHandlerSignal.noChange
        case .awaitingApproval:
            try handleLanguageServerPendingOutcome()
        case let .failed(message):
            actions.transitionToTransientPanel(.languageServers)
            throw CommandHandlerSignal.failed(message)
        }
    }
    register("lsp-definition", enablement: symbolNavigationAvailable) { _ in
        guard let request = NativeFeatureCoordinator.languageServerRequest(
            method: .definition, model: model, workspace: workspace
        ) else {
            try await runIndexedDefinition()
            return
        }
        let locations: [LanguageLocation]
        switch await languageServers.definitionOutcome(request) {
        case let .completed(result):
            locations = result
        case .awaitingApproval:
            try handleLanguageServerPendingOutcome()
            return
        case .cancelled:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            actions.transitionToTransientPanel(.languageServers)
            throw CommandHandlerSignal.failed(message)
        }
        guard !locations.isEmpty else {
            languageServers.clearInteractiveResult()
            actions.presentNotice("No definition found.")
            throw CommandHandlerSignal.noChange
        }
        if locations.count == 1, let location = locations.first,
           let target = LanguageServerNavigationTarget(location) {
            guard await navigation.goToFile(
                target.url, line: target.line, column: target.column
            ) else { throw CommandHandlerSignal.noChange }
        } else {
            actions.presentTransientPanel(.languageServers)
            throw CommandHandlerSignal.visiblePanel
        }
    }
    register("lsp-references", enablement: symbolNavigationAvailable) { _ in
        guard let request = NativeFeatureCoordinator.languageServerRequest(
            method: .references, model: model, workspace: workspace
        ) else {
            try runIndexedReferences()
            return
        }
        switch await languageServers.referencesOutcome(request) {
        case let .completed(locations) where locations.isEmpty:
            languageServers.clearInteractiveResult()
            actions.presentNotice("No references found.")
            throw CommandHandlerSignal.noChange
        case .completed:
            actions.presentTransientPanel(.languageServers)
            throw CommandHandlerSignal.visiblePanel
        case .awaitingApproval:
            try handleLanguageServerPendingOutcome()
        case .cancelled:
            throw CommandHandlerSignal.noChange
        case let .failed(message):
            actions.transitionToTransientPanel(.languageServers)
            throw CommandHandlerSignal.failed(message)
        }
    }
    register("lsp-rename", enablement: lspAvailable) { _ in
        guard let base = NativeFeatureCoordinator.languageServerRequest(
            method: .rename, model: model, workspace: workspace
        ) else { throw CommandHandlerSignal.noChange }
        let locale = settings.settings.locale
        let prompt = NSAlert()
        prompt.messageText = locale.localizedApp(.renameSymbol)
        prompt.informativeText = locale.localizedApp(.enterNewSymbolName)
        let field = NSTextField(string: "")
        field.placeholderString = locale.localizedApp(.newName)
        prompt.accessoryView = field
        prompt.addButton(withTitle: locale.localizedApp(.preview))
        prompt.addButton(withTitle: locale.localized(.cancel))
        guard prompt.runModal() == .alertFirstButtonReturn,
              !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandHandlerSignal.noChange
        }
        let request = LanguageServerInteractiveRequest(
            root: base.root, config: base.config, content: base.content,
            filePath: base.filePath, languageId: base.languageId, method: .rename,
            line: base.line, character: base.character, newName: field.stringValue
        )
        switch await languageServers.renameOutcome(request) {
        case .completed(true):
            actions.presentTransientPanel(.languageServers)
            throw CommandHandlerSignal.visiblePanel
        case .completed(false), .cancelled:
            throw CommandHandlerSignal.noChange
        case .awaitingApproval:
            try handleLanguageServerPendingOutcome()
        case let .failed(message):
            actions.transitionToTransientPanel(.languageServers)
            throw CommandHandlerSignal.failed(message)
        }
    }
    register("font-zoom-in", enablement: { _ in
        guard actions.canExecutePanelCommand else {
            return .disabled(reason: "Finish the current interaction first.")
        }
        return settings.settings.fontSize < 40
            ? .enabled
            : .disabled(reason: "Maximum zoom reached.")
    }) { _ in
        settings.zoomFont(by: 1)
    }
    register("font-zoom-out", enablement: { _ in
        guard actions.canExecutePanelCommand else {
            return .disabled(reason: "Finish the current interaction first.")
        }
        return settings.settings.fontSize > 8
            ? .enabled
            : .disabled(reason: "Minimum zoom reached.")
    }) { _ in
        settings.zoomFont(by: -1)
    }
    register("font-zoom-reset", enablement: { _ in
        guard actions.canExecutePanelCommand else {
            return .disabled(reason: "Finish the current interaction first.")
        }
        return settings.settings.fontSize != EditorSettings.default.fontSize
            ? .enabled
            : .disabled(reason: "The editor is already at actual size.")
    }) { _ in
        settings.resetFontZoom()
    }
}
