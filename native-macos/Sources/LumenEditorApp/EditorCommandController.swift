import Foundation
import LumenEditorCore

enum EditorCommandControllerResult: Equatable, Sendable {
    case applied
    case noChange
    case unavailable
    case unsupported
    case failed(String)

    var didApply: Bool { self == .applied }
}

/// Thin application bridge for Foundation-only editing command plans.
///
/// The shell injects a synchronous snapshot of the active document/view and a
/// single atomic apply closure. This keeps command logic independent of
/// AppModel while ensuring every text command is one DocumentBuffer undo step.
@MainActor
final class EditorCommandController {
    struct SelectionHistoryKey: Hashable, Sendable {
        let documentID: String
        let viewID: EditorViewID
    }

    typealias SnapshotProvider = @MainActor () -> EditingCommandSnapshot?
    typealias SelectionHistoryKeyProvider = @MainActor () -> SelectionHistoryKey?
    typealias TransactionApplier = @MainActor (TextTransaction) -> Bool
    typealias PrepareParsedSyntax = @MainActor (EditingCommandSnapshot) async -> Void
    typealias SuccessfulSelectionChange = @MainActor (
        _ commandID: String, _ before: EditingCommandSnapshot, _ after: SelectionSet
    ) -> Void

    static let commandIDs = EditingCommands.recognizedCommandIDs

    private let snapshot: SnapshotProvider
    private let selectionHistoryKey: SelectionHistoryKeyProvider
    private let apply: TransactionApplier
    private let prepareParsedSyntax: PrepareParsedSyntax
    private let successfulSelectionChange: SuccessfulSelectionChange
    private let limits: EditingCommandLimits
    private let selectionHistoryCapacity: Int
    private struct HistoryState {
        var planner: EditingCommandPlanner
        var documentRevision: UInt64?
    }

    private var histories: [SelectionHistoryKey: HistoryState] = [:]
    private let fallbackHistoryKey = SelectionHistoryKey(
        documentID: "__editor-command-controller__", viewID: .default
    )

    init(
        limits: EditingCommandLimits = .standard,
        selectionHistoryCapacity: Int = 100,
        snapshot: @escaping SnapshotProvider,
        selectionHistoryKey: @escaping SelectionHistoryKeyProvider = { nil },
        apply: @escaping TransactionApplier,
        prepareParsedSyntax: @escaping PrepareParsedSyntax = { _ in },
        successfulSelectionChange: @escaping SuccessfulSelectionChange = { _, _, _ in }
    ) {
        self.snapshot = snapshot
        self.selectionHistoryKey = selectionHistoryKey
        self.apply = apply
        self.prepareParsedSyntax = prepareParsedSyntax
        self.successfulSelectionChange = successfulSelectionChange
        self.limits = limits
        self.selectionHistoryCapacity = selectionHistoryCapacity
    }

    var canUndoSelection: Bool { currentPlanner.selectionHistory.canUndo }
    var canRedoSelection: Bool { currentPlanner.selectionHistory.canRedo }

    @discardableResult
    func dispatch(commandID: String) -> EditorCommandControllerResult {
        guard Self.commandIDs.contains(commandID) else { return .unsupported }
        guard let snapshot = snapshot() else { return .unavailable }
        let key = currentHistoryKey
        do {
            var candidatePlanner = planner(for: key, revision: snapshot.expectedRevision)
            switch try candidatePlanner.plan(commandID: commandID, snapshot: snapshot) {
            case let .transaction(transaction):
                guard apply(transaction) else { return .noChange }
                histories[key] = HistoryState(
                    planner: candidatePlanner,
                    documentRevision: transaction.edits.isEmpty
                        ? snapshot.expectedRevision
                        : snapshot.expectedRevision.map { $0 &+ 1 }
                )
                if transaction.edits.isEmpty, let after = transaction.selection {
                    successfulSelectionChange(commandID, snapshot, after)
                }
                return .applied
            case .noChange:
                return .noChange
            case .unsupported:
                return .unsupported
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func dispatchPrepared(commandID: String) async -> EditorCommandControllerResult {
        guard Self.commandIDs.contains(commandID) else { return .unsupported }
        if Self.parserAwareCommandIDs.contains(commandID), let before = snapshot() {
            await prepareParsedSyntax(before)
        }
        // Capture again after the asynchronous parse. If the user edited or
        // switched documents, the revision-keyed provider will either supply
        // the new exact snapshot or deliberately fall back.
        return dispatch(commandID: commandID)
    }

    /// Feed native mouse/keyboard selection changes into the same history used
    /// by Selection Undo/Redo. Rejected/no-op selections are not recorded.
    func recordSelectionChange(
        documentID: String, viewID: EditorViewID,
        documentRevision: UInt64,
        from previous: SelectionSet, to next: SelectionSet
    ) {
        let key = SelectionHistoryKey(documentID: documentID, viewID: viewID)
        var planner = planner(for: key, revision: documentRevision)
        planner.recordSelectionChange(from: previous, to: next)
        histories[key] = HistoryState(
            planner: planner, documentRevision: documentRevision
        )
    }

    func resetSelectionHistory(documentID: String, viewID: EditorViewID) {
        histories[SelectionHistoryKey(documentID: documentID, viewID: viewID)] = nil
    }

    private var currentHistoryKey: SelectionHistoryKey {
        selectionHistoryKey() ?? fallbackHistoryKey
    }

    private var currentPlanner: EditingCommandPlanner {
        planner(for: currentHistoryKey, revision: snapshot()?.expectedRevision)
    }

    private func planner(
        for key: SelectionHistoryKey, revision: UInt64?
    ) -> EditingCommandPlanner {
        guard let state = histories[key], state.documentRevision == revision else {
            return EditingCommandPlanner(
                limits: limits, selectionHistoryCapacity: selectionHistoryCapacity
            )
        }
        return state.planner
    }

    /// Register every recognized editor command with the shared router.
    /// The planner currently supplies bounded lexical fallbacks for structural
    /// commands, so every recognized command remains reachable without a parser.
    @discardableResult
    func registerCommands(on router: CommandRouter) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            for commandID in Self.commandIDs.sorted() {
                tokens.append(try router.register(
                    commandID,
                    replaceExisting: true,
                    enablement: { [weak self] _ in
                        guard let self else { return .disabled(reason: nil) }
                        return self.snapshot() == nil
                            ? .disabled(reason: "No active document") : .enabled
                    }
                ) { [weak self] _ in
                    guard let self else {
                        throw CommandHandlerSignal.unavailable(
                            reason: "Editor command controller unavailable"
                        )
                    }
                    switch await self.dispatchPrepared(commandID: commandID) {
                    case .applied:
                        return
                    case .noChange:
                        throw CommandHandlerSignal.noChange
                    case .unavailable:
                        throw CommandHandlerSignal.unavailable(reason: "No active document")
                    case .unsupported:
                        throw CommandHandlerSignal.unsupported
                    case let .failed(message):
                        throw CommandHandlerSignal.failed(message)
                    }
                })
            }
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    /// Production adapter for AppModel's active pane. Callers may pass settings
    /// snapshots without coupling this controller to SettingsController.
    convenience init(
        model: AppModel,
        settings: @escaping @MainActor () -> EditorSettings,
        parsedSyntax: @escaping @MainActor (
            String, String, UInt64, Int, Int, Bool
        ) -> ParsedSyntaxSnapshot? = { _, _, _, _, _, _ in nil },
        prepareParsedSyntax: @escaping PrepareParsedSyntax = { _ in },
        successfulSelectionChange: @escaping SuccessfulSelectionChange = { _, _, _ in }
    ) {
        self.init(
            snapshot: {
                guard let document = model.selectedDocument else { return nil }
                let viewID = model.paneLayout.activeViewID
                let currentSettings = settings()
                let indentation = EditorConfig.resolveIndentation(
                    config: document.editorConfig?.properties,
                    detected: IndentationPreferences(
                        indentSize: currentSettings.tabSize,
                        insertSpaces: currentSettings.insertSpaces
                    ),
                    defaultTabWidth: currentSettings.tabSize
                )
                return EditingCommandSnapshot(
                    text: document.buffer.text,
                    selection: document.selectionSet(for: viewID) ?? .cursor(at: 0),
                    language: document.language,
                    tabWidth: indentation.tabWidth,
                    indentWidth: indentation.indentSize,
                    insertSpaces: indentation.insertSpaces,
                    expectedRevision: document.buffer.revision,
                    parsedSyntax: parsedSyntax(
                        document.buffer.text, document.language, document.buffer.revision,
                        indentation.tabWidth, indentation.indentSize,
                        indentation.insertSpaces
                    )
                )
            },
            selectionHistoryKey: {
                guard let document = model.selectedDocument else { return nil }
                return SelectionHistoryKey(
                    documentID: document.sessionDocumentID,
                    viewID: model.paneLayout.activeViewID
                )
            },
            apply: { transaction in
                guard let document = model.selectedDocument else { return false }
                return model.apply(
                    transaction,
                    to: document,
                    inPaneAt: model.paneLayout.activePaneIndex
                )
            },
            prepareParsedSyntax: prepareParsedSyntax,
            successfulSelectionChange: successfulSelectionChange
        )
    }

    private static let parserAwareCommandIDs: Set<String> = [
        "goto-matching-bracket", "select-matching-bracket",
        "select-parent-syntax", "expand-selection", "reindent-selection"
    ]
}
