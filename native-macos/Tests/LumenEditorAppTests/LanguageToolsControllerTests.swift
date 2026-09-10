import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class LanguageToolsControllerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/lumen-language-tools-controller")

    @MainActor
    func testUnconfiguredDocumentUsesRevisionPinnedBuiltInFormatter() async {
        var current = snapshot(text: "one  \n\n\n\ntwo\t", revision: 4)
        var requests: [LanguageToolApplyRequest] = []
        let controller = makeController(
            snapshot: { current },
            configuration: { _ in nil },
            apply: { request in
                guard request.snapshot.bufferRevision == current.bufferRevision else {
                    return false
                }
                requests.append(request)
                if let replacement = request.replacementContent {
                    current = self.snapshot(text: replacement, revision: 5)
                }
                return true
            }
        )

        let didFormat = await controller.formatDocument()

        XCTAssertTrue(didFormat)
        XCTAssertEqual(requests.first?.replacementContent, "one\n\ntwo")
        XCTAssertEqual(
            controller.runState,
            .completed(source: .builtIn, changed: true, diagnosticCount: 0)
        )
    }

    @MainActor
    func testUnchangedFormattingReportsNoChangeThroughRouter() async throws {
        let snapshot = snapshot(text: "already formatted", revision: 1)
        let controller = makeController(
            snapshot: { snapshot },
            configuration: { _ in nil },
            apply: { request in request.replacementContent == nil }
        )
        let router = CommandRouter()
        _ = try controller.registerCommands(on: router)

        let result = await router.execute(
            "format-document", context: .init(hasDocument: true)
        )

        guard case .noChange(commandID: "format-document") = result else {
            return XCTFail("Unchanged formatting must report no change")
        }
    }

    @MainActor
    func testLanguageToolRequiresApprovalThenAppliesOneResult() async throws {
        let config = LanguageToolConfig(command: "formatter", args: ["-"])
        let execution = try executionConfiguration(args: ["-"])
        let tool = LanguageToolServiceStub(
            execution: execution,
            results: [LanguageToolResult(
                content: "formatted",
                diagnostics: [LanguageToolDiagnostic(
                    line: 2, column: 3, severity: .warning, message: "warning"
                )]
            )]
        )
        var applyRequests: [LanguageToolApplyRequest] = []
        let controller = makeController(
            tool: tool,
            configuration: { _ in config },
            apply: { applyRequests.append($0); return true }
        )

        await controller.formatDocument()
        XCTAssertEqual(controller.runState, .awaitingApproval)
        XCTAssertEqual(controller.pendingApproval?.configuration, execution)
        XCTAssertTrue(controller.pendingApproval?.identityDescription.contains(
            execution.identity.rawValue
        ) == true)
        let runCountBeforeApproval = await tool.runCount
        XCTAssertEqual(runCountBeforeApproval, 0)

        await controller.confirmPendingApproval()

        XCTAssertNil(controller.pendingApproval)
        let runCountAfterApproval = await tool.runCount
        XCTAssertEqual(runCountAfterApproval, 1)
        XCTAssertEqual(applyRequests.first?.replacementContent, "formatted")
        XCTAssertEqual(applyRequests.first?.diagnostics.count, 1)
        XCTAssertEqual(controller.diagnostics.first?.severity, .warning)
        XCTAssertEqual(
            controller.runState,
            .completed(source: .languageTool, changed: true, diagnosticCount: 1)
        )
    }

    @MainActor
    func testStaleRevisionAfterToolCompletionIsNotApplied() async throws {
        let gate = LanguageToolResultGate()
        let tool = LanguageToolServiceStub(
            execution: try executionConfiguration(), resultGate: gate
        )
        var current = snapshot(text: "before", revision: 1)
        var applyCount = 0
        let controller = makeController(
            tool: tool,
            snapshot: { current },
            configuration: { _ in LanguageToolConfig(command: "formatter", args: []) },
            apply: { _ in applyCount += 1; return true }
        )

        await controller.formatDocument()
        let confirmation = Task { @MainActor in
            await controller.confirmPendingApproval()
        }
        await gate.waitUntilStarted()
        current = snapshot(text: "user edit", revision: 2)
        await gate.finish(LanguageToolResult(content: "stale formatter output"))
        await confirmation.value
        await waitUntil { controller.runState == .discardedStale }

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(controller.issue?.title, "Formatting Result Not Applied")
        XCTAssertEqual(
            controller.issue?.titleContent, .formattingResultNotApplied
        )
        XCTAssertEqual(controller.issue?.content, .app(.staleFormattingResult))
    }

    @MainActor
    func testConfigurationChangeWhileAwaitingApprovalDiscardsRequest() async throws {
        let initial = LanguageToolConfig(command: "formatter", args: [])
        var currentConfiguration = initial
        let tool = LanguageToolServiceStub(execution: try executionConfiguration())
        let controller = makeController(
            tool: tool,
            configuration: { _ in currentConfiguration }
        )

        await controller.formatDocument()
        XCTAssertNotNil(controller.pendingApproval)
        currentConfiguration = LanguageToolConfig(
            command: "formatter", args: ["--changed"]
        )

        await controller.confirmPendingApproval()

        XCTAssertEqual(controller.runState, .discardedStale)
        let runCount = await tool.runCount
        XCTAssertEqual(runCount, 0)
    }

    @MainActor
    func testLanguageServerTakesPrecedenceAndFailureDoesNotFallBack() async {
        let tool = LanguageToolServiceStub(
            execution: try! executionConfiguration(),
            results: [LanguageToolResult(content: "tool")]
        )
        var applied: [LanguageToolApplyRequest] = []
        let controller = makeController(
            tool: tool,
            configuration: { _ in LanguageToolConfig(command: "formatter", args: []) },
            lspConfiguration: { _ in
                LanguageServerConfig(command: "sourcekit-lsp", args: [])
            },
            apply: { applied.append($0); return true },
            lsp: { _ in LanguageToolResult(content: "lsp") }
        )
        await controller.formatDocument()
        XCTAssertEqual(applied.first?.replacementContent, "lsp")
        let firstRunCount = await tool.runCount
        XCTAssertEqual(firstRunCount, 0)
        XCTAssertEqual(
            controller.runState,
            .completed(source: .languageServer, changed: true, diagnosticCount: 0)
        )

        let failing = makeController(
            tool: tool,
            configuration: { _ in LanguageToolConfig(command: "formatter", args: []) },
            lspConfiguration: { _ in
                LanguageServerConfig(command: "sourcekit-lsp", args: [])
            },
            apply: { _ in return false },
            lsp: { _ in throw TestError.failed }
        )
        await failing.formatDocument()
        XCTAssertEqual(failing.issue?.title, "Language Server Formatting Failed")
        guard case .verbatim? = failing.issue?.content else {
            return XCTFail("Unknown LSP integration failures must remain verbatim")
        }
        let secondRunCount = await tool.runCount
        XCTAssertEqual(secondRunCount, 0)
    }

    @MainActor
    func testKnownLanguageToolErrorsStayTypedForRuntimeLocalization() async {
        let controller = makeController(
            lspConfiguration: { _ in
                LanguageServerConfig(command: "sourcekit-lsp", args: [])
            },
            lsp: { _ in throw LanguageServerClientError.notRunning }
        )

        await controller.formatDocument()

        XCTAssertEqual(
            controller.issue?.titleContent, .languageServerFormattingFailed
        )
        XCTAssertEqual(controller.issue?.content, .languageServer(.notRunning))
        XCTAssertEqual(
            controller.issue.map {
                EditorLocale.zhCN.localizedLanguageToolIssue($0.content)
            },
            "语言服务器未运行。"
        )
    }

    @MainActor
    func testFormatCommandPreservesTypedLanguageToolFailure() async throws {
        let controller = makeController(
            lspConfiguration: { _ in
                LanguageServerConfig(command: "sourcekit-lsp", args: [])
            },
            lsp: { _ in throw LanguageServerClientError.notRunning }
        )
        let router = CommandRouter()
        _ = try controller.registerCommands(on: router)

        let result = await router.execute(
            "format-document", context: .init(hasDocument: true)
        )

        guard case let .failed(commandID, error) = result,
              let signal = error as? CommandHandlerSignal,
              case let .failedPresentation(.languageTool(issue)) = signal else {
            return XCTFail("Expected the typed language-tool failure")
        }
        XCTAssertEqual(commandID, "format-document")
        XCTAssertEqual(issue.titleContent, .languageServerFormattingFailed)
        XCTAssertEqual(issue.content, .languageServer(.notRunning))
        XCTAssertNil(controller.issue)
        XCTAssertEqual(
            EditorLocale.zhCN.localizedCommandPresentation(.languageTool(issue)),
            "语言服务器未运行。"
        )
    }

    @MainActor
    func testDraftErrorsAreTypedButUnknownCollidingTextRemainsVerbatim() async {
        let draftController = makeController()
        draftController.setDraft("", for: \.language)

        XCTAssertFalse(draftController.saveConfiguration(dismiss: false))
        XCTAssertEqual(draftController.issue?.content, .draft(.invalidLanguage))
        XCTAssertEqual(
            draftController.issue.map {
                EditorLocale.zhCN.localizedLanguageToolIssue($0.content)
            },
            "请选择有效的文档语言。"
        )

        struct CollisionFailure: LocalizedError {
            var errorDescription: String? { "Choose a valid document language." }
        }
        let collisionController = makeController(
            save: { _, _ in throw CollisionFailure() }
        )
        collisionController.setDraft("formatter", for: \.command)

        XCTAssertFalse(collisionController.saveConfiguration(dismiss: false))
        XCTAssertEqual(
            collisionController.issue?.content,
            .verbatim("Choose a valid document language.")
        )
        XCTAssertEqual(
            collisionController.issue.map {
                EditorLocale.zhCN.localizedLanguageToolIssue($0.content)
            },
            "Choose a valid document language."
        )
    }

    @MainActor
    func testLanguageServerApprovalIsReplayedAgainstCapturedSnapshot() async throws {
        let execution = try ToolExecutionConfiguration(
            kind: .languageServer, root: root, command: "xcrun",
            arguments: ["sourcekit-lsp"], resolver: .system
        )
        var approved = false
        var approvalValues: [ToolExecutionConfiguration] = []
        var lspCalls = 0
        var applied: [LanguageToolApplyRequest] = []
        let controller = makeController(
            configuration: { _ in
                XCTFail("Language tool fallback must not run")
                return nil
            },
            lspConfiguration: { _ in
                LanguageServerConfig(command: "sourcekit-lsp", args: [])
            },
            apply: { applied.append($0); return true },
            lsp: { _ in
                lspCalls += 1
                if !approved {
                    throw LanguageServerClientError.approvalRequired(execution)
                }
                return LanguageToolResult(content: "from lsp")
            },
            approveLSP: { configuration in
                approvalValues.append(configuration)
                approved = true
            }
        )

        await controller.formatDocument()
        XCTAssertEqual(controller.runState, .awaitingApproval)
        XCTAssertEqual(controller.pendingApproval?.configuration, execution)
        XCTAssertEqual(lspCalls, 1)

        await controller.confirmPendingApproval()

        XCTAssertEqual(approvalValues, [execution])
        XCTAssertEqual(lspCalls, 2)
        XCTAssertEqual(applied.first?.replacementContent, "from lsp")
        XCTAssertEqual(
            controller.runState,
            .completed(source: .languageServer, changed: true, diagnosticCount: 0)
        )
    }

    @MainActor
    func testDraftValidatesDirectAndExplicitShellContracts() async throws {
        var draft = LanguageToolDraft(language: "Swift")
        draft.command = "/usr/bin/formatter"
        draft.argumentsJSON = #"["--stdin", "literal;argument"]"#
        draft.environmentJSON = #"{"MODE":"format"}"#
        draft.workingDirectory = "Sources"

        let direct = try XCTUnwrap(draft.validatedConfiguration())
        XCTAssertEqual(direct.args, ["--stdin", "literal;argument"])
        XCTAssertEqual(direct.shell, false)
        XCTAssertEqual(direct.workingDirectory, "Sources")
        XCTAssertEqual(direct.env, ["MODE": "format"])

        draft.shell = true
        XCTAssertThrowsError(try draft.validatedConfiguration()) { error in
            XCTAssertEqual(error as? LanguageToolDraftError, .shellArgumentsNotAllowed)
        }
        draft.argumentsJSON = "[]"
        XCTAssertEqual(try draft.validatedConfiguration()?.shell, true)
    }

    @MainActor
    func testConfigurationSaveAndRemoveUseTypedAPI() async {
        var stored: [String: LanguageToolConfig] = [:]
        let controller = makeController(
            configuration: { stored[$0] },
            save: { language, configuration in stored[language] = configuration }
        )

        controller.presentConfiguration()
        controller.setDraft("xcrun", for: \.command)
        controller.setDraft(#"["swift-format"]"#, for: \.argumentsJSON)
        XCTAssertTrue(controller.saveConfiguration(dismiss: false))
        XCTAssertEqual(stored["Swift"]?.args, ["swift-format"])

        controller.setDraft("", for: \.command)
        XCTAssertTrue(controller.saveConfiguration())
        XCTAssertNil(stored["Swift"])
        XCTAssertFalse(controller.isConfigurationPresented)
    }

    @MainActor
    func testCommandRegistrationRollsBackOnConflictAndViewContractIsStable() async throws {
        let router = CommandRouter()
        _ = try router.register("language-tools") { _ in }
        let controller = makeController()

        XCTAssertThrowsError(try controller.registerCommands(on: router))
        XCTAssertEqual(
            router.status(
                for: "format-document", context: .init(hasDocument: true)
            ),
            .unsupported
        )
    }

    @MainActor
    private func makeController(
        tool: (any LanguageToolRunning)? = nil,
        snapshot: @escaping @MainActor () -> LanguageToolDocumentSnapshot? = {
            LanguageToolDocumentSnapshot(
                documentID: "document", paneIndex: 0, viewID: "view",
                bufferRevision: 1, text: "original", language: "Swift",
                fileURL: URL(fileURLWithPath: "/tmp/lumen-language-tools-controller/main.swift"),
                workspaceRoot: URL(fileURLWithPath: "/tmp/lumen-language-tools-controller")
            )
        },
        configuration: @escaping @MainActor (String) -> LanguageToolConfig? = { _ in nil },
        lspConfiguration: @escaping LanguageToolsController.LanguageServerConfigurationProvider
            = { _ in nil },
        save: @escaping LanguageToolsController.SaveConfiguration = { _, _ in },
        apply: @escaping LanguageToolsController.ApplyResult = { _ in true },
        lsp: @escaping LanguageToolsController.FormatWithLanguageServer = { _ in nil },
        approveLSP: @escaping LanguageToolsController.ApproveLanguageServer = { _ in }
    ) -> LanguageToolsController {
        let resolvedTool: any LanguageToolRunning
        if let tool {
            resolvedTool = tool
        } else {
            resolvedTool = LanguageToolServiceStub(
                execution: try! executionConfiguration()
            )
        }
        return LanguageToolsController(
            tool: resolvedTool, snapshot: snapshot, workspace: { self.root },
            language: { "Swift" }, configuration: configuration,
            languageServerConfiguration: lspConfiguration,
            saveConfiguration: save, applyResult: apply,
            formatWithLanguageServer: lsp,
            approveLanguageServer: approveLSP
        )
    }

    @MainActor
    private func snapshot(text: String, revision: UInt64) -> LanguageToolDocumentSnapshot {
        LanguageToolDocumentSnapshot(
            documentID: "document", paneIndex: 0, viewID: "view",
            bufferRevision: revision, text: text, language: "Swift",
            fileURL: root.appendingPathComponent("main.swift"), workspaceRoot: root
        )
    }

    @MainActor
    private func executionConfiguration(args: [String] = []) throws
        -> ToolExecutionConfiguration {
        let resolver = try ToolExecutableResolver(allowedExecutables: [
            "formatter": URL(fileURLWithPath: "/usr/bin/formatter")
        ])
        return try ToolExecutionConfiguration(
            kind: .languageTool, root: root, command: "formatter",
            arguments: args, resolver: resolver
        )
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
    }
}

private enum TestError: Error { case failed }

private actor LanguageToolServiceStub: LanguageToolRunning {
    private let execution: ToolExecutionConfiguration
    private var results: [LanguageToolResult]
    private let resultGate: LanguageToolResultGate?
    private(set) var requests: [LanguageToolRequest] = []
    private(set) var approved: [ToolExecutionConfiguration] = []
    private(set) var authorizedExecutables: [URL] = []
    private(set) var cancelCount = 0

    init(
        execution: ToolExecutionConfiguration,
        results: [LanguageToolResult] = [],
        resultGate: LanguageToolResultGate? = nil
    ) {
        self.execution = execution
        self.results = results
        self.resultGate = resultGate
    }

    var runCount: Int { requests.count }

    func approvalConfiguration(
        root: URL, configuration: LanguageToolConfig
    ) async throws -> ToolExecutionConfiguration { execution }

    func approve(_ configuration: ToolExecutionConfiguration) async {
        approved.append(configuration)
    }

    func run(_ request: LanguageToolRequest) async throws -> LanguageToolResult {
        guard approved.contains(execution) else {
            throw LanguageToolError.approvalRequired(execution)
        }
        requests.append(request)
        if let resultGate { return await resultGate.run() }
        return results.isEmpty ? LanguageToolResult() : results.removeFirst()
    }

    func authorizeExecutable(_ url: URL) async throws -> URL {
        authorizedExecutables.append(url)
        return url
    }

    func cancelAll() async { cancelCount += 1 }
}

private actor LanguageToolResultGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<LanguageToolResult, Never>?
    private var pendingResult: LanguageToolResult?

    func run() async -> LanguageToolResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
        if let pendingResult { return pendingResult }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ result: LanguageToolResult) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            pendingResult = result
        }
    }
}
