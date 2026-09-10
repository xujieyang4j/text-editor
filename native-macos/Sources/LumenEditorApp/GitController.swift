import Combine
import Foundation
import LumenEditorCore

struct GitPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case unavailable
        case actionUnavailable
        case operationFailed
        case openConflicts
        case discardBlocked
        case branchChangeBlocked
    }

    enum Message: Equatable, Sendable {
        case app(GitAppIssue)
        case input(GitInputIssue)
        case discardPreflight(GitDiscardPreflightError)
        case branchPreflight(GitBranchPreflightError)
        case conflictedFile(path: String)
        case operationFailure(GitOperationFailure)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    var title: String { EditorLocale.enUS.localizedGitIssueTitle(titleContent) }
    var message: String { content.englishMessage }

    init(id: UUID = UUID(), title: Title, content: Message) {
        self.id = id
        titleContent = title
        self.content = content
    }
}

enum GitAppIssue: Equatable, Sendable {
    case noWorkspace
    case launchFailed
    case cancelled
    case statusRefreshFailed
    case openAllConflictsFailed(openedCount: Int)

    var englishMessage: String {
        switch self {
        case .noWorkspace:
            return "Open a workspace folder to use source control."
        case .launchFailed:
            return "Git could not be launched."
        case .cancelled:
            return "The Git operation was cancelled."
        case .statusRefreshFailed:
            return "Git status could not be refreshed."
        case let .openAllConflictsFailed(openedCount):
            return "Could not open all conflicted files (opened \(openedCount))."
        }
    }
}

enum GitInputIssue: Equatable, Sendable {
    case currentHunkToStage
    case changedFilesFromStatus
    case changedFileToDiscard
    case validHunkToDiscard
    case changedFileForAction
    case commitMessageRequired
    case branchNameRequired
    case confirmationOutOfDate

    var englishMessage: String {
        switch self {
        case .currentHunkToStage: return "Choose a current Git hunk to stage."
        case .changedFilesFromStatus:
            return "Choose changed files from the current repository status."
        case .changedFileToDiscard:
            return "Select at least one changed file to discard."
        case .validHunkToDiscard: return "Choose a valid Git hunk to discard."
        case .changedFileForAction:
            return "Select at least one changed file for this Git action."
        case .commitMessageRequired: return "Enter a commit message."
        case .branchNameRequired: return "Enter a branch name."
        case .confirmationOutOfDate:
            return "Git status changed before confirmation. Review the action and try again."
        }
    }
}

extension GitPresentationIssue.Message {
    var englishMessage: String {
        switch self {
        case let .app(issue): return issue.englishMessage
        case let .input(issue): return issue.englishMessage
        case let .discardPreflight(error): return error.message
        case let .branchPreflight(error): return error.englishMessage
        case let .conflictedFile(path): return "Could not open conflicted file \(path)."
        case let .operationFailure(failure): return failure.englishMessage
        case let .verbatim(message): return message
        }
    }
}

enum GitBranchPreflightError: Error, Equatable, Sendable {
    case savingDocument(name: String)
    case dirtyDocument(name: String)
    case externalConflict(name: String)
    case workspaceBusy

    var englishMessage: String {
        switch self {
        case let .savingDocument(name):
            return "Finish saving \(name) before changing branches."
        case let .dirtyDocument(name):
            return "Save or close the dirty tab \(name) before changing branches."
        case let .externalConflict(name):
            return "Resolve the external change conflict for \(name) before changing branches."
        case .workspaceBusy:
            return "Finish the current document operation before changing branches."
        }
    }
}

enum GitControllerOperation: Equatable, Sendable {
    case refreshing
    case loadingDiff(String)
    case loadingHunks(String)
    case loadingHistory(String)
    case loadingBlame(String)
    case loadingConflicts
    case action(GitAction)

    var accessibilityDescription: String {
        switch self {
        case .refreshing:
            return "Refreshing Git status"
        case .loadingDiff:
            return "Loading Git diff"
        case .loadingHunks:
            return "Loading Git hunks"
        case .loadingHistory:
            return "Loading Git history"
        case .loadingBlame:
            return "Loading Git blame"
        case .loadingConflicts:
            return "Loading Git conflicts"
        case let .action(action):
            switch action {
            case .stage: return "Staging files"
            case .unstage: return "Unstaging files"
            case .discard: return "Discarding file changes"
            case .stageHunk: return "Staging hunk"
            case .discardHunk: return "Discarding hunk"
            case .commit: return "Creating commit"
            case .checkoutBranch: return "Switching branch"
            case .createBranch: return "Creating branch"
            }
        }
    }

    func localizedDescription(locale: EditorLocale, ongoing: Bool = true) -> String {
        let description: (english: String, chinese: String)
        switch self {
        case .refreshing:
            description = ("Refreshing Git status", "刷新 Git 状态")
        case .loadingDiff:
            description = ("Loading Git diff", "载入 Git 差异")
        case .loadingHunks:
            description = ("Loading Git hunks", "载入 Git 区块")
        case .loadingHistory:
            description = ("Loading Git history", "载入 Git 历史")
        case .loadingBlame:
            description = ("Loading Git blame", "载入 Git 追溯")
        case .loadingConflicts:
            description = ("Loading Git conflicts", "载入 Git 冲突")
        case let .action(action):
            switch action {
            case .stage: description = ("Staging files", "暂存文件")
            case .unstage: description = ("Unstaging files", "取消暂存文件")
            case .discard: description = ("Discarding file changes", "丢弃文件更改")
            case .stageHunk: description = ("Staging hunk", "暂存区块")
            case .discardHunk: description = ("Discarding hunk", "丢弃区块")
            case .commit: description = ("Creating commit", "创建提交")
            case .checkoutBranch: description = ("Switching branch", "切换分支")
            case .createBranch: description = ("Creating branch", "创建分支")
            }
        }
        return locale.isSimplifiedChinese
            ? (ongoing ? "正在" : "") + description.chinese
            : description.english
    }
}

/// Work performed around a confirmed disk mutation while no Git subprocess is
/// active. Keeping this separate from `operation` makes async document checks
/// and post-mutation buffer reconciliation visible to sighted and VoiceOver
/// users for the full transaction.
enum GitConfirmationProgress: Equatable {
    case checkingBranchDocuments
    case checkingDiscardDocuments
    case reconcilingBranchDocuments
    case reconcilingDiscardDocuments

    func localizedDescription(locale: EditorLocale) -> String {
        switch self {
        case .checkingBranchDocuments:
            return locale.text(
                "Checking open documents before switching branches",
                zh: "正在切换分支前检查打开的文档"
            )
        case .checkingDiscardDocuments:
            return locale.text(
                "Checking open documents before discarding changes",
                zh: "正在丢弃更改前检查打开的文档"
            )
        case .reconcilingBranchDocuments:
            return locale.text(
                "Reloading open documents after switching branches",
                zh: "正在切换分支后重新载入打开的文档"
            )
        case .reconcilingDiscardDocuments:
            return locale.text(
                "Reloading open documents after discarding changes",
                zh: "正在丢弃更改后重新载入打开的文档"
            )
        }
    }
}

struct GitDiscardRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case paths([String])
        case hunk(GitHunk)
    }

    let id: UUID
    let target: Target
    fileprivate let rootGeneration: UInt64
    fileprivate let statusGeneration: UInt64
    fileprivate let rootURL: URL

    fileprivate init(
        id: UUID = UUID(),
        target: Target,
        rootGeneration: UInt64,
        statusGeneration: UInt64,
        rootURL: URL
    ) {
        self.id = id
        self.target = target
        self.rootGeneration = rootGeneration
        self.statusGeneration = statusGeneration
        self.rootURL = rootURL
    }

    var affectedPaths: [String] {
        switch target {
        case let .paths(paths): return paths
        case let .hunk(hunk): return [hunk.path]
        }
    }
}

/// An immutable, typed snapshot of a Git mutation awaiting explicit user
/// confirmation. Mutable panel inputs are deliberately not read again when
/// the confirmation is accepted.
struct GitMutationConfirmation: Identifiable, Equatable {
    enum Target: Equatable {
        case stagePaths([String])
        case unstagePaths([String])
        case stageHunk(GitHunk)
        case commit(message: String)
        case checkoutBranch(name: String)
        case createBranch(name: String)
    }

    let id: UUID
    let target: Target
    fileprivate let rootGeneration: UInt64
    fileprivate let statusGeneration: UInt64
    fileprivate let rootURL: URL

    fileprivate init(
        id: UUID = UUID(),
        target: Target,
        rootGeneration: UInt64,
        statusGeneration: UInt64,
        rootURL: URL
    ) {
        self.id = id
        self.target = target
        self.rootGeneration = rootGeneration
        self.statusGeneration = statusGeneration
        self.rootURL = rootURL
    }
}

private extension GitMutationConfirmation.Target {
    var isBranchMutation: Bool {
        switch self {
        case .checkoutBranch, .createBranch: return true
        case .stagePaths, .unstagePaths, .stageHunk, .commit: return false
        }
    }
}

struct GitDiscardRefreshToken: Equatable {
    let url: URL
    let documentID: UUID
    let documentRevision: UInt64
    let diskRevision: String?
}

struct GitDiscardPreflightResult: Equatable {
    let refreshTokens: [GitDiscardRefreshToken]
    let lockID: UUID?

    init(refreshTokens: [GitDiscardRefreshToken], lockID: UUID? = nil) {
        self.refreshTokens = refreshTokens
        self.lockID = lockID
    }
}

struct GitBranchPreflightResult: Equatable {
    let refreshTokens: [GitDiscardRefreshToken]
    let lockID: UUID?

    init(refreshTokens: [GitDiscardRefreshToken], lockID: UUID? = nil) {
        self.refreshTokens = refreshTokens
        self.lockID = lockID
    }
}

enum GitDiscardPreflightError: Error, Equatable, LocalizedError, Sendable {
    case savingDocument(name: String)
    case externalConflict(name: String)
    case dirtyDocument(name: String)
    case workspaceBusy
    case verbatim(String)

    var message: String {
        switch self {
        case let .savingDocument(name):
            return "Finish saving \(name) before discarding its Git changes."
        case let .externalConflict(name):
            return "Resolve the external change conflict for \(name) before discarding its Git changes."
        case let .dirtyDocument(name):
            return "Save or close the dirty tab \(name) before discarding its Git changes."
        case .workspaceBusy:
            return "Finish the current document operation before discarding Git changes."
        case let .verbatim(message):
            return message
        }
    }

    var errorDescription: String? { message }
}

struct GitConflictPresentation: Identifiable, Equatable {
    enum Target: Equatable {
        case worktree
        case ours
        case theirs
        case compare
    }

    let id: String
    let path: String
    let ours: String?
    let theirs: String?

    init(path: String, ours: String?, theirs: String?) {
        self.id = path
        self.path = path
        self.ours = ours
        self.theirs = theirs
    }

    var availableTargets: [Target] {
        var targets: [Target] = [.worktree]
        if ours != nil { targets.append(.ours) }
        if theirs != nil { targets.append(.theirs) }
        if ours != nil || theirs != nil { targets.append(.compare) }
        return targets
    }
}

struct GitConflictOpenRequest: Equatable {
    let target: GitConflictPresentation.Target
    let path: String
    let worktreeURL: URL?
    let ours: OpenedTextFile?
    let theirs: OpenedTextFile?
}

enum GitOpenAllWorktreeConflictsResult: Equatable {
    case opened(count: Int)
    case noChange
    case failed(openedCount: Int)

    var didOpenAll: Bool {
        if case .opened = self { return true }
        return false
    }
}

@MainActor
final class GitController: ObservableObject {
    typealias ServiceFactory = (URL) throws -> GitService
    typealias OpenWorktreeFile = @MainActor (URL) async -> Bool
    typealias DiscardPreflight = @MainActor ([URL]) async
        -> Result<GitDiscardPreflightResult, GitDiscardPreflightError>
    typealias CompleteDiscardPreflight = @MainActor (
        GitDiscardPreflightResult, _ requiresReconciliation: Bool
    ) async -> Void
    typealias PresentConflict = @MainActor (GitConflictOpenRequest) async -> Bool
    typealias BranchPreflight = @MainActor (URL) async
        -> Result<GitBranchPreflightResult, GitBranchPreflightError>
    typealias CompleteBranchPreflight = @MainActor (
        GitBranchPreflightResult, _ requiresReconciliation: Bool
    ) async -> Void

    enum DetailKind: String, Equatable {
        case diff
        case history
        case blame
    }

    @Published private(set) var rootURL: URL?
    @Published private(set) var selectedFileURL: URL?
    @Published private(set) var selectedRelativePath: String?
    @Published private(set) var status: GitStatus?
    @Published private(set) var conflicts: [GitConflict] = []
    @Published private(set) var selectedPaths: Set<String> = []
    @Published private(set) var activePath: String?

    @Published private(set) var detailKind: DetailKind = .diff
    @Published private(set) var diff: GitDiff?
    @Published private(set) var hunks: [GitHunk] = []
    @Published private(set) var selectedHunk: GitHunk?
    @Published private(set) var history: [GitHistoryEntry] = []
    @Published private(set) var blame: GitBlame?

    @Published private(set) var operation: GitControllerOperation?
    @Published private(set) var issue: GitPresentationIssue?
    @Published private(set) var pendingConfirmation: GitMutationConfirmation?
    @Published private(set) var pendingDiscard: GitDiscardRequest?
    @Published private(set) var isConfirmingMutation = false
    @Published private(set) var confirmationProgress: GitConfirmationProgress?

    private let serviceFactory: ServiceFactory
    private var service: GitService?
    private var rootGeneration: UInt64 = 0
    private var statusGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var operationID: UUID?
    private let openWorktreeFile: OpenWorktreeFile
    private let discardPreflight: DiscardPreflight
    private let completeDiscardPreflight: CompleteDiscardPreflight
    private let presentConflict: PresentConflict
    private let branchPreflight: BranchPreflight
    private let completeBranchPreflight: CompleteBranchPreflight
    private var confirmationInFlightID: UUID?
    private var confirmationTaskID: UUID?
    private var confirmationTask: Task<Bool, Never>?
    private var isShutdown = false
    private var serviceReclamations: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?

    init(
        serviceFactory: @escaping ServiceFactory = { try GitService(rootURL: $0) },
        openWorktreeFile: @escaping OpenWorktreeFile = { _ in false },
        discardPreflight: @escaping DiscardPreflight = { _ in .success(.init(refreshTokens: [])) },
        completeDiscardPreflight: @escaping CompleteDiscardPreflight = { _, _ in },
        branchPreflight: @escaping BranchPreflight = { _ in .success(.init(refreshTokens: [])) },
        completeBranchPreflight: @escaping CompleteBranchPreflight = { _, _ in },
        presentConflict: @escaping PresentConflict = { _ in false }
    ) {
        self.serviceFactory = serviceFactory
        self.openWorktreeFile = openWorktreeFile
        self.discardPreflight = discardPreflight
        self.completeDiscardPreflight = completeDiscardPreflight
        self.presentConflict = presentConflict
        self.branchPreflight = branchPreflight
        self.completeBranchPreflight = completeBranchPreflight
    }

    var isBusy: Bool { operation != nil || isConfirmingMutation }
    var hasWorkspace: Bool { rootURL != nil }
    var isRepositoryAvailable: Bool { status?.available == true }
    var conflictPresentations: [GitConflictPresentation] {
        conflicts.map { GitConflictPresentation(path: $0.path, ours: $0.ours, theirs: $0.theirs) }
    }

    /// The shell owns WorkspaceController and the active editor. It injects a
    /// snapshot here instead of giving GitController either object's lifetime.
    /// A root change cancels old commands, builds a root-scoped GitService, and
    /// refreshes. A selected-file-only change does not restart repository work.
    func updateContext(
        primaryRoot: WorkspaceRoot?,
        selectedFileURL: URL?
    ) async {
        await updateContext(rootURL: primaryRoot?.url, selectedFileURL: selectedFileURL)
    }

    func updateContext(rootURL newRootURL: URL?, selectedFileURL: URL?) async {
        guard !isShutdown else { return }
        let normalizedRoot = normalizedAbsoluteFileURL(newRootURL)
        guard normalizedRoot != rootURL else {
            updateSelectedFile(selectedFileURL)
            if service != nil, status == nil, !isBusy { await refresh() }
            return
        }

        await switchRoot(to: normalizedRoot, selectedFileURL: selectedFileURL)
    }

    private func switchRoot(to normalizedRoot: URL?, selectedFileURL: URL?) async {
        let pendingConfirmationTask = confirmationTask
        confirmationTask?.cancel()
        rootGeneration &+= 1
        let generation = rootGeneration
        detailGeneration &+= 1
        let previousService = service
        service = nil
        rootURL = normalizedRoot
        operation = nil
        operationID = nil
        confirmationInFlightID = nil
        issue = nil
        pendingConfirmation = nil
        pendingDiscard = nil
        confirmationProgress = nil
        clearRepositoryState()
        updateSelectedFile(selectedFileURL)
        if let previousService { registerReclamation(of: previousService) }
        if let pendingConfirmationTask { await pendingConfirmationTask.value }
        guard rootGeneration == generation, rootURL == normalizedRoot else { return }
        confirmationTask = nil
        confirmationTaskID = nil
        isConfirmingMutation = false

        // A root-scoped service must not outlive its context. Cancellation may
        // briefly suspend while the old process terminates; generation checks
        // keep any concurrently requested newer context authoritative.
        await joinServiceReclamations()
        guard !isShutdown else { return }
        guard let normalizedRoot else { return }

        do {
            service = try serviceFactory(normalizedRoot)
        } catch {
            present(error, operation: .refreshing)
            return
        }
        await refresh()
    }

    /// Irreversibly stops this window's root-scoped Git work and waits for
    /// hooks, filters, and other descendants to leave their process groups.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShutdown else { return }
        let task = Task { @MainActor [weak self] in
            await self?.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        guard !isShutdown else { return }
        let pendingConfirmationTask = confirmationTask
        confirmationTask?.cancel()
        isShutdown = true
        rootGeneration &+= 1
        detailGeneration &+= 1
        let previousService = service
        service = nil
        rootURL = nil
        operation = nil
        operationID = nil
        confirmationInFlightID = nil
        issue = nil
        pendingConfirmation = nil
        pendingDiscard = nil
        confirmationProgress = nil
        clearRepositoryState()
        if let previousService { registerReclamation(of: previousService) }
        if let pendingConfirmationTask { await pendingConfirmationTask.value }
        confirmationTask = nil
        confirmationTaskID = nil
        isConfirmingMutation = false

        let reclamations = Array(serviceReclamations.values)
        for reclamation in reclamations { await reclamation.value }
    }

    /// Registration is synchronous on the main actor and always precedes the
    /// first suspension, so shutdown and later root switches can observe every
    /// service whose teardown is already in flight.
    private func registerReclamation(of service: GitService) {
        let id = UUID()
        serviceReclamations[id] = Task { @MainActor [weak self] in
            await service.shutdown()
            self?.serviceReclamations[id] = nil
        }
    }

    private func joinServiceReclamations() async {
        while !serviceReclamations.isEmpty {
            let reclamations = Array(serviceReclamations.values)
            for reclamation in reclamations { await reclamation.value }
        }
    }

    func updateSelectedFile(_ url: URL?) {
        let normalized = normalizedAbsoluteFileURL(url)
        let relative = normalized.flatMap(relativePath(for:))
        selectedFileURL = normalized
        guard relative != selectedRelativePath else { return }

        selectedRelativePath = relative
        detailGeneration &+= 1
        activePath = relative
        clearDetails()
        if let relative, status?.entries.contains(where: { $0.path == relative }) == true {
            selectedPaths = [relative]
        } else {
            selectedPaths = []
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        await refresh(allowingConfirmationTask: false)
    }

    private func refresh(allowingConfirmationTask: Bool) async -> Bool {
        guard pendingConfirmation == nil, pendingDiscard == nil,
              allowingConfirmationTask || !isConfirmingMutation else { return false }
        guard let context = begin(
            .refreshing, allowingConfirmationTask: allowingConfirmationTask
        ) else { return false }
        do {
            let refreshedStatus = try await context.service.status()
            let refreshedConflicts = refreshedStatus.available
                ? try await context.service.conflicts()
                : []
            guard isCurrent(context) else { return false }
            apply(refreshedStatus)
            conflicts = refreshedConflicts
            finish(context)
            return true
        } catch {
            finish(context, error: error)
            return false
        }
    }

    func loadDiff(for relativePath: String) async {
        await loadDiff(for: relativePath, includingHunks: false)
    }

    func loadDiffAndHunks(for relativePath: String) async {
        guard prepareDetail(.diff, relativePath: relativePath) else { return }
        let requestGeneration = detailGeneration
        guard let context = begin(.loadingDiff(relativePath)) else { return }
        do {
            let loadedDiff = try await context.service.diff(relativePath: relativePath)
            guard isCurrent(context) else { return }
            guard detailGeneration == requestGeneration, activePath == relativePath else {
                finish(context)
                return
            }
            diff = loadedDiff
            hunks = GitParsers.parseHunks(relativePath: relativePath, diff: loadedDiff.diff)
            selectedHunk = hunks.first
            finish(context)
        } catch {
            finish(context, error: error)
        }
    }

    func loadHunks(for relativePath: String) async {
        guard prepareDetail(.diff, relativePath: relativePath) else { return }
        let requestGeneration = detailGeneration
        guard let context = begin(.loadingHunks(relativePath)) else { return }
        do {
            let loadedHunks = try await context.service.hunks(relativePath: relativePath)
            guard isCurrent(context) else { return }
            guard detailGeneration == requestGeneration, activePath == relativePath else {
                finish(context)
                return
            }
            hunks = loadedHunks
            selectedHunk = loadedHunks.first
            finish(context)
        } catch {
            finish(context, error: error)
        }
    }

    func loadHistory(for relativePath: String) async {
        guard prepareDetail(.history, relativePath: relativePath) else { return }
        let requestGeneration = detailGeneration
        guard let context = begin(.loadingHistory(relativePath)) else { return }
        do {
            let loadedHistory = try await context.service.history(relativePath: relativePath)
            guard isCurrent(context) else { return }
            guard detailGeneration == requestGeneration, activePath == relativePath else {
                finish(context)
                return
            }
            history = loadedHistory
            finish(context)
        } catch {
            finish(context, error: error)
        }
    }

    func loadBlame(for relativePath: String) async {
        guard prepareDetail(.blame, relativePath: relativePath) else { return }
        let requestGeneration = detailGeneration
        guard let context = begin(.loadingBlame(relativePath)) else { return }
        do {
            let loadedBlame = try await context.service.blameDetails(relativePath: relativePath)
            guard isCurrent(context) else { return }
            guard detailGeneration == requestGeneration, activePath == relativePath else {
                finish(context)
                return
            }
            blame = loadedBlame
            finish(context)
        } catch {
            finish(context, error: error)
        }
    }

    @discardableResult
    func loadConflicts() async -> Bool {
        guard let context = begin(.loadingConflicts) else { return false }
        do {
            let loadedConflicts = try await context.service.conflicts()
            guard isCurrent(context) else { return false }
            conflicts = loadedConflicts
            finish(context)
            return true
        } catch {
            finish(context, error: error)
            return false
        }
    }

    func setActivePath(_ relativePath: String) {
        guard fileURL(for: relativePath) != nil else { return }
        guard activePath != relativePath else { return }
        detailGeneration &+= 1
        activePath = relativePath
        clearDetails()
    }

    func toggleSelection(of relativePath: String) {
        guard status?.entries.contains(where: { $0.path == relativePath }) == true else { return }
        if selectedPaths.contains(relativePath) {
            selectedPaths.remove(relativePath)
        } else {
            selectedPaths.insert(relativePath)
        }
        setActivePath(relativePath)
    }

    func selectAllChanges() {
        selectedPaths = Set(status?.entries.map(\.path) ?? [])
    }

    func clearSelection() {
        selectedPaths = []
    }

    func selectHunk(_ hunk: GitHunk) {
        guard hunks.contains(hunk) else { return }
        selectedHunk = hunk
    }

    func fileURL(for relativePath: String) -> URL? {
        guard let rootURL else { return nil }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard self.relativePath(for: candidate) == relativePath else { return nil }
        return candidate
    }

    @discardableResult
    func openFile(_ relativePath: String) async -> Bool {
        guard let url = fileURL(for: relativePath) else { return false }
        return await openWorktreeFile(url)
    }

    @discardableResult
    func requestStage(paths: [String]? = nil) -> Bool {
        requestPathConfirmation(.stage, paths: paths)
    }

    @discardableResult
    func requestUnstage(paths: [String]? = nil) -> Bool {
        requestPathConfirmation(.unstage, paths: paths)
    }

    @discardableResult
    func requestStage(hunk: GitHunk) -> Bool {
        guard canRequestConfirmation else { return false }
        guard hunks.contains(hunk), !hunk.patch.isEmpty, fileURL(for: hunk.path) != nil else {
            presentInputIssue(.currentHunkToStage)
            return false
        }
        return setPendingConfirmation(.stageHunk(hunk))
    }

    @discardableResult
    func requestCommit(message: String) -> Bool {
        guard canRequestConfirmation else { return false }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            presentInputIssue(.commitMessageRequired)
            return false
        }
        return setPendingConfirmation(.commit(message: message))
    }

    @discardableResult
    func requestCheckoutBranch(_ branch: String) -> Bool {
        requestBranchConfirmation(branch, create: false)
    }

    @discardableResult
    func requestCreateBranch(_ branch: String) -> Bool {
        requestBranchConfirmation(branch, create: true)
    }

    func cancelConfirmation() {
        guard confirmationInFlightID == nil else { return }
        pendingConfirmation = nil
    }

    @discardableResult
    func confirmPendingMutation() async -> Bool {
        if let confirmationTask { return await confirmationTask.value }
        let taskID = UUID()
        isConfirmingMutation = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performPendingMutationConfirmation()
        }
        confirmationTaskID = taskID
        confirmationTask = task
        let result = await task.value
        if confirmationTaskID == taskID {
            confirmationTaskID = nil
            confirmationTask = nil
            isConfirmingMutation = false
        }
        return result
    }

    private func performPendingMutationConfirmation() async -> Bool {
        guard let request = pendingConfirmation else { return false }
        guard confirmationInFlightID == nil else { return false }
        guard isCurrent(request) else {
            if pendingConfirmation?.id == request.id { pendingConfirmation = nil }
            presentInputIssue(.confirmationOutOfDate)
            return false
        }

        var branchPreflightResult: GitBranchPreflightResult?
        if request.target.isBranchMutation {
            confirmationProgress = .checkingBranchDocuments
            confirmationInFlightID = request.id
            switch await branchPreflight(request.rootURL) {
            case let .success(result):
                branchPreflightResult = result
            case let .failure(error):
                guard confirmationInFlightID == request.id else {
                    return false
                }
                confirmationInFlightID = nil
                confirmationProgress = nil
                guard isCurrent(request), !Task.isCancelled else {
                    return false
                }
                pendingConfirmation = nil
                issue = GitPresentationIssue(
                    title: .branchChangeBlocked, content: .branchPreflight(error)
                )
                return false
            }
            // The preflight closure is asynchronous. Recheck both immutable
            // request identity and repository generation before mutating.
            guard confirmationInFlightID == request.id else {
                if let branchPreflightResult {
                    confirmationProgress = .reconcilingBranchDocuments
                    await completeBranchPreflight(branchPreflightResult, false)
                }
                confirmationProgress = nil
                return false
            }
            confirmationInFlightID = nil
            guard !Task.isCancelled else {
                if let branchPreflightResult {
                    confirmationProgress = .reconcilingBranchDocuments
                    await completeBranchPreflight(branchPreflightResult, false)
                }
                confirmationProgress = nil
                return false
            }
            guard isCurrent(request), !Task.isCancelled else {
                if pendingConfirmation?.id == request.id {
                    pendingConfirmation = nil
                    if !Task.isCancelled { presentInputIssue(.confirmationOutOfDate) }
                }
                if let branchPreflightResult {
                    confirmationProgress = .reconcilingBranchDocuments
                    await completeBranchPreflight(branchPreflightResult, false)
                }
                confirmationProgress = nil
                return false
            }
            confirmationProgress = nil
        }

        pendingConfirmation = nil
        let outcome: GitMutationExecutionOutcome
        switch request.target {
        case let .stagePaths(paths):
            outcome = await perform(.stage, paths: paths, fromConfirmation: true)
        case let .unstagePaths(paths):
            outcome = await perform(.unstage, paths: paths, fromConfirmation: true)
        case let .stageHunk(hunk):
            outcome = await perform(
                .stageHunk, paths: [hunk.path], patch: hunk.patch, fromConfirmation: true
            )
        case let .commit(message):
            outcome = await perform(.commit, message: message, fromConfirmation: true)
        case let .checkoutBranch(name):
            outcome = await perform(
                .checkoutBranch, branch: name, fromConfirmation: true
            )
        case let .createBranch(name):
            outcome = await perform(
                .createBranch, branch: name, fromConfirmation: true
            )
        }
        if request.target.isBranchMutation {
            if let branchPreflightResult {
                confirmationProgress = .reconcilingBranchDocuments
                await completeBranchPreflight(
                    branchPreflightResult, outcome.requiresReconciliation
                )
            }
            confirmationProgress = nil
        }
        return outcome.didCommit
    }

    func requestDiscard(paths: [String]? = nil) {
        guard canRequestConfirmation else { return }
        guard let paths = validatedKnownPaths(paths) else {
            presentInputIssue(.changedFilesFromStatus)
            return
        }
        guard !paths.isEmpty else {
            presentInputIssue(.changedFileToDiscard)
            return
        }
        guard let rootURL else { return }
        pendingDiscard = GitDiscardRequest(
            target: .paths(paths), rootGeneration: rootGeneration,
            statusGeneration: statusGeneration, rootURL: rootURL
        )
    }

    func requestDiscard(hunk: GitHunk) {
        guard canRequestConfirmation else { return }
        guard hunks.contains(hunk), !hunk.patch.isEmpty, fileURL(for: hunk.path) != nil else {
            presentInputIssue(.validHunkToDiscard)
            return
        }
        guard let rootURL else { return }
        pendingDiscard = GitDiscardRequest(
            target: .hunk(hunk), rootGeneration: rootGeneration,
            statusGeneration: statusGeneration, rootURL: rootURL
        )
    }

    func cancelDiscard() {
        guard confirmationInFlightID == nil else { return }
        pendingDiscard = nil
    }

    @discardableResult
    func confirmDiscard() async -> Bool {
        if let confirmationTask { return await confirmationTask.value }
        let taskID = UUID()
        isConfirmingMutation = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performDiscardConfirmation()
        }
        confirmationTaskID = taskID
        confirmationTask = task
        let result = await task.value
        if confirmationTaskID == taskID {
            confirmationTaskID = nil
            confirmationTask = nil
            isConfirmingMutation = false
        }
        return result
    }

    private func performDiscardConfirmation() async -> Bool {
        guard let request = pendingDiscard else { return false }
        guard confirmationInFlightID == nil else { return false }
        guard isCurrent(request) else {
            pendingDiscard = nil
            presentInputIssue(.confirmationOutOfDate)
            return false
        }
        let urls = request.affectedPaths.compactMap(fileURL(for:))
        guard urls.count == request.affectedPaths.count else {
            presentInputIssue(.changedFilesFromStatus)
            return false
        }
        let preflight: GitDiscardPreflightResult
        confirmationProgress = .checkingDiscardDocuments
        confirmationInFlightID = request.id
        switch await discardPreflight(urls) {
        case let .success(result):
            preflight = result
        case let .failure(error):
            guard confirmationInFlightID == request.id else {
                confirmationProgress = nil
                return false
            }
            confirmationInFlightID = nil
            confirmationProgress = nil
            guard isCurrent(request), !Task.isCancelled else { return false }
            pendingDiscard = nil
            issue = GitPresentationIssue(
                title: .discardBlocked, content: .discardPreflight(error)
            )
            return false
        }
        guard confirmationInFlightID == request.id else {
            confirmationProgress = .reconcilingDiscardDocuments
            await completeDiscardPreflight(preflight, false)
            confirmationProgress = nil
            return false
        }
        confirmationInFlightID = nil
        guard isCurrent(request), !Task.isCancelled else {
            if pendingDiscard?.id == request.id {
                pendingDiscard = nil
                if !Task.isCancelled { presentInputIssue(.confirmationOutOfDate) }
            }
            confirmationProgress = .reconcilingDiscardDocuments
            await completeDiscardPreflight(preflight, false)
            confirmationProgress = nil
            return false
        }

        pendingDiscard = nil
        confirmationProgress = nil
        let outcome: GitMutationExecutionOutcome
        switch request.target {
        case let .paths(paths):
            outcome = await perform(.discard, paths: paths, fromConfirmation: true)
        case let .hunk(hunk):
            outcome = await perform(
                .discardHunk, paths: [hunk.path], patch: hunk.patch,
                fromConfirmation: true
            )
        }
        confirmationProgress = .reconcilingDiscardDocuments
        await completeDiscardPreflight(preflight, outcome.requiresReconciliation)
        confirmationProgress = nil
        return outcome.didCommit
    }

    @discardableResult
    func openConflict(
        _ target: GitConflictPresentation.Target,
        conflict: GitConflictPresentation
    ) async -> Bool {
        guard !isBusy else { return false }
        guard let service,
              conflicts.contains(where: { $0.path == conflict.path }) else { return false }
        let ours: OpenedTextFile?
        let theirs: OpenedTextFile?
        do {
            ours = target == .ours || target == .compare
                ? try await service.conflictSnapshot(relativePath: conflict.path, side: .ours)
                : nil
            theirs = target == .theirs || target == .compare
                ? try await service.conflictSnapshot(relativePath: conflict.path, side: .theirs)
                : nil
        } catch {
            present(error, operation: .loadingConflicts)
            return false
        }
        return await presentConflict(GitConflictOpenRequest(
            target: target,
            path: conflict.path,
            worktreeURL: fileURL(for: conflict.path),
            ours: ours,
            theirs: theirs
        ))
    }

    func openAllWorktreeConflicts() async -> GitOpenAllWorktreeConflictsResult {
        guard await loadConflicts() else {
            return .failed(openedCount: 0)
        }
        guard !conflicts.isEmpty else { return .noChange }

        var openedCount = 0
        for conflict in conflictPresentations {
            let didOpen = await openConflict(.worktree, conflict: conflict)
            guard didOpen else {
                if issue == nil {
                    issue = GitPresentationIssue(
                        title: .operationFailed,
                        content: .conflictedFile(path: conflict.path)
                    )
                }
                return .failed(openedCount: openedCount)
            }
            openedCount += 1
        }
        return .opened(count: openedCount)
    }

    func dismissIssue() {
        issue = nil
    }

    private var canRequestConfirmation: Bool {
        !isBusy && !isConfirmingMutation
            && pendingConfirmation == nil && pendingDiscard == nil
    }

    @discardableResult
    private func setPendingConfirmation(
        _ target: GitMutationConfirmation.Target
    ) -> Bool {
        guard let rootURL, let status, status.available else {
            issue = GitPresentationIssue(
                title: .unavailable, content: .app(.noWorkspace)
            )
            return false
        }
        issue = nil
        pendingConfirmation = GitMutationConfirmation(
            target: target,
            rootGeneration: rootGeneration,
            statusGeneration: statusGeneration,
            rootURL: rootURL
        )
        return true
    }

    @discardableResult
    private func requestPathConfirmation(_ action: GitAction, paths: [String]?) -> Bool {
        guard canRequestConfirmation else { return false }
        guard let paths = validatedKnownPaths(paths), !paths.isEmpty else {
            presentInputIssue(.changedFileForAction)
            return false
        }
        switch action {
        case .stage: return setPendingConfirmation(.stagePaths(paths))
        case .unstage: return setPendingConfirmation(.unstagePaths(paths))
        default: return false
        }
    }

    @discardableResult
    private func requestBranchConfirmation(_ rawBranch: String, create: Bool) -> Bool {
        guard canRequestConfirmation else { return false }
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            presentInputIssue(.branchNameRequired)
            return false
        }
        return setPendingConfirmation(
            create ? .createBranch(name: branch) : .checkoutBranch(name: branch)
        )
    }

    private func isCurrent(_ request: GitMutationConfirmation) -> Bool {
        pendingConfirmation?.id == request.id
            && rootGeneration == request.rootGeneration
            && statusGeneration == request.statusGeneration
            && rootURL == request.rootURL
            && operation == nil
    }

    private func isCurrent(_ request: GitDiscardRequest) -> Bool {
        pendingDiscard?.id == request.id
            && rootGeneration == request.rootGeneration
            && statusGeneration == request.statusGeneration
            && rootURL == request.rootURL
            && operation == nil
    }

    private struct OperationContext {
        let id: UUID
        let rootGeneration: UInt64
        let rootURL: URL
        let service: GitService
        let operation: GitControllerOperation
    }

    private func begin(
        _ requestedOperation: GitControllerOperation,
        allowingConfirmationTask: Bool = false
    ) -> OperationContext? {
        guard !isShutdown else { return nil }
        guard operation == nil, confirmationInFlightID == nil else { return nil }
        guard allowingConfirmationTask || confirmationTask == nil else { return nil }
        guard let rootURL, let service else {
            issue = GitPresentationIssue(
                title: .unavailable, content: .app(.noWorkspace)
            )
            return nil
        }
        let id = UUID()
        operationID = id
        operation = requestedOperation
        issue = nil
        return OperationContext(
            id: id,
            rootGeneration: rootGeneration,
            rootURL: rootURL,
            service: service,
            operation: requestedOperation
        )
    }

    private func isCurrent(_ context: OperationContext) -> Bool {
        operationID == context.id
            && rootGeneration == context.rootGeneration
            && rootURL == context.rootURL
    }

    private func finish(_ context: OperationContext, error: (any Error)? = nil) {
        guard isCurrent(context) else { return }
        operation = nil
        operationID = nil
        guard let error, !isCancellation(error) else { return }
        present(error, operation: context.operation)
    }

    private func loadDiff(for relativePath: String, includingHunks: Bool) async {
        guard prepareDetail(.diff, relativePath: relativePath) else { return }
        let requestGeneration = detailGeneration
        guard let context = begin(.loadingDiff(relativePath)) else { return }
        do {
            let loadedDiff = try await context.service.diff(relativePath: relativePath)
            let loadedHunks = includingHunks
                ? GitParsers.parseHunks(relativePath: relativePath, diff: loadedDiff.diff)
                : []
            guard isCurrent(context) else { return }
            guard detailGeneration == requestGeneration, activePath == relativePath else {
                finish(context)
                return
            }
            diff = loadedDiff
            hunks = loadedHunks
            selectedHunk = loadedHunks.first
            finish(context)
        } catch {
            finish(context, error: error)
        }
    }

    private func prepareDetail(_ kind: DetailKind, relativePath: String) -> Bool {
        guard !isBusy, fileURL(for: relativePath) != nil else { return false }
        detailGeneration &+= 1
        detailKind = kind
        activePath = relativePath
        clearDetails()
        return true
    }

    @discardableResult
    private func perform(
        _ action: GitAction,
        paths: [String]? = nil,
        message: String? = nil,
        branch: String? = nil,
        patch: String? = nil,
        fromConfirmation: Bool = false
    ) async -> GitMutationExecutionOutcome {
        guard let context = begin(
            .action(action), allowingConfirmationTask: fromConfirmation
        ) else { return .notStarted }
        let serviceTask = Task {
            try await context.service.perform(GitActionRequest(
                root: context.rootURL, action: action, paths: paths,
                message: message, branch: branch, patch: patch
            ))
        }
        do {
            let result = await withTaskCancellationHandler {
                await serviceTask.result
            } onCancel: {
                // The root-scoped service also gets shut down by switchRoot, but
                // direct task cancellation must make the in-flight command stop.
                serviceTask.cancel()
            }
            switch result {
            case let .success(.committed(statusRefresh)):
                // Context changes may make this snapshot irrelevant, but callers
                // must still reconcile locked documents before releasing locks.
                if isCurrent(context) {
                    switch statusRefresh {
                    case let .refreshed(refreshedStatus):
                        apply(refreshedStatus)
                        conflicts = conflictsDerived(from: refreshedStatus)
                        detailGeneration &+= 1
                        clearDetails()
                        finish(context)
                    case let .failed(error):
                        // Keep the last known status visible; a later manual or
                        // watcher refresh can replace it. This does not change
                        // the mutation's committed state.
                        finish(context, error: error)
                    }
                }
                return .committed
            case let .success(.indeterminate(error)):
                if isCurrent(context) { finish(context, error: error) }
                return .indeterminate
            case let .failure(error):
                finish(context, error: error)
                return .notStarted
            }
        }
    }

    private func apply(_ refreshedStatus: GitStatus) {
        // GitService has already removed credentials, query strings, and
        // fragments from remote addresses. Keep those safe display values in
        // observable state so the native panel can match the renderer UI.
        status = refreshedStatus
        statusGeneration &+= 1

        let currentPaths = Set(refreshedStatus.entries.map(\.path))
        selectedPaths.formIntersection(currentPaths)
        if let selectedRelativePath, currentPaths.contains(selectedRelativePath) {
            selectedPaths.insert(selectedRelativePath)
        }
        if activePath == nil {
            activePath = selectedRelativePath ?? refreshedStatus.entries.first?.path
        }
    }

    private func conflictsDerived(from status: GitStatus) -> [GitConflict] {
        let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        return status.entries.compactMap { entry in
            conflictCodes.contains(entry.indexStatus + entry.worktreeStatus)
                ? conflicts.first(where: { $0.path == entry.path }) ?? GitConflict(path: entry.path)
                : nil
        }
    }

    private func resolvedPaths(_ supplied: [String]?) -> [String] {
        let source = supplied ?? Array(selectedPaths)
        return Array(Set(source)).sorted()
    }

    private func validatedKnownPaths(_ supplied: [String]?) -> [String]? {
        let paths = resolvedPaths(supplied)
        let knownPaths = Set(status?.entries.map(\.path) ?? [])
        guard paths.allSatisfy(knownPaths.contains) else { return nil }
        return paths
    }

    private func relativePath(for candidateURL: URL) -> String? {
        guard let rootURL, candidateURL.isFileURL else { return nil }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else { return nil }
        let components = candidateComponents.dropFirst(rootComponents.count)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private func normalizedAbsoluteFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL, url.path.hasPrefix("/") else { return nil }
        return url.standardizedFileURL
    }

    private func clearRepositoryState() {
        status = nil
        conflicts = []
        selectedPaths = []
        activePath = nil
        selectedFileURL = nil
        selectedRelativePath = nil
        clearDetails()
    }

    private func clearDetails() {
        diff = nil
        hunks = []
        selectedHunk = nil
        history = []
        blame = nil
    }

    private func presentInputIssue(_ inputIssue: GitInputIssue) {
        issue = GitPresentationIssue(
            title: .actionUnavailable, content: .input(inputIssue)
        )
    }

    private func present(_ error: any Error, operation: GitControllerOperation) {
        issue = GitPresentationIssue(
            title: .operationFailed,
            content: safeMessage(for: error, operation: operation)
        )
    }

    private func safeMessage(
        for error: any Error,
        operation: GitControllerOperation
    ) -> GitPresentationIssue.Message {
        guard let gitError = error as? GitServiceError else {
            return .operationFailure(.generic(operation: operation))
        }
        switch gitError {
        case let .processFailed(exitCode, _):
            return .operationFailure(.processExited(
                status: exitCode, operation: operation
            ))
        case .launchFailed:
            return .app(.launchFailed)
        case .cancelled:
            return .app(.cancelled)
        default:
            return .verbatim(gitError.localizedDescription)
        }
    }

    private func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? GitServiceError) == .cancelled
    }
}

private enum GitMutationExecutionOutcome {
    case notStarted
    case committed
    case indeterminate

    var didCommit: Bool {
        if case .committed = self { return true }
        return false
    }

    var requiresReconciliation: Bool {
        switch self {
        case .notStarted: return false
        case .committed, .indeterminate: return true
        }
    }
}

enum GitOperationFailure: Equatable, Sendable {
    case generic(operation: GitControllerOperation)
    case processExited(status: Int32, operation: GitControllerOperation)

    var englishMessage: String {
        switch self {
        case let .generic(operation):
            return "\(operation.accessibilityDescription) could not be completed."
        case let .processExited(status, operation):
            return "Git exited with status \(status) while \(operation.accessibilityDescription.lowercased())."
        }
    }

    func localizedMessage(locale: EditorLocale) -> String {
        guard locale.isSimplifiedChinese else { return englishMessage }
        switch self {
        case let .generic(operation):
            return "无法完成\(operation.localizedDescription(locale: locale, ongoing: false))。"
        case let .processExited(status, operation):
            return "Git 在\(operation.localizedDescription(locale: locale, ongoing: false))时退出，状态码为 \(status)。"
        }
    }
}
