import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class TerminalControllerTests: XCTestCase {
    func testRetainedIssueRerendersForRuntimeLocale() async {
        let controller = TerminalController()

        await controller.requestStart()
        guard let issue = controller.issue else {
            return XCTFail("Expected a retained terminal issue")
        }

        XCTAssertEqual(
            EditorLocale.enUS.localizedTerminalIssueTitle(issue.titleContent),
            "No Workspace Open"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssueTitle(issue.titleContent),
            "未打开工作区"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedTerminalIssue(issue.content),
            "Open a workspace folder before starting the terminal."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedTerminalIssue(issue.content),
            "请先打开工作区文件夹，再启动终端。"
        )
    }

    private let root = URL(
        fileURLWithPath: "/tmp/lumen-terminal-controller-tests",
        isDirectory: true
    )
    private let scope = ToolApprovalScope(
        windowID: "terminal-window", sessionID: "terminal-session"
    )

    func testWorkspaceIsRequiredBeforeApprovalOrLaunch() async {
        let runner = TerminalRunnerStub()
        let controller = TerminalController(runner: runner, scope: scope)

        await controller.requestStart()

        XCTAssertEqual(controller.issue?.title, "No Workspace Open")
        XCTAssertNil(controller.pendingApproval)
        XCTAssertEqual(controller.state, .idle)
        let startCount = await runner.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testFirstExactShellIdentityRequiresConfirmation() async throws {
        let runner = TerminalRunnerStub()
        let approvals = ToolApprovalStore()
        let controller = makeController(runner: runner, approvals: approvals)

        await controller.requestStart()
        let request = try XCTUnwrap(controller.pendingApproval)

        XCTAssertEqual(controller.state, .awaitingApproval)
        XCTAssertEqual(request.configuration.kind, .terminal)
        XCTAssertEqual(request.configuration.root, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(request.configuration.cwd, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(request.configuration.env["TERM"], "dumb")
        let startCount = await runner.startCount
        let approvalCount = await approvals.approvalCount(in: scope)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(approvalCount, 0)
    }

    func testShellConfigurationForcesDumbTerminalIntoApprovalIdentity() throws {
        let shell = TerminalShellConfiguration(
            executable: "/bin/zsh", arguments: ["-i"],
            environment: ["TERM": "xterm-256color", "MODE": "test"],
            inheritedEnvironment: ["TERM": "screen", "LANG": "en_US.UTF-8"]
        )
        let configuration = try shell.executionConfiguration(workspaceRoot: root)

        XCTAssertEqual(configuration.env["TERM"], "dumb")
        XCTAssertEqual(configuration.env["MODE"], "test")
        XCTAssertEqual(configuration.env["LANG"], "en_US.UTF-8")
        XCTAssertTrue(
            TerminalApprovalRequest(configuration: configuration)
                .identityDescription.contains(configuration.identity.rawValue)
        )
    }

    func testDefaultShellUsesValidatedEnvironmentExecutableInApprovalIdentity() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "lumen-custom-shell-" + UUID().uuidString, isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("custom-shell")
        let requestedShell = directory.appendingPathComponent("login-shell")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], atPath: executable.path
        )
        try fileManager.createSymbolicLink(
            at: requestedShell, withDestinationURL: executable
        )
        let expectedShell = executable
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let shell = TerminalShellConfiguration(
            inheritedEnvironment: ["SHELL": requestedShell.path, "LANG": "en_US.UTF-8"],
            accountShell: "/bin/zsh",
            fallbackExecutables: ["/bin/sh"],
            fileManager: fileManager
        )
        let configuration = try shell.executionConfiguration(workspaceRoot: root)
        let request = TerminalApprovalRequest(configuration: configuration)

        XCTAssertEqual(shell.executable, expectedShell)
        XCTAssertEqual(configuration.executable, expectedShell)
        XCTAssertEqual(configuration.executableURL.path, expectedShell)
        XCTAssertEqual(configuration.env["SHELL"], expectedShell)
        XCTAssertEqual(configuration.args, ["-i"])
        XCTAssertFalse(configuration.shell)
        XCTAssertFalse(ToolExecutableResolver.system.allowedExecutableURLs.contains(
            configuration.executableURL
        ))
        XCTAssertTrue(request.commandDescription.hasPrefix(expectedShell + " "))
        XCTAssertTrue(request.identityDescription.contains("Command: \(expectedShell) -i"))

        let fallbackConfiguration = try TerminalShellConfiguration(
            inheritedEnvironment: [:],
            accountShell: "/bin/sh",
            fallbackExecutables: ["/bin/sh"]
        ).executionConfiguration(workspaceRoot: root)
        XCTAssertNotEqual(configuration.identity, fallbackConfiguration.identity)
    }

    func testNonExecutableEnvironmentShellFallsBackToValidatedAccountShell() throws {
        let accountShell = "/bin/sh"
        let expectedShell = URL(fileURLWithPath: accountShell)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let shell = TerminalShellConfiguration(
            inheritedEnvironment: [
                "SHELL": "/etc/passwd",
                "LANG": "en_US.UTF-8"
            ],
            accountShell: accountShell,
            fallbackExecutables: ["/bin/zsh"]
        )
        let configuration = try shell.executionConfiguration(workspaceRoot: root)

        XCTAssertEqual(shell.executable, expectedShell)
        XCTAssertEqual(configuration.executableURL.path, expectedShell)
        XCTAssertEqual(configuration.env["SHELL"], expectedShell)
    }

    func testInvalidEnvironmentAndAccountShellsUseSafeSystemFallback() throws {
        let tooLong = "/" + String(
            repeating: "x",
            count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits + 1
        )
        let fallback = "/bin/sh"
        let expectedShell = URL(fileURLWithPath: fallback)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let shell = TerminalShellConfiguration(
            inheritedEnvironment: ["SHELL": tooLong],
            accountShell: "/path/that/does/not/exist",
            fallbackExecutables: ["relative-shell", "/etc/passwd", fallback]
        )
        let configuration = try shell.executionConfiguration(workspaceRoot: root)

        XCTAssertEqual(shell.executable, expectedShell)
        XCTAssertEqual(configuration.executableURL.path, expectedShell)
        XCTAssertEqual(configuration.env["SHELL"], expectedShell)
    }

    func testConfirmStartsAndExactApprovalIsReused() async throws {
        let runner = TerminalRunnerStub()
        let approvals = ToolApprovalStore()
        let controller = makeController(runner: runner, approvals: approvals)

        await controller.requestStart()
        await controller.confirmPendingStart()

        XCTAssertEqual(controller.state, .running(sessionID: "terminal-test-1"))
        let firstStartCount = await runner.startCount
        let approvalCount = await approvals.approvalCount(in: scope)
        let firstCommand = await runner.commands.first
        XCTAssertEqual(firstStartCount, 1)
        XCTAssertEqual(approvalCount, 1)
        let command = try XCTUnwrap(firstCommand)
        XCTAssertEqual(command.executableURL.path, TerminalShellConfiguration().executable)
        XCTAssertEqual(command.arguments, ["-i"])
        XCTAssertEqual(command.environment["TERM"], "dumb")
        XCTAssertEqual(command.environment["SHELL"], command.executableURL.path)
        XCTAssertEqual(command.timeout, 30 * 24 * 60 * 60)
        XCTAssertEqual(command.processGroupPolicy, .isolated)

        await controller.stop()
        await controller.requestStart()

        XCTAssertNil(controller.pendingApproval)
        XCTAssertEqual(controller.state, .running(sessionID: "terminal-test-2"))
        let secondStartCount = await runner.startCount
        XCTAssertEqual(secondStartCount, 2)
        await controller.stop()
    }

    func testDecliningApprovalNeverStartsShell() async {
        let runner = TerminalRunnerStub()
        let controller = makeController(runner: runner)

        await controller.requestStart()
        controller.declinePendingStart()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.pendingApproval)
        let startCount = await runner.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testPTYLineInputEmptyReturnAndInterruptUseSeparateOperations() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        controller.input = "echo hello"
        await controller.submitInput()
        controller.input = ""
        await controller.submitInput()
        await controller.sendInterrupt()

        XCTAssertEqual(controller.input, "")
        let writes = await session.writes
        let interruptCount = await session.interruptCount
        let cancelCountBeforeStop = await session.cancelCount
        XCTAssertEqual(writes, [
            Data("echo hello\n".utf8),
            Data("\n".utf8)
        ])
        XCTAssertEqual(interruptCount, 1)
        XCTAssertEqual(cancelCountBeforeStop, 0)
        await controller.stop()
    }

    func testOversizedInputIsRejectedWithoutWriting() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        await controller.sendLine(String(
            repeating: "x", count: ToolExecutionLimits.maximumStdinWriteBytes
        ))

        XCTAssertEqual(controller.issue?.title, "Invalid Terminal Input")
        let writes = await session.writes
        XCTAssertEqual(writes, [])
        await controller.stop()
    }

    func testResizeIsForwardedOnlyToRunningPTY() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)

        await controller.resize(columns: 80, rows: 24)
        await controller.requestStart()
        let session = try XCTUnwrap(await runner.lastSession)
        await controller.resize(columns: 132, rows: 40)
        await controller.resize(columns: 1, rows: 40)

        let sizes = await session.sizes
        let startSizes = await runner.startSizes
        XCTAssertEqual(sizes, [
            try PseudoTerminalSize(columns: 80, rows: 24),
            try PseudoTerminalSize(columns: 132, rows: 40)
        ])
        XCTAssertEqual(startSizes, [
            try PseudoTerminalSize(columns: 80, rows: 24)
        ])
        await controller.stop()
    }

    func testSplitPTYUTF8ScalarIsDecodedWithoutReplacementCharacter() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let bytes = Array("中🙂".utf8)

        await runner.emit(data: Data(bytes[0 ..< 2]))
        await runner.emit(data: Data(bytes[2 ..< 5]))
        await runner.emit(data: Data(bytes[5...]))
        await drainMainActorTasks()

        XCTAssertEqual(controller.outputText, "中🙂")
        XCTAssertFalse(controller.outputText.contains("�"))
        await controller.stop()
    }

    func testStreamingOutputIsBounded() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let sessionID = try XCTUnwrap(controller.activeSessionID)

        await runner.emit(
            stream: .standardOutput,
            text: String(repeating: "x", count: TerminalController.maximumLogCharacters + 32)
        )
        await runner.emit(stream: .standardError, text: "error\n")
        await drainMainActorTasks()

        XCTAssertTrue(controller.wasOutputTruncated)
        XCTAssertLessThanOrEqual(
            controller.outputText.utf16.count, TerminalController.maximumLogCharacters
        )
        XCTAssertTrue(controller.logEntries.contains {
            $0.sessionID == sessionID && $0.kind == .standardError
        })
        await controller.stop()
    }

    func testLogTrimmingKeepsSurrogatePairsIntact() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()

        await runner.emit(
            stream: .standardOutput,
            text: "🙂" + String(
                repeating: "x", count: TerminalController.maximumLogCharacters
            )
        )
        await drainMainActorTasks()

        XCTAssertFalse(controller.outputText.contains("�"))
        XCTAssertEqual(controller.outputText.utf16.count, TerminalController.maximumLogCharacters)
        await controller.stop()
    }

    func testStopCancelsWaitsForExitAndDiscardsLateOutput() async throws {
        let runner = TerminalRunnerStub(autoFinishOnCancel: false)
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let oldSessionID = try XCTUnwrap(controller.activeSessionID)
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        let stopTask = Task { @MainActor in await controller.stop() }
        await session.waitUntilCancelled()
        await runner.emit(stream: .standardOutput, text: "late secret")
        await session.finish(exitCode: 143)
        await stopTask.value
        await drainMainActorTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionID)
        XCTAssertFalse(controller.outputText.contains("late secret"))
        let cancelCount = await session.cancelCount
        let waitCount = await session.waitCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertGreaterThanOrEqual(waitCount, 1)
        XCTAssertEqual(oldSessionID, "terminal-test-1")
    }

    func testOldSessionEventsCannotMutateReplacementSession() async throws {
        let runner = TerminalRunnerStub(autoFinishOnCancel: false)
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let firstStartedSession = await runner.lastSession
        let callback = await runner.lastOutputCallback
        let first = try XCTUnwrap(firstStartedSession)
        let firstCallback = try XCTUnwrap(callback)

        let stopTask = Task { @MainActor in await controller.stop() }
        await first.waitUntilCancelled()
        await first.finish(exitCode: 0)
        await stopTask.value
        await controller.requestStart()
        XCTAssertEqual(controller.activeSessionID, "terminal-test-2")

        firstCallback(.standardOutput, Data("old session output".utf8))
        await drainMainActorTasks()

        XCTAssertFalse(controller.outputText.contains("old session output"))
        XCTAssertEqual(controller.state, .running(sessionID: "terminal-test-2"))
        let secondStartedSession = await runner.lastSession
        let second = try XCTUnwrap(secondStartedSession)
        let secondStop = Task { @MainActor in await controller.stop() }
        await second.waitUntilCancelled()
        await second.finish(exitCode: 0)
        await secondStop.value
    }

    func testNaturalExitPublishesStatusAndNoLiveSession() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        await session.finish(exitCode: 7)
        await drainMainActorTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.lastExitCode, 7)
        XCTAssertTrue(controller.outputText.hasSuffix("Terminal exited with code 7.\n"))
    }

    func testExitStatusEntryRerendersForRuntimeLocale() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        await session.finish(exitCode: 7)
        await drainMainActorTasks()

        let status = try XCTUnwrap(controller.logEntries.last)
        XCTAssertEqual(status.kind, .status)
        XCTAssertEqual(status.content, .exitStatus(code: 7))
        XCTAssertEqual(status.text(locale: .enUS), "Terminal exited with code 7.\n")
        XCTAssertEqual(status.text(locale: .zhCN), "终端退出，代码为 7。\n")
        XCTAssertEqual(controller.outputText(locale: .enUS), "Terminal exited with code 7.\n")
        XCTAssertEqual(controller.outputText(locale: .zhCN), "终端退出，代码为 7。\n")
    }

    func testProcessOutputThatLooksLikeExitStatusRemainsVerbatimAcrossLocales() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let stdout = "Terminal exited with code 7.\n"
        let stderr = "终端已退出。\n"

        await runner.emit(stream: .standardOutput, text: stdout)
        await runner.emit(stream: .standardError, text: stderr)
        await drainMainActorTasks()

        XCTAssertEqual(controller.logEntries.count, 2)
        XCTAssertEqual(controller.logEntries[0].kind, .standardOutput)
        XCTAssertEqual(controller.logEntries[0].content, .verbatim(stdout))
        XCTAssertEqual(controller.logEntries[0].text(locale: .enUS), stdout)
        XCTAssertEqual(controller.logEntries[0].text(locale: .zhCN), stdout)
        XCTAssertEqual(controller.logEntries[1].kind, .standardError)
        XCTAssertEqual(controller.logEntries[1].content, .verbatim(stderr))
        XCTAssertEqual(controller.logEntries[1].text(locale: .enUS), stderr)
        XCTAssertEqual(controller.logEntries[1].text(locale: .zhCN), stderr)
        await controller.stop()
    }

    func testLocaleRenderingDoesNotMutateLogEntryIdentityOrContent() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        await runner.emit(stream: .standardOutput, text: "output\n")
        await runner.emit(stream: .standardError, text: "error\n")
        await drainMainActorTasks()
        await session.finish(exitCode: 9)
        await drainMainActorTasks()
        let snapshot = controller.logEntries

        XCTAssertEqual(
            controller.outputText(locale: .enUS),
            "output\nerror\nTerminal exited with code 9.\n"
        )
        XCTAssertEqual(
            controller.outputText(locale: .zhCN),
            "output\nerror\n终端退出，代码为 9。\n"
        )
        XCTAssertEqual(controller.logEntries, snapshot)
        XCTAssertEqual(controller.logEntries.map(\.id), snapshot.map(\.id))
        XCTAssertEqual(controller.logEntries.map(\.content), snapshot.map(\.content))
    }

    func testCloseCancelsAndWaitsForProcessTeardown() async throws {
        let runner = TerminalRunnerStub(autoFinishOnCancel: false)
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)

        let closeTask = Task { @MainActor in await controller.close() }
        await session.waitUntilCancelled()
        XCTAssertFalse(closeTask.isCancelled)
        await session.finish(exitCode: 0)
        await closeTask.value

        let cancelCount = await session.cancelCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPanelDismissHidesWithoutStoppingActiveSession() async throws {
        let runner = TerminalRunnerStub()
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let sessionID = try XCTUnwrap(controller.activeSessionID)
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)
        var dismissCount = 0
        let panel = TerminalPanelView(controller: controller) { dismissCount += 1 }

        panel.dismissPanel()
        await runner.emit(stream: .standardOutput, text: "still running\n")
        await drainMainActorTasks()

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(controller.state, .running(sessionID: sessionID))
        XCTAssertEqual(controller.activeSessionID, sessionID)
        XCTAssertEqual(controller.outputText, "still running\n")
        let cancelCountAfterHide = await session.cancelCount
        XCTAssertEqual(cancelCountAfterHide, 0)

        await controller.stop()
        let cancelCountAfterStop = await session.cancelCount
        XCTAssertEqual(cancelCountAfterStop, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testRootChangeStopsSessionAndRequiresNewIdentityApproval() async throws {
        let runner = TerminalRunnerStub(autoFinishOnCancel: false)
        let approvals = ToolApprovalStore()
        let controller = try await approvedController(runner: runner, approvals: approvals)
        await controller.requestStart()
        let startedSession = await runner.lastSession
        let session = try XCTUnwrap(startedSession)
        let secondRoot = URL(fileURLWithPath: "/tmp/lumen-terminal-other", isDirectory: true)

        let updateTask = Task { @MainActor in
            await controller.updateWorkspaceRoot(secondRoot)
        }
        await session.waitUntilCancelled()
        await session.finish(exitCode: 0)
        await updateTask.value
        await controller.requestStart()

        XCTAssertEqual(controller.workspaceRoot, secondRoot)
        XCTAssertNotNil(controller.pendingApproval)
        XCTAssertEqual(controller.state, .awaitingApproval)
    }

    func testNewestWorkspaceRootWinsWhilePriorRootChangeAwaitsTeardown() async throws {
        let runner = TerminalRunnerStub(autoFinishOnCancel: false)
        let controller = try await approvedController(runner: runner)
        await controller.requestStart()
        let session = try XCTUnwrap(await runner.lastSession)
        let secondRoot = URL(
            fileURLWithPath: "/tmp/lumen-terminal-second", isDirectory: true
        )
        let thirdRoot = URL(
            fileURLWithPath: "/tmp/lumen-terminal-third", isDirectory: true
        )

        let older = Task { @MainActor in
            await controller.updateWorkspaceRoot(secondRoot)
        }
        await session.waitUntilCancelled()
        let newer = Task { @MainActor in
            await controller.updateWorkspaceRoot(thirdRoot)
        }
        await Task.yield()
        await session.finish(exitCode: 0)
        await older.value
        await newer.value

        XCTAssertEqual(controller.workspaceRoot, thirdRoot)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPanelAccessibilityContract() {
        XCTAssertEqual(TerminalPanelView.Accessibility.panel, "Terminal")
        XCTAssertEqual(TerminalPanelView.Accessibility.output, "Terminal Output")
        XCTAssertEqual(TerminalPanelView.Accessibility.input, "Terminal Command Input")
        XCTAssertEqual(TerminalPanelView.Accessibility.interrupt, "Interrupt Terminal Command")
    }

    private func makeController(
        runner: any TerminalProcessRunning,
        approvals: ToolApprovalStore = ToolApprovalStore()
    ) -> TerminalController {
        var nextID = 0
        return TerminalController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope,
            makeSessionID: {
                nextID += 1
                return "terminal-test-\(nextID)"
            }
        )
    }

    private func approvedController(
        runner: any TerminalProcessRunning,
        approvals: ToolApprovalStore = ToolApprovalStore()
    ) async throws -> TerminalController {
        let shell = TerminalShellConfiguration()
        let configuration = try shell.executionConfiguration(workspaceRoot: root)
        _ = await approvals.approve(configuration, in: scope)
        return makeController(runner: runner, approvals: approvals)
    }

    private func drainMainActorTasks() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }
}

private actor TerminalRunnerStub: TerminalProcessRunning {
    private let autoFinishOnCancel: Bool
    private(set) var commands: [ToolCommand] = []
    private(set) var startSizes: [PseudoTerminalSize] = []
    private(set) var lastSession: TerminalSessionStub?
    private(set) var lastOutputCallback: ToolProcessOutputHandler?

    var startCount: Int { commands.count }

    init(autoFinishOnCancel: Bool = true) {
        self.autoFinishOnCancel = autoFinishOnCancel
    }

    func start(
        _ command: ToolCommand,
        size: PseudoTerminalSize,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any TerminalProcessSessioning {
        let session = TerminalSessionStub(autoFinishOnCancel: autoFinishOnCancel)
        commands.append(command)
        startSizes.append(size)
        lastSession = session
        lastOutputCallback = onOutput
        return session
    }

    func emit(stream: ToolOutputStream, text: String) {
        lastOutputCallback?(stream, Data(text.utf8))
    }

    func emit(stream: ToolOutputStream = .standardOutput, data: Data) {
        lastOutputCallback?(stream, data)
    }
}

private actor TerminalSessionStub: TerminalProcessSessioning {
    private let autoFinishOnCancel: Bool
    private(set) var writes: [Data] = []
    private(set) var interruptCount = 0
    private(set) var sizes: [PseudoTerminalSize] = []
    private(set) var cancelCount = 0
    private(set) var waitCount = 0

    private var result: Result<ToolProcessResult, any Error>?
    private var waiters: [CheckedContinuation<ToolProcessResult, any Error>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []

    init(autoFinishOnCancel: Bool) {
        self.autoFinishOnCancel = autoFinishOnCancel
    }

    func write(_ data: Data) async throws { writes.append(data) }

    func closeStandardInput() async throws {}

    func interrupt() async throws { interruptCount += 1 }

    func resize(to size: PseudoTerminalSize) async throws { sizes.append(size) }

    nonisolated func cancel() {
        Task { await recordCancellation() }
    }

    func waitForExit() async throws -> ToolProcessResult {
        waitCount += 1
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func finish(exitCode: Int32) {
        finishNow(exitCode: exitCode)
    }

    private func finishNow(exitCode: Int32) {
        let value = ToolProcessResult(
            standardOutput: Data(), standardError: Data(), exitCode: exitCode
        )
        result = .success(value)
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume(returning: value) }
    }

    func waitUntilCancelled() async {
        if cancelCount > 0 { return }
        await withCheckedContinuation { cancelledWaiters.append($0) }
    }

    private func recordCancellation() {
        cancelCount += 1
        let cancellationWaiters = cancelledWaiters
        cancelledWaiters = []
        cancellationWaiters.forEach { $0.resume() }
        if autoFinishOnCancel { finishNow(exitCode: 143) }
    }
}
