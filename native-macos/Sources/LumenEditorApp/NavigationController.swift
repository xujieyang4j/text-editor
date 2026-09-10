import Combine
import Foundation
import LumenEditorCore

enum NavigationPaletteMode: String, CaseIterable, Sendable {
    case anything
    case file
    case symbol
    case projectSymbol
    case line
}

/// An immutable view of a document. Navigation deliberately consumes this
/// value instead of reaching into AppModel or retaining an EditorDocument.
struct NavigationDocumentSnapshot: Identifiable, Equatable, Sendable {
    let documentID: String
    let url: URL?
    let displayName: String
    let text: String

    var id: String { documentID }

    init(documentID: String, url: URL?, displayName: String, text: String) {
        self.documentID = documentID
        self.url = url
        self.displayName = displayName
        self.text = text
    }

    var totalLines: Int {
        1 + text.utf16.reduce(into: 0) { count, unit in
            if unit == 0x0a { count += 1 }
        }
    }

    func lineColumn(atUTF16Offset requestedOffset: Int) -> (line: Int, column: Int) {
        let units = Array(text.utf16)
        let offset = min(units.count, max(0, requestedOffset))
        var line = 1
        var column = 1
        for unit in units.prefix(offset) {
            if unit == 0x0a {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    func clampedLineColumn(line requestedLine: Int, column requestedColumn: Int)
        -> (line: Int, column: Int) {
        let units = Array(text.utf16)
        let line = min(totalLines, max(1, requestedLine))
        var start = 0
        var currentLine = 1
        while start < units.count, currentLine < line {
            if units[start] == 0x0a { currentLine += 1 }
            start += 1
        }
        var end = start
        while end < units.count, units[end] != 0x0a { end += 1 }
        let maximumColumn = end - start + 1
        return (line, min(maximumColumn, max(1, requestedColumn)))
    }

    /// Converts a 1-based line/UTF-16 column into a clamped document offset.
    /// Shell selection/open adapters can use this instead of duplicating the
    /// controller's coordinate policy.
    func utf16Offset(line requestedLine: Int, column requestedColumn: Int) -> Int {
        let units = Array(text.utf16)
        let target = clampedLineColumn(
            line: requestedLine, column: requestedColumn
        )
        var start = 0
        var currentLine = 1
        while start < units.count, currentLine < target.line {
            if units[start] == 0x0a { currentLine += 1 }
            start += 1
        }
        return min(units.count, start + target.column - 1)
    }
}

/// The cursor belongs to a pane, not just a document: the same buffer can be
/// visible at different positions in multiple panes.
struct NavigationPaneSnapshot: Identifiable, Equatable, Sendable {
    let groupID: Int
    let activeDocumentID: String?
    let cursorUTF16Offset: Int

    var id: Int { groupID }
    var paneID: Int { groupID }

    init(groupID: Int, activeDocumentID: String?, cursorUTF16Offset: Int) {
        self.groupID = groupID
        self.activeDocumentID = activeDocumentID
        self.cursorUTF16Offset = cursorUTF16Offset
    }
}

/// Complete value snapshot passed across every navigation callback boundary.
/// Its arrays and members are values, so an asynchronous callback never has to
/// observe a half-mutated application model.
struct NavigationAppSnapshot: Equatable, Sendable {
    let documents: [NavigationDocumentSnapshot]
    let panes: [NavigationPaneSnapshot]
    let activeGroupID: Int
    let workspaceRoots: [URL]

    init(
        documents: [NavigationDocumentSnapshot],
        panes: [NavigationPaneSnapshot],
        activeGroupID: Int,
        workspaceRoots: [URL] = []
    ) {
        self.documents = documents
        self.panes = panes
        self.activeGroupID = activeGroupID
        self.workspaceRoots = workspaceRoots
    }

    var activePane: NavigationPaneSnapshot? {
        panes.first { $0.groupID == activeGroupID }
    }

    var activeDocument: NavigationDocumentSnapshot? {
        guard let documentID = activePane?.activeDocumentID else { return nil }
        return document(id: documentID)
    }

    func document(id: String) -> NavigationDocumentSnapshot? {
        documents.first { $0.documentID == id }
    }

    func document(url: URL) -> NavigationDocumentSnapshot? {
        let path = Self.normalizedPath(url)
        return documents.first { document in
            document.url.map(Self.normalizedPath) == path
        }
    }

    var currentLocation: NavigationLocation? {
        guard let pane = activePane,
              let documentID = pane.activeDocumentID,
              let document = document(id: documentID) else { return nil }
        let position = Self.lineColumn(
            atUTF16Offset: pane.cursorUTF16Offset,
            in: document.text
        )
        return NavigationLocation(
            documentID: document.documentID,
            path: document.url.map(Self.normalizedPath),
            groupID: pane.groupID,
            line: position.line,
            column: position.column
        )
    }

    private static func lineColumn(
        atUTF16Offset requestedOffset: Int,
        in text: String
    ) -> (line: Int, column: Int) {
        let units = Array(text.utf16)
        let offset = min(units.count, max(0, requestedOffset))
        var line = 1
        var column = 1
        for unit in units.prefix(offset) {
            if unit == 0x0a {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    fileprivate static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

struct NavigationFileSnapshot: Identifiable, Equatable, Sendable {
    let url: URL
    /// The workspace-relative string searched and highlighted by the palette.
    let displayPath: String

    var id: String { NavigationAppSnapshot.normalizedPath(url) }

    init(url: URL, displayPath: String? = nil) {
        self.url = url
        self.displayPath = displayPath ?? url.path
    }
}

struct NavigationProjectSymbolSnapshot: Identifiable, Equatable, Sendable {
    let label: String
    let url: URL
    let displayPath: String
    let line: Int
    let column: Int
    let utf16Offset: Int?

    var id: String {
        "\(NavigationAppSnapshot.normalizedPath(url)):\(line):\(column):\(label)"
    }

    init(
        label: String,
        url: URL,
        displayPath: String? = nil,
        line: Int,
        column: Int = 1,
        utf16Offset: Int? = nil
    ) {
        self.label = label
        self.url = url
        self.displayPath = displayPath ?? url.path
        self.line = max(1, line)
        self.column = max(1, column)
        self.utf16Offset = utf16Offset.map { max(0, $0) }
    }
}

enum NavigationDestinationTarget: Equatable, Sendable {
    case document(id: String)
    case url(URL)
}

/// A semantic target. `groupID` is always explicit so selection does not
/// accidentally move a different view of a buffer in a multi-pane window.
struct NavigationDestination: Equatable, Sendable {
    let target: NavigationDestinationTarget
    let groupID: Int
    let line: Int?
    let column: Int?
    let utf16Offset: Int?
    let selectionUTF16Length: Int?

    init(
        target: NavigationDestinationTarget,
        groupID: Int,
        line: Int? = nil,
        column: Int? = nil,
        utf16Offset: Int? = nil,
        selectionUTF16Length: Int? = nil
    ) {
        self.target = target
        self.groupID = groupID
        self.line = line
        self.column = column
        self.utf16Offset = utf16Offset.map { max(0, $0) }
        self.selectionUTF16Length = selectionUTF16Length.map { max(0, $0) }
    }
}

struct NavigationSelectionRequest: Equatable, Sendable {
    let snapshot: NavigationAppSnapshot
    let documentID: String
    let destination: NavigationDestination
    let generation: UInt64

    var groupID: Int { destination.groupID }
    var paneID: Int { groupID }
    var line: Int? { destination.line }
    var column: Int? { destination.column }
    var utf16Offset: Int? { destination.utf16Offset }
    var selectionUTF16Length: Int? { destination.selectionUTF16Length }
}

struct NavigationOpenRequest: Equatable, Sendable {
    let snapshot: NavigationAppSnapshot
    let url: URL
    let destination: NavigationDestination
    let generation: UInt64

    var groupID: Int { destination.groupID }
    var paneID: Int { groupID }
    var line: Int? { destination.line }
    var column: Int? { destination.column }
    var utf16Offset: Int? { destination.utf16Offset }
    var selectionUTF16Length: Int? { destination.selectionUTF16Length }
}

struct NavigationPaletteItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case line
        case symbol
        case projectSymbol
    }

    let id: String
    let kind: Kind
    let label: String
    let detail: String?
    /// Exact text against which `fuzzyMatch.matches` is indexed.
    let searchText: String
    let fuzzyMatch: NavigationFuzzyMatch
    let destination: NavigationDestination

    var matches: [Int] { fuzzyMatch.matches }
    var matchedUTF16Offsets: [Int] { fuzzyMatch.matches }
    var score: Double { fuzzyMatch.score }
}

struct NavigationPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case locationUnavailable
        case navigationFailed
        case couldNotListWorkspaceFiles
        case couldNotLoadProjectSymbols
        case noNavigationLocation
        case staleNavigation
    }

    enum Message: Equatable, Sendable {
        case selectedLocationCouldNotOpen
        case noEarlierLocation
        case noLaterLocation
        case locationHasNoOpenDocumentOrURL
        case historyLocationCouldNotBeRestored
        case historyChangedBeforeJumpCompleted
        case workspace(WorkspaceServiceError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    init(id: UUID = UUID(), title: Title, content: Message) {
        self.id = id
        titleContent = title
        self.content = content
    }

    init(id: UUID = UUID(), title: Title, error: any Error) {
        self.id = id
        titleContent = title
        if let error = error as? WorkspaceServiceError {
            content = .workspace(error)
        } else {
            content = .verbatim((error as NSError).localizedDescription)
        }
    }

    var title: String { EditorLocale.enUS.localizedNavigationIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedNavigationIssue(content) }
}

enum NavigationExactSymbolOutcome: Equatable, Sendable {
    case notFound
    case navigated
    case presented(matchCount: Int)
}

/// Exact workspace policy under which asynchronous file and project-symbol
/// results were produced. Both halves are synchronously re-read at acceptance
/// time because either publisher may still be queued on the main actor.
private struct NavigationAsyncResultContext: Equatable, Sendable {
    let roots: WorkspaceRootSnapshot
    let projectExclusionGeneration: UInt64
}

/// Main-actor navigation coordinator. The application supplies value snapshots
/// and narrow callbacks; the controller has no dependency on AppModel.
@MainActor
final class NavigationController: ObservableObject {
    typealias SnapshotProvider = @MainActor () -> NavigationAppSnapshot
    /// Monotonically identifies the workspace filtering context used by
    /// asynchronous palette providers. The production value is the project
    /// exclusion generation; tests and alternate shells may supply their own.
    typealias ContextGenerationProvider = @MainActor () -> UInt64
    typealias WorkspaceRootSnapshotProvider = @MainActor () -> WorkspaceRootSnapshot
    typealias WorkspaceFilesProvider = @MainActor (NavigationAppSnapshot) async throws -> [NavigationFileSnapshot]
    typealias ProjectSymbolsProvider = @MainActor (NavigationAppSnapshot) async throws -> [NavigationProjectSymbolSnapshot]
    typealias ExactProjectSymbolsProvider = @MainActor (
        NavigationAppSnapshot, String
    ) async throws -> [NavigationProjectSymbolSnapshot]
    typealias SelectDestination = @MainActor (NavigationSelectionRequest) async throws -> NavigationLocation?
    typealias OpenURL = @MainActor (NavigationOpenRequest) async throws -> NavigationLocation?

    /// Commands owned by this coordinator. Matching-bracket remains an editor
    /// operation because only the editor can validate bracket syntax/movement.
    static let commandIDs = [
        "goto-anything",
        "goto-symbol",
        "goto-project-symbol",
        "go-to-line",
        "navigate-back",
        "navigate-forward"
    ]
    static let matchingBracketCommandID = "goto-matching-bracket"
    static let catalogNavigationCommandIDs = commandIDs + [matchingBracketCommandID]

    @Published private(set) var mode: NavigationPaletteMode = .anything
    @Published private(set) var effectiveMode: NavigationPaletteMode = .anything
    @Published var query: String = "" {
        didSet {
            if query != oldValue { reloadItems() }
        }
    }
    @Published private(set) var items: [NavigationPaletteItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var issue: NavigationPresentationIssue?
    @Published private(set) var isPresented = false
    @Published private(set) var canGoBack: Bool
    @Published private(set) var canGoForward: Bool
    @Published private(set) var historyRevision: UInt64 = 0

    let history: NavigationHistory

    private let snapshotProvider: SnapshotProvider
    private let contextGenerationProvider: ContextGenerationProvider
    private let workspaceRootSnapshotProvider: WorkspaceRootSnapshotProvider
    private let workspaceFilesProvider: WorkspaceFilesProvider
    private let projectSymbolsProvider: ProjectSymbolsProvider
    private let exactProjectSymbolsProvider: ExactProjectSymbolsProvider
    private let selectDestination: SelectDestination
    private let openURL: OpenURL
    private let maximumResults: Int
    private let maximumProjectSymbolResults: Int
    private let intentEpoch = NavigationIntentEpoch()

    private var resultGeneration: UInt64 = 0
    private var resultTask: Task<Void, Never>?
    private var resultContext: NavigationAsyncResultContext?
    private var contextGenerationSubscription: AnyCancellable?
    private var workspaceRootSubscription: AnyCancellable?
    private var exactProjectSymbolGeneration: UInt64 = 0
    private var exactProjectSymbolTask: Task<
        [NavigationProjectSymbolSnapshot], any Error
    >?
    private var exactProjectSymbolContext: NavigationAsyncResultContext?
    private var navigationGeneration: UInt64 = 0
    private var traversalSerial: UInt64 = 0
    private var traversalTail: Task<Bool, Never>?

    init(
        history: NavigationHistory = NavigationHistory(),
        maximumResults: Int = 200,
        maximumProjectSymbolResults: Int = 200,
        workspaceRootSnapshot: @escaping WorkspaceRootSnapshotProvider = { .empty },
        workspaceRootChanges: AnyPublisher<WorkspaceRootSnapshot, Never>? = nil,
        contextGeneration: @escaping ContextGenerationProvider = { 0 },
        contextGenerationChanges: AnyPublisher<UInt64, Never>? = nil,
        snapshot: @escaping SnapshotProvider,
        workspaceFiles: @escaping WorkspaceFilesProvider = { _ in [] },
        projectSymbols: @escaping ProjectSymbolsProvider = { _ in [] },
        exactProjectSymbols: ExactProjectSymbolsProvider? = nil,
        selectDestination: @escaping SelectDestination,
        openURL: @escaping OpenURL
    ) {
        self.history = history
        self.maximumResults = max(1, maximumResults)
        self.maximumProjectSymbolResults = max(1, maximumProjectSymbolResults)
        workspaceRootSnapshotProvider = workspaceRootSnapshot
        contextGenerationProvider = contextGeneration
        snapshotProvider = snapshot
        workspaceFilesProvider = workspaceFiles
        projectSymbolsProvider = projectSymbols
        exactProjectSymbolsProvider = exactProjectSymbols ?? { snapshot, label in
            try await projectSymbols(snapshot).filter { $0.label == label }
        }
        self.selectDestination = selectDestination
        self.openURL = openURL
        canGoBack = history.canGoBack
        canGoForward = history.canGoForward
        contextGenerationSubscription = contextGenerationChanges?
            .removeDuplicates()
            .sink { [weak self] generation in
                // Production publishes from a main-actor workspace, but keep
                // the injected publisher safe for arbitrary schedulers.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.contextGenerationDidChange(to: generation)
                }
            }
        workspaceRootSubscription = workspaceRootChanges?
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.asyncResultContextDidChange()
                }
            }
    }

    var selectedItem: NavigationPaletteItem? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var backEntries: [NavigationLocation] { history.backEntries }
    var forwardEntries: [NavigationLocation] { history.forwardEntries }

    func present(_ mode: NavigationPaletteMode, query initialQuery: String = "") {
        invalidateNavigationIntents()
        self.mode = mode
        isPresented = true
        issue = nil
        if query == initialQuery {
            reloadItems()
        } else {
            query = initialQuery
        }
    }

    func dismiss() {
        invalidateNavigationIntents()
        invalidateResults(clearItems: true)
        isPresented = false
    }

    func dismissIssue() {
        issue = nil
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? 0
        let next = ((current + delta) % items.count + items.count) % items.count
        selectedIndex = next
    }

    func moveSelection(_ delta: Int) {
        moveSelection(by: delta)
    }

    @discardableResult
    func acceptSelection() async -> Bool {
        guard let item = selectedItem else { return false }
        guard validateContextForAccepting(item) else { return false }
        let destination = item.destination
        dismiss()
        return await navigate(to: destination)
    }

    @discardableResult
    func acceptItem(at index: Int) async -> Bool {
        guard items.indices.contains(index) else { return false }
        selectedIndex = index
        return await acceptSelection()
    }

    /// Await only the provider request that is current at the time of this
    /// call. Useful to deterministic shells and tests; local modes return now.
    func waitForPendingResults() async {
        await resultTask?.value
    }

    /// Resolves an exact-label project definition without applying the fuzzy
    /// palette's pre-filter result cap. A single match navigates immediately;
    /// ambiguity is retained as an exact project-symbol palette for the user.
    /// Returning `.notFound` after the filtering context changes is deliberate:
    /// the provider's frozen-policy answer is no longer eligible to navigate.
    func openExactProjectSymbol(
        named label: String
    ) async throws -> NavigationExactSymbolOutcome {
        guard !label.isEmpty else { return .notFound }
        let snapshot = snapshotProvider()
        let context = currentAsyncResultContext()
        exactProjectSymbolTask?.cancel()
        exactProjectSymbolGeneration &+= 1
        let generation = exactProjectSymbolGeneration
        exactProjectSymbolContext = context
        let provider = exactProjectSymbolsProvider
        let task = Task { @MainActor in
            try await provider(snapshot, label)
        }
        exactProjectSymbolTask = task

        let supplied: [NavigationProjectSymbolSnapshot]
        do {
            supplied = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            let isSuperseded = generation != exactProjectSymbolGeneration
            let isStaleContext = context != currentAsyncResultContext()
            if isStaleContext { rejectStaleContextResults() }
            clearExactProjectSymbolTask(ifCurrent: generation)
            if isSuperseded || isStaleContext || error is CancellationError {
                return .notFound
            }
            throw error
        }
        guard generation == exactProjectSymbolGeneration,
              context == currentAsyncResultContext() else {
            if context != currentAsyncResultContext() {
                rejectStaleContextResults()
            }
            clearExactProjectSymbolTask(ifCurrent: generation)
            return .notFound
        }
        clearExactProjectSymbolTask(ifCurrent: generation)
        let symbols = Array(
            supplied.lazy
                .filter { $0.label == label }
                .prefix(maximumProjectSymbolResults)
        )
        guard !symbols.isEmpty else { return .notFound }
        if symbols.count == 1, let symbol = symbols.first {
            let didNavigate = await navigate(to: projectSymbolDestination(
                symbol, groupID: snapshot.activeGroupID
            ))
            return didNavigate ? .navigated : .notFound
        }

        presentExactProjectSymbols(
            symbols, named: label, groupID: snapshot.activeGroupID,
            context: context
        )
        return .presented(matchCount: symbols.count)
    }

    @discardableResult
    func navigate(to destination: NavigationDestination) async -> Bool {
        let snapshot = snapshotProvider()
        let source = snapshot.currentLocation
        let generation = beginOrdinaryNavigationIntent()
        issue = nil

        do {
            let actual = try await resolve(
                destination, snapshot: snapshot, generation: generation
            )
            guard generation == navigationGeneration else { return false }
            guard let actual, arrival(
                actual, satisfies: destination, snapshot: snapshotProvider()
            ) else {
                issue = NavigationPresentationIssue(
                    title: .locationUnavailable,
                    content: .selectedLocationCouldNotOpen
                )
                return false
            }
            let latest = snapshotProvider()
            let reachableSource = source.flatMap { location in
                latest.document(id: location.documentID) == nil ? nil : location
            }
            history.recordSuccessfulJump(source: reachableSource, target: actual)
            synchronizeHistoryState()
            return true
        } catch {
            guard generation == navigationGeneration else { return false }
            issue = NavigationPresentationIssue(
                title: .navigationFailed,
                content: Self.presentationMessage(for: error)
            )
            return false
        }
    }

    @discardableResult
    func goToFile(
        _ url: URL,
        line: Int? = nil,
        column: Int? = nil,
        groupID: Int? = nil,
        utf16Offset: Int? = nil,
        selectionUTF16Length: Int? = nil
    ) async -> Bool {
        let snapshot = snapshotProvider()
        let destination = NavigationDestination(
            target: .url(url),
            groupID: groupID ?? snapshot.activeGroupID,
            line: line,
            column: line == nil ? nil : (column ?? 1),
            utf16Offset: utf16Offset,
            selectionUTF16Length: selectionUTF16Length
        )
        return await navigate(to: destination)
    }

    @discardableResult
    func goToLine(_ input: String) async -> Bool {
        let snapshot = snapshotProvider()
        guard let pane = snapshot.activePane,
              let documentID = pane.activeDocumentID,
              let document = snapshot.document(id: documentID),
              let current = snapshot.currentLocation,
              let location = GotoLineResolver.resolve(
                input, currentLine: current.line, totalLines: document.totalLines
              ) else { return false }
        return await navigate(to: NavigationDestination(
            target: .document(id: documentID),
            groupID: pane.groupID,
            line: location.line,
            column: location.column
        ))
    }

    @discardableResult
    func goBack() async -> Bool {
        await enqueueTraversal(.back)
    }

    @discardableResult
    func goForward() async -> Bool {
        await enqueueTraversal(.forward)
    }

    /// Invalidates in-flight and queued navigation without changing history.
    /// A shell can use this when an unrelated user selection becomes the new
    /// navigation intent.
    func invalidateNavigationIntents() {
        _ = intentEpoch.begin()
        navigationGeneration &+= 1
    }

    // MARK: - Document and workspace lifecycle

    /// Lets editor-owned synchronous navigation (for example outline or
    /// matching-bracket selection) join the same history after it succeeds.
    func recordSuccessfulJump(
        source: NavigationLocation?,
        target: NavigationLocation?
    ) {
        history.recordSuccessfulJump(source: source, target: target)
        synchronizeHistoryState()
    }

    func documentDidSave(documentID: String, url: URL) {
        updateDocumentPath(documentID: documentID, url: url)
    }

    /// Saved documents stay recoverable by URL after closing; untitled
    /// documents have no fallback and must be removed.
    func documentDidClose(documentID: String, url: URL?) {
        if url == nil { removeDocumentFromHistory(documentID: documentID) }
    }

    func pathDidMove(from source: URL, to target: URL) {
        history.rewritePathPrefix(
            source: NavigationAppSnapshot.normalizedPath(source),
            target: NavigationAppSnapshot.normalizedPath(target)
        )
        synchronizeHistoryState()
    }

    func pathDidDelete(_ url: URL) {
        history.removePathPrefix(NavigationAppSnapshot.normalizedPath(url))
        synchronizeHistoryState()
    }

    func updateDocumentPath(documentID: String, url: URL?) {
        history.updateDocumentPath(
            documentID: documentID,
            path: url.map(NavigationAppSnapshot.normalizedPath)
        )
        synchronizeHistoryState()
    }

    func updateDocumentPath(documentID: String, path: String?) {
        history.updateDocumentPath(documentID: documentID, path: path)
        synchronizeHistoryState()
    }

    func rewritePathPrefix(from source: URL, to target: URL) {
        pathDidMove(from: source, to: target)
    }

    func rewritePathPrefix(source: String, target: String) {
        history.rewritePathPrefix(source: source, target: target)
        synchronizeHistoryState()
    }

    func removeDocumentFromHistory(documentID: String) {
        history.removeDocument(documentID: documentID)
        synchronizeHistoryState()
    }

    func removePathFromHistory(_ url: URL) {
        pathDidDelete(url)
    }

    func removePathPrefix(_ path: String) {
        history.removePathPrefix(path)
        synchronizeHistoryState()
    }

    /// Register the six catalog routes owned by NavigationController. The
    /// returned ownership tokens let the app unregister or replace them later.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        presentPalette: @escaping @MainActor () -> Void = {}
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register(
                "goto-anything", replaceExisting: replaceExisting,
                enablement: { [weak self] context in
                    guard let self else { return .disabled(reason: "Navigation unavailable") }
                    return context.availableRequirements.contains(.document)
                        || !self.snapshotProvider().workspaceRoots.isEmpty
                        ? .enabled
                        : .disabled(reason: "No document or workspace")
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                self.present(.anything)
                presentPalette()
            })
            tokens.append(try router.register(
                "goto-symbol", replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Navigation unavailable")
                    }
                    return self.snapshotProvider().activeDocument == nil
                        ? .disabled(reason: "No active document") : .enabled
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                self.present(.symbol)
                presentPalette()
            })
            tokens.append(try router.register(
                "goto-project-symbol", replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Navigation unavailable")
                    }
                    return self.snapshotProvider().workspaceRoots.isEmpty
                        ? .disabled(reason: "No workspace") : .enabled
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                self.present(.projectSymbol)
                presentPalette()
            })
            tokens.append(try router.register(
                "go-to-line", replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Navigation unavailable")
                    }
                    return self.snapshotProvider().activeDocument == nil
                        ? .disabled(reason: "No active document") : .enabled
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                self.present(.line)
                presentPalette()
            })
            tokens.append(try router.register(
                "navigate-back",
                replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Navigation unavailable")
                    }
                    return self.canGoBack ? .enabled
                        : .disabled(reason: "No back navigation location")
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                guard await self.goBack() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "navigate-forward",
                replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Navigation unavailable")
                    }
                    return self.canGoForward ? .enabled
                        : .disabled(reason: "No forward navigation location")
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Navigation unavailable")
                }
                await prepareForCommand()
                guard await self.goForward() else { throw CommandHandlerSignal.noChange }
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    // MARK: - Palette results

    private func reloadItems() {
        guard isPresented else { return }
        invalidateResults(clearItems: true)
        issue = nil
        let generation = resultGeneration
        let context = currentAsyncResultContext()
        let resolved = resolvedModeAndQuery()
        effectiveMode = resolved.mode
        let snapshot = snapshotProvider()

        switch resolved.mode {
        case .anything, .file:
            loadFiles(
                query: resolved.query, snapshot: snapshot, generation: generation,
                context: context
            )
        case .symbol:
            setItems(symbolItems(query: resolved.query, snapshot: snapshot), generation: generation)
        case .projectSymbol:
            loadProjectSymbols(
                query: resolved.query, snapshot: snapshot, generation: generation,
                context: context,
                limit: mode == .projectSymbol
                    ? maximumProjectSymbolResults
                    : maximumResults
            )
        case .line:
            setItems(lineItems(query: resolved.query, snapshot: snapshot), generation: generation)
        }
    }

    private func resolvedModeAndQuery() -> (mode: NavigationPaletteMode, query: String) {
        switch mode {
        case .anything:
            guard let first = query.first else { return (.file, query) }
            switch first {
            case ":": return (.line, String(query.dropFirst()))
            case "@": return (.symbol, String(query.dropFirst()))
            case "#": return (.projectSymbol, String(query.dropFirst()))
            default: return (.file, query)
            }
        case .symbol:
            return (.symbol, query.first == "@" ? String(query.dropFirst()) : query)
        case .projectSymbol:
            return (.projectSymbol, query.first == "#" ? String(query.dropFirst()) : query)
        case .line:
            return (.line, query.first == ":" ? String(query.dropFirst()) : query)
        case .file:
            return (.file, query)
        }
    }

    private func loadFiles(
        query: String,
        snapshot: NavigationAppSnapshot,
        generation: UInt64,
        context: NavigationAsyncResultContext
    ) {
        isBusy = true
        resultContext = context
        let provider = workspaceFilesProvider
        resultTask = Task { @MainActor [weak self] in
            do {
                let files = try await provider(snapshot)
                guard let self, self.isCurrentResult(
                    generation, context: context
                ) else {
                    return
                }
                self.resultContext = context
                self.setItems(
                    self.fileItems(query: query, files: files, groupID: snapshot.activeGroupID),
                    generation: generation
                )
            } catch {
                guard let self, self.isCurrentResult(
                    generation, context: context
                ) else {
                    return
                }
                self.items = []
                self.selectedIndex = nil
                self.isBusy = false
                self.resultTask = nil
                self.resultContext = nil
                self.issue = NavigationPresentationIssue(
                    title: .couldNotListWorkspaceFiles,
                    content: Self.presentationMessage(for: error)
                )
            }
        }
    }

    private func loadProjectSymbols(
        query: String,
        snapshot: NavigationAppSnapshot,
        generation: UInt64,
        context: NavigationAsyncResultContext,
        limit: Int
    ) {
        isBusy = true
        resultContext = context
        let provider = projectSymbolsProvider
        resultTask = Task { @MainActor [weak self] in
            do {
                let symbols = try await provider(snapshot)
                guard let self, self.isCurrentResult(
                    generation, context: context
                ) else {
                    return
                }
                self.resultContext = context
                self.setItems(
                    self.projectSymbolItems(
                        query: query, symbols: symbols, groupID: snapshot.activeGroupID,
                        limit: limit
                    ),
                    generation: generation
                )
            } catch {
                guard let self, self.isCurrentResult(
                    generation, context: context
                ) else {
                    return
                }
                self.items = []
                self.selectedIndex = nil
                self.isBusy = false
                self.resultTask = nil
                self.resultContext = nil
                self.issue = NavigationPresentationIssue(
                    title: .couldNotLoadProjectSymbols,
                    content: Self.presentationMessage(for: error)
                )
            }
        }
    }

    private struct FileQuery {
        let fuzzy: String
        let line: Int?
        let column: Int?
    }

    private func fileItems(
        query: String,
        files: [NavigationFileSnapshot],
        groupID: Int
    ) -> [NavigationPaletteItem] {
        let parsed = Self.parseFileQuery(query)
        let ranked = NavigationFuzzyMatcher.filter(
            query: parsed.fuzzy, items: files, key: { $0.displayPath }
        )
        return ranked.prefix(maximumResults).enumerated().map { index, ranked in
            let file = ranked.item
            let locationSuffix = parsed.line.map { line in
                ":\(line)" + (parsed.column.map { ":\($0)" } ?? "")
            } ?? ""
            return NavigationPaletteItem(
                id: "file:\(file.id):\(parsed.line ?? 0):\(parsed.column ?? 0):\(index)",
                kind: .file,
                label: file.url.lastPathComponent,
                detail: file.displayPath + locationSuffix,
                searchText: file.displayPath,
                fuzzyMatch: ranked.result,
                destination: NavigationDestination(
                    target: .url(file.url),
                    groupID: groupID,
                    line: parsed.line,
                    column: parsed.line == nil ? nil : (parsed.column ?? 1)
                )
            )
        }
    }

    private func symbolItems(
        query: String,
        snapshot: NavigationAppSnapshot
    ) -> [NavigationPaletteItem] {
        guard let pane = snapshot.activePane,
              let documentID = pane.activeDocumentID,
              let document = snapshot.document(id: documentID) else { return [] }
        let ranked = NavigationFuzzyMatcher.filter(
            query: query,
            items: SymbolExtractor.extract(from: document.text),
            key: { $0.label }
        )
        return ranked.prefix(maximumResults).enumerated().map { index, ranked in
            let symbol = ranked.item
            return NavigationPaletteItem(
                id: "symbol:\(documentID):\(symbol.position):\(index)",
                kind: .symbol,
                label: symbol.label,
                detail: "Ln \(symbol.line)",
                searchText: symbol.label,
                fuzzyMatch: ranked.result,
                destination: NavigationDestination(
                    target: .document(id: documentID),
                    groupID: pane.groupID,
                    line: symbol.line,
                    column: 1,
                    utf16Offset: symbol.position
                )
            )
        }
    }

    private func projectSymbolItems(
        query: String,
        symbols: [NavigationProjectSymbolSnapshot],
        groupID: Int,
        limit: Int
    ) -> [NavigationPaletteItem] {
        let ranked = NavigationFuzzyMatcher.filter(
            query: query, items: symbols, key: { "\($0.label) \($0.displayPath)" }
        )
        return ranked.prefix(limit).enumerated().map { index, ranked in
            let symbol = ranked.item
            let searchText = "\(symbol.label) \(symbol.displayPath)"
            return NavigationPaletteItem(
                id: "project-symbol:\(symbol.id):\(index)",
                kind: .projectSymbol,
                label: symbol.label,
                detail: "\(symbol.displayPath):\(symbol.line):\(symbol.column)",
                searchText: searchText,
                fuzzyMatch: ranked.result,
                destination: projectSymbolDestination(symbol, groupID: groupID)
            )
        }
    }

    private func presentExactProjectSymbols(
        _ symbols: [NavigationProjectSymbolSnapshot], named label: String,
        groupID: Int,
        context: NavigationAsyncResultContext
    ) {
        invalidateNavigationIntents()
        invalidateResults(clearItems: true)
        mode = .projectSymbol
        effectiveMode = .projectSymbol
        issue = nil
        isPresented = false
        query = label
        isPresented = true
        resultContext = context
        setItems(
            projectSymbolItems(
                query: label, symbols: symbols,
                groupID: groupID,
                limit: maximumProjectSymbolResults
            ),
            generation: resultGeneration
        )
    }

    private func projectSymbolDestination(
        _ symbol: NavigationProjectSymbolSnapshot, groupID: Int
    ) -> NavigationDestination {
        NavigationDestination(
            target: .url(symbol.url), groupID: groupID,
            line: symbol.line, column: symbol.column,
            utf16Offset: symbol.utf16Offset
        )
    }

    private func lineItems(
        query: String,
        snapshot: NavigationAppSnapshot
    ) -> [NavigationPaletteItem] {
        guard let pane = snapshot.activePane,
              let documentID = pane.activeDocumentID,
              let document = snapshot.document(id: documentID),
              let current = snapshot.currentLocation,
              let location = GotoLineResolver.resolve(
                query, currentLine: current.line, totalLines: document.totalLines
              ) else { return [] }
        let label = "Go to \(location.line):\(location.column)"
        return [NavigationPaletteItem(
            id: "line:\(documentID):\(pane.groupID):\(location.line):\(location.column)",
            kind: .line,
            label: label,
            detail: document.displayName,
            searchText: label,
            fuzzyMatch: NavigationFuzzyMatch(score: 1, matches: []),
            destination: NavigationDestination(
                target: .document(id: documentID),
                groupID: pane.groupID,
                line: location.line,
                column: location.column
            )
        )]
    }

    private static func parseFileQuery(_ query: String) -> FileQuery {
        let pattern = #"^(.*):(\d+)(?::(\d+))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return FileQuery(fuzzy: query, line: nil, column: nil)
        }
        let source = query as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = expression.firstMatch(in: query, range: range),
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound else {
            return FileQuery(fuzzy: query, line: nil, column: nil)
        }
        let fuzzy = source.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fuzzy.isEmpty,
              let line = Int(source.substring(with: match.range(at: 2))),
              line >= 1 else {
            return FileQuery(fuzzy: query, line: nil, column: nil)
        }
        var column: Int?
        if match.range(at: 3).location != NSNotFound {
            guard let parsed = Int(source.substring(with: match.range(at: 3))), parsed >= 1 else {
                return FileQuery(fuzzy: query, line: nil, column: nil)
            }
            column = parsed
        }
        return FileQuery(fuzzy: fuzzy, line: line, column: column)
    }

    private func setItems(_ items: [NavigationPaletteItem], generation: UInt64) {
        guard generation == resultGeneration, isPresented else { return }
        self.items = items
        selectedIndex = items.isEmpty ? nil : 0
        isBusy = false
        resultTask = nil
    }

    private func invalidateResults(clearItems: Bool) {
        resultGeneration &+= 1
        resultTask?.cancel()
        resultTask = nil
        resultContext = nil
        isBusy = false
        if clearItems {
            items = []
            selectedIndex = nil
        }
    }

    private func isCurrentResult(
        _ generation: UInt64, context: NavigationAsyncResultContext
    ) -> Bool {
        guard generation == resultGeneration, isPresented else { return false }
        guard context == currentAsyncResultContext() else {
            rejectStaleContextResults()
            return false
        }
        return true
    }

    private func validateContextForAccepting(
        _ item: NavigationPaletteItem
    ) -> Bool {
        guard item.kind == .file || item.kind == .projectSymbol else {
            return true
        }
        guard let resultContext,
              resultContext == currentAsyncResultContext() else {
            rejectStaleContextResults()
            return false
        }
        return true
    }

    private func contextGenerationDidChange(to _: UInt64) {
        asyncResultContextDidChange()
    }

    private func currentAsyncResultContext() -> NavigationAsyncResultContext {
        NavigationAsyncResultContext(
            roots: workspaceRootSnapshotProvider(),
            projectExclusionGeneration: contextGenerationProvider()
        )
    }

    private func asyncResultContextDidChange() {
        // Publisher delivery may hop executors, so an older notification can
        // arrive after a newer context has already produced valid results.
        // Treat the notification only as a wake-up and compare retained work
        // against the synchronous source of truth.
        let currentContext = currentAsyncResultContext()
        let exactContextIsStale = exactProjectSymbolContext.map {
            $0 != currentContext
        } ?? false
        if exactContextIsStale {
            exactProjectSymbolGeneration &+= 1
            exactProjectSymbolTask?.cancel()
            exactProjectSymbolTask = nil
            self.exactProjectSymbolContext = nil
        }
        guard let resultContext else { return }
        let resultContextIsStale = resultContext != currentContext
        guard resultContextIsStale else { return }
        rejectStaleContextResults()
    }

    private func clearExactProjectSymbolTask(ifCurrent generation: UInt64) {
        guard generation == exactProjectSymbolGeneration else { return }
        exactProjectSymbolTask = nil
        exactProjectSymbolContext = nil
    }

    private func rejectStaleContextResults() {
        let closesAsynchronousPalette = effectiveMode == .file
            || effectiveMode == .projectSymbol
        invalidateResults(clearItems: true)
        issue = nil
        if closesAsynchronousPalette { isPresented = false }
    }

    // MARK: - Navigation execution and history

    private func beginOrdinaryNavigationIntent() -> UInt64 {
        _ = intentEpoch.begin()
        navigationGeneration &+= 1
        return navigationGeneration
    }

    private func resolve(
        _ destination: NavigationDestination,
        snapshot: NavigationAppSnapshot,
        generation: UInt64
    ) async throws -> NavigationLocation? {
        switch destination.target {
        case let .document(id):
            return try await selectDestination(NavigationSelectionRequest(
                snapshot: snapshot, documentID: id,
                destination: destination, generation: generation
            ))
        case let .url(url):
            if let document = snapshot.document(url: url) {
                return try await selectDestination(NavigationSelectionRequest(
                    snapshot: snapshot, documentID: document.documentID,
                    destination: destination, generation: generation
                ))
            }
            return try await openURL(NavigationOpenRequest(
                snapshot: snapshot, url: url,
                destination: destination, generation: generation
            ))
        }
    }

    private func arrival(
        _ actual: NavigationLocation,
        satisfies destination: NavigationDestination,
        snapshot: NavigationAppSnapshot
    ) -> Bool {
        guard actual.groupID == destination.groupID else { return false }
        switch destination.target {
        case let .document(id):
            guard actual.documentID == id,
                  let document = snapshot.document(id: id) else { return false }
            let expected: (line: Int, column: Int)?
            if let offset = destination.utf16Offset {
                let target = offset.addingReportingOverflow(
                    destination.selectionUTF16Length ?? 0
                )
                expected = document.lineColumn(
                    atUTF16Offset: target.overflow ? Int.max : target.partialValue
                )
            } else if let line = destination.line {
                expected = document.clampedLineColumn(
                    line: line, column: destination.column ?? 1
                )
            } else {
                expected = nil
            }
            guard let expected else { return true }
            return actual.line == expected.line && actual.column == expected.column
        case let .url(url):
            if let openDocument = snapshot.document(url: url) {
                guard actual.documentID == openDocument.documentID else { return false }
                let expected: (line: Int, column: Int)?
                if let offset = destination.utf16Offset {
                    let target = offset.addingReportingOverflow(
                        destination.selectionUTF16Length ?? 0
                    )
                    expected = openDocument.lineColumn(
                        atUTF16Offset: target.overflow ? Int.max : target.partialValue
                    )
                } else if let line = destination.line {
                    expected = openDocument.clampedLineColumn(
                        line: line, column: destination.column ?? 1
                    )
                } else {
                    expected = nil
                }
                guard let expected else { return true }
                return actual.line == expected.line && actual.column == expected.column
            }
            // A trusted open callback may not have published its document into
            // the shell snapshot yet. Require path identity and, without text
            // for clamping, the exact requested positive line/column.
            guard actual.path == NavigationAppSnapshot.normalizedPath(url) else { return false }
            if let line = destination.line, actual.line != max(1, line) { return false }
            if let column = destination.column, actual.column != max(1, column) { return false }
            return true
        }
    }

    private func enqueueTraversal(_ direction: NavigationDirection) async -> Bool {
        let expectedIntent = intentEpoch.current
        let previous = traversalTail
        traversalSerial &+= 1
        let serial = traversalSerial
        let operation = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performTraversal(direction, expectedIntent: expectedIntent)
        }
        traversalTail = operation
        let result = await operation.value
        if traversalSerial == serial { traversalTail = nil }
        return result
    }

    private func performTraversal(
        _ direction: NavigationDirection,
        expectedIntent: Int
    ) async -> Bool {
        guard intentEpoch.isCurrent(expectedIntent) else { return false }
        guard let traversal = history.prepareTraversal(direction) else {
            issue = NavigationPresentationIssue(
                title: .noNavigationLocation,
                content: direction == .back ? .noEarlierLocation : .noLaterLocation
            )
            return false
        }

        let snapshot = snapshotProvider()
        let current = snapshot.currentLocation
        let destination: NavigationDestination
        if snapshot.document(id: traversal.target.documentID) != nil {
            destination = NavigationDestination(
                target: .document(id: traversal.target.documentID),
                groupID: traversal.target.groupID,
                line: traversal.target.line,
                column: traversal.target.column
            )
        } else if let path = traversal.target.path {
            destination = NavigationDestination(
                target: .url(URL(fileURLWithPath: path)),
                groupID: traversal.target.groupID,
                line: traversal.target.line,
                column: traversal.target.column
            )
        } else {
            issue = NavigationPresentationIssue(
                title: .locationUnavailable,
                content: .locationHasNoOpenDocumentOrURL
            )
            return false
        }

        navigationGeneration &+= 1
        let generation = navigationGeneration
        issue = nil
        do {
            let actual = try await resolve(
                destination, snapshot: snapshot, generation: generation
            )
            guard generation == navigationGeneration,
                  intentEpoch.isCurrent(expectedIntent) else { return false }
            guard let actual, arrival(
                actual, satisfies: destination, snapshot: snapshotProvider()
            ) else {
                issue = NavigationPresentationIssue(
                    title: .locationUnavailable,
                    content: .historyLocationCouldNotBeRestored
                )
                return false
            }

            let latest = snapshotProvider()
            let returnLocation = current.flatMap { location in
                latest.document(id: location.documentID) == nil ? nil : location
            }
            guard history.commitTraversal(traversal, current: returnLocation) else {
                issue = NavigationPresentationIssue(
                    title: .staleNavigation,
                    content: .historyChangedBeforeJumpCompleted
                )
                synchronizeHistoryState()
                return false
            }
            synchronizeHistoryState()
            return true
        } catch {
            guard generation == navigationGeneration,
                  intentEpoch.isCurrent(expectedIntent) else { return false }
            issue = NavigationPresentationIssue(
                title: .navigationFailed,
                content: Self.presentationMessage(for: error)
            )
            return false
        }
    }

    private func synchronizeHistoryState() {
        canGoBack = history.canGoBack
        canGoForward = history.canGoForward
        historyRevision &+= 1
    }

    private static func presentationMessage(
        for error: any Error
    ) -> NavigationPresentationIssue.Message {
        if let error = error as? WorkspaceServiceError { return .workspace(error) }
        return .verbatim((error as NSError).localizedDescription)
    }
}
