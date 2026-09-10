import Combine
@preconcurrency import Foundation
import LumenEditorCore

private final class CompletionTaskBox {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

private final class CompletionWorkspaceObserverCleanup {
    weak var cache: WorkspaceCompletionCache?
    var observerID: UUID?

    func set(cache: WorkspaceCompletionCache, observerID: UUID?) {
        self.cache = cache
        self.observerID = observerID
    }

    @MainActor
    func disconnect() {
        if let cache, let observerID {
            cache.removeObserver(observerID)
        }
        observerID = nil
    }

    deinit {
        guard let cache, let observerID else { return }
        Task { @MainActor [weak cache] in
            cache?.removeObserver(observerID)
        }
    }
}

struct CompletionDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let revision: UInt64
    let text: String
    let cursorUTF16Offset: Int
    let fileURL: URL?
    let language: String
    let project: WindowSessionProject?
    let workspaceRoots: [WorkspaceRoot]
}

struct CompletionPresentation: Equatable, Sendable {
    let query: CompletionQuery
    let suggestions: [CompletionSuggestion]
    let selectedIndex: Int

    var selectedSuggestion: CompletionSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }
}

struct CompletionPaneIdentity: Equatable, Hashable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let paneIndex: Int

    func isActive(
        activeDocumentID: String?, activeViewID: EditorViewID,
        activePaneIndex: Int
    ) -> Bool {
        activeDocumentID == documentID && activeViewID == viewID
            && activePaneIndex == paneIndex
    }
}

@MainActor
final class WorkspaceCompletionCache: ObservableObject {
    private let ttl: TimeInterval
    private let now: () -> Date
    private var words: [String] = []
    private var indexedAt: Date?
    private let taskBox = CompletionTaskBox()
    private var generation: UInt64 = 0
    private var observers: [UUID: @MainActor ([String]) -> Void] = [:]

    init(
        ttl: TimeInterval = CompletionPlanner.workspaceCacheTTL,
        now: @escaping () -> Date = Date.init
    ) {
        self.ttl = max(0, ttl)
        self.now = now
    }

    var currentWords: [String] { words }

    private var task: Task<Void, Never>? {
        get { taskBox.task }
        set { taskBox.task = newValue }
    }

    func invalidate() {
        generation = next(generation)
        task?.cancel()
        task = nil
        words = []
        indexedAt = nil
        notifyObservers()
    }

    func refreshIfNeeded(
        using provider: @escaping @MainActor () async -> [String]?
    ) {
        let fresh = !words.isEmpty && indexedAt.map {
            now().timeIntervalSince($0) <= ttl
        } ?? false
        guard !fresh, task == nil else { return }
        generation = next(generation)
        let requestedGeneration = generation
        task = Task { @MainActor [weak self] in
            let result = await provider()
            guard let self, !Task.isCancelled, requestedGeneration == self.generation else {
                return
            }
            self.task = nil
            guard let result else { return }
            self.words = Array(result.prefix(CompletionPlanner.maximumWorkspaceWords))
            self.indexedAt = self.now()
            self.notifyObservers()
        }
    }

    func isFreshForTesting() -> Bool {
        !words.isEmpty && indexedAt.map { now().timeIntervalSince($0) <= ttl } ?? false
    }

    func waitForRefreshForTesting() async {
        await task?.value
    }

    @discardableResult
    func observe(_ observer: @escaping @MainActor ([String]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(words)
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    private func notifyObservers() {
        for observer in observers.values { observer(words) }
    }

    private func next(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }
}

@MainActor
final class CompletionController: ObservableObject {
    let id = UUID()
    typealias SnapshotProvider = @MainActor () -> CompletionDocumentSnapshot?
    typealias LanguageServerRequest = @MainActor (
        CompletionDocumentSnapshot, CompletionQuery
    ) async -> [LanguageCompletionItem]?
    typealias LanguageServerAvailability = @MainActor (
        CompletionDocumentSnapshot, CompletionQuery
    ) -> Bool
    typealias WorkspaceWordsProvider = @MainActor () async -> [String]?
    typealias OpenBufferProvider = @MainActor () -> [String]
    typealias ApplyTransaction = @MainActor (
        TextTransaction, CompletionDocumentSnapshot
    ) -> Bool
    typealias PresentApproval = @MainActor (
        LanguageServerApprovalRequest,
        @escaping @MainActor () async -> Void,
        @escaping @MainActor () -> Void
    ) -> Void

    @Published private(set) var presentation: CompletionPresentation?
    @Published private(set) var isLoading = false

    private var snapshotProvider: SnapshotProvider
    private var requestLanguageServer: LanguageServerRequest
    private var canRequestLanguageServer: LanguageServerAvailability
    private var workspaceWordsProvider: WorkspaceWordsProvider
    private var openBufferProvider: OpenBufferProvider
    private var applyTransaction: ApplyTransaction
    private let workspaceCache: WorkspaceCompletionCache

    private let taskBox = CompletionTaskBox()
    private let observerCleanup = CompletionWorkspaceObserverCleanup()
    private var requestGeneration: UInt64 = 0
    private var pendingRequestIdentity: CompletionQuery?
    private var presentationObserver: (@MainActor (CompletionPresentation?) -> Void)?
    private var isConnected = false
    private var approvalProvider: (@MainActor () -> LanguageServerApprovalRequest?)?
    private var confirmApproval: (@MainActor () async -> Void)?
    private var declineApproval: (@MainActor () -> Void)?
    private var replayedCompletionProvider: (@MainActor () -> [LanguageCompletionItem]?)?
    private var languageServerIssueProvider: (@MainActor () -> LanguageServerPresentationIssue?)?
    private var presentLanguageServerIssue: (@MainActor (LanguageServerPresentationIssue) -> Void) = { _ in }
    private var presentApproval: PresentApproval = { _, _, _ in }
    private var pendingApprovalSnapshot: CompletionDocumentSnapshot?
    private var pendingApprovalQuery: CompletionQuery?
    private var workspaceObserverID: UUID?
    private var usesWorkspaceFallback = false
    private var didPresentApproval = false

    convenience init(workspaceCache: WorkspaceCompletionCache) {
        self.init(
            snapshot: { nil }, requestLanguageServer: { _, _ in nil },
            canRequestLanguageServer: { _, _ in false },
            workspaceWords: { nil }, openBuffers: { [] },
            applyTransaction: { _, _ in false },
            workspaceCache: workspaceCache
        )
    }

    init(
        snapshot: @escaping SnapshotProvider,
        requestLanguageServer: @escaping LanguageServerRequest,
        canRequestLanguageServer: @escaping LanguageServerAvailability = { _, _ in true },
        workspaceWords: @escaping WorkspaceWordsProvider,
        openBuffers: @escaping OpenBufferProvider,
        applyTransaction: @escaping ApplyTransaction,
        workspaceCache: WorkspaceCompletionCache
    ) {
        snapshotProvider = snapshot
        self.requestLanguageServer = requestLanguageServer
        self.canRequestLanguageServer = canRequestLanguageServer
        workspaceWordsProvider = workspaceWords
        openBufferProvider = openBuffers
        self.applyTransaction = applyTransaction
        self.workspaceCache = workspaceCache
        workspaceObserverID = nil
    }

    var isPresented: Bool { presentation != nil }

    private var task: Task<Void, Never>? {
        get { taskBox.task }
        set { taskBox.task = newValue }
    }

    func request() {
        guard let snapshot = snapshotProvider(),
              let query = CompletionPlanner.query(
                documentID: snapshot.documentID, viewID: snapshot.viewID,
                revision: snapshot.revision, text: snapshot.text,
                cursorUTF16Offset: snapshot.cursorUTF16Offset
              ) else {
            dismiss()
            return
        }
        if pendingRequestIdentity == query { return }

        requestGeneration = next(requestGeneration)
        let generation = requestGeneration
        let hadPendingApproval = didPresentApproval
        task?.cancel()
        if hadPendingApproval { declinePendingApproval() }
        setPresentation(nil)
        pendingApprovalSnapshot = nil
        pendingApprovalQuery = nil
        didPresentApproval = false
        pendingRequestIdentity = query
        usesWorkspaceFallback = false
        isLoading = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let canRequestLanguageServer = self.canRequestLanguageServer(snapshot, query)
            let lsp = canRequestLanguageServer
                ? await requestLanguageServer(snapshot, query) : nil
            guard self.isCurrent(snapshot, query: query, generation: generation) else {
                self.finishDiscardedRequest(generation)
                return
            }
            if let approval = self.approvalProvider?() {
                self.pendingApprovalSnapshot = snapshot
                self.pendingApprovalQuery = query
                self.didPresentApproval = true
                self.isLoading = false
                self.task = nil
                self.pendingRequestIdentity = nil
                self.presentApproval(
                    approval,
                    { [weak self] in await self?.confirmPendingApproval() },
                    { [weak self] in self?.declinePendingApproval() }
                )
                return
            }
            if canRequestLanguageServer, lsp == nil,
               let issue = self.languageServerIssueProvider?() {
                self.presentLanguageServerIssue(issue)
                self.finishDiscardedRequest(generation)
                return
            }
            let lspSuggestions = CompletionPlanner.languageServerSuggestions(lsp ?? [])
            if !lspSuggestions.isEmpty {
                self.usesWorkspaceFallback = false
                self.publish(lspSuggestions, query: query, generation: generation)
                return
            }

            let fallback = CompletionPlanner.workspaceSuggestions(
                token: query.token, openBufferTexts: openBufferProvider(),
                workspaceWords: self.workspaceCache.currentWords, currentText: query.text
            )
            guard self.isCurrent(snapshot, query: query, generation: generation) else {
                self.finishDiscardedRequest(generation)
                return
            }
            self.usesWorkspaceFallback = true
            self.publish(fallback, query: query, generation: generation)
            self.workspaceCache.refreshIfNeeded(using: self.workspaceWordsProvider)
        }
    }

    func dismiss() {
        cancelRequest()
        if didPresentApproval { declinePendingApproval() }
    }

    func cancelRequest() {
        requestGeneration = next(requestGeneration)
        task?.cancel()
        task = nil
        pendingRequestIdentity = nil
        isLoading = false
        setPresentation(nil)
        usesWorkspaceFallback = false
    }

    /// The TextKit coordinator applies the exact transaction locally so the
    /// AppKit mirror and DocumentBuffer advance atomically. This consumes only
    /// the presentation after its document/view/revision/cursor guard passes.
    func consumeSelectionForNativeEditor() -> (CompletionSuggestion, CompletionQuery)? {
        guard let current = presentation, let suggestion = current.selectedSuggestion,
              let snapshot = snapshotProvider(), matches(snapshot, query: current.query)
        else {
            dismiss()
            return nil
        }
        cancelRequest()
        return (suggestion, current.query)
    }

    func activeEditorDidChange() {
        cancelRequest()
    }

    func editorContextDidChange() {
        let query = pendingRequestIdentity ?? presentation?.query ?? pendingApprovalQuery
        guard let query else { return }
        guard let snapshot = snapshotProvider(), matches(snapshot, query: query) else {
            cancelRequest()
            return
        }
    }

    func disconnect() {
        cancelRequest()
        if didPresentApproval { declinePendingApproval() }
        observerCleanup.disconnect()
        workspaceObserverID = nil
        presentationObserver = nil
        isConnected = false
    }

    func shutdown() {
        disconnect()
    }

    func confirmPendingApproval() async {
        guard let snapshot = pendingApprovalSnapshot,
              let query = pendingApprovalQuery else { return }
        pendingApprovalSnapshot = nil
        pendingApprovalQuery = nil
        didPresentApproval = false
        requestGeneration = next(requestGeneration)
        let generation = requestGeneration
        await confirmApproval?()
        if currentLanguageServerApproval() != nil { return }
        guard let current = snapshotProvider(), current == snapshot,
              matches(current, query: query) else { return }
        if let replayed = replayedCompletionProvider?(), !replayed.isEmpty {
            usesWorkspaceFallback = false
            publish(
                CompletionPlanner.languageServerSuggestions(replayed),
                query: query, generation: generation
            )
        } else {
            usesWorkspaceFallback = true
            publish(CompletionPlanner.workspaceSuggestions(
                token: query.token, openBufferTexts: openBufferProvider(),
                workspaceWords: workspaceCache.currentWords, currentText: query.text
            ), query: query, generation: generation)
            workspaceCache.refreshIfNeeded(using: workspaceWordsProvider)
        }
    }

    func declinePendingApproval() {
        pendingApprovalSnapshot = nil
        pendingApprovalQuery = nil
        didPresentApproval = false
        declineApproval?()
    }

    func moveSelection(by delta: Int) {
        guard let current = presentation, !current.suggestions.isEmpty else { return }
        let nextIndex = ((current.selectedIndex + delta) % current.suggestions.count
            + current.suggestions.count) % current.suggestions.count
        setPresentation(CompletionPresentation(
            query: current.query, suggestions: current.suggestions, selectedIndex: nextIndex
        ))
    }

    func select(at index: Int) {
        guard let current = presentation, current.suggestions.indices.contains(index),
              current.selectedIndex != index else { return }
        setPresentation(CompletionPresentation(
            query: current.query, suggestions: current.suggestions, selectedIndex: index
        ))
    }

    func setPresentationObserver(
        _ observer: (@MainActor (CompletionPresentation?) -> Void)?
    ) {
        presentationObserver = observer
        observer?(presentation)
    }

    /// Test seam for the exact approval/replay handshake. Production installs
    /// these callbacks through `connect(...)` and the window-owned broker.
#if DEBUG
    func setTestLanguageServerLifecycle(
        approval: @escaping @MainActor () -> LanguageServerApprovalRequest?,
        confirm: @escaping @MainActor () async -> Void,
        decline: @escaping @MainActor () -> Void,
        replayed: @escaping @MainActor () -> [LanguageCompletionItem]?,
        present: @escaping PresentApproval
    ) {
        approvalProvider = approval
        confirmApproval = confirm
        declineApproval = decline
        replayedCompletionProvider = replayed
        presentApproval = present
    }
#endif

    @discardableResult
    func acceptSelection() -> Bool {
        guard let current = presentation,
              let suggestion = current.selectedSuggestion,
              let snapshot = snapshotProvider(),
              matches(snapshot, query: current.query),
              let transaction = CompletionPlanner.insertionTransaction(
                suggestion: suggestion, query: current.query
              ),
              applyTransaction(transaction, snapshot) else {
            dismiss()
            return false
        }
        dismiss()
        return true
    }

    private func publish(
        _ suggestions: [CompletionSuggestion], query: CompletionQuery,
        generation: UInt64
    ) {
        guard generation == requestGeneration else { return }
        isLoading = false
        task = nil
        pendingRequestIdentity = nil
        setPresentation(suggestions.isEmpty ? nil : CompletionPresentation(
            query: query, suggestions: suggestions, selectedIndex: 0
        ))
    }

    private func finishDiscardedRequest(_ generation: UInt64) {
        guard generation == requestGeneration else { return }
        isLoading = false
        task = nil
        pendingRequestIdentity = nil
        setPresentation(nil)
    }

    private func isCurrent(
        _ captured: CompletionDocumentSnapshot, query: CompletionQuery,
        generation: UInt64
    ) -> Bool {
        guard generation == requestGeneration, !Task.isCancelled,
              let current = snapshotProvider(), matches(current, query: query) else {
            return false
        }
        return current.documentID == captured.documentID
            && current.viewID == captured.viewID
            && current.revision == captured.revision
    }

    private func matches(
        _ snapshot: CompletionDocumentSnapshot, query: CompletionQuery
    ) -> Bool {
        snapshot.documentID == query.documentID
            && snapshot.viewID == query.viewID
            && snapshot.revision == query.revision
            && snapshot.cursorUTF16Offset == query.cursorUTF16Offset
            && snapshot.text == query.text
    }

    private func next(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private func setPresentation(_ value: CompletionPresentation?) {
        presentation = value
        presentationObserver?(value)
    }

    private func currentLanguageServerApproval() -> LanguageServerApprovalRequest? {
        approvalProvider?()
    }

    private func workspaceWordsDidRefresh() {
        guard let current = presentation, usesWorkspaceFallback,
              let snapshot = snapshotProvider(), matches(snapshot, query: current.query)
        else { return }
        let refreshed = CompletionPlanner.workspaceSuggestions(
            token: current.query.token, openBufferTexts: openBufferProvider(),
            workspaceWords: workspaceCache.currentWords, currentText: current.query.text
        )
        guard !refreshed.isEmpty else { return }
        setPresentation(CompletionPresentation(
            query: current.query, suggestions: refreshed, selectedIndex: 0
        ))
    }
}

extension CompletionController {
    func connect(
        model: AppModel, actions: EditorActionController, workspace: WorkspaceController,
        languageServers: LanguageServerController,
        documentID: String, viewID: EditorViewID, paneIndex: Int,
        applyTextTransaction: @escaping @MainActor (TextTransaction) -> Bool,
        presentApproval: @escaping PresentApproval = { _, _, _ in }
    ) {
        guard !isConnected else { return }
        isConnected = true
        let paneIdentity = CompletionPaneIdentity(
            documentID: documentID, viewID: viewID, paneIndex: paneIndex
        )
        if workspaceObserverID == nil {
            workspaceObserverID = workspaceCache.observe { [weak self] _ in
                self?.workspaceWordsDidRefresh()
            }
            observerCleanup.set(cache: workspaceCache, observerID: workspaceObserverID)
        }
        snapshotProvider = {
            guard paneIdentity.isActive(
                    activeDocumentID: model.selectedDocument?.sessionDocumentID,
                    activeViewID: model.paneLayout.activeViewID,
                    activePaneIndex: model.paneLayout.activePaneIndex
                  ),
                  model.paneLayout.panes.indices.contains(paneIndex),
                  model.paneLayout.panes[paneIndex].viewID == viewID,
                  model.paneLayout.panes[paneIndex].activeDocumentID == documentID,
                  let document = model.document(sessionDocumentID: documentID)
            else { return nil }
            return CompletionDocumentSnapshot(
                documentID: document.sessionDocumentID, viewID: viewID,
                revision: document.buffer.revision, text: document.buffer.text,
                cursorUTF16Offset: model.selection(
                    for: document.sessionDocumentID, viewID: viewID
                ).main.head,
                fileURL: document.fileURL, language: document.language,
                project: model.sessionProject, workspaceRoots: workspace.roots
            )
        }
        requestLanguageServer = { snapshot, query in
            guard let request = NativeFeatureCoordinator.languageServerRequest(
                snapshot: snapshot, query: query
            ) else { return nil }
            return await languageServers.completionForEditor(request)
        }
        canRequestLanguageServer = { snapshot, query in
            NativeFeatureCoordinator.languageServerRequest(
                snapshot: snapshot, query: query
            ) != nil
        }
        approvalProvider = { languageServers.pendingApproval }
        confirmApproval = { await languageServers.confirmPendingApproval() }
        declineApproval = { languageServers.declinePendingApproval() }
        replayedCompletionProvider = { languageServers.takeEditorCompletionResult() }
        languageServerIssueProvider = { languageServers.issue }
        presentLanguageServerIssue = { issue in
            actions.presentIssue(issue)
            languageServers.dismissIssue()
        }
        self.presentApproval = presentApproval
        workspaceWordsProvider = {
            await NativeFeatureCoordinator.workspaceCompletionWords(workspace: workspace)
        }
        openBufferProvider = { model.documents.map { $0.buffer.text } }
        self.applyTransaction = { transaction, captured in
            guard paneIdentity.isActive(
                    activeDocumentID: model.selectedDocument?.sessionDocumentID,
                    activeViewID: model.paneLayout.activeViewID,
                    activePaneIndex: model.paneLayout.activePaneIndex
                  ),
                  model.paneLayout.panes.indices.contains(paneIndex),
                  model.paneLayout.panes[paneIndex].viewID == viewID,
                  model.paneLayout.panes[paneIndex].activeDocumentID == documentID,
                  let current = model.document(sessionDocumentID: documentID),
                  current.sessionDocumentID == captured.documentID,
                  current.buffer.revision == captured.revision else { return false }
            return applyTextTransaction(transaction)
        }
    }

}
