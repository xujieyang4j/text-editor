import Combine
import Foundation
import LumenEditorCore

enum MacroSnippetStatus: Equatable, Sendable {
    case idle
    case recording(stepCount: Int)
    case recorded(stepCount: Int)
    case replaying(name: String?)
    case saved(name: String)
    case failed
}

struct MacroSnippetPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case snippetSessionEnded
        case macroUnavailable
        case noWorkspaceOpen
        case macroCouldNotBeSaved
        case savedMacrosCouldNotBeLoaded
        case snippetUnavailable
        case snippetCouldNotBeInserted
        case macroCouldNotRun
        case macroRecordingStopped
        case verbatim(String)
    }

    enum Message: Equatable, Sendable {
        case app(english: String, chinese: String)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English compatibility for command routing and existing clients.
    /// Views resolve `titleContent` and `content` with the live app locale.
    var title: String {
        EditorLocale.enUS.localizedMacroSnippetIssueTitle(titleContent)
    }

    var message: String {
        EditorLocale.enUS.localizedMacroSnippetIssue(content)
    }

    init(id: UUID = UUID(), title: Title, message: Message) {
        self.id = id
        titleContent = title
        content = message
    }
}

struct MacroPickerItem: Identifiable, Equatable, Sendable {
    let macro: SavedMacro
    let fuzzyResult: FuzzyResult

    var id: String { macro.name }
    var label: String { macro.name }
    var detail: String {
        let count = macro.replayOperations.count
        return "\(count) step\(count == 1 ? "" : "s")"
    }
}

struct SnippetPickerItem: Identifiable, Equatable, Sendable {
    let snippet: SnippetDefinition
    let fuzzyResult: FuzzyResult

    var id: String { snippet.id }
    var label: String {
        switch snippet.source {
        case .builtIn: snippet.label
        case .project: "Project: \(snippet.label)"
        case let .plugin(_, name): "\(name): \(snippet.label)"
        }
    }
}

/// Fresh editor state used to validate snippet-session identity before every
/// keystroke. The shell can construct it without exposing AppModel itself.
struct SnippetDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let text: String
    let selection: SelectionSet
    let revision: UInt64

    init(
        documentID: String,
        viewID: EditorViewID = .default,
        text: String,
        selection: SelectionSet,
        revision: UInt64
    ) {
        self.documentID = documentID
        self.viewID = viewID
        self.text = text
        self.selection = selection
        self.revision = revision
    }
}

enum MacroSnippetPresentation: Equatable, Sendable {
    case saveName
    case savedMacros
    case snippets
}

enum MacroSnippetControllerError: Error, Equatable, LocalizedError, Sendable {
    case noRecordedMacro
    case noWorkspace
    case noSavedMacros
    case noSnippets
    case invalidMacroName
    case replayAlreadyInProgress
    case replayOperationLimit(maximum: Int)
    case routedCommandFailed(String)
    case transactionRejected
    case legacySnapshotUnavailable
    case snippetUnavailable

    var errorDescription: String? {
        switch self {
        case .noRecordedMacro: "No recorded macro is available."
        case .noWorkspace: "Open a workspace first."
        case .noSavedMacros: "No saved macros are available for this workspace."
        case .noSnippets: "No snippets are available for the active document."
        case .invalidMacroName: "Enter a non-empty macro name."
        case .replayAlreadyInProgress: "A macro is already being replayed."
        case let .replayOperationLimit(maximum):
            "Macro replay exceeded the \(maximum)-operation limit."
        case let .routedCommandFailed(commandID):
            "Macro command ‘\(commandID)’ could not be executed."
        case .transactionRejected: "A macro edit no longer applies to the active document."
        case .legacySnapshotUnavailable:
            "The application did not provide a legacy snapshot replacement capability."
        case .snippetUnavailable: "The selected snippet is no longer available."
        }
    }
}

/// Native application coordinator for the five Electron macro/snippet routes.
///
/// The shell injects command routing and transaction application separately.
/// This lets replay preserve strict ordering while every edit/snippet is still
/// validated by the current document's revision-aware transaction boundary.
@MainActor
final class MacroSnippetController: ObservableObject {
    typealias WorkspaceProvider = @MainActor () -> URL?
    typealias StoreProvider = @MainActor (URL) -> MacroStore
    typealias CommandDispatcher = @MainActor (MacroCommand) async -> Bool
    typealias TransactionApplier = @MainActor (TextTransaction) -> Bool
    typealias DocumentSnapshotProvider = @MainActor () -> SnippetDocumentSnapshot?
    typealias SelectionApplier = @MainActor (SelectionSet) -> Bool
    typealias LegacyTextApplier = @MainActor (String) -> Bool
    typealias SnippetPlanner = @MainActor (String) throws -> SnippetInsertionPlan?
    typealias TriggerSnippetPlanner = @MainActor (String, String) throws -> SnippetInsertionPlan?
    typealias ProjectSnippetsProvider = @MainActor () -> [ProjectSnippet]
    typealias PluginSnippetsProvider = @MainActor () -> [PluginSnippetRoute]
    typealias LanguageProvider = @MainActor () -> String?

    nonisolated static let commandIDs = [
        "record-macro", "run-macro", "save-macro",
        "run-saved-macro", "insert-snippet"
    ]
    static let builtInSnippets: [SnippetDefinition] = [
        SnippetDefinition(
            id: "built-in:console-log", label: "Console log",
            text: "console.log(${1:value})", source: .builtIn
        ),
        SnippetDefinition(
            id: "built-in:function", label: "Function",
            text: "function ${1:name}(${2:args}) {\n  ${0}\n}", source: .builtIn
        ),
        SnippetDefinition(
            id: "built-in:try-catch", label: "Try / catch",
            text: "try {\n  ${1}\n} catch (error) {\n  ${2}\n}", source: .builtIn
        )
    ]

    @Published private(set) var status: MacroSnippetStatus = .idle
    @Published private(set) var presentation: MacroSnippetPresentation?
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshPresentedItems()
        }
    }
    @Published private(set) var macroItems: [MacroPickerItem] = []
    @Published private(set) var snippetItems: [SnippetPickerItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var issue: MacroSnippetPresentationIssue?
    @Published private(set) var snippetInsertion: SnippetInsertionPlan?

    private let limits: MacroLimits
    private let workspace: WorkspaceProvider
    private let makeStore: StoreProvider
    private let dispatchCommand: CommandDispatcher
    private let applyTransaction: TransactionApplier
    private let documentSnapshot: DocumentSnapshotProvider
    private let applySelection: SelectionApplier
    private let applyLegacyText: LegacyTextApplier?
    private let planSnippet: SnippetPlanner
    private let planTriggerSnippet: TriggerSnippetPlanner?
    private let projectSnippets: ProjectSnippetsProvider
    private let pluginSnippets: PluginSnippetsProvider
    private let currentLanguage: LanguageProvider
    private var recording: MacroRecording
    private var lastMacro: [MacroStep] = []
    private var loadedMacros: [SavedMacro] = []
    private var replayDepth = 0
    private var recordedCommandDispatchDepth = 0
    private struct PendingRoutedCommand {
        let command: MacroCommand?
        let recordsOnSuccess: Bool
    }
    private var pendingRoutedCommands: [PendingRoutedCommand] = []
    private var snippetSession: SnippetSession?
    private var snippetSessionViewID: EditorViewID?
    private var snippetSessionRevision: UInt64?
    private var applyingSnippetInsertion = false

    init(
        limits: MacroLimits = .standard,
        workspace: @escaping WorkspaceProvider = { nil },
        makeStore: StoreProvider? = nil,
        dispatchCommand: @escaping CommandDispatcher,
        applyTransaction: @escaping TransactionApplier,
        documentSnapshot: @escaping DocumentSnapshotProvider = { nil },
        applySelection: @escaping SelectionApplier = { _ in false },
        applyLegacyText: LegacyTextApplier? = nil,
        planSnippet: @escaping SnippetPlanner,
        planTriggerSnippet: TriggerSnippetPlanner? = nil,
        projectSnippets: @escaping ProjectSnippetsProvider = { [] },
        pluginSnippets: @escaping PluginSnippetsProvider = { [] },
        currentLanguage: @escaping LanguageProvider = { nil }
    ) {
        self.limits = limits
        self.workspace = workspace
        self.makeStore = makeStore ?? {
            MacroStore(workspaceURL: $0, limits: limits)
        }
        self.dispatchCommand = dispatchCommand
        self.applyTransaction = applyTransaction
        self.documentSnapshot = documentSnapshot
        self.applySelection = applySelection
        self.applyLegacyText = applyLegacyText
        self.planSnippet = planSnippet
        self.planTriggerSnippet = planTriggerSnippet
        self.projectSnippets = projectSnippets
        self.pluginSnippets = pluginSnippets
        self.currentLanguage = currentLanguage
        recording = MacroRecording(limits: limits)
    }

    var isRecording: Bool { recording.isRecording }
    var isReplaying: Bool { replayDepth > 0 }
    var recordedSteps: [MacroStep] { recording.isRecording ? recording.steps : lastMacro }
    var isPresented: Bool { presentation != nil }
    var hasActiveSnippetSession: Bool { snippetSession?.isActive == true }
    var activeSnippetPlaceholder: SnippetPlaceholder? { snippetSession?.activePlaceholder }

    /// Call at the same boundary that receives native editor transactions.
    /// Replay-generated transactions are suppressed, as are empty selections.
    func record(transaction: TextTransaction) {
        guard recording.isRecording, replayDepth == 0,
              recordedCommandDispatchDepth == 0, !transaction.edits.isEmpty else { return }
        do {
            try recording.record(edits: transaction.edits)
            status = .recording(stepCount: recording.steps.count)
        } catch {
            stopAfterRecordingFailure(error)
        }
    }

    /// Ready for NativeTextEditor's `onTextChange` closure. Only accepted user
    /// transactions are recorded; replay and command-generated changes remain
    /// suppressed by the controller's execution guards.
    @discardableResult
    func applyAndRecord(_ transaction: TextTransaction) -> Bool {
        guard !applyingSnippetInsertion else { return applyTransaction(transaction) }
        let transactionToApply: TextTransaction
        var candidateSession = snippetSession
        if var candidate = candidateSession, candidate.isActive,
           let snapshot = documentSnapshot(), snapshot.documentID == candidate.documentID,
           snapshot.viewID == snippetSessionViewID,
           snapshot.revision == snippetSessionRevision {
            do {
                transactionToApply = try candidate.incorporatingUserTransaction(
                    transaction, in: snapshot.text,
                    maximumMirrorEdits: limits.maximumEditsPerStep
                )
                candidateSession = candidate
            } catch {
                candidate.cancel()
                snippetSession = candidate
                present(error, title: .snippetSessionEnded)
                return false
            }
        } else {
            candidateSession = nil
            transactionToApply = transaction
        }
        let applied = applyTransaction(transactionToApply)
        if applied {
            snippetSession = candidateSession
            if snippetSession == nil {
                snippetSessionViewID = nil
                snippetInsertion = nil
            }
            snippetSessionRevision = documentSnapshot()?.revision
            record(transaction: transactionToApply)
        }
        return applied
    }

    /// NativeTextEditor key hook: consume Tab/Shift-Tab while a snippet session
    /// is active and route the resulting selection through the injected model
    /// boundary. Forward Tab on the last placeholder lands at `${0}` and ends.
    @discardableResult
    func navigateSnippetPlaceholder(_ direction: SnippetNavigationDirection) -> Bool {
        guard let snapshot = documentSnapshot() else {
            _ = cancelSnippetSession()
            return false
        }
        guard var candidate = snippetSession, candidate.isActive else {
            return expandTriggerOnForwardTab(direction, snapshot: snapshot)
        }
        guard snapshot.documentID == candidate.documentID,
              snapshot.viewID == snippetSessionViewID,
              snapshot.revision == snippetSessionRevision else {
            _ = cancelSnippetSession()
            return expandTriggerOnForwardTab(direction, snapshot: snapshot)
        }
        switch candidate.navigate(direction) {
        case .inactive:
            return false
        case let .selection(selection), let .final(selection):
            guard applySelection(selection) else { return false }
            snippetSession = candidate
            return true
        }
    }

    private func expandTriggerOnForwardTab(
        _ direction: SnippetNavigationDirection,
        snapshot: SnippetDocumentSnapshot
    ) -> Bool {
        guard direction == .next, snapshot.selection.ranges.count == 1,
              snapshot.selection.main.isEmpty,
              let trigger = SnippetEngine.triggerBeforeCursor(
                in: snapshot.text, cursor: snapshot.selection.main.head
              ) else { return false }
        return expandTrigger(trigger)
    }

    /// NativeTextEditor Escape and AppModel active-document-change hook.
    @discardableResult
    func cancelSnippetSession() -> Bool {
        guard snippetSession?.isActive == true else { return false }
        snippetSession?.cancel()
        snippetSession = nil
        snippetSessionViewID = nil
        snippetSessionRevision = nil
        snippetInsertion = nil
        return true
    }

    func activeEditorDidChange(documentID: String?, viewID: EditorViewID?) {
        guard snippetSession?.documentID != documentID
                || snippetSessionViewID != viewID else { return }
        _ = cancelSnippetSession()
    }

    /// Revision-aware lifecycle hook. Call this from the active editor snapshot
    /// observer so undo/redo or a command that bypasses `applyAndRecord` ends a
    /// stale placeholder session instead of navigating obsolete ranges.
    func activeEditorDidChange(
        documentID: String?, viewID: EditorViewID?, revision: UInt64?
    ) {
        guard snippetSession?.documentID != documentID
                || snippetSessionViewID != viewID
                || snippetSessionRevision != revision else { return }
        _ = cancelSnippetSession()
    }

    /// Records a typed command without exposing an arbitrary command string.
    /// Production routing should normally use `observeRoutedCommand`, which
    /// also suppresses the command's generated transaction.
    func record(command: MacroCommand) {
        guard recording.isRecording, replayDepth == 0 else { return }
        do {
            try recording.record(command: command)
            status = .recording(stepCount: recording.steps.count)
        } catch {
            stopAfterRecordingFailure(error)
        }
    }

    func observeRoutedCommand(
        _ commandID: String, observation: CommandExecutionObservation
    ) {
        let command = MacroCommand(rawValue: commandID)
        switch observation {
        case .began:
            pendingRoutedCommands.append(PendingRoutedCommand(
                command: command,
                recordsOnSuccess: command != nil
                    && recordedCommandDispatchDepth == 0 && replayDepth == 0
            ))
            if command != nil { recordedCommandDispatchDepth += 1 }
        case let .finished(succeeded):
            guard let pending = pendingRoutedCommands.popLast() else { return }
            if pending.command != nil {
                recordedCommandDispatchDepth = max(0, recordedCommandDispatchDepth - 1)
            }
            guard succeeded, pending.recordsOnSuccess,
                  replayDepth == 0, let command = pending.command else { return }
            record(command: command)
        }
    }

    /// Recommended routing seam for ordinary recordable commands. It records
    /// the typed command before normal dispatch when no router observer owns
    /// that responsibility, and suppresses transactions emitted by dispatch.
    @discardableResult
    func dispatchRecording(_ command: MacroCommand) async -> Bool {
        let recordsOnSuccess = recordedCommandDispatchDepth == 0 && replayDepth == 0
        recordedCommandDispatchDepth += 1
        defer { recordedCommandDispatchDepth -= 1 }
        let succeeded = await dispatchCommand(command)
        if succeeded, recordsOnSuccess { record(command: command) }
        return succeeded
    }

    @discardableResult
    func toggleRecording() -> Bool {
        issue = nil
        if recording.isRecording {
            lastMacro = recording.stop()
            status = .recorded(stepCount: lastMacro.count)
            return false
        }
        recording.start()
        lastMacro = []
        status = .recording(stepCount: 0)
        return true
    }

    @discardableResult
    func runLastMacro() async -> Bool {
        let steps = recording.isRecording ? recording.steps : lastMacro
        guard !steps.isEmpty else {
            present(MacroSnippetControllerError.noRecordedMacro, title: .macroUnavailable)
            return false
        }
        return await replay(
            steps.map { step in
                switch step {
                case let .command(command): .command(command)
                case let .edits(edits): .edits(edits)
                }
            },
            name: nil
        )
    }

    @discardableResult
    func presentSaveMacro() -> Bool {
        guard workspace() != nil else {
            present(MacroSnippetControllerError.noWorkspace, title: .noWorkspaceOpen)
            return false
        }
        let steps = recording.isRecording ? recording.steps : lastMacro
        guard !steps.isEmpty else {
            present(MacroSnippetControllerError.noRecordedMacro, title: .macroUnavailable)
            return false
        }
        query = ""
        presentation = .saveName
        selectedIndex = nil
        issue = nil
        return true
    }

    @discardableResult
    func saveMacro(named rawName: String) -> Bool {
        guard let root = workspace() else {
            present(MacroSnippetControllerError.noWorkspace, title: .noWorkspaceOpen)
            return false
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = recording.isRecording ? recording.steps : lastMacro
        guard !name.isEmpty, name.utf16.count <= limits.maximumNameUTF16Length,
              !name.utf8.contains(0), !steps.isEmpty else {
            present(
                name.isEmpty ? MacroSnippetControllerError.invalidMacroName
                    : MacroSnippetControllerError.noRecordedMacro,
                title: .macroCouldNotBeSaved
            )
            return false
        }
        do {
            _ = try makeStore(root).save(SavedMacro(
                name: name,
                commands: steps.compactMap(\.command),
                steps: steps
            ))
            presentation = nil
            status = .saved(name: name)
            issue = nil
            return true
        } catch {
            present(error, title: .macroCouldNotBeSaved)
            return false
        }
    }

    @discardableResult
    func presentSavedMacros(query initialQuery: String = "") -> Bool {
        guard let root = workspace() else {
            present(MacroSnippetControllerError.noWorkspace, title: .noWorkspaceOpen)
            return false
        }
        do {
            loadedMacros = try makeStore(root).load()
            guard !loadedMacros.isEmpty else {
                present(MacroSnippetControllerError.noSavedMacros, title: .macroUnavailable)
                return false
            }
            presentation = .savedMacros
            query = initialQuery
            issue = nil
            refreshMacroItems()
            return true
        } catch {
            present(error, title: .savedMacrosCouldNotBeLoaded)
            return false
        }
    }

    @discardableResult
    func runSavedMacro(id: String) async -> Bool {
        guard let macro = loadedMacros.first(where: { $0.name == id }) else {
            present(MacroSnippetControllerError.noSavedMacros, title: .macroUnavailable)
            return false
        }
        presentation = nil
        return await replay(macro.replayOperations, name: macro.name)
    }

    @discardableResult
    func presentSnippets(query initialQuery: String = "") -> Bool {
        let snippets = availableSnippets()
        guard !snippets.isEmpty else {
            present(MacroSnippetControllerError.noSnippets, title: .snippetUnavailable)
            return false
        }
        presentation = .snippets
        query = initialQuery
        issue = nil
        refreshSnippetItems(from: snippets)
        return true
    }

    @discardableResult
    func insertSnippet(id: String) -> Bool {
        guard let snippet = availableSnippets().first(where: { $0.id == id }) else {
            present(MacroSnippetControllerError.snippetUnavailable, title: .snippetUnavailable)
            return false
        }
        return insert(snippet)
    }

    /// Tab-trigger path: project and enabled plug-in snippets only, exact
    /// trigger match, optional exact language scope, first declaration wins.
    @discardableResult
    func expandTrigger(_ trigger: String) -> Bool {
        guard !trigger.isEmpty, let snippet = triggerSnippets().first(where: {
            $0.trigger == trigger && ($0.scope == nil || $0.scope == currentLanguage())
        }) else { return false }
        guard let planTriggerSnippet else { return insert(snippet) }
        do {
            guard let plan = try planTriggerSnippet(trigger, snippet.text),
                  applySnippetPlan(plan) else {
                throw MacroSnippetControllerError.transactionRejected
            }
            presentation = nil
            issue = nil
            return true
        } catch {
            present(error, title: .snippetCouldNotBeInserted)
            return false
        }
    }

    func dismissPresentation() {
        presentation = nil
        selectedIndex = nil
    }

    func selectItem(at index: Int) {
        let count = presentation == .savedMacros ? macroItems.count : snippetItems.count
        guard (0..<count).contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        let count = presentation == .savedMacros ? macroItems.count : snippetItems.count
        guard count > 0 else { selectedIndex = nil; return }
        let current = selectedIndex.flatMap { (0..<count).contains($0) ? $0 : nil } ?? 0
        selectedIndex = ((current + delta) % count + count) % count
    }

    @discardableResult
    func acceptSelection() async -> Bool {
        guard let selectedIndex else { return false }
        switch presentation {
        case .savedMacros:
            guard macroItems.indices.contains(selectedIndex) else { return false }
            return await runSavedMacro(id: macroItems[selectedIndex].id)
        case .snippets:
            guard snippetItems.indices.contains(selectedIndex) else { return false }
            return insertSnippet(id: snippetItems[selectedIndex].id)
        case .saveName, .none:
            return false
        }
    }

    func dismissIssue() { issue = nil }

    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {}
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            for commandID in Self.commandIDs {
                tokens.append(try router.register(
                    commandID,
                    replaceExisting: replaceExisting,
                    enablement: { [weak self] context in
                        guard let self else { return .disabled(reason: "Macro controller unavailable") }
                        if self.isReplaying { return .disabled(reason: "A macro is being replayed") }
                        if ["save-macro", "run-saved-macro"].contains(commandID),
                           self.workspace() == nil {
                            return .disabled(reason: "No workspace")
                        }
                        return context.availableRequirements.contains(.document)
                            ? .enabled : .disabled(reason: "No active document")
                    }
                ) { [weak self] _ in
                    guard let self else {
                        throw CommandHandlerSignal.unavailable(
                            reason: "Macro controller unavailable"
                        )
                    }
                    await prepareForCommand()
                    switch commandID {
                    case "record-macro": _ = self.toggleRecording()
                    case "run-macro":
                        guard await self.runLastMacro() else {
                            throw CommandHandlerSignal.noChange
                        }
                    case "save-macro":
                        guard self.presentSaveMacro() else {
                            throw CommandHandlerSignal.failed(
                                self.issue?.message ?? "No macro is available to save."
                            )
                        }
                    case "run-saved-macro":
                        guard self.presentSavedMacros() else {
                            throw CommandHandlerSignal.failed(
                                self.issue?.message ?? "No saved macro is available."
                            )
                        }
                    case "insert-snippet":
                        guard self.presentSnippets() else {
                            throw CommandHandlerSignal.failed(
                                self.issue?.message ?? "No snippet is available."
                            )
                        }
                    default:
                        throw CommandHandlerSignal.unsupported
                    }
                })
            }
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    private func replay(_ operations: [MacroReplayOperation], name: String?) async -> Bool {
        guard replayDepth == 0 else {
            present(MacroSnippetControllerError.replayAlreadyInProgress, title: .macroCouldNotRun)
            return false
        }
        guard operations.count <= limits.maximumSteps else {
            present(
                MacroSnippetControllerError.replayOperationLimit(maximum: limits.maximumSteps),
                title: .macroCouldNotRun
            )
            return false
        }
        replayDepth += 1
        status = .replaying(name: name)
        defer { replayDepth -= 1 }

        for operation in operations {
            let succeeded: Bool
            switch operation {
            case let .command(command):
                succeeded = await dispatchCommand(command)
                if !succeeded {
                    present(
                        MacroSnippetControllerError.routedCommandFailed(command.commandID),
                        title: .macroCouldNotRun
                    )
                }
            case let .edits(edits):
                let expectedRevision = documentSnapshot()?.revision
                if let transaction = try? TextTransaction(
                    edits: edits, expectedRevision: expectedRevision
                ) {
                    succeeded = applyTransaction(transaction)
                } else {
                    succeeded = false
                }
                if !succeeded {
                    present(MacroSnippetControllerError.transactionRejected, title: .macroCouldNotRun)
                }
            case let .legacyText(text):
                succeeded = applyLegacyText?(text) ?? false
                if !succeeded {
                    present(MacroSnippetControllerError.legacySnapshotUnavailable, title: .macroCouldNotRun)
                }
            }
            if !succeeded { return false }
        }
        status = recording.isRecording
            ? .recording(stepCount: recording.steps.count) : .idle
        issue = nil
        return true
    }

    private func insert(_ snippet: SnippetDefinition) -> Bool {
        do {
            guard let plan = try planSnippet(snippet.text),
                  applySnippetPlan(plan) else {
                throw MacroSnippetControllerError.transactionRejected
            }
            presentation = nil
            issue = nil
            return true
        } catch {
            present(error, title: .snippetCouldNotBeInserted)
            return false
        }
    }

    private func applySnippetPlan(_ plan: SnippetInsertionPlan) -> Bool {
        guard let snapshot = documentSnapshot() else { return false }
        applyingSnippetInsertion = true
        let applied = applyAndRecord(plan.transaction)
        applyingSnippetInsertion = false
        guard applied else { return false }
        record(transaction: plan.transaction)
        snippetInsertion = plan
        if plan.placeholders.isEmpty {
            snippetSession = nil
            snippetSessionViewID = nil
            snippetSessionRevision = nil
        } else {
            snippetSession = SnippetSession(
                documentID: snapshot.documentID,
                placeholders: plan.placeholders,
                finalPosition: plan.finalPosition
            )
            snippetSessionViewID = snapshot.viewID
            snippetSessionRevision = documentSnapshot()?.revision
        }
        return true
    }

    private func availableSnippets() -> [SnippetDefinition] {
        Self.builtInSnippets + triggerSnippets()
    }

    private func triggerSnippets() -> [SnippetDefinition] {
        let plugins = pluginSnippets().map { route in
            SnippetDefinition(
                id: route.id, label: route.label, text: route.text,
                trigger: route.trigger, scope: route.scope,
                source: .plugin(id: route.pluginID, name: route.pluginName)
            )
        }
        let projects = projectSnippets().enumerated().map { index, snippet in
            SnippetDefinition(
                id: "project:\(index)", label: snippet.label, text: snippet.text,
                trigger: snippet.trigger, scope: snippet.scope, source: .project
            )
        }
        return plugins + projects
    }

    private func refreshPresentedItems() {
        switch presentation {
        case .savedMacros: refreshMacroItems()
        case .snippets: refreshSnippetItems(from: availableSnippets())
        case .saveName, .none: break
        }
    }

    private func refreshMacroItems() {
        macroItems = CommandFuzzyMatcher.filter(
            query: query, items: loadedMacros, key: \.name
        ).map { MacroPickerItem(macro: $0.item, fuzzyResult: $0.result) }
        selectedIndex = macroItems.isEmpty ? nil : 0
    }

    private func refreshSnippetItems(from snippets: [SnippetDefinition]) {
        let rows = snippets.map { snippet in
            (snippet: snippet, label: displayLabel(for: snippet))
        }
        snippetItems = CommandFuzzyMatcher.filter(
            query: query, items: rows, key: \.label
        ).map { SnippetPickerItem(snippet: $0.item.snippet, fuzzyResult: $0.result) }
        selectedIndex = snippetItems.isEmpty ? nil : 0
    }

    private func displayLabel(for snippet: SnippetDefinition) -> String {
        switch snippet.source {
        case .builtIn: snippet.label
        case .project: "Project: \(snippet.label)"
        case let .plugin(_, name): "\(name): \(snippet.label)"
        }
    }

    private func stopAfterRecordingFailure(_ error: any Error) {
        lastMacro = recording.stop()
        present(error, title: .macroRecordingStopped)
    }

    private func present(
        _ error: any Error, title: MacroSnippetPresentationIssue.Title
    ) {
        status = .failed
        issue = MacroSnippetPresentationIssue(
            title: title, message: Self.presentationMessage(for: error)
        )
    }

    static func presentationMessage(
        for error: any Error
    ) -> MacroSnippetPresentationIssue.Message {
        if let error = error as? MacroSnippetControllerError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedControllerError(error)
            )
        }
        if let error = error as? MacroStoreError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedMacroStoreError(error)
            )
        }
        if let error = error as? MacroSanitizerError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedMacroSanitizerError(error)
            )
        }
        if let error = error as? MacroRecordingError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedMacroRecordingError(error)
            )
        }
        if let error = error as? SnippetError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedSnippetError(error)
            )
        }
        if let error = error as? SnippetSessionError {
            return .app(
                english: error.localizedDescription,
                chinese: localizedSnippetSessionError(error)
            )
        }
        return .verbatim(error.localizedDescription)
    }

    private static func localizedControllerError(
        _ error: MacroSnippetControllerError
    ) -> String {
        switch error {
        case .noRecordedMacro: return "没有可用的已录制宏。"
        case .noWorkspace: return "请先打开一个工作区。"
        case .noSavedMacros: return "此工作区没有可用的已保存宏。"
        case .noSnippets: return "当前文档没有可用的代码片段。"
        case .invalidMacroName: return "请输入非空的宏名称。"
        case .replayAlreadyInProgress: return "已有宏正在重放。"
        case let .replayOperationLimit(maximum):
            return "宏重放超过 \(maximum) 项操作的上限。"
        case let .routedCommandFailed(commandID):
            return "宏中的命令无法执行：\(commandID)"
        case .transactionRejected:
            return "宏编辑已不再适用于当前文档。"
        case .legacySnapshotUnavailable:
            return "应用未提供旧版快照替换功能。"
        case .snippetUnavailable:
            return "所选代码片段已不可用。"
        }
    }

    private static func localizedMacroStoreError(_ error: MacroStoreError) -> String {
        switch error {
        case let .invalidWorkspace(url):
            return "宏工作区不是安全的本地目录：\(url.path)"
        case let .workspaceChanged(url):
            return "已授权的宏工作区发生了变化：\(url.path)"
        case .symbolicLinkEncountered:
            return ".lumen-macros.json 不能是符号链接。"
        case .notARegularFile:
            return ".lumen-macros.json 必须是普通文件。"
        case .hardLinkedFile:
            return ".lumen-macros.json 不能有多个硬链接。"
        case .wrongOwner:
            return ".lumen-macros.json 必须归当前用户所有。"
        case let .fileTooLarge(actual, maximum):
            return "宏数据使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case .changedDuringRead:
            return "读取宏文件时文件发生了变化。"
        case .changedDuringWrite:
            return "保存宏文件时文件发生了变化。"
        case .invalidMacro:
            return "宏名称或步骤无效。"
        case let .fileSystem(operation, code):
            return "宏文件操作“\(operation)”失败（errno \(code)）。"
        }
    }

    private static func localizedMacroSanitizerError(
        _ error: MacroSanitizerError
    ) -> String {
        switch error {
        case let .serializedDataTooLarge(actual, maximum):
            return "宏数据使用了 \(actual) 个字节；上限为 \(maximum) 个字节。"
        case .invalidJSON: return "宏文件不是有效的 JSON。"
        case .invalidRoot: return "宏文件必须包含 JSON 数组。"
        case .invalidMacro: return "宏无效或超出资源限制。"
        }
    }

    private static func localizedMacroRecordingError(
        _ error: MacroRecordingError
    ) -> String {
        switch error {
        case .editStepRejected:
            return "无法将此编辑操作表示为安全的宏步骤。"
        case let .recordingLimitReached(maximum):
            return "宏录制已达到 \(maximum) 个步骤的上限。"
        }
    }

    private static func localizedSnippetError(_ error: SnippetError) -> String {
        switch error {
        case let .templateTooLarge(actual, maximum):
            return "代码片段使用了 \(actual) 个 UTF-16 代码单元；上限为 \(maximum) 个。"
        case let .tooManyPlaceholders(actual, maximum):
            return "代码片段有 \(actual) 个占位符；上限为 \(maximum) 个。"
        case let .placeholderIndexTooLarge(index, maximum):
            return "代码片段占位符 \(index) 超过 \(maximum) 的编号上限。"
        case .invalidSelection:
            return "代码片段选择范围位于当前文档之外。"
        }
    }

    private static func localizedSnippetSessionError(
        _ error: SnippetSessionError
    ) -> String {
        switch error {
        case .invalidPlaceholderRange:
            return "代码片段占位符位于文档范围之外。"
        case .editCannotBeMapped:
            return "无法在当前代码片段会话中映射此编辑。"
        case let .mirrorLimitExceeded(actual, maximum):
            return "代码片段镜像需要 \(actual) 项编辑；上限为 \(maximum) 项。"
        }
    }
}

extension MacroSnippetController {
    /// Ready-to-wire adapter for the existing AppModel transaction boundary.
    /// Command routing remains injected because the owning composition root
    /// must decide which handlers and preflight checks apply.
    static func connected(
        model: AppModel,
        workspace: @escaping WorkspaceProvider,
        dispatchCommand: @escaping CommandDispatcher,
        projectSnippets: @escaping ProjectSnippetsProvider = { [] },
        pluginSnippets: @escaping PluginSnippetsProvider = { [] }
    ) -> MacroSnippetController {
        MacroSnippetController(
            workspace: workspace,
            dispatchCommand: dispatchCommand,
            applyTransaction: { transaction in
                guard let document = model.selectedDocument,
                      transaction.expectedRevision == nil
                        || transaction.expectedRevision == document.buffer.revision
                else { return false }
                let guarded: TextTransaction
                do {
                    guarded = try TextTransaction(
                        edits: transaction.edits, selection: transaction.selection,
                        expectedRevision: document.buffer.revision
                    )
                } catch {
                    return false
                }
                return model.apply(
                    guarded, to: document, inPaneAt: model.paneLayout.activePaneIndex
                )
            },
            documentSnapshot: {
                guard let document = model.selectedDocument else { return nil }
                return SnippetDocumentSnapshot(
                    documentID: document.sessionDocumentID,
                    viewID: model.paneLayout.activeViewID,
                    text: document.buffer.text,
                    selection: model.selection(
                        for: document.sessionDocumentID,
                        viewID: model.paneLayout.activeViewID
                    ),
                    revision: document.buffer.revision
                )
            },
            applySelection: { selection in
                guard let document = model.selectedDocument else { return false }
                return model.setSelections(
                    selection, for: document,
                    inPaneAt: model.paneLayout.activePaneIndex
                )
            },
            applyLegacyText: { text in
                guard text.utf16.count <= MacroLimits.standard.maximumLegacyTextUTF16Length
                else { return false }
                guard let document = model.selectedDocument,
                      let transaction = try? TextTransaction(
                        edits: [TextEdit(
                            from: 0, to: document.buffer.utf16Length, insert: text
                        )],
                        expectedRevision: document.buffer.revision
                      ) else { return false }
                return model.apply(
                    transaction, to: document, inPaneAt: model.paneLayout.activePaneIndex
                )
            },
            planSnippet: { template in
                guard let document = model.selectedDocument else { return nil }
                return try SnippetEngine.insertionPlan(
                    template: template,
                    documentUTF16Length: document.buffer.utf16Length,
                    selection: model.selection(
                        for: document.sessionDocumentID,
                        viewID: model.paneLayout.activeViewID
                    ),
                    expectedRevision: document.buffer.revision
                )
            },
            planTriggerSnippet: { trigger, template in
                guard let document = model.selectedDocument else { return nil }
                let selection = model.selection(
                    for: document.sessionDocumentID,
                    viewID: model.paneLayout.activeViewID
                )
                guard selection.ranges.count == 1, selection.main.isEmpty else { return nil }
                return try SnippetEngine.triggerExpansionPlan(
                    trigger: trigger, template: template,
                    documentText: document.buffer.text,
                    cursor: selection.main.head,
                    expectedRevision: document.buffer.revision
                )
            },
            projectSnippets: projectSnippets,
            pluginSnippets: pluginSnippets,
            currentLanguage: { model.selectedDocument?.language }
        )
    }
}
