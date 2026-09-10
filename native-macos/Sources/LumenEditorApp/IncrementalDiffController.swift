@preconcurrency import Foundation
import LumenEditorCore

struct IncrementalDiffSnapshot: Equatable, Sendable {
    let documentID: String
    let fileURL: URL?
    let paneIndex: Int
    let viewID: EditorViewID
    let baselineText: String
    let currentText: String
    let selection: SelectionSet
    let bufferRevision: UInt64
    let hasExternalConflict: Bool

    init(
        documentID: String,
        fileURL: URL?,
        paneIndex: Int,
        viewID: EditorViewID,
        baselineText: String,
        currentText: String,
        selection: SelectionSet,
        bufferRevision: UInt64,
        hasExternalConflict: Bool = false
    ) {
        self.documentID = documentID
        self.fileURL = fileURL
        self.paneIndex = paneIndex
        self.viewID = viewID
        self.baselineText = baselineText
        self.currentText = currentText
        self.selection = selection
        self.bufferRevision = bufferRevision
        self.hasExternalConflict = hasExternalConflict
    }

    var currentLine: Int {
        IncrementalDiff.lineNumber(
            atUTF16Offset: selection.main.head, in: currentText
        )
    }

    static func == (left: Self, right: Self) -> Bool {
        left.documentID == right.documentID
            && left.fileURL == right.fileURL
            && left.paneIndex == right.paneIndex
            && left.viewID == right.viewID
            && IncrementalDiff.exactlyEqual(left.baselineText, right.baselineText)
            && IncrementalDiff.exactlyEqual(left.currentText, right.currentText)
            && left.selection == right.selection
            && left.bufferRevision == right.bufferRevision
            && left.hasExternalConflict == right.hasExternalConflict
    }
}

struct IncrementalDiffNavigationRequest: Equatable, Sendable {
    let snapshot: IncrementalDiffSnapshot
    let hunk: IncrementalDiffHunk
    let targetLine: Int
    let targetUTF16Offset: Int
}

struct IncrementalDiffRevertRequest: Equatable, Sendable {
    let snapshot: IncrementalDiffSnapshot
    let hunk: IncrementalDiffHunk
    let transaction: TextTransaction
}

enum IncrementalDiffControllerStatus: Equatable, Sendable {
    case idle
    case navigated(IncrementalDiffHunk)
    case reverted(IncrementalDiffHunk)
    case noChanges
    case noChangeAtCursor
    case unavailable
    case conflict
    case limited(String)
    case failed(String)
}

/// Saved-baseline incremental diff owner for one window. Every callback gets
/// the exact document/pane/revision snapshot used to compute its hunk.
@MainActor
final class IncrementalDiffController {
    typealias SnapshotProvider = @MainActor () -> IncrementalDiffSnapshot?
    typealias Navigator = @MainActor (IncrementalDiffNavigationRequest) async -> Bool
    typealias Reverter = @MainActor (IncrementalDiffRevertRequest) -> Bool

    static let commandIDs = [
        "next-change",
        "prev-change",
        "revert-current-change"
    ]

    private let limits: IncrementalDiffLimits
    private let snapshotProvider: SnapshotProvider
    private let navigate: Navigator
    private let revert: Reverter

    private(set) var status: IncrementalDiffControllerStatus = .idle
    private var cachedKey: DiffCacheKey?
    private var cachedResult: Result<IncrementalDiffResult, IncrementalDiffError>?

    init(
        limits: IncrementalDiffLimits = .standard,
        snapshot: @escaping SnapshotProvider,
        navigate: @escaping Navigator,
        revert: @escaping Reverter
    ) {
        self.limits = limits
        snapshotProvider = snapshot
        self.navigate = navigate
        self.revert = revert
    }

    func markers(for snapshot: IncrementalDiffSnapshot? = nil) -> [IncrementalDiffMarker] {
        guard let snapshot = snapshot ?? snapshotProvider(),
              snapshot.fileURL != nil, !snapshot.hasExternalConflict else { return [] }
        return (try? cachedDiff(snapshot).markers) ?? []
    }

    @discardableResult
    func nextChange() async -> Bool {
        await move(.next)
    }

    @discardableResult
    func previousChange() async -> Bool {
        await move(.previous)
    }

    @discardableResult
    func revertCurrentChange() -> Bool {
        guard let snapshot = availableSnapshot() else { return false }
        guard !snapshot.hasExternalConflict else {
            status = .conflict
            return false
        }
        do {
            let result = try cachedDiff(snapshot)
            guard let hunk = result.currentHunk(at: snapshot.currentLine) else {
                status = result.hunks.isEmpty ? .noChanges : .noChangeAtCursor
                return false
            }
            let transaction = try IncrementalDiff.revertTransaction(
                current: snapshot.currentText,
                hunk: hunk,
                selection: snapshot.selection,
                expectedRevision: snapshot.bufferRevision
            )
            guard !transaction.edits.isEmpty else {
                status = .noChangeAtCursor
                return false
            }
            let accepted = revert(IncrementalDiffRevertRequest(
                snapshot: snapshot, hunk: hunk, transaction: transaction
            ))
            status = accepted ? .reverted(hunk) : .failed(
                "The document changed before the hunk could be reverted."
            )
            return accepted
        } catch let error as IncrementalDiffError {
            status = isLimitError(error)
                ? .limited(error.localizedDescription)
                : .failed(error.localizedDescription)
            return false
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> [CommandHandlerToken] {
        let available: CommandRouter.Enablement = { [weak self] _ in
            guard let self else {
                return .disabled(reason: "Incremental diff unavailable")
            }
            guard let snapshot = self.snapshotProvider() else {
                return .disabled(reason: "No active document")
            }
            guard snapshot.fileURL != nil else {
                return .disabled(reason: "Save the document first")
            }
            guard !snapshot.hasExternalConflict else {
                return .disabled(reason: "Resolve the external file conflict first")
            }
            return .enabled
        }
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register(
                "next-change", replaceExisting: replaceExisting, enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Incremental diff unavailable")
                }
                guard await self.nextChange() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "prev-change", replaceExisting: replaceExisting, enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Incremental diff unavailable")
                }
                guard await self.previousChange() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "revert-current-change", replaceExisting: replaceExisting,
                enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Incremental diff unavailable")
                }
                guard self.revertCurrentChange() else { throw CommandHandlerSignal.noChange }
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    /// Production adapter. NavigationController is optional so embedders can
    /// still use pane-local selection; pass it to preserve shared history.
    convenience init(
        model: AppModel,
        navigation navigationController: NavigationController? = nil,
        limits: IncrementalDiffLimits = .standard
    ) {
        self.init(
            limits: limits,
            snapshot: { Self.snapshot(model: model) },
            navigate: { request in
                guard Self.matches(request.snapshot, model: model) else { return false }
                guard let document = model.activeDocument(
                    inPaneAt: request.snapshot.paneIndex
                ) else { return false }
                let sourcePosition = IncrementalDiff.lineAndColumn(
                    atUTF16Offset: request.snapshot.selection.main.head,
                    in: request.snapshot.currentText
                )
                let path = request.snapshot.fileURL?.standardizedFileURL.path
                let source = NavigationLocation(
                    documentID: request.snapshot.documentID, path: path,
                    groupID: request.snapshot.paneIndex, line: sourcePosition.line,
                    column: sourcePosition.column
                )
                let selected = model.setSelections(
                    .cursor(at: request.targetUTF16Offset),
                    for: document, inPaneAt: request.snapshot.paneIndex
                )
                let arrived = selected || model.selection(
                    for: document, inPaneAt: request.snapshot.paneIndex
                ).main.head == request.targetUTF16Offset
                guard arrived else { return false }
                if let navigationController {
                    navigationController.invalidateNavigationIntents()
                    navigationController.recordSuccessfulJump(
                        source: source,
                        target: NavigationLocation(
                            documentID: request.snapshot.documentID, path: path,
                            groupID: request.snapshot.paneIndex,
                            line: request.targetLine, column: 1
                        )
                    )
                }
                return true
            },
            revert: { request in
                guard Self.matches(request.snapshot, model: model),
                      let document = model.activeDocument(
                        inPaneAt: request.snapshot.paneIndex
                      ) else { return false }
                return model.apply(
                    request.transaction, to: document,
                    inPaneAt: request.snapshot.paneIndex
                )
            }
        )
    }

    static func snapshot(
        model: AppModel, paneIndex requestedPaneIndex: Int? = nil
    ) -> IncrementalDiffSnapshot? {
        let paneIndex = requestedPaneIndex ?? model.paneLayout.activePaneIndex
        guard model.paneLayout.panes.indices.contains(paneIndex),
              let document = model.activeDocument(inPaneAt: paneIndex) else { return nil }
        let viewID = model.paneLayout.panes[paneIndex].viewID
        return IncrementalDiffSnapshot(
            documentID: document.sessionDocumentID,
            fileURL: document.fileURL,
            paneIndex: paneIndex,
            viewID: viewID,
            baselineText: document.savedText,
            currentText: document.buffer.text,
            selection: model.selection(for: document, inPaneAt: paneIndex),
            bufferRevision: document.buffer.revision,
            hasExternalConflict: document.externalConflict != nil
        )
    }

    private func move(_ direction: IncrementalDiffNavigationDirection) async -> Bool {
        guard let snapshot = availableSnapshot() else { return false }
        guard !snapshot.hasExternalConflict else {
            status = .conflict
            return false
        }
        do {
            let result = try cachedDiff(snapshot)
            guard let hunk = result.hunk(from: snapshot.currentLine, direction: direction) else {
                status = .noChanges
                return false
            }
            let targetLine = result.markerLine(for: hunk)
            let targetOffset = IncrementalDiff.utf16Offset(
                forLine: targetLine, in: snapshot.currentText
            )
            let accepted = await navigate(IncrementalDiffNavigationRequest(
                snapshot: snapshot, hunk: hunk, targetLine: targetLine,
                targetUTF16Offset: targetOffset
            ))
            status = accepted ? .navigated(hunk) : .failed(
                "The document changed before the hunk could be selected."
            )
            return accepted
        } catch let error as IncrementalDiffError {
            status = isLimitError(error)
                ? .limited(error.localizedDescription)
                : .failed(error.localizedDescription)
            return false
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    private func availableSnapshot() -> IncrementalDiffSnapshot? {
        guard let snapshot = snapshotProvider(), snapshot.fileURL != nil else {
            status = .unavailable
            return nil
        }
        return snapshot
    }

    private func diff(_ snapshot: IncrementalDiffSnapshot) throws -> IncrementalDiffResult {
        try IncrementalDiff.compare(
            baseline: snapshot.baselineText,
            current: snapshot.currentText,
            limits: limits
        )
    }

    private func cachedDiff(
        _ snapshot: IncrementalDiffSnapshot
    ) throws -> IncrementalDiffResult {
        let key = DiffCacheKey(
            documentID: snapshot.documentID,
            fileURL: snapshot.fileURL,
            baselineText: snapshot.baselineText,
            currentText: snapshot.currentText,
            bufferRevision: snapshot.bufferRevision,
            hasExternalConflict: snapshot.hasExternalConflict
        )
        if key == cachedKey, let cachedResult { return try cachedResult.get() }
        let result: Result<IncrementalDiffResult, IncrementalDiffError>
        do {
            result = .success(try diff(snapshot))
        } catch let error as IncrementalDiffError {
            result = .failure(error)
        } catch {
            // IncrementalDiff currently throws only its public typed error.
            result = .failure(.staleHunk)
        }
        cachedKey = key
        cachedResult = result
        return try result.get()
    }

    private func isLimitError(_ error: IncrementalDiffError) -> Bool {
        switch error {
        case .textTooLarge, .tooManyLines, .matrixTooLarge, .tooManyHunks:
            return true
        case .staleHunk, .invalidSelection:
            return false
        }
    }

    private static func matches(
        _ snapshot: IncrementalDiffSnapshot, model: AppModel
    ) -> Bool {
        guard model.paneLayout.activePaneIndex == snapshot.paneIndex,
              model.paneLayout.panes.indices.contains(snapshot.paneIndex),
              model.paneLayout.panes[snapshot.paneIndex].viewID == snapshot.viewID,
              let document = model.activeDocument(inPaneAt: snapshot.paneIndex)
        else { return false }
        return document.sessionDocumentID == snapshot.documentID
            && document.fileURL == snapshot.fileURL
            && IncrementalDiff.exactlyEqual(
                document.savedText, snapshot.baselineText
            )
            && IncrementalDiff.exactlyEqual(
                document.buffer.text, snapshot.currentText
            )
            && document.buffer.revision == snapshot.bufferRevision
            && document.externalConflict == nil
    }

    private struct DiffCacheKey: Equatable {
        let documentID: String
        let fileURL: URL?
        let baselineText: String
        let currentText: String
        let bufferRevision: UInt64
        let hasExternalConflict: Bool

        static func == (left: Self, right: Self) -> Bool {
            left.documentID == right.documentID
                && left.fileURL == right.fileURL
                && IncrementalDiff.exactlyEqual(
                    left.baselineText, right.baselineText
                )
                && IncrementalDiff.exactlyEqual(
                    left.currentText, right.currentText
                )
                && left.bufferRevision == right.bufferRevision
                && left.hasExternalConflict == right.hasExternalConflict
        }
    }
}
