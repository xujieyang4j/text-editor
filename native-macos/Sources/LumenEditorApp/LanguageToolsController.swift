import Combine
@preconcurrency import Foundation
import LumenEditorCore

protocol LanguageToolRunning: Sendable {
    func approvalConfiguration(
        root: URL, configuration: LanguageToolConfig
    ) async throws -> ToolExecutionConfiguration
    func approve(_ configuration: ToolExecutionConfiguration) async
    func run(_ request: LanguageToolRequest) async throws -> LanguageToolResult
    func authorizeExecutable(_ url: URL) async throws -> URL
    func cancelAll() async
}

extension LanguageToolService: LanguageToolRunning {}

struct LanguageToolDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let paneIndex: Int
    let viewID: EditorViewID
    let bufferRevision: UInt64
    let text: String
    let language: String
    let fileURL: URL?
    let workspaceRoot: URL?
}

struct LanguageToolApplyRequest: Equatable, Sendable {
    let snapshot: LanguageToolDocumentSnapshot
    let replacementContent: String?
    let diagnostics: [LanguageToolDiagnostic]
}

enum LanguageToolFormatSource: String, Equatable, Sendable {
    case languageServer
    case languageTool
    case builtIn
}

enum LanguageToolRunState: Equatable, Sendable {
    case idle
    case awaitingApproval
    case running(LanguageToolFormatSource)
    case completed(source: LanguageToolFormatSource, changed: Bool, diagnosticCount: Int)
    case discardedStale
}

struct LanguageToolPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case noWorkspace
        case saveLanguageTool
        case selectLanguageTool
        case languageServerFormattingFailed
        case languageToolFailed
        case formattingResultNotApplied
    }

    enum Message: Equatable, Sendable {
        case app(LanguageToolAppIssue)
        case draft(LanguageToolDraftError)
        case languageTool(LanguageToolError)
        case languageServer(LanguageServerClientError)
        case toolExecution(ToolExecutionError)
        case toolProcess(ToolProcessRunnerError)
        case composition(LanguageToolsCompositionError)
        case securityScope(SecurityScopedAccessError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English compatibility copy for command results and tests. Views
    /// render the typed payload using the current runtime locale.
    var title: String { EditorLocale.enUS.localizedLanguageToolIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedLanguageToolIssue(content) }

    init(id: UUID = UUID(), title: Title, appIssue: LanguageToolAppIssue) {
        self.id = id
        titleContent = title
        content = .app(appIssue)
    }

    init(id: UUID = UUID(), title: Title, error: any Error) {
        self.id = id
        titleContent = title
        if let draftError = error as? LanguageToolDraftError {
            content = .draft(draftError)
        } else if let toolError = error as? LanguageToolError {
            content = .languageTool(toolError)
        } else if let serverError = error as? LanguageServerClientError {
            content = .languageServer(serverError)
        } else if let executionError = error as? ToolExecutionError {
            content = .toolExecution(executionError)
        } else if let processError = error as? ToolProcessRunnerError {
            content = .toolProcess(processError)
        } else if let compositionError = error as? LanguageToolsCompositionError {
            content = .composition(compositionError)
        } else if let scopeError = error as? SecurityScopedAccessError {
            content = .securityScope(scopeError)
        } else {
            content = .verbatim(error.localizedDescription)
        }
    }
}

enum LanguageToolAppIssue: Equatable, Sendable {
    case missingWorkspace
    case staleFormattingResult
}

struct LanguageToolApprovalRequest: Identifiable, Equatable, Sendable {
    var id: ToolExecutionIdentity { configuration.identity }
    let language: String
    let configuration: ToolExecutionConfiguration

    var identityDescription: String {
        let command = configuration.shell
            ? configuration.executable
            : ([configuration.executable] + configuration.args).joined(separator: " ")
        let environment = configuration.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return [
            "Language: \(language)",
            "Purpose: \(configuration.kind.rawValue)",
            "Workspace: \(configuration.root.path)",
            "Command: \(command)",
            "Resolved executable: \(configuration.executableURL.path)",
            "Working directory: \(configuration.cwd.path)",
            "Uses shell command parsing: \(configuration.shell ? "yes" : "no")",
            environment.isEmpty ? "Environment: none" : "Environment:\n" + environment,
            "Identity: \(configuration.identity.rawValue)"
        ].joined(separator: "\n")
    }
}

enum LanguageToolDraftError: Error, Equatable, LocalizedError, Sendable {
    case invalidLanguage
    case invalidArguments
    case invalidEnvironment
    case shellArgumentsNotAllowed
    case commandTooLong
    case workingDirectoryTooLong

    var errorDescription: String? {
        switch self {
        case .invalidLanguage:
            return "Choose a valid document language."
        case .invalidArguments:
            return "Arguments must be a JSON array of at most 50 strings."
        case .invalidEnvironment:
            return "Environment must be a JSON object with safe string keys and values."
        case .shellArgumentsNotAllowed:
            return "Put the complete command in Command when shell mode is enabled; separate arguments are not allowed."
        case .commandTooLong:
            return "The language tool command is too long."
        case .workingDirectoryTooLong:
            return "The working directory is too long."
        }
    }
}

struct LanguageToolDraft: Equatable, Sendable {
    var language: String
    var command: String
    var argumentsJSON: String
    var workingDirectory: String
    var shell: Bool
    var environmentJSON: String

    init(language: String, configuration: LanguageToolConfig? = nil) {
        self.language = language
        command = configuration?.command ?? ""
        argumentsJSON = Self.prettyJSON(configuration?.args ?? [], fallback: "[]")
        workingDirectory = configuration?.workingDirectory ?? ""
        shell = configuration?.shell ?? false
        environmentJSON = Self.prettyJSON(configuration?.env ?? [:], fallback: "{}")
    }

    /// An empty command deletes the current language's configuration.
    func validatedConfiguration() throws -> LanguageToolConfig? {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty,
              language.utf16.count <= ProjectSettingsSanitizer.maximumLanguageNameUTF16CodeUnits,
              !language.utf8.contains(0) else { throw LanguageToolDraftError.invalidLanguage }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        guard command.utf16.count
                <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits,
              !command.utf8.contains(0) else {
            throw LanguageToolDraftError.commandTooLong
        }

        guard let argumentsData = argumentsJSON.data(using: .utf8),
              argumentsData.count <= ProjectSettingsSanitizer.maximumSerializedBytes,
              let argumentsValue = try? JSONSerialization.jsonObject(
                with: argumentsData, options: [.fragmentsAllowed]
              ),
              let rawArguments = argumentsValue as? [Any],
              rawArguments.count <= ToolExecutionLimits.maximumArguments,
              rawArguments.allSatisfy({ $0 is String }) else {
            throw LanguageToolDraftError.invalidArguments
        }
        let arguments = rawArguments.compactMap { $0 as? String }
        guard arguments.allSatisfy({
            !$0.utf8.contains(0)
                && $0.utf16.count <= ToolExecutionLimits.maximumArgumentUTF16CodeUnits
        }) else { throw LanguageToolDraftError.invalidArguments }
        guard !shell || arguments.isEmpty else {
            throw LanguageToolDraftError.shellArgumentsNotAllowed
        }

        guard let environmentData = environmentJSON.data(using: .utf8),
              environmentData.count <= ProjectSettingsSanitizer.maximumSerializedBytes,
              let environmentValue = try? JSONSerialization.jsonObject(
                with: environmentData, options: [.fragmentsAllowed]
              ),
              let rawEnvironment = environmentValue as? [String: Any],
              rawEnvironment.values.allSatisfy({ $0 is String }) else {
            throw LanguageToolDraftError.invalidEnvironment
        }
        let environment = rawEnvironment.compactMapValues { $0 as? String }
        do { _ = try ToolEnvironmentPolicy.sanitizedEnvironment(overrides: environment) }
        catch { throw LanguageToolDraftError.invalidEnvironment }

        let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd.utf16.count <= ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits,
              !cwd.utf8.contains(0) else {
            throw LanguageToolDraftError.workingDirectoryTooLong
        }
        return LanguageToolConfig(
            command: command,
            args: arguments,
            shell: shell,
            workingDirectory: cwd.isEmpty ? nil : cwd,
            env: environment
        )
    }

    private static func prettyJSON<T: Encodable>(_ value: T, fallback: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class LanguageToolsController: ObservableObject {
    typealias SnapshotProvider = @MainActor () -> LanguageToolDocumentSnapshot?
    typealias WorkspaceProvider = @MainActor () -> URL?
    typealias LanguageProvider = @MainActor () -> String
    typealias ConfigurationProvider = @MainActor (String) -> LanguageToolConfig?
    typealias LanguageServerConfigurationProvider = @MainActor (
        String
    ) -> LanguageServerConfig?
    typealias SaveConfiguration = @MainActor (String, LanguageToolConfig?) throws -> Void
    typealias ApplyResult = @MainActor (LanguageToolApplyRequest) -> Bool
    typealias FormatWithLanguageServer = @MainActor (
        LanguageToolDocumentSnapshot
    ) async throws -> LanguageToolResult?
    typealias ApproveLanguageServer = @MainActor (
        ToolExecutionConfiguration
    ) async -> Void
    typealias ChooseExecutable = @MainActor () async -> URL?
    typealias PrepareForCommand = @MainActor () async -> Void

    static let commandIDs = ["format-document", "language-tools"]

    @Published private(set) var runState: LanguageToolRunState = .idle
    @Published private(set) var diagnostics: [LanguageToolDiagnostic] = []
    @Published private(set) var issue: LanguageToolPresentationIssue?
    @Published private(set) var pendingApproval: LanguageToolApprovalRequest?
    @Published private(set) var isConfigurationPresented = false
    @Published private(set) var isSavingConfiguration = false
    @Published private(set) var draft = LanguageToolDraft(language: "Plain Text")

    private struct ToolOperation: Equatable, Sendable {
        let snapshot: LanguageToolDocumentSnapshot
        let configuration: LanguageToolConfig
    }

    private struct LanguageServerOperation: Equatable, Sendable {
        let snapshot: LanguageToolDocumentSnapshot
        let configuration: LanguageServerConfig
    }

    private enum PendingOperation: Equatable, Sendable {
        case languageServer(LanguageServerOperation)
        case languageTool(ToolOperation)
    }

    private let tool: any LanguageToolRunning
    private let snapshotProvider: SnapshotProvider
    private let workspaceProvider: WorkspaceProvider
    private let languageProvider: LanguageProvider
    private let configurationProvider: ConfigurationProvider
    private let languageServerConfigurationProvider: LanguageServerConfigurationProvider
    private let saveConfigurationAction: SaveConfiguration
    private let applyResult: ApplyResult
    private let formatWithLanguageServer: FormatWithLanguageServer
    private let approveLanguageServer: ApproveLanguageServer
    private let chooseExecutableAction: ChooseExecutable
    private let securityScopedAccess: SecurityScopedAccessController
    private var executableSecurityScope: SecurityScopedResourceLease?
    private var pendingOperation: PendingOperation?
    private var operationTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        tool: any LanguageToolRunning = LanguageToolService(),
        snapshot: @escaping SnapshotProvider,
        workspace: @escaping WorkspaceProvider,
        language: @escaping LanguageProvider,
        configuration: @escaping ConfigurationProvider,
        languageServerConfiguration: @escaping LanguageServerConfigurationProvider
            = { _ in nil },
        saveConfiguration: @escaping SaveConfiguration,
        applyResult: @escaping ApplyResult,
        formatWithLanguageServer: @escaping FormatWithLanguageServer = { _ in nil },
        approveLanguageServer: @escaping ApproveLanguageServer = { _ in },
        chooseExecutable: @escaping ChooseExecutable = { nil },
        securityScopedAccess: SecurityScopedAccessController = .shared
    ) {
        self.tool = tool
        snapshotProvider = snapshot
        workspaceProvider = workspace
        languageProvider = language
        configurationProvider = configuration
        languageServerConfigurationProvider = languageServerConfiguration
        saveConfigurationAction = saveConfiguration
        self.applyResult = applyResult
        self.formatWithLanguageServer = formatWithLanguageServer
        self.approveLanguageServer = approveLanguageServer
        chooseExecutableAction = chooseExecutable
        self.securityScopedAccess = securityScopedAccess
    }

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    var hasConfiguration: Bool { configurationProvider(draft.language) != nil }

    func setDraft<Value>(_ value: Value, for keyPath: WritableKeyPath<LanguageToolDraft, Value>) {
        var next = draft
        next[keyPath: keyPath] = value
        draft = next
    }

    func setShell(_ enabled: Bool) {
        var next = draft
        next.shell = enabled
        if enabled { next.argumentsJSON = "[]" }
        draft = next
    }

    func presentConfiguration() {
        guard workspaceProvider() != nil else {
            presentIssue(title: .noWorkspace, appIssue: .missingWorkspace)
            return
        }
        let language = languageProvider()
        draft = LanguageToolDraft(
            language: language, configuration: configurationProvider(language)
        )
        issue = nil
        isConfigurationPresented = true
    }

    func dismissConfiguration() {
        isConfigurationPresented = false
        let language = languageProvider()
        draft = LanguageToolDraft(
            language: language, configuration: configurationProvider(language)
        )
    }

    @discardableResult
    func saveConfiguration(dismiss: Bool = true) -> Bool {
        isSavingConfiguration = true
        defer { isSavingConfiguration = false }
        do {
            let language = draft.language.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = try draft.validatedConfiguration()
            try saveConfigurationAction(language, configuration)
            draft = LanguageToolDraft(language: language, configuration: configuration)
            issue = nil
            if dismiss { isConfigurationPresented = false }
            return true
        } catch {
            presentIssue(title: .saveLanguageTool, error: error)
            return false
        }
    }

    func chooseExecutable() async {
        guard let selected = await chooseExecutableAction() else { return }
        var lease: SecurityScopedResourceLease?
        do {
            do {
                lease = try securityScopedAccess.accessUserSelectedURL(
                    selected, kind: .file
                )
            } catch {
                guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
                else { throw error }
                lease = SecurityScopedResourceLease(url: selected.standardizedFileURL)
            }
            guard let lease else { return }
            let authorized = try await tool.authorizeExecutable(lease.url)
            executableSecurityScope?.invalidate()
            executableSecurityScope = lease
            setDraft(authorized.path, for: \.command)
            setDraft(false, for: \.shell)
            issue = nil
        } catch {
            // A newly selected scope is not retained when executable
            // validation fails. Existing valid configuration remains active.
            lease?.invalidate()
            presentIssue(title: .selectLanguageTool, error: error)
        }
    }

    @discardableResult
    func formatDocument() async -> Bool {
        guard operationTask == nil, pendingApproval == nil,
              let snapshot = snapshotProvider() else { return false }
        issue = nil
        pendingApproval = nil
        pendingOperation = nil
        generation = next(generation)
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(snapshot: snapshot, generation: token)
        }
        operationTask = task
        await task.value
        if generation == token { operationTask = nil }
        switch runState {
        case .awaitingApproval:
            return true
        case let .completed(_, changed, diagnosticCount):
            return changed || diagnosticCount > 0
        case .idle, .running, .discardedStale:
            return false
        }
    }

    func confirmPendingApproval() async {
        guard operationTask == nil, let approval = pendingApproval,
              let operation = pendingOperation else { return }
        let snapshot: LanguageToolDocumentSnapshot
        switch operation {
        case let .languageServer(value): snapshot = value.snapshot
        case let .languageTool(value): snapshot = value.snapshot
        }
        guard isCurrent(snapshot) else { discardStale(); return }
        switch operation {
        case let .languageServer(serverOperation):
            guard languageServerConfigurationProvider(
                serverOperation.snapshot.language
            ) == serverOperation.configuration else {
                discardStale()
                return
            }
            await approveLanguageServer(approval.configuration)
        case let .languageTool(toolOperation):
            guard configurationProvider(toolOperation.snapshot.language)
                    == toolOperation.configuration else {
                discardStale()
                return
            }
            await tool.approve(approval.configuration)
        }
        guard pendingApproval?.configuration == approval.configuration,
              pendingOperation == operation else { return }
        pendingApproval = nil
        pendingOperation = nil
        generation = next(generation)
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch operation {
            case let .languageServer(serverOperation):
                await self.execute(
                    snapshot: serverOperation.snapshot, generation: token
                )
            case let .languageTool(toolOperation):
                await self.executeLanguageTool(toolOperation, generation: token)
            }
        }
        operationTask = task
        await task.value
        if generation == token { operationTask = nil }
    }

    func declinePendingApproval() {
        pendingApproval = nil
        pendingOperation = nil
        runState = .idle
    }

    func cancel() async {
        guard operationTask != nil || isRunning || pendingApproval != nil else { return }
        generation = next(generation)
        let task = operationTask
        operationTask = nil
        task?.cancel()
        await tool.cancelAll()
        await task?.value
        pendingApproval = nil
        pendingOperation = nil
        runState = .idle
    }

    /// Revoke pending work when the workspace capability changes. Exact
    /// approvals for the old root remain harmless in the shared store, but no
    /// captured request is allowed to cross the root boundary.
    func workspaceDidChange() async {
        await cancel()
        pendingApproval = nil
        pendingOperation = nil
        runState = .idle
        diagnostics = []
        issue = nil
    }

    func dismissIssue() { issue = nil }
    func clearDiagnostics() { diagnostics = [] }

    func releaseSecurityScopedAccess() {
        executableSecurityScope?.invalidate()
        executableSecurityScope = nil
    }

    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping PrepareForCommand = {}
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register(
                "format-document", replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self, self.snapshotProvider() != nil else {
                        return .disabled(reason: "No active document.")
                    }
                    return self.operationTask == nil && self.pendingApproval == nil
                        ? .enabled : .disabled(reason: "A language tool operation is active.")
                },
                handler: { [weak self] _ in
                    await prepareForCommand()
                    guard let self else {
                        throw CommandHandlerSignal.unavailable(
                            reason: "Language tools unavailable."
                        )
                    }
                    guard await self.formatDocument() else {
                        if let issue = self.issue {
                            self.dismissIssue()
                            throw CommandHandlerSignal.failed(.languageTool(issue))
                        }
                        throw CommandHandlerSignal.noChange
                    }
                }
            ))
            tokens.append(try router.register(
                "language-tools", replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    self?.workspaceProvider() == nil
                        ? .disabled(reason: "No workspace.") : .enabled
                },
                handler: { [weak self] _ in
                    await prepareForCommand()
                    guard let self else {
                        throw CommandHandlerSignal.unavailable(
                            reason: "Language tools unavailable."
                        )
                    }
                    self.presentConfiguration()
                    guard self.isConfigurationPresented else {
                        if let issue = self.issue {
                            self.dismissIssue()
                            throw CommandHandlerSignal.failed(.languageTool(issue))
                        }
                        throw CommandHandlerSignal.noChange
                    }
                }
            ))
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    private func execute(
        snapshot: LanguageToolDocumentSnapshot, generation token: UInt64
    ) async {
        runState = .running(.languageServer)
        if let serverConfiguration = languageServerConfigurationProvider(
            snapshot.language
        ) {
            do {
                if let result = try await formatWithLanguageServer(snapshot) {
                    guard languageServerConfigurationProvider(snapshot.language)
                            == serverConfiguration else {
                        discardStale()
                        return
                    }
                    commit(
                        result, source: .languageServer,
                        snapshot: snapshot, generation: token
                    )
                    return
                }
            } catch let LanguageServerClientError.approvalRequired(configuration) {
                guard isGeneration(token), isCurrent(snapshot),
                      languageServerConfigurationProvider(snapshot.language)
                        == serverConfiguration else {
                    discardStale()
                    return
                }
                pendingOperation = .languageServer(LanguageServerOperation(
                    snapshot: snapshot, configuration: serverConfiguration
                ))
                pendingApproval = LanguageToolApprovalRequest(
                    language: snapshot.language, configuration: configuration
                )
                runState = .awaitingApproval
                return
            } catch {
                guard isGeneration(token), !Self.isCancellation(error) else { return }
                presentIssue(title: .languageServerFormattingFailed, error: error)
                runState = .idle
                return
            }
        }
        guard isGeneration(token) else { return }

        if snapshot.workspaceRoot != nil,
           let configuration = configurationProvider(snapshot.language) {
            await executeLanguageTool(
                ToolOperation(snapshot: snapshot, configuration: configuration),
                generation: token
            )
            return
        }
        let content = BuiltInDocumentFormatter.format(snapshot.text)
        commit(
            LanguageToolResult(content: content), source: .builtIn,
            snapshot: snapshot, generation: token
        )
    }

    private func executeLanguageTool(
        _ operation: ToolOperation, generation token: UInt64
    ) async {
        guard isGeneration(token), let root = operation.snapshot.workspaceRoot,
              configurationProvider(operation.snapshot.language)
                == operation.configuration else {
            discardStale()
            return
        }
        runState = .running(.languageTool)
        do {
            let result = try await tool.run(LanguageToolRequest(
                root: root, configuration: operation.configuration,
                content: operation.snapshot.text, fileURL: operation.snapshot.fileURL
            ))
            guard configurationProvider(operation.snapshot.language)
                    == operation.configuration else {
                discardStale()
                return
            }
            commit(
                result, source: .languageTool, snapshot: operation.snapshot,
                generation: token
            )
        } catch let LanguageToolError.approvalRequired(configuration) {
            guard isGeneration(token), isCurrent(operation.snapshot),
                  configurationProvider(operation.snapshot.language)
                    == operation.configuration else {
                discardStale()
                return
            }
            pendingOperation = .languageTool(operation)
            pendingApproval = LanguageToolApprovalRequest(
                language: operation.snapshot.language, configuration: configuration
            )
            runState = .awaitingApproval
        } catch {
            guard isGeneration(token), !Self.isCancellation(error) else { return }
            presentIssue(title: .languageToolFailed, error: error)
            runState = .idle
        }
    }

    private func commit(
        _ result: LanguageToolResult, source: LanguageToolFormatSource,
        snapshot: LanguageToolDocumentSnapshot, generation token: UInt64
    ) {
        guard isGeneration(token), isCurrent(snapshot) else {
            discardStale()
            return
        }
        let replacement = result.content == snapshot.text ? nil : result.content
        let request = LanguageToolApplyRequest(
            snapshot: snapshot, replacementContent: replacement,
            diagnostics: result.diagnostics
        )
        guard applyResult(request) else {
            discardStale()
            return
        }
        diagnostics = result.diagnostics
        runState = .completed(
            source: source, changed: replacement != nil,
            diagnosticCount: result.diagnostics.count
        )
    }

    private func isCurrent(_ expected: LanguageToolDocumentSnapshot) -> Bool {
        guard let current = snapshotProvider() else { return false }
        return current.documentID == expected.documentID
            && current.paneIndex == expected.paneIndex
            && current.viewID == expected.viewID
            && current.bufferRevision == expected.bufferRevision
            && current.language == expected.language
            && current.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
                == expected.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
            && current.workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()
                == expected.workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func discardStale() {
        pendingApproval = nil
        pendingOperation = nil
        runState = .discardedStale
        presentIssue(
            title: .formattingResultNotApplied,
            appIssue: .staleFormattingResult
        )
    }

    private func isGeneration(_ token: UInt64) -> Bool { generation == token }

    private func next(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private func presentIssue(
        title: LanguageToolPresentationIssue.Title, error: any Error
    ) {
        issue = LanguageToolPresentationIssue(title: title, error: error)
    }

    private func presentIssue(
        title: LanguageToolPresentationIssue.Title, appIssue: LanguageToolAppIssue
    ) {
        issue = LanguageToolPresentationIssue(title: title, appIssue: appIssue)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ToolExecutionError) == .cancelled
    }
}
