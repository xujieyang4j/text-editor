import AppKit
import Combine
import Foundation
import LumenEditorCore

struct ReopenEncodingRequest: Identifiable {
    let id = UUID()
    let document: EditorDocument
    let encoding: TextEncoding?

    func encodingName(locale: EditorLocale) -> String {
        encoding?.displayName ?? locale.text("Auto Detect", zh: "自动检测")
    }
}

struct ReloadDiskRequest: Identifiable {
    let id = UUID()
    let document: EditorDocument
}

struct EditorActionIssue: Identifiable, Equatable {
    enum Title: Equatable {
        case presented(String)
        case git(GitPresentationIssue.Title)
        case navigation(NavigationPresentationIssue.Title)
        case languageTool(LanguageToolPresentationIssue.Title)
        case languageServer(LanguageServerPresentationIssue.Title)
        case appModel(AppModelIssue.Title)
    }

    enum Content: Equatable {
        /// Legacy app-owned copy that is still localized by the central
        /// presentation catalog at render time.
        case presented(String)
        /// A structured command failure retained across menu/keyboard dispatch.
        case command(CommandPresentation)
        /// A model-layer file/session failure forwarded without flattening.
        case appModel(AppModelIssue.Message)
    }

    let id = UUID()
    let titleContent: Title
    let content: Content

    var title: String {
        switch titleContent {
        case let .presented(title): title
        case let .git(title): EditorLocale.enUS.localizedGitIssueTitle(title)
        case let .navigation(title):
            EditorLocale.enUS.localizedNavigationIssueTitle(title)
        case let .languageTool(title):
            EditorLocale.enUS.localizedLanguageToolIssueTitle(title)
        case let .languageServer(title):
            EditorLocale.enUS.localizedLanguageServerIssueTitle(title)
        case let .appModel(title): EditorLocale.enUS.localizedAppModelIssueTitle(title)
        }
    }

    var message: String {
        switch content {
        case let .presented(message):
            message
        case let .command(presentation):
            EditorLocale.enUS.localizedCommandPresentation(presentation)
        case let .appModel(content):
            EditorLocale.enUS.localizedAppModelIssue(content)
        }
    }

    init(title: String, message: String) {
        titleContent = .presented(title)
        content = .presented(message)
    }

    init(title: String, commandPresentation: CommandPresentation) {
        if case let .appModel(issue) = commandPresentation {
            titleContent = .appModel(issue.titleContent)
        } else if case let .git(issue) = commandPresentation {
            titleContent = .git(issue.titleContent)
        } else if case let .navigation(issue) = commandPresentation {
            titleContent = .navigation(issue.titleContent)
        } else if case let .languageTool(issue) = commandPresentation {
            titleContent = .languageTool(issue.titleContent)
        } else if case let .languageServer(issue) = commandPresentation {
            titleContent = .languageServer(issue.titleContent)
        } else if case .securityScope = commandPresentation {
            titleContent = .appModel(.openFile)
        } else {
            titleContent = .presented(title)
        }
        content = .command(commandPresentation)
    }

    init(appModelIssue issue: AppModelIssue) {
        titleContent = .appModel(issue.titleContent)
        content = .appModel(issue.content)
    }
}

struct EditorActionNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct LanguageServerApprovalPresentation: Identifiable {
    let id = UUID()
    let request: LanguageServerApprovalRequest
    let ownerID: UUID
    let confirm: @MainActor () async -> Void
    let decline: @MainActor () -> Void
}

enum EditorTransientPanel: String, Identifiable {
    case commandPalette
    case workspaceSearch
    case navigation
    case git
    case build
    case buildSystem
    case terminal
    case languageServers
    case plugins
    case marketplace
    case recentItems
    case sublimeImport
    case languageSelection
    case projectSettings
    case macroSnippet
    case documentFormat
    case softwareUpdate
    case colorScheme
    case languageTools

    var id: String { rawValue }
}

typealias ClosePreparation = (@escaping (Bool) -> Void) -> Void

enum SecurityScopedAccessSource: Sendable {
    /// The URL was returned directly by an NSOpenPanel/drag/Finder event and
    /// may be converted into a persistent security-scoped bookmark.
    case userSelected
    /// The URL came from session/recent state and must resolve an existing grant.
    case persisted
}

enum EditorActionOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(message: String)
    case failedPresentation(CommandPresentation)

    var didComplete: Bool {
        if case .completed = self { return true }
        return false
    }
}

struct EditorDropOutcome: Equatable, Sendable {
    let providerCount: Int
    let truncatedCount: Int
    let parseFailureCount: Int
    let directoryRootSuccessCount: Int
    let directoryRootFailureCount: Int
    let fileOpenSuccessCount: Int
    let fileOpenFailureCount: Int
    let fileNotFoundCount: Int
    let fileInvalidCount: Int

    var successCount: Int {
        directoryRootSuccessCount + fileOpenSuccessCount
    }

    var failedCount: Int {
        parseFailureCount
            + directoryRootFailureCount
            + fileOpenFailureCount
    }

    var rejectedCount: Int {
        fileNotFoundCount + fileInvalidCount
    }

    var allFailed: Bool {
        successCount == 0
            && (providerCount > 0
                || failedCount > 0
                || rejectedCount > 0
                || truncatedCount > 0)
    }

    var feedbackMessage: String {
        [
            "\(successCount) succeeded",
            "\(rejectedCount) rejected",
            "\(truncatedCount) truncated",
            "\(directoryRootSuccessCount) folders added",
            "\(directoryRootFailureCount) folders failed",
            "\(fileOpenSuccessCount) files opened",
            "\(fileNotFoundCount) files missing",
            "\(fileInvalidCount) files invalid",
            "\(fileOpenFailureCount) files failed to open",
            "\(parseFailureCount) drop items could not be parsed"
        ].joined(separator: ", ") + "."
    }
}

struct EditorFilePanelCopy: Equatable {
    let title: String
    let message: String
    let prompt: String

    static func open(
        locale: EditorLocale, forcedEncoding: TextEncoding?
    ) -> EditorFilePanelCopy {
        EditorFilePanelCopy(
            title: forcedEncoding.map {
                locale.localizedApp(.openUsingEncoding(name: $0.displayName))
            } ?? locale.localizedApp(.openFiles),
            message: locale.localizedApp(.chooseTextFilesToOpen),
            prompt: locale.localizedApp(.openFiles)
        )
    }

    static func save(
        locale: EditorLocale, documentName: String
    ) -> EditorFilePanelCopy {
        EditorFilePanelCopy(
            title: locale.localizedApp(.saveDocument(name: documentName)),
            message: locale.localizedApp(.chooseWhereToSaveDocument),
            prompt: locale.localizedApp(.save)
        )
    }
}

/// The native Open panel intentionally stays broad: the editor has its own
/// bounded text/binary detection, and restricting the chooser to a short UTI
/// list would hide legitimate source files and make Finder/Open inconsistent.
/// Keeping this value type independent from AppKit makes the multi-file
/// contract testable without presenting a panel.
struct EditorOpenPanelConfiguration: Equatable {
    let canChooseFiles: Bool
    let canChooseDirectories: Bool
    let allowsMultipleSelection: Bool
    let resolvesAliases: Bool

    static let documentOpen = EditorOpenPanelConfiguration(
        canChooseFiles: true,
        canChooseDirectories: false,
        allowsMultipleSelection: true,
        resolvesAliases: true
    )

    func apply(to panel: NSOpenPanel) {
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.resolvesAliases = resolvesAliases
    }
}

/// UI-owned coordination for panels and multi-step operations. File lifecycle
/// rules remain in AppModel; this object supplies the destinations and explicit
/// confirmations that the model deliberately cannot choose on its own.
@MainActor
final class EditorActionController: ObservableObject {
    let model: AppModel
    let workspace: WorkspaceController
    let securityScopedAccess: SecurityScopedAccessController

    @Published private(set) var isSessionReady = false
    @Published private(set) var isPresentingPanel = false
    @Published private(set) var isOpeningDocuments = false
    @Published private(set) var isSavingAll = false
    @Published private(set) var isResolvingClose = false
    @Published private(set) var isClosingTabsInBulk = false
    @Published private(set) var isClosingApplicationOrWindow = false
    @Published private(set) var isPerformingDestructiveAction = false
    @Published private(set) var isPerformingWorkspaceAction = false
    @Published private(set) var isWorkspaceSettling = false
    @Published private(set) var presentedIssue: EditorActionIssue?
    @Published private(set) var dropNotice: EditorActionNotice?
    @Published private(set) var languageServerApproval: LanguageServerApprovalPresentation?
    @Published private(set) var transientPanel: EditorTransientPanel?
    @Published var reopenEncodingRequest: ReopenEncodingRequest?
    @Published var reloadDiskRequest: ReloadDiskRequest?
    private(set) var locale: EditorLocale

    private var didStartSessionRestore = false
    private var isDrainingExternalURLs = false
    private var pendingExternalURLs: [URL] = []
    private var pendingExternalPaths: Set<String> = []
    private var closeFlowCompletion: ((Bool) -> Void)?
    private var closeFlowDiscardedDocumentRevisions: [EditorDocument.ID: UInt64] = [:]
    private var isCloseFlowPrepared = false
    private var isCommittingCloseFlow = false
    private struct BulkTabCloseFlow {
        let paneIndex: Int
        let documentIDs: [EditorDocument.ID]
        var discardedDocumentRevisions: [EditorDocument.ID: UInt64] = [:]
    }
    private var bulkTabCloseFlow: BulkTabCloseFlow?
    private var preflightClose: (() -> Bool)?
    private var additionalBlockingInteraction: (() -> Bool)?
    private var additionalShutdownBlocker: (() -> Bool)?
    private var transientPanelDidDismiss: ((EditorTransientPanel) -> Void)?
    private var workspaceRootsSubscription: AnyCancellable?
    private var workspaceActivitySubscription: AnyCancellable?
    private var workspaceSettleTask: Task<Void, Never>?
    private var workspaceActivityGeneration: UInt64 = 0
    private var canPersistWorkspaceRoots = false
    let editorConfigController: EditorConfigController

    init(
        model: AppModel,
        workspace: WorkspaceController,
        editorConfigController: EditorConfigController? = nil,
        securityScopedAccess: SecurityScopedAccessController = .shared,
        locale: EditorLocale = .zhCN
    ) {
        self.model = model
        self.workspace = workspace
        self.securityScopedAccess = securityScopedAccess
        self.locale = locale
        self.editorConfigController = editorConfigController
            ?? EditorConfigController.connected(to: workspace)
        model.restoreSecurityScopedFileAccess = { url in
            try securityScopedAccess.accessPersistedURL(
                url, kind: .file, allowingDirectoryAncestor: true
            )
        }
        model.securityScopedFileAccessDidEnd = { [weak workspace, weak model] url in
            guard let workspace, let model,
                  !model.documents.contains(where: {
                      $0.fileURL?.standardizedFileURL == url.standardizedFileURL
                  }) else { return }
            Task { await workspace.service.revokeFileAuthorization(url) }
        }
        model.prepareSecurityScopedFileAccessMoves = { moves in
            try securityScopedAccess.prepareExactFileAccessRebases(moves)
        }
        model.securityScopedFileAccessDidMove = { _, newURL in
            // Preflight has already rebased any exact file bookmark. Exact
            // matches win over directory ancestors, preserving a stronger
            // symlink-target capability for the relocated document.
            try securityScopedAccess.accessPersistedURL(
                newURL, kind: .file, allowingDirectoryAncestor: true
            )
        }
        workspace.setRetainFileAccess { [weak model] url, lease in
            guard let document = model?.documents.first(where: {
                $0.fileURL?.standardizedFileURL == url.standardizedFileURL
            }) else {
                lease.invalidate()
                return
            }
            model?.retainSecurityScopedAccess(lease, for: document)
        }
        let editorConfig = self.editorConfigController
        workspace.setFileSystemChangeHandler {
            [weak model, weak workspace, weak editorConfig] changedURL in
            guard let model, let workspace, let editorConfig else { return }
            let changedPath = changedURL.standardizedFileURL.path
            let prefix = changedPath.hasSuffix("/")
                ? changedPath : changedPath + "/"
            let documents = model.documents.filter { document in
                guard let path = document.fileURL?.standardizedFileURL.path else {
                    return false
                }
                // File-level FSEvents refresh just that open document. A
                // directory/root invalidation still refreshes descendants.
                return path == changedPath || path.hasPrefix(prefix)
            }
            for document in documents {
                await model.checkForExternalChange(document)
            }
            if changedURL.lastPathComponent == ".editorconfig"
                || workspace.roots.contains(where: {
                    $0.url.standardizedFileURL == changedURL.standardizedFileURL
                }) {
                await editorConfig.resolveAll(
                    model.documents, workspaceRoots: workspace.roots
                )
            } else if !documents.isEmpty {
                await editorConfig.resolveAll(
                    documents, workspaceRoots: workspace.roots
                )
            }
        }
        workspaceRootsSubscription = workspace.$roots
            .dropFirst()
            .sink { [weak self] roots in
                self?.workspaceRootsDidChange(roots)
            }
        workspaceActivitySubscription = Publishers.CombineLatest4(
            workspace.$isPresentingPanel,
            workspace.$isChangingRoots,
            workspace.$isRevealingActiveFile,
            workspace.$openingFileURLs
        ).sink { [weak self] activity in
            self?.workspaceActivityDidChange(
                isActive: activity.0 || activity.1 || activity.2 || !activity.3.isEmpty
            )
        }
    }

    convenience init(model: AppModel, locale: EditorLocale = .zhCN) {
        let securityScopedAccess = SecurityScopedAccessController.shared
        let workspace = WorkspaceController(
            maximumEditableByteCount: model.maximumEditableByteCount,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { openedFile in
                _ = model.open(openedFile: openedFile)
            },
            securityScopedAccess: securityScopedAccess
        )
        self.init(
            model: model, workspace: workspace,
            securityScopedAccess: securityScopedAccess, locale: locale
        )
    }

    /// Kept in sync by the window before user interaction. Native panels read
    /// this value only when they are created, so later language changes apply
    /// to the very next presentation without rebuilding the controller.
    func updateLocale(_ locale: EditorLocale) {
        self.locale = locale
    }

    func setPreflightClose(_ action: @escaping () -> Bool) {
        preflightClose = action
    }

    func setAdditionalBlockingInteraction(
        _ action: @escaping () -> Bool,
        shutdownBlocker: @escaping () -> Bool = { false }
    ) {
        additionalBlockingInteraction = action
        additionalShutdownBlocker = shutdownBlocker
    }

    /// Refresh all open workspace documents after a file watcher reports an
    /// `.editorconfig` change. The controller's generations suppress stale
    /// reads when roots or document paths change concurrently.
    func refreshEditorConfigs() async {
        await editorConfigController.resolveAll(
            model.documents,
            workspaceRoots: workspace.roots
        )
    }

    func setTransientPanelDidDismiss(
        _ action: @escaping (EditorTransientPanel) -> Void
    ) {
        transientPanelDidDismiss = action
    }

    var hasBlockingInteraction: Bool {
        isDrainingExternalURLs || hasBlockingInteractionExcludingDrain
    }

    var canExecuteRoutedCommand: Bool {
        isSessionReady
            && !isDrainingExternalURLs
            && !hasBlockingInteractionExcludingDrainAndPalette
    }

    var canExecutePanelCommand: Bool {
        isSessionReady
            && !isDrainingExternalURLs
            && !hasBlockingInteractionExcludingDrainAndPalette
    }

    var isAnyTransientPanelPresented: Bool {
        transientPanel != nil || languageServerApproval != nil || workspace.isBusy
    }

    var isCommandPalettePresented: Bool { transientPanel == .commandPalette }
    var isGitPanelPresented: Bool { transientPanel == .git }
    var isBuildPanelPresented: Bool { transientPanel == .build }
    var isTerminalPanelPresented: Bool { transientPanel == .terminal }
    var isLanguageServersPanelPresented: Bool { transientPanel == .languageServers }

    private var hasBlockingInteractionExcludingDrain: Bool {
        transientPanel != nil
            || hasBlockingInteractionExcludingDrainAndPalette
    }

    private var hasBlockingInteractionExcludingDrainAndPalette: Bool {
        isPresentingPanel
            || isOpeningDocuments
            || isSavingAll
            || isResolvingClose
            || isClosingTabsInBulk
            || isClosingApplicationOrWindow
            || isPerformingDestructiveAction
            || isPerformingWorkspaceAction
            || isWorkspaceSettling
            || reopenEncodingRequest != nil
            || reloadDiskRequest != nil
            || languageServerApproval != nil
            || presentedIssue != nil
            || workspace.isBusy
            || !workspace.openingFileURLs.isEmpty
            || additionalBlockingInteraction?() == true
            || model.pendingCloseRequest != nil
            || model.presentedIssue != nil
            || model.documents.contains(where: { $0.isSaving })
    }

    private var hasBlockingInteractionForBulkTabClose: Bool {
        isPresentingPanel
            || isOpeningDocuments
            || isSavingAll
            || isResolvingClose
            || isClosingApplicationOrWindow
            || isPerformingDestructiveAction
            || isPerformingWorkspaceAction
            || isWorkspaceSettling
            || reopenEncodingRequest != nil
            || reloadDiskRequest != nil
            || languageServerApproval != nil
            || presentedIssue != nil
            || workspace.isBusy
            || !workspace.openingFileURLs.isEmpty
            || additionalBlockingInteraction?() == true
            || model.pendingCloseRequest != nil
            || model.presentedIssue != nil
            || model.documents.contains(where: { $0.isSaving })
    }

    private var hasBlockingInteractionForWorkspaceOpen: Bool {
        isPresentingPanel
            || isOpeningDocuments
            || isSavingAll
            || isResolvingClose
            || isClosingTabsInBulk
            || isClosingApplicationOrWindow
            || isPerformingDestructiveAction
            || isPerformingWorkspaceAction
            || isWorkspaceSettling
            || reopenEncodingRequest != nil
            || reloadDiskRequest != nil
            || languageServerApproval != nil
            || presentedIssue != nil
            || workspace.isBusy
            || !workspace.openingFileURLs.isEmpty
            || model.pendingCloseRequest != nil
            || model.presentedIssue != nil
            || model.documents.contains(where: { $0.isSaving })
    }

    func restoreSessionIfNeeded() async {
        guard !didStartSessionRestore else { return }
        didStartSessionRestore = true
        await model.restoreSession()
        let restoredFolders = model.workspaceFolders
        let restoredPrimaryFolder = model.workspaceFolder
        await workspace.restoreRoots(
            restoredFolders.map(URL.init(fileURLWithPath:)),
            primaryURL: restoredPrimaryFolder.map(URL.init(fileURLWithPath:))
        )
        isSessionReady = true
        if workspace.issue == nil {
            canPersistWorkspaceRoots = true
            synchronizeWorkspaceSession()
        }
        await editorConfigController.resolveAll(
            model.documents,
            workspaceRoots: workspace.roots
        )
        await drainExternalURLsIfPossible()
    }

    /// Keeps clean tabs in sync with disk and turns changes to dirty tabs into
    /// the explicit conflict state rendered by the window.
    func runExternalChangeMonitor() async {
        await restoreSessionIfNeeded()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if NSApplication.shared.isActive, !hasBlockingInteraction, !isDrainingExternalURLs {
                await model.checkForExternalChanges()
                await refreshEditorConfigs()
            }
        }
    }

    func enqueueExternalURLs(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let canonicalURL = url.standardizedFileURL
            guard pendingExternalPaths.insert(canonicalURL.path).inserted else { continue }
            pendingExternalURLs.append(canonicalURL)
        }
        scheduleExternalURLDrainIfPossible()
    }

    func handleDroppedURLs(_ urls: [URL]) async {
        await handleDroppedURLs(
            DropLoadSummary.plan(
                urls: urls,
                providerCount: urls.count,
                parseFailureCount: 0
            )
        )
    }

    func handleDroppedURLs(_ summary: DropLoadSummary) async {
        guard isSessionReady, !hasBlockingInteraction else { return }
        dropNotice = nil
        model.clearPresentedIssue()

        var directories: [URL] = []
        var files: [URL] = []
        var fileNotFoundCount = 0
        for url in summary.urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            ) else {
                fileNotFoundCount += 1
                continue
            }
            if isDirectory.boolValue { directories.append(url) }
            else { files.append(url) }
        }

        var directoryRootSuccessCount = 0
        var directoryRootFailureCount = 0
        if let first = directories.first {
            if await replaceWorkspaceRootForDrop(first) {
                directoryRootSuccessCount += 1
            } else {
                directoryRootFailureCount += 1
            }
            for directory in directories.dropFirst() {
                if await addWorkspaceRootForDrop(directory) {
                    directoryRootSuccessCount += 1
                } else {
                    directoryRootFailureCount += 1
                }
            }
            if directoryRootSuccessCount > 0 {
                synchronizeWorkspaceSession()
            }
        }

        var fileOpenSuccessCount = 0
        var fileOpenFailureCount = 0
        var fileInvalidCount = 0
        for file in files {
            switch await openDroppedFile(at: file) {
            case .opened:
                fileOpenSuccessCount += 1
            case .notFound:
                fileNotFoundCount += 1
            case .invalid:
                fileInvalidCount += 1
            case .failed:
                fileOpenFailureCount += 1
            }
        }

        let outcome = EditorDropOutcome(
            providerCount: summary.providerCount,
            truncatedCount: summary.truncatedCount,
            parseFailureCount: summary.parseFailureCount,
            directoryRootSuccessCount: directoryRootSuccessCount,
            directoryRootFailureCount: directoryRootFailureCount,
            fileOpenSuccessCount: fileOpenSuccessCount,
            fileOpenFailureCount: fileOpenFailureCount,
            fileNotFoundCount: fileNotFoundCount,
            fileInvalidCount: fileInvalidCount
        )
        presentDropFeedback(outcome)
    }

    private enum DroppedFileOpenResult {
        case opened
        case notFound
        case invalid
        case failed
    }

    private func replaceWorkspaceRootForDrop(_ url: URL) async -> Bool {
        let previousIssue = workspace.issue
        await workspace.restoreRoots(
            [url], primaryURL: url, accessSource: .userSelected
        )
        let succeeded = workspace.roots.first(where: \.isPrimary)?.url.standardizedFileURL
            == url.standardizedFileURL
        if workspace.issue != previousIssue { workspace.dismissIssue() }
        return succeeded
    }

    private func addWorkspaceRootForDrop(_ url: URL) async -> Bool {
        let previousIssue = workspace.issue
        let didAdd = await workspace.addRoot(
            url, accessSource: .userSelected
        )
        if workspace.issue != previousIssue { workspace.dismissIssue() }
        return didAdd
    }

    private func openDroppedFile(at url: URL) async -> DroppedFileOpenResult {
        let fileURL = url.standardizedFileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return .notFound
        }
        if let existing = model.documents.first(where: {
            $0.fileURL?.standardizedFileURL == fileURL
        }) {
            _ = model.selectDocument(
                existing,
                inPaneAt: model.paneLayout.activePaneIndex
            )
            return .opened
        }
        do {
            let lease = try securityScopedAccess.accessUserSelectedURL(
                fileURL, kind: .file
            )
            do {
                try await workspace.service.authorizeFile(lease.url)
                let openedFile = try await workspace.service.openFile(lease.url)
                guard !openedFile.isBinary, !openedFile.isTooLarge else {
                    lease.invalidate()
                    return .invalid
                }
                guard let document = model.open(openedFile: openedFile) else {
                    lease.invalidate()
                    return .failed
                }
                model.retainSecurityScopedAccess(lease, for: document)
                await editorConfigController.resolve(
                    for: document,
                    workspaceRoots: workspace.roots
                )
                return .opened
            } catch let error as WorkspaceServiceError {
                lease.invalidate()
                if case .itemNotFound = error { return .notFound }
                return .failed
            } catch {
                lease.invalidate()
                return .failed
            }
        } catch {
            return .failed
        }
    }

    func newDocument() {
        guard isSessionReady, !hasBlockingInteraction else { return }
        _ = model.newDocument()
    }

    @discardableResult
    func openDocuments(forcedEncoding: TextEncoding? = nil) async -> Bool {
        guard isSessionReady, !hasBlockingInteraction else { return false }
        isOpeningDocuments = true
        defer {
            isOpeningDocuments = false
            scheduleExternalURLDrainIfPossible()
        }
        let panel = NSOpenPanel()
        let copy = EditorFilePanelCopy.open(
            locale: locale, forcedEncoding: forcedEncoding
        )
        panel.title = copy.title
        panel.message = copy.message
        panel.prompt = copy.prompt
        EditorOpenPanelConfiguration.documentOpen.apply(to: panel)

        guard await run(panel) == .OK else { return false }
        var didOpen = false
        for url in panel.urls {
            didOpen = await openAuthorizedSnapshot(
                at: url,
                forcedEncoding: forcedEncoding,
                accessSource: .userSelected
            ) || didOpen
        }
        return didOpen
    }

    func chooseLocalPluginDirectory(locale: EditorLocale) async -> URL? {
        guard isSessionReady, !isPresentingPanel else { return nil }
        let panel = NSOpenPanel()
        panel.title = locale.localizedApp(.installLocalPlugin)
        panel.message = locale.localizedApp(.chooseLocalPluginDirectory)
        panel.prompt = locale.localizedApp(.install)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard await run(panel) == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }

    func installLocalPlugin(
        using pluginController: PluginController,
        locale: EditorLocale
    ) async -> EditorActionOutcome {
        guard let url = await chooseLocalPluginDirectory(locale: locale) else {
            return .cancelled
        }
        do {
            let installed = try withUserSelectedSecurityScope(at: url) { authorisedURL in
                pluginController.installLocalPlugin(from: authorisedURL)
            }
            guard installed else {
                let message = pluginController.issue?.message
                    ?? "The local plugin could not be installed."
                presentIssue(
                    title: pluginController.issue?.title ?? "Could Not Install Plugin",
                    message: message
                )
                return .failed(message: message)
            }
            return .completed
        } catch {
            let message = error.localizedDescription
            presentIssue(
                title: locale.localizedApp(.couldNotAuthorizePluginFolder),
                message: message
            )
            return .failed(message: message)
        }
    }

    func saveCurrentDocumentOutcome() async -> EditorActionOutcome {
        guard isSessionReady, !isPresentingPanel, let document = model.selectedDocument else {
            return .cancelled
        }
        return await saveOutcome(document)
    }

    @discardableResult
    func saveCurrentDocument() async -> Bool {
        await saveCurrentDocumentOutcome().didComplete
    }

    @discardableResult
    func save(_ document: EditorDocument) async -> Bool {
        await saveOutcome(document).didComplete
    }

    private func saveOutcome(_ document: EditorDocument) async -> EditorActionOutcome {
        guard !document.isSaving else { return .cancelled }
        defer { scheduleExternalURLDrainIfPossible() }
        if document.isUntitled {
            guard let destination = await chooseSaveDestination(for: document) else {
                return .cancelled
            }
            return await saveOutcome(
                document,
                to: destination,
                isSaveAs: true,
                selectedDestination: true
            )
        }
        guard let destination = document.fileURL else { return .cancelled }
        return await saveOutcome(document, to: destination, isSaveAs: false)
    }

    func saveCurrentDocumentAsOutcome() async -> EditorActionOutcome {
        guard isSessionReady, !isPresentingPanel, let document = model.selectedDocument else {
            return .cancelled
        }
        guard let destination = await chooseSaveDestination(for: document) else {
            return .cancelled
        }
        let outcome = await saveOutcome(
            document, to: destination, isSaveAs: true, selectedDestination: true
        )
        scheduleExternalURLDrainIfPossible()
        return outcome
    }

    @discardableResult
    func saveCurrentDocumentAs() async -> Bool {
        await saveCurrentDocumentAsOutcome().didComplete
    }

    func saveAllDocumentsOutcome() async -> EditorActionOutcome {
        guard isSessionReady, !isSavingAll, !isPresentingPanel else { return .cancelled }
        isSavingAll = true
        defer {
            isSavingAll = false
            scheduleExternalURLDrainIfPossible()
        }

        // Capture the order so a comparison tab created during an await does not
        // unexpectedly join the operation halfway through.
        let dirtyDocuments = model.documents.filter(\.isDirty)
        for document in dirtyDocuments {
            if document.isUntitled {
                guard let destination = await chooseSaveDestination(for: document) else {
                    return .cancelled
                }
                let outcome = await saveOutcome(
                    document, to: destination, isSaveAs: true, selectedDestination: true
                )
                guard outcome.didComplete else { return outcome }
            } else {
                let outcome = await saveOutcome(
                    document,
                    to: document.fileURL!,
                    isSaveAs: false
                )
                guard outcome.didComplete else { return outcome }
            }
        }
        return .completed
    }

    @discardableResult
    func saveAllDocuments() async -> Bool {
        await saveAllDocumentsOutcome().didComplete
    }

    @discardableResult
    func requestCloseCurrentDocument() -> Bool {
        guard isSessionReady, !hasBlockingInteraction, let document = model.selectedDocument else {
            return false
        }
        let paneIndex = model.paneLayout.activePaneIndex
        model.requestClose(document, fromPaneAt: paneIndex)
        return true
    }

    func requestCloseCurrentTab() {
        _ = requestCloseCurrentDocument()
    }

    @discardableResult
    func togglePinForCurrentTab() -> Bool {
        guard isSessionReady, !hasBlockingInteraction else { return false }
        return model.togglePinForSelectedDocument() != nil
    }

    func togglePinTab() {
        _ = togglePinForCurrentTab()
    }

    var canCloseOtherTabs: Bool {
        canStartBulkTabClose(.others)
    }

    var canCloseTabsToRight: Bool {
        canStartBulkTabClose(.right)
    }

    var canCloseAllTabs: Bool {
        canStartBulkTabClose(.all)
    }

    var canReopenClosedTab: Bool {
        isSessionReady && !hasBlockingInteraction && model.canReopenClosedTab
    }

    @discardableResult
    func requestCloseOtherTabs() -> Bool {
        requestBulkTabClose(.others)
    }

    func closeOtherTabs() { _ = requestCloseOtherTabs() }

    @discardableResult
    func requestCloseTabsToRight() -> Bool {
        requestBulkTabClose(.right)
    }

    func closeTabsToRight() { _ = requestCloseTabsToRight() }

    @discardableResult
    func requestCloseAllTabs() -> Bool {
        requestBulkTabClose(.all)
    }

    func closeAllTabs() { _ = requestCloseAllTabs() }

    /// Reopen the runtime LIFO entry. The model entry is consumed only after
    /// the authorised read and open/focus succeeds.
    @discardableResult
    func reopenClosedTab() async -> Bool {
        guard canReopenClosedTab,
              let closed = model.mostRecentlyClosedTab else { return false }
        isOpeningDocuments = true
        defer {
            isOpeningDocuments = false
            scheduleExternalURLDrainIfPossible()
        }
        let opened: Bool
        let fileURL = closed.url.standardizedFileURL
        if let existing = model.documents.first(where: {
            $0.fileURL?.standardizedFileURL == fileURL
        }) {
            _ = model.selectDocument(
                existing,
                inPaneAt: model.paneLayout.activePaneIndex
            )
            opened = true
        } else {
            do {
                let lease = try securityScopedAccess.accessPersistedURL(
                    fileURL, kind: .file, allowingDirectoryAncestor: true
                )
                try await workspace.service.authorizeFile(lease.url)
                let file = try await workspace.service.openFile(
                    lease.url,
                    forcedEncoding: closed.encoding
                )
                if let document = model.open(openedFile: file) {
                    model.retainSecurityScopedAccess(lease, for: document)
                    opened = true
                } else {
                    lease.invalidate()
                    opened = false
                }
            } catch {
                presentedIssue = EditorActionIssue(
                    title: "Could Not Reopen Tab",
                    message: "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
                opened = false
            }
        }
        if opened { _ = model.consumeRecentlyClosedTab(id: closed.id) }
        return opened
    }

    @discardableResult
    func reopenLastClosedTab() async -> Bool {
        await reopenClosedTab()
    }

    /// Cmd-1...Cmd-9 wiring calls this one-based API.
    func selectTab(number: Int) {
        guard isSessionReady, !hasBlockingInteraction else { return }
        _ = model.selectTab(number: number)
    }

    func selectTab(at index: Int) {
        guard (0..<9).contains(index) else { return }
        selectTab(number: index + 1)
    }

    var canUndoCurrentDocument: Bool {
        let viewID = model.paneLayout.activeViewID
        isSessionReady
            && !hasBlockingInteraction
            && model.selectedDocument?.buffer.canUndo(for: viewID) == true
    }

    var canRedoCurrentDocument: Bool {
        let viewID = model.paneLayout.activeViewID
        isSessionReady
            && !hasBlockingInteraction
            && model.selectedDocument?.buffer.canRedo(for: viewID) == true
    }

    func undoCurrentDocument() {
        guard canUndoCurrentDocument else { return }
        _ = model.undo()
    }

    func redoCurrentDocument() {
        guard canRedoCurrentDocument else { return }
        _ = model.redo()
    }

    func presentCommandPalette() {
        guard canExecuteRoutedCommand else { return }
        transientPanel = .commandPalette
    }

    func dismissCommandPalette() {
        dismissTransientPanel(.commandPalette)
        scheduleExternalURLDrainIfPossible()
    }

    func presentGitPanel() {
        guard canExecuteRoutedCommand else { return }
        transientPanel = .git
    }

    func dismissGitPanel() {
        dismissTransientPanel(.git)
        scheduleExternalURLDrainIfPossible()
    }

    func presentBuildPanel() {
        guard canExecuteRoutedCommand else { return }
        transientPanel = .build
    }

    func presentBuildSystemPalette() {
        guard canExecuteRoutedCommand else { return }
        transientPanel = .buildSystem
    }

    func dismissBuildPanel() {
        dismissTransientPanel(.build)
        scheduleExternalURLDrainIfPossible()
    }

    func presentTerminalPanel() {
        guard canExecuteRoutedCommand else { return }
        transientPanel = .terminal
    }

    func dismissTerminalPanel() {
        dismissTransientPanel(.terminal)
        scheduleExternalURLDrainIfPossible()
    }

    func toggleTransientPanel(_ panel: EditorTransientPanel) {
        if transientPanel == panel {
            dismissTransientPanel(panel)
            return
        }
        if let current = transientPanel {
            transientPanelDidDismiss?(current)
            transientPanel = panel
        } else {
            presentTransientPanel(panel)
        }
    }

    func presentTransientPanel(_ panel: EditorTransientPanel) {
        guard isSessionReady, !isDrainingExternalURLs,
              !hasBlockingInteractionExcludingTransientPanel else { return }
        transientPanel = panel
    }

    /// Used when a controller publishes its own presentation state from a
    /// routed command. It atomically replaces an existing palette/sheet while
    /// still dismissing that panel's controller-owned state.
    func transitionToTransientPanel(_ panel: EditorTransientPanel) {
        if let current = transientPanel, current != panel {
            transientPanelDidDismiss?(current)
            transientPanel = panel
        } else if transientPanel == nil {
            presentTransientPanel(panel)
        }
    }

    func replaceTransientPanel(
        _ current: EditorTransientPanel, with replacement: EditorTransientPanel
    ) {
        guard transientPanel == current else { return }
        transientPanelDidDismiss?(current)
        transientPanel = replacement
    }

    func dismissTransientPanel(_ panel: EditorTransientPanel? = nil) {
        guard panel == nil || transientPanel == panel else { return }
        let dismissed = transientPanel
        transientPanel = nil
        if let dismissed { transientPanelDidDismiss?(dismissed) }
        scheduleExternalURLDrainIfPossible()
    }

    func resumeDeferredActions() {
        scheduleExternalURLDrainIfPossible()
    }

    func prepareForRoutedCommand() async {
        guard let dismissed = transientPanel else { return }
        transientPanel = nil
        transientPanelDidDismiss?(dismissed)
        await Task.yield()
    }

    private var hasBlockingInteractionExcludingTransientPanel: Bool {
        isPresentingPanel
            || isOpeningDocuments
            || isSavingAll
            || isResolvingClose
            || isClosingTabsInBulk
            || isClosingApplicationOrWindow
            || isPerformingDestructiveAction
            || isPerformingWorkspaceAction
            || isWorkspaceSettling
            || reopenEncodingRequest != nil
            || reloadDiskRequest != nil
            || presentedIssue != nil
            || workspace.isBusy
            || !workspace.openingFileURLs.isEmpty
            || additionalBlockingInteraction?() == true
            || model.pendingCloseRequest != nil
            || model.presentedIssue != nil
            || model.documents.contains(where: { $0.isSaving })
    }

    @discardableResult
    func openWorkspaceFolder() async -> Bool {
        guard isSessionReady, !hasBlockingInteraction else { return false }
        isPerformingWorkspaceAction = true
        defer { isPerformingWorkspaceAction = false }
        guard await workspace.openFolder(locale: locale) else { return false }
        synchronizeWorkspaceSession()
        return true
    }

    @discardableResult
    func addWorkspaceFolder() async -> Bool {
        guard isSessionReady, !hasBlockingInteraction, !workspace.roots.isEmpty else {
            return false
        }
        isPerformingWorkspaceAction = true
        defer { isPerformingWorkspaceAction = false }
        guard await workspace.addFolder(locale: locale) else { return false }
        synchronizeWorkspaceSession()
        return true
    }

    @discardableResult
    func openWorkspaceFile(
        at url: URL,
        selectingUTF16Range range: NSRange? = nil
    ) async -> EditorDocument? {
        guard isSessionReady,
              !isDrainingExternalURLs,
              !hasBlockingInteractionForWorkspaceOpen
        else { return nil }
        isOpeningDocuments = true
        defer {
            isOpeningDocuments = false
            scheduleExternalURLDrainIfPossible()
        }
        guard await openAuthorizedSnapshot(at: url, authorizeDirectFile: false),
              let document = model.documents.first(where: {
                  $0.fileURL?.standardizedFileURL == url.standardizedFileURL
              }) else { return nil }
        if let range {
            let lowerBound = min(max(0, range.location), document.buffer.utf16Length)
            let upperBound = min(
                max(lowerBound, NSMaxRange(range)),
                document.buffer.utf16Length
            )
            _ = model.setSelection(
                .single(anchor: lowerBound, head: upperBound),
                for: document.sessionDocumentID,
                viewID: model.paneLayout.activeViewID
            )
        }
        return document
    }

    func commandRoutingContext() -> CommandRoutingContext {
        commandRoutingContext(hasFindResults: false, hasGitRepository: false)
    }

    func commandRoutingContext(
        hasFindResults: Bool,
        hasGitRepository: Bool,
        hasNavigationHistory: Bool = false,
        hasLanguageService: Bool = false
    ) -> CommandRoutingContext {
        let document = model.selectedDocument
        let selection = document.map { document in
            model.selection(
                for: document.sessionDocumentID,
                viewID: model.paneLayout.activeViewID
            )
        }
        return CommandRoutingContext(
            hasDocument: document != nil,
            hasSavedDocument: document?.fileURL != nil,
            hasWorkspace: !workspace.roots.isEmpty,
            hasSelection: selection?.ranges.contains(where: { !$0.isEmpty }) == true,
            hasFindResults: hasFindResults,
            hasNavigationHistory: hasNavigationHistory,
            hasClosedTab: model.canReopenClosedTab,
            hasGitRepository: hasGitRepository,
            hasLanguageService: hasLanguageService,
            keyBindingContext: .editor
        )
    }

    func synchronizeWorkspaceSession() {
        guard isSessionReady, canPersistWorkspaceRoots else { return }
        synchronizeWorkspaceSession(roots: workspace.roots)
    }

    private func synchronizeWorkspaceSession(roots: [WorkspaceRoot]) {
        let folders = roots.map { $0.url.path }
        let primaryFolder = roots.first(where: \.isPrimary)?.url.path
        guard folders != model.workspaceFolders
                || primaryFolder != model.workspaceFolder else { return }
        model.configureSessionWorkspace(
            folders: folders,
            primaryFolder: primaryFolder,
            project: model.sessionProject
        )
    }

    private func workspaceRootsDidChange(_ roots: [WorkspaceRoot]) {
        guard isSessionReady else { return }
        canPersistWorkspaceRoots = true
        synchronizeWorkspaceSession(roots: roots)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.editorConfigController.resolveAll(
                self.model.documents,
                workspaceRoots: roots
            )
        }
    }

    private func saveOutcome(
        _ document: EditorDocument,
        to destination: URL,
        isSaveAs: Bool,
        selectedDestination: Bool = false
    ) async -> EditorActionOutcome {
        let replacementLease: SecurityScopedResourceLease?
        do {
            if selectedDestination {
                replacementLease = try beginUserSelectedFileAccess(destination)
            } else {
                replacementLease = nil
            }
        } catch {
            presentedIssue = EditorActionIssue(
                title: "Could Not Authorize Save Location",
                message: "\(destination.lastPathComponent): \(error.localizedDescription)"
            )
            return .failed(message: presentedIssue?.message ?? error.localizedDescription)
        }
        let lineEnding = await editorConfigController.lineEndingForSave(
            document: document,
            destination: destination,
            workspaceRoots: workspace.roots,
            allowMissingTarget: isSaveAs
        )
        let modelOutcome = await model.saveOutcome(
            document,
            to: destination,
            usingResolvedLineEnding: lineEnding,
            isSaveAs: isSaveAs
        )
        if modelOutcome.reachedDestination {
            if let replacementLease {
                model.retainSecurityScopedAccess(replacementLease, for: document)
                do {
                    try persistUserSelectedFileAccess(destination)
                } catch {
                    presentedIssue = EditorActionIssue(
                        title: "File Saved, Access Not Remembered",
                        message: "The file was saved, but macOS access could not be persisted: \(error.localizedDescription)"
                    )
                    // The write itself succeeded. Returning true prevents a
                    // close flow from asking the user to save the clean tab a
                    // second time; relaunch will require re-authorisation.
                    return .completed
                }
            }
            await editorConfigController.resolve(
                for: document,
                workspaceRoots: workspace.roots
            )
        } else {
            replacementLease?.invalidate()
        }
        switch modelOutcome {
        case .complete, .completeWithCleanupWarning:
            return .completed
        case let .durabilityUnconfirmed(notice):
            return .failedPresentation(.app(.fileSaveNotice(notice)))
        case .failed:
            break
        }
        if let issue = model.presentedIssue {
            return .failedPresentation(.appModel(issue))
        }
        return .failed(
            message: presentedIssue?.message ?? "The document could not be saved."
        )
    }

    private func save(
        _ document: EditorDocument,
        to destination: URL,
        isSaveAs: Bool,
        selectedDestination: Bool = false
    ) async -> Bool {
        await saveOutcome(
            document, to: destination, isSaveAs: isSaveAs,
            selectedDestination: selectedDestination
        ).didComplete
    }

    private func beginUserSelectedFileAccess(
        _ url: URL
    ) throws -> SecurityScopedResourceLease {
        do {
            return try securityScopedAccess.beginUserSelectedAccess(url)
        } catch {
            guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            else { throw error }
            return SecurityScopedResourceLease(url: url.standardizedFileURL)
        }
    }

    private func persistUserSelectedFileAccess(_ url: URL) throws {
        do {
            try securityScopedAccess.persistUserSelectedURL(url, kind: .file)
        } catch {
            guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            else { throw error }
        }
    }

    private func workspaceActivityDidChange(isActive: Bool) {
        workspaceActivityGeneration &+= 1
        let generation = workspaceActivityGeneration
        isWorkspaceSettling = true
        workspaceSettleTask?.cancel()
        guard !isActive else { return }
        workspaceSettleTask = Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            guard let self, !Task.isCancelled,
                  self.workspaceActivityGeneration == generation else { return }
            self.isWorkspaceSettling = false
            self.workspaceSettleTask = nil
            self.scheduleExternalURLDrainIfPossible()
        }
    }

    func requestClose(_ document: EditorDocument) {
        guard isSessionReady, !hasBlockingInteraction else { return }
        model.requestClose(document)
    }

    func requestClose(_ document: EditorDocument, fromPaneAt paneIndex: Int) {
        guard isSessionReady, !hasBlockingInteraction else { return }
        model.requestClose(document, fromPaneAt: paneIndex)
    }

    @discardableResult
    private func requestBulkTabClose(_ scope: TabCloseScope) -> Bool {
        guard canStartBulkTabClose(scope) else { return false }
        let paneIndex = model.paneLayout.activePaneIndex
        let targets = model.documentsToClose(scope, inPaneAt: paneIndex)
        guard !targets.isEmpty else { return false }
        guard model.flushSession() else { return false }
        bulkTabCloseFlow = BulkTabCloseFlow(
            paneIndex: paneIndex,
            documentIDs: targets.map(\.id)
        )
        isClosingTabsInBulk = true
        continueBulkTabCloseIfNeeded()
        return true
    }

    private func canStartBulkTabClose(_ scope: TabCloseScope) -> Bool {
        isSessionReady
            && !isClosingTabsInBulk
            && !hasBlockingInteractionForBulkTabClose
            && !model.documentsToClose(scope).isEmpty
    }

    private func continueBulkTabCloseIfNeeded() {
        guard isClosingTabsInBulk, let flow = bulkTabCloseFlow else { return }
        if let dirtyDocument = flow.documentIDs.lazy.compactMap({ id in
            model.documents.first(where: { $0.id == id })
        }).first(where: { document in
            model.referenceCount(for: document) == 1
                && document.isDirty
                && flow.discardedDocumentRevisions[document.id]
                    != document.buffer.revision
        }) {
            model.requestClose(dirtyDocument)
            return
        }

        let committed = model.commitReviewedTabClose(
            documentIDs: flow.documentIDs,
            fromPaneAt: flow.paneIndex,
            reviewedDirtyDocumentRevisions: flow.discardedDocumentRevisions
        )
        finishBulkTabClose()
        if !committed {
            presentedIssue = EditorActionIssue(
                title: "Could Not Close Tabs",
                message: "The tab set changed while it was being reviewed. No unreviewed changes were discarded."
            )
        }
    }

    private func scheduleBulkTabCloseContinuation() {
        guard isClosingTabsInBulk else { return }
        Task { @MainActor [weak self] in
            // Allow the current alert to dismiss before publishing the next
            // request, matching the serial application-close review.
            await Task.yield()
            self?.continueBulkTabCloseIfNeeded()
        }
    }

    private func finishBulkTabClose() {
        bulkTabCloseFlow = nil
        isClosingTabsInBulk = false
        scheduleExternalURLDrainIfPossible()
    }

    func resolvePendingCloseBySaving() async {
        guard !isResolvingClose,
              let request = model.pendingCloseRequest,
              let document = model.documents.first(where: { $0.id == request.documentID })
        else { return }

        isResolvingClose = true
        defer {
            isResolvingClose = false
            scheduleExternalURLDrainIfPossible()
        }

        let needsNewDestination = document.isUntitled
            || document.externalConflict != nil
            || document.encodingIssue != nil
        let destination: URL?
        if needsNewDestination {
            guard let chosenDestination = await chooseSaveDestination(for: document) else {
                _ = await model.resolveClose(.cancel)
                if isClosingTabsInBulk { finishBulkTabClose() }
                finishCloseFlowIfNeeded(allowingClose: false)
                return
            }
            destination = chosenDestination
        } else {
            destination = nil
        }

        if isClosingTabsInBulk {
            let saved: Bool
            if let destination {
                saved = await save(
                    document, to: destination, isSaveAs: true, selectedDestination: true
                )
            } else {
                guard let fileURL = document.fileURL else { return }
                saved = await save(document, to: fileURL, isSaveAs: false)
            }
            guard saved, !document.isDirty else { return }
            _ = await model.resolveClose(.cancel)
            scheduleBulkTabCloseContinuation()
        } else if isClosingApplicationOrWindow {
            let saved: Bool
            if let destination {
                saved = await save(
                    document, to: destination, isSaveAs: true, selectedDestination: true
                )
            } else {
                guard let fileURL = document.fileURL else { return }
                saved = await save(document, to: fileURL, isSaveAs: false)
            }
            guard saved, !document.isDirty else { return }
            _ = await model.resolveClose(.cancel)
            scheduleCloseFlowContinuation()
        } else {
            let saved: Bool
            if let destination {
                saved = await save(
                    document, to: destination, isSaveAs: true,
                    selectedDestination: true
                )
            } else {
                guard let fileURL = document.fileURL else { return }
                saved = await save(document, to: fileURL, isSaveAs: false)
            }
            guard saved, !document.isDirty else { return }
            let didClose = await model.resolveClose(.discard)
            if didClose { scheduleCloseFlowContinuation() }
        }
    }

    func resolvePendingCloseByDiscarding() async {
        guard !isResolvingClose else { return }
        isResolvingClose = true
        defer {
            isResolvingClose = false
            scheduleExternalURLDrainIfPossible()
        }

        if isClosingTabsInBulk, let request = model.pendingCloseRequest {
            if let document = model.documents.first(where: {
                $0.id == request.documentID
            }) {
                bulkTabCloseFlow?.discardedDocumentRevisions[request.documentID] =
                    document.buffer.revision
            }
            _ = await model.resolveClose(.cancel)
            scheduleBulkTabCloseContinuation()
        } else if isClosingApplicationOrWindow, let request = model.pendingCloseRequest {
            // Delay removal until the application-wide commit. Keep the exact
            // reviewed revision so a later edit can never be discarded by a
            // stale approval.
            if let document = model.documents.first(where: {
                $0.id == request.documentID
            }) {
                closeFlowDiscardedDocumentRevisions[request.documentID] =
                    document.buffer.revision
            }
            _ = await model.resolveClose(.cancel)
            scheduleCloseFlowContinuation()
        } else {
            _ = await model.resolveClose(.discard)
        }
    }

    func cancelPendingClose() async {
        guard !isResolvingClose else { return }
        _ = await model.resolveClose(.cancel)
        if isClosingTabsInBulk { finishBulkTabClose() }
        finishCloseFlowIfNeeded(allowingClose: false)
        scheduleExternalURLDrainIfPossible()
    }

    @discardableResult
    func chooseEncodingForSave(
        _ encoding: TextEncoding,
        document: EditorDocument
    ) -> Bool {
        guard model.documents.contains(where: { $0 === document }),
              !document.isSaving else { return false }
        document.chooseEncodingForSave(encoding)
        return true
    }

    @discardableResult
    func chooseLineEndingForSave(
        _ lineEnding: LineEnding,
        document: EditorDocument
    ) -> Bool {
        guard model.documents.contains(where: { $0 === document }),
              !document.isSaving else { return false }
        document.chooseLineEndingForSave(lineEnding)
        return true
    }

    @discardableResult
    func requestReopen(
        _ document: EditorDocument,
        using encoding: TextEncoding?
    ) -> Bool {
        guard document.fileURL != nil, !document.isSaving, !hasBlockingInteraction else {
            return false
        }
        reopenEncodingRequest = ReopenEncodingRequest(
            document: document,
            encoding: encoding
        )
        return true
    }

    @discardableResult
    func confirmReopenWithEncoding() async -> Bool {
        guard !isPerformingDestructiveAction, let request = reopenEncodingRequest else {
            return false
        }
        reopenEncodingRequest = nil
        isPerformingDestructiveAction = true
        defer {
            isPerformingDestructiveAction = false
            scheduleExternalURLDrainIfPossible()
        }
        if await model.reopen(request.document, using: request.encoding) {
            await editorConfigController.resolve(
                for: request.document,
                workspaceRoots: workspace.roots
            )
            return true
        }
        if let issue = model.presentedIssue {
            presentedIssue = EditorActionIssue(appModelIssue: issue)
        } else {
            presentedIssue = EditorActionIssue(
                title: "Could Not Reopen File",
                message: "The document changed while it was being reopened. No edits were discarded."
            )
        }
        return false
    }

    func cancelReopenWithEncoding() {
        reopenEncodingRequest = nil
        scheduleExternalURLDrainIfPossible()
    }

    func requestReloadFromDisk(_ document: EditorDocument) {
        guard document.externalConflict?.canCompareOrReload == true, !hasBlockingInteraction else {
            return
        }
        reloadDiskRequest = ReloadDiskRequest(document: document)
    }

    func confirmReloadFromDisk() {
        guard let request = reloadDiskRequest else { return }
        reloadDiskRequest = nil
        if model.reloadDiskVersion(for: request.document) {
            let document = request.document
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.editorConfigController.resolve(
                    for: document,
                    workspaceRoots: self.workspace.roots
                )
            }
        }
        scheduleExternalURLDrainIfPossible()
    }

    func cancelReloadFromDisk() {
        reloadDiskRequest = nil
        scheduleExternalURLDrainIfPossible()
    }

    func keepLocalVersion(_ document: EditorDocument) {
        _ = model.keepLocalVersion(for: document)
        scheduleExternalURLDrainIfPossible()
    }

    func compareDiskVersion(_ document: EditorDocument) {
        _ = model.compareDiskVersion(for: document)
        scheduleExternalURLDrainIfPossible()
    }

    func saveConflictedDocumentAs(_ document: EditorDocument) async {
        guard !isPresentingPanel, !document.isSaving else { return }
        guard let destination = await chooseSaveDestination(for: document) else { return }
        _ = await save(
            document, to: destination, isSaveAs: true, selectedDestination: true
        )
        scheduleExternalURLDrainIfPossible()
    }

    func checkForExternalChange(_ document: EditorDocument) async {
        await model.checkForExternalChange(document)
    }

    func checkForExternalChanges() async {
        guard isSessionReady, !hasBlockingInteraction, !isDrainingExternalURLs else { return }
        await model.checkForExternalChanges()
    }

    func dismissPresentedIssue() {
        model.clearPresentedIssue()
        scheduleExternalURLDrainIfPossible()
    }

    func dismissActionIssue() {
        presentedIssue = nil
        scheduleExternalURLDrainIfPossible()
    }

    func dismissDropNotice() {
        dropNotice = nil
    }

    func handleCommandExecutionResult(_ result: CommandExecutionResult) {
        switch result {
        case .executed:
            break
        case .visiblePanel:
            break
        case .noChange:
            NSSound.beep()
        case let .unavailable(status):
            let message: String
            switch status {
            case .unsupported:
                message = "This command is not supported."
            case let .disabled(.handler(reason)):
                message = reason ?? "This command is unavailable right now."
            case let .disabled(.missingRequirements(requirements)):
                message = "This command requires additional editor context (\(requirements.rawValue))."
            case .enabled:
                message = "This command is unavailable right now."
            }
            presentedIssue = EditorActionIssue(
                title: "Command Unavailable", message: message
            )
        case let .unknownCommand(commandID):
            presentedIssue = EditorActionIssue(
                title: "Unknown Command",
                message: "No command named \(commandID) is available."
            )
        case let .failed(commandID, error):
            let title = CommandCatalog.command(id: commandID)?.englishName ?? commandID
            let presentation: CommandPresentation
            if let signal = error as? CommandHandlerSignal,
               case let .failedPresentation(content) = signal {
                presentation = content
            } else if let error = error as? any AppPresentationError {
                presentation = .app(error.presentationText)
            } else {
                // Unknown/system/tool errors are external payloads. Do not feed
                // their text back through the app-owned English string matcher.
                presentation = CommandPresentation(error.localizedDescription)
            }
            // A routed AppModel failure is now owned by the command feedback
            // alert. Clear the model copy so dismissing it cannot reveal a
            // duplicate alert containing the same failure. Direct model flows
            // (for example close review) still keep their original issue.
            if case .appModel = presentation { model.clearPresentedIssue() }
            presentedIssue = EditorActionIssue(
                title: "Could Not Run \(title)",
                commandPresentation: presentation
            )
        }
    }

    func presentIssue(title: String, message: String) {
        presentedIssue = EditorActionIssue(title: title, message: message)
    }

    func presentIssue(_ issue: NavigationPresentationIssue) {
        presentedIssue = EditorActionIssue(
            title: issue.title, commandPresentation: .navigation(issue)
        )
    }

    func presentIssue(_ issue: LanguageServerPresentationIssue) {
        presentedIssue = EditorActionIssue(
            title: issue.title, commandPresentation: .languageServer(issue)
        )
    }

    func presentNotice(_ message: String) {
        presentedIssue = nil
        dropNotice = EditorActionNotice(message: message)
    }

    private func presentDropFeedback(_ outcome: EditorDropOutcome) {
        if outcome.allFailed {
            presentedIssue = EditorActionIssue(
                title: "Could Not Open Dropped Items",
                message: outcome.feedbackMessage
            )
            dropNotice = nil
            return
        }
        presentedIssue = nil
        dropNotice = EditorActionNotice(message: outcome.feedbackMessage)
    }

    func presentLanguageServerApproval(
        _ request: LanguageServerApprovalRequest,
        ownerID: UUID,
        confirm: @escaping @MainActor () async -> Void,
        decline: @escaping @MainActor () -> Void
    ) {
        guard canPresentLanguageServerApproval(ownerID: ownerID) else { return }
        if languageServerApproval?.ownerID == ownerID {
            languageServerApproval = nil
        }
        languageServerApproval = LanguageServerApprovalPresentation(
            request: request, ownerID: ownerID, confirm: confirm, decline: decline
        )
    }

    func canPresentLanguageServerApproval(ownerID: UUID) -> Bool {
        (languageServerApproval == nil || languageServerApproval?.ownerID == ownerID)
            && transientPanel == nil && presentedIssue == nil
    }

    func withdrawLanguageServerApproval(ownerID: UUID) {
        guard languageServerApproval?.ownerID == ownerID else { return }
        let approval = languageServerApproval
        languageServerApproval = nil
        approval?.decline()
    }

    func confirmLanguageServerApproval() async {
        guard let approval = languageServerApproval else { return }
        languageServerApproval = nil
        await approval.confirm()
    }

    func declineLanguageServerApproval() {
        let approval = languageServerApproval
        languageServerApproval = nil
        approval?.decline()
    }

    func presentIssue(_ error: any Error, title: String) {
        presentIssue(title: title, message: error.localizedDescription)
    }

    /// Reviews this window for Cmd-Q without applying destructive discard
    /// choices. A successful completion leaves a prepared transaction that the
    /// application delegate must either commit or abort. Saves remain immediate.
    func prepareForApplicationTermination(completion: @escaping (Bool) -> Void) {
        guard isSessionReady,
              !model.isRestoringSession,
              !isClosingTabsInBulk,
              !isClosingApplicationOrWindow,
              !isPresentingPanel,
              !isOpeningDocuments,
              !isSavingAll,
              !isResolvingClose,
              !isPerformingDestructiveAction,
              !isPerformingWorkspaceAction,
              !isWorkspaceSettling,
              !isDrainingExternalURLs,
              !workspace.isBusy,
              workspace.openingFileURLs.isEmpty,
              transientPanel == nil,
              languageServerApproval == nil,
              additionalShutdownBlocker?() != true,
              !model.documents.contains(where: { $0.isSaving }),
              presentedIssue == nil,
              model.presentedIssue == nil,
              reopenEncodingRequest == nil,
              reloadDiskRequest == nil,
              model.pendingCloseRequest == nil
        else {
            completion(false)
            return
        }
        synchronizeWorkspaceSession()
        guard model.presentedIssue == nil else {
            completion(false)
            return
        }
        guard preflightClose?() != false else {
            completion(false)
            return
        }
        guard workspace.beginApplicationTerminationPreparation() else {
            completion(false)
            return
        }
        guard model.beginApplicationCloseReview() else {
            workspace.abortApplicationTerminationPreparation()
            completion(false)
            return
        }

        isClosingApplicationOrWindow = true
        if let dismissed = transientPanel { transientPanelDidDismiss?(dismissed) }
        transientPanel = nil
        closeFlowDiscardedDocumentRevisions.removeAll(keepingCapacity: true)
        isCloseFlowPrepared = false
        closeFlowCompletion = completion
        continueCloseFlowIfNeeded()
    }

    /// A standalone window close uses the same review, then immediately commits
    /// that one window. Cmd-Q instead lets LumenApplicationDelegate coordinate
    /// every window between these two phases.
    func prepareForWindowClose(completion: @escaping (Bool) -> Void) {
        prepareForApplicationTermination { [weak self] prepared in
            guard prepared else {
                completion(false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.preflightWindowClosePersistence() else {
                    await self.abortApplicationTerminationPreparation()
                    completion(false)
                    return
                }
                guard self.validateApplicationTerminationPreparation() else {
                    await self.abortApplicationTerminationPreparation()
                    completion(false)
                    return
                }
                guard self.model.commitApplicationCloseSnapshot() else {
                    await self.abortApplicationTerminationPreparation()
                    completion(false)
                    return
                }
                self.commitApplicationTerminationPreparation()
                completion(true)
            }
        }
    }

    /// Synchronously validates every prepared discard before any window in the
    /// application enters its destructive commit.
    func validateApplicationTerminationPreparation() -> Bool {
        guard isClosingApplicationOrWindow, isCloseFlowPrepared,
              !isCommittingCloseFlow, model.pendingCloseRequest == nil,
              presentedIssue == nil, model.presentedIssue == nil,
              !model.documents.contains(where: { $0.isSaving }),
              !workspace.hasInFlightOperation,
              additionalShutdownBlocker?() != true
        else { return false }

        let documentsByID = Dictionary(uniqueKeysWithValues: model.documents.map {
            ($0.id, $0)
        })
        let reviewedDiscardsAreCurrent = closeFlowDiscardedDocumentRevisions.allSatisfy {
            documentID, revision in
            documentsByID[documentID]?.buffer.revision == revision
        }
        let everyDirtyDocumentWasReviewed = model.documents.allSatisfy { document in
            !document.isDirty
                || closeFlowDiscardedDocumentRevisions[document.id]
                    == document.buffer.revision
        }
        guard reviewedDiscardsAreCurrent, everyDirtyDocumentWasReviewed else {
            presentedIssue = EditorActionIssue(
                title: "Could Not Close Window",
                message: "A document changed while application termination was being prepared. No unreviewed changes were discarded."
            )
            return false
        }
        return model.validateReviewedApplicationClose(
            documentRevisions: closeFlowDiscardedDocumentRevisions
        )
    }

    /// Writes the exact state that will remain after commit while every live
    /// document and lease is still recoverable. No persistence occurs after
    /// this succeeds.
    func preflightApplicationTerminationPersistence() -> Bool {
        guard validateApplicationTerminationPreparation() else { return false }
        return model.preflightApplicationClosePersistence(
            documentRevisions: closeFlowDiscardedDocumentRevisions
        )
    }

    private func preflightWindowClosePersistence() -> Bool {
        guard validateApplicationTerminationPreparation() else { return false }
        return model.persistApplicationCloseSnapshot(
            documentRevisions: closeFlowDiscardedDocumentRevisions
        )
    }

    /// Applies a globally validated transaction. No persistence or other
    /// fallible work is permitted beyond this boundary.
    func commitApplicationTerminationPreparation() {
        isCommittingCloseFlow = true
        workspace.lockForApplicationTermination()
        model.commitValidatedApplicationClose(
            documentRevisions: closeFlowDiscardedDocumentRevisions
        )
        // Keep the closing/committing gates engaged across async finalizers.
        // A durable marker already describes the only state allowed to survive
        // this point, so no editor command may create a newer un-staged edit.
        closeFlowCompletion = nil
        closeFlowDiscardedDocumentRevisions.removeAll(keepingCapacity: true)
        isCloseFlowPrepared = false
    }

    /// Rolls back a successful prepare after another window cancels or fails.
    /// Save choices have already reached disk; only deferred discards are reset.
    func abortApplicationTerminationPreparation() async {
        guard isClosingApplicationOrWindow, !isCommittingCloseFlow else { return }
        if model.pendingCloseRequest != nil {
            _ = await model.resolveClose(.cancel)
        }
        finishCloseFlowIfNeeded(allowingClose: false)
    }

    private func drainExternalURLsIfPossible() async {
        guard isSessionReady,
              !isDrainingExternalURLs,
              !hasBlockingInteractionExcludingDrain
        else { return }
        isDrainingExternalURLs = true
        defer { isDrainingExternalURLs = false }

        while !pendingExternalURLs.isEmpty, !hasBlockingInteractionExcludingDrain {
            // Process one URL at a time so each trusted request is authorised and
            // read into exactly one snapshot before it reaches AppModel.
            let url = pendingExternalURLs.removeFirst()
            _ = await openAuthorizedSnapshot(at: url, accessSource: .userSelected)
            pendingExternalPaths.remove(url.path)
            if model.presentedIssue != nil || presentedIssue != nil { return }
        }
    }

    private func scheduleExternalURLDrainIfPossible() {
        guard isSessionReady, !pendingExternalURLs.isEmpty else { return }
        Task { await drainExternalURLsIfPossible() }
    }

    @discardableResult
    func openAuthorizedSnapshot(
        at url: URL,
        forcedEncoding: TextEncoding? = nil,
        authorizeDirectFile: Bool = true,
        accessSource: SecurityScopedAccessSource = .persisted
    ) async -> Bool {
        let fileURL = url.standardizedFileURL
        if let existing = model.documents.first(where: {
            $0.fileURL?.standardizedFileURL == fileURL
        }) {
            _ = model.selectDocument(
                existing,
                inPaneAt: model.paneLayout.activePaneIndex
            )
            return true
        }
        do {
            let lease: SecurityScopedResourceLease?
            if authorizeDirectFile {
                switch accessSource {
                case .userSelected:
                    lease = try securityScopedAccess.accessUserSelectedURL(
                        fileURL, kind: .file
                    )
                case .persisted:
                    lease = try securityScopedAccess.accessPersistedURL(
                        fileURL, kind: .file, allowingDirectoryAncestor: true
                    )
                }
            } else {
                lease = try securityScopedAccess.accessPersistedURL(
                    fileURL, kind: .file, allowingDirectoryAncestor: true
                )
            }
            let authorizedURL = lease?.url ?? fileURL
            if let existing = model.documents.first(where: {
                $0.fileURL?.standardizedFileURL == authorizedURL.standardizedFileURL
            }) {
                lease?.invalidate()
                _ = model.selectDocument(
                    existing, inPaneAt: model.paneLayout.activePaneIndex
                )
                return true
            }
            if authorizeDirectFile {
                try await workspace.service.authorizeFile(authorizedURL)
            }
            let openedFile = try await workspace.service.openFile(
                authorizedURL,
                forcedEncoding: forcedEncoding
            )
            guard let document = model.open(openedFile: openedFile) else {
                lease?.invalidate()
                return false
            }
            if let lease { model.retainSecurityScopedAccess(lease, for: document) }
            await editorConfigController.resolve(
                for: document,
                workspaceRoots: workspace.roots
            )
            return true
        } catch {
            let presentation: CommandPresentation
            if let error = error as? WorkspaceServiceError {
                presentation = .workspace(.workspaceError(
                    error, context: fileURL.lastPathComponent
                ))
            } else if let error = error as? SecurityScopedAccessError {
                presentation = .securityScope(
                    error, context: fileURL.lastPathComponent
                )
            } else {
                presentation = CommandPresentation(
                    "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
            presentedIssue = EditorActionIssue(
                title: "Could Not Open File",
                commandPresentation: presentation
            )
            return false
        }
    }

    /// Runs a synchronous consumer while retaining the Powerbox grant returned
    /// for a local file or directory. Import/install flows copy bounded bytes
    /// during this callback and must not retain the selected URL afterwards.
    func withUserSelectedSecurityScope<T>(
        at url: URL,
        _ body: (URL) throws -> T
    ) throws -> T {
        let lease: SecurityScopedResourceLease
        do {
            lease = try securityScopedAccess.beginUserSelectedAccess(url)
        } catch {
            guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            else { throw error }
            return try body(url.standardizedFileURL)
        }
        defer { lease.invalidate() }
        return try body(lease.url)
    }

    private func scheduleCloseFlowContinuation() {
        guard isClosingApplicationOrWindow else { return }
        Task { @MainActor [weak self] in
            // Give the native alert a full dismissal turn before publishing the
            // next CloseRequest in a multi-tab review.
            await Task.yield()
            self?.continueCloseFlowIfNeeded()
        }
    }

    private func continueCloseFlowIfNeeded() {
        guard isClosingApplicationOrWindow else { return }
        if let dirtyDocument = model.documents.first(where: {
            $0.isDirty
                && closeFlowDiscardedDocumentRevisions[$0.id]
                    != $0.buffer.revision
        }) {
            model.requestClose(dirtyDocument)
            return
        }
        guard !isCloseFlowPrepared else { return }
        isCloseFlowPrepared = true
        let completion = closeFlowCompletion
        closeFlowCompletion = nil
        completion?(true)
    }

    private func finishCloseFlowIfNeeded(allowingClose: Bool) {
        guard isClosingApplicationOrWindow, !isCommittingCloseFlow else { return }
        if !allowingClose {
            model.abortApplicationCloseSnapshot()
            model.cancelApplicationCloseReview()
            workspace.abortApplicationTerminationPreparation()
        }
        let completion = closeFlowCompletion
        closeFlowCompletion = nil
        closeFlowDiscardedDocumentRevisions.removeAll(keepingCapacity: true)
        isCloseFlowPrepared = false
        isCommittingCloseFlow = false
        isClosingApplicationOrWindow = false
        completion?(allowingClose)
        if !allowingClose { scheduleExternalURLDrainIfPossible() }
    }

    private func chooseSaveDestination(for document: EditorDocument) async -> URL? {
        guard !isPresentingPanel else { return nil }
        let panel = NSSavePanel()
        let copy = EditorFilePanelCopy.save(
            locale: locale, documentName: document.displayName
        )
        panel.title = copy.title
        panel.message = copy.message
        panel.prompt = copy.prompt
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = document.displayName
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        guard await run(panel) == .OK else { return nil }
        return panel.url
    }

    private func run(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard !isPresentingPanel else { return .cancel }
        isPresentingPanel = true
        defer {
            isPresentingPanel = false
            scheduleExternalURLDrainIfPossible()
        }

        return await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }
}
