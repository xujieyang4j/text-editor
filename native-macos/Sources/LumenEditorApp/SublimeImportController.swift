import Combine
@preconcurrency import Foundation
import LumenEditorCore

/// The five declarative Sublime formats supported by the native application.
/// Importing a build system only stores its declaration. Execution remains a
/// separate BuildController request with its own tool-approval boundary.
enum SublimeImportKind: String, CaseIterable, Equatable, Sendable {
    case project
    case settings
    case keymap
    case snippet
    case build

    var commandID: String {
        switch self {
        case .project: "import-sublime-project"
        case .settings: "import-sublime-settings"
        case .keymap: "import-sublime-keymap"
        case .snippet: "import-sublime-snippet"
        case .build: "import-sublime-build"
        }
    }

    var displayName: String {
        switch self {
        case .project: "Project"
        case .settings: "Settings"
        case .keymap: "Keymap"
        case .snippet: "Snippet"
        case .build: "Build System"
        }
    }

    var requiresWorkspace: Bool {
        self == .keymap || self == .snippet || self == .build
    }
}

/// A standalone build-system preview retains the picker-approved source URL
/// without adding filesystem authority to the Core declaration type.
struct SublimeBuildImport: Equatable, Sendable {
    let sourceURL: URL
    let system: SublimeBuildSystemImport

    init(sourceURL: URL, system: SublimeBuildSystemImport) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.system = system
    }
}

/// Bytes selected and read by the application shell. The import controller
/// intentionally has no URL-reading API and cannot expand its filesystem
/// authority beyond the system picker used by the shell.
struct SublimeImportSource: Equatable, Sendable {
    let sourceURL: URL
    let data: Data

    init(sourceURL: URL, data: Data) {
        self.sourceURL = sourceURL
        self.data = data
    }
}

/// A type-safe preview. Callers never need to downcast an untyped payload, and
/// parsing one format cannot accidentally invoke another format's apply path.
enum SublimeImportPreview: Equatable, Sendable {
    case project(SublimeProjectImport)
    case settings(SublimeSettingsImport)
    case keymap(SublimeKeymapImport)
    case snippet(SublimeSnippetImport)
    case build(SublimeBuildImport)

    var kind: SublimeImportKind {
        switch self {
        case .project: .project
        case .settings: .settings
        case .keymap: .keymap
        case .snippet: .snippet
        case .build: .build
        }
    }

    var sourceURL: URL {
        switch self {
        case let .project(value): value.sourceURL
        case let .settings(value): value.sourceURL
        case let .keymap(value): value.sourceURL
        case let .snippet(value): value.sourceURL
        case let .build(value): value.sourceURL
        }
    }
}

/// The short-lived value rendered by a confirmation sheet. `token` is the
/// presentation identity and the only capability accepted by `confirm`.
struct SublimeImportPresentation: Identifiable, Equatable, Sendable {
    let token: UUID
    let preview: SublimeImportPreview
    let expiresAt: Date

    var id: UUID { token }
    var kind: SublimeImportKind { preview.kind }
    var sourceURL: URL { preview.sourceURL }

    var title: String { "Import Sublime \(kind.displayName)?" }

    var message: String {
        switch preview {
        case let .project(value):
            let roots = value.roots.count
            let builds = value.buildSystems.count
            let rootSuffix = roots == 1 ? "" : "s"
            let exclusionSuffix = value.exclusions.count == 1 ? "" : "s"
            let buildSuffix = builds == 1 ? "" : "s"
            return "Import \(roots) project root\(rootSuffix), \(value.exclusions.count) exclusion pattern\(exclusionSuffix), and \(builds) declarative build system\(buildSuffix)? Sublime plug-ins and code will not run."
        case let .settings(value):
            let suffix = value.changes.count == 1 ? "" : "s"
            return "Apply \(value.changes.count) supported setting change\(suffix)?"
        case let .keymap(value):
            let bindingSuffix = value.overrides.count == 1 ? "" : "s"
            let skipped = value.skipped == 1 ? "entry was" : "entries were"
            return "Import \(value.overrides.count) supported key binding\(bindingSuffix)? \(value.skipped) \(skipped) skipped."
        case let .snippet(value):
            let trigger = value.trigger.map { " (trigger: \($0))" } ?? ""
            return "Import snippet ‘\(value.label)’\(trigger)? Only declarative text, trigger, and scope are imported."
        case let .build(value):
            let argumentSuffix = value.system.arguments.isEmpty
                ? "" : " " + value.system.arguments.joined(separator: " ")
            return "Import declarative build system ‘\(value.system.name)’? Command: \(value.system.command)\(argumentSuffix). Importing will not run it; execution still requires separate approval."
        }
    }
}

enum SublimeImportStatus: Equatable, Sendable {
    case idle
    case requestingSource(SublimeImportKind)
    case parsing(SublimeImportKind)
    case awaitingConfirmation(SublimeImportKind)
    case applying(SublimeImportKind)
    case completed(SublimeImportKind)
    case cancelled(SublimeImportKind)
    case failed(SublimeImportKind)

    var kind: SublimeImportKind? {
        switch self {
        case .idle: nil
        case let .requestingSource(kind), let .parsing(kind),
             let .awaitingConfirmation(kind), let .applying(kind),
             let .completed(kind), let .cancelled(kind), let .failed(kind): kind
        }
    }
}

struct SublimeImportCompletion: Equatable, Sendable {
    let preview: SublimeImportPreview
    /// Roots actually validated and authorised by `ApplyProject`. This can be a
    /// subset of the lexical roots in a project preview. It is nil for all
    /// non-project imports.
    let projectRoots: [URL]?

    var kind: SublimeImportKind { preview.kind }
}

struct SublimeImportPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case noWorkspaceOpen
        case confirmationUnavailable
        case couldNotRead(SublimeImportKind)
        case couldNotApply(SublimeImportKind)
    }

    enum Message: Equatable, Sendable {
        case controller(SublimeImportControllerError)
        case parser(SublimeImportError)
        case production(SublimeImportProductionError)
        case projectSettingsStore(ProjectSettingsStoreError)
        case workspace(WorkspaceServiceError)
        case securityScopedAccess(SecurityScopedAccessError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English compatibility for diagnostics and controller-only tests.
    /// SwiftUI and command feedback resolve the typed values with the live locale.
    var title: String { EditorLocale.enUS.localizedSublimeImportIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedSublimeImportIssue(content) }

    init(id: UUID = UUID(), title: Title, content: Message) {
        self.id = id
        titleContent = title
        self.content = content
    }
}

enum SublimeImportControllerError: Error, Equatable, LocalizedError, Sendable {
    case workspaceRequired(SublimeImportKind)
    case noPendingConfirmation
    case invalidConfirmationToken
    case confirmationExpired
    case mismatchedPreview(expected: SublimeImportKind, actual: SublimeImportKind)
    case applyHandlerUnavailable(SublimeImportKind)
    case applyInProgress

    var errorDescription: String? {
        switch self {
        case let .workspaceRequired(kind):
            return "Open a workspace before importing a Sublime \(kind.displayName.lowercased())."
        case .noPendingConfirmation:
            return "There is no Sublime import awaiting confirmation."
        case .invalidConfirmationToken:
            return "The Sublime import confirmation token is invalid."
        case .confirmationExpired:
            return "The Sublime import preview has expired. Select the file again."
        case let .mismatchedPreview(expected, actual):
            return "The parser returned a \(actual.displayName.lowercased()) preview while importing \(expected.displayName.lowercased())."
        case let .applyHandlerUnavailable(kind):
            return "The application cannot apply a Sublime \(kind.displayName.lowercased()) import."
        case .applyInProgress:
            return "Another Sublime import is already being applied."
        }
    }
}

/// Coordinates selection, parsing, confirmation and application without
/// owning a file picker, a filesystem reader, or any application model.
///
/// The shell supplies picker-approved bytes through `RequestSource` (or calls
/// `prepareImport` directly) and supplies narrow, typed mutation capabilities.
/// No apply callback is reachable until a live one-shot token is confirmed.
@MainActor
final class SublimeImportController: ObservableObject {
    typealias RequestSource = @MainActor (SublimeImportKind) async throws -> SublimeImportSource?
    typealias CurrentSettings = @MainActor () -> EditorSettings
    typealias WorkspaceAvailability = @MainActor () -> Bool
    typealias ParseAction = (
        SublimeImportKind, SublimeImportSource, EditorSettings
    ) async throws -> SublimeImportPreview
    /// Must validate and authorise every accepted root. The return value is the
    /// exact set of roots that became available to the application.
    typealias ApplyProject = @MainActor (SublimeProjectImport) async throws -> [URL]
    typealias ApplySettings = @MainActor (SublimeSettingsImport) async throws -> Void
    typealias ApplyKeymap = @MainActor (SublimeKeymapImport) async throws -> Void
    typealias ApplySnippet = @MainActor (SublimeSnippetImport) async throws -> Void
    typealias ApplyBuild = @MainActor (SublimeBuildImport) async throws -> Void
    typealias PrepareForCommand = @MainActor () async -> Void
    typealias DidFinishRequest = @MainActor () -> Void
    typealias Clock = @MainActor () -> Date
    typealias MakeToken = @MainActor () -> UUID

    nonisolated static let commandIDs = SublimeImportKind.allCases.map(\.commandID)
    nonisolated static let defaultConfirmationLifetime: TimeInterval = 60

    @Published private(set) var status: SublimeImportStatus = .idle
    @Published private(set) var presentation: SublimeImportPresentation?
    @Published private(set) var completion: SublimeImportCompletion?
    @Published private(set) var issue: SublimeImportPresentationIssue?

    private let requestSourceAction: RequestSource
    private let currentSettings: CurrentSettings
    private let workspaceIsAvailable: WorkspaceAvailability
    private let parseAction: ParseAction
    private let applyProjectAction: ApplyProject
    private let applySettingsAction: ApplySettings
    private let applyKeymapAction: ApplyKeymap
    private let applySnippetAction: ApplySnippet
    private let applyBuildAction: ApplyBuild
    private let clock: Clock
    private let makeToken: MakeToken
    private let confirmationLifetime: TimeInterval
    private var operationGeneration: UInt64 = 0

    init(
        requestSource: @escaping RequestSource = { _ in nil },
        currentSettings: @escaping CurrentSettings = { .default },
        hasWorkspace: @escaping WorkspaceAvailability = { false },
        parse: @escaping ParseAction = SublimeImportController.defaultParse,
        applyProject: @escaping ApplyProject = { _ in
            throw SublimeImportControllerError.applyHandlerUnavailable(.project)
        },
        applySettings: @escaping ApplySettings = { _ in
            throw SublimeImportControllerError.applyHandlerUnavailable(.settings)
        },
        applyKeymap: @escaping ApplyKeymap = { _ in
            throw SublimeImportControllerError.applyHandlerUnavailable(.keymap)
        },
        applySnippet: @escaping ApplySnippet = { _ in
            throw SublimeImportControllerError.applyHandlerUnavailable(.snippet)
        },
        applyBuild: @escaping ApplyBuild = { _ in
            throw SublimeImportControllerError.applyHandlerUnavailable(.build)
        },
        confirmationLifetime: TimeInterval = SublimeImportController.defaultConfirmationLifetime,
        clock: @escaping Clock = Date.init,
        makeToken: @escaping MakeToken = UUID.init
    ) {
        precondition(confirmationLifetime > 0 && confirmationLifetime.isFinite)
        requestSourceAction = requestSource
        self.currentSettings = currentSettings
        workspaceIsAvailable = hasWorkspace
        parseAction = parse
        applyProjectAction = applyProject
        applySettingsAction = applySettings
        applyKeymapAction = applyKeymap
        applySnippetAction = applySnippet
        applyBuildAction = applyBuild
        self.confirmationLifetime = confirmationLifetime
        self.clock = clock
        self.makeToken = makeToken
    }

    var preview: SublimeImportPreview? { presentation?.preview }
    var confirmationToken: UUID? { presentation?.token }
    var isPresented: Bool { presentation != nil }

    var isBusy: Bool {
        switch status {
        case .requestingSource, .parsing, .applying: true
        default: false
        }
    }

    var statusMessage: String {
        switch status {
        case .idle: "Ready to import from Sublime Text."
        case let .requestingSource(kind): "Choose a Sublime \(kind.displayName.lowercased()) file."
        case let .parsing(kind): "Reading Sublime \(kind.displayName.lowercased()) preview…"
        case let .awaitingConfirmation(kind): "Review the Sublime \(kind.displayName.lowercased()) preview."
        case let .applying(kind): "Applying Sublime \(kind.displayName.lowercased())…"
        case let .completed(kind): "Imported Sublime \(kind.displayName.lowercased())."
        case let .cancelled(kind): "Cancelled Sublime \(kind.displayName.lowercased()) import."
        case let .failed(kind): "Sublime \(kind.displayName.lowercased()) import failed."
        }
    }

    /// Requests picker-approved bytes from the shell, then parses them. A nil
    /// source is an ordinary user cancellation and never becomes an error.
    @discardableResult
    func requestImport(_ kind: SublimeImportKind) async -> Bool {
        guard canStart(kind) else { return false }
        let generation = beginOperation(kind, status: .requestingSource(kind))
        do {
            let source = try await requestSourceAction(kind)
            guard generation == operationGeneration else { return false }
            guard let source else {
                status = .cancelled(kind)
                return false
            }
            return await parse(source, as: kind, generation: generation)
        } catch {
            guard generation == operationGeneration else { return false }
            status = .failed(kind)
            present(error, title: .couldNotRead(kind))
            return false
        }
    }

    /// Parses bytes already obtained through a system picker owned by the
    /// caller. Starting a new preview supersedes any in-flight parse and any
    /// older unconfirmed token.
    @discardableResult
    func prepareImport(
        _ kind: SublimeImportKind,
        source: SublimeImportSource
    ) async -> Bool {
        guard canStart(kind) else { return false }
        let generation = beginOperation(kind, status: .parsing(kind))
        return await parse(source, as: kind, generation: generation)
    }

    @discardableResult
    func prepareImport(
        _ kind: SublimeImportKind,
        sourceURL: URL,
        data: Data
    ) async -> Bool {
        await prepareImport(kind, source: SublimeImportSource(
            sourceURL: sourceURL, data: data
        ))
    }

    /// Compatibility spelling for shell call sites that describe this as the
    /// beginning of the two-phase import.
    @discardableResult
    func beginImport(
        _ kind: SublimeImportKind,
        sourceURL: URL,
        data: Data
    ) async -> Bool {
        await prepareImport(kind, sourceURL: sourceURL, data: data)
    }

    /// Consumes a valid token before awaiting the mutation capability. This
    /// makes concurrent confirmation and retry-after-failure one-shot as well.
    @discardableResult
    func confirm(token: UUID) async -> Bool {
        guard let pending = presentation else {
            presentConfirmationIssue(SublimeImportControllerError.noPendingConfirmation)
            return false
        }
        guard pending.token == token else {
            presentConfirmationIssue(SublimeImportControllerError.invalidConfirmationToken)
            return false
        }

        // Matching tokens are consumed on every terminal confirmation path,
        // including expiry and a throwing apply callback.
        presentation = nil
        if clock() >= pending.expiresAt {
            status = .failed(pending.kind)
            presentConfirmationIssue(SublimeImportControllerError.confirmationExpired)
            return false
        }
        guard !pending.kind.requiresWorkspace || workspaceIsAvailable() else {
            status = .failed(pending.kind)
            presentWorkspaceIssue(pending.kind)
            return false
        }

        operationGeneration &+= 1
        status = .applying(pending.kind)
        issue = nil
        do {
            let roots: [URL]?
            switch pending.preview {
            case let .project(value):
                roots = try await applyProjectAction(value)
            case let .settings(value):
                try await applySettingsAction(value)
                roots = nil
            case let .keymap(value):
                try await applyKeymapAction(value)
                roots = nil
            case let .snippet(value):
                try await applySnippetAction(value)
                roots = nil
            case let .build(value):
                try await applyBuildAction(value)
                roots = nil
            }
            completion = SublimeImportCompletion(
                preview: pending.preview, projectRoots: roots
            )
            status = .completed(pending.kind)
            return true
        } catch {
            status = .failed(pending.kind)
            present(
                error,
                title: .couldNotApply(pending.kind)
            )
            return false
        }
    }

    /// Cancels source selection, parsing, or an awaiting preview. Application
    /// itself is intentionally non-cancellable once the one-shot token has
    /// crossed the mutation boundary.
    func cancel() {
        guard case .applying = status else {
            let kind = presentation?.kind ?? status.kind
            operationGeneration &+= 1
            presentation = nil
            issue = nil
            status = kind.map(SublimeImportStatus.cancelled) ?? .idle
            return
        }
    }

    /// Token-scoped cancellation prevents an old sheet from dismissing a newer
    /// preview that superseded it.
    @discardableResult
    func cancel(token: UUID) -> Bool {
        guard let pending = presentation, pending.token == token else { return false }
        cancel()
        return true
    }

    func dismissIssue() {
        issue = nil
    }

    /// Registers exactly the five imports owned here. Partial registration is
    /// transactional: on failure, all tokens acquired by this call are removed.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping PrepareForCommand = {},
        didFinishRequest: @escaping DidFinishRequest = {}
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            for kind in SublimeImportKind.allCases {
                tokens.append(try router.register(
                    kind.commandID,
                    replaceExisting: replaceExisting,
                    enablement: { [weak self] context in
                        guard let self else {
                            return .disabled(reason: "Sublime import unavailable")
                        }
                        if self.isBusy {
                            return .disabled(reason: "A Sublime import is in progress")
                        }
                        if kind.requiresWorkspace {
                            guard context.availableRequirements.contains(.workspace),
                                  self.workspaceIsAvailable() else {
                                return .disabled(reason: "No workspace")
                            }
                        }
                        return .enabled
                    }
                ) { [weak self] _ in
                    await prepareForCommand()
                    guard let self else {
                        throw CommandHandlerSignal.unavailable(
                            reason: "Sublime import unavailable"
                        )
                    }
                    let succeeded = await self.requestImport(kind)
                    didFinishRequest()
                    guard succeeded else {
                        if let issue = self.issue {
                            throw CommandHandlerSignal.failed(
                                .sublimeImport(issue.content)
                            )
                        }
                        throw CommandHandlerSignal.noChange
                    }
                })
            }
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    private func canStart(_ kind: SublimeImportKind) -> Bool {
        if case .applying = status {
            presentConfirmationIssue(SublimeImportControllerError.applyInProgress)
            return false
        }
        if isBusy {
            return false
        }
        guard !kind.requiresWorkspace || workspaceIsAvailable() else {
            operationGeneration &+= 1
            presentation = nil
            completion = nil
            status = .failed(kind)
            presentWorkspaceIssue(kind)
            return false
        }
        return true
    }

    private func beginOperation(
        _ kind: SublimeImportKind,
        status: SublimeImportStatus
    ) -> UInt64 {
        operationGeneration &+= 1
        presentation = nil
        completion = nil
        issue = nil
        self.status = status
        return operationGeneration
    }

    private func parse(
        _ source: SublimeImportSource,
        as kind: SublimeImportKind,
        generation: UInt64
    ) async -> Bool {
        status = .parsing(kind)
        let settings = currentSettings()
        do {
            let preview = try await parseAction(kind, source, settings)
            guard generation == operationGeneration else { return false }
            guard preview.kind == kind else {
                throw SublimeImportControllerError.mismatchedPreview(
                    expected: kind, actual: preview.kind
                )
            }
            let createdAt = clock()
            presentation = SublimeImportPresentation(
                token: makeToken(),
                preview: preview,
                expiresAt: createdAt.addingTimeInterval(confirmationLifetime)
            )
            status = .awaitingConfirmation(kind)
            issue = nil
            return true
        } catch {
            guard generation == operationGeneration else { return false }
            presentation = nil
            status = .failed(kind)
            present(
                error,
                title: .couldNotRead(kind)
            )
            return false
        }
    }

    private func presentWorkspaceIssue(_ kind: SublimeImportKind) {
        present(
            SublimeImportControllerError.workspaceRequired(kind),
            title: .noWorkspaceOpen
        )
    }

    private func presentConfirmationIssue(_ error: SublimeImportControllerError) {
        present(error, title: .confirmationUnavailable)
    }

    private func present(
        _ error: any Error,
        title: SublimeImportPresentationIssue.Title
    ) {
        issue = SublimeImportPresentationIssue(
            title: title, content: Self.presentationMessage(for: error)
        )
    }

    static func presentationMessage(
        for error: any Error
    ) -> SublimeImportPresentationIssue.Message {
        if let error = error as? SublimeImportControllerError {
            return .controller(error)
        }
        if let error = error as? SublimeImportError {
            return .parser(error)
        }
        if let error = error as? SublimeImportProductionError {
            return .production(error)
        }
        if let error = error as? ProjectSettingsStoreError {
            return .projectSettingsStore(error)
        }
        if let error = error as? WorkspaceServiceError {
            return .workspace(error)
        }
        if let error = error as? SecurityScopedAccessError {
            return .securityScopedAccess(error)
        }
        return .verbatim(error.localizedDescription)
    }

    static func defaultParse(
        kind: SublimeImportKind,
        source: SublimeImportSource,
        currentSettings: EditorSettings
    ) async throws -> SublimeImportPreview {
        try await Task.detached(priority: .userInitiated) {
            switch kind {
            case .project:
                return .project(try SublimeImportParser.parseProject(
                    source.data, sourceURL: source.sourceURL
                ))
            case .settings:
                return .settings(try SublimeImportParser.parseSettings(
                    source.data,
                    sourceURL: source.sourceURL,
                    current: currentSettings
                ))
            case .keymap:
                return .keymap(try SublimeImportParser.parseKeymap(
                    source.data, sourceURL: source.sourceURL
                ))
            case .snippet:
                return .snippet(try SublimeImportParser.parseSnippet(
                    source.data, sourceURL: source.sourceURL
                ))
            case .build:
                return .build(SublimeBuildImport(
                    sourceURL: source.sourceURL,
                    system: try SublimeImportParser.parseBuildSystem(
                        source.data, sourceURL: source.sourceURL
                    )
                ))
            }
        }.value
    }
}
