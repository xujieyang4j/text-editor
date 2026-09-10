import Foundation
import LumenEditorCore

/// Window-scoped, revision-aware access to the asynchronous parser service.
/// Parsing is scheduled on a detached utility task; synchronous consumers may
/// only read an already validated cached value.
final class CodeMirrorParserCoordinator: @unchecked Sendable {
    static let probeDebounceNanoseconds: UInt64 = 120_000_000
    typealias Analyze = @Sendable (String, String, Int, Int, Bool)
        async -> CodeMirrorParserAnalysis?
    typealias AnalyzeWithNewlinePositions = @Sendable (
        String, String, Int, Int, Bool, [Int]
    ) async -> CodeMirrorParserAnalysis?
    typealias CancelAll = @Sendable () async -> Void

    private struct AnalysisKey: Hashable, Sendable {
        let revision: UInt64
        // Swift String equality is canonically equivalent. Parser offsets are
        // UTF-16 exact, so cache identity must compare the actual code units.
        let languageUTF16: [UInt16]
        let textUTF16: [UInt16]
        let tabWidth: Int
        let indentWidth: Int
        let insertSpaces: Bool
        let newlineIndentationPositions: [Int]
    }

    private let analyzeFunction: AnalyzeWithNewlinePositions
    private let cancelAllFunction: CancelAll
    private let maximumCachedAnalyses: Int
    private let maximumInFlightAnalyses: Int
    private let stateLock = NSLock()
    private var cache: [AnalysisKey: CodeMirrorParserAnalysis] = [:]
    private var cacheOrder: [AnalysisKey] = []
    private struct InFlight: @unchecked Sendable {
        let id: UUID
        let task: Task<CodeMirrorParserAnalysis?, Never>
        var waiterIDs: Set<UUID>
    }
    private struct PendingTask: @unchecked Sendable {
        let id: UUID
        let task: Task<CodeMirrorParserAnalysis?, Never>
        let start: @Sendable () -> Void
    }
    private var inFlight: [AnalysisKey: InFlight] = [:]
    private var inFlightOrder: [AnalysisKey] = []
    private var reclamationTask: Task<Void, Never>?
    private var isShutdown = false

    private enum AnalysisLookup {
        case cached(CodeMirrorParserAnalysis)
        case inFlight(InFlight, waiterID: UUID)
        case unavailable
    }

    init(
        service: CodeMirrorParserService,
        maximumCachedAnalyses: Int = 8,
        maximumInFlightAnalyses: Int = 4
    ) {
        self.maximumCachedAnalyses = max(1, maximumCachedAnalyses)
        self.maximumInFlightAnalyses = max(1, maximumInFlightAnalyses)
        analyzeFunction = {
            text, language, tabWidth, indentWidth, insertSpaces, positions in
            await service.analyze(
                text: text, language: language, tabWidth: tabWidth,
                indentWidth: indentWidth, insertSpaces: insertSpaces,
                newlineIndentationPositions: positions
            )
        }
        cancelAllFunction = { await service.cancelAll() }
    }

    init(
        maximumCachedAnalyses: Int = 8,
        maximumInFlightAnalyses: Int = 4,
        analyze: @escaping Analyze,
        cancelAll: @escaping CancelAll = {}
    ) {
        self.maximumCachedAnalyses = max(1, maximumCachedAnalyses)
        self.maximumInFlightAnalyses = max(1, maximumInFlightAnalyses)
        analyzeFunction = { text, language, tabWidth, indentWidth, insertSpaces, _ in
            await analyze(text, language, tabWidth, indentWidth, insertSpaces)
        }
        cancelAllFunction = cancelAll
    }

    init(
        maximumCachedAnalyses: Int = 8,
        maximumInFlightAnalyses: Int = 4,
        analyzeWithNewlinePositions analyze: @escaping AnalyzeWithNewlinePositions,
        cancelAll: @escaping CancelAll = {}
    ) {
        self.maximumCachedAnalyses = max(1, maximumCachedAnalyses)
        self.maximumInFlightAnalyses = max(1, maximumInFlightAnalyses)
        analyzeFunction = analyze
        cancelAllFunction = cancelAll
    }

    /// Analyze an exact document revision. The full text participates in the
    /// key so unrelated documents or content cannot alias merely because they
    /// share a revision number and language.
    func analyze(
        text: String,
        language: String,
        revision: UInt64,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        newlineIndentationPositions: [Int] = []
    ) async -> CodeMirrorParserAnalysis? {
        guard text.utf16.count <= 128 * 1_024, language.utf16.count <= 128,
              Self.lineCountWithinBudget(text) else {
            return nil
        }
        let tabWidth = min(16, max(1, tabWidth))
        let indentWidth = min(16, max(1, indentWidth ?? tabWidth))
        let newlineIndentationPositions = Self.boundedNewlinePositions(
            newlineIndentationPositions, textLength: text.utf16.count
        )
        let key = AnalysisKey(
            revision: revision, languageUTF16: Array(language.utf16),
            textUTF16: Array(text.utf16),
            tabWidth: tabWidth, indentWidth: indentWidth, insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        )
        let lookup = analysisLookup(
            key: key, text: text, language: language, tabWidth: tabWidth,
            indentWidth: indentWidth, insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        )
        switch lookup {
        case .cached(let analysis):
            return analysis
        case .inFlight(let inFlight, let waiterID):
            let result = await withTaskCancellationHandler {
                await inFlight.task.value
            } onCancel: {
                self.unregisterWaiter(
                    for: key, taskID: inFlight.id, waiterID: waiterID,
                    cancelSharedIfLast: true
                )
            }
            unregisterWaiter(
                for: key, taskID: inFlight.id, waiterID: waiterID,
                cancelSharedIfLast: false
            )
            return Task.isCancelled ? nil : result
        case .unavailable:
            return nil
        }
    }

    /// Defers cursor-specific indentation probes so transient selection changes
    /// do not launch full parser workers. Cancellation is checked both before
    /// and by `analyze`, preserving exact-key worker cancellation semantics.
    func analyzeAfterProbeDebounce(
        text: String, language: String, revision: UInt64,
        tabWidth: Int = 4, indentWidth: Int? = nil, insertSpaces: Bool = true,
        newlineIndentationPositions: [Int],
        debounceNanoseconds: UInt64 = CodeMirrorParserCoordinator
            .probeDebounceNanoseconds
    ) async -> CodeMirrorParserAnalysis? {
        do {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
            try Task.checkCancellation()
        } catch {
            return nil
        }
        return await analyze(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        )
    }

    /// A non-blocking cache seam for later highlighting and editing-command
    /// consumers. This method never invokes JavaScript.
    func cachedAnalysis(
        text: String,
        language: String,
        revision: UInt64,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        newlineIndentationPositions: [Int] = []
    ) -> CodeMirrorParserAnalysis? {
        let tabWidth = min(16, max(1, tabWidth))
        return cacheEntry(for: AnalysisKey(
            revision: revision, languageUTF16: Array(language.utf16),
            textUTF16: Array(text.utf16), tabWidth: tabWidth,
            indentWidth: min(16, max(1, indentWidth ?? tabWidth)),
            insertSpaces: insertSpaces,
            newlineIndentationPositions: Self.boundedNewlinePositions(
                newlineIndentationPositions, textLength: text.utf16.count
            )
        ))
    }

    func cachedAnalysisForAnyNewlinePositions(
        text: String, language: String, revision: UInt64, tabWidth: Int,
        indentWidth: Int?, insertSpaces: Bool
    ) -> CodeMirrorParserAnalysis? {
        let tabWidth = min(16, max(1, tabWidth))
        let indentWidth = min(16, max(1, indentWidth ?? tabWidth))
        let languageUTF16 = Array(language.utf16)
        let textUTF16 = Array(text.utf16)
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.first { element in
            let key = element.key
            key.revision == revision && key.languageUTF16 == languageUTF16
                && key.textUTF16 == textUTF16 && key.tabWidth == tabWidth
                && key.indentWidth == indentWidth
                && key.insertSpaces == insertSpaces
        }?.value
    }

    func cachedParsedSyntaxSnapshot(
        text: String,
        language: String,
        revision: UInt64,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true
    ) -> ParsedSyntaxSnapshot? {
        guard let analysis = cachedAnalysisForAnyNewlinePositions(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth, insertSpaces: insertSpaces
        ), analysis.supported, !analysis.truncated.source else { return nil }
        return analysis.parsedSyntaxSnapshot(expectedRevision: revision)
    }

    /// Return only exact-key, complete indentation data. This is a synchronous
    /// cache read and never evaluates JavaScript on the main thread.
    func cachedParsedIndentationSnapshot(
        text: String,
        language: String,
        revision: UInt64,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        newlineIndentationPositions: [Int] = []
    ) -> CodeMirrorIndentationSnapshot? {
        let tabWidth = min(16, max(1, tabWidth))
        let indentWidth = min(16, max(1, indentWidth ?? tabWidth))
        guard let analysis = cachedAnalysis(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        ), analysis.supported, !analysis.truncated.source,
           !analysis.truncated.indentation else { return nil }
        return CodeMirrorIndentationSnapshot(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            entries: analysis.indentation.map {
                .init(lineFrom: $0.lineFrom, columns: $0.columns)
            },
            newlineEntries: analysis.newlineIndentation.map {
                .init(
                    position: $0.position, columns: $0.columns,
                    doubleColumns: $0.doubleColumns, explode: $0.explode
                )
            },
            transitionEntries: analysis.newlineIndentationTransitions.map {
                .init(
                    position: $0.position, insert: $0.insert,
                    columns: $0.columns, doubleColumns: $0.doubleColumns,
                    explode: $0.explode
                )
            }
        )
    }

    /// Returns a fully validated snapshot from an analysis already obtained by
    /// the caller. This avoids a second cache-key construction on MainActor.
    static func parsedIndentationSnapshot(
        from analysis: CodeMirrorParserAnalysis?, text: String,
        language: String, revision: UInt64, tabWidth requestedTabWidth: Int = 4,
        indentWidth requestedIndentWidth: Int? = nil, insertSpaces: Bool = true
    ) -> CodeMirrorIndentationSnapshot? {
        let tabWidth = min(16, max(1, requestedTabWidth))
        let indentWidth = min(16, max(1, requestedIndentWidth ?? tabWidth))
        guard let analysis, analysis.supported, !analysis.truncated.source,
              !analysis.truncated.indentation,
              analysis.requestedLanguage == language,
              analysis.sourceUTF16Length == text.utf16.count else { return nil }
        return CodeMirrorIndentationSnapshot(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            entries: analysis.indentation.map {
                .init(lineFrom: $0.lineFrom, columns: $0.columns)
            },
            newlineEntries: analysis.newlineIndentation.map {
                .init(
                    position: $0.position, columns: $0.columns,
                    doubleColumns: $0.doubleColumns, explode: $0.explode
                )
            },
            transitionEntries: analysis.newlineIndentationTransitions.map {
                .init(
                    position: $0.position, insert: $0.insert,
                    columns: $0.columns, doubleColumns: $0.doubleColumns,
                    explode: $0.explode
                )
            }
        )
    }

    /// Parser-backed outline analysis with the bounded lexical analyzer as a
    /// fail-closed fallback for unsupported languages and every bridge/schema
    /// failure. Both paths execute away from the main actor.
    func outlineDocumentModel(
        text: String,
        language: String,
        revision: UInt64,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        limits: OutlineLimits
    ) async -> OutlineDocumentModel {
        if let analysis = await analyze(
            text: text, language: language, revision: revision,
            tabWidth: tabWidth, indentWidth: indentWidth, insertSpaces: insertSpaces
        ), analysis.supported, analysis.parserKind == .lezer,
           !analysis.truncated.source,
           !analysis.truncated.syntaxNodes {
            return analysis.outlineDocumentModel(limits: limits)
        }
        return await Task.detached(priority: .utility) {
            OutlineFoldingAnalyzer.analyze(
                text: text, language: language, limits: limits
            )
        }.value
    }

    /// Immediately invalidates every cache/in-flight entry and starts worker
    /// reclamation. Callers that need confirmed teardown may await the returned
    /// task; window shutdown may safely discard it after triggering cleanup.
    @discardableResult
    func removeAllCachedAnalyses() -> Task<Void, Never> {
        reclaimWorkers(permanently: false)
    }

    /// Permanently closes this window-owned coordinator. New requests fail
    /// closed while all admitted helper processes are cancelled and joined.
    /// This is separate from cache invalidation so teardown cannot race a late
    /// SwiftUI or command task into starting another parser worker.
    func shutdown() async {
        await reclaimWorkers(permanently: true).value
    }

    private func reclaimWorkers(
        permanently: Bool
    ) -> Task<Void, Never> {
        stateLock.lock()
        if permanently { isShutdown = true }
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll(keepingCapacity: false)
        inFlightOrder.removeAll(keepingCapacity: false)
        let previousReclamation = reclamationTask
        let cancelAll = cancelAllFunction
        let reclamation = Task.detached(priority: .utility) {
            if let previousReclamation {
                await previousReclamation.value
            }
            await cancelAll()
            for task in tasks { _ = await task.value }
        }
        reclamationTask = reclamation
        stateLock.unlock()

        // Cancellation handlers may synchronously call back into this
        // coordinator, so cancellation must happen after releasing the lock.
        tasks.forEach { $0.cancel() }
        return reclamation
    }

    /// Diagnostic seam used by concurrency tests.
    var activeWaiterCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inFlight.values.reduce(0) { $0 + $1.waiterIDs.count }
    }

    static func lineCountWithinBudget(_ text: String) -> Bool {
        var count = 1
        let units = Array(text.utf16)
        for index in units.indices {
            if units[index] == 0x0A {
                count += 1
            } else if units[index] == 0x0D,
                      index + 1 == units.count || units[index + 1] != 0x0A {
                count += 1
            }
            if count > 50_000 { return false }
        }
        return count <= 50_000
    }

    private static func boundedNewlinePositions(
        _ positions: [Int], textLength: Int
    ) -> [Int] {
        Array(Set(positions.filter { $0 >= 0 && $0 <= textLength }))
            .sorted()
            .prefix(
                CodeMirrorParserService.AnalyzeRequest
                    .maximumNewlineIndentationPositions
            )
            .map { $0 }
    }

}

private extension CodeMirrorParserCoordinator {
    func analysisLookup(
        key: AnalysisKey, text: String, language: String, tabWidth: Int,
        indentWidth: Int, insertSpaces: Bool,
        newlineIndentationPositions: [Int]
    ) -> AnalysisLookup {
        stateLock.lock()
        guard !isShutdown else {
            stateLock.unlock()
            return .unavailable
        }
        if let cached = cache[key] {
            stateLock.unlock()
            return .cached(cached)
        }

        let waiterID = UUID()
        if var item = inFlight[key] {
            item.waiterIDs.insert(waiterID)
            inFlight[key] = item
            stateLock.unlock()
            return .inFlight(item, waiterID: waiterID)
        }

        var evictedTasks: [Task<CodeMirrorParserAnalysis?, Never>] = []
        while inFlight.count >= maximumInFlightAnalyses,
              !inFlightOrder.isEmpty {
            let oldestKey = inFlightOrder.removeFirst()
            if let evicted = inFlight.removeValue(forKey: oldestKey) {
                evictedTasks.append(evicted.task)
            }
        }
        let pending = makeTask(
            key: key, text: text, language: language, tabWidth: tabWidth,
            indentWidth: indentWidth, insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        )
        let item = InFlight(
            id: pending.id, task: pending.task, waiterIDs: [waiterID]
        )
        inFlight[key] = item
        inFlightOrder.append(key)
        stateLock.unlock()

        evictedTasks.forEach { $0.cancel() }
        pending.start()
        return .inFlight(item, waiterID: waiterID)
    }

    func makeTask(
        key: AnalysisKey, text: String, language: String, tabWidth: Int,
        indentWidth: Int, insertSpaces: Bool,
        newlineIndentationPositions: [Int]
    ) -> PendingTask {
        let analyzer = analyzeFunction
        let pendingReclamation = reclamationTask
        let taskID = UUID()
        let startGate = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) { [weak self] in
            startGate.wait()
            guard !Task.isCancelled else { return nil }
            if let pendingReclamation {
                await pendingReclamation.value
            }
            guard !Task.isCancelled else { return nil }
            let result = await analyzer(
                text, language, tabWidth, indentWidth, insertSpaces,
                newlineIndentationPositions
            )
            let acceptedResult = Task.isCancelled ? nil : result
            self?.finishAnalysis(acceptedResult, for: key, taskID: taskID)
            return acceptedResult
        }
        return PendingTask(
            id: taskID, task: task,
            start: { startGate.signal() }
        )
    }

    func finishAnalysis(
        _ analysis: CodeMirrorParserAnalysis?,
        for key: AnalysisKey,
        taskID: UUID
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard inFlight[key]?.id == taskID else { return }
        removeInFlightLocked(for: key)
        // Bridge failures and post-call timeouts are transient. Only validated
        // parser responses (including stable `unsupported`) are cached.
        guard let analysis else { return }
        storeLocked(analysis, for: key)
    }

    func unregisterWaiter(
        for key: AnalysisKey, taskID: UUID, waiterID: UUID,
        cancelSharedIfLast: Bool
    ) {
        stateLock.lock()
        guard var item = inFlight[key], item.id == taskID,
              item.waiterIDs.remove(waiterID) != nil else {
            stateLock.unlock()
            return
        }
        guard cancelSharedIfLast, item.waiterIDs.isEmpty else {
            inFlight[key] = item
            stateLock.unlock()
            return
        }
        removeInFlightLocked(for: key)
        stateLock.unlock()
        item.task.cancel()
    }

    func cacheEntry(for key: AnalysisKey) -> CodeMirrorParserAnalysis? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache[key]
    }

    func storeLocked(_ analysis: CodeMirrorParserAnalysis, for key: AnalysisKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = analysis
        while cacheOrder.count > maximumCachedAnalyses {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    func removeInFlightLocked(for key: AnalysisKey) {
        inFlight[key] = nil
        if let index = inFlightOrder.firstIndex(of: key) {
            inFlightOrder.remove(at: index)
        }
    }
}
