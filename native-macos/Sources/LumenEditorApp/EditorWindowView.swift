import AppKit
import LumenEditorCore
import SwiftUI

enum EditorWindowAccessibility {
    static let languageToolApprove = AppAccessibility.id(
        "editor language tool approval approve"
    )
    static let languageToolCancel = AppAccessibility.id(
        "editor language tool approval cancel"
    )
    static let languageServerApprove = AppAccessibility.id(
        "editor language server approval approve"
    )
    static let languageServerCancel = AppAccessibility.id(
        "editor language server approval cancel"
    )
    static let pluginWorkerApprove = AppAccessibility.id(
        "editor plugin worker approval approve"
    )
    static let pluginWorkerCancel = AppAccessibility.id(
        "editor plugin worker approval cancel"
    )
    static let alertOK = AppAccessibility.id("editor alert ok")
    static let alertCancel = AppAccessibility.id("editor alert cancel")
    static let alertDontSave = AppAccessibility.id("editor alert dont save")
    static let alertSave = AppAccessibility.id("editor alert save")
    static let alertReopen = AppAccessibility.id("editor alert reopen")
    static let alertReload = AppAccessibility.id("editor alert reload")

    static let all = [
        languageToolApprove, languageToolCancel,
        languageServerApprove, languageServerCancel,
        pluginWorkerApprove, pluginWorkerCancel,
        alertOK, alertCancel, alertDontSave, alertSave, alertReopen, alertReload
    ]
}

enum EditorWindowInteractionPlan {
    enum EscapeAction: Equatable {
        case dismissFind
        case exitDistractionFree
        case none
    }

    static func escapeAction(
        findIsPresented: Bool, distractionFree: Bool
    ) -> EscapeAction {
        if findIsPresented { return .dismissFind }
        if distractionFree { return .exitDistractionFree }
        return .none
    }

    static func showsFindBar(isPresented: Bool, distractionFree: Bool) -> Bool {
        // Distraction-free mode hides persistent chrome, not an explicitly
        // invoked editing control. Keeping this independent of the setting also
        // prevents the keyboard router from being disabled by an invisible bar.
        _ = distractionFree
        return isPresented
    }

    static func keyboardRoutingIsAvailable(
        hasTransientPanel: Bool,
        findIsPresented: Bool,
        navigationIsPresented: Bool
    ) -> Bool {
        !hasTransientPanel && !findIsPresented && !navigationIsPresented
    }
}

enum EditorWorkspaceTaskPlan {
    static func permitsContinuation<Snapshot: Equatable>(
        captured: Snapshot, current: Snapshot, isCancelled: Bool
    ) -> Bool {
        !isCancelled && captured == current
    }
}

@MainActor
struct EditorWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var settings: SettingsController
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var commandRouter: CommandRouter
    @ObservedObject var workspaceSearch: WorkspaceSearchController
    @ObservedObject var gitController: GitController
    @ObservedObject var buildController: BuildController
    @ObservedObject var terminalController: TerminalController
    @ObservedObject var findController: FindBarController
    @ObservedObject var navigationController: NavigationController
    @ObservedObject var previewController: PreviewController
    @ObservedObject var languageServerController: LanguageServerController
    @ObservedObject var pluginController: PluginController
    @ObservedObject var recentItemsController: RecentItemsController
    @ObservedObject var projectSettingsController: ProjectSettingsController
    @ObservedObject var languageController: LanguageController
    @ObservedObject var macroSnippetController: MacroSnippetController
    @ObservedObject var documentFormatController: DocumentFormatController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var colorSchemeController: ColorSchemeController
    @ObservedObject var outlineController: OutlineController
    let codeMirrorParserCoordinator: CodeMirrorParserCoordinator
    let editorCommandController: EditorCommandController
    let incrementalDiffController: IncrementalDiffController
    @ObservedObject var languageToolsController: LanguageToolsController
    @ObservedObject var sublimeImportController: SublimeImportController
    @ObservedObject var editorConfigController: EditorConfigController
    @StateObject private var workspaceCompletionCache = WorkspaceCompletionCache()
    var windowSession: WindowSessionComposition? = nil
    var windowDidBecomeKey: @MainActor () -> Void = {}
    var windowDidResignKey: @MainActor () -> Void = {}
    var windowWillClose: @MainActor (WindowSessionPresentation?) -> Void = { _ in }
    @State private var displayedAlert: EditorAlertPresentation?
    @State private var isAlertPresented = false
    @State private var presentedLanguageServerResultRevision: UInt64 = 0
    @State private var closingLanguageServerPaths = Set<LanguageServerDocumentPath>()
    @State private var languageServerCloseRevision: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            if let issue = settings.persistenceIssue {
                SettingsPersistenceBanner(issue: issue, controller: settings)
                Divider()
            }
            if let notice = actions.dropNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(settings.locale.localizedPresentedMessage(notice.message))
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { actions.dismissDropNotice() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.locale.text(
                        "Dismiss Drop Result", zh: "关闭拖放结果"
                    ))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AppAccessibility.id("drop result"))
                Divider()
            }
            if let notice = model.encodingNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(settings.locale.localizedEncodingNotice(notice))
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { model.dismissEncodingNotice() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.locale.text(
                        "Dismiss Encoding Warning", zh: "关闭编码警告"
                    ))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AppAccessibility.id("encoding notice"))
                Divider()
            }
            if let notice = model.fileSaveNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(settings.locale.localizedFileSaveNotice(notice))
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { model.dismissFileSaveNotice() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.locale.text(
                        "Dismiss Save Warning", zh: "关闭保存警告"
                    ))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AppAccessibility.id("save warning"))
                Divider()
            }

            Group {
                if !actions.isSessionReady || model.isRestoringSession {
                    restoringView
                } else {
                    editorWorkspace
                        .allowsHitTesting(!actions.isClosingApplicationOrWindow)
                }
            }
        }
        .background {
            WindowCloseGuard(
                prepareToClose: { completion in
                    actions.prepareForWindowClose(completion: completion)
                },
                session: windowSession,
                becameKey: windowDidBecomeKey,
                resignedKey: windowDidResignKey,
                willClose: windowWillClose
            )
        }
        .onAppear {
            previewController.setJSONTransactionApplier {
                [weak macroSnippetController] transaction in
                guard let macroSnippetController else { return false }
                _ = macroSnippetController.cancelSnippetSession()
                return macroSnippetController.applyAndRecord(transaction)
            }
        }
        .task {
            await actions.runExternalChangeMonitor()
        }
        .onChange(of: settings.locale, initial: true) { _, locale in
            actions.updateLocale(locale)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await actions.checkForExternalChanges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenSelectNumberedTab)) { note in
            if let number = note.object as? Int { actions.selectTab(number: number) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenOpenSettings)) { _ in
            openSettings()
        }
        .onExitCommand {
            switch EditorWindowInteractionPlan.escapeAction(
                findIsPresented: findController.isPresented,
                distractionFree: settings.settings.distractionFree
            ) {
            case .dismissFind:
                findController.dismiss()
            case .exitDistractionFree:
                settings.set(false, for: \.distractionFree)
            case .none:
                break
            }
        }
        .alert(
            displayedAlert.map(localizedAlertTitle) ?? settings.locale.localizedApp(.appName),
            isPresented: $isAlertPresented,
            presenting: displayedAlert
        ) { presentation in
            alertActions(for: presentation)
        } message: { presentation in
            Text(localizedAlertMessage(presentation))
        }
        .onChange(of: activeAlert?.id, initial: true) { _, _ in
            synchronizeAlertPresentation()
        }
        .sheet(item: transientPanelPresentation) { panel in
            transientPanelContent(panel)
        }
        .onChange(of: navigationController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.navigation) }
        }
        .onChange(of: navigationController.issue?.id) { _, issueID in
            guard issueID != nil, !navigationController.isPresented,
                  let issue = navigationController.issue else { return }
            actions.presentIssue(issue)
            navigationController.dismissIssue()
        }
        .onChange(of: recentItemsController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.recentItems) }
        }
        .onChange(of: projectSettingsController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.projectSettings) }
        }
        .onChange(of: languageController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.languageSelection) }
        }
        .onChange(of: macroSnippetController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.macroSnippet) }
        }
        .onChange(of: documentFormatController.isPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.documentFormat) }
        }
        .onChange(of: languageToolsController.isConfigurationPresented) { _, presented in
            if presented { actions.transitionToTransientPanel(.languageTools) }
        }
        .confirmationDialog(
            settings.locale.localizedApp(.confirmExternalLanguageTool),
            isPresented: languageToolApprovalBinding,
            presenting: languageToolsController.pendingApproval
        ) { _ in
            Button(settings.locale.localizedApp(.runLanguageTool)) {
                Task { await languageToolsController.confirmPendingApproval() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(EditorWindowAccessibility.languageToolApprove)
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) {
                languageToolsController.declinePendingApproval()
            }
            .accessibilityIdentifier(EditorWindowAccessibility.languageToolCancel)
        } message: { request in
            Text(
                settings.locale.localizedApprovalDescription(request.identityDescription)
                    + "\n"
                    + settings.locale.localizedApp(
                        .approvalCurrentWindowExactConfiguration
                    )
            )
        }
        .confirmationDialog(
            settings.locale.localizedApp(.runLanguageServerPrompt),
            isPresented: languageServerApprovalBinding,
            presenting: actions.languageServerApproval
        ) { _ in
            Button(settings.locale.localizedApp(.runLanguageServer)) {
                Task { await actions.confirmLanguageServerApproval() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(EditorWindowAccessibility.languageServerApprove)
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) {
                actions.declineLanguageServerApproval()
            }
            .accessibilityIdentifier(EditorWindowAccessibility.languageServerCancel)
        } message: { approval in
            Text(
                settings.locale.localizedApprovalDescription(
                    approval.request.identityDescription
                )
                    + "\n"
                    + settings.locale.localizedApp(
                        .approvalCurrentWindowExactConfiguration
                    )
            )
        }
        .confirmationDialog(
            settings.locale.localizedApp(.runPluginWorkerPrompt),
            isPresented: pluginWorkerApprovalBinding,
            presenting: pluginController.pendingWorkerApproval
        ) { request in
            Button(settings.locale.text(
                "Run \(request.pluginName)", zh: "运行 \(request.pluginName)"
            )) {
                Task { await pluginController.approveWorker(request) }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(EditorWindowAccessibility.pluginWorkerApprove)
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) {
                pluginController.declinePendingWorkerApproval()
            }
            .accessibilityIdentifier(EditorWindowAccessibility.pluginWorkerCancel)
        } message: { request in
            Text(
                settings.locale.localizedApprovalDescription(request.identityDescription)
                    + "\n"
                    + settings.locale.localizedApp(
                        .approvalCurrentWindowExactWorkerConfiguration
                    )
            )
        }
        .task(id: workspaceContextSnapshot) {
            let snapshot = workspaceContextSnapshot
            let primaryRoot = snapshot.primaryRoot
            if primaryRoot == nil {
                buildController.clearProjectBuildCommandOverride()
            }
            await buildController.updateWorkspaceRoot(primaryRoot?.url)
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
            await terminalController.updateWorkspaceRoot(primaryRoot?.url)
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
            pluginController.updateWorkspace(primaryRoot?.url)
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
            projectSettingsController.updateWorkspace(primaryRoot?.url)
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
            if let root = primaryRoot?.url {
                _ = recentItemsController.recordProject(root)
            }
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
            await gitController.updateContext(
                primaryRoot: primaryRoot,
                selectedFileURL: snapshot.selectedFileURL
            )
            guard EditorWorkspaceTaskPlan.permitsContinuation(
                captured: snapshot, current: workspaceContextSnapshot,
                isCancelled: Task.isCancelled
            ) else { return }
        }
        .task(id: primaryWorkspaceRootID) {
            await languageToolsController.workspaceDidChange()
        }
        .onChange(of: workspace.roots.map(\.id), initial: true) { _, _ in
            workspaceCompletionCache.invalidate()
        }
        .onChange(of: activeDocumentSnapshot, initial: true) { _, _ in
            findController.documentContextDidChange()
            macroSnippetController.activeEditorDidChange(
                documentID: model.selectedDocument?.sessionDocumentID,
                viewID: model.paneLayout.activeViewID,
                revision: model.selectedDocument?.buffer.revision
            )
            if let document = model.selectedDocument,
               (previewController.isJSONViewVisible
                    ? NativeFeatureCoordinator.isJSON(document)
                    : NativeFeatureCoordinator.isMarkdown(document)) {
                previewController.updateForCurrentDocument()
            } else {
                previewController.hide()
            }
        }
        .task(id: languageServerSyncSnapshot) {
            let syncSnapshot = languageServerSyncSnapshot
            guard actions.isSessionReady,
                  let request = NativeFeatureCoordinator.languageServerSyncRequest(
                    model: model, workspace: workspace
                  ) else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let targetPath = openLanguageServerDocuments.first {
                $0.documentID == syncSnapshot.documentID
            }?.pathIdentity
            guard targetPath.map({ closingLanguageServerPaths.contains($0) }) != true else {
                return
            }
            _ = await languageServerController.synchronize(
                request, documentID: syncSnapshot.documentID,
                documentRevision: syncSnapshot.revision
            )
            if languageServerController.pendingApproval != nil {
                actions.presentTransientPanel(.languageServers)
            }
        }
        .onChange(of: openLanguageServerDocuments, initial: true) { previous, current in
            let closed = LanguageServerDocumentLifecycle.closedDocuments(
                previous: previous, current: current
            )
            guard !closed.isEmpty else { return }
            closingLanguageServerPaths.formUnion(closed.map(\.pathIdentity))
            languageServerCloseRevision &+= 1
            Task { @MainActor in
                defer {
                    closingLanguageServerPaths.subtract(closed.map(\.pathIdentity))
                    languageServerCloseRevision &+= 1
                }
                for document in closed {
                    _ = await languageServerController.closeDocument(
                        root: document.root, config: document.config,
                        fileURL: document.fileURL
                    )
                }
            }
        }
        .onChange(of: selectedDocumentURL, initial: true) { _, url in
            if let url { _ = recentItemsController.recordFile(url) }
        }
        .onChange(of: languageServerController.interactiveResultRevision) { _, _ in
            presentLanguageServerInteractiveResultIfNeeded()
        }
        .onChange(of: languageServerController.pendingApproval?.id) { _, approvalID in
            if approvalID != nil { actions.transitionToTransientPanel(.languageServers) }
        }
        .onChange(of: languageServerController.issue?.id) { _, issueID in
            if issueID != nil { actions.transitionToTransientPanel(.languageServers) }
        }
        .onChange(of: actions.isOpeningDocuments) { _, isOpening in
            if !isOpening { presentLanguageServerInteractiveResultIfNeeded() }
        }
        .onChange(of: actions.presentedIssue?.id) { _, issueID in
            if issueID == nil { presentLanguageServerInteractiveResultIfNeeded() }
        }
        .onChange(of: workspaceSearch.status) { _, status in
            guard !workspaceSearch.isBusy else { return }
            AppAccessibility.announce(localizedWorkspaceSearchStatus(status))
        }
        .onChange(of: workspaceSearch.issue?.id) { _, issueID in
            guard issueID != nil, let issue = workspaceSearch.issue else { return }
            AppAccessibility.announce(
                settings.locale.localizedWorkspaceSearchIssueAnnouncement(issue)
            )
        }
        .onChange(of: findController.status) { _, status in
            guard status != .searching else { return }
            AppAccessibility.announce(localizedFindStatus(status))
        }
    }

    private var activeAlert: EditorAlertPresentation? {
        if let issue = actions.presentedIssue {
            return .actionIssue(issue)
        }
        if let issue = model.presentedIssue {
            return .issue(issue)
        }
        if let issue = languageToolsController.issue {
            return .languageToolIssue(issue)
        }
        if let issue = editorConfigController.issue {
            return .editorConfigIssue(issue)
        }
        if let issue = pluginController.workerIssue {
            return .pluginWorkerIssue(issue)
        }
        if !actions.isResolvingClose, let request = model.pendingCloseRequest {
            return .close(
                request,
                closingApplication: actions.isClosingApplicationOrWindow
            )
        }
        if let request = actions.reopenEncodingRequest {
            return .reopen(request)
        }
        if let request = actions.reloadDiskRequest {
            return .reload(request)
        }
        return nil
    }

    private func localizedWorkspaceSearchStatus(_ status: WorkspaceSearchStatus) -> String {
        settings.locale.localizedWorkspaceSearchStatus(
            status,
            hasRoots: !workspaceSearch.rootIDs.isEmpty,
            purpose: .announcement
        )
    }

    private func localizedFindStatus(_ status: FindBarStatus) -> String {
        settings.locale.localizedFindStatus(
            status,
            queryIsEmpty: findController.query.isEmpty,
            purpose: .announcement
        )
    }

    private func synchronizeAlertPresentation() {
        guard let nextAlert = activeAlert else {
            isAlertPresented = false
            return
        }
        guard displayedAlert?.id != nextAlert.id || !isAlertPresented else { return }

        // A batch close can replace one CloseRequest with the next in the same
        // main-actor turn. Force a dismissed render before showing the next item.
        isAlertPresented = false
        Task { @MainActor in
            guard activeAlert?.id == nextAlert.id else { return }
            displayedAlert = nextAlert
            isAlertPresented = true
        }
    }

    @ViewBuilder
    private func alertActions(for presentation: EditorAlertPresentation) -> some View {
        switch presentation {
        case .actionIssue:
            Button(settings.locale.text("OK", zh: "好")) { actions.dismissActionIssue() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertOK)
        case .issue:
            Button(settings.locale.text("OK", zh: "好")) { actions.dismissPresentedIssue() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertOK)
        case .languageToolIssue:
            Button(settings.locale.text("OK", zh: "好")) { languageToolsController.dismissIssue() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertOK)
        case .editorConfigIssue:
            Button(settings.locale.text("OK", zh: "好")) { editorConfigController.dismissIssue() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertOK)
        case .pluginWorkerIssue:
            Button(settings.locale.text("OK", zh: "好")) { pluginController.dismissWorkerIssue() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertOK)
        case .close:
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) {
                Task { await actions.cancelPendingClose() }
            }
            .accessibilityIdentifier(EditorWindowAccessibility.alertCancel)
            Button(settings.locale.text("Don’t Save", zh: "不保存"), role: .destructive) {
                Task { await actions.resolvePendingCloseByDiscarding() }
            }
            .accessibilityIdentifier(EditorWindowAccessibility.alertDontSave)
            Button(settings.locale.text("Save", zh: "保存")) {
                Task { await actions.resolvePendingCloseBySaving() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(EditorWindowAccessibility.alertSave)
        case .reopen:
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) { actions.cancelReopenWithEncoding() }
                .accessibilityIdentifier(EditorWindowAccessibility.alertCancel)
            Button(settings.locale.text("Reopen", zh: "重新打开"), role: .destructive) {
                Task { _ = await actions.confirmReopenWithEncoding() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(EditorWindowAccessibility.alertReopen)
        case .reload:
            Button(settings.locale.text("Cancel", zh: "取消"), role: .cancel) { actions.cancelReloadFromDisk() }
                .accessibilityIdentifier(EditorWindowAccessibility.alertCancel)
            Button(settings.locale.text("Reload", zh: "重新载入"), role: .destructive) { actions.confirmReloadFromDisk() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(EditorWindowAccessibility.alertReload)
        }
    }

    private func localizedAlertTitle(_ presentation: EditorAlertPresentation) -> String {
        switch presentation {
        case let .actionIssue(issue):
            switch issue.titleContent {
            case let .presented(title):
                return settings.locale.localizedPresentedTitle(title)
            case let .git(title):
                return settings.locale.localizedGitIssueTitle(title)
            case let .navigation(title):
                return settings.locale.localizedNavigationIssueTitle(title)
            case let .languageTool(title):
                return settings.locale.localizedLanguageToolIssueTitle(title)
            case let .languageServer(title):
                return settings.locale.localizedLanguageServerIssueTitle(title)
            case let .appModel(title):
                return settings.locale.localizedAppModelIssueTitle(title)
            }
        case let .issue(issue):
            return settings.locale.localizedAppModelIssueTitle(issue.titleContent)
        case let .languageToolIssue(issue):
            return settings.locale.localizedLanguageToolIssueTitle(issue.titleContent)
        case let .editorConfigIssue(issue):
            return settings.locale.localizedEditorConfigIssueTitle(issue.titleContent)
        case let .pluginWorkerIssue(issue):
            return settings.locale.localizedApp(issue.titleCopy)
        case let .close(request, _):
            return settings.locale.localizedApp(.saveChangesToDocument(name: request.displayName))
        case let .reopen(request):
            return settings.locale.localizedApp(.reopenUsingEncoding(
                name: request.encodingName(locale: settings.locale)
            ))
        case .reload:
            return settings.locale.localizedApp(.reloadDiskVersionPrompt)
        }
    }

    private func localizedAlertMessage(_ presentation: EditorAlertPresentation) -> String {
        switch presentation {
        case let .actionIssue(issue):
            switch issue.content {
            case let .presented(message):
                return settings.locale.localizedPresentedMessage(message)
            case let .command(content):
                return settings.locale.localizedCommandPresentation(content)
            case let .appModel(content):
                return settings.locale.localizedAppModelIssue(content)
            }
        case let .issue(issue):
            return settings.locale.localizedAppModelIssue(issue.content)
        case let .languageToolIssue(issue):
            return settings.locale.localizedLanguageToolIssue(issue.content)
        case let .editorConfigIssue(issue):
            return settings.locale.localizedEditorConfigIssue(issue.content)
        case let .pluginWorkerIssue(issue):
            return settings.locale.localizedPluginWorkerIssue(issue.content)
        case let .close(_, closingApplication):
            return closingApplication
                ? settings.locale.localizedApp(.reviewBeforeClosing)
                : settings.locale.localizedApp(.loseUnsavedChanges)
        case let .reopen(request):
            return request.document.isDirty
                ? settings.locale.localizedApp(.discardUnsavedEditsAndReinterpret)
                : settings.locale.localizedApp(.reinterpretOriginalFileBytes)
        case .reload:
            return settings.locale.localizedApp(.discardLocalDraftForDiskVersion)
        }
    }

    private var restoringView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(settings.locale.text(
                "Restoring your editing session…", zh: "正在恢复编辑会话…"
            ))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            if let document = model.selectedDocument,
               let conflict = document.externalConflict {
                ExternalConflictBanner(
                    document: document,
                    conflict: conflict,
                    actions: actions
                )
                Divider()
            }

            HStack(spacing: 0) {
                if workspace.isSidebarVisible && !settings.settings.distractionFree {
                    WorkspaceSidebarView(
                        controller: workspace,
                        activeFileURL: model.selectedDocument?.fileURL
                    )
                    Divider()
                }

                if outlineController.isVisible && !settings.settings.distractionFree {
                    OutlinePanelView(controller: outlineController)
                    Divider()
                }

                EditorPaneView(
                    model: model,
                    actions: actions,
                    settings: settings,
                    workspace: workspace,
                    commandRouter: commandRouter,
                    previewController: previewController,
                    languageServerController: languageServerController,
                    workspaceCompletionCache: workspaceCompletionCache,
                    codeMirrorParserCoordinator: codeMirrorParserCoordinator,
                    editorCommandController: editorCommandController,
                    applyTextTransaction: macroSnippetController.applyAndRecord(_:),
                    navigateSnippetPlaceholder: macroSnippetController
                        .navigateSnippetPlaceholder(_:),
                    cancelSnippetSession: macroSnippetController.cancelSnippetSession,
                    incrementalDiffMarkers: { document, paneIndex in
                        guard let snapshot = IncrementalDiffController.snapshot(
                            model: model, paneIndex: paneIndex
                        ), snapshot.documentID == document.sessionDocumentID else {
                            return []
                        }
                        return incrementalDiffController.markers(for: snapshot)
                    },
                    findHighlightSnapshot: { document, viewID, paneIndex in
                        findController.highlightSnapshot(
                            documentID: document.sessionDocumentID,
                            viewID: viewID,
                            paneIndex: paneIndex,
                            documentRevision: document.buffer.revision
                        )
                    },
                    foldSnapshot: { document, viewID in
                        outlineController.textKitFoldSnapshot(
                            documentID: document.sessionDocumentID,
                            viewID: viewID,
                            documentRevision: document.buffer.revision
                        )
                    },
                    toggleFoldMarker: { documentID, viewID, revision, regionID in
                        guard model.paneLayout.panes.contains(where: { pane in
                            pane.viewID == viewID && pane.contains(documentID)
                        }),
                              model.document(sessionDocumentID: documentID)?.buffer.revision
                                == revision else { return false }
                        outlineController.toggleFoldMarker(
                            documentID: documentID, viewID: viewID,
                            documentRevision: revision, regionID: regionID
                        )
                    },
                    revealFoldedContent: { documentID, viewID, offset in
                        outlineController.revealFoldedContent(
                            documentID: documentID, viewID: viewID,
                            atUTF16Offset: offset
                        )
                    },
                    activeEditorFocusRequest: findController.dismissalGeneration,
                    showsTabBar: !settings.settings.distractionFree
                )

                if previewController.isVisible {
                    Divider()
                    DocumentPreviewView(controller: previewController)
                        .frame(minWidth: 280, idealWidth: 400, maxWidth: 620)
                }
            }

            if EditorWindowInteractionPlan.showsFindBar(
                isPresented: findController.isPresented,
                distractionFree: settings.settings.distractionFree
            ) {
                Divider()
                HStack {
                    Spacer(minLength: 12)
                    FindBarView(controller: findController)
                    Spacer(minLength: 12)
                }
                .padding(.vertical, 6)
                .background(.bar)
            }

            if let document = model.selectedDocument, !settings.settings.distractionFree {
                Divider()
                EditorStatusBar(
                    model: model,
                    document: document,
                    actions: actions,
                    languageController: languageController
                )
            }
        }
        .frame(maxWidth: settings.settings.distractionFree ? 1_100 : .infinity)
    }

    private var transientPanelPresentation: Binding<EditorTransientPanel?> {
        Binding(
            get: { actions.transientPanel },
            set: { panel in
                if panel == nil {
                    navigationController.dismiss()
                    workspaceSearch.dismiss()
                    actions.dismissTransientPanel()
                }
            }
        )
    }

    @ViewBuilder
    private func transientPanelContent(_ panel: EditorTransientPanel) -> some View {
        switch panel {
        case .commandPalette:
            CommandPaletteView(
                router: commandRouter,
                locale: settings.locale == .zhCN ? .simplifiedChinese : .english,
                context: routingContext,
                pluginRoutes: pluginController.commandRoutes,
                workerPluginRoutes: pluginController.workerCommandRoutes,
                executePlugin: executePluginCommand,
                executeWorkerPlugin: { routeID in
                    await pluginController.runWorkerCommand(routeID)
                },
                onDismiss: actions.dismissCommandPalette
            )
        case .workspaceSearch:
            WorkspaceSearchPanelView(
                controller: workspaceSearch,
                onDismiss: {
                    workspaceSearch.dismiss()
                    actions.dismissTransientPanel(.workspaceSearch)
                }
            )
        case .navigation:
            NavigationPaletteView(
                controller: navigationController,
                onDismiss: {
                    navigationController.dismiss()
                    actions.dismissTransientPanel(.navigation)
                }
            )
        case .git:
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(settings.locale.text("Done", zh: "完成")) {
                        actions.dismissGitPanel()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Divider()
                GitPanelView(
                    controller: gitController
                )
            }
            .frame(minWidth: 720, minHeight: 480)
        case .build:
            BuildPanelView(
                controller: buildController,
                buildSystems: NativeFeatureCoordinator.buildSystems(
                    from: projectSettingsController.settings
                ),
                openProblem: { problem in
                    actions.dismissBuildPanel()
                    return await navigationController.goToFile(
                        problem.url, line: problem.line, column: problem.column
                    )
                },
                onDismiss: actions.dismissBuildPanel
            )
        case .buildSystem:
            BuildSystemPaletteView(
                controller: buildController,
                onDismiss: { actions.dismissTransientPanel(.buildSystem) },
                onAccept: {
                    let accepted = await buildController.acceptBuildSystemPaletteSelection()
                    guard accepted else { return false }
                    actions.replaceTransientPanel(.buildSystem, with: .build)
                    return true
                }
            )
        case .terminal:
            TerminalPanelView(
                controller: terminalController,
                onDismiss: actions.dismissTerminalPanel
            )
        case .languageServers:
            LanguageServerPanelView(
                controller: languageServerController,
                onOpenLocation: openLanguageServerLocation,
                onDismiss: { actions.dismissTransientPanel(.languageServers) }
            )
        case .plugins:
            PluginManagerView(
                controller: pluginController,
                installLocalPlugin: {
                    let outcome = await actions.installLocalPlugin(
                        using: pluginController, locale: settings.settings.locale
                    )
                    return outcome.didComplete
                },
                onOpenMarketplace: {
                    actions.replaceTransientPanel(.plugins, with: .marketplace)
                }
            )
        case .marketplace:
            MarketplaceView(
                controller: pluginController,
                onDismiss: { actions.dismissTransientPanel(.marketplace) }
            )
        case .recentItems:
            RecentItemsView(
                controller: recentItemsController,
                onDismiss: { actions.dismissTransientPanel(.recentItems) }
            )
        case .projectSettings:
            ProjectSettingsView(controller: projectSettingsController)
                .onDisappear { actions.dismissTransientPanel(.projectSettings) }
        case .languageSelection:
            LanguagePaletteView(
                controller: languageController,
                onDismiss: { actions.dismissTransientPanel(.languageSelection) }
            )
        case .macroSnippet:
            MacroSnippetView(
                controller: macroSnippetController,
                onDismiss: { actions.dismissTransientPanel(.macroSnippet) }
            )
        case .documentFormat:
            DocumentFormatPaletteView(
                controller: documentFormatController,
                onDismiss: { actions.dismissTransientPanel(.documentFormat) }
            )
        case .softwareUpdate:
            UpdateView(
                controller: updateController,
                onDismiss: { actions.dismissTransientPanel(.softwareUpdate) }
            )
        case .colorScheme:
            ColorSchemeView(
                controller: colorSchemeController,
                onDismiss: { actions.dismissTransientPanel(.colorScheme) }
            )
        case .languageTools:
            LanguageToolsConfigurationView(controller: languageToolsController)
                .onDisappear {
                    languageToolsController.dismissConfiguration()
                    actions.dismissTransientPanel(.languageTools)
                }
        case .sublimeImport:
            SublimeImportView(
                controller: sublimeImportController,
                onDismiss: { actions.dismissTransientPanel(.sublimeImport) }
            )
        }
    }

    private var routingContext: CommandRoutingContext {
        actions.commandRoutingContext(
            hasFindResults: workspaceSearch.hasResults,
            hasGitRepository: gitController.isRepositoryAvailable,
            hasNavigationHistory: navigationController.canGoBack
                || navigationController.canGoForward,
            hasLanguageService: languageServerController.runningServerCount > 0
        )
    }

    private var languageToolApprovalBinding: Binding<Bool> {
        Binding(
            get: { languageToolsController.pendingApproval != nil },
            set: { if !$0 { languageToolsController.declinePendingApproval() } }
        )
    }

    private var languageServerApprovalBinding: Binding<Bool> {
        Binding(
            get: { actions.languageServerApproval != nil },
            set: { if !$0 { actions.declineLanguageServerApproval() } }
        )
    }

    private var pluginWorkerApprovalBinding: Binding<Bool> {
        Binding(
            get: { pluginController.pendingWorkerApproval != nil },
            set: { _ in }
        )
    }

    private func executePluginCommand(_ routeID: String) async -> Bool {
        guard case let .insertText(text) = commandRouter.routePluginCommand(
            routeID, routes: pluginController.commandRoutes, context: routingContext
        ) else { return false }
        return NativeFeatureCoordinator.insertText(text, model: model)
    }

    /// LSP positions are zero-based UTF-16 coordinates. NavigationController
    /// performs the trusted open, clamps the requested cursor, and records the
    /// successful jump for Navigate Back/Forward.
    private func openLanguageServerLocation(_ location: LanguageLocation) {
        guard let target = LanguageServerNavigationTarget(location) else { return }
        actions.dismissTransientPanel(.languageServers)
        Task { @MainActor in
            let didOpen = await navigationController.goToFile(
                target.url, line: target.line, column: target.column
            )
            if !didOpen {
                actions.presentIssue(
                    title: settings.locale.localizedApp(
                        .couldNotOpenLanguageServerLocation
                    ),
                    message: settings.locale.localizedApp(
                        .requestedLanguageServerLocationCouldNotOpen(
                            path: target.url.path
                        )
                    )
                )
            }
        }
    }

    /// A single definition may already have been opened by the command route;
    /// every result that needs inspection remains reachable from the native
    /// panel. In particular, multiple definitions are never reduced to only
    /// the first location and references stay individually navigable.
    private func presentLanguageServerInteractiveResultIfNeeded() {
        let revision = languageServerController.interactiveResultRevision
        guard revision > 0, revision != presentedLanguageServerResultRevision else { return }
        guard let result = languageServerController.interactiveResult,
              let method = languageServerController.interactiveResultMethod else { return }
        guard LanguageServerResultPresentation.requiresPanel(
            method: method, result: result
        ) else {
            presentedLanguageServerResultRevision = revision
            return
        }
        actions.transitionToTransientPanel(.languageServers)
        if actions.transientPanel == .languageServers {
            presentedLanguageServerResultRevision = revision
        }
    }

    private var workspaceContextSnapshot: WorkspaceContextSnapshot {
        let primaryRoot = workspace.roots.first(where: \.isPrimary)
        WorkspaceContextSnapshot(
            primaryRoot: primaryRoot,
            selectedFileURL: model.selectedDocument?.fileURL
        )
    }

    private var primaryWorkspaceRootID: WorkspaceRoot.ID? {
        workspace.roots.first(where: \.isPrimary)?.id
    }

    private var activeDocumentSnapshot: ActiveDocumentSnapshot {
        let paneIndex = model.paneLayout.activePaneIndex
        let viewID = model.paneLayout.panes.indices.contains(paneIndex)
            ? model.paneLayout.panes[paneIndex].viewID : nil
        let document = model.activeDocument(inPaneAt: paneIndex)
        let selection = document.flatMap { document in
            viewID.map { model.selection(
                for: document.sessionDocumentID, viewID: $0
            ).main }
        }
        return ActiveDocumentSnapshot(
            documentID: document?.sessionDocumentID,
            viewID: viewID, paneIndex: paneIndex,
            revision: document?.buffer.revision,
            selection: selection
        )
    }


    private var selectedDocumentURL: URL? {
        model.selectedDocument?.fileURL?.standardizedFileURL
    }

    private var languageServerSyncSnapshot: LanguageServerSyncSnapshot {
        LanguageServerSyncSnapshot(
            documentID: model.selectedDocument?.sessionDocumentID,
            revision: model.selectedDocument?.buffer.revision,
            rootID: workspace.roots.first(where: \.isPrimary)?.id,
            project: model.sessionProject,
            closeRevision: languageServerCloseRevision
        )
    }

    private var openLanguageServerDocuments: [LanguageServerOpenDocument] {
        model.documents.compactMap { document in
            guard let fileURL = document.fileURL,
                  let root = workspace.roots
                    .filter({ Self.contains(root: $0.url, file: fileURL) })
                    .max(by: { $0.url.path.count < $1.url.path.count }),
                  let config = NativeFeatureCoordinator.languageServerConfig(
                    for: document, project: model.sessionProject
                  ) else { return nil }
            return LanguageServerOpenDocument(
                documentID: document.sessionDocumentID,
                fileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
                root: root.url.standardizedFileURL.resolvingSymlinksInPath(),
                config: config
            )
        }.sorted { lhs, rhs in
            if lhs.documentID != rhs.documentID { return lhs.documentID < rhs.documentID }
            return lhs.fileURL.path < rhs.fileURL.path
        }
    }

    private static func contains(root: URL, file: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, fileComponents).allSatisfy { $0.0 == $0.1 }
    }

}

struct LanguageServerOpenDocument: Equatable, Sendable {
    struct Identity: Hashable, Sendable {
        let documentID: String
        let filePath: String
        let rootPath: String
        let command: String
        let arguments: [String]
    }

    let documentID: String
    let fileURL: URL
    let root: URL
    let config: LanguageServerConfig

    var identity: Identity {
        Identity(
            documentID: documentID, filePath: fileURL.path, rootPath: root.path,
            command: config.command, arguments: config.args
        )
    }

    var pathIdentity: LanguageServerDocumentPath {
        LanguageServerDocumentPath(
            filePath: fileURL.path, rootPath: root.path,
            command: config.command, arguments: config.args
        )
    }
}

struct LanguageServerDocumentPath: Hashable, Sendable {
    let filePath: String
    let rootPath: String
    let command: String
    let arguments: [String]
}

enum LanguageServerDocumentLifecycle {
    static func closedDocuments(
        previous: [LanguageServerOpenDocument],
        current: [LanguageServerOpenDocument]
    ) -> [LanguageServerOpenDocument] {
        let currentIdentities = Set(current.map(\.identity))
        return previous.filter { old in !currentIdentities.contains(old.identity) }
    }
}

private struct ActiveDocumentSnapshot: Equatable {
    let documentID: String?
    let viewID: EditorViewID?
    let paneIndex: Int
    let revision: UInt64?
    let selection: DirectedSelection?
}

private struct LanguageServerSyncSnapshot: Equatable {
    let documentID: String?
    let revision: UInt64?
    let rootID: WorkspaceRoot.ID?
    let project: WindowSessionProject?
    let closeRevision: UInt64
}

struct WorkspaceContextSnapshot: Equatable {
    let primaryRoot: WorkspaceRoot?
    let selectedFileURL: URL?
}

private enum EditorAlertPresentation: Identifiable {
    case actionIssue(EditorActionIssue)
    case issue(AppModelIssue)
    case languageToolIssue(LanguageToolPresentationIssue)
    case editorConfigIssue(EditorConfigPresentationIssue)
    case pluginWorkerIssue(PluginWorkerRuntimeIssue)
    case close(CloseRequest, closingApplication: Bool)
    case reopen(ReopenEncodingRequest)
    case reload(ReloadDiskRequest)

    var id: String {
        switch self {
        case let .actionIssue(issue): "action-issue-\(issue.id.uuidString)"
        case let .issue(issue): "issue-\(issue.id.uuidString)"
        case let .languageToolIssue(issue): "language-tool-\(issue.id.uuidString)"
        case let .editorConfigIssue(issue): "editor-config-\(issue.id.uuidString)"
        case let .pluginWorkerIssue(issue): "plugin-worker-\(issue.id.uuidString)"
        case let .close(request, _): "close-\(request.id.uuidString)"
        case let .reopen(request): "reopen-\(request.id.uuidString)"
        case let .reload(request): "reload-\(request.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case let .actionIssue(issue): issue.title
        case let .issue(issue): issue.title
        case let .languageToolIssue(issue): issue.title
        case let .editorConfigIssue(issue): issue.title
        case let .pluginWorkerIssue(issue): issue.title
        case let .close(request, _): "Save changes to \(request.displayName)?"
        case let .reopen(request):
            "Reopen Using \(request.encodingName(locale: .enUS))?"
        case .reload: "Reload the Disk Version?"
        }
    }

    var message: String {
        switch self {
        case let .actionIssue(issue):
            issue.message
        case let .issue(issue):
            issue.message
        case let .languageToolIssue(issue):
            issue.message
        case let .editorConfigIssue(issue):
            issue.message
        case let .pluginWorkerIssue(issue):
            issue.message
        case let .close(_, closingApplication):
            closingApplication
                ? "Review this document before Lumen Editor closes."
                : "Your changes will be lost if you don’t save them."
        case let .reopen(request):
            request.document.isDirty
                ? "This discards unsaved edits and reinterprets the original file bytes."
                : "The document will be reinterpreted from its original file bytes."
        case .reload:
            "This discards the local draft and replaces it with the version currently on disk."
        }
    }
}

private struct SettingsPersistenceBanner: View {
    let issue: SettingsPersistenceIssue
    @ObservedObject var controller: SettingsController
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocale.localizedApp(issue.titleContent))
                    .font(.headline)
                Text(appLocale.localizedSettingsPersistenceIssue(issue.content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(appLocale.text("Retry", zh: "重试")) { _ = controller.retrySave() }
            Button(appLocale.text("Dismiss", zh: "忽略")) {
                controller.dismissPersistenceIssue()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

private struct ExternalConflictBanner: View {
    @ObservedObject var document: EditorDocument
    let conflict: ExternalConflict
    @ObservedObject var actions: EditorActionController
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(conflictTitle)
                    .font(.headline)
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if conflict.canCompareOrReload {
                Button(l("Compare", "比较")) {
                    actions.compareDiskVersion(document)
                }
                Button(l("Keep Local", "保留本地版本")) {
                    actions.keepLocalVersion(document)
                }
                Button(l("Reload", "重新载入")) {
                    actions.requestReloadFromDisk(document)
                }
            }

            Button(l("Save As…", "另存为…")) {
                Task { await actions.saveConflictedDocumentAs(document) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                Task { await actions.checkForExternalChange(document) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(l("Check Again", "再次检查"))
            .accessibilityLabel(l("Check for Changes Again", "再次检查文件更改"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.10))
    }

    private var conflictTitle: String {
        switch conflict.kind {
        case .modified: l("This file changed on disk", "此文件已在磁盘上更改")
        case .missing: l("This file is missing on disk", "磁盘上的此文件已丢失")
        case .binary: l("The file on disk is now binary", "磁盘上的文件现为二进制文件")
        case .tooLarge: l("The file on disk is now too large", "磁盘上的文件现已过大")
        case .hardLinked: l("This file has multiple hard links", "此文件有多个硬链接")
        case .unreadable: l("This file cannot be read", "无法读取此文件")
        }
    }

    private var conflictMessage: String {
        if let detail = conflict.detail, !detail.isEmpty { return detail }
        switch conflict.kind {
        case .modified:
            l("Choose which version to keep, compare both versions, or save your draft elsewhere.", "请选择要保留的版本、比较两个版本，或将草稿另存到其他位置。")
        case .missing:
            l("Your local draft is intact. Save it to choose a new location.", "本地草稿仍然完好。请另存以选择新位置。")
        case .binary:
            l("The local draft is intact, but the disk version is no longer editable text.", "本地草稿仍然完好，但磁盘版本已不是可编辑文本。")
        case .tooLarge:
            l("The local draft is intact, but the disk version exceeds the editing limit.", "本地草稿仍然完好，但磁盘版本超过编辑大小限制。")
        case .hardLinked:
            l("Safe atomic replacement is unavailable. Save your draft to a different file.", "无法安全地原子替换此文件。请将草稿另存为其他文件。")
        case .unreadable:
            l("The local draft is intact. Check permissions or save it to another location.", "本地草稿仍然完好。请检查权限或另存到其他位置。")
        }
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }
}

private struct EditorStatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var document: EditorDocument
    @ObservedObject var actions: EditorActionController
    @ObservedObject var languageController: LanguageController
    @Environment(\.appLocale) private var appLocale

    private var position: CursorPosition {
        CursorPosition(
            text: document.text,
            selection: model.selection(
                for: document.sessionDocumentID,
                viewID: model.paneLayout.activeViewID
            ).main.sessionSelection
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(appLocale.text(
                "Ln \(position.line), Col \(position.column)",
                zh: "行 \(position.line)，列 \(position.column)"
            ))
            if position.selectionLength > 0 {
                Text(appLocale.text(
                    "Sel \(position.selectionLength)",
                    zh: "已选 \(position.selectionLength)"
                ))
            }

            Text(document.fileURL?.path ?? appLocale.text("Untitled", zh: "未命名"))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(document.fileURL?.path ?? appLocale.text(
                    "This document has not been saved.", zh: "此文档尚未保存。"
                ))

            Spacer(minLength: 8)

            if document.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text(appLocale.text("Saving…", zh: "正在保存…"))
                    .foregroundStyle(.secondary)
            }

            EncodingMenu(document: document, actions: actions)
            LineEndingMenu(document: document, actions: actions)
            Button(document.language) { _ = languageController.present() }
                .buttonStyle(.plain)
                .help(document.languageLocked
                    ? appLocale.text("Syntax is locked for this document", zh: "此文档的语法已锁定")
                    : appLocale.text("Syntax is detected from the file name", zh: "语法根据文件名自动检测"))
                .accessibilityLabel(appLocale.text("Document Language", zh: "文档语言"))
                .accessibilityValue(document.language)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }
}

private struct EncodingMenu: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var actions: EditorActionController
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        Menu {
            Section(appLocale.text("Save Using", zh: "保存编码")) {
                ForEach(TextEncoding.allCases, id: \.rawValue) { encoding in
                    Button {
                        actions.chooseEncodingForSave(encoding, document: document)
                    } label: {
                        menuLabel(encoding.displayName, selected: document.encoding == encoding)
                    }
                }
            }

            Divider()

            Menu(appLocale.text("Reopen Using", zh: "重新打开编码")) {
                ForEach(TextEncoding.allCases, id: \.rawValue) { encoding in
                    Button(encoding.displayName) {
                        actions.requestReopen(document, using: encoding)
                    }
                }
            }
            .disabled(document.isUntitled)
        } label: {
            HStack(spacing: 4) {
                if document.encodingIssue != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                }
                Text(document.encodingStatusText)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(encodingHelp)
        .disabled(document.isSaving)
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }

    private var encodingHelp: String {
        if document.encodingIssue != nil {
            return appLocale.text("The displayed text may contain decoding errors. Choose Reopen Using to reinterpret the original bytes.", zh: "显示的文本可能包含解码错误。请选择重新打开编码以重新解释原始字节。")
        }
        return appLocale.text("Choose the next-save encoding or reopen the original bytes with a specific encoding.", zh: "选择下次保存编码，或使用指定编码重新解释原始字节。")
    }
}

private struct LineEndingMenu: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var actions: EditorActionController
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        Menu {
            ForEach(LineEnding.allCases, id: \.rawValue) { lineEnding in
                Button {
                    actions.chooseLineEndingForSave(lineEnding, document: document)
                } label: {
                    HStack {
                        Text(lineEnding.rawValue)
                        if document.lineEnding == lineEnding {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(document.lineEndingStatusText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(appLocale.text("Choose the line ending used by the next save.", zh: "选择下次保存使用的换行符。"))
        .disabled(document.isSaving)
    }
}

private struct CursorPosition {
    let line: Int
    let column: Int
    let selectionLength: Int

    init(text: String, selection: SessionSelection) {
        let utf16 = text.utf16
        let upperBound = utf16.count
        let head = min(max(selection.head, 0), upperBound)
        var line = 1
        var column = 1
        var offset = 0

        for codeUnit in utf16 {
            guard offset < head else { break }
            if codeUnit == 10 {
                line += 1
                column = 1
            } else {
                column += 1
            }
            offset += 1
        }

        self.line = line
        self.column = column
        self.selectionLength = abs(
            min(max(selection.head, 0), upperBound)
                - min(max(selection.anchor, 0), upperBound)
        )
    }
}
