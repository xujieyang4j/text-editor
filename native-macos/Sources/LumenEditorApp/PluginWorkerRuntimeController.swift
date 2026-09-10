import Combine
import Foundation
import LumenEditorCore

struct PluginWorkerDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let viewID: EditorViewID
    let revision: UInt64
    let text: String
    let language: String
    let selection: DirectedSelection
}

struct PluginWorkerCommandRoute: Identifiable, Equatable, Sendable {
    let pluginID: String
    let pluginName: String
    let commandID: String
    let title: String

    var id: String { "plugin-worker:\(pluginID):\(commandID)" }
}

struct PluginWorkerApprovalRequest: Identifiable, Equatable, Sendable {
    var id: ToolExecutionIdentity { configuration.identity }
    let pluginID: String
    let pluginName: String
    let configuration: ToolExecutionConfiguration

    var identityDescription: String {
        [
            "Plugin: \(pluginName) (\(pluginID))",
            "Purpose: \(configuration.kind.rawValue)",
            "Workspace: \(configuration.root.path)",
            "Host: \(configuration.executableURL.path)",
            "Worker digest: \(configuration.args.dropFirst().first ?? "unknown")",
            "Identity: \(configuration.identity.rawValue)"
        ].joined(separator: "\n")
    }
}

struct PluginWorkerRuntimeIssue: Identifiable, Equatable, Sendable {
    enum Message: Equatable, Sendable {
        case runtime(PluginWorkerRuntimeError)
        case protocolError(PluginWorkerProtocolError)
        case package(PluginWorkerPackageError)
        case pluginStore(PluginStoreError)
        case manifestValidation(PluginManifestValidationError)
        case toolExecution(ToolExecutionError)
        case toolProcess(ToolProcessRunnerError)
        case toolSession(ToolProcessSessionError)
        case verbatim(String)
    }

    let id = UUID()
    let titleCopy: AppLocalizedCopy
    let content: Message

    var title: String { EditorLocale.enUS.localizedApp(titleCopy) }
    var message: String { EditorLocale.enUS.localizedPluginWorkerIssue(content) }
}

enum PluginWorkerRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case hostUnavailable
    case pluginUnavailable(String)
    case commandUnavailable(String)
    case invalidHostMessage
    case requestMismatch
    case permissionDenied(PluginPermission)
    case workerExited(Int32, String)

    var errorDescription: String? {
        switch self {
        case .hostUnavailable: "The isolated plugin worker host is unavailable."
        case let .pluginUnavailable(id): "Plugin worker ‘\(id)’ is unavailable."
        case let .commandUnavailable(id): "Plugin command ‘\(id)’ is unavailable."
        case .invalidHostMessage: "The plugin worker returned an invalid message."
        case .requestMismatch: "The active document changed before the plugin result arrived."
        case let .permissionDenied(permission):
            "The plugin was not granted ‘\(permission.rawValue)’ permission."
        case let .workerExited(code, message):
            message.isEmpty
                ? "The plugin worker exited with status \(code)."
                : "The plugin worker exited with status \(code): \(message)"
        }
    }
}

struct PluginWorkerRuntimeTimeouts: Equatable, Sendable {
    var activation: TimeInterval
    var command: TimeInterval
    var deactivation: TimeInterval
    var processLifetime: TimeInterval

    init(
        activation: TimeInterval = 3,
        command: TimeInterval = 10,
        deactivation: TimeInterval = 1,
        processLifetime: TimeInterval = 24 * 60 * 60
    ) {
        precondition(activation > 0 && activation.isFinite)
        precondition(command > 0 && command.isFinite)
        precondition(deactivation > 0 && deactivation.isFinite)
        precondition(processLifetime > 0 && processLifetime.isFinite)
        self.activation = activation
        self.command = command
        self.deactivation = deactivation
        self.processLifetime = processLifetime
    }
}

/// App-facing lifecycle owner for isolated, persistent plugin helpers. Worker
/// code receives only permission-filtered JSON and never an application object.
@MainActor
final class PluginWorkerRuntimeController: ObservableObject {
    typealias DocumentProvider = @MainActor () -> PluginWorkerDocumentSnapshot?
    typealias ReplaceDocument = @MainActor (
        _ pluginID: String, _ snapshot: PluginWorkerDocumentSnapshot, _ text: String
    ) async -> Bool
    typealias Notify = @MainActor (String) -> Void

    @Published private(set) var commandRoutes: [PluginWorkerCommandRoute] = []
    @Published private(set) var pendingApproval: PluginWorkerApprovalRequest?
    @Published private(set) var issue: PluginWorkerRuntimeIssue?
    @Published private(set) var isRunning = false

    private let runner: any PluginWorkerProcessRunning
    private let approvals: ToolApprovalStore
    private let scope: ToolApprovalScope
    private let hostExecutableURL: URL?
    private let documentProvider: DocumentProvider
    private let replaceDocument: ReplaceDocument
    private let notify: Notify
    private let timeouts: PluginWorkerRuntimeTimeouts
    private var workspaceRoot: URL?
    private var packages: [String: PluginWorkerPackage] = [:]
    private var connections: [String: PluginWorkerConnection] = [:]
    private var pendingPackages: [PluginWorkerPackage] = []
    private var generation: UInt64 = 0
    private var pendingWorkerOperations = 0

    var loadedPluginIDs: Set<String> { Set(connections.keys) }

    init(
        runner: any PluginWorkerProcessRunning = PluginWorkerProcessRunnerAdapter(),
        approvals: ToolApprovalStore = ToolApprovalStore(),
        scope: ToolApprovalScope = ToolApprovalScope(windowID: UUID(), sessionID: UUID()),
        hostExecutableURL: URL? = PluginWorkerRuntimeController.defaultHostExecutableURL(),
        document: @escaping DocumentProvider = { nil },
        replaceDocument: @escaping ReplaceDocument = { _, _, _ in false },
        notify: @escaping Notify = { _ in },
        timeouts: PluginWorkerRuntimeTimeouts = PluginWorkerRuntimeTimeouts()
    ) {
        self.runner = runner
        self.approvals = approvals
        self.scope = scope
        self.hostExecutableURL = hostExecutableURL
        documentProvider = document
        self.replaceDocument = replaceDocument
        self.notify = notify
        self.timeouts = timeouts
    }

    func update(workspaceRoot: URL?, plugins: [InstalledPlugin], store: PluginStore?) async {
        let previousRoot = self.workspaceRoot
        await deactivateAll(releaseWorkspaceState: false)
        let updateGeneration = generation
        guard !Task.isCancelled else { return }
        let normalizedRoot = workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()
        if let previousRoot, previousRoot != normalizedRoot {
            _ = try? await approvals.releaseRoot(previousRoot, in: scope)
        }
        guard !Task.isCancelled, generation == updateGeneration else { return }
        self.workspaceRoot = normalizedRoot
        issue = nil
        guard let store, self.workspaceRoot != nil else { return }

        var loaded: [PluginWorkerPackage] = []
        for plugin in plugins where plugin.isEnabled && plugin.manifest.extensionManifest != nil {
            guard !Task.isCancelled, generation == updateGeneration else { return }
            do { loaded.append(try store.loadWorkerPackage(for: plugin)) }
            catch { present(error, title: .couldNotLoadPluginWorker) }
        }
        guard !Task.isCancelled, generation == updateGeneration else { return }
        packages = Dictionary(uniqueKeysWithValues: loaded.map { ($0.pluginID, $0) })
        pendingPackages = loaded
        await activateNextPackageIfPossible(requiredGeneration: updateGeneration)
    }

    func confirmPendingApproval() async {
        let approvalGeneration = generation
        guard let request = pendingApproval,
              let package = pendingPackages.first,
              package.pluginID == request.pluginID else { return }
        _ = await approvals.approve(request.configuration, in: scope)
        guard generation == approvalGeneration, !Task.isCancelled,
              pendingApproval == request,
              pendingPackages.first?.pluginID == package.pluginID else {
            return
        }
        pendingApproval = nil
        pendingPackages.removeFirst()
        await activate(
            package, configuration: request.configuration,
            requiredGeneration: approvalGeneration
        )
        await activateNextPackageIfPossible(requiredGeneration: approvalGeneration)
    }

    func declinePendingApproval() {
        if !pendingPackages.isEmpty { pendingPackages.removeFirst() }
        pendingApproval = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activateNextPackageIfPossible(requiredGeneration: self.generation)
        }
    }

    @discardableResult
    func runCommand(routeID: String) async -> Bool {
        guard let route = commandRoutes.first(where: { $0.id == routeID }),
              let package = packages[route.pluginID],
              let connection = connections[route.pluginID] else {
            present(
                PluginWorkerRuntimeError.commandUnavailable(routeID),
                title: .couldNotRunPluginCommand
            )
            return false
        }
        return await performRequest(
            package: package, connection: connection,
            kind: .runCommand, commandID: route.commandID,
            timeout: timeouts.command, requiresDocument: false
        )
    }

    func deactivateAll(releaseWorkspaceState: Bool = true) async {
        let wasRunning = isRunning
        generation &+= 1
        let teardownGeneration = generation
        let active = connections
        connections = [:]
        if wasRunning {
            for connection in active.values { await connection.cancel() }
        } else {
            for (pluginID, connection) in active {
                if let package = packages[pluginID] {
                    await sendDeactivation(
                        package: package, connection: connection,
                        timeout: timeouts.deactivation
                    )
                }
                await connection.close(gracefulExitTimeout: timeouts.deactivation)
            }
        }
        await runner.cancelAll()
        guard generation == teardownGeneration else { return }
        if releaseWorkspaceState, let workspaceRoot {
            _ = try? await approvals.releaseRoot(workspaceRoot, in: scope)
            guard generation == teardownGeneration else { return }
        }
        packages = [:]
        if releaseWorkspaceState { workspaceRoot = nil }
        pendingPackages = []
        pendingApproval = nil
        commandRoutes = []
        isRunning = false
        pendingWorkerOperations = 0
    }

    private func sendDeactivation(
        package: PluginWorkerPackage,
        connection: PluginWorkerConnection,
        timeout: TimeInterval
    ) async {
        let context = PluginWorkerContext(permissions: package.permissions)
        let requestID = UUID().uuidString.lowercased()
        do {
            let responses = try await connection.request(
                PluginWorkerRequest(
                    type: .deactivate, requestID: requestID, context: context
                ),
                timeout: timeout
            )
            try ensureCompleted(responses)
        } catch {
            await connection.cancel()
        }
    }

    func cancel() async {
        generation &+= 1
        let active = connections.values
        connections = [:]
        for connection in active { await connection.cancel() }
        await runner.cancelAll()
        commandRoutes = []
        pendingPackages = []
        pendingApproval = nil
        isRunning = false
        pendingWorkerOperations = 0
    }

    func dismissIssue() { issue = nil }

    func approve(_ request: PluginWorkerApprovalRequest) async {
        guard pendingApproval == request else { return }
        await confirmPendingApproval()
    }

    private func activateNextPackageIfPossible(requiredGeneration: UInt64? = nil) async {
        let activationGeneration = requiredGeneration ?? generation
        guard generation == activationGeneration, !Task.isCancelled,
              pendingApproval == nil, !pendingPackages.isEmpty else {
            return
        }
        let package = pendingPackages[0]
        do {
            let configuration = try configuration(for: package)
            if await approvals.isApproved(configuration, in: scope) {
                guard generation == activationGeneration, !Task.isCancelled,
                      pendingPackages.first?.pluginID == package.pluginID else { return }
                pendingPackages.removeFirst()
                await activate(
                    package, configuration: configuration,
                    requiredGeneration: activationGeneration
                )
                await activateNextPackageIfPossible(requiredGeneration: activationGeneration)
            } else {
                guard generation == activationGeneration, !Task.isCancelled else { return }
                pendingApproval = PluginWorkerApprovalRequest(
                    pluginID: package.pluginID, pluginName: package.pluginName,
                    configuration: configuration
                )
            }
        } catch {
            guard generation == activationGeneration, !Task.isCancelled else { return }
            pendingPackages.removeFirst()
            present(error, title: .couldNotLoadPluginWorker)
            await activateNextPackageIfPossible(requiredGeneration: activationGeneration)
        }
    }

    private func activate(
        _ package: PluginWorkerPackage,
        configuration: ToolExecutionConfiguration,
        requiredGeneration: UInt64? = nil
    ) async {
        let activationGeneration = requiredGeneration ?? generation
        var startedConnection: PluginWorkerConnection?
        do {
            let started = try await startConnection(
                package: package, configuration: configuration
            )
            startedConnection = started.connection
            guard generation == activationGeneration, !Task.isCancelled else {
                await started.connection.cancel()
                return
            }
            try await handle(
                started.responses, requestID: started.requestID,
                package: package, snapshot: nil
            )
            guard generation == activationGeneration, !Task.isCancelled else {
                await started.connection.cancel()
                return
            }
            let connection = started.connection
            connections[package.pluginID] = connection
            let succeeded = await performRequest(
                package: package, connection: connection, kind: .activate,
                commandID: nil, timeout: timeouts.activation,
                requiresDocument: false
            )
            if !succeeded {
                await connection.cancel()
                if connections[package.pluginID]?.id == connection.id {
                    connections[package.pluginID] = nil
                    commandRoutes.removeAll { $0.pluginID == package.pluginID }
                }
            }
        } catch is CancellationError {
            await startedConnection?.cancel()
        } catch ToolExecutionError.cancelled {
            await startedConnection?.cancel()
        } catch {
            await startedConnection?.cancel()
            guard generation == activationGeneration else { return }
            present(error, title: .couldNotStartPluginWorker)
        }
    }

    private func startConnection(
        package: PluginWorkerPackage,
        configuration: ToolExecutionConfiguration
    ) async throws -> (
        connection: PluginWorkerConnection,
        responses: [PluginWorkerResponse],
        requestID: String
    ) {
        let command = try configuration.makeCommand(limits: ToolProcessLimits(
            timeout: timeouts.processLifetime,
            maximumStandardInputBytes: PluginWorkerProtocol.maximumMessageBytes,
            maximumStandardOutputBytes: PluginWorkerProtocol.maximumProcessOutputBytes,
            maximumRetainedStandardOutputBytes:
                PluginWorkerProtocol.maximumRetainedProcessOutputBytes,
            maximumStandardErrorBytes: 256 * 1_024
        ))
        let connection = try await PluginWorkerConnection.start(
            runner: runner, command: command,
            onExit: { [weak self] connectionID, error in
                Task { @MainActor [weak self] in
                    self?.connectionDidExit(
                        connectionID, pluginID: package.pluginID, error: error
                    )
                }
            }
        )
        let loadID = UUID().uuidString.lowercased()
        let responses = try await connection.request(
            PluginWorkerRequest(
                type: .load, requestID: loadID, source: package.source,
                sourceSHA256: package.sourceIntegrity.rawValue
            ),
            timeout: timeouts.activation
        )
        try ensureCompleted(responses)
        return (connection, responses, loadID)
    }

    private func performRequest(
        package: PluginWorkerPackage,
        connection: PluginWorkerConnection,
        kind: PluginWorkerRequestKind,
        commandID: String?,
        timeout: TimeInterval,
        requiresDocument: Bool,
        updatesBusyState: Bool = true
    ) async -> Bool {
        guard connections[package.pluginID]?.id == connection.id else { return false }
        let document = documentProvider()
        if requiresDocument, document == nil {
            present(
                PluginWorkerRuntimeError.pluginUnavailable(package.pluginID),
                title: .couldNotRunPluginWorker
            )
            return false
        }
        let context: PluginWorkerContext
        do {
            let readableDocument: PluginWorkerDocumentContext?
            if package.permissions.contains(.documentRead), let document {
                readableDocument = try PluginWorkerDocumentContext(
                    text: document.text, language: document.language,
                    selection: PluginWorkerSelection(
                        from: document.selection.from, to: document.selection.to
                    )
                )
            } else {
                readableDocument = nil
            }
            context = PluginWorkerContext(
                permissions: package.permissions, document: readableDocument
            )
        } catch {
            present(error, title: .couldNotBuildPluginContext)
            return false
        }

        let requestGeneration = generation
        if updatesBusyState {
            pendingWorkerOperations += 1
            isRunning = true
        }
        let requestID = UUID().uuidString.lowercased()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                let responses = try await connection.request(
                    PluginWorkerRequest(
                        type: kind, requestID: requestID,
                        commandID: commandID, context: context
                    ),
                    timeout: timeout
                )
                guard generation == requestGeneration, !Task.isCancelled,
                      connections[package.pluginID]?.id == connection.id else { return false }
                try await handle(
                    responses, requestID: requestID, package: package, snapshot: document
                )
                return true
            } catch is CancellationError {
                if connections[package.pluginID]?.id == connection.id {
                    connections[package.pluginID] = nil
                    commandRoutes.removeAll { $0.pluginID == package.pluginID }
                }
                return false
            } catch ToolExecutionError.cancelled {
                if connections[package.pluginID]?.id == connection.id {
                    connections[package.pluginID] = nil
                    commandRoutes.removeAll { $0.pluginID == package.pluginID }
                }
                return false
            } catch {
                guard generation == requestGeneration else { return false }
                if connections[package.pluginID]?.id == connection.id {
                    connections[package.pluginID] = nil
                    commandRoutes.removeAll { $0.pluginID == package.pluginID }
                }
                await connection.cancel()
                present(error, title: .pluginWorkerFailed)
                return false
            }
        }
        let succeeded = await task.value
        if updatesBusyState, generation == requestGeneration {
            pendingWorkerOperations = max(0, pendingWorkerOperations - 1)
            isRunning = pendingWorkerOperations > 0
        }
        return succeeded
    }

    private func configuration(
        for package: PluginWorkerPackage
    ) throws -> ToolExecutionConfiguration {
        guard let workspaceRoot, let hostExecutableURL else {
            throw PluginWorkerRuntimeError.hostUnavailable
        }
        let resolver = try ToolExecutableResolver(
            allowedExecutables: ["LumenPluginWorker": hostExecutableURL]
        )
        return try ToolExecutionConfiguration(
            kind: .pluginWorker, executable: hostExecutableURL.path,
            args: [package.pluginID, package.sourceIntegrity.rawValue]
                + package.permissions.map(\.rawValue).sorted(),
            cwd: workspaceRoot, authorizedRoot: workspaceRoot, resolver: resolver
        )
    }

    static func makeDocumentSnapshot(model: AppModel) -> PluginWorkerDocumentSnapshot? {
        let paneIndex = model.paneLayout.activePaneIndex
        guard model.paneLayout.panes.indices.contains(paneIndex),
              let document = model.activeDocument(inPaneAt: paneIndex) else { return nil }
        let selection = model.selection(
            for: document.sessionDocumentID,
            viewID: model.paneLayout.panes[paneIndex].viewID
        ).main
        return PluginWorkerDocumentSnapshot(
            documentID: document.sessionDocumentID,
            viewID: model.paneLayout.panes[paneIndex].viewID,
            revision: document.buffer.revision,
            text: document.buffer.text,
            language: document.language,
            selection: selection
        )
    }

    static func applyReplacement(
        _ text: String,
        from snapshot: PluginWorkerDocumentSnapshot,
        to model: AppModel
    ) -> Bool {
        let paneIndex = model.paneLayout.activePaneIndex
        guard model.paneLayout.panes.indices.contains(paneIndex),
              model.paneLayout.panes[paneIndex].viewID == snapshot.viewID,
              let document = model.activeDocument(inPaneAt: paneIndex),
              document.sessionDocumentID == snapshot.documentID,
              document.buffer.revision == snapshot.revision else { return false }
        guard let transaction = try? TextTransaction(
            edits: [TextEdit(
                from: 0, to: document.buffer.utf16Length, insert: text
            )],
            selection: .cursor(at: text.utf16.count),
            expectedRevision: snapshot.revision
        ) else { return false }
        return model.apply(transaction, to: document, inPaneAt: paneIndex)
    }

    static func production(
        model: AppModel,
        approvals: ToolApprovalStore,
        scope: ToolApprovalScope,
        notify: @escaping Notify = { _ in }
    ) -> PluginWorkerRuntimeController {
        PluginWorkerRuntimeController(
            approvals: approvals, scope: scope,
            document: { makeDocumentSnapshot(model: model) },
            replaceDocument: { _, snapshot, text in
                applyReplacement(text, from: snapshot, to: model)
            },
            notify: notify
        )
    }

    private func handle(
        _ responses: [PluginWorkerResponse],
        requestID: String,
        package: PluginWorkerPackage,
        snapshot: PluginWorkerDocumentSnapshot?
    ) async throws {
        try ensureCompleted(responses)
        var routes: [PluginWorkerCommandRoute] = []
        var notifications: [String] = []
        var replacement: String?
        for response in responses where response.type != .completed {
            guard response.requestID == requestID else {
                throw PluginWorkerRuntimeError.invalidHostMessage
            }
            switch response.type {
            case .registerCommand:
                guard let id = response.id, !id.isEmpty, let title = response.title else {
                    throw PluginWorkerRuntimeError.invalidHostMessage
                }
                guard let contribution = PluginManifestSecurity.sanitizeRegisteredCommand(
                    id: id, title: title
                ) else { throw PluginWorkerRuntimeError.invalidHostMessage }
                let route = PluginWorkerCommandRoute(
                    pluginID: package.pluginID, pluginName: package.pluginName,
                    commandID: contribution.id, title: contribution.title
                )
                routes.removeAll { $0.id == route.id }
                guard routes.count < PluginWorkerProtocol.maximumCommandsPerWorker else {
                    throw PluginWorkerProtocolError.tooManyMessages(
                        maximum: PluginWorkerProtocol.maximumCommandsPerWorker
                    )
                }
                routes.append(route)
            case .replaceDocument:
                guard package.permissions.contains(.documentEdit) else {
                    throw PluginWorkerRuntimeError.permissionDenied(.documentEdit)
                }
                guard replacement == nil, let snapshot, let text = response.text,
                      text.utf8.count <= PluginWorkerProtocol.maximumReplacementBytes else {
                    throw PluginWorkerRuntimeError.invalidHostMessage
                }
                replacement = text
            case .notify:
                guard let text = response.text else {
                    throw PluginWorkerRuntimeError.invalidHostMessage
                }
                notifications.append(
                    package.pluginName + ": "
                        + PluginManifestSecurity.sanitizeWorkerNotification(text)
                )
            case .completed, .failed:
                throw PluginWorkerRuntimeError.invalidHostMessage
            }
        }
        if let replacement {
            guard let snapshot,
                  await replaceDocument(package.pluginID, snapshot, replacement) else {
                throw PluginWorkerRuntimeError.requestMismatch
            }
        }
        for route in routes {
            commandRoutes.removeAll { $0.id == route.id }
            commandRoutes.append(route)
        }
        for notification in notifications { notify(notification) }
    }

    private func ensureCompleted(_ responses: [PluginWorkerResponse]) throws {
        guard responses.last?.type == .completed,
              responses.allSatisfy({ $0.type != .failed }) else {
            throw PluginWorkerRuntimeError.invalidHostMessage
        }
    }

    private func connectionDidExit(
        _ connectionID: UUID,
        pluginID: String,
        error: any Error
    ) {
        guard connections[pluginID]?.id == connectionID else { return }
        connections[pluginID] = nil
        commandRoutes.removeAll { $0.pluginID == pluginID }
        present(error, title: .pluginWorkerExited)
    }

    private static func defaultHostExecutableURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/LumenPluginWorker")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("LumenPluginWorker")
        return development.flatMap {
            FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
        }
    }

    private func present(_ error: any Error, title: AppLocalizedCopy) {
        issue = PluginWorkerRuntimeIssue(
            titleCopy: title, content: Self.presentationMessage(for: error)
        )
    }

    static func presentationMessage(for error: any Error) -> PluginWorkerRuntimeIssue.Message {
        if let error = error as? PluginWorkerRuntimeError {
            if case let .workerExited(code, standardError) = error {
                return .runtime(.workerExited(code, bounded(standardError, 2_000)))
            }
            return .runtime(error)
        }
        if let error = error as? PluginWorkerProtocolError {
            if case let .workerFailure(message) = error {
                return .protocolError(.workerFailure(bounded(message, 2_000)))
            }
            return .protocolError(error)
        }
        if let error = error as? PluginWorkerPackageError { return .package(error) }
        if let error = error as? PluginStoreError { return .pluginStore(error) }
        if let error = error as? PluginManifestValidationError {
            return .manifestValidation(error)
        }
        if let error = error as? ToolExecutionError { return .toolExecution(error) }
        if let error = error as? ToolProcessRunnerError {
            if case let .launchFailed(detail) = error {
                return .toolProcess(.launchFailed(bounded(detail, 2_000)))
            }
            return .toolProcess(error)
        }
        if let error = error as? ToolProcessSessionError { return .toolSession(error) }
        return .verbatim(bounded(error.localizedDescription, 2_000))
    }

    private static func bounded(_ value: String, _ maximumUTF16Count: Int) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterCount = value[end..<next].utf16.count
            guard count + characterCount <= maximumUTF16Count else { break }
            count += characterCount
            end = next
        }
        return String(value[..<end])
    }
}
