import Combine
import Foundation
import LumenEditorCore

enum WorkspaceSearchMode: String, CaseIterable, Identifiable, Sendable {
    case find
    case replace

    var id: String { rawValue }
    var title: String { self == .find ? "Find" : "Replace" }
}

enum WorkspaceSearchStatus: Equatable, Sendable {
    case idle
    case searching
    case matches(count: Int, truncated: Bool)
    case previewing
    case previewReady(files: Int, replacements: Int, truncated: Bool)
    case applying
    case applied(files: Int, replacements: Int)
    case undoing
    case undone(files: Int)
    case cancelled
}

enum WorkspaceSearchFileChangeKind: Equatable, Sendable {
    case replacement
    case undo
}

struct WorkspaceSearchPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case search
        case previewReplacement
        case applyReplacement
        case undoReplacement
    }

    enum Message: Equatable, Sendable {
        case app(WorkspaceSearchAppIssue)
        case searchError(WorkspaceSearchError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English text for diagnostics and controller-level compatibility.
    /// Views render the typed title and content with the current runtime locale.
    var title: String { EditorLocale.enUS.localizedWorkspaceSearchIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedWorkspaceSearchIssue(content) }

    init(id: UUID = UUID(), title: Title, message: String) {
        self.id = id
        self.titleContent = title
        self.content = .verbatim(message)
    }

    init(id: UUID = UUID(), title: Title, appIssue: WorkspaceSearchAppIssue) {
        self.id = id
        self.titleContent = title
        self.content = .app(appIssue)
    }

    init(id: UUID = UUID(), title: Title, error: any Error) {
        self.id = id
        self.titleContent = title
        if let searchError = error as? WorkspaceSearchError {
            self.content = .searchError(searchError)
        } else {
            self.content = .verbatim(error.localizedDescription)
        }
    }
}

enum WorkspaceSearchAppIssue: Equatable, Sendable {
    case missingWorkspace
    case missingQuery
}

/// Main-actor presentation state for native Find/Replace in Files.
///
/// Root wiring is deliberately capability-based: the production initializer
/// snapshots `WorkspaceController.roots.map(\.id)` for every operation and
/// runs the core against that controller's exact `WorkspaceService`. The shell
/// only needs to supply navigation and post-write reconciliation callbacks; it
/// must not translate result URLs into new filesystem grants.
@MainActor
final class WorkspaceSearchController: ObservableObject {
    typealias NavigateToMatch = @MainActor (WorkspaceMatch) async -> Bool
    typealias FilesChanged = @MainActor ([URL], WorkspaceSearchFileChangeKind) async -> Void

    typealias SearchAction = (WorkspaceSearchRequest) async throws -> WorkspaceSearchResult
    typealias PreviewAction = (WorkspaceReplaceRequest) async throws -> WorkspaceReplacePreview
    typealias ApplyAction = (WorkspaceReplacePreview) async throws -> WorkspaceReplaceResult
    typealias UndoAction = (WorkspaceReplaceReceipt) async throws -> WorkspaceReplaceResult
    typealias ScopedSearchAction = (
        WorkspaceSearchRequest, WorkspaceProjectExclusionSnapshot
    ) async throws -> WorkspaceSearchResult
    typealias ScopedPreviewAction = (
        WorkspaceReplaceRequest, WorkspaceProjectExclusionSnapshot
    ) async throws -> WorkspaceReplacePreview
    typealias ScopedApplyAction = (
        WorkspaceReplacePreview, WorkspaceProjectExclusionSnapshot
    ) async throws -> WorkspaceReplaceResult
    typealias ProjectExclusionObserver = @MainActor (
        @escaping @MainActor (WorkspaceProjectExclusionSnapshot) -> Void
    ) -> AnyCancellable
    typealias ProjectExclusionSnapshotProvider = @MainActor () ->
        WorkspaceProjectExclusionSnapshot
    typealias RootSnapshotProvider = @MainActor () -> [WorkspaceRoot.ID]
    typealias RootObserver = @MainActor (
        @escaping @MainActor ([WorkspaceRoot.ID]) -> Void
    ) -> AnyCancellable
    typealias RecordHistory = @MainActor (_ search: String, _ replacement: String?) -> Void
    typealias HistoryProvider = @MainActor () -> [String]

    @Published var mode: WorkspaceSearchMode {
        didSet { if mode != oldValue { editableInputDidChange() } }
    }
    @Published var query: String {
        didSet { if query != oldValue { editableInputDidChange() } }
    }
    @Published var replacement: String {
        didSet { if replacement != oldValue { editableInputDidChange() } }
    }
    @Published var includePattern: String {
        didSet { if includePattern != oldValue { editableInputDidChange() } }
    }
    @Published var excludePattern: String {
        didSet { if excludePattern != oldValue { editableInputDidChange() } }
    }
    @Published var isCaseSensitive: Bool {
        didSet { if isCaseSensitive != oldValue { editableInputDidChange() } }
    }
    @Published var isWholeWord: Bool {
        didSet { if isWholeWord != oldValue { editableInputDidChange() } }
    }
    @Published var usesRegularExpression: Bool {
        didSet { if usesRegularExpression != oldValue { editableInputDidChange() } }
    }

    @Published private(set) var rootIDs: [WorkspaceRoot.ID]
    @Published private(set) var matches: [WorkspaceMatch] = []
    @Published private(set) var selectedResultIndex: Int?
    @Published private(set) var status: WorkspaceSearchStatus = .idle
    @Published private(set) var issue: WorkspaceSearchPresentationIssue?
    @Published private(set) var isApplyConfirmationPresented = false
    @Published private(set) var isPresented = false
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var replaceHistory: [String] = []

    private let searchAction: ScopedSearchAction
    private let previewAction: ScopedPreviewAction
    private let applyAction: ScopedApplyAction
    private let undoAction: UndoAction
    private let navigateToMatch: NavigateToMatch
    private let filesChanged: FilesChanged
    private var recordHistory: RecordHistory = { _, _ in }
    private var searchHistoryProvider: HistoryProvider = { [] }
    private var replaceHistoryProvider: HistoryProvider = { [] }

    @Published private(set) var currentPreview: WorkspaceReplacePreview?
    private var previewInputRevision: UInt64?
    private var previewProjectExclusionSnapshot: WorkspaceProjectExclusionSnapshot?
    private var resultProjectExclusionSnapshot: WorkspaceProjectExclusionSnapshot?
    private var resultRootIDs: [WorkspaceRoot.ID]?
    private var confirmationProjectExclusionSnapshot: WorkspaceProjectExclusionSnapshot?
    private var undoReceipt: WorkspaceReplaceReceipt?
    private var undoFileURLs: [URL] = []
    private var inputRevision: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var operationTask: Task<Void, Never>?
    private var rootsSubscription: AnyCancellable?
    private var projectExclusionsSubscription: AnyCancellable?
    private var deferredRootIDs: [WorkspaceRoot.ID]?
    private let rootSnapshotProvider: RootSnapshotProvider?
    private var projectExclusionSnapshot: WorkspaceProjectExclusionSnapshot
    private let projectExclusionSnapshotProvider: ProjectExclusionSnapshotProvider?
    private var deferredProjectExclusionSnapshot: WorkspaceProjectExclusionSnapshot?

    /// Production wiring. `WorkspaceController` remains the sole owner of root
    /// grants; this controller observes its public root snapshot and shares its
    /// capability-scoped service with `WorkspaceSearch`.
    convenience init(
        workspaceController: WorkspaceController,
        mode: WorkspaceSearchMode = .find,
        navigateToMatch: @escaping NavigateToMatch,
        filesChanged: @escaping FilesChanged = { _, _ in }
    ) {
        let core = WorkspaceSearch(workspace: workspaceController.service)
        let initialExclusions = workspaceController.projectExclusionSnapshot
        self.init(
            rootIDs: workspaceController.roots.map(\.id),
            mode: mode,
            search: { try await core.searchResult($0) },
            preview: { try await core.previewReplace($0) },
            apply: { try await core.apply($0) },
            undo: { try await core.undo($0) },
            navigateToMatch: navigateToMatch,
            filesChanged: filesChanged,
            projectExclusionSnapshot: initialExclusions,
            projectExclusionSnapshotProvider: {
                workspaceController.projectExclusionSnapshot
            },
            rootSnapshotProvider: {
                workspaceController.rootSnapshot.ids
            },
            searchWithScope: { request, snapshot in
                try await core.searchResult(
                    request, projectExclusions: snapshot.exclusions
                )
            },
            previewWithScope: { request, snapshot in
                try await core.previewReplace(
                    request, projectExclusions: snapshot.exclusions
                )
            },
            applyWithScope: { preview, snapshot in
                try await core.apply(
                    preview, projectExclusions: snapshot.exclusions
                )
            }
        )
        rootsSubscription = workspaceController.$roots
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] rootIDs in
                Task { @MainActor [weak self] in
                    self?.setRootIDs(rootIDs)
                }
            }
        projectExclusionsSubscription = workspaceController.$projectExclusionSnapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.setProjectExclusionSnapshot(snapshot)
                }
            }
    }

    /// Dependency-injected initializer used by App tests and alternate shells.
    /// Root IDs must still originate from a trusted `WorkspaceController`; the
    /// core rejects IDs absent from its associated `WorkspaceService`.
    init(
        rootIDs: [WorkspaceRoot.ID],
        mode: WorkspaceSearchMode = .find,
        query: String = "",
        replacement: String = "",
        includePattern: String = "",
        excludePattern: String = "",
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        usesRegularExpression: Bool = false,
        search: @escaping SearchAction,
        preview: @escaping PreviewAction,
        apply: @escaping ApplyAction,
        undo: @escaping UndoAction,
        navigateToMatch: @escaping NavigateToMatch = { _ in true },
        filesChanged: @escaping FilesChanged = { _, _ in },
        projectExclusionSnapshot: WorkspaceProjectExclusionSnapshot = .init(
            exclusions: [], generation: 0
        ),
        projectExclusionSnapshotProvider: ProjectExclusionSnapshotProvider? = nil,
        rootSnapshotProvider: RootSnapshotProvider? = nil,
        observeRoots: RootObserver? = nil,
        observeProjectExclusions: ProjectExclusionObserver? = nil,
        searchWithScope: ScopedSearchAction? = nil,
        previewWithScope: ScopedPreviewAction? = nil,
        applyWithScope: ScopedApplyAction? = nil
    ) {
        self.rootIDs = Self.unique(rootIDs)
        self.mode = mode
        self.query = query
        self.replacement = replacement
        self.includePattern = includePattern
        self.excludePattern = excludePattern
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.usesRegularExpression = usesRegularExpression
        searchAction = searchWithScope ?? { request, _ in try await search(request) }
        previewAction = previewWithScope ?? { request, _ in try await preview(request) }
        applyAction = applyWithScope ?? { preview, _ in try await apply(preview) }
        undoAction = undo
        self.navigateToMatch = navigateToMatch
        self.filesChanged = filesChanged
        self.projectExclusionSnapshot = projectExclusionSnapshot
        self.projectExclusionSnapshotProvider = projectExclusionSnapshotProvider
        self.rootSnapshotProvider = rootSnapshotProvider
        if let observeRoots {
            rootsSubscription = observeRoots { [weak self] rootIDs in
                self?.setRootIDs(rootIDs)
            }
        }
        if let observeProjectExclusions {
            projectExclusionsSubscription = observeProjectExclusions { [weak self] snapshot in
                self?.setProjectExclusionSnapshot(snapshot)
            }
        }
    }

    var isBusy: Bool {
        switch status {
        case .searching, .previewing, .applying, .undoing: true
        default: false
        }
    }

    var isCancelable: Bool {
        status == .searching || status == .previewing
    }

    var isMutatingFiles: Bool {
        status == .applying || status == .undoing
    }

    var canSearch: Bool {
        !isBusy && !rootIDs.isEmpty && !query.isEmpty
    }

    var canPreviewReplacement: Bool {
        canSearch && mode == .replace
    }

    var canApplyPreview: Bool {
        !isBusy && mode == .replace && currentPreview != nil &&
            previewInputRevision == inputRevision &&
            previewProjectExclusionSnapshot == latestProjectExclusionSnapshot
    }

    var canUndo: Bool {
        !isBusy && undoReceipt != nil
    }

    var hasResults: Bool { !matches.isEmpty }

    var selectedMatch: WorkspaceMatch? {
        guard let selectedResultIndex, matches.indices.contains(selectedResultIndex) else {
            return nil
        }
        return matches[selectedResultIndex]
    }

    var statusMessage: String {
        EditorLocale.enUS.localizedWorkspaceSearchStatus(
            status, hasRoots: !rootIDs.isEmpty, purpose: .visible
        )
    }

    var primaryActionTitle: String { mode == .find ? "Find All" : "Preview Replace" }

    func setHistoryRecorder(_ recorder: @escaping RecordHistory) {
        recordHistory = recorder
    }

    func setHistoryIntegration(
        search: @escaping HistoryProvider,
        replace: @escaping HistoryProvider,
        record: @escaping RecordHistory
    ) {
        setHistoryProviders(search: search, replace: replace)
        setHistoryRecorder { [weak self] search, replacement in
            record(search, replacement)
            self?.refreshHistory()
        }
    }

    func setHistoryProviders(
        search: @escaping HistoryProvider,
        replace: @escaping HistoryProvider
    ) {
        searchHistoryProvider = search
        replaceHistoryProvider = replace
        refreshHistory()
    }

    func refreshHistory() {
        synchronizeHistory(
            search: searchHistoryProvider(), replace: replaceHistoryProvider()
        )
    }

    func synchronizeHistory(search: [String], replace: [String]) {
        searchHistory = Array(search.prefix(50))
        replaceHistory = Array(replace.prefix(50))
    }

    func show(mode: WorkspaceSearchMode) {
        refreshHistory()
        if self.mode != mode { self.mode = mode }
        isPresented = true
        issue = nil
    }

    /// Configures and starts the non-LSP references fallback as one operation.
    /// Returning false leaves the panel hidden so callers can report no change.
    @discardableResult
    func showLiteralWholeWordResults(
        for identifier: String,
        caseSensitive: Bool,
        excludePattern: String = ""
    ) -> Bool {
        guard !isBusy, !rootIDs.isEmpty, !identifier.isEmpty else { return false }
        mode = .find
        query = identifier
        replacement = ""
        includePattern = ""
        self.excludePattern = excludePattern
        isCaseSensitive = caseSensitive
        isWholeWord = true
        usesRegularExpression = false
        show(mode: .find)
        return search()
    }

    func dismiss() {
        guard !isMutatingFiles else { return }
        if isCancelable { cancel() }
        isApplyConfirmationPresented = false
        confirmationProjectExclusionSnapshot = nil
        isPresented = false
    }

    func dismissIssue() {
        issue = nil
    }

    @discardableResult
    func performPrimaryAction() -> Bool {
        switch mode {
        case .find: return search()
        case .replace: return previewReplacement()
        }
    }

    /// Starts a cancellable search. Completion is published only while both
    /// the operation generation and the form revision still match.
    @discardableResult
    func search() -> Bool {
        guard !isBusy else { return false }
        synchronizeRootIDs()
        synchronizeProjectExclusionSnapshot()
        guard let request = requestForOperation(title: .search) else {
            return false
        }

        let generation = beginOperation(.searching)
        let revision = inputRevision
        let exclusions = projectExclusionSnapshot
        let action = searchAction
        operationTask = Task { @MainActor [weak self] in
            do {
                let result = try await action(request, exclusions)
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                guard
                      self.isCurrentOperation(
                        generation, inputRevision: revision,
                        rootIDs: request.rootIDs,
                        projectExclusionSnapshot: exclusions
                      ) else { return }
                self.matches = result.matches
                self.resultRootIDs = request.rootIDs
                self.resultProjectExclusionSnapshot = exclusions
                self.selectedResultIndex = result.matches.isEmpty ? nil : 0
                self.status = .matches(
                    count: result.matches.count,
                    truncated: result.isTruncated
                )
                self.recordHistory(request.query, nil)
                self.operationTask = nil
            } catch is CancellationError {
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                self.completeCancellation(
                    generation: generation, rootIDs: request.rootIDs,
                    projectExclusionSnapshot: exclusions
                )
            } catch {
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                self.completeFailure(
                    error,
                    title: .search,
                    generation: generation, rootIDs: request.rootIDs,
                    projectExclusionSnapshot: exclusions
                )
            }
        }
        return true
    }

    /// Starts a cancellable, revision-pinned preview. No disk bytes are changed.
    @discardableResult
    func previewReplacement() -> Bool {
        guard mode == .replace else { return false }
        guard !isBusy else { return false }
        synchronizeRootIDs()
        synchronizeProjectExclusionSnapshot()
        guard let searchRequest = requestForOperation(title: .previewReplacement) else {
            return false
        }

        let request = WorkspaceReplaceRequest(search: searchRequest, replacement: replacement)
        let generation = beginOperation(.previewing)
        let revision = inputRevision
        let exclusions = projectExclusionSnapshot
        let action = previewAction
        operationTask = Task { @MainActor [weak self] in
            do {
                let preview = try await action(request, exclusions)
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                guard
                      self.isCurrentOperation(
                        generation, inputRevision: revision,
                        rootIDs: request.search.rootIDs,
                        projectExclusionSnapshot: exclusions
                      ) else { return }
                self.currentPreview = preview
                self.previewInputRevision = revision
                self.previewProjectExclusionSnapshot = exclusions
                self.matches = preview.matches
                self.resultRootIDs = request.search.rootIDs
                self.resultProjectExclusionSnapshot = exclusions
                self.selectedResultIndex = preview.matches.isEmpty ? nil : 0
                self.status = .previewReady(
                    files: preview.files,
                    replacements: preview.replacements,
                    truncated: preview.isTruncated
                )
                self.operationTask = nil
            } catch is CancellationError {
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                self.completeCancellation(
                    generation: generation, rootIDs: request.search.rootIDs,
                    projectExclusionSnapshot: exclusions
                )
            } catch {
                guard let self else { return }
                self.synchronizeRootIDs()
                self.synchronizeProjectExclusionSnapshot()
                self.completeFailure(
                    error,
                    title: .previewReplacement,
                    generation: generation, rootIDs: request.search.rootIDs,
                    projectExclusionSnapshot: exclusions
                )
            }
        }
        return true
    }

    /// Opens the destructive confirmation owned by `WorkspaceSearchPanelView`.
    /// The preview is never applied merely by creating it.
    @discardableResult
    func requestApplyPreview() -> Bool {
        synchronizeRootIDs()
        synchronizeProjectExclusionSnapshot()
        guard canApplyPreview, currentPreview?.replacements ?? 0 > 0 else { return false }
        confirmationProjectExclusionSnapshot = previewProjectExclusionSnapshot
        isApplyConfirmationPresented = true
        return true
    }

    func cancelApplyConfirmation() {
        isApplyConfirmationPresented = false
        confirmationProjectExclusionSnapshot = nil
    }

    @discardableResult
    func confirmApplyPreview() -> Bool {
        guard isApplyConfirmationPresented else { return false }
        synchronizeRootIDs()
        synchronizeProjectExclusionSnapshot()
        guard canApplyPreview, let preview = currentPreview,
              let exclusions = confirmationProjectExclusionSnapshot
                ?? previewProjectExclusionSnapshot,
              exclusions == projectExclusionSnapshot else {
            isApplyConfirmationPresented = false
            confirmationProjectExclusionSnapshot = nil
            return false
        }
        isApplyConfirmationPresented = false
        confirmationProjectExclusionSnapshot = nil

        _ = beginOperation(.applying)
        let action = applyAction
        let historyQuery = query
        let historyReplacement = replacement
        let changedURLs = preview.fileURLs
        operationTask = Task { @MainActor [weak self] in
            do {
                let result = try await action(preview, exclusions)
                guard let self else { return }
                self.currentPreview = nil
                self.previewInputRevision = nil
                self.previewProjectExclusionSnapshot = nil
                self.matches = []
                self.resultRootIDs = nil
                self.resultProjectExclusionSnapshot = nil
                self.selectedResultIndex = nil
                self.undoReceipt = result.receipt
                self.undoFileURLs = result.receipt == nil ? [] : changedURLs
                self.status = .applied(files: result.files, replacements: result.replacements)
                self.recordHistory(historyQuery, historyReplacement)
                self.operationTask = nil
                if result.files > 0 {
                    await self.filesChanged(changedURLs, .replacement)
                }
                self.synchronizeProjectExclusionSnapshot()
                self.applyDeferredScopeIfNeeded()
            } catch {
                guard let self else { return }
                self.operationTask = nil
                if let searchError = error as? WorkspaceSearchError,
                   case .rollbackFailed = searchError {
                    // Core explicitly reports an indeterminate partial state.
                    // The preview/receipt must not be retried against it.
                    self.currentPreview = nil
                    self.previewInputRevision = nil
                    self.previewProjectExclusionSnapshot = nil
                    self.matches = []
                    self.resultRootIDs = nil
                    self.resultProjectExclusionSnapshot = nil
                    self.selectedResultIndex = nil
                    self.undoReceipt = nil
                    self.undoFileURLs = []
                }
                self.status = .idle
                self.issue = WorkspaceSearchPresentationIssue(
                    title: .applyReplacement,
                    error: error
                )
                self.synchronizeProjectExclusionSnapshot()
                self.applyDeferredScopeIfNeeded()
            }
        }
        return true
    }

    @discardableResult
    func undoLastReplacement() -> Bool {
        guard !isBusy, let receipt = undoReceipt else { return false }

        _ = beginOperation(.undoing)
        let action = undoAction
        let changedURLs = undoFileURLs
        operationTask = Task { @MainActor [weak self] in
            do {
                let result = try await action(receipt)
                guard let self else { return }
                self.undoReceipt = nil
                self.undoFileURLs = []
                self.status = .undone(files: result.files)
                self.operationTask = nil
                if result.files > 0 {
                    await self.filesChanged(changedURLs, .undo)
                }
                self.synchronizeProjectExclusionSnapshot()
                self.applyDeferredScopeIfNeeded()
            } catch {
                guard let self else { return }
                self.operationTask = nil
                if let searchError = error as? WorkspaceSearchError {
                    switch searchError {
                    case .receiptAlreadyUsed, .rollbackFailed:
                        self.undoReceipt = nil
                        self.undoFileURLs = []
                    default:
                        break
                    }
                }
                self.status = .idle
                self.issue = WorkspaceSearchPresentationIssue(
                    title: .undoReplacement,
                    error: error
                )
                self.synchronizeProjectExclusionSnapshot()
                self.applyDeferredScopeIfNeeded()
            }
        }
        return true
    }

    /// Search and preview are safe to cancel. Once a disk mutation begins the
    /// operation must run through commit or compensating rollback.
    func cancel() {
        guard isCancelable else { return }
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        status = .cancelled
    }

    func selectResult(at index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedResultIndex = index
    }

    @discardableResult
    func moveResult(by offset: Int) -> WorkspaceMatch? {
        guard !matches.isEmpty else { return nil }
        let current = selectedResultIndex ?? 0
        let normalizedOffset = offset % matches.count
        let next = (current + normalizedOffset + matches.count) % matches.count
        selectedResultIndex = next
        return matches[next]
    }

    @discardableResult
    func navigate(to index: Int) async -> Bool {
        // A committed exclusions snapshot can precede its queued Combine
        // delivery by one main-actor turn. Re-read it at acceptance time so a
        // rendered result cannot open a path that has just become excluded.
        let latestExclusions = latestProjectExclusionSnapshot
        let latestRoots = latestRootIDs
        synchronizeRootIDs()
        synchronizeProjectExclusionSnapshot()
        guard matches.indices.contains(index) else { return false }
        guard resultRootIDs == latestRoots,
              resultRootIDs == rootIDs,
              resultProjectExclusionSnapshot == latestExclusions,
              resultProjectExclusionSnapshot == projectExclusionSnapshot else {
            invalidateInput()
            return false
        }
        selectedResultIndex = index
        return await navigateToMatch(matches[index])
    }

    @discardableResult
    func navigateToSelectedResult() async -> Bool {
        guard let selectedResultIndex else { return false }
        return await navigate(to: selectedResultIndex)
    }

    /// Test/support hook that waits for the operation current at call time.
    func waitForCurrentOperation() async {
        let task = operationTask
        await task?.value
    }

    /// Exact integration recipe for the current App shell. Keeping it here
    /// avoids giving the view direct access to either filesystem capabilities
    /// or AppModel internals. The host may use the lower-level initializer
    /// when it needs pane-specific navigation or a different refresh policy.
    static func connected(
        workspaceController: WorkspaceController,
        model: AppModel,
        mode: WorkspaceSearchMode = .find,
        securityScopedAccess: SecurityScopedAccessController = .shared
    ) -> WorkspaceSearchController {
        WorkspaceSearchController(
            workspaceController: workspaceController,
            mode: mode,
            navigateToMatch: { match in
                let lease: SecurityScopedResourceLease?
                do {
                    lease = try securityScopedAccess.accessPersistedURL(
                        match.url, kind: .file, allowingDirectoryAncestor: true
                    )
                } catch {
                    return false
                }
                let effectiveURL = lease?.url ?? match.url
                guard let document = await model.open(url: effectiveURL) else {
                    lease?.invalidate()
                    return false
                }
                if let lease { model.retainSecurityScopedAccess(lease, for: document) }
                let start = max(0, match.utf16Range.location)
                let end = min(document.buffer.utf16Length, NSMaxRange(match.utf16Range))
                guard end >= start else { return false }
                let paneIndex = model.paneLayout.activePaneIndex
                let viewID = model.paneLayout.panes[paneIndex].viewID
                do {
                    return try document.setSelections(
                        .single(anchor: start, head: end),
                        for: viewID
                    )
                } catch {
                    return false
                }
            },
            filesChanged: { urls, _ in
                workspaceController.refreshWorkspace()
                // AppModel's external-change path refreshes clean documents and
                // reports conflicts without overwriting dirty buffers.
                for url in urls {
                    guard let document = model.documents.first(where: {
                        $0.fileURL?.standardizedFileURL == url.standardizedFileURL
                    }) else { continue }
                    await model.checkForExternalChange(document)
                }
            }
        )
    }

    private func setRootIDs(_ rootIDs: [WorkspaceRoot.ID]) {
        let unique = Self.unique(rootIDs)
        guard unique != self.rootIDs else { return }
        guard !isMutatingFiles else {
            deferredRootIDs = unique
            return
        }
        deferredRootIDs = nil
        self.rootIDs = unique
        undoReceipt = nil
        undoFileURLs = []
        invalidateInput()
    }

    private var latestRootIDs: [WorkspaceRoot.ID] {
        Self.unique(rootSnapshotProvider?() ?? rootIDs)
    }

    private func synchronizeRootIDs() {
        guard let rootSnapshotProvider else { return }
        setRootIDs(rootSnapshotProvider())
    }

    private var latestProjectExclusionSnapshot: WorkspaceProjectExclusionSnapshot {
        projectExclusionSnapshotProvider?() ?? projectExclusionSnapshot
    }

    private func synchronizeProjectExclusionSnapshot() {
        guard let projectExclusionSnapshotProvider else { return }
        setProjectExclusionSnapshot(projectExclusionSnapshotProvider())
    }

    private func setProjectExclusionSnapshot(
        _ snapshot: WorkspaceProjectExclusionSnapshot
    ) {
        let latestKnown = deferredProjectExclusionSnapshot ?? projectExclusionSnapshot
        guard snapshot.generation >= latestKnown.generation else { return }
        guard snapshot != latestKnown else { return }
        guard !isMutatingFiles else {
            deferredProjectExclusionSnapshot = snapshot
            return
        }
        deferredProjectExclusionSnapshot = nil
        projectExclusionSnapshot = snapshot
        invalidateInput()
    }

    private func applyDeferredScopeIfNeeded() {
        let pendingRootIDs = deferredRootIDs
        deferredRootIDs = nil
        if let deferredProjectExclusionSnapshot {
            self.deferredProjectExclusionSnapshot = nil
            setProjectExclusionSnapshot(deferredProjectExclusionSnapshot)
        }
        if let pendingRootIDs {
            setRootIDs(pendingRootIDs)
        }
    }

    private func requestForOperation(
        title: WorkspaceSearchPresentationIssue.Title
    ) -> WorkspaceSearchRequest? {
        issue = nil
        guard !rootIDs.isEmpty else {
            issue = WorkspaceSearchPresentationIssue(
                title: title,
                appIssue: .missingWorkspace
            )
            return nil
        }
        guard !query.isEmpty else {
            issue = WorkspaceSearchPresentationIssue(
                title: title,
                appIssue: .missingQuery
            )
            return nil
        }
        // The Core mirrors Electron by truncating queries to 2,000 UTF-16
        // units. Keep UI request snapshots identical to that visible contract.
        let rawQuery = query as NSString
        let boundedQuery = rawQuery.substring(
            to: min(rawQuery.length, WorkspaceSearch.maximumQueryUTF16Length)
        )
        return WorkspaceSearchRequest(
            rootIDs: rootIDs,
            query: boundedQuery,
            caseSensitive: isCaseSensitive,
            wholeWord: isWholeWord,
            useRegex: usesRegularExpression,
            include: includePattern,
            exclude: excludePattern
        )
    }

    private func beginOperation(_ status: WorkspaceSearchStatus) -> UInt64 {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        issue = nil
        isApplyConfirmationPresented = false
        confirmationProjectExclusionSnapshot = nil
        self.status = status
        return operationGeneration
    }

    private func isCurrentOperation(
        _ generation: UInt64, inputRevision: UInt64,
        rootIDs: [WorkspaceRoot.ID],
        projectExclusionSnapshot: WorkspaceProjectExclusionSnapshot
    ) -> Bool {
        generation == operationGeneration && inputRevision == self.inputRevision &&
            rootIDs == self.rootIDs &&
            projectExclusionSnapshot == self.projectExclusionSnapshot &&
            !Task.isCancelled
    }

    private func completeCancellation(
        generation: UInt64,
        rootIDs: [WorkspaceRoot.ID],
        projectExclusionSnapshot: WorkspaceProjectExclusionSnapshot
    ) {
        guard generation == operationGeneration,
              rootIDs == self.rootIDs,
              projectExclusionSnapshot == self.projectExclusionSnapshot else { return }
        operationTask = nil
        status = .cancelled
    }

    private func completeFailure(
        _ error: any Error, title: WorkspaceSearchPresentationIssue.Title, generation: UInt64,
        rootIDs: [WorkspaceRoot.ID],
        projectExclusionSnapshot: WorkspaceProjectExclusionSnapshot
    ) {
        guard generation == operationGeneration,
              rootIDs == self.rootIDs,
              projectExclusionSnapshot == self.projectExclusionSnapshot else { return }
        operationTask = nil
        status = .idle
        issue = WorkspaceSearchPresentationIssue(
            title: title,
            error: error
        )
    }

    private func editableInputDidChange() {
        guard !isMutatingFiles else { return }
        invalidateInput()
    }

    private func invalidateInput() {
        inputRevision &+= 1
        currentPreview = nil
        previewInputRevision = nil
        previewProjectExclusionSnapshot = nil
        resultRootIDs = nil
        resultProjectExclusionSnapshot = nil
        isApplyConfirmationPresented = false
        confirmationProjectExclusionSnapshot = nil
        matches = []
        selectedResultIndex = nil
        issue = nil
        if isCancelable {
            operationGeneration &+= 1
            operationTask?.cancel()
            operationTask = nil
        }
        status = .idle
    }

    private static func unique(_ rootIDs: [WorkspaceRoot.ID]) -> [WorkspaceRoot.ID] {
        var result: [WorkspaceRoot.ID] = []
        for rootID in rootIDs where !result.contains(rootID) { result.append(rootID) }
        return result
    }
}
