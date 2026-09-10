import Combine
import Foundation
import LumenEditorCore

enum FindBarMode: String, CaseIterable, Identifiable, Sendable {
    case find
    case replace

    var id: String { rawValue }
}

/// Immutable editor state captured for one pane. Shell callbacks must reject a
/// request when its document, view, or buffer revision no longer matches.
struct FindDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let paneIndex: Int
    let text: String
    let selectedRange: NSRange
    let bufferRevision: UInt64

    init(
        documentID: String,
        viewID: EditorViewID,
        paneIndex: Int,
        text: String,
        selectedRange: NSRange,
        bufferRevision: UInt64
    ) {
        self.documentID = documentID
        self.viewID = viewID
        self.paneIndex = paneIndex
        self.text = text
        self.selectedRange = Self.clamped(selectedRange, to: text.utf16.count)
        self.bufferRevision = bufferRevision
    }

    var identity: FindPaneIdentity {
        FindPaneIdentity(documentID: documentID, viewID: viewID, paneIndex: paneIndex)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let start = min(length, max(0, range.location))
        let end: Int
        if range.length > Int.max - max(0, range.location) {
            end = length
        } else {
            end = min(length, max(start, max(0, range.location) + max(0, range.length)))
        }
        return NSRange(location: start, length: end - start)
    }
}

struct FindPaneIdentity: Equatable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let paneIndex: Int
}

/// Exact, immutable find decoration state for one native editor surface.
/// Consumers must match all identity fields before drawing so a tab, pane, or
/// revision transition can never retain highlights from the previous buffer.
struct FindHighlightSnapshot: Equatable, Sendable {
    let identity: FindPaneIdentity
    let documentRevision: UInt64
    let matches: [FindMatch]
    let selectedMatchIndex: Int?

    init(
        snapshot: FindDocumentSnapshot,
        matches: [FindMatch],
        selectedMatchIndex: Int?
    ) {
        identity = snapshot.identity
        documentRevision = snapshot.bufferRevision
        self.matches = matches
        self.selectedMatchIndex = selectedMatchIndex.flatMap { index in
            matches.indices.contains(index) ? index : nil
        }
    }
}

struct FindSelectionRequest: Equatable, Sendable {
    let identity: FindPaneIdentity
    let expectedBufferRevision: UInt64
    let selectedRange: NSRange

    init(snapshot: FindDocumentSnapshot, selectedRange: NSRange) {
        identity = snapshot.identity
        expectedBufferRevision = snapshot.bufferRevision
        self.selectedRange = selectedRange
    }
}

/// One atomic edit request. `edits` use original-document UTF-16 coordinates.
/// A nil selection asks the shell to let its transaction engine map the current
/// pane selection, just like CodeMirror does for Replace All.
struct FindEditRequest: Equatable, Sendable {
    let identity: FindPaneIdentity
    let expectedBufferRevision: UInt64
    let edits: [TextEdit]
    let selectionAfter: NSRange?

    init(
        snapshot: FindDocumentSnapshot,
        edits: [TextEdit],
        selectionAfter: NSRange? = nil
    ) {
        identity = snapshot.identity
        expectedBufferRevision = snapshot.bufferRevision
        self.edits = edits
        self.selectionAfter = selectionAfter
    }
}

enum FindBarStatus: Equatable, Sendable {
    case idle
    case searching
    case matches(current: Int?, total: Int, truncated: Bool)
    case noMatches
    case replaced(Int)
    case unavailable
    case invalidQuery(AppPresentationText)
}

/// Main-actor UI/controller for find and replace inside the active pane.
///
/// The controller never reaches into AppModel. A window shell supplies a
/// snapshot and two capability callbacks. That makes pane identity and buffer
/// revision explicit, and lets the shell reject stale selection/edit requests.
@MainActor
final class FindBarController: ObservableObject {
    typealias SnapshotProvider = @MainActor () -> FindDocumentSnapshot?
    typealias SelectMatch = @MainActor (FindSelectionRequest) async -> Bool
    typealias ApplyEdits = @MainActor (FindEditRequest) async -> Bool
    typealias SearchAction = (String, FindQuery, Int) async throws -> FindScanResult
    typealias RecordHistory = @MainActor (_ search: String, _ replacement: String?) -> Void
    typealias HistoryProvider = @MainActor () -> [String]

    static let commandIDs = ["find", "replace", "find-next", "find-previous"]

    @Published var query: String {
        didSet { if query != oldValue { editableInputDidChange() } }
    }
    @Published var replacement: String {
        didSet { if replacement != oldValue { editableInputDidChange() } }
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

    @Published private(set) var mode: FindBarMode
    @Published private(set) var isPresented = false
    @Published private(set) var isSearching = false
    @Published private(set) var matches: [FindMatch] = []
    @Published private(set) var selectedMatchIndex: Int?
    @Published private(set) var highlightSnapshot: FindHighlightSnapshot?
    @Published private(set) var status: FindBarStatus = .idle
    /// Changes after a successful navigation/edit so the shell can restore
    /// editor focus and reveal the active selection after presentation updates.
    @Published private(set) var revealGeneration: UInt64 = 0
    @Published private(set) var dismissalGeneration: UInt64 = 0
    @Published private(set) var focusGeneration: UInt64 = 0
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var replaceHistory: [String] = []

    private let snapshotProvider: SnapshotProvider
    private let selectMatchAction: SelectMatch
    private let applyEditsAction: ApplyEdits
    private let searchAction: SearchAction
    private var recordHistory: RecordHistory = { _, _ in }
    private var searchHistoryProvider: HistoryProvider = { [] }
    private var replaceHistoryProvider: HistoryProvider = { [] }
    private let resultLimit: Int
    private var operationGeneration: UInt64 = 0
    private var inputRevision: UInt64 = 0
    private var searchTask: Task<Void, Never>?

    init(
        mode: FindBarMode = .find,
        query: String = "",
        replacement: String = "",
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        usesRegularExpression: Bool = false,
        resultLimit: Int = FindCore.defaultMaximumResults,
        snapshot: @escaping SnapshotProvider,
        selectMatch: @escaping SelectMatch,
        applyEdits: @escaping ApplyEdits,
        search: @escaping SearchAction = FindBarController.defaultSearch
    ) {
        precondition(resultLimit > 0, "The find result limit must be positive")
        self.mode = mode
        self.query = query
        self.replacement = replacement
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.usesRegularExpression = usesRegularExpression
        self.resultLimit = resultLimit
        snapshotProvider = snapshot
        selectMatchAction = selectMatch
        applyEditsAction = applyEdits
        searchAction = search
    }

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

    var currentQuery: FindQuery {
        FindQuery(
            search: query,
            replacement: replacement,
            options: FindOptions(
                isCaseSensitive: isCaseSensitive,
                isWholeWord: isWholeWord,
                usesRegularExpression: usesRegularExpression
            )
        )
    }

    var canFind: Bool { snapshotProvider() != nil && !query.isEmpty }
    var canReplace: Bool { canFind && mode == .replace }

    /// Returns decorations only for the exact editor currently represented by
    /// this controller. `isPresented` is part of the gate so closing the bar
    /// removes highlights without retaining a hidden search UI state.
    func highlightSnapshot(
        documentID: String,
        viewID: EditorViewID,
        paneIndex: Int,
        documentRevision: UInt64
    ) -> FindHighlightSnapshot? {
        guard isPresented, let highlightSnapshot,
              highlightSnapshot.identity == FindPaneIdentity(
                  documentID: documentID, viewID: viewID, paneIndex: paneIndex
              ),
              highlightSnapshot.documentRevision == documentRevision
        else { return nil }
        return highlightSnapshot
    }

    var statusMessage: String {
        EditorLocale.enUS.localizedFindStatus(
            status, queryIsEmpty: query.isEmpty, purpose: .visible
        )
    }

    func show(mode: FindBarMode) {
        refreshHistory()
        self.mode = mode
        isPresented = true
        focusGeneration &+= 1
        if query.isEmpty, let snapshot = snapshotProvider(), snapshot.selectedRange.length > 0 {
            query = (snapshot.text as NSString).substring(with: snapshot.selectedRange)
        } else {
            refresh()
        }
    }

    func showFind() { show(mode: .find) }
    func showReplace() { show(mode: .replace) }

    /// Opens the UI for a command that has no usable query yet, otherwise runs
    /// the command immediately. This mirrors CodeMirror's search-command gate.
    @discardableResult
    func findNextOrShow() async -> Bool {
        guard !query.isEmpty else { showFind(); return false }
        return await findNext()
    }

    @discardableResult
    func findPreviousOrShow() async -> Bool {
        guard !query.isEmpty else { showFind(); return false }
        return await findPrevious()
    }

    func dismiss() {
        guard isPresented else { return }
        invalidateOperations()
        isPresented = false
        isSearching = false
        clearHighlights()
        // The shell observes this generation to return focus to the active
        // editor after Escape or the close button removes the find bar.
        dismissalGeneration &+= 1
    }

    /// The shell calls this after active tab/pane or document contents change.
    /// It invalidates any in-flight result before taking the new snapshot.
    func documentContextDidChange() {
        invalidateOperations()
        clearHighlights()
        if isPresented { refresh() }
    }

    /// Recomputes result metadata without changing the editor selection.
    func refresh() {
        searchTask?.cancel()
        let generation = nextGeneration()
        let revision = inputRevision
        clearHighlights()
        guard let snapshot = snapshotProvider() else {
            isSearching = false
            status = .unavailable
            return
        }
        guard !query.isEmpty else {
            isSearching = false
            status = .idle
            return
        }

        let findQuery = currentQuery
        let action = searchAction
        let limit = resultLimit
        isSearching = true
        status = .searching
        searchTask = Task { @MainActor [weak self] in
            do {
                let result = try await action(snapshot.text, findQuery, limit)
                guard !Task.isCancelled, let self,
                      self.operationGeneration == generation,
                      self.inputRevision == revision,
                      self.snapshotStillMatches(snapshot) else { return }
                self.publish(
                    result, selection: snapshot.selectedRange, snapshot: snapshot
                )
                self.searchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self,
                      self.operationGeneration == generation,
                      self.inputRevision == revision else { return }
                self.clearHighlights()
                self.isSearching = false
                self.status = .invalidQuery(Self.presentationText(for: error))
                self.searchTask = nil
            }
        }
    }

    @discardableResult
    func findNext() async -> Bool {
        await find(.next)
    }

    @discardableResult
    func findPrevious() async -> Bool {
        await find(.previous)
    }

    @discardableResult
    func replaceNext() async -> Bool {
        guard mode == .replace else { return false }
        searchTask?.cancel()
        let generation = nextGeneration()
        guard let snapshot = snapshotProvider(), !query.isEmpty else {
            status = snapshotProvider() == nil ? .unavailable : .idle
            return false
        }
        let findQuery = currentQuery
        do {
            let scan = try FindCore.scan(
                snapshot.text, query: findQuery, limit: completeLimit(for: snapshot.text)
            )
            guard operationGeneration == generation else { return false }
            let currentIndex = scan.matches.firstIndex {
                $0.range == snapshot.selectedRange
            }
            guard !scan.matches.isEmpty else {
                clearHighlights()
                status = .noMatches
                return false
            }

            if let currentIndex, scan.matches[currentIndex].range.length > 0 {
                let current = scan.matches[currentIndex]
                let replacementText = FindCore.replacementText(
                    for: current, in: snapshot.text, query: findQuery
                )
                let edit = TextEdit(
                    from: current.lowerBound, to: current.upperBound, insert: replacementText
                )
                let nextOriginal = scan.matches.count > 1
                    ? scan.matches[(currentIndex + 1) % scan.matches.count] : nil
                let transaction = try TextTransaction(edits: [edit])
                let selectionAfter: NSRange?
                if let nextOriginal, nextOriginal.lowerBound > current.lowerBound {
                    selectionAfter = mappedRange(nextOriginal.range, through: transaction)
                } else {
                    // A wrapped target precedes this edit and maps unchanged.
                    selectionAfter = nextOriginal?.range
                }
                let succeeded = await applyEditsAction(FindEditRequest(
                    snapshot: snapshot, edits: [edit], selectionAfter: selectionAfter
                ))
                guard operationGeneration == generation, succeeded else { return false }
                clearHighlights()
                recordHistory(findQuery.search, findQuery.replacement)
                revealGeneration &+= 1
                status = .replaced(1)
                refresh()
                return true
            }

            guard let target = nextMatch(
                in: scan.matches, after: snapshot.selectedRange
            ) else {
                clearHighlights()
                status = .noMatches
                return false
            }
            return await select(
                target, in: snapshot, generation: generation, allMatches: scan.matches
            )
        } catch {
            guard operationGeneration == generation else { return false }
            publish(error: error)
            return false
        }
    }

    @discardableResult
    func replaceAll() async -> Bool {
        guard mode == .replace else { return false }
        searchTask?.cancel()
        let generation = nextGeneration()
        guard let snapshot = snapshotProvider(), !query.isEmpty else {
            status = snapshotProvider() == nil ? .unavailable : .idle
            return false
        }
        let findQuery = currentQuery
        do {
            let scan = try FindCore.scan(
                snapshot.text, query: findQuery, limit: completeLimit(for: snapshot.text)
            )
            guard operationGeneration == generation else { return false }
            guard !scan.isTruncated, !scan.matches.isEmpty else {
                clearHighlights()
                status = scan.matches.isEmpty ? .noMatches
                    : .invalidQuery(.app(.findTooManyMatchesToReplaceSafely))
                return false
            }
            guard scan.matches.allSatisfy({ $0.range.length > 0 }) else {
                clearHighlights()
                status = .invalidQuery(
                    .app(.findZeroWidthRegularExpressionCannotBeReplaced)
                )
                return false
            }
            let edits = scan.matches.map { match in
                TextEdit(
                    from: match.lowerBound,
                    to: match.upperBound,
                    insert: FindCore.replacementText(
                        for: match, in: snapshot.text, query: findQuery
                    )
                )
            }
            let succeeded = await applyEditsAction(FindEditRequest(
                snapshot: snapshot, edits: edits
            ))
            guard operationGeneration == generation, succeeded else { return false }
            recordHistory(findQuery.search, findQuery.replacement)
            revealGeneration &+= 1
            clearHighlights()
            isSearching = false
            status = .replaced(edits.count)
            return true
        } catch {
            guard operationGeneration == generation else { return false }
            publish(error: error)
            return false
        }
    }

    /// Installs the four Electron command IDs. The returned ownership tokens
    /// must be retained by the shell and unregistered when the window closes.
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> [CommandHandlerToken] {
        let available: CommandRouter.Enablement = { [weak self] _ in
            guard let self else { return .disabled(reason: "Find unavailable") }
            return self.snapshotProvider() == nil
                ? .disabled(reason: "No active document") : .enabled
        }
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register("find", replaceExisting: replaceExisting, enablement: available) {
                [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Find unavailable")
                }
                self.showFind()
            })
            tokens.append(try router.register("replace", replaceExisting: replaceExisting, enablement: available) {
                [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Find unavailable")
                }
                self.showReplace()
            })
            tokens.append(try router.register("find-next", replaceExisting: replaceExisting, enablement: available) {
                [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Find unavailable")
                }
                let hadQuery = !self.query.isEmpty
                guard await self.findNextOrShow() || !hadQuery else {
                    throw CommandHandlerSignal.noChange
                }
            })
            tokens.append(try router.register("find-previous", replaceExisting: replaceExisting, enablement: available) {
                [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Find unavailable")
                }
                let hadQuery = !self.query.isEmpty
                guard await self.findPreviousOrShow() || !hadQuery else {
                    throw CommandHandlerSignal.noChange
                }
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    func waitForCurrentSearch() async {
        await searchTask?.value
    }

    private func find(_ direction: FindDirection) async -> Bool {
        searchTask?.cancel()
        let generation = nextGeneration()
        guard let snapshot = snapshotProvider(), !query.isEmpty else {
            status = snapshotProvider() == nil ? .unavailable : .idle
            return false
        }
        let findQuery = currentQuery
        do {
            let match = try FindCore.match(
                in: snapshot.text,
                query: findQuery,
                selection: snapshot.selectedRange,
                direction: direction
            )
            guard operationGeneration == generation else { return false }
            recordHistory(findQuery.search, nil)
            guard let match else {
                clearHighlights()
                status = .noMatches
                return false
            }
            let scan = try FindCore.scan(
                snapshot.text, query: findQuery, limit: completeLimit(for: snapshot.text)
            )
            return await select(
                match, in: snapshot, generation: generation, allMatches: scan.matches,
                truncated: scan.isTruncated
            )
        } catch {
            guard operationGeneration == generation else { return false }
            publish(error: error)
            return false
        }
    }

    private func select(
        _ match: FindMatch,
        in snapshot: FindDocumentSnapshot,
        generation: UInt64,
        allMatches: [FindMatch],
        truncated: Bool = false
    ) async -> Bool {
        let succeeded = await selectMatchAction(FindSelectionRequest(
            snapshot: snapshot, selectedRange: match.range
        ))
        guard operationGeneration == generation, succeeded else {
            clearHighlights()
            return false
        }
        revealGeneration &+= 1
        let publishedMatches = Array(allMatches.prefix(resultLimit))
        let absoluteIndex = allMatches.firstIndex(of: match)
        let selectedIndex = publishedMatches.firstIndex(of: match)
        publishHighlights(
            publishedMatches, selectedMatchIndex: selectedIndex, snapshot: snapshot
        )
        isSearching = false
        status = .matches(
            current: absoluteIndex.map { $0 + 1 },
            total: allMatches.count,
            truncated: truncated || allMatches.count > resultLimit
        )
        return true
    }

    private func editableInputDidChange() {
        inputRevision &+= 1
        clearHighlights()
        status = query.isEmpty ? .idle : .searching
        if isPresented { refresh() } else { invalidateOperations() }
    }

    private func publish(
        _ result: FindScanResult,
        selection: NSRange,
        snapshot: FindDocumentSnapshot
    ) {
        let selectedIndex = result.matches.firstIndex { $0.range == selection }
        publishHighlights(
            result.matches, selectedMatchIndex: selectedIndex, snapshot: snapshot
        )
        isSearching = false
        status = result.matches.isEmpty ? .noMatches : .matches(
            current: selectedIndex.map { $0 + 1 },
            total: result.matches.count,
            truncated: result.isTruncated
        )
    }

    private func publish(error: any Error) {
        clearHighlights()
        isSearching = false
        status = .invalidQuery(Self.presentationText(for: error))
    }

    static func presentationText(for error: any Error) -> AppPresentationText {
        guard let error = error as? FindCoreError else {
            return .verbatim(error.localizedDescription)
        }
        switch error {
        case let .invalidRegularExpression(diagnostic):
            return .app(.findInvalidRegularExpression(diagnostic: diagnostic))
        case .invalidResultLimit:
            return .app(.findResultLimitMustBePositive)
        }
    }

    private func nextMatch(in matches: [FindMatch], after selection: NSRange) -> FindMatch? {
        matches.first(where: { $0.lowerBound >= NSMaxRange(selection) }) ?? matches.first
    }

    private func mappedRange(_ range: NSRange, through transaction: TextTransaction) -> NSRange {
        let mapped = transaction.mapSelection(DirectedSelection(
            anchor: range.location, head: NSMaxRange(range)
        ))
        return mapped.range
    }

    private func snapshotStillMatches(_ snapshot: FindDocumentSnapshot) -> Bool {
        guard let current = snapshotProvider() else { return false }
        return current.identity == snapshot.identity
            && current.bufferRevision == snapshot.bufferRevision
            && current.text == snapshot.text
    }

    private func publishHighlights(
        _ matches: [FindMatch],
        selectedMatchIndex: Int?,
        snapshot: FindDocumentSnapshot
    ) {
        self.matches = matches
        self.selectedMatchIndex = selectedMatchIndex.flatMap { index in
            matches.indices.contains(index) ? index : nil
        }
        highlightSnapshot = matches.isEmpty ? nil : FindHighlightSnapshot(
            snapshot: snapshot, matches: matches,
            selectedMatchIndex: self.selectedMatchIndex
        )
    }

    private func clearHighlights() {
        matches = []
        selectedMatchIndex = nil
        highlightSnapshot = nil
    }

    @discardableResult
    private func nextGeneration() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func invalidateOperations() {
        searchTask?.cancel()
        searchTask = nil
        _ = nextGeneration()
    }

    private func completeLimit(for text: String) -> Int {
        let length = text.utf16.count
        return length == Int.max ? Int.max : max(resultLimit, length + 1)
    }

    nonisolated static func defaultSearch(
        _ text: String,
        _ query: FindQuery,
        _ limit: Int
    ) async throws -> FindScanResult {
        try await Task.detached(priority: .userInitiated) {
            try FindCore.scan(text, query: query, limit: limit)
        }.value
    }
}
