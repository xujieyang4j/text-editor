import Foundation
import XCTest
@testable import LumenEditorCore

final class LanguageServerClientTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/lumen-lsp-client-tests", isDirectory: true)
    private let config = LanguageServerConfig(command: "test-lsp", args: ["--stdio"])

    func testInstanceKeyIncludesNormalizedRootAndCompleteConfiguration() {
        let first = LanguageServerInstanceKey(root: root, config: config)
        let same = LanguageServerInstanceKey(
            root: root.appendingPathComponent("..").appendingPathComponent(root.lastPathComponent),
            config: config
        )
        let otherArguments = LanguageServerInstanceKey(
            root: root, config: LanguageServerConfig(command: "test-lsp", args: ["--tcp"])
        )
        let otherRoot = LanguageServerInstanceKey(
            root: URL(fileURLWithPath: "/tmp/another-lsp-root", isDirectory: true),
            config: config
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherArguments)
        XCTAssertNotEqual(first, otherRoot)
    }

    func testInitializeHandshakeUsesFramingAndAdvertisesRunningStatus() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events)

        try await client.start()

        let session = try await runner.session(at: 0)
        let messages = await session.receivedMessages()
        XCTAssertEqual(
            Array(messages.compactMap(\.methodName).prefix(2)),
            ["initialize", "initialized"]
        )
        let initialize = try XCTUnwrap(messages.first)
        XCTAssertEqual(initialize["jsonrpc"], .string("2.0"))
        XCTAssertEqual(
            initialize["params"]?.objectValue?["rootUri"],
            .string(root.standardizedFileURL.resolvingSymlinksInPath().absoluteString)
        )
        let status = await client.currentStatus()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.capabilities, ["completionProvider", "hoverProvider"])
        XCTAssertTrue(events.statuses().contains { $0.state == .starting })
        XCTAssertTrue(events.statuses().contains { $0.state == .running })
    }

    func testInitializeTimeoutCancelsTheProcessAndFailsPendingRequest() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: false)
        let client = makeClient(runner: runner, initializeTimeout: 0.02)

        do {
            try await client.start()
            XCTFail("Expected initialization timeout")
        } catch let error as LanguageServerClientError {
            XCTAssertEqual(error, .requestTimedOut("initialize"))
        }

        let session = try await runner.session(at: 0)
        let wasCancelled = await session.wasCancelled()
        let status = await client.currentStatus()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(status.state, .failed)
    }

    func testPendingResponsesAreMatchedByIDWhenTheyArriveOutOfOrder() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true, interactiveAutoRespond: false)
        let client = makeClient(runner: runner)
        try await client.start()
        let session = try await runner.session(at: 0)
        let file = root.appendingPathComponent("main.swift")

        let completionTask = Task {
            try await client.perform(self.request(
                file: file, content: "let alpha = 1", method: .completion
            ))
        }
        let hoverTask = Task {
            try await client.perform(self.request(
                file: file, content: "let alpha = 1", method: .hover
            ))
        }
        try await session.waitForMethods(["textDocument/completion", "textDocument/hover"])
        let requests = await session.receivedMessages()
        let completionID = try XCTUnwrap(requests.firstRequestID(method: "textDocument/completion"))
        let hoverID = try XCTUnwrap(requests.firstRequestID(method: "textDocument/hover"))

        await session.emitResponse(
            id: hoverID, result: .object([
                "contents": .object(["kind": .string("plaintext"), "value": .string("hover text")])
            ])
        )
        await session.emitResponse(
            id: completionID, result: .array([.object(["label": .string("alpha")])])
        )

        let hover = try await hoverTask.value
        let completion = try await completionTask.value
        XCTAssertEqual(hover.hover?.text, "hover text")
        XCTAssertEqual(completion.completions?.map(\.label), ["alpha"])
    }

    func testLargeDidOpenFrameIsChunkedWithoutBreakingFraming() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let client = makeClient(runner: runner)
        try await client.start()
        let session = try await runner.session(at: 0)
        let content = String(repeating: "é", count: 80_000)

        try await client.synchronizeDocument(
            fileURL: root.appendingPathComponent("large.swift"),
            languageID: "swift", text: content, version: 1
        )

        let chunks = await session.writeChunks()
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ToolExecutionLimits.maximumStdinWriteBytes })
        let messages = await session.receivedMessages()
        let didOpen = try XCTUnwrap(
            messages.first { $0.methodName == "textDocument/didOpen" }
        )
        XCTAssertEqual(
            didOpen["params"]?.objectValue?["textDocument"]?.objectValue?["text"],
            .string(content)
        )
    }

    func testDocumentVersionsOpenChangeCloseAndRejectRegression() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let client = makeClient(runner: runner)
        try await client.start()
        let file = root.appendingPathComponent("version.swift")

        try await client.synchronizeDocument(
            fileURL: file, languageID: "swift", text: "one", version: 4
        )
        try await client.synchronizeDocument(
            fileURL: file, languageID: "swift", text: "two", version: 5
        )
        do {
            try await client.synchronizeDocument(
                fileURL: file, languageID: "swift", text: "old", version: 3
            )
            XCTFail("Expected stale version rejection")
        } catch let error as LanguageServerClientError {
            XCTAssertEqual(error, .staleDocumentVersion(current: 5, received: 3))
        }
        try await client.closeDocument(fileURL: file)

        let session = try await runner.session(at: 0)
        let messages = await session.receivedMessages()
        XCTAssertEqual(
            messages.compactMap(\.methodName).filter { $0.hasPrefix("textDocument/did") },
            ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"]
        )
        let change = try XCTUnwrap(messages.first { $0.methodName == "textDocument/didChange" })
        XCTAssertEqual(
            change["params"]?.objectValue?["textDocument"]?.objectValue?["version"],
            .integer(5)
        )
    }

    func testDiagnosticsAreVersionCheckedRootConfinedAndLimitedToOneThousand() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events)
        try await client.start()
        let session = try await runner.session(at: 0)
        let file = root.appendingPathComponent("diagnostics.swift")
        try await client.synchronizeDocument(
            fileURL: file, languageID: "swift", text: "x", version: 2
        )
        let items = (0..<1_005).map { index in
            LSPJSONValue.object([
                "range": .object([
                    "start": .object(["line": .integer(Int64(index)), "character": .integer(0)]),
                    "end": .object(["line": .integer(Int64(index)), "character": .integer(1)])
                ]),
                "severity": .integer(2),
                "message": .string("warning \(index)")
            ])
        }
        await session.emitNotification(
            method: "textDocument/publishDiagnostics",
            params: .object([
                "uri": .string(file.absoluteString), "version": .integer(1),
                "diagnostics": .array(items)
            ])
        )
        await drainTasks()
        XCTAssertTrue(events.diagnostics().isEmpty)

        await session.emitNotification(
            method: "textDocument/publishDiagnostics",
            params: .object([
                "uri": .string(file.absoluteString), "version": .integer(2),
                "diagnostics": .array(items)
            ])
        )
        try await eventually { events.diagnostics().count == 1 }
        let update = try XCTUnwrap(events.diagnostics().first)
        XCTAssertEqual(update.event.filePath, file.path)
        XCTAssertEqual(update.event.diagnostics.count, LSPProtocolLimits.maximumDiagnostics)
        XCTAssertEqual(update.event.diagnostics.first?.severity, .warning)
    }

    func testFutureDiagnosticVersionIsRejectedUntilDocumentCatchesUp() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events)
        try await client.start()
        let session = try await runner.session(at: 0)
        let file = root.appendingPathComponent("future-diagnostic.swift")
        try await client.synchronizeDocument(
            fileURL: file, languageID: "swift", text: "x", version: 1
        )

        await session.emitNotification(
            method: "textDocument/publishDiagnostics",
            params: .object([
                "uri": .string(file.absoluteString),
                "version": .integer(Int64.max),
                "diagnostics": .array([.object([
                    "range": Self.range(line: 0, character: 0),
                    "message": .string("future")
                ])])
            ])
        )
        await drainTasks()

        XCTAssertTrue(events.diagnostics().isEmpty)
    }

    func testCompletionHoverLocationsAndRenameProduceBoundedDTOsOnly() async throws {
        let responses: [String: LSPJSONValue] = [
            "textDocument/completion": .array((0..<250).map { index in
                .object(["label": .string("item-\(index)")])
            }),
            "textDocument/hover": .object([
                "contents": .string("symbol documentation")
            ]),
            "textDocument/definition": .object([
                "uri": .string(root.appendingPathComponent("definition.swift").absoluteString),
                "range": Self.range(line: 3, character: 4)
            ]),
            "textDocument/references": .array([.object([
                "targetUri": .string(root.appendingPathComponent("reference.swift").absoluteString),
                "targetRange": Self.range(line: 1, character: 2),
                "targetSelectionRange": Self.range(line: 5, character: 6)
            ])]),
            "textDocument/rename": .object([
                "changes": .object([
                    root.appendingPathComponent("rename.swift").absoluteString: .array([.object([
                        "range": Self.range(line: 7, character: 8),
                        "newText": .string("renamed")
                    ])]),
                    URL(fileURLWithPath: "/tmp/outside.swift").absoluteString: .array([.object([
                        "range": Self.range(line: 0, character: 0),
                        "newText": .string("excluded")
                    ])])
                ])
            ])
        ]
        let runner = FakeLanguageServerRunner(autoRespond: true, responses: responses)
        let client = makeClient(runner: runner)
        try await client.start()
        let file = root.appendingPathComponent("main.swift")

        let completion = try await client.perform(request(
            file: file, content: "let value = 1", method: .completion
        ))
        let hover = try await client.perform(request(
            file: file, content: "let value = 1", method: .hover
        ))
        let definition = try await client.perform(request(
            file: file, content: "let value = 1", method: .definition
        ))
        let references = try await client.perform(request(
            file: file, content: "let value = 1", method: .references
        ))
        let preview = try await client.renamePreview(request(
            file: file, content: "let value = 1", method: .rename, newName: " renamed "
        ))

        XCTAssertEqual(completion.completions?.count, LSPProtocolLimits.maximumCompletionItems)
        XCTAssertEqual(hover.hover?.text, "symbol documentation")
        XCTAssertEqual(definition.locations?.first?.line, 3)
        XCTAssertEqual(references.locations?.first?.line, 5)
        XCTAssertEqual(preview.newName, "renamed")
        XCTAssertEqual(preview.edits.count, 1, "Edits outside the authorised root are excluded")
        XCTAssertEqual(preview.edits.first?.newText, "renamed")
    }

    func testFormattingSynchronizesAndSendsTypedDefaultParams() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
            "textDocument/formatting": .array([.object([
                "range": .object([
                    "start": .object(["line": .integer(-2), "character": .integer(-3)]),
                    "end": .object(["line": .integer(5), "character": .integer(7)])
                ]),
                "newText": .string("formatted\n")
            ])])
        ])
        let client = makeClient(runner: runner)
        try await client.start()
        let file = root.appendingPathComponent("format.swift")

        let result = try await client.format(formatRequest(
            file: file, content: "let value=1"
        ))

        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.edits, [LanguageServerTextEdit(
            startLine: 0, startCharacter: 0, endLine: 5, endCharacter: 7,
            newText: "formatted\n"
        )])
        let session = try await runner.session(at: 0)
        let messages = await session.receivedMessages()
        let methods = messages.compactMap(\.methodName)
        let didOpenIndex = try XCTUnwrap(methods.firstIndex(of: "textDocument/didOpen"))
        let formattingIndex = try XCTUnwrap(
            methods.firstIndex(of: "textDocument/formatting")
        )
        XCTAssertLessThan(didOpenIndex, formattingIndex)
        let formatting = try XCTUnwrap(messages.first {
            $0.methodName == "textDocument/formatting"
        })
        XCTAssertEqual(
            formatting["params"]?.objectValue?["textDocument"]?.objectValue?["uri"],
            .string(file.absoluteString)
        )
        XCTAssertEqual(
            formatting["params"]?.objectValue?["options"]?.objectValue?["tabSize"],
            .integer(4)
        )
        XCTAssertEqual(
            formatting["params"]?.objectValue?["options"]?.objectValue?["insertSpaces"],
            .bool(true)
        )
    }

    func testFormattingNullReturnsEmptyEdits() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
            "textDocument/formatting": .null
        ])
        let client = makeClient(runner: runner)
        try await client.start()

        let result = try await client.format(formatRequest(
            file: root.appendingPathComponent("unchanged.swift"),
            content: "let value = 1"
        ))

        XCTAssertEqual(result, LanguageServerResult(edits: [], diagnostics: []))
    }

    func testFormattingRejectsMalformedAndOverBudgetEdits() async throws {
        let malformed: [LSPJSONValue] = [
            .object(["newText": .string("missing range")]),
            .array([.object([
                "range": Self.range(line: 0, character: 0),
                "newText": .integer(7)
            ])])
        ]
        for (index, response) in malformed.enumerated() {
            let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
                "textDocument/formatting": response
            ])
            let client = makeClient(runner: runner)
            try await client.start()
            do {
                _ = try await client.format(formatRequest(
                    file: root.appendingPathComponent("malformed-\(index).swift"),
                    content: "x"
                ))
                XCTFail("Expected malformed formatting response to fail")
            } catch let error as LanguageServerClientError {
                XCTAssertEqual(error, .invalidResponse("textDocument/formatting"))
            }
        }

        let tooMany = (0...LSPProtocolLimits.maximumFormattingEdits).map { index in
            LSPJSONValue.object([
                "range": Self.range(line: index, character: 0),
                "newText": .string("x")
            ])
        }
        let oversizedText = String(
            repeating: "x",
            count: LSPProtocolLimits.maximumFormattingEditTextUTF16CodeUnits + 1
        )
        let overBudgetResponses: [LSPJSONValue] = [
            .array(tooMany),
            .array([.object([
                "range": Self.range(line: 0, character: 0),
                "newText": .string(oversizedText)
            ])])
        ]
        for (index, response) in overBudgetResponses.enumerated() {
            let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
                "textDocument/formatting": response
            ])
            let client = makeClient(runner: runner)
            try await client.start()
            do {
                _ = try await client.format(formatRequest(
                    file: root.appendingPathComponent("over-budget-\(index).swift"),
                    content: "x"
                ))
                XCTFail("Expected over-budget formatting response to fail")
            } catch let error as LanguageServerClientError {
                XCTAssertEqual(error, .invalidResponse("textDocument/formatting"))
            }
        }
    }

    func testFormattingRejectsAggregateNewTextOverBudget() async throws {
        let halfBudget = String(
            repeating: "x",
            count: LSPProtocolLimits.maximumFormattingTotalTextUTF16CodeUnits / 2
        )
        let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
            "textDocument/formatting": .array([
                .object([
                    "range": Self.range(line: 0, character: 0),
                    "newText": .string(halfBudget)
                ]),
                .object([
                    "range": Self.range(line: 1, character: 0),
                    "newText": .string(halfBudget + "x")
                ])
            ])
        ])
        let client = makeClient(runner: runner)
        try await client.start()

        do {
            _ = try await client.format(formatRequest(
                file: root.appendingPathComponent("aggregate-over-budget.swift"),
                content: "x"
            ))
            XCTFail("Expected aggregate formatting text budget rejection")
        } catch let error as LanguageServerClientError {
            XCTAssertEqual(error, .invalidResponse("textDocument/formatting"))
        }
    }

    func testManagerFormattingRequiresExactApprovalThenReusesManagedClient() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true, responses: [
            "textDocument/formatting": .null
        ])
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(windowID: "format-window", sessionID: "format-session")
        let manager = LanguageServerManager(
            runner: runner, approvals: approvals, approvalScope: scope, sessionLifetime: 60
        ) { root, config in
            try ToolExecutionConfiguration(
                kind: .languageServer, executable: config.command, args: config.args,
                cwd: root, authorizedRoot: root,
                resolver: try ToolExecutableResolver(allowedExecutables: [
                    config.command: URL(fileURLWithPath: "/usr/bin/true")
                ])
            )
        }
        let request = formatRequest(
            file: root.appendingPathComponent("managed.swift"), content: "x"
        )
        let differentConfig = LanguageServerConfig(command: config.command, args: ["--other"])
        let differentApproval = try await manager.approvalConfiguration(
            root: root, config: differentConfig
        )
        await manager.approve(differentApproval)

        do {
            _ = try await manager.format(request)
            XCTFail("Expected exact approval before formatting")
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            XCTAssertEqual(configuration.executable, config.command)
            XCTAssertEqual(configuration.args, config.args)
            await manager.approve(configuration)
        }
        let beforeApprovalCount = await runner.sessionCount()
        XCTAssertEqual(beforeApprovalCount, 0)

        let firstResult = try await manager.format(request)
        XCTAssertEqual(firstResult, LanguageServerResult(edits: [], diagnostics: []))
        let afterApprovalCount = await runner.sessionCount()
        XCTAssertEqual(afterApprovalCount, 1)
        let secondResult = try await manager.format(request)
        XCTAssertEqual(secondResult, LanguageServerResult(edits: [], diagnostics: []))
        let afterReuseCount = await runner.sessionCount()
        XCTAssertEqual(afterReuseCount, 1)
    }

    func testRestartReopensDocumentsAndDropsLateEventsFromOldGeneration() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events, gracefulStopTimeout: 0.02)
        try await client.start()
        let first = try await runner.session(at: 0)
        let file = root.appendingPathComponent("restored.swift")
        try await client.synchronizeDocument(
            fileURL: file, languageID: "swift", text: "saved snapshot", version: 7
        )

        try await client.restart()
        let second = try await runner.session(at: 1)
        await first.emit(stream: .standardError, data: Data("late old generation".utf8))
        await second.emit(stream: .standardError, data: Data("current generation".utf8))
        try await eventually { events.logs().contains { $0.text.contains("current generation") } }

        XCTAssertFalse(events.logs().contains { $0.text.contains("late old generation") })
        let reopened = (await second.receivedMessages()).first {
            $0.methodName == "textDocument/didOpen"
        }
        XCTAssertEqual(
            reopened?["params"]?.objectValue?["textDocument"]?.objectValue?["version"],
            .integer(7)
        )
    }

    func testCancelSettlesOutstandingRequestAndDropsLateOutput() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true, interactiveAutoRespond: false)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events)
        try await client.start()
        let session = try await runner.session(at: 0)
        let task = Task {
            try await client.perform(self.request(
                file: self.root.appendingPathComponent("cancel.swift"),
                content: "x", method: .hover
            ))
        }
        try await session.waitForMethods(["textDocument/hover"])

        await client.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected pending request to fail")
        } catch {
            XCTAssertTrue(error is LanguageServerClientError)
        }
        await session.emit(stream: .standardError, data: Data("late secret".utf8))
        await drainTasks()
        XCTAssertFalse(events.logs().contains { $0.text.contains("late secret") })
        let status = await client.currentStatus()
        XCTAssertEqual(status.state, .stopped)
    }

    func testLogsAreControlCharacterSanitizedAndBounded() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let events = LanguageServerEventRecorder()
        let client = makeClient(runner: runner, events: events)
        try await client.start()
        let session = try await runner.session(at: 0)
        let raw = "visible\u{0}\u{7}" + String(repeating: "x", count: 70_000)

        await session.emit(stream: .standardError, data: Data(raw.utf8))
        try await eventually { !events.logs().isEmpty }

        let log = try XCTUnwrap(events.logs().last)
        XCTAssertFalse(log.text.contains("\u{0}"))
        XCTAssertFalse(log.text.contains("\u{7}"))
        XCTAssertLessThanOrEqual(log.text.utf16.count, LSPProtocolLimits.maximumLogCharacters)
        XCTAssertTrue(log.text.hasSuffix(LSPLogSanitizer.truncationSuffix))
    }

    func testManagerCreatesOneClientPerRootAndConfigAndReusesExactKey() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(windowID: "lsp-window", sessionID: "lsp-session")
        let manager = LanguageServerManager(
            runner: runner, approvals: approvals, approvalScope: scope, sessionLifetime: 60
        ) { root, config in
            try ToolExecutionConfiguration(
                kind: .languageServer, executable: config.command, args: config.args,
                cwd: root, authorizedRoot: root,
                resolver: try ToolExecutableResolver(allowedExecutables: [
                    config.command: URL(fileURLWithPath: "/usr/bin/true")
                ])
            )
        }
        let firstApproval = try await manager.approvalConfiguration(root: root, config: config)
        await manager.approve(firstApproval)

        let first = try await manager.start(root: root, config: config)
        let duplicate = try await manager.start(root: root, config: config)
        let otherConfig = LanguageServerConfig(command: "other-lsp", args: [])
        let otherApproval = try await manager.approvalConfiguration(root: root, config: otherConfig)
        await manager.approve(otherApproval)
        let second = try await manager.start(root: root, config: otherConfig)

        XCTAssertEqual(first, duplicate)
        XCTAssertNotEqual(first, second)
        let sessionCount = await runner.sessionCount()
        XCTAssertEqual(sessionCount, 2)
    }

    func testManagerRequiresExactSessionApprovalBeforeStarting() async throws {
        let runner = FakeLanguageServerRunner(autoRespond: true)
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(windowID: "approval-window", sessionID: "approval-session")
        let manager = LanguageServerManager(
            runner: runner, approvals: approvals, approvalScope: scope, sessionLifetime: 60
        ) { root, config in
            try ToolExecutionConfiguration(
                kind: .languageServer, executable: config.command, args: config.args,
                cwd: root, authorizedRoot: root,
                resolver: try ToolExecutableResolver(allowedExecutables: [
                    config.command: URL(fileURLWithPath: "/usr/bin/true")
                ])
            )
        }

        var approval: ToolExecutionConfiguration?
        do {
            _ = try await manager.start(root: root, config: config)
            XCTFail("Expected session approval")
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            XCTAssertEqual(configuration.kind, .languageServer)
            XCTAssertEqual(
                configuration.root.path,
                root.standardizedFileURL.resolvingSymlinksInPath().path
            )
            XCTAssertEqual(configuration.executable, config.command)
            XCTAssertEqual(configuration.args, config.args)
            approval = configuration
        } catch {
            throw error
        }
        let beforeApprovalCount = await runner.sessionCount()
        XCTAssertEqual(beforeApprovalCount, 0)
        await manager.approve(try XCTUnwrap(approval))
        _ = try await manager.start(root: root, config: config)
        let afterApprovalCount = await runner.sessionCount()
        XCTAssertEqual(afterApprovalCount, 1)
    }

    func testProductionManagerRequiresSelectionThenExactApprovalForAbsoluteExecutable() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-language-server-\(UUID().uuidString)", isDirectory: false
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        defer { try? FileManager.default.removeItem(at: executable) }

        let runner = FakeLanguageServerRunner(autoRespond: true)
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(
            windowID: "absolute-window", sessionID: "absolute-session"
        )
        let manager = LanguageServerManager(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:], sessionLifetime: 60
        )
        let absoluteConfig = LanguageServerConfig(
            command: executable.path, args: ["--stdio"]
        )

        do {
            _ = try await manager.start(root: root, config: absoluteConfig)
            XCTFail("Project configuration must not authorize its executable")
        } catch {
            XCTAssertEqual(
                error as? ToolExecutionError,
                .executableNotAllowed(executable.path)
            )
        }
        let sessionsBeforeSelection = await runner.sessionCount()
        XCTAssertEqual(sessionsBeforeSelection, 0)

        let selected = try await manager.authorizeExecutable(executable)
        XCTAssertEqual(selected, executable.standardizedFileURL.resolvingSymlinksInPath())
        let approval = try await manager.approvalConfiguration(
            root: root, config: absoluteConfig
        )
        XCTAssertEqual(approval.executableURL, selected)
        do {
            _ = try await manager.start(root: root, config: absoluteConfig)
            XCTFail("Selection must not bypass exact execution approval")
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            XCTAssertEqual(configuration, approval)
        }
        let sessionsBeforeApproval = await runner.sessionCount()
        XCTAssertEqual(sessionsBeforeApproval, 0)

        await manager.approve(approval)
        _ = try await manager.start(root: root, config: absoluteConfig)
        let commands = await runner.startedCommandList()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.executableURL, selected)
    }

    func testProductionManagerSelectionIsCanonicalAndInstanceLocal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-language-server-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        let executable = directory.appendingPathComponent("clangd", isDirectory: false)
        let alias = directory.appendingPathComponent("clangd-link", isDirectory: false)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = LanguageServerManager(
            runner: FakeLanguageServerRunner(autoRespond: true),
            inheritedEnvironment: [:], sessionLifetime: 60
        )
        let second = LanguageServerManager(
            runner: FakeLanguageServerRunner(autoRespond: true),
            inheritedEnvironment: [:], sessionLifetime: 60
        )
        let authorized = try await first.authorizeExecutable(alias)
        XCTAssertEqual(authorized, executable)
        let config = LanguageServerConfig(command: alias.path, args: [])
        let configuration = try await first.approvalConfiguration(
            root: root, config: config
        )
        XCTAssertEqual(configuration.executableURL, executable)
        do {
            _ = try await second.approvalConfiguration(root: root, config: config)
            XCTFail("Executable selection must stay in its manager session")
        } catch {
            XCTAssertEqual(error as? ToolExecutionError, .executableNotAllowed(alias.path))
        }
        await first.revokeAllExecutables()
        do {
            _ = try await first.approvalConfiguration(root: root, config: config)
            XCTFail("Revoking the session capability must restore resolver denial")
        } catch {
            XCTAssertEqual(error as? ToolExecutionError, .executableNotAllowed(alias.path))
        }
    }

    private func makeClient(
        runner: FakeLanguageServerRunner,
        events: LanguageServerEventRecorder = LanguageServerEventRecorder(),
        initializeTimeout: TimeInterval = 0.5,
        requestTimeout: TimeInterval = 0.5,
        gracefulStopTimeout: TimeInterval = 0.05
    ) -> LanguageServerClient {
        LanguageServerClient(
            root: root, config: config, command: Self.command(root: root, config: config),
            runner: runner, initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout, gracefulStopTimeout: gracefulStopTimeout,
            eventHandler: { events.record($0) }
        )
    }

    private func request(
        file: URL, content: String, method: LanguageServerMethod, newName: String? = nil
    ) -> LanguageServerInteractiveRequest {
        LanguageServerInteractiveRequest(
            root: root.path, config: config, content: content, filePath: file.path,
            languageId: "swift", method: method, line: 0, character: 0, newName: newName
        )
    }

    private func formatRequest(file: URL, content: String) -> LanguageServerRequest {
        LanguageServerRequest(
            root: root.path, config: config, content: content, filePath: file.path,
            languageId: "swift"
        )
    }

    private static func command(root: URL, config: LanguageServerConfig) -> ToolCommand {
        ToolCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: config.args, workingDirectoryURL: root, timeout: 60,
            maximumStandardInputBytes: LSPProtocolLimits.maximumInputQueueBytes,
            maximumStandardOutputBytes: 1024 * 1024,
            maximumStandardErrorBytes: 1024 * 1024
        )
    }

    private static func range(line: Int, character: Int) -> LSPJSONValue {
        .object([
            "start": .object(["line": .integer(Int64(line)), "character": .integer(Int64(character))]),
            "end": .object(["line": .integer(Int64(line)), "character": .integer(Int64(character + 1))])
        ])
    }

    private func eventually(
        attempts: Int = 2_000, _ predicate: @escaping () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition did not become true")
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private final class LanguageServerEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LanguageServerEvent] = []

    func record(_ event: LanguageServerEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }

    func statuses() -> [LanguageServerStatus] {
        lock.lock()
        let result = values.compactMap {
            if case let .status(status) = $0 { return status }
            return nil
        }
        lock.unlock()
        return result
    }

    func diagnostics() -> [LanguageServerDiagnosticsUpdate] {
        lock.lock()
        let result = values.compactMap {
            if case let .diagnostics(update) = $0 { return update }
            return nil
        }
        lock.unlock()
        return result
    }

    func logs() -> [LanguageServerLogEntry] {
        lock.lock()
        let result = values.compactMap {
            if case let .log(entry) = $0 { return entry }
            return nil
        }
        lock.unlock()
        return result
    }
}

private actor FakeLanguageServerRunner: LanguageServerProcessRunning {
    private let autoRespond: Bool
    private let interactiveAutoRespond: Bool
    private let responses: [String: LSPJSONValue]
    private var sessions: [FakeLanguageServerSession] = []
    private var startedCommands: [ToolCommand] = []

    init(
        autoRespond: Bool,
        interactiveAutoRespond: Bool = true,
        responses: [String: LSPJSONValue] = [:]
    ) {
        self.autoRespond = autoRespond
        self.interactiveAutoRespond = interactiveAutoRespond
        self.responses = responses
    }

    func start(
        _ command: ToolCommand, onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any LanguageServerProcessSessioning {
        let session = FakeLanguageServerSession(
            onOutput: onOutput, autoRespond: autoRespond,
            interactiveAutoRespond: interactiveAutoRespond, responses: responses
        )
        startedCommands.append(command)
        sessions.append(session)
        return session
    }

    func session(at index: Int) throws -> FakeLanguageServerSession {
        guard sessions.indices.contains(index) else { throw FakeError.missingSession }
        return sessions[index]
    }

    func sessionCount() -> Int { sessions.count }

    func startedCommandList() -> [ToolCommand] { startedCommands }
}

private actor FakeLanguageServerSession: LanguageServerProcessSessioning {
    private let onOutput: ToolProcessOutputHandler
    private let autoRespond: Bool
    private let interactiveAutoRespond: Bool
    private let responses: [String: LSPJSONValue]
    private let reader = LSPMessageReader()
    private var messages: [LSPMessage] = []
    private var chunks: [Data] = []
    private var result: ToolProcessResult?
    private var cancelled = false
    private var standardInputClosed = false

    init(
        onOutput: @escaping ToolProcessOutputHandler, autoRespond: Bool,
        interactiveAutoRespond: Bool, responses: [String: LSPJSONValue]
    ) {
        self.onOutput = onOutput
        self.autoRespond = autoRespond
        self.interactiveAutoRespond = interactiveAutoRespond
        self.responses = responses
    }

    func write(_ data: Data) async throws {
        guard result == nil, !standardInputClosed else { throw FakeError.closed }
        chunks.append(data)
        let output = reader.append(data)
        for message in output.messages {
            messages.append(message)
            await respondIfNeeded(to: message)
        }
    }

    func closeStandardInput() async throws { standardInputClosed = true }

    nonisolated func cancel() { Task { await self.finish(cancelled: true) } }

    func waitForExit() async throws -> ToolProcessResult {
        while result == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return result!
    }

    func receivedMessages() -> [LSPMessage] { messages }
    func writeChunks() -> [Data] { chunks }
    func wasCancelled() -> Bool { cancelled }

    func waitForMethods(_ methods: Set<String>) async throws {
        for _ in 0..<2_000 {
            let received = Set(messages.compactMap(\.methodName))
            if methods.isSubset(of: received) { return }
            await Task.yield()
        }
        throw FakeError.timedOut
    }

    func emit(stream: ToolOutputStream, data: Data) { onOutput(stream, data) }

    func emitNotification(method: String, params: LSPJSONValue) {
        emitMessage([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params
        ])
    }

    func emitResponse(id: LSPRequestID, result: LSPJSONValue) {
        emitMessage([
            "jsonrpc": .string("2.0"), "id": id.jsonValue, "result": result
        ])
    }

    private func respondIfNeeded(to message: LSPMessage) async {
        guard autoRespond, let method = message.methodName, let id = message.requestID else { return }
        if method == "initialize" {
            emitResponse(id: id, result: .object([
                "capabilities": .object([
                    "hoverProvider": .bool(true),
                    "completionProvider": .object([:]),
                    "unusedProvider": .bool(false)
                ]),
                "serverInfo": .object(["name": .string("Fake LSP")])
            ]))
        } else if method == "shutdown" {
            emitResponse(id: id, result: .null)
        } else if interactiveAutoRespond, let response = responses[method] {
            emitResponse(id: id, result: response)
        }
    }

    private func emitMessage(_ message: LSPMessage) {
        if let data = try? LSPMessageFraming.encode(message) {
            onOutput(.standardOutput, data)
        }
    }

    private func finish(cancelled: Bool) {
        guard result == nil else { return }
        self.cancelled = cancelled
        let value = ToolProcessResult(
            standardOutput: Data(), standardError: Data(), exitCode: cancelled ? 143 : 0
        )
        result = value
    }
}

private enum FakeError: Error { case missingSession, closed, timedOut }

private extension Dictionary where Key == String, Value == LSPJSONValue {
    var methodName: String? {
        guard case let .string(method)? = self["method"] else { return nil }
        return method
    }

    var requestID: LSPRequestID? { self["id"]?.requestID }
}

private extension Array where Element == LSPMessage {
    func firstRequestID(method: String) -> LSPRequestID? {
        first { $0.methodName == method }?.requestID
    }
}

private extension LSPJSONValue {
    var requestID: LSPRequestID? {
        switch self {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        default: nil
        }
    }
}

private extension LSPRequestID {
    var jsonValue: LSPJSONValue {
        switch self {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        }
    }
}
