import AppKit
import Combine
@preconcurrency import Foundation
import LumenEditorCore

struct WorkspacePresentationIssue: Identifiable, Equatable {
    enum Title: Equatable, Sendable {
        case app(english: String, chinese: String)
        case verbatim(String)

        static let couldNotAddFolder = app(english: "Could Not Add Folder", chinese: "无法添加文件夹")
        static let couldNotRestoreFolder = app(english: "Could Not Restore Folder", chinese: "无法恢复文件夹")
        static let couldNotRestoreWorkspace = app(english: "Could Not Restore Workspace", chinese: "无法恢复工作区")
        static let couldNotRestorePrimaryFolder = app(english: "Could Not Restore Primary Folder", chinese: "无法恢复主要文件夹")
        static let couldNotRemoveFolder = app(english: "Could Not Remove Folder", chinese: "无法移除文件夹")
        static let couldNotAuthorizeFile = app(english: "Could Not Authorize File", chinese: "无法授权文件")
        static let couldNotOpenFile = app(english: "Could Not Open File", chinese: "无法打开文件")
        static let couldNotReadFolder = app(english: "Could Not Read Folder", chinese: "无法读取文件夹")
        static let couldNotCreateFile = app(english: "Could Not Create File", chinese: "无法创建文件")
        static let couldNotCreateFolder = app(english: "Could Not Create Folder", chinese: "无法创建文件夹")
        static let couldNotRenameItem = app(english: "Could Not Rename Item", chinese: "无法重命名项目")
        static let couldNotMoveItem = app(english: "Could Not Move Item", chinese: "无法移动项目")
        static let couldNotTrashItem = app(english: "Could Not Move Item to Trash", chinese: "无法将项目移到废纸篓")
        static let couldNotRevealItem = app(english: "Could Not Reveal Item", chinese: "无法显示项目")
        static let couldNotRevealFile = app(english: "Could Not Reveal File", chinese: "无法显示文件")
        static let couldNotCopyPath = app(english: "Could Not Copy Path", chinese: "无法复制路径")
        static let couldNotOpenFolder = app(english: "Could Not Open Folder", chinese: "无法打开文件夹")
        static let couldNotMonitorFolder = app(english: "Could Not Monitor Folder", chinese: "无法监控文件夹")
        static let noSavedFileToReveal = app(english: "No Saved File to Reveal", chinese: "没有可显示的已保存文件")
        static let fileOutsideWorkspace = app(english: "File Is Outside the Workspace", chinese: "文件位于工作区之外")
        static let fileNotVisible = app(english: "File Is Not Visible in the Workspace", chinese: "文件在工作区中不可见")
        static let mutationCoordinationFailed = app(english: "Item Changed but Open Documents Could Not Update", chinese: "项目已更改，但无法更新打开的文档")
        static let refreshAfterMutationFailed = app(english: "Item Changed but the Folder Could Not Refresh", chinese: "项目已更改，但无法刷新文件夹")
        static let binaryFile = app(english: "Binary File", chinese: "二进制文件")
        static let fileTooLarge = app(english: "File Is Too Large", chinese: "文件过大")
        static let moveRecoveryFailed = app(english: "Item Moved but Recovery Failed", chinese: "项目已移动，但恢复失败")
        static let couldNotFinalizeWorkspace = app(english: "Could Not Finalize Workspace", chinese: "无法完成工作区更改")
    }

    enum Message: Equatable, Sendable {
        case workspaceError(WorkspaceServiceError, context: String?)
        case app(english: String, chinese: String)
        case verbatim(String)
    }

    let id = UUID()
    let titleContent: Title
    let content: Message

    var title: String {
        EditorLocale.enUS.localizedWorkspaceIssueTitle(titleContent)
    }

    /// Stable English text retained for command-routing compatibility. Views
    /// render `content` with the current runtime locale.
    var message: String {
        EditorLocale.enUS.localizedWorkspaceIssue(content)
    }

    init(title: Title, message: Message) {
        titleContent = title
        content = message
    }

    init(title: Title, verbatim message: String) {
        titleContent = title
        self.content = .verbatim(message)
    }

    init(title: Title, error: WorkspaceServiceError, context: String? = nil) {
        titleContent = title
        self.content = .workspaceError(error, context: context)
    }
}

struct WorkspacePresentationNotice: Identifiable, Equatable {
    let id = UUID()
    let content: WorkspacePresentationIssue.Message

    var message: String { EditorLocale.enUS.localizedWorkspaceIssue(content) }
}

/// Atomically published project filtering state. Consumers that launch
/// asynchronous work must retain this whole value so an exclusions update
/// cannot be observed with the generation from a different commit.
struct WorkspaceProjectExclusionSnapshot: Equatable, Sendable {
    let exclusions: [String]
    let generation: UInt64

    var policy: WorkspaceExclusionPolicy {
        WorkspaceExclusionPolicy(globPatterns: exclusions)
    }
}

/// Atomically published identity for the authorised workspace root set. The
/// generation advances only when the committed roots (including primary
/// semantics) change, never for a failed root transaction.
struct WorkspaceRootSnapshot: Equatable, Sendable {
    let roots: [WorkspaceRoot]
    let generation: UInt64

    static let empty = WorkspaceRootSnapshot(roots: [], generation: 0)

    var ids: [WorkspaceRoot.ID] { roots.map(\.id) }
}

struct WorkspaceFolderPanelCopy: Equatable {
    let title: String
    let message: String
    let prompt: String

    static func open(locale: EditorLocale) -> WorkspaceFolderPanelCopy {
        WorkspaceFolderPanelCopy(
            title: locale.localizedApp(.openFolder),
            message: locale.localizedApp(.chooseWorkspaceFolder),
            prompt: locale.localizedApp(.openFiles)
        )
    }

    static func add(locale: EditorLocale) -> WorkspaceFolderPanelCopy {
        WorkspaceFolderPanelCopy(
            title: locale.localizedApp(.addFolderToWorkspace),
            message: locale.localizedApp(.chooseAnotherWorkspaceFolder),
            prompt: locale.localizedApp(.add)
        )
    }

    static func move(
        itemName: String, locale: EditorLocale
    ) -> WorkspaceFolderPanelCopy {
        WorkspaceFolderPanelCopy(
            title: locale.localizedApp(.moveItem(name: itemName)),
            message: locale.localizedApp(.chooseMoveDestination),
            prompt: locale.localizedApp(.move)
        )
    }
}

/// A filesystem change coordinated across the workspace tree and the owners of
/// open documents/navigation state. `authorizeMutation` receives the proposed
/// value before disk I/O and may throw to veto it. `didMutate` is called only
/// after the capability-scoped core operation succeeds.
enum WorkspaceMutationEvent: Equatable, Sendable {
    case created(url: URL, isDirectory: Bool)
    case renamed(from: URL, to: URL)
    case moved(from: URL, to: URL)
    case trashed(URL)

    var sourceURL: URL? {
        switch self {
        case .created:
            nil
        case let .renamed(from, _), let .moved(from, _):
            from
        case let .trashed(url):
            url
        }
    }
}

final class PreparedWorkspaceMutation {
    private let commitAction: @MainActor () -> Void
    private let abortAction: @MainActor () throws -> Void

    init(
        commit: @escaping @MainActor () -> Void = {},
        abort: @escaping @MainActor () throws -> Void = {}
    ) {
        commitAction = commit
        abortAction = abort
    }

    @MainActor func commit() { commitAction() }
    @MainActor func abort() throws { try abortAction() }
}

enum WorkspaceMutationAuthorizationError: Error, Equatable, LocalizedError, Sendable {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(reason): reason
        }
    }
}

private enum WorkspaceClipboardError: Error, LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "The path could not be written to the clipboard."
    }
}

/// Non-actor lifetime owner for watcher resources. It provides a final
/// cancellation fallback without making a global-actor-isolated controller
/// touch its state from `deinit`. Normal window shutdown still calls the
/// controller's explicit `shutdown()` on the main actor.
private final class WorkspaceWatcherLifecycle {
    var watchers: [String: any WorkspaceFileWatching] = [:]
    var refreshTask: Task<Void, Never>?

    func cancelAll() {
        refreshTask?.cancel()
        refreshTask = nil
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
    }

    deinit { cancelAll() }
}

/// Captures watcher callback ordering before delivery hops onto the main actor.
/// Without this lock-protected token, a callback queued before an exclusions
/// commit could be mistaken for an event produced under the new policy.
private final class WorkspaceWatcherCallbackEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

/// Main-actor adapter between trusted AppKit panels, WorkspaceService's
/// capability boundary, and the SwiftUI file tree. Session ownership stays in
/// the app layer; restored roots can be registered through `restoreRoots(_:)`.
@MainActor
final class WorkspaceController: ObservableObject {
    typealias OpenFileAction = @MainActor (OpenedTextFile) async -> Void
    typealias OpenDocumentURLs = @MainActor () -> [URL]
    typealias AuthorizeMutation = @MainActor (
        WorkspaceMutationEvent
    ) async throws -> Void
    typealias PrepareMutation = @MainActor (
        WorkspaceMutationEvent
    ) async throws -> PreparedWorkspaceMutation?
    typealias DidMutate = @MainActor (WorkspaceMutationEvent) async throws -> Void
    typealias RetainFileAccess = @MainActor (
        URL, SecurityScopedResourceLease
    ) -> Void
    typealias FileSystemChange = @MainActor (URL) async -> Void
    typealias RevealInFinder = @MainActor (URL) -> Void
    typealias WriteClipboard = @MainActor (String) -> Bool
    typealias PrepareSidebarReveal = @MainActor () -> Bool
    typealias ChooseFolder = @MainActor (
        WorkspaceFolderPanelCopy, URL?
    ) async -> URL?

    struct DirectoryState: Equatable {
        enum LoadState: Equatable {
            case unloaded
            case loading
            case loaded
            case failed
        }

        var entries: [WorkspaceEntry] = []
        var loadState: LoadState = .unloaded
        var isTruncated = false
        var errorContent: WorkspacePresentationIssue.Message?
    }

    private struct TreeRootIdentity: Hashable, Sendable {
        let id: WorkspaceRoot.ID
        let url: URL
    }

    private struct TreeRequestSnapshot: Equatable, Sendable {
        let roots: Set<TreeRootIdentity>
        let rootGeneration: UInt64
        let projectExclusions: WorkspaceProjectExclusionSnapshot
    }

    @Published private(set) var roots: [WorkspaceRoot] = []
    @Published private(set) var rootSnapshot = WorkspaceRootSnapshot.empty
    @Published private(set) var projectExclusionSnapshot =
        WorkspaceProjectExclusionSnapshot(exclusions: [], generation: 0)
    @Published private(set) var directoryStates: [URL: DirectoryState] = [:]
    @Published var expandedDirectories: Set<URL> = []
    @Published private(set) var selectedURL: URL?
    @Published var isSidebarVisible = false
    @Published private(set) var isPresentingPanel = false
    @Published private(set) var isChangingRoots = false
    @Published private(set) var isRevealingActiveFile = false
    @Published private(set) var isMutatingItems = false
    @Published private(set) var openingFileURLs: Set<URL> = []
    @Published private(set) var isApplicationTerminationPrepared = false
    @Published private(set) var isApplicationTerminationCommitted = false
    @Published private(set) var issue: WorkspacePresentationIssue?
    @Published private(set) var notice: WorkspacePresentationNotice?

    let service: WorkspaceService

    private let openFileAction: OpenFileAction
    private let openDocumentURLs: OpenDocumentURLs
    private let authorizeMutation: AuthorizeMutation
    private let prepareMutation: PrepareMutation
    private let didMutate: DidMutate
    private let revealInFinderAction: RevealInFinder
    private let writeClipboard: WriteClipboard
    private let chooseFolderAction: ChooseFolder?
    private let securityScopedAccess: SecurityScopedAccessController
    private let fileWatcherFactory: any WorkspaceFileWatcherFactory
    private let watcherDebounceNanoseconds: UInt64
    private var retainFileAccess: RetainFileAccess?
    private var fileSystemChangeAction: FileSystemChange?
    private var securityScopedRootLeases: [String: SecurityScopedResourceLease] = [:]
    private let watcherLifecycle = WorkspaceWatcherLifecycle()
    private let watcherCallbackEpoch = WorkspaceWatcherCallbackEpoch()
    private var rootWatchers: [String: any WorkspaceFileWatching] {
        get { watcherLifecycle.watchers }
        set { watcherLifecycle.watchers = newValue }
    }
    private var pendingChangedEvents: [String: WorkspaceFileSystemEvent] = [:]
    private var pendingWatcherSnapshot: TreeRequestSnapshot?
    private var unwatchedRootPaths: Set<String> = []
    private var rootWatcherTokens: [String: UInt64] = [:]
    private var rootWatcherIDs: [String: WorkspaceRoot.ID] = [:]
    private var nextRootWatcherToken: UInt64 = 0
    private var watcherRefreshTask: Task<Void, Never>? {
        get { watcherLifecycle.refreshTask }
        set { watcherLifecycle.refreshTask = newValue }
    }
    private var directoryGenerations: [URL: UInt64] = [:]
    private var openingFileCounts: [URL: Int] = [:]
    private var revealGeneration: UInt64 = 0
    private var rootMutationGeneration: UInt64 = 0
    private var watcherBatchGeneration: UInt64 = 0

    var projectExclusions: [String] {
        projectExclusionSnapshot.exclusions
    }

    var projectExclusionGeneration: UInt64 {
        projectExclusionSnapshot.generation
    }

    init(
        service: WorkspaceService = WorkspaceService(),
        openDocumentURLs: @escaping OpenDocumentURLs = { [] },
        openFile: @escaping OpenFileAction,
        authorizeMutation: AuthorizeMutation? = nil,
        prepareMutation: @escaping PrepareMutation = { _ in nil },
        didMutate: @escaping DidMutate = { _ in },
        securityScopedAccess: SecurityScopedAccessController = .shared,
        fileWatcherFactory: any WorkspaceFileWatcherFactory
            = FSEventsWorkspaceFileWatcherFactory(),
        watcherDebounceNanoseconds: UInt64 = 250_000_000,
        revealInFinder: @escaping RevealInFinder = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        writeClipboard: @escaping WriteClipboard = { value in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(value, forType: .string)
        },
        chooseFolder: ChooseFolder? = nil
    ) {
        self.service = service
        self.openDocumentURLs = openDocumentURLs
        openFileAction = openFile
        self.authorizeMutation = authorizeMutation ?? { event in
            guard let source = event.sourceURL else { return }
            let sourcePath = source.standardizedFileURL.path
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            let hasAffectedOpenDocument = openDocumentURLs().contains { url in
                let path = url.standardizedFileURL.path
                return path == sourcePath || path.hasPrefix(prefix)
            }
            guard !hasAffectedOpenDocument else {
                throw WorkspaceMutationAuthorizationError.rejected(
                    "Close affected open documents before changing this workspace item."
                )
            }
        }
        self.prepareMutation = prepareMutation
        self.didMutate = didMutate
        self.securityScopedAccess = securityScopedAccess
        self.fileWatcherFactory = fileWatcherFactory
        self.watcherDebounceNanoseconds = watcherDebounceNanoseconds
        revealInFinderAction = revealInFinder
        self.writeClipboard = writeClipboard
        chooseFolderAction = chooseFolder
    }

    convenience init(
        maximumEditableByteCount: Int64,
        openDocumentURLs: @escaping OpenDocumentURLs = { [] },
        openFile: @escaping OpenFileAction,
        authorizeMutation: AuthorizeMutation? = nil,
        prepareMutation: @escaping PrepareMutation = { _ in nil },
        didMutate: @escaping DidMutate = { _ in },
        securityScopedAccess: SecurityScopedAccessController = .shared,
        fileWatcherFactory: any WorkspaceFileWatcherFactory
            = FSEventsWorkspaceFileWatcherFactory(),
        watcherDebounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.init(
            service: WorkspaceService(
                limits: .init(maximumEditableBytes: maximumEditableByteCount)
            ),
            openDocumentURLs: openDocumentURLs,
            openFile: openFile,
            authorizeMutation: authorizeMutation,
            prepareMutation: prepareMutation,
            didMutate: didMutate,
            securityScopedAccess: securityScopedAccess,
            fileWatcherFactory: fileWatcherFactory,
            watcherDebounceNanoseconds: watcherDebounceNanoseconds,
            chooseFolder: nil
        )
    }

    var isBusy: Bool {
        isApplicationTerminationPrepared || isApplicationTerminationCommitted
            || isPresentingPanel || isChangingRoots
            || isRevealingActiveFile || isMutatingItems
    }

    var hasInFlightOperation: Bool {
        isPresentingPanel || isChangingRoots || isRevealingActiveFile
            || isMutatingItems || !openingFileURLs.isEmpty
    }

    @discardableResult
    func beginApplicationTerminationPreparation() -> Bool {
        guard !isApplicationTerminationPrepared,
              !isApplicationTerminationCommitted,
              !hasInFlightOperation else { return false }
        isApplicationTerminationPrepared = true
        return true
    }

    func abortApplicationTerminationPreparation() {
        guard !isApplicationTerminationCommitted else { return }
        isApplicationTerminationPrepared = false
    }

    /// Irreversible gate installed after the application-wide session marker
    /// commits. No later UI callback may mutate disk or add state outside it.
    func lockForApplicationTermination() {
        isApplicationTerminationPrepared = true
        isApplicationTerminationCommitted = true
    }

    func setRetainFileAccess(_ action: @escaping RetainFileAccess) {
        retainFileAccess = action
    }

    func setFileSystemChangeHandler(_ action: @escaping FileSystemChange) {
        fileSystemChangeAction = action
    }

    /// Applies the exclusions committed by the primary project's settings.
    /// Draft edits never affect workspace behavior until ProjectSettingsController
    /// publishes a successful load/save.
    func setProjectExclusions(_ exclusions: [String]) {
        let normalized = exclusions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard normalized != projectExclusions else { return }
        projectExclusionSnapshot = WorkspaceProjectExclusionSnapshot(
            exclusions: normalized, generation: projectExclusionGeneration &+ 1
        )
        watcherCallbackEpoch.advance()
        revealGeneration &+= 1
        isRevealingActiveFile = false
        cancelPendingWatcherRefresh()
        for directory in Array(directoryGenerations.keys) {
            _ = nextDirectoryGeneration(for: directory)
        }
        directoryStates.removeAll()
        refreshWorkspace()
    }

    var projectExclusionPolicy: WorkspaceExclusionPolicy {
        projectExclusionSnapshot.policy
    }

    /// Tears down recursive watchers before the window-owned controller graph
    /// is released. `deinit` remains a final defensive fallback.
    func shutdown() {
        rootMutationGeneration &+= 1
        watcherCallbackEpoch.advance()
        watcherLifecycle.cancelAll()
        rootWatcherTokens.removeAll()
        rootWatcherIDs.removeAll()
        pendingChangedEvents.removeAll()
        pendingWatcherSnapshot = nil
        watcherBatchGeneration &+= 1
        fileSystemChangeAction = nil
        for lease in securityScopedRootLeases.values { lease.invalidate() }
        securityScopedRootLeases.removeAll()
    }

    func state(for directory: URL) -> DirectoryState {
        directoryStates[key(for: directory)] ?? DirectoryState()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func showSidebar() {
        isSidebarVisible = true
    }

    func dismissIssue() {
        issue = nil
    }

    func dismissNotice() {
        notice = nil
    }

    /// Replaces the current in-memory workspace after a trusted folder panel.
    /// Cancellation and failed registration leave the old workspace untouched.
    @discardableResult
    func openFolder(locale: EditorLocale = .zhCN) async -> Bool {
        guard !isBusy else { return false }
        let copy = WorkspaceFolderPanelCopy.open(locale: locale)
        guard let url = await chooseFolder(
            title: copy.title,
            message: copy.message,
            prompt: copy.prompt
        ) else { return false }
        return await replaceWorkspace(with: url, accessSource: .userSelected)
    }

    /// Adds one separately authorised root to the current workspace.
    @discardableResult
    func addFolder(locale: EditorLocale = .zhCN) async -> Bool {
        guard !isBusy else { return false }
        let copy = WorkspaceFolderPanelCopy.add(locale: locale)
        guard let url = await chooseFolder(
            title: copy.title,
            message: copy.message,
            prompt: copy.prompt
        ) else { return false }
        return await addRoot(url, accessSource: .userSelected)
    }

    @discardableResult
    func addRoot(
        _ url: URL,
        makePrimary: Bool = false,
        accessSource: SecurityScopedAccessSource = .persisted
    ) async -> Bool {
        guard !isBusy else { return false }
        isChangingRoots = true
        defer { isChangingRoots = false }
        invalidateTreeOperations()

        do {
            let lease = try securityScopedLease(for: url, source: accessSource)
            do {
                _ = try await service.addRoot(lease.url, makePrimary: makePrimary)
            } catch {
                lease.invalidate()
                throw error
            }
            retainRootLease(lease)
            resetTreeState()
            await synchronizeRoots(showingSidebar: true)
            return true
        } catch {
            present(error, title: .couldNotAddFolder, context: url.lastPathComponent)
            return false
        }
    }

    /// Changes the primary marker for an already-authorised root and publishes
    /// a fresh snapshot. Import transactions use this narrow operation to
    /// restore the exact pre-import primary root during compensation.
    func setPrimaryRoot(_ root: WorkspaceRoot) async throws {
        guard !isApplicationTerminationCommitted else {
            throw WorkspaceMutationAuthorizationError.rejected(
                "The application is terminating."
            )
        }
        try await service.setPrimaryRoot(root.id)
        await synchronizeRoots(showingSidebar: true)
    }

    /// Replaces registered roots with folders supplied by the app's trusted
    /// session/bookmark restore.
    /// Invalid roots remain visible as an error, but do not prevent later
    /// roots in the same bounded session snapshot from being restored. If no
    /// requested root can be restored, the current workspace is left intact so
    /// a stale bookmark cannot turn a failed restore into destructive removal.
    /// This method itself performs no persistence.
    func restoreRoots(
        _ urls: [URL],
        primaryURL: URL? = nil,
        accessSource: SecurityScopedAccessSource = .persisted
    ) async {
        guard !isBusy else { return }
        isChangingRoots = true
        defer { isChangingRoots = false }
        invalidateTreeOperations()
        issue = nil

        var requestedPaths: Set<String> = []
        let existingRoots = await service.registeredRoots()
        let restoredOpenFiles = openDocumentURLs()
        var restoredRootIDsByPath: [String: WorkspaceRoot.ID] = [:]
        var restoredRootCount = 0
        var firstRestoreFailure: WorkspacePresentationIssue?
        for url in urls {
            do {
                let lease = try securityScopedLease(for: url, source: accessSource)
                let authorizedURL = lease.url
                let requestedPath = key(for: url).resolvingSymlinksInPath().path
                let authorizedPath = key(for: authorizedURL).resolvingSymlinksInPath().path
                requestedPaths.insert(authorizedPath)
                let makePrimary = primaryURL.map {
                    key(for: $0).resolvingSymlinksInPath().path == requestedPath
                } ?? false
                let root: WorkspaceRoot
                do {
                    root = try await service.addRoot(
                        authorizedURL, makePrimary: makePrimary
                    )
                } catch let workspaceError as WorkspaceServiceError {
                    if case .rootAlreadyRegistered = workspaceError {
                        lease.invalidate()
                        restoredRootCount += 1
                        continue
                    }
                    lease.invalidate()
                    throw workspaceError
                } catch {
                    lease.invalidate()
                    throw error
                }
                retainRootLease(lease)
                restoredRootCount += 1
                restoredRootIDsByPath[
                    requestedPath
                ] = root.id
            } catch let workspaceError as WorkspaceServiceError {
                if firstRestoreFailure == nil {
                    firstRestoreFailure = WorkspacePresentationIssue(
                        title: .couldNotRestoreFolder,
                        error: workspaceError,
                        context: url.lastPathComponent
                    )
                }
            } catch {
                if firstRestoreFailure == nil {
                    firstRestoreFailure = WorkspacePresentationIssue(
                        title: .couldNotRestoreFolder,
                        verbatim: "\(url.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
        }

        // `restoreRoots` is also the replace operation used by folder drops.
        // Preserve the previous workspace when every requested capability is
        // stale or invalid; successfully restored siblings still proceed.
        if !urls.isEmpty, restoredRootCount == 0, firstRestoreFailure != nil {
            await synchronizeRoots(showingSidebar: true)
            issue = firstRestoreFailure
            return
        }
        let allRegisteredRoots = await service.registeredRoots()
        let requestedRoots = allRegisteredRoots.filter {
            requestedPaths.contains(key(for: $0.url).resolvingSymlinksInPath().path)
        }
        for root in existingRoots where !requestedPaths.contains(
            key(for: root.url).resolvingSymlinksInPath().path
        ) {
            do {
                let retained = retainedFiles(
                    from: restoredOpenFiles,
                    whenRemoving: root,
                    whileKeeping: requestedRoots
                )
                try retainSecurityScopedAccessForFiles(retained)
                try await service.removeRoot(root.id, retainingOpenFiles: retained)
                releaseRootLease(for: root.url)
            } catch {
                await synchronizeRoots(showingSidebar: true)
                present(
                    error,
                    title: .couldNotRestoreWorkspace,
                    context: root.displayName
                )
                return
            }
        }
        if let primaryURL {
            let primaryPath = key(for: primaryURL).resolvingSymlinksInPath().path
            var primaryID = restoredRootIDsByPath[primaryPath]
            if primaryID == nil {
                let registeredRoots = await service.registeredRoots()
                primaryID = registeredRoots.first(where: {
                    key(for: $0.url).resolvingSymlinksInPath().path == primaryPath
                })?.id
            }
            if let primaryID {
                do {
                    try await service.setPrimaryRoot(primaryID)
                } catch {
                    await synchronizeRoots(showingSidebar: true)
                    present(error, title: .couldNotRestorePrimaryFolder)
                    return
                }
            }
        }
        resetTreeState()
        await synchronizeRoots(showingSidebar: !urls.isEmpty)
        releaseLeasesForUnregisteredRoots()
        issue = firstRestoreFailure
    }

    /// Keeps already-open files authorised while removing their former root.
    /// The caller supplies the current saved document URLs because document
    /// ownership deliberately remains outside this workspace adapter.
    @discardableResult
    func removeRoot(_ root: WorkspaceRoot) async -> Bool {
        await removeRoot(root, retainingOpenFiles: openDocumentURLs())
    }

    @discardableResult
    func removeRoot(_ root: WorkspaceRoot, retainingOpenFiles: [URL]) async -> Bool {
        guard !isBusy, openingFileURLs.isEmpty else { return false }
        isChangingRoots = true
        defer { isChangingRoots = false }
        invalidateTreeOperations()

        let retained = retainedFiles(
            from: retainingOpenFiles,
            whenRemoving: root,
            whileKeeping: roots.filter { $0.id != root.id }
        )
        do {
            try retainSecurityScopedAccessForFiles(retained)
            try await service.removeRoot(root.id, retainingOpenFiles: retained)
            releaseRootLease(for: root.url)
            invalidateDirectories(under: root.url)
            expandedDirectories = Set(
                expandedDirectories.filter { !contains(root.url, $0) }
            )
            if selectedURL.map({ contains(root.url, $0) }) == true { selectedURL = nil }
            await synchronizeRoots(showingSidebar: false)
            if roots.count == 1 {
                // Single-root presentation has no root disclosure row, so any
                // cached root expansion bit must not affect its direct contents.
                expandedDirectories.remove(roots[0].url.standardizedFileURL)
            }
            return true
        } catch {
            present(error, title: .couldNotRemoveFolder, context: root.displayName)
            return false
        }
    }

    /// Direct-file capabilities here remain in WorkspaceService. Persistent
    /// App-Sandbox ownership is retained by AppModel after the file is opened.
    func authorizeUserSelectedFiles(_ urls: [URL]) async {
        guard !isApplicationTerminationCommitted else { return }
        for url in urls {
            var lease: SecurityScopedResourceLease?
            do {
                lease = try securityScopedAccess.accessUserSelectedURL(
                    url, kind: .file
                )
                guard let lease else { continue }
                try await service.authorizeFile(lease.url)
                retainFileAccess?(lease.url, lease)
                if retainFileAccess == nil { lease.invalidate() }
            } catch {
                lease?.invalidate()
                present(error, title: .couldNotAuthorizeFile, context: url.lastPathComponent)
                return
            }
        }
    }

    /// Authorises a file chosen by trusted UI before using the app's existing
    /// tab/document opening path. Workspace-tree files use their root grant.
    func authorizeAndOpenUserSelectedFile(_ url: URL) async {
        guard !isApplicationTerminationCommitted else { return }
        let fileURL = key(for: url)
        beginOpening(fileURL)
        defer { finishOpening(fileURL) }
        var lease: SecurityScopedResourceLease?
        do {
            lease = try securityScopedAccess.accessUserSelectedURL(
                url, kind: .file
            )
            guard let lease else { return }
            try await service.authorizeFile(lease.url)
            let opened = try await service.openFile(lease.url)
            guard validateEditable(opened) else {
                lease.invalidate()
                return
            }
            await openFileAction(opened)
            retainFileAccess?(opened.url, lease)
            if retainFileAccess == nil { lease.invalidate() }
        } catch {
            lease?.invalidate()
            present(error, title: .couldNotOpenFile, context: url.lastPathComponent)
        }
    }

    func setExpanded(_ expanded: Bool, directory: URL) {
        guard !isApplicationTerminationCommitted else { return }
        let directory = key(for: directory)
        if expanded {
            expandedDirectories.insert(directory)
            if state(for: directory).loadState == .unloaded {
                loadChildren(of: directory)
            }
        } else {
            expandedDirectories.remove(directory)
        }
    }

    func loadChildren(of directory: URL, force: Bool = false) {
        guard !isApplicationTerminationCommitted else { return }
        let directory = key(for: directory)
        let current = state(for: directory)
        if !force, current.loadState == .loading || current.loadState == .loaded { return }

        let request = treeRequestSnapshot()
        let generation = nextDirectoryGeneration(for: directory)
        directoryStates[directory] = DirectoryState(
            entries: current.entries,
            loadState: .loading,
            isTruncated: current.isTruncated,
            errorContent: nil
        )
        let service = service
        // Freeze the policy with this directory generation. A later project
        // settings commit invalidates the generation and starts fresh loads;
        // the in-flight request must neither retain the controller nor read a
        // newer policy halfway through the older request.
        let exclusions = request.projectExclusions.policy

        Task { @MainActor [weak self] in
            do {
                let listing = try await service.children(
                    of: directory, exclusions: exclusions
                )
                guard let self,
                      self.isCurrentTreeRequest(request),
                      self.directoryGenerations[directory] == generation
                else { return }
                self.directoryStates[directory] = DirectoryState(
                    entries: listing.entries,
                    loadState: .loaded,
                    isTruncated: listing.isTruncated,
                    errorContent: nil
                )
            } catch {
                guard let self,
                      self.isCurrentTreeRequest(request),
                      self.directoryGenerations[directory] == generation
                else { return }
                self.directoryStates[directory] = DirectoryState(
                    loadState: .failed,
                    errorContent: Self.presentationMessage(for: error)
                )
                self.present(error, title: .couldNotReadFolder, context: directory.lastPathComponent)
            }
        }
    }

    func refresh(_ directory: URL) {
        loadChildren(of: directory, force: true)
    }

    func refreshWorkspace() {
        guard !isApplicationTerminationCommitted else { return }
        let directories = Set(roots.map { key(for: $0.url) })
            .union(expandedDirectories)
        for directory in directories {
            loadChildren(of: directory, force: true)
        }
    }

    /// Test/support hook: wait for the debounce task that was current when
    /// called. Production never polls this; FSEvents delivery remains fully
    /// asynchronous.
    func waitForPendingFileSystemRefresh() async {
        for _ in 0..<4 where watcherRefreshTask == nil { await Task.yield() }
        await watcherRefreshTask?.value
    }

    var watchedRootCount: Int { rootWatchers.count }

    func open(_ entry: WorkspaceEntry) {
        guard !isBusy,
              entry.kind == .file || entry.kind == .symbolicLink else { return }
        let fileURL = key(for: entry.url)
        selectedURL = fileURL
        beginOpening(fileURL)
        let service = service
        Task { @MainActor [weak self, openFileAction] in
            defer { self?.finishOpening(fileURL) }
            do {
                // WorkspaceService performs the capability and symlink boundary
                // check; AppModel remains the owner of tab de-duplication and UI.
                let opened = try await service.openFile(entry.url)
                guard self?.validateEditable(opened) == true else { return }
                await openFileAction(opened)
            } catch {
                self?.present(
                    error,
                    title: .couldNotOpenFile,
                    context: entry.name
                )
            }
        }
    }

    // MARK: - Workspace item actions

    /// Creates an empty file without overwriting an existing item, refreshes
    /// its parent, and opens the new file through the normal document path.
    @discardableResult
    func createFile(in directory: URL, named name: String) async -> WorkspaceEntry? {
        guard beginItemMutation() else { return nil }
        defer { isMutatingItems = false }

        let parent = key(for: directory)
        do {
            try validateItemName(name)
            let proposed = parent.appendingPathComponent(name).standardizedFileURL
            let event = WorkspaceMutationEvent.created(url: proposed, isDirectory: false)
            try await authorizeMutation(event)
            let entry = try await service.createFile(in: parent, named: name)
            let committed = WorkspaceMutationEvent.created(
                url: key(for: entry.url),
                isDirectory: false
            )
            _ = await publishCommittedMutation(committed)
            await refreshDirectories([parent])
            selectedURL = key(for: entry.url)
            await openCreatedFile(entry)
            return entry
        } catch {
            present(error, title: .couldNotCreateFile, context: name)
            return nil
        }
    }

    /// Creates one immediate child directory. Name validation and no-clobber
    /// semantics are enforced by WorkspaceService.
    @discardableResult
    func createDirectory(in directory: URL, named name: String) async -> WorkspaceEntry? {
        guard beginItemMutation() else { return nil }
        defer { isMutatingItems = false }

        let parent = key(for: directory)
        do {
            try validateItemName(name)
            let proposed = parent.appendingPathComponent(
                name,
                isDirectory: true
            ).standardizedFileURL
            let event = WorkspaceMutationEvent.created(url: proposed, isDirectory: true)
            try await authorizeMutation(event)
            let entry = try await service.createDirectory(in: parent, named: name)
            let committed = WorkspaceMutationEvent.created(
                url: key(for: entry.url),
                isDirectory: true
            )
            _ = await publishCommittedMutation(committed)
            await refreshDirectories([parent])
            selectedURL = key(for: entry.url)
            return entry
        } catch {
            present(error, title: .couldNotCreateFolder, context: name)
            return nil
        }
    }

    /// Renames only within the current parent. Open-document owners receive
    /// the committed new prefix before the tree publishes it.
    @discardableResult
    func rename(_ source: URL, toName name: String) async -> URL? {
        guard beginItemMutation() else { return nil }
        defer { isMutatingItems = false }

        let source = key(for: source)
        var prepared: PreparedWorkspaceMutation?
        do {
            try validateItemName(name)
            let target = source.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: source.hasDirectoryPath)
                .standardizedFileURL
            if source == target { return source }
            let proposed = WorkspaceMutationEvent.renamed(from: source, to: target)
            try await authorizeMutation(proposed)
            prepared = try await prepareMutation(proposed)
            let serviceResult: URL
            do {
                serviceResult = try await service.rename(source, toName: name)
                prepared?.commit()
                prepared = nil
            } catch {
                if let workspaceError = error as? WorkspaceServiceError,
                   case let .moveRollbackFailed(
                       _, committedTarget, _, .committedAtTarget
                   ) = workspaceError {
                    prepared?.commit()
                    prepared = nil
                    return await reconcileCommittedRecovery(
                        source: source, target: committedTarget,
                        event: .renamed(from: source, to: committedTarget), error: error
                    )
                }
                var uncertainTarget: URL?
                if let workspaceError = error as? WorkspaceServiceError,
                   case let .moveRollbackFailed(
                       _, target, _, .indeterminate
                   ) = workspaceError {
                    uncertainTarget = target
                }
                try prepared?.abort()
                prepared = nil
                if let uncertainTarget {
                    await refreshDirectories([
                        source.deletingLastPathComponent(),
                        uncertainTarget.deletingLastPathComponent()
                    ])
                }
                throw error
            }
            let renamed = key(for: URL(
                fileURLWithPath: serviceResult.path,
                isDirectory: source.hasDirectoryPath
            ))
            let committed = WorkspaceMutationEvent.renamed(from: source, to: renamed)
            _ = await publishCommittedMutation(committed)
            rewriteTreeState(from: source, to: renamed)
            await refreshDirectories([source.deletingLastPathComponent()])
            return renamed
        } catch {
            try? prepared?.abort()
            present(error, title: .couldNotRenameItem, context: source.lastPathComponent)
            return nil
        }
    }

    /// Presents a trusted native directory chooser, then uses either an
    /// existing workspace grant or a one-shot external destination token.
    @discardableResult
    func move(
        _ source: URL, locale: EditorLocale = .zhCN
    ) async -> URL? {
        guard !isBusy else { return nil }
        let copy = WorkspaceFolderPanelCopy.move(
            itemName: source.lastPathComponent, locale: locale
        )
        guard let selectedDestination = await chooseFolder(
            title: copy.title,
            message: copy.message,
            prompt: copy.prompt,
            initialDirectory: source.deletingLastPathComponent()
        ) else { return nil }
        guard beginItemMutation() else { return nil }
        defer { isMutatingItems = false }

        let destination = key(for: selectedDestination)
        if await service.root(containing: destination) != nil {
            return await performMove(
                source,
                destinationDirectory: destination,
                operation: {
                    try await service.move(source, toDirectory: destination)
                }
            )
        }
        var destinationLease: SecurityScopedResourceLease?
        do {
            destinationLease = try securityScopedLease(
                for: destination, source: .userSelected
            )
            guard let authorizedDestination = destinationLease?.url else { return nil }
            let authorization = try await service.authorizeMoveDestination(
                userSelectedDirectory: authorizedDestination
            )
            let moved = await performMove(
                source,
                destinationDirectory: authorizedDestination,
                operation: {
                    try await service.move(source, using: authorization)
                }
            )
            destinationLease?.invalidate()
            return moved
        } catch {
            destinationLease?.invalidate()
            present(
                error,
                title: .couldNotMoveItem,
                context: source.lastPathComponent
            )
            return nil
        }
    }

    /// Programmatic variant for an already-authorised workspace directory.
    /// External destinations remain reachable only through the private token
    /// minted immediately after the native panel returns.
    @discardableResult
    func move(_ source: URL, toDirectory destination: URL) async -> URL? {
        guard beginItemMutation() else { return nil }
        defer { isMutatingItems = false }

        let destination = key(for: destination)
        guard await service.root(containing: destination) != nil else {
            present(
                WorkspaceServiceError.unauthorized(destination),
                title: .couldNotMoveItem,
                context: source.lastPathComponent
            )
            return nil
        }
        return await performMove(
            source,
            destinationDirectory: destination,
            operation: {
                try await service.move(source, toDirectory: destination)
            }
        )
    }

    private func performMove(
        _ rawSource: URL,
        destinationDirectory rawDestination: URL,
        operation: () async throws -> URL
    ) async -> URL? {
        let source = key(for: rawSource)
        let destination = key(for: rawDestination)
        let proposedTarget = destination
            .appendingPathComponent(
                source.lastPathComponent,
                isDirectory: source.hasDirectoryPath
            )
            .standardizedFileURL
        if source == proposedTarget { return source }
        let proposed = WorkspaceMutationEvent.moved(from: source, to: proposedTarget)
        var prepared: PreparedWorkspaceMutation?
        do {
            try await authorizeMutation(proposed)
            prepared = try await prepareMutation(proposed)
            let moved: URL
            do {
                moved = try await operation()
                prepared?.commit()
                prepared = nil
            } catch {
                if let workspaceError = error as? WorkspaceServiceError,
                   case let .moveRollbackFailed(
                       _, committedTarget, _, .committedAtTarget
                   ) = workspaceError {
                    prepared?.commit()
                    prepared = nil
                    return await reconcileCommittedRecovery(
                        source: source, target: committedTarget,
                        event: .moved(from: source, to: committedTarget), error: error
                    )
                }
                var uncertainTarget: URL?
                if let workspaceError = error as? WorkspaceServiceError,
                   case let .moveRollbackFailed(
                       _, target, _, .indeterminate
                   ) = workspaceError {
                    uncertainTarget = target
                }
                try prepared?.abort()
                prepared = nil
                if let uncertainTarget {
                    await refreshDirectories([
                        source.deletingLastPathComponent(),
                        uncertainTarget.deletingLastPathComponent()
                    ])
                }
                throw error
            }
            let committedTarget = key(for: URL(
                fileURLWithPath: moved.path,
                isDirectory: source.hasDirectoryPath
            ))
            let committed = WorkspaceMutationEvent.moved(
                from: source,
                to: committedTarget
            )
            let coordinated = await publishCommittedMutation(committed)
            rewriteTreeState(from: source, to: committedTarget)
            await refreshDirectories([
                source.deletingLastPathComponent(),
                committedTarget.deletingLastPathComponent()
            ])
            if coordinated {
                notice = WorkspacePresentationNotice(
                    content: .app(
                        english: "Moved to \(committedTarget.path)",
                        chinese: "已移动到 \(committedTarget.path)"
                    )
                )
            }
            return committedTarget
        } catch {
            try? prepared?.abort()
            present(error, title: .couldNotMoveItem, context: source.lastPathComponent)
            return nil
        }
    }

    private func reconcileCommittedRecovery(
        source: URL, target: URL, event: WorkspaceMutationEvent, error: any Error
    ) async -> URL {
        let target = key(for: target)
        _ = await publishCommittedMutation(event)
        rewriteTreeState(from: source, to: target)
        await refreshDirectories([
            source.deletingLastPathComponent(), target.deletingLastPathComponent()
        ])
        present(error, title: .moveRecoveryFailed, context: source.lastPathComponent)
        return target
    }

    /// Moves an authorised item to the recoverable system Trash. Confirmation
    /// belongs to the SwiftUI caller; the preflight callback runs before disk
    /// mutation so dirty open documents can veto the operation.
    @discardableResult
    func moveToTrash(_ url: URL) async -> Bool {
        guard beginItemMutation() else { return false }
        defer { isMutatingItems = false }

        let target = key(for: url)
        let event = WorkspaceMutationEvent.trashed(target)
        do {
            try await authorizeMutation(event)
            try await service.moveToTrash(target)
            _ = await publishCommittedMutation(event)
            removeTreeState(under: target)
            await refreshDirectories([target.deletingLastPathComponent()])
            return true
        } catch {
            present(error, title: .couldNotTrashItem, context: target.lastPathComponent)
            return false
        }
    }

    /// Validates the capability immediately before handing the path to Finder.
    @discardableResult
    func revealInFinder(_ url: URL) async -> Bool {
        guard !isBusy else { return false }
        let target = key(for: url)
        do {
            try await validateWorkspaceEntry(target)
            revealInFinderAction(target)
            return true
        } catch {
            present(error, title: .couldNotRevealItem, context: target.lastPathComponent)
            return false
        }
    }

    /// Writes only to the pasteboard; no clipboard read capability is needed.
    @discardableResult
    func copyPath(_ url: URL, relativeToWorkspace: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        let target = key(for: url)
        do {
            let value: String
            if relativeToWorkspace {
                // Relative paths are a workspace capability: validate the
                // current root attachment before deriving user-visible text.
                try await validateWorkspaceEntry(target)
                guard let root = mostSpecificRoot(containing: target) else {
                    throw WorkspaceServiceError.unauthorized(target)
                }
                let components = relativeComponents(of: target, under: root.url)
                value = components.isEmpty
                    ? target.lastPathComponent
                    : components.joined(separator: "/")
            } else {
                // Copying an already-open document's absolute local path does
                // not read the file and must also work outside the workspace.
                guard target.isFileURL else {
                    throw WorkspaceServiceError.unauthorized(target)
                }
                value = target.path
            }
            guard writeClipboard(value) else {
                throw WorkspaceClipboardError.writeFailed
            }
            notice = WorkspacePresentationNotice(
                content: .app(
                    english: relativeToWorkspace
                        ? "Copied relative path: \(value)"
                        : "Copied path: \(value)",
                    chinese: relativeToWorkspace
                        ? "已复制相对路径：\(value)"
                        : "已复制路径：\(value)"
                )
            )
            return true
        } catch {
            present(error, title: .couldNotCopyPath, context: target.lastPathComponent)
            return false
        }
    }

    func openDocumentCount(under url: URL) -> Int {
        let target = key(for: url)
        return openDocumentURLs().reduce(into: 0) { count, documentURL in
            if contains(target, key(for: documentURL)) { count += 1 }
        }
    }

    func selectFile(_ url: URL) {
        guard !isApplicationTerminationCommitted else { return }
        let candidate = key(for: url)
        guard roots.contains(where: { contains($0.url, candidate) }) else {
            selectedURL = nil
            return
        }
        selectedURL = candidate
    }

    /// Expands just the ancestors needed for the active file and selects it.
    /// A generation token prevents a slow previous reveal from selecting stale
    /// data after the active editor has changed.
    @discardableResult
    func revealActiveFile(
        _ url: URL?, prepareSidebar: PrepareSidebarReveal = { true }
    ) async -> Bool {
        await revealFile(
            url, reportsUnavailable: true, prepareSidebar: prepareSidebar
        )
    }

    /// Keeps the tree selection aligned with editor activation without turning
    /// an untitled or out-of-workspace tab into a user-facing error.
    func synchronizeActiveFile(_ url: URL?) async {
        _ = await revealFile(url, reportsUnavailable: false, prepareSidebar: { true })
    }

    private func revealFile(
        _ url: URL?, reportsUnavailable: Bool, prepareSidebar: PrepareSidebarReveal
    ) async -> Bool {
        guard !isApplicationTerminationCommitted else { return false }
        revealGeneration &+= 1
        let generation = revealGeneration
        let request = treeRequestSnapshot()
        isRevealingActiveFile = true
        defer {
            if revealGeneration == generation { isRevealingActiveFile = false }
        }

        guard let url else {
            selectedURL = nil
            if reportsUnavailable {
                presentMessage(
                    title: .noSavedFileToReveal,
                    message: .app(
                        english: "Save the active document inside an open workspace first.",
                        chinese: "请先将活动文档保存到已打开的工作区中。"
                    )
                )
            }
            return false
        }
        let resolvedRoot = await service.root(containing: url)
        guard revealGeneration == generation, isCurrentTreeRequest(request) else {
            return false
        }
        guard let root = resolvedRoot else {
            selectedURL = nil
            if reportsUnavailable {
                presentMessage(
                    title: .fileOutsideWorkspace,
                    message: .app(
                        english: "Add the file’s folder to the workspace before revealing it.",
                        chinese: "请先将文件所在的文件夹添加到工作区，再显示该文件。"
                    )
                )
            }
            return false
        }

        let fileURL = key(for: url)
        let exclusions = request.projectExclusions.policy
        var directory = root.url
        var ancestors: [URL] = [directory]
        for component in relativeComponents(of: fileURL, under: root.url).dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            ancestors.append(key(for: directory))
        }

        guard prepareSidebar() else { return false }
        isSidebarVisible = true
        for ancestor in ancestors {
            guard revealGeneration == generation, isCurrentTreeRequest(request) else {
                return false
            }
            expandedDirectories.insert(ancestor)
            let directoryGeneration = nextDirectoryGeneration(for: ancestor)
            let previous = state(for: ancestor)
            directoryStates[ancestor] = DirectoryState(
                entries: previous.entries,
                loadState: .loading,
                isTruncated: previous.isTruncated,
                errorContent: nil
            )
            do {
                let listing = try await service.children(
                    of: ancestor, exclusions: exclusions
                )
                guard revealGeneration == generation,
                      isCurrentTreeRequest(request),
                      directoryGenerations[ancestor] == directoryGeneration
                else { return false }
                directoryStates[ancestor] = DirectoryState(
                    entries: listing.entries,
                    loadState: .loaded,
                    isTruncated: listing.isTruncated,
                    errorContent: nil
                )
            } catch {
                guard revealGeneration == generation,
                      isCurrentTreeRequest(request),
                      directoryGenerations[ancestor] == directoryGeneration
                else { return false }
                directoryStates[ancestor] = DirectoryState(
                    loadState: .failed,
                    errorContent: Self.presentationMessage(for: error)
                )
                selectedURL = nil
                if reportsUnavailable {
                    present(
                        error,
                        title: .couldNotRevealFile,
                        context: fileURL.lastPathComponent
                    )
                }
                return false
            }
        }
        guard revealGeneration == generation, isCurrentTreeRequest(request) else {
            return false
        }
        guard let parent = ancestors.last,
              let visibleEntry = state(for: parent).entries.first(where: {
                  key(for: $0.url) == fileURL
              }),
              visibleEntry.kind == .file || visibleEntry.kind == .symbolicLink
        else {
            selectedURL = nil
            if reportsUnavailable {
                presentMessage(
                    title: .fileNotVisible,
                    message: .app(
                        english: "\(fileURL.lastPathComponent) is missing or excluded from the file tree.",
                        chinese: "\(fileURL.lastPathComponent) 不存在或已从文件树中排除。"
                    )
                )
            }
            return false
        }
        do {
            // Recheck the exact file capability (including symlink containment)
            // without handing the result to the editor or changing the document.
            _ = try await service.openFile(fileURL)
            guard revealGeneration == generation, isCurrentTreeRequest(request) else {
                return false
            }
        } catch {
            guard revealGeneration == generation, isCurrentTreeRequest(request) else {
                return false
            }
            selectedURL = nil
            if reportsUnavailable {
                present(
                    error,
                    title: .couldNotRevealFile,
                    context: fileURL.lastPathComponent
                )
            }
            return false
        }
        guard revealGeneration == generation, isCurrentTreeRequest(request) else {
            return false
        }
        selectedURL = fileURL
        return true
    }

    private func replaceWorkspace(
        with url: URL,
        accessSource: SecurityScopedAccessSource
    ) async -> Bool {
        guard !isBusy else { return false }
        isChangingRoots = true
        defer { isChangingRoots = false }
        invalidateTreeOperations()
        let mutationGeneration = rootMutationGeneration

        let oldRoots = await service.registeredRoots()
        do {
            let lease = try securityScopedLease(for: url, source: accessSource)
            let authorizedURL = lease.url
            let selectedPath = key(for: authorizedURL).resolvingSymlinksInPath().path
            let alreadyRegistered = oldRoots.first {
                key(for: $0.url).resolvingSymlinksInPath().path == selectedPath
            }
            let openFiles = openDocumentURLs()
            let removals = oldRoots.compactMap { root
                -> WorkspaceRootReplacementRemoval? in
                guard root.id != alreadyRegistered?.id else { return nil }
                let retained = retainedFilesForReplacement(
                    from: openFiles, removing: root, replacementURL: authorizedURL
                )
                return WorkspaceRootReplacementRemoval(
                    id: root.id, retainingOpenFiles: retained
                )
            }
            let retainedURLs = uniqueURLs(
                removals.flatMap(\.retainingOpenFiles)
            )
            var retainedFileLeases: [SecurityScopedResourceLease] = []
            do {
                for retainedURL in retainedURLs {
                    retainedFileLeases.append(
                        try securityScopedAccess.accessPersistedURL(
                            retainedURL, kind: .file,
                            allowingDirectoryAncestor: true
                        )
                    )
                }
            } catch {
                for retainedLease in retainedFileLeases { retainedLease.invalidate() }
                lease.invalidate()
                throw error
            }

            let transaction: WorkspaceRootReplacementTransaction
            do {
                transaction = try await service.beginRootReplacement(
                    with: authorizedURL, removing: removals
                )
            } catch {
                for retainedLease in retainedFileLeases { retainedLease.invalidate() }
                lease.invalidate()
                throw error
            }
            guard !Task.isCancelled,
                  rootMutationGeneration == mutationGeneration,
                  !isApplicationTerminationCommitted else {
                for retainedLease in retainedFileLeases { retainedLease.invalidate() }
                lease.invalidate()
                do {
                    try await service.finishRootReplacement(
                        transaction, commit: false
                    )
                } catch {
                    present(
                        WorkspaceServiceError.rootReplacementRollbackFailed,
                        title: .couldNotRestoreWorkspace
                    )
                }
                return false
            }
            let replacement = transaction.replacement
            do {
                try await service.finishRootReplacement(transaction, commit: true)
            } catch {
                for retainedLease in retainedFileLeases { retainedLease.invalidate() }
                lease.invalidate()
                let authoritativeRoots = await service.registeredRoots()
                let rootsChanged = authoritativeRoots != roots
                publishRoots(authoritativeRoots)
                if !isApplicationTerminationCommitted {
                    synchronizeRootWatchers()
                    if rootsChanged { resetTreeState() }
                    releaseLeasesForUnregisteredRoots()
                    present(error, title: .couldNotFinalizeWorkspace)
                }
                return false
            }
            guard rootMutationGeneration == mutationGeneration,
                  !isApplicationTerminationCommitted else {
                // Shutdown may run while the actor acknowledges the commit.
                // Do not reacquire scopes after shutdown, but publish the exact
                // committed singleton so controller and service cannot diverge.
                for retainedLease in retainedFileLeases { retainedLease.invalidate() }
                lease.invalidate()
                for root in oldRoots { releaseRootLease(for: root.url) }
                publishRoots([replacement])
                return false
            }

            // Core committed atomically. Only now transfer security-scope
            // ownership and retire leases for removed roots. A failed Core
            // transaction reaches neither side effect.
            if alreadyRegistered?.id == replacement.id {
                lease.invalidate()
            } else {
                retainRootLease(lease)
            }
            for retainedLease in retainedFileLeases {
                if let retainFileAccess {
                    retainFileAccess(retainedLease.url, retainedLease)
                } else {
                    retainedLease.invalidate()
                }
            }
            for root in oldRoots where root.id != replacement.id {
                releaseRootLease(for: root.url)
            }

            let committedRoots = [replacement]
            let rootsChanged = committedRoots != oldRoots
            publishRoots(committedRoots)
            if rootsChanged {
                synchronizeRootWatchers()
                resetTreeState()
            }
            isSidebarVisible = true
            return true
        } catch {
            // `replaceRoots` stages every mutation and commits once, so the
            // exact old service roots/primary/direct grants, app leases,
            // watchers, and visible tree remain authoritative on failure.
            present(error, title: .couldNotOpenFolder, context: url.lastPathComponent)
            return false
        }
    }

    private func synchronizeRoots(showingSidebar: Bool) async {
        let currentRoots = await service.registeredRoots()
        publishRoots(currentRoots)
        synchronizeRootWatchers()
        if showingSidebar, !currentRoots.isEmpty { isSidebarVisible = true }
    }

    private func publishRoots(_ committedRoots: [WorkspaceRoot]) {
        roots = committedRoots
        guard committedRoots != rootSnapshot.roots else { return }
        rootSnapshot = WorkspaceRootSnapshot(
            roots: committedRoots, generation: rootSnapshot.generation &+ 1
        )
    }

    private func synchronizeRootWatchers() {
        let desired = Dictionary(uniqueKeysWithValues: roots.map { root in
            (key(for: root.url).path, (url: key(for: root.url), id: root.id))
        })
        let removedPaths = rootWatchers.keys.filter { path in
            desired[path] == nil || rootWatcherIDs[path] != desired[path]?.id
        }
        for path in removedPaths {
            rootWatchers.removeValue(forKey: path)?.cancel()
            rootWatcherTokens.removeValue(forKey: path)
            rootWatcherIDs.removeValue(forKey: path)
            pendingChangedEvents = pendingChangedEvents.filter { _, event in
                event.rootURL.standardizedFileURL.path != path
            }
        }
        if !removedPaths.isEmpty { watcherCallbackEpoch.advance() }
        if pendingChangedEvents.isEmpty
            || pendingWatcherSnapshot.map({ !isCurrentTreeRequest($0) }) == true {
            cancelPendingWatcherRefresh()
        }
        unwatchedRootPaths = Set(unwatchedRootPaths.filter { desired[$0] != nil })
        let maximum = min(20, fileWatcherFactory.maximumWatchedRoots)
        for (path, desiredRoot) in desired.sorted(by: { $0.key < $1.key }) {
            guard rootWatchers[path] == nil, !unwatchedRootPaths.contains(path),
                  rootWatchers.count < maximum else { continue }
            do {
                nextRootWatcherToken &+= 1
                let watcherToken = nextRootWatcherToken
                rootWatchers[path] = try fileWatcherFactory.makeWatcher(
                    for: desiredRoot.url
                ) { [weak self, watcherCallbackEpoch] event in
                    let callbackEpoch = watcherCallbackEpoch.snapshot()
                    Task { @MainActor [weak self] in
                        self?.workspaceFileSystemDidChange(
                            event, rootID: desiredRoot.id,
                            watcherToken: watcherToken, callbackEpoch: callbackEpoch
                        )
                    }
                }
                rootWatcherTokens[path] = watcherToken
                rootWatcherIDs[path] = desiredRoot.id
            } catch {
                unwatchedRootPaths.insert(path)
                if issue == nil {
                    present(
                        error, title: .couldNotMonitorFolder,
                        context: desiredRoot.url.lastPathComponent
                    )
                }
            }
        }
    }

    private func workspaceFileSystemDidChange(
        _ event: WorkspaceFileSystemEvent, rootID: WorkspaceRoot.ID,
        watcherToken: UInt64, callbackEpoch: UInt64
    ) {
        let root = key(for: event.rootURL)
        guard !isChangingRoots,
              watcherCallbackEpoch.snapshot() == callbackEpoch,
              rootWatcherTokens[root.path] == watcherToken
        else { return }
        guard roots.contains(where: {
            $0.id == rootID && key(for: $0.url) == root
        }) else { return }
        let request = treeRequestSnapshot()
        guard isCurrentTreeRequest(request) else { return }
        if let pendingWatcherSnapshot, pendingWatcherSnapshot != request {
            cancelPendingWatcherRefresh()
        }
        let normalized = normalizedFileSystemEvent(event)
        let eventKey = pendingEventKey(for: normalized)
        if let existing = pendingChangedEvents[eventKey] {
            pendingChangedEvents[eventKey] = existing.merged(with: normalized)
        } else {
            pendingChangedEvents[eventKey] = normalized
        }
        pendingWatcherSnapshot = request
        watcherRefreshTask?.cancel()
        watcherBatchGeneration &+= 1
        let batchGeneration = watcherBatchGeneration
        let delay = watcherDebounceNanoseconds
        watcherRefreshTask = Task { @MainActor [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.watcherBatchGeneration == batchGeneration,
                  self.pendingWatcherSnapshot == request,
                  self.isCurrentTreeRequest(request)
            else {
                return
            }
            await self.flushPendingWorkspaceFileSystemChanges(
                request: request, batchGeneration: batchGeneration
            )
        }
    }

    private func flushPendingWorkspaceFileSystemChanges(
        request: TreeRequestSnapshot, batchGeneration: UInt64
    ) async {
        guard watcherBatchGeneration == batchGeneration,
              pendingWatcherSnapshot == request,
              isCurrentTreeRequest(request)
        else { return }
        watcherRefreshTask = nil
        let events = pendingChangedEvents.values.sorted {
            let lhs = ($0.rootURL.path, $0.callbackURL.path, $0.kind.precedence)
            let rhs = ($1.rootURL.path, $1.callbackURL.path, $1.kind.precedence)
            return lhs < rhs
        }
        pendingChangedEvents.removeAll()
        pendingWatcherSnapshot = nil
        guard !events.isEmpty else { return }

        let impactedDirectories = impactedDirectories(for: events)
        await refreshDirectories(Array(impactedDirectories), request: request)
        guard watcherBatchGeneration == batchGeneration,
              isCurrentTreeRequest(request)
        else { return }
        if let fileSystemChangeAction {
            let callbackURLs = callbackTargets(for: events)
            for url in callbackURLs {
                guard watcherBatchGeneration == batchGeneration,
                      isCurrentTreeRequest(request)
                else { return }
                await fileSystemChangeAction(url)
                guard watcherBatchGeneration == batchGeneration,
                      isCurrentTreeRequest(request)
                else { return }
            }
        }
    }

    private func cancelPendingWatcherRefresh() {
        watcherRefreshTask?.cancel()
        watcherRefreshTask = nil
        pendingChangedEvents.removeAll()
        pendingWatcherSnapshot = nil
        watcherBatchGeneration &+= 1
    }

    private func normalizedFileSystemEvent(
        _ event: WorkspaceFileSystemEvent
    ) -> WorkspaceFileSystemEvent {
        if event.isRootInvalidation {
            return .rootInvalidated(rootURL: key(for: event.rootURL))
        }
        guard let changedURL = event.changedURL else {
            return .rootInvalidated(rootURL: key(for: event.rootURL))
        }
        return WorkspaceFileSystemEvent(
            rootURL: key(for: event.rootURL),
            kind: event.kind,
            changedURL: key(for: changedURL)
        )
    }

    private func pendingEventKey(for event: WorkspaceFileSystemEvent) -> String {
        let callbackPath = event.callbackURL.standardizedFileURL.path
        return "\(event.rootURL.standardizedFileURL.path)|\(callbackPath)"
    }

    private func impactedDirectories(
        for events: [WorkspaceFileSystemEvent]
    ) -> Set<URL> {
        let visibleDirectories = Set(roots.map { key(for: $0.url) })
            .union(expandedDirectories)
        var directories: Set<URL> = []
        for event in events {
            let root = key(for: event.rootURL)
            if event.isRootInvalidation {
                directories.formUnion(
                    visibleDirectories.filter { contains(root, $0) }
                )
                continue
            }
            guard let changedURL = event.changedURL?.standardizedFileURL else {
                directories.formUnion(
                    visibleDirectories.filter { contains(root, $0) }
                )
                continue
            }
            let impacted = directoriesToRefresh(for: changedURL, root: root)
            for directory in impacted where visibleDirectories.contains(directory) {
                directories.insert(directory)
            }
        }
        return directories
    }

    private func directoriesToRefresh(for changedURL: URL, root: URL) -> Set<URL> {
        var directories: Set<URL> = [root]
        let directParent = changedURL.deletingLastPathComponent().standardizedFileURL
        if contains(root, directParent) {
            directories.insert(directParent)
        }
        for directory in expandedDirectories
        where contains(directory, changedURL) && directory != changedURL {
            directories.insert(directory)
        }
        return directories
    }

    private func callbackTargets(for events: [WorkspaceFileSystemEvent]) -> [URL] {
        var ordered: [URL] = []
        var seen: Set<String> = []
        for event in events {
            let callbackURL = event.callbackURL
            let path = callbackURL.standardizedFileURL.path
            if seen.insert(path).inserted {
                ordered.append(callbackURL)
            }
        }
        return ordered
    }

    private func securityScopedLease(
        for url: URL, source: SecurityScopedAccessSource
    ) throws -> SecurityScopedResourceLease {
        do {
            switch source {
            case .userSelected:
                return try securityScopedAccess.accessUserSelectedURL(
                    url, kind: .directory
                )
            case .persisted:
                return try securityScopedAccess.accessPersistedURL(
                    url, kind: .directory
                )
            }
        } catch {
            // SwiftPM test executables and the historical unsigned preview do
            // not carry App Sandbox. Keep their filesystem semantics while
            // requiring real grants whenever the process has a sandbox container.
            guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            else { throw error }
            return SecurityScopedResourceLease(url: url.standardizedFileURL)
        }
    }

    private func retainRootLease(_ lease: SecurityScopedResourceLease) {
        let path = key(for: lease.url).path
        securityScopedRootLeases.removeValue(forKey: path)?.invalidate()
        securityScopedRootLeases[path] = lease
    }

    private func releaseRootLease(for url: URL) {
        securityScopedRootLeases.removeValue(forKey: key(for: url).path)?.invalidate()
    }

    private func releaseLeasesForUnregisteredRoots() {
        let retained = Set(roots.map { key(for: $0.url).path })
        let removedPaths = securityScopedRootLeases.keys.filter {
            !retained.contains($0)
        }
        for path in removedPaths {
            securityScopedRootLeases.removeValue(forKey: path)?.invalidate()
        }
    }

    private func retainSecurityScopedAccessForFiles(_ urls: [URL]) throws {
        for url in urls {
            let lease = try securityScopedAccess.accessPersistedURL(
                url, kind: .file, allowingDirectoryAncestor: true
            )
            if let retainFileAccess {
                retainFileAccess(lease.url, lease)
            } else {
                lease.invalidate()
            }
        }
    }

    private func chooseFolder(
        title: String,
        message: String,
        prompt: String,
        initialDirectory: URL? = nil
    ) async -> URL? {
        guard !isPresentingPanel else { return nil }
        let copy = WorkspaceFolderPanelCopy(
            title: title, message: message, prompt: prompt
        )
        if let chooseFolderAction {
            isPresentingPanel = true
            defer { isPresentingPanel = false }
            return await chooseFolderAction(copy, initialDirectory)
        }
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.directoryURL = initialDirectory

        isPresentingPanel = true
        defer { isPresentingPanel = false }
        let response = await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK else { return nil }
        return panel.url
    }

    private func beginItemMutation() -> Bool {
        guard !isBusy, openingFileURLs.isEmpty else { return false }
        issue = nil
        notice = nil
        isMutatingItems = true
        return true
    }

    private func validateItemName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0"),
              name.lengthOfBytes(using: .utf8) <= service.limits.maximumNameBytes else {
            throw WorkspaceServiceError.invalidName(name)
        }
    }

    private func openCreatedFile(_ entry: WorkspaceEntry) async {
        let fileURL = key(for: entry.url)
        beginOpening(fileURL)
        defer { finishOpening(fileURL) }
        do {
            let opened = try await service.openFile(fileURL)
            guard validateEditable(opened) else { return }
            await openFileAction(opened)
        } catch {
            present(error, title: .couldNotOpenFile, context: entry.name)
        }
    }

    /// Disk mutation has already committed when this runs. A coordinator
    /// failure is surfaced prominently, while tree state is still reconciled
    /// with disk so the UI never pretends the old path remains present.
    @discardableResult
    private func publishCommittedMutation(_ event: WorkspaceMutationEvent) async -> Bool {
        do {
            try await didMutate(event)
            await synchronizeRootsAfterMutation(event)
            return true
        } catch {
            issue = WorkspacePresentationIssue(
                title: .mutationCoordinationFailed,
                verbatim: error.localizedDescription
            )
            isSidebarVisible = true
            await synchronizeRootsAfterMutation(event)
            return false
        }
    }

    /// Renaming or moving a path that contains a nested registered root can
    /// invalidate that root's capability. Re-read the authoritative service
    /// snapshot so UI/session owners never retain a stale root URL.
    private func synchronizeRootsAfterMutation(_ event: WorkspaceMutationEvent) async {
        guard let source = event.sourceURL,
              roots.contains(where: { contains(source, $0.url) }) else { return }
        invalidateTreeOperations()
        publishRoots(await service.registeredRoots())
        synchronizeRootWatchers()
    }

    /// Revalidates an exact entry using the capability service. Directory
    /// enumeration validates its parent and confirms the final node exists.
    private func validateWorkspaceEntry(_ url: URL) async throws {
        guard let root = await service.root(containing: url) else {
            throw WorkspaceServiceError.unauthorized(url)
        }
        if key(for: root.url) == url {
            _ = try await service.children(of: url)
            return
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let listing = try await service.children(of: parent)
        guard listing.entries.contains(where: { key(for: $0.url) == url }) else {
            throw WorkspaceServiceError.itemNotFound(url)
        }
    }

    private func refreshDirectories(
        _ directories: [URL], request suppliedRequest: TreeRequestSnapshot? = nil
    ) async {
        var seen = Set<URL>()
        let request = suppliedRequest ?? treeRequestSnapshot()
        let exclusions = request.projectExclusions.policy
        for rawDirectory in directories {
            guard isCurrentTreeRequest(request) else { return }
            let directory = key(for: rawDirectory)
            guard seen.insert(directory).inserted,
                  roots.contains(where: { contains($0.url, directory) }) else { continue }

            let generation = nextDirectoryGeneration(for: directory)
            let previous = state(for: directory)
            directoryStates[directory] = DirectoryState(
                entries: previous.entries,
                loadState: .loading,
                isTruncated: previous.isTruncated,
                errorContent: nil
            )
            do {
                let listing = try await service.children(
                    of: directory, exclusions: exclusions
                )
                guard isCurrentTreeRequest(request) else { return }
                guard directoryGenerations[directory] == generation else { continue }
                directoryStates[directory] = DirectoryState(
                    entries: listing.entries,
                    loadState: .loaded,
                    isTruncated: listing.isTruncated,
                    errorContent: nil
                )
            } catch {
                guard isCurrentTreeRequest(request) else { return }
                guard directoryGenerations[directory] == generation else { continue }
                directoryStates[directory] = DirectoryState(
                    entries: previous.entries,
                    loadState: .failed,
                    isTruncated: previous.isTruncated,
                    errorContent: Self.presentationMessage(for: error)
                )
                if issue == nil {
                    present(
                        error,
                        title: .refreshAfterMutationFailed,
                        context: directory.lastPathComponent
                    )
                }
            }
        }
    }

    private func rewriteTreeState(from source: URL, to target: URL) {
        let source = key(for: source)
        let target = key(for: target)
        let targetIsVisible = roots.contains { contains($0.url, target) }

        let rewrittenExpanded = expandedDirectories.compactMap { directory -> URL? in
            guard contains(source, directory) else { return directory }
            guard targetIsVisible else { return nil }
            return replacingPathPrefix(in: directory, from: source, to: target)
        }
        expandedDirectories = Set(rewrittenExpanded)

        if let selectedURL, contains(source, selectedURL) {
            self.selectedURL = targetIsVisible
                ? replacingPathPrefix(in: selectedURL, from: source, to: target)
                : nil
        }
        invalidateDirectories(under: source)
        invalidateDirectories(under: target)
    }

    private func removeTreeState(under target: URL) {
        let target = key(for: target)
        invalidateDirectories(under: target)
        expandedDirectories = Set(
            expandedDirectories.filter { !contains(target, $0) }
        )
        if selectedURL.map({ contains(target, $0) }) == true {
            selectedURL = nil
        }
    }

    private func replacingPathPrefix(
        in value: URL,
        from source: URL,
        to target: URL
    ) -> URL {
        let value = key(for: value)
        if value == source { return target }
        let suffix = String(value.path.dropFirst(source.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !suffix.isEmpty else { return target }
        return suffix.split(separator: "/").reduce(target) { partial, component in
            partial.appendingPathComponent(String(component))
        }.standardizedFileURL
    }

    @discardableResult
    private func nextDirectoryGeneration(for directory: URL) -> UInt64 {
        let next = (directoryGenerations[directory] ?? 0) &+ 1
        directoryGenerations[directory] = next
        return next
    }

    private func treeRequestSnapshot() -> TreeRequestSnapshot {
        TreeRequestSnapshot(
            roots: Set(roots.map { root in
                TreeRootIdentity(id: root.id, url: key(for: root.url))
            }),
            rootGeneration: rootMutationGeneration,
            projectExclusions: projectExclusionSnapshot
        )
    }

    private func isCurrentTreeRequest(_ request: TreeRequestSnapshot) -> Bool {
        guard !isApplicationTerminationCommitted, !isChangingRoots,
              request.rootGeneration == rootMutationGeneration,
              request.projectExclusions == projectExclusionSnapshot
        else { return false }
        let currentRoots = Set(roots.map { root in
            TreeRootIdentity(id: root.id, url: key(for: root.url))
        })
        return request.roots == currentRoots
    }

    private func invalidateDirectories(under root: URL) {
        for directory in Array(directoryStates.keys) where contains(root, directory) {
            _ = nextDirectoryGeneration(for: directory)
            directoryStates[directory] = nil
        }
    }

    private func resetTreeState() {
        for directory in Array(directoryGenerations.keys) {
            _ = nextDirectoryGeneration(for: directory)
        }
        directoryStates.removeAll()
        expandedDirectories.removeAll()
        selectedURL = nil
        revealGeneration &+= 1
        isRevealingActiveFile = false
    }

    private func invalidateTreeOperations() {
        rootMutationGeneration &+= 1
        watcherCallbackEpoch.advance()
        revealGeneration &+= 1
        isRevealingActiveFile = false
        cancelPendingWatcherRefresh()
        for directory in Array(directoryGenerations.keys) {
            _ = nextDirectoryGeneration(for: directory)
        }
    }

    private func relativeComponents(of url: URL, under root: URL) -> [String] {
        let rootComponents = key(for: root).pathComponents
        let fileComponents = key(for: url).pathComponents
        guard fileComponents.count >= rootComponents.count else { return [] }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    private func retainedFiles(
        from openFiles: [URL],
        whenRemoving root: WorkspaceRoot,
        whileKeeping remainingRoots: [WorkspaceRoot]
    ) -> [URL] {
        var seen: Set<String> = []
        return openFiles.filter { file in
            let path = key(for: file).path
            guard seen.insert(path).inserted, contains(root.url, file) else { return false }
            return !remainingRoots.contains { contains($0.url, file) }
        }
    }

    private func retainedFilesForReplacement(
        from openFiles: [URL], removing root: WorkspaceRoot,
        replacementURL: URL
    ) -> [URL] {
        var seen: Set<String> = []
        return openFiles.filter { file in
            let path = key(for: file).path
            guard seen.insert(path).inserted, contains(root.url, file) else {
                return false
            }
            return !contains(replacementURL, file)
        }
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(key(for: $0).path).inserted }
    }

    private func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = key(for: root).path
        let candidatePath = key(for: candidate).path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func mostSpecificRoot(containing url: URL) -> WorkspaceRoot? {
        roots
            .filter { contains($0.url, url) }
            .max { key(for: $0.url).path.count < key(for: $1.url).path.count }
    }

    private func key(for url: URL) -> URL {
        url.standardizedFileURL
    }

    private func beginOpening(_ url: URL) {
        openingFileCounts[url, default: 0] += 1
        openingFileURLs.insert(url)
    }

    private func finishOpening(_ url: URL) {
        let remaining = max((openingFileCounts[url] ?? 1) - 1, 0)
        if remaining == 0 {
            openingFileCounts[url] = nil
            openingFileURLs.remove(url)
        } else {
            openingFileCounts[url] = remaining
        }
    }

    private func present(
        _ error: any Error, title: WorkspacePresentationIssue.Title,
        context: String? = nil
    ) {
        let content = Self.presentationMessage(for: error, context: context)
        issue = WorkspacePresentationIssue(title: title, message: content)
        isSidebarVisible = true
    }

    static func presentationMessage(
        for error: any Error, context: String? = nil
    ) -> WorkspacePresentationIssue.Message {
        if let error = error as? WorkspaceServiceError {
            return .workspaceError(error, context: context)
        }
        if let error = error as? WorkspaceClipboardError {
            switch error {
            case .writeFailed:
                return .app(
                    english: "The path could not be written to the clipboard.",
                    chinese: "无法将路径写入剪贴板。"
                )
            }
        }
        if let error = error as? WorkspaceFileWatcherError {
            let message: WorkspacePresentationIssue.Message
            switch error {
            case let .invalidRoot(url):
                message = .app(
                    english: "The workspace watcher requires an absolute local directory: \(url.path)",
                    chinese: "工作区监视器需要绝对本地目录：\(url.path)"
                )
            case let .couldNotCreateStream(url):
                message = .app(
                    english: "The recursive workspace event stream could not be created: \(url.path)",
                    chinese: "无法创建递归工作区事件流：\(url.path)"
                )
            case let .couldNotStartStream(url):
                message = .app(
                    english: "The recursive workspace event stream could not be started: \(url.path)",
                    chinese: "无法启动递归工作区事件流：\(url.path)"
                )
            }
            guard let context else { return message }
            switch message {
            case let .app(english, chinese):
                return .app(
                    english: "\(context): \(english)",
                    chinese: "\(context)：\(chinese)"
                )
            case .workspaceError, .verbatim:
                return message
            }
        }
        let prefix = context.map { "\($0): " } ?? ""
        return .verbatim(prefix + error.localizedDescription)
    }

    private func validateEditable(_ file: OpenedTextFile) -> Bool {
        if file.isBinary {
            presentMessage(
                title: .binaryFile,
                message: .app(
                    english: "\(file.url.lastPathComponent) does not appear to be a text file.",
                    chinese: "\(file.url.lastPathComponent) 似乎不是文本文件。"
                )
            )
            return false
        }
        if file.isTooLarge {
            presentMessage(
                title: .fileTooLarge,
                message: .app(
                    english: "\(file.url.lastPathComponent) exceeds the workspace editing limit.",
                    chinese: "\(file.url.lastPathComponent) 超出工作区编辑大小限制。"
                )
            )
            return false
        }
        return true
    }

    private func presentMessage(
        title: WorkspacePresentationIssue.Title,
        message: WorkspacePresentationIssue.Message
    ) {
        issue = WorkspacePresentationIssue(title: title, message: message)
        isSidebarVisible = true
    }
}
