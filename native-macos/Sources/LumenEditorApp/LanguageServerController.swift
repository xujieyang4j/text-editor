import Combine
@preconcurrency import Foundation
import LumenEditorCore

private final class LanguageServerEventTaskBox {
    var eventTask: Task<Void, Never>?

    deinit {
        eventTask?.cancel()
    }
}

/// The application-facing portion of `LanguageServerManager`. Keeping this
/// boundary small lets App tests exercise event ordering and lifecycle calls
/// without launching an external process.
protocol LanguageServerManaging: Sendable {
    func events() async -> AsyncStream<LanguageServerEvent>
    func approvalConfiguration(
        root: URL, config: LanguageServerConfig
    ) async throws -> ToolExecutionConfiguration
    func approve(_ configuration: ToolExecutionConfiguration) async
    func authorizeExecutable(_ url: URL) async throws -> URL
    func revokeAllExecutables() async

    func start(
        root: URL, config: LanguageServerConfig
    ) async throws -> LanguageServerInstanceKey

    func synchronize(
        _ request: LanguageServerSyncRequest
    ) async throws -> LanguageServerInstanceKey

    func closeDocument(
        root: URL, config: LanguageServerConfig, fileURL: URL
    ) async throws

    func perform(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerInteractiveResult

    func format(
        _ request: LanguageServerRequest
    ) async throws -> LanguageServerResult

    func renamePreview(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerRenamePreview

    func stop(_ key: LanguageServerInstanceKey) async
    func stopAll() async
    func restart(_ key: LanguageServerInstanceKey) async throws
    func cancel(_ key: LanguageServerInstanceKey) async
}

struct LanguageServerManagerAdapter: LanguageServerManaging {
    let manager: LanguageServerManager

    init(manager: LanguageServerManager = LanguageServerManager()) {
        self.manager = manager
    }

    func events() async -> AsyncStream<LanguageServerEvent> {
        await manager.events()
    }

    func approvalConfiguration(
        root: URL, config: LanguageServerConfig
    ) async throws -> ToolExecutionConfiguration {
        try await manager.approvalConfiguration(root: root, config: config)
    }

    func approve(_ configuration: ToolExecutionConfiguration) async {
        await manager.approve(configuration)
    }

    func authorizeExecutable(_ url: URL) async throws -> URL {
        try await manager.authorizeExecutable(url)
    }

    func revokeAllExecutables() async {
        await manager.revokeAllExecutables()
    }

    func start(
        root: URL, config: LanguageServerConfig
    ) async throws -> LanguageServerInstanceKey {
        try await manager.start(root: root, config: config)
    }

    func synchronize(
        _ request: LanguageServerSyncRequest
    ) async throws -> LanguageServerInstanceKey {
        try await manager.synchronize(request)
    }

    func closeDocument(
        root: URL, config: LanguageServerConfig, fileURL: URL
    ) async throws {
        try await manager.closeDocument(root: root, config: config, fileURL: fileURL)
    }

    func perform(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerInteractiveResult {
        try await manager.perform(request)
    }

    func format(
        _ request: LanguageServerRequest
    ) async throws -> LanguageServerResult {
        try await manager.format(request)
    }

    func renamePreview(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerRenamePreview {
        try await manager.renamePreview(request)
    }

    func stop(_ key: LanguageServerInstanceKey) async { await manager.stop(key) }
    func stopAll() async { await manager.stopAll() }
    func restart(_ key: LanguageServerInstanceKey) async throws {
        try await manager.restart(key)
    }
    func cancel(_ key: LanguageServerInstanceKey) async { await manager.cancel(key) }
}

struct LanguageServerPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case couldNotStart
        case couldNotSynchronize
        case couldNotCloseDocument
        case couldNotRestart
        case couldNotPreviewRename
        case requestFailed
        case invalidRequest
        case verbatim(String)
    }

    enum Message: Equatable, Sendable {
        case app(english: String, chinese: String)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    var title: String {
        EditorLocale.enUS.localizedLanguageServerIssueTitle(titleContent)
    }

    var message: String {
        EditorLocale.enUS.localizedLanguageServerIssue(content)
    }

    init(
        id: UUID = UUID(), title: Title, message: Message
    ) {
        self.id = id
        titleContent = title
        content = message
    }
}

/// The explicit result of an interactive language-server command. A completed
/// value may itself be empty (for example, no hover or no definitions), which
/// remains distinct from approval, cancellation, and execution failure.
enum LanguageServerInteractiveOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case completed(Value)
    case awaitingApproval
    case cancelled
    case failed(String)

    func map<MappedValue: Equatable & Sendable>(
        _ transform: @Sendable (Value) -> MappedValue
    ) -> LanguageServerInteractiveOutcome<MappedValue> {
        switch self {
        case let .completed(value):
            return .completed(transform(value))
        case .awaitingApproval:
            return .awaitingApproval
        case .cancelled:
            return .cancelled
        case let .failed(message):
            return .failed(message)
        }
    }
}

struct LanguageServerApprovalRequest: Identifiable, Equatable, Sendable {
    var id: ToolExecutionIdentity { configuration.identity }
    let configuration: ToolExecutionConfiguration

    var commandDescription: String {
        ([configuration.executable] + configuration.args).joined(separator: " ")
    }

    var identityDescription: String {
        let environment = configuration.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return [
            "Purpose: \(configuration.kind.rawValue)",
            "Workspace: \(configuration.root.path)",
            "Command: \(commandDescription)",
            "Resolved executable: \(configuration.executableURL.path)",
            "Working directory: \(configuration.cwd.path)",
            environment.isEmpty ? "Environment: none" : "Environment:\n\(environment)",
            "Identity: \(configuration.identity.rawValue)"
        ].joined(separator: "\n")
    }
}

/// A diagnostic together with the server generation which produced it.
/// The ID is presentation-only and changes when a document publishes a new
/// diagnostic batch, allowing SwiftUI to replace rows cleanly.
struct LanguageServerDiagnosticEntry: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let revision: UInt64
        let index: Int
    }

    let id: ID
    let key: LanguageServerInstanceKey
    let filePath: String
    let diagnostic: LanguageServerDiagnostic
    let documentVersion: Int?
    let generation: UInt64
}

/// A bounded diagnostic batch tied to the exact open editor document.
/// Consumers must still validate these identity fields before drawing.
struct LanguageServerDiagnosticPresentationSnapshot: Equatable, Sendable {
    let documentID: String
    let serverKey: LanguageServerInstanceKey
    let filePath: String
    let documentRevision: UInt64
    let generation: UInt64
    let presentationRevision: UInt64
    let entries: [LanguageServerDiagnosticEntry]
}

@MainActor
final class LanguageServerController: ObservableObject {
    /// The shell mutation coordinator owns conflict checks, confirmation, and
    /// application of a rename. This controller deliberately hands it only a
    /// preview and never writes files or mutates editor documents itself.
    typealias CoordinateRenamePreview = @MainActor (
        LanguageServerRenamePreview
    ) async throws -> Void

    static let maximumServers = 64
    static let maximumStatuses = maximumServers
    static let maximumDiagnosticDocuments = 256
    static let maximumDiagnostics = LSPProtocolLimits.maximumDiagnostics
    static let maximumLogEntries = 500
    static let maximumLogCharacters = 200 * 1_024
    static let maximumLogEntryCharacters = 32 * 1_024
    static let maximumInteractiveLocations = LSPProtocolLimits.maximumDiagnostics
    static let maximumCompletionItems = LSPProtocolLimits.maximumCompletionItems

    @Published private(set) var statuses: [LanguageServerStatus] = []
    @Published private(set) var diagnostics: [LanguageServerDiagnosticEntry] = []
    /// Changes whenever the editor-safe diagnostic identity/snapshot changes,
    /// including successful synchronization before any diagnostic event.
    @Published private(set) var diagnosticPresentationRevision: UInt64 = 0
    @Published private(set) var logEntries: [LanguageServerLogEntry] = []
    @Published private(set) var discardedLogEntryCount = 0
    @Published private(set) var interactiveResult: LanguageServerInteractiveResult?
    /// Method and server identity for the retained non-mutating result. The
    /// active method is cleared as soon as a request finishes, while these
    /// values intentionally remain available to the results panel.
    @Published private(set) var interactiveResultMethod: LanguageServerMethod?
    @Published private(set) var interactiveResultKey: LanguageServerInstanceKey?
    @Published private(set) var interactiveResultRevision: UInt64 = 0
    @Published private(set) var activeInteractiveMethod: LanguageServerMethod?
    @Published private(set) var isInteractiveRequestRunning = false
    @Published private(set) var issue: LanguageServerPresentationIssue?
    @Published private(set) var pendingApproval: LanguageServerApprovalRequest?
    private var editorCompletionResult: [LanguageCompletionItem]?

    private struct DiagnosticDocumentKey: Hashable {
        let server: LanguageServerInstanceKey
        let filePath: String
    }

    private struct DiagnosticBucket {
        let generation: UInt64
        let documentVersion: Int?
        let presentationRevision: UInt64
        let entries: [LanguageServerDiagnosticEntry]
    }

    private struct SynchronizedDocumentIdentity: Equatable {
        let documentID: String
        let documentRevision: UInt64
        let documentVersion: Int
    }

    private enum ObservationState: Equatable {
        case starting
        case active
        case finished
    }

    private enum ObservationPhase: Sendable {
        case ready
        case event(LanguageServerEvent)
        case finished
    }

    private let manager: any LanguageServerManaging
    private let coordinateRenamePreview: CoordinateRenamePreview
    private let eventTaskBox = LanguageServerEventTaskBox()

    private var observationState = ObservationState.starting
    private var statusesByKey: [LanguageServerInstanceKey: LanguageServerStatus] = [:]
    private var latestGenerationByKey: [LanguageServerInstanceKey: UInt64] = [:]
    private var latestSequenceByKey: [LanguageServerInstanceKey: UInt64] = [:]
    private var lastUnsequencedStateByKey: [
        LanguageServerInstanceKey: LanguageServerClientState
    ] = [:]
    private var retainedServerOrder: [LanguageServerInstanceKey] = []

    private var diagnosticBuckets: [DiagnosticDocumentKey: DiagnosticBucket] = [:]
    private var diagnosticDocumentOrder: [DiagnosticDocumentKey] = []
    private var diagnosticRevision: UInt64 = 0
    private var synchronizedDocumentIdentities: [
        DiagnosticDocumentKey: SynchronizedDocumentIdentity
    ] = [:]

    private var retainedLogUTF16Units = 0
    private var interactiveToken: UInt64 = 0
    private var activeInteractiveToken: UInt64?
    private var activeInteractiveKey: LanguageServerInstanceKey?
    private var invalidatedGenerationByKey: [LanguageServerInstanceKey: UInt64] = [:]

    private enum PendingApprovedOperation: Equatable {
        case start(root: URL, config: LanguageServerConfig)
        case synchronize(
            LanguageServerSyncRequest, documentID: String?, documentRevision: UInt64?
        )
        case perform(LanguageServerInteractiveRequest)
        case editorCompletion(LanguageServerInteractiveRequest)
        case rename(LanguageServerInteractiveRequest)
        case restart(LanguageServerInstanceKey)
    }

    private var pendingApprovedOperation: PendingApprovedOperation?

    init(
        manager: any LanguageServerManaging = LanguageServerManagerAdapter(),
        coordinateRenamePreview: @escaping CoordinateRenamePreview = { _ in }
    ) {
        self.manager = manager
        self.coordinateRenamePreview = coordinateRenamePreview
        eventTask = nil
        startObservingEvents()
    }

    var wasLogTruncated: Bool { discardedLogEntryCount > 0 }

    var runningServerCount: Int {
        statuses.lazy.filter { $0.state == .running }.count
    }

    /// Trusted UI calls this after obtaining a Powerbox-backed file lease. It
    /// changes only executable resolution; launch still requires exact approval.
    func authorizeExecutable(_ url: URL) async throws -> URL {
        try await manager.authorizeExecutable(url)
    }

    func revokeAllExecutableAuthorizations() async {
        await manager.revokeAllExecutables()
    }

    func status(for key: LanguageServerInstanceKey) -> LanguageServerStatus? {
        statusesByKey[key]
    }

    func diagnostics(for key: LanguageServerInstanceKey) -> [LanguageServerDiagnosticEntry] {
        diagnostics.filter { $0.key == key }
    }

    /// Returns editor diagnostics only for the current canonical file path,
    /// latest server generation, and exact `DocumentBuffer.revision`. Servers
    /// which omit publishDiagnostics.version remain visible in the panel but
    /// deliberately never receive an editor presentation snapshot.
    func diagnosticPresentationSnapshot(
        documentID: String, fileURL: URL?, documentRevision: UInt64,
        serverKey: LanguageServerInstanceKey
    ) -> LanguageServerDiagnosticPresentationSnapshot? {
        guard !documentID.isEmpty, let fileURL,
              let filePath = Self.canonicalFilePath(fileURL),
              let expectedVersion = Self.languageServerVersion(for: documentRevision)
        else { return nil }

        let key = DiagnosticDocumentKey(server: serverKey, filePath: filePath)
        let expectedIdentity = SynchronizedDocumentIdentity(
            documentID: documentID, documentRevision: documentRevision,
            documentVersion: expectedVersion
        )
        guard synchronizedDocumentIdentities[key] == expectedIdentity,
              let bucket = diagnosticBuckets[key],
              latestGenerationByKey[serverKey] == bucket.generation,
              bucket.documentVersion == expectedVersion else { return nil }
        return LanguageServerDiagnosticPresentationSnapshot(
            documentID: documentID, serverKey: serverKey, filePath: filePath,
            documentRevision: documentRevision,
            generation: bucket.generation,
            presentationRevision: bucket.presentationRevision,
            entries: bucket.entries
        )
    }

    func logs(for key: LanguageServerInstanceKey) -> [LanguageServerLogEntry] {
        logEntries.filter { $0.key == key }
    }

    /// Primarily useful to hosts which need to sequence an immediate startup,
    /// and to tests which must know that the AsyncStream observer is installed.
    func waitUntilObservingEvents() async {
        while observationState == .starting, !Task.isCancelled {
            await Task.yield()
        }
    }

    // MARK: - Lifecycle and document synchronization

    @discardableResult
    func start(root: URL, config: LanguageServerConfig) async -> LanguageServerInstanceKey? {
        await waitUntilObservingEvents()
        do {
            return try await manager.start(root: root, config: config)
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            requestApproval(configuration, for: .start(root: root, config: config))
            return nil
        } catch {
            present(error, title: .couldNotStart)
            return nil
        }
    }

    @discardableResult
    func synchronize(
        _ request: LanguageServerSyncRequest,
        documentID: String? = nil, documentRevision: UInt64? = nil
    ) async -> LanguageServerInstanceKey? {
        await waitUntilObservingEvents()
        do {
            let key = try await manager.synchronize(request)
            recordSynchronizedDocument(
                request, key: key, documentID: documentID,
                documentRevision: documentRevision
            )
            return key
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            requestApproval(
                configuration,
                for: .synchronize(
                    request, documentID: documentID, documentRevision: documentRevision
                )
            )
            return nil
        } catch {
            present(error, title: .couldNotSynchronize)
            return nil
        }
    }

    @discardableResult
    func closeDocument(
        root: URL, config: LanguageServerConfig, fileURL: URL
    ) async -> Bool {
        do {
            try await manager.closeDocument(root: root, config: config, fileURL: fileURL)
            removeDiagnostics(
                for: LanguageServerInstanceKey(root: root, config: config),
                fileURL: fileURL
            )
            return true
        } catch {
            present(error, title: .couldNotCloseDocument)
            return false
        }
    }

    func stop(_ key: LanguageServerInstanceKey) async {
        declineApproval(for: key)
        invalidateEvents(for: key)
        invalidateInteractiveRequest(for: key)
        await manager.stop(key)
        synchronizedDocumentIdentities = synchronizedDocumentIdentities.filter {
            $0.key.server != key
        }
        clearRetainedGeneration(for: key)
    }

    @discardableResult
    func restart(_ key: LanguageServerInstanceKey) async -> Bool {
        invalidateEvents(for: key)
        invalidateInteractiveRequest(for: key)
        do {
            try await manager.restart(key)
            return true
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            requestApproval(configuration, for: .restart(key))
            return false
        } catch {
            present(error, title: .couldNotRestart)
            return false
        }
    }

    /// Immediately cancels a server generation and any interactive result
    /// which could still arrive for that key.
    func cancel(_ key: LanguageServerInstanceKey) async {
        declineApproval(for: key)
        invalidateEvents(for: key)
        invalidateInteractiveRequest(for: key)
        await manager.cancel(key)
    }

    /// Cancels the currently active interactive request at the manager. This
    /// intentionally terminates that server generation because Core's public
    /// cancellation boundary is generation-scoped.
    func cancel() async {
        let key = activeInteractiveKey
        invalidateInteractiveRequest()
        if let key {
            invalidateEvents(for: key)
            await manager.cancel(key)
        }
    }

    func stopAll() async {
        declinePendingApproval()
        invalidateInteractiveRequest()
        for key in retainedServerOrder {
            invalidateEvents(for: key)
        }
        await manager.stopAll()
        synchronizedDocumentIdentities.removeAll()
        diagnosticBuckets.removeAll()
        diagnosticDocumentOrder.removeAll()
        rebuildDiagnostics()
    }

    func shutdown() async {
        await stopAll()
        stopObservingEvents()
    }

    /// Discards a late interactive result without terminating the server.
    func cancelInteractiveRequest() {
        invalidateInteractiveRequest()
    }

    func dismissIssue() { issue = nil }

    /// Formatting is coordinated by the document formatter, which owns the
    /// captured editor revision and result continuation. Errors deliberately
    /// propagate so the caller can preserve and replay its exact snapshot.
    func formatForDocument(
        _ request: LanguageServerRequest
    ) async throws -> LanguageServerResult? {
        try await manager.format(request)
    }

    /// Approves the exact server configuration on the same ephemeral manager
    /// scope used by lifecycle and interactive operations.
    func approveForDocumentFormatting(
        _ configuration: ToolExecutionConfiguration
    ) async {
        await manager.approve(configuration)
    }

    func confirmPendingApproval() async {
        guard let approval = pendingApproval,
              let operation = pendingApprovedOperation else { return }
        await manager.approve(approval.configuration)
        guard pendingApproval?.configuration == approval.configuration,
              pendingApprovedOperation == operation else { return }
        pendingApproval = nil
        pendingApprovedOperation = nil
        switch operation {
        case let .start(root, config):
            _ = await start(root: root, config: config)
        case let .synchronize(request, documentID, documentRevision):
            _ = await synchronize(
                request, documentID: documentID, documentRevision: documentRevision
            )
        case let .perform(request):
            _ = await performNonmutatingOutcome(request)
        case let .editorCompletion(request):
            editorCompletionResult = await completionForEditor(request)
        case let .rename(request):
            _ = await rename(request)
        case let .restart(key):
            _ = await restart(key)
        }
    }

    func declinePendingApproval() {
        pendingApproval = nil
        pendingApprovedOperation = nil
    }

    func clearLogs() {
        logEntries = []
        retainedLogUTF16Units = 0
        discardedLogEntryCount = 0
    }

    func clearInteractiveResult() {
        interactiveResult = nil
        interactiveResultMethod = nil
        interactiveResultKey = nil
    }

    func takeEditorCompletionResult() -> [LanguageCompletionItem]? {
        defer { editorCompletionResult = nil }
        return editorCompletionResult
    }

    // MARK: - Interactive language features

    /// Performs a non-mutating interactive request. Rename is intentionally
    /// routed through `rename(_:)`, which only emits a preview to the injected
    /// coordinator and therefore returns no generic result.
    @discardableResult
    func perform(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveResult? {
        if request.method == .rename {
            _ = await rename(request)
            return nil
        }
        switch await performNonmutatingOutcome(request) {
        case let .completed(result): return result
        case .awaitingApproval, .cancelled, .failed: return nil
        }
    }

    func completion(
        _ request: LanguageServerInteractiveRequest
    ) async -> [LanguageCompletionItem]? {
        guard validate(request, method: .completion) else { return nil }
        switch await performNonmutatingOutcome(request) {
        case let .completed(result): return result.completions ?? []
        case .awaitingApproval, .cancelled, .failed: return nil
        }
    }

    /// Completion is an ephemeral editor affordance rather than a result shown
    /// in the language-server inspector. It still shares approval, cancellation,
    /// and protocol bounds, but does not overwrite the panel's retained result.
    func completionForEditor(
        _ request: LanguageServerInteractiveRequest
    ) async -> [LanguageCompletionItem]? {
        guard validate(request, method: .completion) else { return nil }
        editorCompletionResult = nil
        let operation = beginInteractive(request, clearsRetainedResult: false)
        defer { finishInteractive(operation) }
        do {
            let result = try await manager.perform(request)
            guard isCurrent(operation) else { return nil }
            let completions = bounded(result).completions ?? []
            return completions
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            guard isCurrent(operation) else { return nil }
            requestApproval(configuration, for: .editorCompletion(request))
            return nil
        } catch {
            guard isCurrent(operation) else { return nil }
            if !Self.isCancellation(error) {
                present(error, title: .requestFailed)
            }
            return nil
        }
    }

    func hoverOutcome(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveOutcome<LanguageHover?> {
        guard validate(request, method: .hover) else {
            return .failed(issue?.message ?? "Invalid language server request.")
        }
        return (await performNonmutatingOutcome(request)).map(\.hover)
    }

    func hover(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageHover? {
        guard case let .completed(hover) = await hoverOutcome(request) else { return nil }
        return hover
    }

    func definitionOutcome(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveOutcome<[LanguageLocation]> {
        guard validate(request, method: .definition) else {
            return .failed(issue?.message ?? "Invalid language server request.")
        }
        return (await performNonmutatingOutcome(request)).map { $0.locations ?? [] }
    }

    func definition(
        _ request: LanguageServerInteractiveRequest
    ) async -> [LanguageLocation]? {
        guard case let .completed(locations) = await definitionOutcome(request) else {
            return nil
        }
        return locations
    }

    func referencesOutcome(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveOutcome<[LanguageLocation]> {
        guard validate(request, method: .references) else {
            return .failed(issue?.message ?? "Invalid language server request.")
        }
        return (await performNonmutatingOutcome(request)).map { $0.locations ?? [] }
    }

    func references(
        _ request: LanguageServerInteractiveRequest
    ) async -> [LanguageLocation]? {
        guard case let .completed(locations) = await referencesOutcome(request) else {
            return nil
        }
        return locations
    }

    /// Requests a rename preview and transfers it to the shell mutation
    /// coordinator. No edit application API exists in this controller.
    @discardableResult
    func renameOutcome(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveOutcome<Bool> {
        guard validate(request, method: .rename) else {
            return .failed(issue?.message ?? "Invalid language server request.")
        }
        let operation = beginInteractive(request)
        defer { finishInteractive(operation) }
        do {
            let preview = try await manager.renamePreview(request)
            guard isCurrent(operation) else { return .cancelled }
            try await coordinateRenamePreview(preview)
            guard isCurrent(operation) else { return .cancelled }
            return .completed(true)
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            guard isCurrent(operation) else { return .cancelled }
            requestApproval(configuration, for: .rename(request))
            return .awaitingApproval
        } catch {
            guard isCurrent(operation), !Self.isCancellation(error) else {
                return .cancelled
            }
            return .failed(present(error, title: .couldNotPreviewRename).message)
        }
    }

    @discardableResult
    func rename(_ request: LanguageServerInteractiveRequest) async -> Bool {
        guard case let .completed(didCoordinate) = await renameOutcome(request) else {
            return false
        }
        return didCoordinate
    }

    // MARK: - Event stream

    /// Internal for deterministic tests; production events arrive exclusively
    /// through the manager's bounded AsyncStream.
    func receive(_ event: LanguageServerEvent) {
        switch event {
        case let .status(status):
            guard accept(status: status) else { return }
            statusesByKey[status.key] = bounded(status)
            publishStatuses()

        case let .diagnostics(update):
            guard accept(
                key: update.key, generation: update.generation, sequence: update.sequence
            ) else { return }
            store(update)

        case let .log(entry):
            guard accept(
                key: entry.key, generation: entry.generation, sequence: entry.sequence
            ) else { return }
            append(entry)
        }
    }

    private func startObservingEvents() {
        guard eventTask == nil, observationState == .starting else { return }
        let manager = manager
        eventTask = Self.makeEventTask(manager: manager) { [weak self] phase in
            self?.consume(phase)
        }
    }

    private func stopObservingEvents() {
        eventTask?.cancel()
        eventTask = nil
        observationState = .finished
    }

    private static func makeEventTask(
        manager: any LanguageServerManaging,
        receive: @escaping @MainActor (ObservationPhase) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let events = await manager.events()
            receive(.ready)
            for await event in events {
                guard !Task.isCancelled else { break }
                receive(.event(event))
            }
            receive(.finished)
        }
    }

    private func consume(_ phase: ObservationPhase) {
        switch phase {
        case .ready:
            observationState = .active
        case let .event(event):
            receive(event)
        case .finished:
            observationState = .finished
            eventTask = nil
        }
    }

    private var eventTask: Task<Void, Never>? {
        get { eventTaskBox.eventTask }
        set { eventTaskBox.eventTask = newValue }
    }

    private func accept(key: LanguageServerInstanceKey, generation: UInt64) -> Bool {
        if let invalidated = invalidatedGenerationByKey[key] {
            guard generation > invalidated else { return false }
            invalidatedGenerationByKey[key] = nil
        }
        if let latest = latestGenerationByKey[key] {
            guard generation >= latest else { return false }
            if generation > latest {
                clearRetainedGeneration(for: key)
                latestSequenceByKey[key] = nil
                lastUnsequencedStateByKey[key] = nil
                if activeInteractiveKey == key || interactiveResultKey == key {
                    invalidateInteractiveRequest(for: key)
                }
            }
        }
        latestGenerationByKey[key] = generation
        retainServer(key)
        return true
    }

    private func accept(
        key: LanguageServerInstanceKey, generation: UInt64, sequence: UInt64
    ) -> Bool {
        guard accept(key: key, generation: generation) else { return false }
        if sequence > 0 {
            guard sequence > (latestSequenceByKey[key] ?? 0) else { return false }
            latestSequenceByKey[key] = sequence
        } else if latestSequenceByKey[key] != nil {
            return false
        }
        return true
    }

    private func retainServer(_ key: LanguageServerInstanceKey) {
        if !retainedServerOrder.contains(key) { retainedServerOrder.append(key) }
        while retainedServerOrder.count > Self.maximumServers {
            evictServer(retainedServerOrder.removeFirst())
        }
    }

    private func evictServer(_ key: LanguageServerInstanceKey) {
        if activeInteractiveKey == key || interactiveResultKey == key {
            invalidateInteractiveRequest(for: key)
        }
        latestGenerationByKey[key] = nil
        latestSequenceByKey[key] = nil
        lastUnsequencedStateByKey[key] = nil
        invalidatedGenerationByKey[key] = nil
        statusesByKey[key] = nil
        clearRetainedGeneration(for: key)
        publishStatuses()
    }

    private func clearRetainedGeneration(for key: LanguageServerInstanceKey) {
        statusesByKey[key] = nil

        let documents = diagnosticDocumentOrder.filter { $0.server == key }
        for document in documents { diagnosticBuckets[document] = nil }
        diagnosticDocumentOrder.removeAll { $0.server == key }
        rebuildDiagnostics()

        if logEntries.contains(where: { $0.key == key }) {
            logEntries.removeAll { $0.key == key }
            retainedLogUTF16Units = logEntries.reduce(0) { $0 + $1.text.utf16.count }
        }
    }

    private func invalidateEvents(for key: LanguageServerInstanceKey) {
        let current = latestGenerationByKey[key] ?? statusesByKey[key]?.generation
        if let current { invalidatedGenerationByKey[key] = current }
    }

    private func publishStatuses() {
        statuses = statusesByKey.values.sorted {
            $0.key.description < $1.key.description
        }
    }

    private func accept(status: LanguageServerStatus) -> Bool {
        guard accept(key: status.key, generation: status.generation) else { return false }
        if status.sequence > 0 {
            guard status.sequence > (latestSequenceByKey[status.key] ?? 0) else {
                return false
            }
            latestSequenceByKey[status.key] = status.sequence
            return true
        }
        if let previous = lastUnsequencedStateByKey[status.key],
           Self.stateRank(status.state) < Self.stateRank(previous) {
            return false
        }
        lastUnsequencedStateByKey[status.key] = status.state
        return true
    }

    private func store(_ update: LanguageServerDiagnosticsUpdate) {
        let boundedPath = LSPLogSanitizer.prefixUTF16(
            update.event.filePath,
            maximumUnits: LSPProtocolLimits.maximumDiagnosticPathCharacters
        )
        let path = Self.canonicalFilePath(URL(fileURLWithPath: boundedPath))
            ?? boundedPath
        let document = DiagnosticDocumentKey(server: update.key, filePath: path)
        if let previous = diagnosticBuckets[document],
           previous.generation == update.generation {
            if previous.documentVersion != nil, update.documentVersion == nil {
                // Preserve the exact batch for editor use. The unversioned
                // notification cannot prove which text snapshot it describes.
                return
            }
            if let previousVersion = previous.documentVersion,
               let incomingVersion = update.documentVersion,
               incomingVersion < previousVersion {
                return
            }
        }

        diagnosticDocumentOrder.removeAll { $0 == document }
        guard !update.event.diagnostics.isEmpty else {
            diagnosticBuckets[document] = nil
            rebuildDiagnostics()
            return
        }

        diagnosticRevision = next(diagnosticRevision)
        let revision = diagnosticRevision
        let entries = update.event.diagnostics
            .prefix(Self.maximumDiagnostics)
            .enumerated()
            .map { index, diagnostic in
                LanguageServerDiagnosticEntry(
                    id: .init(revision: revision, index: index),
                    key: update.key,
                    filePath: path,
                    diagnostic: bounded(diagnostic),
                    documentVersion: update.documentVersion,
                    generation: update.generation
                )
            }
        diagnosticBuckets[document] = DiagnosticBucket(
            generation: update.generation,
            documentVersion: update.documentVersion,
            presentationRevision: revision,
            entries: entries
        )
        diagnosticDocumentOrder.append(document)
        enforceDiagnosticLimits()
        rebuildDiagnostics()
    }

    private func enforceDiagnosticLimits() {
        var count = diagnosticBuckets.values.reduce(0) { $0 + $1.entries.count }
        while diagnosticDocumentOrder.count > Self.maximumDiagnosticDocuments ||
                count > Self.maximumDiagnostics {
            guard let oldest = diagnosticDocumentOrder.first else { break }
            diagnosticDocumentOrder.removeFirst()
            count -= diagnosticBuckets.removeValue(forKey: oldest)?.entries.count ?? 0
        }
    }

    private func rebuildDiagnostics() {
        diagnostics = diagnosticDocumentOrder.flatMap {
            diagnosticBuckets[$0]?.entries ?? []
        }
        diagnosticPresentationRevision = next(diagnosticPresentationRevision)
    }

    private func removeDiagnostics(
        for key: LanguageServerInstanceKey, fileURL: URL
    ) {
        guard let path = Self.canonicalFilePath(fileURL) else { return }
        let document = DiagnosticDocumentKey(server: key, filePath: path)
        diagnosticBuckets[document] = nil
        synchronizedDocumentIdentities[document] = nil
        diagnosticDocumentOrder.removeAll { $0 == document }
        rebuildDiagnostics()
    }

    private func recordSynchronizedDocument(
        _ request: LanguageServerSyncRequest, key: LanguageServerInstanceKey,
        documentID: String?, documentRevision: UInt64?
    ) {
        guard let documentID, !documentID.isEmpty, let documentRevision,
              Self.languageServerVersion(for: documentRevision) == request.version,
              let path = Self.canonicalFilePath(URL(fileURLWithPath: request.filePath)),
              Self.path(path, isContainedInRootPath: key.rootPath)
        else { return }
        let document = DiagnosticDocumentKey(server: key, filePath: path)
        synchronizedDocumentIdentities[document] = SynchronizedDocumentIdentity(
            documentID: documentID, documentRevision: documentRevision,
            documentVersion: request.version
        )
        // Diagnostics may be delivered while synchronize is still awaiting the
        // manager. Publish after recording the identity so SwiftUI retries the
        // snapshot lookup even if the diagnostic array itself did not change.
        diagnosticPresentationRevision = next(diagnosticPresentationRevision)
    }

    private func append(_ source: LanguageServerLogEntry) {
        let text = LSPLogSanitizer.boundedLog(
            source.text, maximumUTF16Units: Self.maximumLogEntryCharacters
        )
        guard !text.isEmpty else { return }
        let entry = LanguageServerLogEntry(
            key: source.key, root: source.root, stream: source.stream,
            level: source.level, text: text, timestamp: source.timestamp,
            generation: source.generation, sequence: source.sequence
        )
        logEntries.append(entry)
        retainedLogUTF16Units += text.utf16.count
        while logEntries.count > Self.maximumLogEntries ||
                retainedLogUTF16Units > Self.maximumLogCharacters {
            guard !logEntries.isEmpty else { break }
            let removed = logEntries.removeFirst()
            retainedLogUTF16Units -= removed.text.utf16.count
            discardedLogEntryCount = min(Int.max, discardedLogEntryCount + 1)
        }
    }

    // MARK: - Interactive operation safety

    private struct InteractiveOperation {
        let token: UInt64
        let key: LanguageServerInstanceKey
    }

    private func performNonmutatingOutcome(
        _ request: LanguageServerInteractiveRequest
    ) async -> LanguageServerInteractiveOutcome<LanguageServerInteractiveResult> {
        let operation = beginInteractive(request)
        defer { finishInteractive(operation) }
        do {
            let result = try await manager.perform(request)
            guard isCurrent(operation) else { return .cancelled }
            let retained = bounded(result)
            interactiveResult = retained
            interactiveResultMethod = request.method
            interactiveResultKey = operation.key
            interactiveResultRevision = next(interactiveResultRevision)
            return .completed(retained)
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            guard isCurrent(operation) else { return .cancelled }
            requestApproval(configuration, for: .perform(request))
            return .awaitingApproval
        } catch {
            guard isCurrent(operation), !Self.isCancellation(error) else {
                return .cancelled
            }
            return .failed(present(error, title: .requestFailed).message)
        }
    }

    private func beginInteractive(
        _ request: LanguageServerInteractiveRequest,
        clearsRetainedResult: Bool = true
    ) -> InteractiveOperation {
        interactiveToken = next(interactiveToken)
        let key = LanguageServerInstanceKey(
            root: URL(fileURLWithPath: request.root, isDirectory: true),
            config: request.config
        )
        activeInteractiveToken = interactiveToken
        activeInteractiveKey = key
        activeInteractiveMethod = request.method
        isInteractiveRequestRunning = true
        if clearsRetainedResult { clearInteractiveResult() }
        issue = nil
        return InteractiveOperation(token: interactiveToken, key: key)
    }

    private func finishInteractive(_ operation: InteractiveOperation) {
        guard activeInteractiveToken == operation.token,
              activeInteractiveKey == operation.key else { return }
        activeInteractiveToken = nil
        activeInteractiveKey = nil
        activeInteractiveMethod = nil
        isInteractiveRequestRunning = false
    }

    private func isCurrent(_ operation: InteractiveOperation) -> Bool {
        activeInteractiveToken == operation.token &&
            activeInteractiveKey == operation.key &&
            !Task.isCancelled
    }

    private func invalidateInteractiveRequest(
        for key: LanguageServerInstanceKey? = nil
    ) {
        if let key {
            let invalidatesActiveRequest = activeInteractiveKey == key
            let invalidatesRetainedResult = interactiveResultKey == key
            guard invalidatesActiveRequest || invalidatesRetainedResult else { return }
            if invalidatesActiveRequest {
                interactiveToken = next(interactiveToken)
                activeInteractiveToken = nil
                activeInteractiveKey = nil
                activeInteractiveMethod = nil
                isInteractiveRequestRunning = false
            }
            if invalidatesRetainedResult { clearInteractiveResult() }
            return
        }

        interactiveToken = next(interactiveToken)
        activeInteractiveToken = nil
        activeInteractiveKey = nil
        activeInteractiveMethod = nil
        isInteractiveRequestRunning = false
        clearInteractiveResult()
    }

    private func validate(
        _ request: LanguageServerInteractiveRequest, method: LanguageServerMethod
    ) -> Bool {
        guard request.method == method else {
            issue = LanguageServerPresentationIssue(
                title: .invalidRequest,
                message: .app(
                    english: "Expected \(method.rawValue), received \(request.method.rawValue).",
                    chinese: "预期为 \(method.rawValue)，实际收到 \(request.method.rawValue)。"
                )
            )
            return false
        }
        return true
    }

    // MARK: - Retention sanitizers

    private func bounded(_ status: LanguageServerStatus) -> LanguageServerStatus {
        var remaining = LSPProtocolLimits.maximumCapabilityCharacters
        var capabilities: [String] = []
        for value in status.capabilities.prefix(LSPProtocolLimits.maximumCapabilityNames) {
            guard remaining > 0 else { break }
            let separatorUnits = capabilities.isEmpty ? 0 : 2
            guard remaining >= separatorUnits else { break }
            remaining -= separatorUnits
            let retained = LSPLogSanitizer.prefixUTF16(value, maximumUnits: remaining)
            guard !retained.isEmpty || value.isEmpty else { break }
            capabilities.append(retained)
            remaining -= retained.utf16.count
        }
        let message = status.message.map {
            LSPLogSanitizer.prefixUTF16(
                $0, maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
            )
        }
        return LanguageServerStatus(
            key: status.key, root: status.root, config: status.config,
            state: status.state, generation: status.generation, sequence: status.sequence,
            capabilities: capabilities, message: message
        )
    }

    private func bounded(
        _ diagnostic: LanguageServerDiagnostic
    ) -> LanguageServerDiagnostic {
        let boundedCharacters = LSPLogSanitizer.prefixUTF16(
            diagnostic.message,
            maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
        )
        return LanguageServerDiagnostic(
            line: max(1, diagnostic.line),
            column: max(1, diagnostic.column),
            endLine: diagnostic.endLine.map { max(1, $0) },
            endColumn: diagnostic.endColumn.map { max(1, $0) },
            severity: diagnostic.severity,
            message: LSPLogSanitizer.prefixUTF8(
                boundedCharacters,
                maximumBytes: LSPProtocolLimits.maximumDiagnosticMessageBytes
            )
        )
    }

    private func bounded(
        _ result: LanguageServerInteractiveResult
    ) -> LanguageServerInteractiveResult {
        let completions = result.completions.map { values in
            values.prefix(Self.maximumCompletionItems).map { item in
                LanguageCompletionItem(
                    label: boundedInteractiveText(item.label),
                    detail: item.detail.map(boundedInteractiveText),
                    documentation: item.documentation.map(boundedInteractiveText),
                    insertText: item.insertText.map(boundedInteractiveText)
                )
            }
        }
        let hover = result.hover.map {
            LanguageHover(text: boundedInteractiveText($0.text))
        }
        let locations = result.locations.map { values in
            values.prefix(Self.maximumInteractiveLocations).map { location in
                LanguageLocation(
                    filePath: LSPLogSanitizer.prefixUTF16(
                        location.filePath,
                        maximumUnits: LSPProtocolLimits.maximumDiagnosticPathCharacters
                    ),
                    line: max(0, location.line),
                    character: max(0, location.character)
                )
            }
        }
        // `perform` is never used for rename, so retaining workspace edits
        // here would create an accidental mutation-capable side channel.
        return LanguageServerInteractiveResult(
            completions: completions, hover: hover, locations: locations,
            renameEdits: nil
        )
    }

    private func boundedInteractiveText(_ value: String) -> String {
        LSPLogSanitizer.prefixUTF16(
            value, maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
        )
    }

    @discardableResult
    private func present(
        _ error: any Error, title: LanguageServerPresentationIssue.Title
    ) -> LanguageServerPresentationIssue {
        let raw = (error as? any LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let presented = LanguageServerPresentationIssue(
            title: title,
            message: Self.presentationMessage(for: error, raw: raw)
        )
        issue = presented
        return presented
    }

    private static func presentationMessage(
        for error: any Error, raw: String? = nil
    ) -> LanguageServerPresentationIssue.Message {
        let raw = LSPLogSanitizer.prefixUTF16(
            raw ?? (error as? any LocalizedError)?.errorDescription
                ?? error.localizedDescription,
            maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
        )
        guard let error = error as? LanguageServerClientError else {
            return .verbatim(raw)
        }
        return .app(
            english: raw, chinese: localizedLanguageServerClientError(error)
        )
    }

    private static func localizedLanguageServerClientError(
        _ error: LanguageServerClientError
    ) -> String {
        switch error {
        case .approvalRequired:
            return "此语言服务器命令需要当前会话授权。"
        case .invalidRoot:
            return "语言服务器工作区根目录无效。"
        case let .fileOutsideRoot(path):
            return "语言服务器文档位于其工作区之外：\(path)"
        case .notRunning:
            return "语言服务器未运行。"
        case .operationInProgress:
            return "已有语言服务器生命周期操作正在进行。"
        case .stopped:
            return "语言服务器已停止。"
        case let .staleDocumentVersion(current, received):
            return "文档版本 \(received) 不晚于版本 \(current)。"
        case .documentVersionExhausted:
            return "语言服务器文档版本已耗尽。"
        case let .requestTimedOut(method):
            return "语言服务器请求“\(method)”超时。"
        case let .requestCancelled(method):
            return "语言服务器请求“\(method)”已取消。"
        case let .responseError(code, message):
            return "语言服务器错误 \(code)：\(message)"
        case let .invalidResponse(method):
            return "语言服务器返回了无效的 \(method) 响应。"
        case let .processTerminated(detail):
            return "语言服务器进程已终止：\(detail)"
        case let .inputQueueOverflow(maximum):
            return "语言服务器输入超过 \(maximum) 字节的队列上限。"
        }
    }

    private func requestApproval(
        _ configuration: ToolExecutionConfiguration,
        for operation: PendingApprovedOperation
    ) {
        issue = nil
        pendingApprovedOperation = operation
        pendingApproval = LanguageServerApprovalRequest(configuration: configuration)
    }

    private func declineApproval(for key: LanguageServerInstanceKey) {
        guard pendingApproval.map({
            LanguageServerInstanceKey(root: $0.configuration.root, config: LanguageServerConfig(
                command: $0.configuration.executable, args: $0.configuration.args
            ))
        }) == key else { return }
        declinePendingApproval()
    }

    private func next(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private static func languageServerVersion(for revision: UInt64) -> Int? {
        guard revision <= UInt64(Int.max) else { return nil }
        return Int(revision)
    }

    private static func canonicalFilePath(_ url: URL) -> String? {
        guard url.isFileURL,
              url.host == nil || url.host?.isEmpty == true,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.utf16.count <= LSPProtocolLimits.maximumDiagnosticPathCharacters else {
            return nil
        }
        return path
    }

    private static func path(_ path: String, isContainedInRootPath rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let file = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard file.count >= root.count else { return false }
        return zip(root, file).allSatisfy { $0.0 == $0.1 }
    }

    private static func stateRank(_ state: LanguageServerClientState) -> Int {
        switch state {
        case .starting: 0
        case .running: 1
        case .restarting: 2
        case .stopping: 3
        case .stopped, .failed: 4
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? LanguageServerClientError else { return false }
        switch error {
        case .requestCancelled, .stopped:
            return true
        default:
            return false
        }
    }
}
