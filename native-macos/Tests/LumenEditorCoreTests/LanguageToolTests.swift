import Foundation
import XCTest
@testable import LumenEditorCore

final class LanguageToolTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/lumen-language-tool-tests", isDirectory: true)
    private let scope = ToolApprovalScope(windowID: "tool-window", sessionID: "tool-session")

    func testPlainStdoutIsReplacementContent() throws {
        let result = try LanguageToolOutputParser.parse(Data("formatted\n".utf8))

        XCTAssertEqual(result.content, "formatted\n")
        XCTAssertEqual(result.diagnostics, [])
    }

    func testStructuredOutputFiltersAndBoundsDiagnostics() throws {
        let values: [[String: Any]] = (0...LanguageToolLimits.maximumDiagnostics).map { index in
            [
                "line": index == 0 ? -4.8 : Double(index + 1),
                "column": 0,
                "endLine": 3.9,
                "endColumn": 5,
                "severity": index == 0 ? "warning" : "unknown",
                "message": index == 0
                    ? String(repeating: "🙂", count: 1_500)
                    : "diagnostic \(index)"
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "content": "replacement", "diagnostics": values + [["line": 1]]
        ])

        let result = try LanguageToolOutputParser.parse(data)

        XCTAssertEqual(result.content, "replacement")
        XCTAssertEqual(result.diagnostics.count, LanguageToolLimits.maximumDiagnostics)
        XCTAssertEqual(result.diagnostics.first?.line, 1)
        XCTAssertEqual(result.diagnostics.first?.column, 1)
        XCTAssertEqual(result.diagnostics.first?.endLine, 3)
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertEqual(
            result.diagnostics.first?.message.utf16.count,
            LanguageToolLimits.maximumDiagnosticMessageUTF16CodeUnits
        )
        XCTAssertFalse(result.diagnostics.first?.message.contains("�") == true)
    }

    func testJSONWithoutDiagnosticsRemainsPlainFormatterOutput() throws {
        let source = #"{"content":"not-a-structured-result"}"#
        XCTAssertEqual(
            try LanguageToolOutputParser.parse(Data(source.utf8)),
            LanguageToolResult(content: source)
        )
    }

    func testInvalidStdoutUTF8IsRejected() {
        XCTAssertThrowsError(try LanguageToolOutputParser.parse(Data([0xff]))) { error in
            XCTAssertEqual(
                error as? LanguageToolError,
                .invalidUTF8(.standardOutput)
            )
        }
    }

    func testExactApprovalThenDirectArgvExecutionUsesBoundedCommand() async throws {
        let runner = LanguageToolRunnerStub(results: [ToolProcessResult(
            standardOutput: Data("formatted".utf8), standardError: Data(), exitCode: 0
        )])
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: ["LANG": "en_US.UTF-8"]
        )
        let config = LanguageToolConfig(
            command: "xcrun", args: ["swift-format", "format"],
            workingDirectory: "Sources", env: ["MODE": "check"]
        )
        let request = LanguageToolRequest(
            root: root, configuration: config, content: "source",
            fileURL: root.appendingPathComponent("Sources/main.swift")
        )

        do {
            _ = try await service.run(request)
            XCTFail("Expected exact approval")
        } catch let LanguageToolError.approvalRequired(configuration) {
            XCTAssertEqual(configuration.kind, .languageTool)
            XCTAssertFalse(configuration.shell)
            XCTAssertEqual(configuration.args, ["swift-format", "format"])
            XCTAssertEqual(configuration.env["MODE"], "check")
            await service.approve(configuration)
        }

        let result = try await service.run(request)
        XCTAssertEqual(result.content, "formatted")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(command.arguments, ["swift-format", "format"])
        XCTAssertEqual(command.standardInput, Data("source".utf8))
        XCTAssertEqual(command.timeout, ToolExecutionLimits.languageToolTimeout)
        XCTAssertEqual(
            command.maximumStandardInputBytes,
            ToolExecutionLimits.maximumOneShotStdinBytes
        )
        XCTAssertEqual(
            command.maximumStandardOutputBytes,
            ToolExecutionLimits.maximumStandardOutputBytes
        )
        XCTAssertEqual(
            command.maximumStandardErrorBytes,
            ToolExecutionLimits.maximumStandardErrorBytes
        )
        XCTAssertEqual(command.processGroupPolicy, .isolated)
    }

    func testShellIsUsedOnlyWhenExplicitlyConfigured() async throws {
        let runner = LanguageToolRunnerStub(results: [ToolProcessResult(
            standardOutput: Data("ok".utf8), standardError: Data(), exitCode: 0
        )])
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let config = LanguageToolConfig(
            command: "printf formatted", args: [], shell: true
        )
        let approved = try await service.approvalConfiguration(
            root: root, configuration: config
        )
        await service.approve(approved)

        _ = try await service.run(LanguageToolRequest(
            root: root, configuration: config, content: "input"
        ))

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.executableURL.path, "/bin/sh")
        XCTAssertEqual(command.arguments, ["-c", "printf formatted"])
    }

    func testChangedArgumentsDoNotReuseApproval() async throws {
        let runner = LanguageToolRunnerStub()
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let first = LanguageToolConfig(command: "xcrun", args: ["first"])
        let second = LanguageToolConfig(command: "xcrun", args: ["second"])
        let approved = try await service.approvalConfiguration(
            root: root, configuration: first
        )
        await service.approve(approved)

        do {
            _ = try await service.run(LanguageToolRequest(
                root: root, configuration: second, content: "input"
            ))
            XCTFail("Expected changed identity to require approval")
        } catch let LanguageToolError.approvalRequired(configuration) {
            XCTAssertEqual(configuration.args, ["second"])
        }
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testDocumentMustStayInsideWorkspace() async throws {
        let runner = LanguageToolRunnerStub()
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let config = LanguageToolConfig(command: "xcrun", args: ["formatter"])
        let approved = try await service.approvalConfiguration(
            root: root, configuration: config
        )
        await service.approve(approved)
        let outside = URL(fileURLWithPath: "/tmp/outside.swift")

        do {
            _ = try await service.run(LanguageToolRequest(
                root: root, configuration: config, content: "input", fileURL: outside
            ))
            XCTFail("Expected workspace containment check")
        } catch let error as LanguageToolError {
            XCTAssertEqual(
                error,
                .fileOutsideWorkspace(
                    file: outside.standardizedFileURL.resolvingSymlinksInPath(),
                    root: root.standardizedFileURL.resolvingSymlinksInPath()
                )
            )
        }
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testExplicitExecutableSelectionIsRequiredAndSessionLocal() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tool-selection-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: temporary.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let service = LanguageToolService(
            runner: LanguageToolRunnerStub(), approvals: ToolApprovalStore(),
            approvalScope: scope, resolver: .system, inheritedEnvironment: [:]
        )
        let relativeCommand = "./" + temporary.lastPathComponent
        let selectionRoot = temporary.deletingLastPathComponent()
        let config = LanguageToolConfig(command: relativeCommand, args: [])

        do {
            _ = try await service.approvalConfiguration(
                root: selectionRoot, configuration: config
            )
            XCTFail("Expected an unselected executable to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ToolExecutionError,
                .executableNotAllowed(relativeCommand)
            )
        }

        let authorized = try await service.authorizeExecutable(temporary)
        XCTAssertEqual(authorized, temporary)
        let approved = try await service.approvalConfiguration(
            root: selectionRoot, configuration: config
        )
        XCTAssertEqual(approved.executableURL, temporary)
    }

    func testNonzeroExitUsesBoundedStderr() async throws {
        let runner = LanguageToolRunnerStub(results: [ToolProcessResult(
            standardOutput: Data(),
            standardError: Data(String(repeating: "e", count: 3_000).utf8),
            exitCode: 7
        )])
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let config = LanguageToolConfig(command: "xcrun", args: ["formatter"])
        let approved = try await service.approvalConfiguration(
            root: root, configuration: config
        )
        await service.approve(approved)

        do {
            _ = try await service.run(LanguageToolRequest(
                root: root, configuration: config, content: "input"
            ))
            XCTFail("Expected nonzero exit")
        } catch let LanguageToolError.nonzeroExit(code, detail) {
            XCTAssertEqual(code, 7)
            XCTAssertEqual(
                detail.utf16.count,
                LanguageToolLimits.maximumErrorDetailUTF16CodeUnits
            )
        }
    }

    func testNonzeroExitSanitizesControlCharactersInDisplayedStderr() async throws {
        let runner = LanguageToolRunnerStub(results: [ToolProcessResult(
            standardOutput: Data(),
            standardError: Data("visible\u{0}\u{7}\nnext".utf8),
            exitCode: 2
        )])
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let config = LanguageToolConfig(command: "xcrun", args: ["formatter"])
        let approved = try await service.approvalConfiguration(
            root: root, configuration: config
        )
        await service.approve(approved)

        do {
            _ = try await service.run(LanguageToolRequest(
                root: root, configuration: config, content: "input"
            ))
            XCTFail("Expected nonzero exit")
        } catch let LanguageToolError.nonzeroExit(_, detail) {
            XCTAssertEqual(detail, "visible\nnext")
        }
    }

    func testOversizedInputFailsBeforeRunner() async throws {
        let runner = LanguageToolRunnerStub()
        let approvals = ToolApprovalStore()
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: scope,
            resolver: .system, inheritedEnvironment: [:]
        )
        let config = LanguageToolConfig(command: "xcrun", args: ["formatter"])
        let approved = try await service.approvalConfiguration(
            root: root, configuration: config
        )
        await service.approve(approved)
        let content = String(
            repeating: "a",
            count: ToolExecutionLimits.maximumOneShotStdinBytes + 1
        )

        do {
            _ = try await service.run(LanguageToolRequest(
                root: root, configuration: config, content: content
            ))
            XCTFail("Expected input bound")
        } catch let error as ToolExecutionError {
            XCTAssertEqual(
                error,
                .standardInputTooLarge(
                    actualBytes: ToolExecutionLimits.maximumOneShotStdinBytes + 1,
                    maximumBytes: ToolExecutionLimits.maximumOneShotStdinBytes
                )
            )
        }
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testBuiltInFormatterMatchesElectronWhitespaceFallback() {
        XCTAssertEqual(
            BuiltInDocumentFormatter.format("one  \n\t\n\n\n two\t\n"),
            "one\n\n two\n"
        )
        XCTAssertEqual(BuiltInDocumentFormatter.format("unchanged"), "unchanged")
    }
}

private actor LanguageToolRunnerStub: ToolCommandRunning {
    private var results: [ToolProcessResult]
    private(set) var commands: [ToolCommand] = []
    private(set) var cancelCount = 0

    init(results: [ToolProcessResult] = []) { self.results = results }

    func run(_ command: ToolCommand) async throws -> ToolProcessResult {
        commands.append(command)
        return results.isEmpty
            ? ToolProcessResult(
                standardOutput: Data(), standardError: Data(), exitCode: 0
            )
            : results.removeFirst()
    }

    func cancelAll() async { cancelCount += 1 }
}
