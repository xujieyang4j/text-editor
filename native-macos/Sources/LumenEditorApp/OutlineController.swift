import Combine
import Foundation
import LumenEditorCore

private final class OutlineAnalysisTaskBox {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

struct OutlineEditorSnapshot: Equatable, Sendable {
    let documentID: String
    let displayName: String
    let text: String
    let language: String
    let documentRevision: UInt64
    let viewID: EditorViewID
    let selections: SelectionSet
    let tabWidth: Int
    let indentWidth: Int
    let insertSpaces: Bool

    var cursorUTF16Offset: Int { selections.main.head }
}

struct OutlineNavigationRequest: Equatable, Sendable {
    let documentID: String
    let documentRevision: UInt64
    let viewID: EditorViewID
    let utf16Offset: Int
    let line: Int
}

enum OutlineCommandFeedback: Equatable, Sendable {
    case noActiveDocument
    case noFoldableRegion
    case noFoldedRegion
}

/// Window-owned outline and per-editor-view folding state. Analysis is value
/// based and can run away from the main actor; all AppModel and UI interaction
/// remains in injected main-actor closures.
@MainActor
final class OutlineController: ObservableObject {
    typealias SnapshotProvider = @MainActor () -> OutlineEditorSnapshot?
    typealias Analyzer = @Sendable (
        String, String, UInt64, Int, Int, Bool, OutlineLimits
    ) async -> OutlineDocumentModel
    typealias Navigate = @MainActor (OutlineNavigationRequest) async -> Bool
    typealias VisibilityChanged = @MainActor (Bool) -> Void
    typealias Feedback = @MainActor (OutlineCommandFeedback) -> Void

    static let commandIDs: Set<String> = [
        "toggle-outline",
        "fold-current",
        "unfold-current",
        "fold-all",
        "unfold-all"
    ]

    @Published private(set) var isVisible: Bool
    @Published var query = ""
    @Published private(set) var documentName = ""
    @Published private(set) var symbols: [OutlineSymbol] = []
    @Published private(set) var activeSymbolID: OutlineSymbol.ID?
    @Published private(set) var sourceWasTruncated = false
    @Published private(set) var symbolsWereTruncated = false
    @Published private(set) var foldsWereTruncated = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var foldPresentationRevision: UInt64 = 0

    private struct AnalysisKey: Hashable {
        let documentID: String
        let documentRevision: UInt64
        let language: String
        let tabWidth: Int
        let indentWidth: Int
        let insertSpaces: Bool
    }

    private struct ViewKey: Hashable {
        let documentID: String
        let viewID: EditorViewID
    }

    private let limits: OutlineLimits
    private let snapshotProvider: SnapshotProvider
    private let analyzer: Analyzer
    private let navigate: Navigate
    private let visibilityChanged: VisibilityChanged
    private let feedback: Feedback
    private let analysisTaskBox = OutlineAnalysisTaskBox()

    private var currentSnapshot: OutlineEditorSnapshot?
    private var currentAnalysisKey: AnalysisKey?
    private var analyses: [AnalysisKey: OutlineDocumentModel] = [:]
    private var documentAnalysisKeys: [String: AnalysisKey] = [:]
    private var foldingStates: [ViewKey: TextFoldingState] = [:]
    private var analysisGeneration: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var visibilityGeneration: UInt64 = 0

    init(
        isVisible: Bool = false,
        limits: OutlineLimits = .default,
        snapshot: @escaping SnapshotProvider,
        analyze: @escaping Analyzer = { text, language, _, _, _, _, limits in
            await Task.detached(priority: .utility) {
                OutlineFoldingAnalyzer.analyze(
                    text: text, language: language, limits: limits
                )
            }.value
        },
        navigate: @escaping Navigate,
        visibilityChanged: @escaping VisibilityChanged = { _ in },
        feedback: @escaping Feedback = { _ in }
    ) {
        self.isVisible = isVisible
        self.limits = limits
        snapshotProvider = snapshot
        analyzer = analyze
        self.navigate = navigate
        self.visibilityChanged = visibilityChanged
        self.feedback = feedback
        synchronize()
    }

    /// Production composition. The optional navigation closure lets a shell
    /// route outline jumps through NavigationController; the fallback performs
    /// a pane-aware local jump without requiring a filesystem capability.
    static func connected(
        model: AppModel,
        settings: SettingsController,
        analyze: @escaping Analyzer,
        navigate: Navigate? = nil,
        feedback: @escaping Feedback = { _ in }
    ) -> OutlineController {
        func snapshot() -> OutlineEditorSnapshot? {
            let paneIndex = model.paneLayout.activePaneIndex
            guard model.paneLayout.panes.indices.contains(paneIndex),
                  let document = model.activeDocument(inPaneAt: paneIndex) else { return nil }
            let viewID = model.paneLayout.panes[paneIndex].viewID
            let currentSettings = settings.settings
            let indentation = EditorConfig.resolveIndentation(
                config: document.editorConfig?.properties,
                detected: IndentationPreferences(
                    indentSize: currentSettings.tabSize,
                    insertSpaces: currentSettings.insertSpaces
                ),
                defaultTabWidth: currentSettings.tabSize
            )
            return OutlineEditorSnapshot(
                documentID: document.sessionDocumentID,
                displayName: document.displayName,
                text: document.text,
                language: document.language,
                documentRevision: document.buffer.revision,
                viewID: viewID,
                selections: model.selection(
                    for: document.sessionDocumentID, viewID: viewID
                ),
                tabWidth: indentation.tabWidth,
                indentWidth: indentation.indentSize,
                insertSpaces: indentation.insertSpaces
            )
        }

        let controller = OutlineController(
            isVisible: settings.settings.showOutline,
            snapshot: snapshot,
            analyze: analyze,
            navigate: navigate ?? { request in
                guard let document = model.document(
                    sessionDocumentID: request.documentID
                ), let paneIndex = model.paneLayout.panes.firstIndex(where: {
                    $0.viewID == request.viewID
                }), model.paneLayout.panes[paneIndex].contains(request.documentID),
                      document.buffer.revision == request.documentRevision
                else { return false }
                _ = model.selectDocument(document, inPaneAt: paneIndex)
                _ = model.setSelection(
                    .cursor(at: min(
                        max(0, request.utf16Offset), document.buffer.utf16Length
                    )),
                    for: request.documentID,
                    viewID: request.viewID
                )
                return true
            },
            visibilityChanged: { visible in
                settings.set(visible, for: \.showOutline)
            },
            feedback: feedback
        )
        controller.retainLiveState(
            documentIDs: Set(model.documents.map(\.sessionDocumentID)),
            viewIDs: Set(model.paneLayout.panes.map(\.viewID))
        )
        // Folding is an editor-gutter feature, not an outline-panel feature.
        // Prime the exact active revision even while the outline panel is hidden.
        controller.synchronize(forceAnalysis: true)

        settings.$settings
            .map(\.showOutline)
            .removeDuplicates()
            .sink { [weak controller] visible in
                Task { @MainActor [weak controller] in
                    controller?.applyExternalVisibility(visible)
                }
            }
            .store(in: &controller.subscriptions)

        model.objectWillChange
            .sink { [weak controller] _ in
                Task { @MainActor [weak controller] in
                    await Task.yield()
                    controller?.retainLiveState(
                        documentIDs: Set(model.documents.map(\.sessionDocumentID)),
                        viewIDs: Set(model.paneLayout.panes.map(\.viewID))
                    )
                    controller?.synchronize(forceAnalysis: true)
                }
            }
            .store(in: &controller.subscriptions)

        return controller
    }

    var filteredSymbols: [OutlineSymbol] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return symbols }
        return symbols.filter {
            $0.label.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var resultSummary: String {
        guard currentSnapshot != nil else { return "No active document" }
        guard !filteredSymbols.isEmpty else { return "No symbols" }
        let truncated = sourceWasTruncated || symbolsWereTruncated ? " (truncated)" : ""
        return "\(filteredSymbols.count)\(truncated)"
    }

    func toggleVisibility() {
        setVisible(!isVisible)
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        visibilityGeneration &+= 1
        applyVisibility(visible)
        visibilityChanged(visible)
    }

    func synchronize(forceAnalysis: Bool = false) {
        let next = snapshotProvider()
        currentSnapshot = next
        documentName = next?.displayName ?? ""
        guard let next else {
            clearPresentation()
            return
        }

        let key = analysisKey(for: next)
        if let cached = analyses[key] {
            publish(cached, snapshot: next)
            return
        }
        if currentAnalysisKey == key, analysisTask != nil {
            updateActiveSymbol(cursor: next.cursorUTF16Offset)
            return
        }
        let hasFoldedState = foldingStates.contains { entry in
            entry.key.documentID == next.documentID
                && !entry.value.foldedRegionIDs.isEmpty
        }
        guard forceAnalysis || isVisible || hasFoldedState else {
            symbols = []
            activeSymbolID = nil
            sourceWasTruncated = false
            symbolsWereTruncated = false
            foldsWereTruncated = false
            return
        }
        startAnalysis(next, key: key)
    }

    func waitForCurrentAnalysis() async {
        let task = analysisTask
        await task?.value
    }

    func retainLiveState(
        documentIDs: Set<String>,
        viewIDs: Set<EditorViewID>
    ) {
        analyses = analyses.filter { documentIDs.contains($0.key.documentID) }
        documentAnalysisKeys = documentAnalysisKeys.filter {
            documentIDs.contains($0.key)
        }
        foldingStates = foldingStates.filter {
            documentIDs.contains($0.key.documentID)
                && viewIDs.contains($0.key.viewID)
        }
    }

    @discardableResult
    func select(_ symbol: OutlineSymbol) async -> Bool {
        guard let snapshot = currentSnapshot, symbols.contains(symbol) else {
            feedback(.noActiveDocument)
            return false
        }
        _ = revealFoldedContent(
            documentID: snapshot.documentID,
            viewID: snapshot.viewID,
            atUTF16Offset: symbol.utf16Offset
        )
        return await navigate(OutlineNavigationRequest(
            documentID: snapshot.documentID,
            documentRevision: snapshot.documentRevision,
            viewID: snapshot.viewID,
            utf16Offset: symbol.utf16Offset,
            line: symbol.line
        ))
    }

    func textKitFoldSnapshot(
        documentID: String,
        viewID: EditorViewID,
        documentRevision: UInt64
    ) -> TextKitFoldSnapshot {
        let key = ViewKey(documentID: documentID, viewID: viewID)
        let analysisKey = documentAnalysisKeys[documentID]
        let analysis = analysisKey.flatMap { key in
            key.documentRevision == documentRevision ? analyses[key] : nil
        }
        let state = analysis.map { analysis in
            foldingStates[key] ?? TextFoldingState(regions: analysis.foldRegions)
        }
        let hiddenRanges = state?.textKitHiddenRanges ?? []
        let markers = state?.regions.map { region in
            TextKitFoldMarker(
                region: region,
                isFolded: state?.foldedRegionIDs.contains(region.id) == true
            )
        } ?? []
        return TextKitFoldSnapshot(
            documentID: documentID,
            viewID: viewID,
            documentRevision: documentRevision,
            hiddenRanges: hiddenRanges,
            markers: markers,
            presentationRevision: foldPresentationRevision
        )
    }

    /// Handles an exact gutter marker without moving the editor selection. The
    /// caller supplies the complete editor identity, preventing an old marker
    /// click from mutating a newly selected tab or a newer document revision.
    @discardableResult
    func toggleFoldMarker(
        documentID: String,
        viewID: EditorViewID,
        documentRevision: UInt64,
        regionID: String
    ) -> Bool {
        guard documentAnalysisKeys[documentID]?.documentRevision == documentRevision else {
            return false
        }
        let key = ViewKey(documentID: documentID, viewID: viewID)
        guard let analysisKey = documentAnalysisKeys[documentID],
              let analysis = analyses[analysisKey] else { return false }
        var state = foldingStates[key] ?? TextFoldingState(regions: analysis.foldRegions)
        guard state.toggle(regionID: regionID) else {
            return false
        }
        foldingStates[key] = state
        foldPresentationRevision &+= 1
        return true
    }

    @discardableResult
    func foldCurrent() async -> Bool {
        guard let snapshot = await preparedSnapshot() else {
            feedback(.noActiveDocument)
            return false
        }
        return mutateFolding(snapshot: snapshot, noChange: .noFoldableRegion) { state in
            state.foldCurrent(atUTF16Offset: snapshot.cursorUTF16Offset)
        }
    }

    @discardableResult
    func unfoldCurrent() async -> Bool {
        guard let snapshot = await preparedSnapshot() else {
            feedback(.noActiveDocument)
            return false
        }
        return mutateFolding(snapshot: snapshot, noChange: .noFoldedRegion) { state in
            state.unfoldCurrent(atUTF16Offset: snapshot.cursorUTF16Offset)
        }
    }

    @discardableResult
    func foldAll() async -> Bool {
        guard let snapshot = await preparedSnapshot() else {
            feedback(.noActiveDocument)
            return false
        }
        return mutateFolding(snapshot: snapshot, noChange: .noFoldableRegion) {
            $0.foldAll()
        }
    }

    @discardableResult
    func unfoldAll() async -> Bool {
        guard let snapshot = await preparedSnapshot() else {
            feedback(.noActiveDocument)
            return false
        }
        return mutateFolding(snapshot: snapshot, noChange: .noFoldedRegion) {
            $0.unfoldAll()
        }
    }

    @discardableResult
    func revealFoldedContent(
        documentID: String,
        viewID: EditorViewID,
        atUTF16Offset offset: Int
    ) -> Bool {
        let key = ViewKey(documentID: documentID, viewID: viewID)
        guard var state = foldingStates[key] else { return false }
        guard state.reveal(atUTF16Offset: offset) else { return false }
        foldingStates[key] = state
        foldPresentationRevision &+= 1
        return true
    }

    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        let documentAvailable: CommandRouter.Enablement = { [weak self] _ in
            self?.snapshotProvider() == nil
                ? .disabled(reason: "No active document") : .enabled
        }
        let foldAvailable: CommandRouter.Enablement = { [weak self] _ in
            guard let self, self.snapshotProvider() != nil else {
                return .disabled(reason: "No active document")
            }
            return self.isAnalyzing
                ? .disabled(reason: "Outline is updating") : .enabled
        }
        do {
            tokens.append(try router.register(
                "toggle-outline", replaceExisting: replaceExisting,
                enablement: documentAvailable
            ) { [weak self] _ in self?.toggleVisibility() })
            tokens.append(try router.register(
                "fold-current", replaceExisting: replaceExisting,
                enablement: foldAvailable
            ) { [weak self] _ in
                guard let self else { throw CommandHandlerSignal.unavailable(reason: "Outline unavailable") }
                guard await self.foldCurrent() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "unfold-current", replaceExisting: replaceExisting,
                enablement: foldAvailable
            ) { [weak self] _ in
                guard let self else { throw CommandHandlerSignal.unavailable(reason: "Outline unavailable") }
                guard await self.unfoldCurrent() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "fold-all", replaceExisting: replaceExisting,
                enablement: foldAvailable
            ) { [weak self] _ in
                guard let self else { throw CommandHandlerSignal.unavailable(reason: "Outline unavailable") }
                guard await self.foldAll() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "unfold-all", replaceExisting: replaceExisting,
                enablement: foldAvailable
            ) { [weak self] _ in
                guard let self else { throw CommandHandlerSignal.unavailable(reason: "Outline unavailable") }
                guard await self.unfoldAll() else { throw CommandHandlerSignal.noChange }
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    private func applyVisibility(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { synchronize() }
    }

    private func applyExternalVisibility(_ visible: Bool) {
        let generation = visibilityGeneration
        guard visible != isVisible else { return }
        visibilityGeneration &+= 1
        applyVisibility(visible)
        // An older SettingsController publication can arrive after a local
        // toggle initiated its persistence write. Only mirror genuine external
        // state changes; never bounce that stale value back into settings.
        if generation != 0 { return }
    }

    private func startAnalysis(_ snapshot: OutlineEditorSnapshot, key: AnalysisKey) {
        analysisGeneration &+= 1
        let generation = analysisGeneration
        analysisTask?.cancel()
        currentAnalysisKey = key
        isAnalyzing = true
        symbols = []
        activeSymbolID = nil
        sourceWasTruncated = false
        symbolsWereTruncated = false
        foldsWereTruncated = false
        let analyzer = self.analyzer
        let limits = self.limits
        analysisTask = Task { @MainActor [weak self] in
            let result = await analyzer(
                snapshot.text, snapshot.language, snapshot.documentRevision,
                snapshot.tabWidth, snapshot.indentWidth, snapshot.insertSpaces, limits
            )
            guard let self, !Task.isCancelled,
                  generation == self.analysisGeneration,
                  self.currentSnapshot.map({ self.analysisKey(for: $0) }) == key else { return }
            self.analyses[key] = result
            self.analysisTask = nil
            self.isAnalyzing = false
            self.publish(result, snapshot: snapshot)
        }
    }

    private func publish(
        _ model: OutlineDocumentModel,
        snapshot: OutlineEditorSnapshot
    ) {
        let nextAnalysisKey = analysisKey(for: snapshot)
        let previousAnalysisKey = documentAnalysisKeys[snapshot.documentID]
        currentAnalysisKey = nextAnalysisKey
        documentAnalysisKeys[snapshot.documentID] = nextAnalysisKey
        symbols = model.symbols
        sourceWasTruncated = model.sourceWasTruncated
        symbolsWereTruncated = model.symbolsWereTruncated
        foldsWereTruncated = model.foldsWereTruncated
        updateActiveSymbol(cursor: snapshot.cursorUTF16Offset)

        let viewKey = ViewKey(
            documentID: snapshot.documentID, viewID: snapshot.viewID
        )
        let documentChanged = previousAnalysisKey != nil
            && previousAnalysisKey != nextAnalysisKey
        var state = foldingStates[viewKey] ?? TextFoldingState()
        let previous = state
        if documentChanged {
            state.reconcile(regions: model.foldRegions)
        } else {
            state.update(regions: model.foldRegions)
        }
        foldingStates[viewKey] = state
        if state != previous { foldPresentationRevision &+= 1 }
        for key in foldingStates.keys where key.documentID == snapshot.documentID
            && key != viewKey {
            var other = foldingStates[key] ?? TextFoldingState()
            let old = other
            if documentChanged {
                other.reconcile(regions: model.foldRegions)
            } else {
                other.update(regions: model.foldRegions)
            }
            foldingStates[key] = other
            if other != old { foldPresentationRevision &+= 1 }
        }
        pruneCaches(liveDocumentID: snapshot.documentID)
    }

    private func updateActiveSymbol(cursor: Int) {
        activeSymbolID = OutlineFoldingAnalyzer.activeSymbol(
            in: symbols, atUTF16Offset: cursor
        )?.id
    }

    private func clearPresentation() {
        analysisGeneration &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        currentAnalysisKey = nil
        symbols = []
        activeSymbolID = nil
        sourceWasTruncated = false
        symbolsWereTruncated = false
        foldsWereTruncated = false
    }

    func shutdown() {
        clearPresentation()
        subscriptions.removeAll()
    }

    private func preparedSnapshot() async -> OutlineEditorSnapshot? {
        synchronize(forceAnalysis: true)
        await waitForCurrentAnalysis()
        guard let snapshot = currentSnapshot,
              analyses[analysisKey(for: snapshot)] != nil else { return nil }
        return snapshot
    }

    private func mutateFolding(
        snapshot: OutlineEditorSnapshot,
        noChange: OutlineCommandFeedback,
        mutation: (inout TextFoldingState) -> Bool
    ) -> Bool {
        let analysisKey = analysisKey(for: snapshot)
        guard let analysis = analyses[analysisKey] else {
            feedback(noChange)
            return false
        }
        let viewKey = ViewKey(
            documentID: snapshot.documentID, viewID: snapshot.viewID
        )
        var state = foldingStates[viewKey]
            ?? TextFoldingState(regions: analysis.foldRegions)
        state.update(regions: analysis.foldRegions)
        guard mutation(&state) else {
            feedback(noChange)
            return false
        }
        foldingStates[viewKey] = state
        foldPresentationRevision &+= 1
        return true
    }

    private func analysisKey(for snapshot: OutlineEditorSnapshot) -> AnalysisKey {
        AnalysisKey(
            documentID: snapshot.documentID,
            documentRevision: snapshot.documentRevision,
            language: snapshot.language,
            tabWidth: snapshot.tabWidth,
            indentWidth: snapshot.indentWidth,
            insertSpaces: snapshot.insertSpaces
        )
    }

    private func pruneCaches(liveDocumentID: String) {
        let stale = analyses.keys.filter {
            $0.documentID == liveDocumentID && $0 != currentAnalysisKey
        }
        for key in stale { analyses[key] = nil }
    }

    private var analysisTask: Task<Void, Never>? {
        get { analysisTaskBox.task }
        set { analysisTaskBox.task = newValue }
    }
}
