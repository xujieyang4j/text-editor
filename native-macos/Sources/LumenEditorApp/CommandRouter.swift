import Combine
import Foundation
import LumenEditorCore
import AppKit

private final class EventMonitorCleanup {
    var monitor: Any?

    func replace(with monitor: Any?) {
        if let current = self.monitor { NSEvent.removeMonitor(current) }
        self.monitor = monitor
    }

    func clear() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// The application state visible to command routing.  Keeping this as a value
/// type lets AppModel, workspace, and settings integrations supply snapshots
/// without coupling the router to any of those concrete types.
struct CommandRoutingContext: Equatable, Sendable {
    var availableRequirements: CommandRequirements
    var keyBindingContext: KeyBindingContext

    init(
        availableRequirements: CommandRequirements,
        keyBindingContext: KeyBindingContext = .editor
    ) {
        self.availableRequirements = availableRequirements
        self.keyBindingContext = keyBindingContext
    }

    init(
        hasDocument: Bool = false,
        hasSavedDocument: Bool = false,
        hasWorkspace: Bool = false,
        hasSelection: Bool = false,
        hasFindResults: Bool = false,
        hasNavigationHistory: Bool = false,
        hasClosedTab: Bool = false,
        hasGitRepository: Bool = false,
        hasLanguageService: Bool = false,
        keyBindingContext: KeyBindingContext = .editor
    ) {
        var requirements: CommandRequirements = []
        if hasDocument || hasSavedDocument { requirements.insert(.document) }
        if hasSavedDocument { requirements.insert(.savedDocument) }
        if hasWorkspace { requirements.insert(.workspace) }
        if hasSelection { requirements.insert(.selection) }
        if hasFindResults { requirements.insert(.findResults) }
        if hasNavigationHistory { requirements.insert(.navigationHistory) }
        if hasClosedTab { requirements.insert(.closedTab) }
        if hasGitRepository { requirements.insert(.gitRepository) }
        if hasLanguageService { requirements.insert(.languageService) }
        self.init(
            availableRequirements: requirements,
            keyBindingContext: keyBindingContext
        )
    }

    func missingRequirements(for command: CommandDescriptor) -> CommandRequirements {
        command.requirements.subtracting(availableRequirements)
    }

    func satisfies(_ command: CommandDescriptor) -> Bool {
        missingRequirements(for: command).isEmpty
    }
}

enum CommandHandlerEnablement: Equatable, Sendable {
    case enabled
    case disabled(reason: String? = nil)
}

enum CommandDisabledReason: Equatable, Sendable {
    case missingRequirements(CommandRequirements)
    case handler(reason: String?)
}

/// A catalog command is unsupported until a real handler has been registered.
/// This is intentionally distinct from a supported command that is temporarily
/// disabled by application state.
enum CommandRouteStatus: Equatable, Sendable {
    case enabled
    case disabled(CommandDisabledReason)
    case unsupported

    var isEnabled: Bool {
        self == .enabled
    }

    var isSupported: Bool {
        self != .unsupported
    }
}

struct CommandInvocation: Sendable {
    let command: CommandDescriptor
    let context: CommandRoutingContext
}

struct CommandHandlerToken: Hashable, Sendable {
    fileprivate let id: UUID
    let commandID: String
}

enum CommandRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case unknownCommand(String)
    case alreadyRegistered(String)

    var errorDescription: String? {
        switch self {
        case let .unknownCommand(commandID):
            return "Unknown command: \(commandID)"
        case let .alreadyRegistered(commandID):
            return "A handler is already registered for: \(commandID)"
        }
    }
}

enum CommandExecutionResult {
    case executed
    case visiblePanel(commandID: String)
    case noChange(commandID: String)
    case unavailable(CommandRouteStatus)
    case unknownCommand(String)
    case failed(commandID: String, error: any Error)

    var didExecuteSuccessfully: Bool {
        switch self {
        case .executed, .visiblePanel:
            true
        default:
            false
        }
    }
}

/// Structured command feedback stays localizable until the presentation layer
/// renders it with the current runtime locale.
enum CommandPresentation: Equatable, Sendable {
    case app(AppPresentationText)
    /// File/session failures retain both their semantic title and message so
    /// menu, keyboard, and command-palette dispatch can render them in the
    /// locale that is active when feedback is shown.
    case appModel(AppModelIssue)
    case workspace(WorkspacePresentationIssue.Message)
    case workspaceSearch(WorkspaceSearchPresentationIssue.Message)
    case navigation(NavigationPresentationIssue)
    case git(GitPresentationIssue)
    case languageTool(LanguageToolPresentationIssue)
    case languageServer(LanguageServerPresentationIssue)
    case securityScope(SecurityScopedAccessError, context: String?)
    case plugin(PluginPresentationIssue.Message)
    case pluginWorker(PluginWorkerRuntimeIssue.Message)
    case sublimeImport(SublimeImportPresentationIssue.Message)

    init(_ verbatim: String) {
        self = .app(.verbatim(verbatim))
    }
}

/// A handler can throw this internal signal when invocation was valid but did
/// not successfully apply an operation. The router translates it into a typed
/// execution result instead of reporting the route as executed.
enum CommandHandlerSignal: Error, Equatable, LocalizedError, Sendable {
    case visiblePanel
    case noChange
    case unavailable(reason: String?)
    case unsupported
    case failedPresentation(CommandPresentation)

    static func failed(_ message: String) -> Self {
        .failedPresentation(CommandPresentation(message))
    }

    static func failed(_ presentation: CommandPresentation) -> Self {
        .failedPresentation(presentation)
    }

    var errorDescription: String? {
        switch self {
        case .visiblePanel: return "The command opened a visible panel."
        case .noChange: return "The command did not change the current state."
        case let .unavailable(reason): return reason ?? "The command is unavailable."
        case .unsupported: return "The command is not supported."
        case let .failedPresentation(presentation):
            return switch presentation {
            case let .app(content):
                EditorLocale.enUS.localizedPresentation(content)
            case let .appModel(issue):
                EditorLocale.enUS.localizedAppModelIssue(issue.content)
            case let .workspace(content):
                EditorLocale.enUS.localizedWorkspaceIssue(content)
            case let .workspaceSearch(content):
                EditorLocale.enUS.localizedWorkspaceSearchIssue(content)
            case let .navigation(issue):
                EditorLocale.enUS.localizedNavigationIssue(issue.content)
            case let .git(issue):
                EditorLocale.enUS.localizedGitIssue(issue.content)
            case let .languageTool(issue):
                EditorLocale.enUS.localizedLanguageToolIssue(issue.content)
            case let .languageServer(issue):
                EditorLocale.enUS.localizedLanguageServerIssue(issue.content)
            case let .securityScope(error, context):
                EditorLocale.enUS.localizedSecurityScopedAccessIssue(
                    error, context: context
                )
            case let .plugin(content):
                EditorLocale.enUS.localizedPluginIssue(content)
            case let .pluginWorker(content):
                EditorLocale.enUS.localizedPluginWorkerIssue(content)
            case let .sublimeImport(content):
                EditorLocale.enUS.localizedSublimeImportIssue(content)
            }
        }
    }
}

enum CommandExecutionObservation: Equatable, Sendable {
    case began
    case finished(succeeded: Bool)
}

struct RoutedCommandSearchResult: Identifiable, Equatable, Sendable {
    let command: CommandDescriptor
    let fuzzyResult: FuzzyResult
    let status: CommandRouteStatus
    let effectiveKeyBinding: CommandKeyBinding?
    let shortcutHint: String?

    var id: String { command.id }
}

/// One dispatch point for menus, keyboard bindings, and the command palette.
///
/// Integrations register closures that capture their AppModel/workspace/settings
/// owner.  The router has no knowledge of those APIs and can therefore be wired
/// incrementally as each native feature stabilizes.
@MainActor
final class CommandRouter: ObservableObject {
    typealias Handler = @MainActor (CommandInvocation) async throws -> Void
    typealias Enablement = @MainActor (CommandRoutingContext) -> CommandHandlerEnablement
    typealias ExecutionObserver = @MainActor (
        _ commandID: String, _ observation: CommandExecutionObservation
    ) -> Void

    private struct RegisteredHandler {
        let token: CommandHandlerToken
        let enablement: Enablement
        let handler: Handler
    }

    @Published private(set) var revision: UInt = 0
    private(set) var keyBindingOverrides: [KeyBindingOverride]
    private var handlers: [String: RegisteredHandler] = [:]
    private var executionObserver: ExecutionObserver?

    init(keyBindingOverrides: [KeyBindingOverride] = []) {
        self.keyBindingOverrides = keyBindingOverrides
    }

    @discardableResult
    func register(
        _ commandID: String,
        replaceExisting: Bool = false,
        enablement: @escaping Enablement = { _ in .enabled },
        handler: @escaping Handler
    ) throws -> CommandHandlerToken {
        guard CommandCatalog.command(id: commandID) != nil else {
            throw CommandRegistrationError.unknownCommand(commandID)
        }
        if handlers[commandID] != nil, !replaceExisting {
            throw CommandRegistrationError.alreadyRegistered(commandID)
        }

        let token = CommandHandlerToken(id: UUID(), commandID: commandID)
        handlers[commandID] = RegisteredHandler(
            token: token,
            enablement: enablement,
            handler: handler
        )
        noteRoutesChanged()
        return token
    }

    /// Removes a registration only when the token still owns the route.  An old
    /// token therefore cannot unregister a replacement handler.
    @discardableResult
    func unregister(_ token: CommandHandlerToken) -> Bool {
        guard handlers[token.commandID]?.token == token else { return false }
        handlers[token.commandID] = nil
        noteRoutesChanged()
        return true
    }

    func removeAllHandlers() {
        guard !handlers.isEmpty else { return }
        handlers.removeAll()
        noteRoutesChanged()
    }

    func setKeyBindingOverrides(_ overrides: [KeyBindingOverride]) {
        keyBindingOverrides = overrides
        noteRoutesChanged()
    }

    /// Installs one window-scoped observer used by macro recording. The
    /// observer sees only commands that passed requirement/enablement checks,
    /// and receives both dispatch start and the final success disposition.
    func setExecutionObserver(_ observer: ExecutionObserver?) {
        executionObserver = observer
    }

    func effectiveKeyBinding(
        for commandID: String,
        context: KeyBindingContext? = nil
    ) -> CommandKeyBinding? {
        CommandCatalog.keyBinding(
            for: commandID,
            overrides: keyBindingOverrides,
            context: context
        )
    }

    func status(
        for commandID: String,
        context: CommandRoutingContext
    ) -> CommandRouteStatus? {
        guard let command = CommandCatalog.command(id: commandID) else { return nil }
        return status(for: command, context: context)
    }

    func search(
        _ query: String,
        locale: CommandLocale,
        context: CommandRoutingContext
    ) -> [RoutedCommandSearchResult] {
        CommandCatalog.search(query, locale: locale).map { result in
            let binding = effectiveKeyBinding(
                for: result.command.id,
                context: context.keyBindingContext
            )
            return RoutedCommandSearchResult(
                command: result.command,
                fuzzyResult: result.result,
                status: status(for: result.command, context: context),
                effectiveKeyBinding: binding,
                shortcutHint: shortcutHint(
                    for: result.command,
                    effectiveBinding: binding,
                    context: context.keyBindingContext
                )
            )
        }
    }

    /// Availability is checked again here even when the caller already checked
    /// it for presentation.  This prevents stale palette/menu state from running
    /// a disabled command and prevents unimplemented commands from reporting
    /// success.
    func execute(
        _ commandID: String,
        context: CommandRoutingContext
    ) async -> CommandExecutionResult {
        guard let command = CommandCatalog.command(id: commandID) else {
            return .unknownCommand(commandID)
        }
        guard let registration = handlers[commandID] else {
            return .unavailable(.unsupported)
        }

        let currentStatus = status(
            for: command,
            registration: registration,
            context: context
        )
        guard currentStatus.isEnabled else {
            return .unavailable(currentStatus)
        }

        executionObserver?(commandID, .began)
        let result: CommandExecutionResult
        do {
            try await registration.handler(
                CommandInvocation(command: command, context: context)
            )
            result = .executed
        } catch let signal as CommandHandlerSignal {
            switch signal {
            case .visiblePanel:
                result = .visiblePanel(commandID: commandID)
            case .noChange:
                result = .noChange(commandID: commandID)
            case let .unavailable(reason):
                result = .unavailable(.disabled(.handler(reason: reason)))
            case .unsupported:
                result = .unavailable(.unsupported)
            case .failedPresentation:
                result = .failed(commandID: commandID, error: signal)
            }
        } catch {
            result = .failed(commandID: commandID, error: error)
        }
        executionObserver?(
            commandID, .finished(succeeded: result.didExecuteSuccessfully)
        )
        return result
    }

    private func status(
        for command: CommandDescriptor,
        context: CommandRoutingContext
    ) -> CommandRouteStatus {
        guard let registration = handlers[command.id] else { return .unsupported }
        return status(for: command, registration: registration, context: context)
    }

    private func status(
        for command: CommandDescriptor,
        registration: RegisteredHandler,
        context: CommandRoutingContext
    ) -> CommandRouteStatus {
        let missing = context.missingRequirements(for: command)
        guard missing.isEmpty else {
            return .disabled(.missingRequirements(missing))
        }
        switch registration.enablement(context) {
        case .enabled:
            return .enabled
        case let .disabled(reason):
            return .disabled(.handler(reason: reason))
        }
    }

    private func shortcutHint(
        for command: CommandDescriptor,
        effectiveBinding: CommandKeyBinding?,
        context: KeyBindingContext
    ) -> String? {
        if let effectiveBinding {
            return effectiveBinding.sequence
                .map(\.displayString)
                .joined(separator: " ")
        }

        // An applicable nil override explicitly unbinds and hides the hint.
        let hasExplicitUnbind = keyBindingOverrides.last(where: { override in
            override.commandID == command.id
                && (override.when == nil || override.when == context)
        }).map { $0.binding == nil } ?? false
        return hasExplicitUnbind ? nil : command.displayShortcut
    }

    private func noteRoutesChanged() {
        revision &+= 1
    }
}

enum CommandKeyRoutingResult: Equatable, Sendable {
    case noMatch
    case awaitingChord(sequence: [CommandKeyEquivalent], deadline: TimeInterval)
    case command(String)
    case defaultConflict([String])
    case ambiguous([String])
}

/// Deterministic runtime state for user overrides and multi-key chords.
/// Callers provide a monotonic timestamp, so timeout behaviour is testable and
/// does not require a timer, AppKit event, or AppModel.
struct CommandKeyboardState: Equatable, Sendable {
    static let defaultChordTimeout: TimeInterval = 1.5

    private(set) var overrides: [KeyBindingOverride]
    private(set) var pendingSequence: [CommandKeyEquivalent] = []
    private(set) var deadline: TimeInterval?
    let chordTimeout: TimeInterval

    init(
        overrides: [KeyBindingOverride] = [],
        chordTimeout: TimeInterval = CommandKeyboardState.defaultChordTimeout
    ) {
        self.overrides = overrides
        self.chordTimeout = max(0, chordTimeout)
    }

    var isAwaitingChord: Bool {
        !pendingSequence.isEmpty
    }

    var pendingDisplayString: String? {
        guard isAwaitingChord else { return nil }
        return pendingSequence.map(\.displayString).joined(separator: " ")
    }

    mutating func setOverrides(_ overrides: [KeyBindingOverride]) {
        self.overrides = overrides
        cancelPendingChord()
    }

    @discardableResult
    mutating func expire(at timestamp: TimeInterval) -> Bool {
        guard let deadline, timestamp >= deadline else { return false }
        cancelPendingChord()
        return true
    }

    mutating func cancelPendingChord() {
        pendingSequence = []
        deadline = nil
    }

    mutating func process(
        _ keyEquivalent: CommandKeyEquivalent,
        at timestamp: TimeInterval,
        context: KeyBindingContext = .editor
    ) -> CommandKeyRoutingResult {
        _ = expire(at: timestamp)
        let candidate = pendingSequence + [Self.normalized(keyEquivalent)]
        let matches = activeBindings(context: context).filter { binding in
            Self.isPrefix(candidate, of: binding.sequence)
        }

        guard !matches.isEmpty else {
            cancelPendingChord()
            return .noMatch
        }

        let completed = matches.filter { $0.sequence.count == candidate.count }
        // A complete one-stroke binding must not pre-empt a longer chord that
        // starts with the same key. This is especially important for imported
        // user overrides (for example Cmd-K, Cmd-S), which intentionally shadow
        // a catalog default bound to the prefix alone.
        let hasLongerMatch = matches.contains { $0.sequence.count > candidate.count }
        if completed.count == 1, !hasLongerMatch {
            cancelPendingChord()
            return .command(completed[0].commandID)
        }
        if completed.count > 1, !hasLongerMatch {
            cancelPendingChord()
            let commandIDs = completed.map(\.commandID)
            if isUnmodifiedDefaultF2Conflict(commandIDs, context: context) {
                return .defaultConflict(commandIDs)
            }
            return .ambiguous(commandIDs)
        }

        pendingSequence = candidate
        let nextDeadline = timestamp + chordTimeout
        deadline = nextDeadline
        return .awaitingChord(sequence: candidate, deadline: nextDeadline)
    }

    private func activeBindings(
        context: KeyBindingContext
    ) -> [(commandID: String, sequence: [CommandKeyEquivalent])] {
        CommandCatalog.all.compactMap { command in
            let override = overrides.last(where: { override in
                override.commandID == command.id
                    && (override.when == nil || override.when == context)
            })
            let binding: CommandKeyBinding?
            if let override {
                binding = override.binding
            } else {
                binding = command.defaultKeyEquivalent.map(CommandKeyBinding.init)
            }
            guard let binding, !binding.sequence.isEmpty else {
                return nil
            }
            return (
                commandID: command.id,
                sequence: binding.sequence.map(Self.normalized)
            )
        }
    }

    private func isUnmodifiedDefaultF2Conflict(
        _ commandIDs: [String],
        context: KeyBindingContext
    ) -> Bool {
        let f2Commands = Set(["next-bookmark", "lsp-rename"])
        guard Set(commandIDs) == f2Commands else { return false }
        let hasExplicitOverride = commandIDs.contains { commandID in
            overrides.last { override in
                override.commandID == commandID
                    && (override.when == nil || override.when == context)
            } != nil
        }
        return !hasExplicitOverride
    }

    private static func normalized(
        _ keyEquivalent: CommandKeyEquivalent
    ) -> CommandKeyEquivalent {
        CommandKeyEquivalent(
            key: keyEquivalent.key.lowercased(),
            modifiers: keyEquivalent.modifiers
        )
    }

    private static func isPrefix(
        _ candidate: [CommandKeyEquivalent],
        of sequence: [CommandKeyEquivalent]
    ) -> Bool {
        guard candidate.count <= sequence.count else { return false }
        return zip(candidate, sequence).allSatisfy { pair in
            pair.0 == pair.1
        }
    }
}

/// AppKit bridge for catalog shortcuts and imported multi-key chords. SwiftUI
/// menus still own the ordinary macOS menu key equivalents; this monitor fills
/// the gaps for palette-only commands and user overrides without taking text
/// input away from NSTextView.
@MainActor
final class CommandKeyboardController: ObservableObject {
    typealias ContextProvider = @MainActor () -> CommandRoutingContext
    typealias ResultHandler = @MainActor (CommandExecutionResult) -> Void
    typealias Availability = @MainActor () -> Bool

    @Published private(set) var pendingChord: String?

    private let router: CommandRouter
    private let contextProvider: ContextProvider
    private let resultHandler: ResultHandler
    private let availability: Availability
    private var state: CommandKeyboardState
    private let localMonitorCleanup = EventMonitorCleanup()

    init(
        router: CommandRouter,
        overrides: [KeyBindingOverride] = [],
        context: @escaping ContextProvider,
        isAvailable: @escaping Availability = { true },
        resultHandler: @escaping ResultHandler = { _ in }
    ) {
        self.router = router
        self.contextProvider = context
        self.availability = isAvailable
        self.resultHandler = resultHandler
        self.state = CommandKeyboardState(overrides: overrides)
    }

    func start() {
        guard localMonitor == nil else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event) == true ? nil : event
            }
        }
        localMonitor = monitor
    }

    func stop() {
        localMonitorCleanup.clear()
        localMonitor = nil
        state.cancelPendingChord()
        pendingChord = nil
    }

    func setOverrides(_ overrides: [KeyBindingOverride]) {
        router.setKeyBindingOverrides(overrides)
        state.setOverrides(overrides)
        pendingChord = nil
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard availability() else { return false }
        guard !event.isARepeat else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            NotificationCenter.default.post(
                name: .lumenSelectNumberedTab, object: number
            )
            return true
        }
        guard let key = Self.keyEquivalent(for: event) else { return false }
        let context = contextProvider()
        switch state.process(
            key,
            at: ProcessInfo.processInfo.systemUptime,
            context: context.keyBindingContext
        ) {
        case .noMatch:
            pendingChord = nil
            return false
        case let .awaitingChord(sequence, _):
            pendingChord = sequence.map(\.displayString).joined(separator: " " )
            return true
        case .ambiguous:
            pendingChord = nil
            NSSound.beep()
            return true
        case let .defaultConflict(commandIDs):
            pendingChord = nil
            guard let commandID = resolveDefaultConflict(
                commandIDs, context: context
            ) else { return false }
            execute(commandID, context: context)
            return true
        case let .command(commandID):
            pendingChord = nil
            guard router.status(for: commandID, context: context)?.isEnabled == true else {
                return false
            }
            execute(commandID, context: context)
            return true
        }
    }

    /// Resolves only the catalog's intentional F2 collision. Route status is
    /// evaluated against the current document context here, rather than from
    /// the window-wide language-service bit used to build that context.
    func resolveDefaultConflict(
        _ commandIDs: [String], context: CommandRoutingContext
    ) -> String? {
        guard Set(commandIDs) == Set(["next-bookmark", "lsp-rename"]) else {
            return nil
        }
        if router.status(for: "lsp-rename", context: context) == .enabled {
            return "lsp-rename"
        }
        if router.status(for: "next-bookmark", context: context) == .enabled {
            return "next-bookmark"
        }
        return nil
    }

    private func execute(_ commandID: String, context: CommandRoutingContext) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.router.execute(commandID, context: context)
            self.resultHandler(result)
        }
    }

    private static func keyEquivalent(for event: NSEvent) -> CommandKeyEquivalent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mapped: CommandKeyModifiers = []
        if modifiers.contains(.command) { mapped.insert(.command) }
        if modifiers.contains(.control) { mapped.insert(.control) }
        if modifiers.contains(.option) { mapped.insert(.option) }
        if modifiers.contains(.shift) { mapped.insert(.shift) }

        let key: String
        switch event.keyCode {
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 51: key = "backspace"
        case 117: key = "delete"
        case 36, 76: key = "return"
        case 49: key = "space"
        case 120: key = "f2"
        case 99: key = "f3"
        case 118: key = "f4"
        case 96: key = "f5"
        case 97: key = "f6"
        case 98: key = "f7"
        case 100: key = "f8"
        case 101: key = "f9"
        case 109: key = "f10"
        case 103: key = "f11"
        case 111: key = "f12"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  characters.utf16.count == 1 else { return nil }
            key = characters.lowercased()
        }
        // Plain printable keys belong to the editor and IME. Catalog routing
        // accepts them only when a command/control/option modifier is present.
        if mapped.isEmpty, !key.hasPrefix("f") { return nil }
        return CommandKeyEquivalent(key: key, modifiers: mapped)
    }

    private var localMonitor: Any? {
        get { localMonitorCleanup.monitor }
        set { localMonitorCleanup.replace(with: newValue) }
    }
}

extension Notification.Name {
    static let lumenSelectNumberedTab = Notification.Name(
        "com.lumen.editor.native.select-numbered-tab"
    )
}
