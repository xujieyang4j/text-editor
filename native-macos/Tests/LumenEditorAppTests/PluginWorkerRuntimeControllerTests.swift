import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class PluginWorkerRuntimeControllerTests: XCTestCase {
    private let host = URL(fileURLWithPath: "/tmp/LumenPluginWorker")
    private let scope = ToolApprovalScope(windowID: "window", sessionID: "session")

    func testExactWorkerConfigurationRequiresApproval() async throws {
        let runner = WorkerRunnerStub()
        let approvals = ToolApprovalStore()
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host
        )
        let fixture = try pluginFixture(permissions: [.documentRead])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        let expectedConfiguration = try configuration(package, root: root)

        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )

        let approval = try XCTUnwrap(runtime.pendingApproval)
        XCTAssertEqual(approval.configuration.kind, .pluginWorker)
        XCTAssertTrue(approval.configuration.args.contains("document-read"))
        XCTAssertTrue(approval.identityDescription.contains(package.sourceIntegrity.rawValue))
        XCTAssertEqual(approval.configuration, expectedConfiguration)
        let startCount = await runner.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testApprovedWorkerActivatesRegistersAndRunsDynamicCommand() async throws {
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed],
            [.register(id: "uppercase", title: "Uppercase"), .completed],
            [.notify("done"), .completed]
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        var notifications: [String] = []
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host, notify: { notifications.append($0) }
        )
        _ = await approvals.approve(try configuration(package, root: root), in: scope)

        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )
        XCTAssertEqual(runtime.commandRoutes.map(\.commandID), ["uppercase"])

        let didRun = await runtime.runCommand(
            routeID: "plugin-worker:worker:uppercase"
        )

        XCTAssertTrue(didRun)
        XCTAssertEqual(notifications, ["Worker: done"])
        let requestKinds = await runner.requests.map(\.type)
        XCTAssertEqual(requestKinds, [.load, .activate, .runCommand])
        let startedCommands = await runner.startedCommands
        let command = try XCTUnwrap(startedCommands.first)
        XCTAssertEqual(
            command.maximumStandardOutputBytes,
            PluginWorkerProtocol.maximumProcessOutputBytes
        )
        XCTAssertEqual(
            command.maximumRetainedStandardOutputBytes,
            PluginWorkerProtocol.maximumRetainedProcessOutputBytes
        )
    }

    func testDocumentReadIsFilteredAndEditNeedsPermission() async throws {
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed],
            [.register(id: "edit", title: "Edit"), .completed],
            [.replace("changed"), .completed]
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [.documentRead])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        var replacementCalls = 0
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host,
            document: { Self.documentSnapshot },
            replaceDocument: { _, _, _ in replacementCalls += 1; return true }
        )
        _ = await approvals.approve(try configuration(package, root: root), in: scope)
        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )

        let didRun = await runtime.runCommand(routeID: "plugin-worker:worker:edit")

        XCTAssertFalse(didRun)
        XCTAssertEqual(replacementCalls, 0)
        XCTAssertEqual(runtime.issue?.title, "Plugin Worker Failed")
        let documentText = await runner.requests.last?.context?.document?.text
        XCTAssertEqual(documentText, "secret")
    }

    func testNoReadPermissionRemovesDocumentContext() async throws {
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed],
            [.register(id: "inspect", title: "Inspect"), .completed],
            [.completed]
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host, document: { Self.documentSnapshot }
        )
        _ = await approvals.approve(try configuration(package, root: root), in: scope)
        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )

        let didRun = await runtime.runCommand(routeID: "plugin-worker:worker:inspect")
        let documentContext = await runner.requests.last?.context?.document
        XCTAssertTrue(didRun)
        XCTAssertNil(documentContext)
    }

    func testTimeoutCancelsCrashedConnectionAndRemovesRoutes() async throws {
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed],
            [.register(id: "slow", title: "Slow"), .completed],
            []
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host,
            timeouts: PluginWorkerRuntimeTimeouts(
                activation: 0.1, command: 0.01,
                deactivation: 0.01, processLifetime: 10
            )
        )
        _ = await approvals.approve(try configuration(package, root: root), in: scope)
        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )

        let didRun = await runtime.runCommand(routeID: "plugin-worker:worker:slow")
        XCTAssertFalse(didRun)
        XCTAssertTrue(runtime.commandRoutes.isEmpty)
        let sessionCancelCount = await runner.sessionCancelCount
        XCTAssertGreaterThanOrEqual(sessionCancelCount, 1)
    }

    func testDeactivateRunsBeforeWorkspaceTeardownAndRevokesApproval() async throws {
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed], [.completed], [.completed]
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [])
        let package = fixture.package
        let root = fixture.store.workspaceURL
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host
        )
        let approved = try configuration(package, root: root)
        _ = await approvals.approve(approved, in: scope)
        await runtime.update(
            workspaceRoot: root, plugins: [fixture.plugin], store: fixture.store
        )

        await runtime.update(workspaceRoot: nil, plugins: [], store: nil)

        let requestKinds = await runner.requests.map(\.type)
        let remainsApproved = await approvals.isApproved(approved, in: scope)
        XCTAssertEqual(requestKinds, [.load, .activate, .deactivate])
        XCTAssertFalse(remainsApproved)
        XCTAssertTrue(runtime.loadedPluginIDs.isEmpty)
    }

    func testResponseChannelAllowsMaximumMessagesPlusCompletion() async throws {
        let templates = Array(
            repeating: WorkerResponseTemplate.notify("n"),
            count: PluginWorkerProtocol.maximumMessagesPerRequest
        ) + [.completed]
        let runner = WorkerRunnerStub(eventsByRequest: [templates])
        let connection = try await PluginWorkerConnection.start(
            runner: runner, command: try workerCommand()
        )

        let responses = try await connection.request(
            PluginWorkerRequest(
                type: .activate, requestID: "maximum",
                context: PluginWorkerContext(permissions: [])
            ),
            timeout: 1
        )

        XCTAssertEqual(
            responses.count, PluginWorkerProtocol.maximumWireMessagesPerRequest
        )
        XCTAssertEqual(responses.last?.type, .completed)
        await connection.cancel()
    }

    func testWorkerFailureResponsePreservesCollidingExternalText() async throws {
        let collision = "The isolated plugin worker host is unavailable."
        let runner = WorkerRunnerStub(eventsByRequest: [
            [.completed],
            [.register(id: "fail", title: "Fail"), .completed],
            [.failed(collision)]
        ])
        let approvals = ToolApprovalStore()
        let fixture = try pluginFixture(permissions: [])
        let runtime = PluginWorkerRuntimeController(
            runner: runner, approvals: approvals, scope: scope,
            hostExecutableURL: host
        )
        _ = await approvals.approve(
            try configuration(fixture.package, root: fixture.store.workspaceURL),
            in: scope
        )
        await runtime.update(
            workspaceRoot: fixture.store.workspaceURL,
            plugins: [fixture.plugin], store: fixture.store
        )

        XCTAssertFalse(await runtime.runCommand(routeID: "plugin-worker:worker:fail"))
        let issue = try XCTUnwrap(runtime.issue)
        XCTAssertEqual(issue.titleCopy, .pluginWorkerFailed)
        XCTAssertEqual(
            issue.content,
            .protocolError(.workerFailure(collision))
        )
        XCTAssertEqual(EditorLocale.enUS.localizedPluginWorkerIssue(issue.content), collision)
        XCTAssertEqual(EditorLocale.zhCN.localizedPluginWorkerIssue(issue.content), collision)
    }

    func testPresentationClassificationBoundsOnlyExternalWorkerPayloads() {
        let collision = "The plugin worker returned an invalid message."
        XCTAssertEqual(
            PluginWorkerRuntimeController.presentationMessage(
                for: PluginWorkerProtocolError.workerFailure(collision)
            ),
            .protocolError(.workerFailure(collision))
        )

        let stderr = "stderr: 中文\n" + String(repeating: "🙂", count: 2_100)
        let content = PluginWorkerRuntimeController.presentationMessage(
            for: PluginWorkerRuntimeError.workerExited(9, stderr)
        )
        guard case let .runtime(.workerExited(code, boundedStderr)) = content else {
            return XCTFail("Expected a typed worker exit")
        }
        XCTAssertEqual(code, 9)
        XCTAssertLessThanOrEqual(boundedStderr.utf16.count, 2_000)
        XCTAssertTrue(stderr.hasPrefix(boundedStderr))
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginWorkerIssue(content),
            "插件 Worker 已退出，状态为 9：" + boundedStderr
        )
    }

    private static let documentSnapshot = PluginWorkerDocumentSnapshot(
        documentID: "document", viewID: .default, revision: 7, text: "secret",
        language: "Plain Text", selection: DirectedSelection(anchor: 0, head: 6)
    )

    private func configuration(
        _ package: PluginWorkerPackage,
        root: URL
    ) throws -> ToolExecutionConfiguration {
        let resolver = try ToolExecutableResolver(
            allowedExecutables: ["LumenPluginWorker": host]
        )
        return try ToolExecutionConfiguration(
            kind: .pluginWorker, executable: host.path,
            args: [package.pluginID, package.sourceIntegrity.rawValue]
                + package.permissions.map(\.rawValue).sorted(),
            cwd: root, authorizedRoot: root, resolver: resolver
        )
    }

    private func workerCommand() throws -> ToolCommand {
        try ToolExecutionConfiguration(
            kind: .pluginWorker, executable: host.path,
            cwd: URL(fileURLWithPath: "/tmp", isDirectory: true),
            authorizedRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            resolver: ToolExecutableResolver(allowedExecutables: [
                "LumenPluginWorker": host
            ])
        ).makeCommand(limits: ToolProcessLimits(
            timeout: 10, maximumStandardInputBytes: 1_024,
            maximumStandardOutputBytes: 1_024 * 1_024,
            maximumStandardErrorBytes: 1_024
        ))
    }

    private func pluginFixture(
        permissions: [PluginPermission]
    ) throws -> (store: PluginStore, plugin: InstalledPlugin, package: PluginWorkerPackage) {
        let workspace = try temporaryDirectory(prefix: "worker-workspace")
        let source = try temporaryDirectory(prefix: "worker-source")
        let manifest = try JSONSerialization.data(withJSONObject: [
            "id": "worker", "name": "Worker",
            "extension": [
                "worker": "worker.js",
                "permissions": permissions.map(\.rawValue)
            ]
        ])
        try manifest.write(to: source.appendingPathComponent(PluginStore.manifestFileName))
        try Data("self.onmessage = function () {}".utf8)
            .write(to: source.appendingPathComponent("worker.js"))
        let store = PluginStore(workspaceURL: workspace)
        _ = try store.installLocalPlugin(from: source)
        try store.setGrantedPermissions(permissions, forPluginID: "worker")
        let plugin = try XCTUnwrap(store.listInstalledPlugins().first)
        return (store, plugin, try store.loadWorkerPackage(forPluginID: plugin.id))
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            prefix + "-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum WorkerResponseTemplate: Equatable, Sendable {
    case register(id: String, title: String)
    case replace(String)
    case notify(String)
    case failed(String)
    case completed
}

private actor WorkerRunnerStub: PluginWorkerProcessRunning {
    private var eventsByRequest: [[WorkerResponseTemplate]]
    private(set) var requests: [PluginWorkerRequest] = []
    private(set) var startCount = 0
    private(set) var startedCommands: [ToolCommand] = []
    private(set) var cancelCount = 0
    private var sessions: [WorkerSessionStub] = []

    init(eventsByRequest: [[WorkerResponseTemplate]] = []) {
        self.eventsByRequest = eventsByRequest
    }

    var sessionCancelCount: Int {
        get async {
            var value = 0
            for session in sessions { value += session.currentCancelCount }
            return value
        }
    }

    func start(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any PluginWorkerProcessSessioning {
        startCount += 1
        startedCommands.append(command)
        let session = WorkerSessionStub(
            eventsByRequest: eventsByRequest, onOutput: onOutput,
            record: { [weak self] request in await self?.record(request) }
        )
        sessions.append(session)
        return session
    }

    func cancelAll() async {
        cancelCount += 1
        for session in sessions { session.cancel() }
    }

    private func record(_ request: PluginWorkerRequest) { requests.append(request) }
}

private final class WorkerSessionStub: PluginWorkerProcessSessioning, @unchecked Sendable {
    private let eventsByRequest: [[WorkerResponseTemplate]]
    private let onOutput: ToolProcessOutputHandler
    private let record: @Sendable (PluginWorkerRequest) async -> Void
    private let lock = NSLock()
    private var decoder = PluginWorkerLineDecoder()
    private var requestIndex = 0
    private(set) var cancelCount = 0
    private var terminalResult: Result<ToolProcessResult, any Error>?
    private var exitWaiters: [CheckedContinuation<ToolProcessResult, any Error>] = []

    var currentCancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCount
    }

    init(
        eventsByRequest: [[WorkerResponseTemplate]],
        onOutput: @escaping ToolProcessOutputHandler,
        record: @escaping @Sendable (PluginWorkerRequest) async -> Void
    ) {
        self.eventsByRequest = eventsByRequest
        self.onOutput = onOutput
        self.record = record
    }

    func write(_ data: Data) async throws {
        lock.lock()
        let lines: [Data]
        do {
            lines = try decoder.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        for line in lines {
            let request = try PluginWorkerWireCodec.decodeRequest(line)
            await record(request)
            lock.lock()
            let templates = requestIndex < eventsByRequest.count
                ? eventsByRequest[requestIndex] : []
            requestIndex += 1
            lock.unlock()
            for template in templates {
                let response: PluginWorkerResponse = switch template {
                case let .register(id, title):
                    PluginWorkerResponse(
                        type: .registerCommand, requestID: request.requestID,
                        id: id, title: title
                    )
                case let .replace(text):
                    PluginWorkerResponse(
                        type: .replaceDocument, requestID: request.requestID, text: text
                    )
                case let .notify(text):
                    PluginWorkerResponse(
                        type: .notify, requestID: request.requestID, text: text
                    )
                case let .failed(text):
                    PluginWorkerResponse(
                        type: .failed, requestID: request.requestID, text: text
                    )
                case .completed:
                    PluginWorkerResponse(type: .completed, requestID: request.requestID)
                }
                onOutput(.standardOutput, try PluginWorkerWireCodec.encode(response))
            }
        }
    }

    func closeStandardInput() async throws {
        finish(.success(ToolProcessResult(
            standardOutput: Data(), standardError: Data(), exitCode: 0
        )))
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
        finish(.failure(ToolExecutionError.cancelled))
    }

    func waitForExit() async throws -> ToolProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminalResult {
                lock.unlock()
                continuation.resume(with: terminalResult)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finish(_ result: Result<ToolProcessResult, any Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(with: result) }
    }
}
