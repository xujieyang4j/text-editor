import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class CodeMirrorParserServiceTests: XCTestCase {
    func testProductionRunnerHasExplicitSmallAdmissionBounds() {
        XCTAssertEqual(CodeMirrorParserService.maximumConcurrentProductionWorkers, 2)
        XCTAssertEqual(CodeMirrorParserService.maximumPendingProductionWorkers, 4)
    }

    func testAnalyzeRequestBoundsAndNormalizesNewlineProbePositions() {
        let request = CodeMirrorParserService.AnalyzeRequest(
            text: "value", language: "Swift",
            newlineIndentationPositions: [5, 2, 5, -1, 6, 4, 3, 1, 0]
        )
        XCTAssertEqual(request.newlineIndentationPositions, [0, 1, 2, 3, 4, 5])

        let bounded = CodeMirrorParserService.AnalyzeRequest(
            text: String(repeating: "x", count: 20), language: "Swift",
            newlineIndentationPositions: Array(0...20)
        )
        XCTAssertEqual(
            bounded.newlineIndentationPositions.count,
            CodeMirrorParserService.AnalyzeRequest
                .maximumNewlineIndentationPositions
        )
    }

    func testCancelAllAwaitsInjectedRunnerReclamation() async {
        let runner = ParserRunnerReclamationGate()
        let service = CodeMirrorParserService(runner: runner)
        let cancellation = Task { await service.cancelAll() }

        await runner.waitUntilCancellationStarted()
        let cancelCount = await runner.cancelCount
        XCTAssertEqual(cancelCount, 1)
        await runner.releaseCancellation()
        await cancellation.value
        let completedCancelCount = await runner.completedCancelCount
        XCTAssertEqual(completedCancelCount, 1)
    }

    func testInlineCancelAllDoesNotTouchProductionRunner() async {
        let runner = ParserRunnerReclamationGate()
        let service = CodeMirrorParserService(
            scriptSource: .inline(Self.validScript), runner: runner
        )

        await service.cancelAll()

        let cancelCount = await runner.cancelCount
        XCTAssertEqual(cancelCount, 0)
    }

    func testInlineScriptReturnsTypedEnvelopeAndRequestOptions() async throws {
        let service = CodeMirrorParserService(scriptSource: .inline(Self.validScript))
        let analysis = await service.analyze(
            .init(
                text: "hi🙂", language: "Swift", tabWidth: 8,
                indentWidth: 2, insertSpaces: false
            )
        )
        let result = try XCTUnwrap(analysis)

        XCTAssertFalse(result.supported)
        XCTAssertEqual(result.requestedLanguage, "Swift")
        XCTAssertEqual(result.sourceUTF16Length, 4)
        XCTAssertEqual(result.resolvedLanguage, "8:2:false:4")
    }

    func testProductionBundleParsesJavaScriptWithUTF16Offsets() async throws {
        try requireProductionWorker()
        XCTAssertNotNil(CodeMirrorParserService.defaultBundleURL())
        let service = CodeMirrorParserService()
        let text = "😀 function demo(value) {\nreturn value\n}"
        let analysis = await service.analyze(text: text, language: "JavaScript")
        let result = try XCTUnwrap(analysis)

        XCTAssertTrue(result.supported)
        XCTAssertEqual(result.sourceUTF16Length, text.utf16.count)
        XCTAssertEqual(result.syntaxNodes.first?.from, 0)
        XCTAssertEqual(result.syntaxNodes.first?.to, text.utf16.count)
        XCTAssertTrue(result.highlights.contains { $0.kind == .keyword && $0.from == 3 })
        XCTAssertFalse(result.bracketPairs.isEmpty)
    }

    func testProductionBundleParsesSwiftWithStreamCapabilities() async throws {
        try requireProductionWorker()
        XCTAssertNotNil(CodeMirrorParserService.defaultBundleURL())
        let service = CodeMirrorParserService()
        let text = "😀\nfunc run(_ value: Int) { print(value) } // (note)\n"
        let analysis = await service.analyze(text: text, language: "Swift")
        let result = try XCTUnwrap(analysis)
        let keywordRange = (text as NSString).range(of: "func")
        let commentRange = (text as NSString).range(of: "// (note)")

        XCTAssertTrue(result.supported)
        XCTAssertEqual(result.parserKind, .stream)
        XCTAssertEqual(result.sourceUTF16Length, text.utf16.count)
        XCTAssertEqual(result.syntaxNodes, [
            .init(from: 0, to: text.utf16.count, type: "Document", parent: -1)
        ])
        let expectedPairs = [
            "(_ value: Int)", "{ print(value) }", "(value)"
        ].map { token -> CodeMirrorParserResult.BracketPair in
            let range = (text as NSString).range(of: token)
            return .init(open: range.location, close: NSMaxRange(range) - 1)
        }
        XCTAssertEqual(result.bracketPairs, expectedPairs)
        XCTAssertTrue(result.folds.isEmpty)
        XCTAssertTrue(result.symbols.isEmpty)
        XCTAssertTrue(result.highlights.contains { highlight in
            highlight.kind == .keyword && highlight.from == keywordRange.location
                && highlight.to == NSMaxRange(keywordRange)
        })
        XCTAssertTrue(result.highlights.contains { highlight in
            highlight.kind == .comment && highlight.from == commentRange.location
                && highlight.to == NSMaxRange(commentRange)
        })
        XCTAssertEqual(result.indentation.map(\.lineFrom), [0, 3, text.utf16.count])
    }

    func testProductionBundleAcceptsRecoveryNodeAtParentEnd() async throws {
        try requireProductionWorker()
        let service = CodeMirrorParserService()
        let text = "("
        let analysis = await service.analyze(text: text, language: "JavaScript")
        let result = try XCTUnwrap(analysis)
        let recovery = try XCTUnwrap(result.syntaxNodes.first {
            $0.from == text.utf16.count && $0.to == text.utf16.count
        })

        XCTAssertGreaterThanOrEqual(recovery.parent, 0)
        XCTAssertEqual(result.syntaxNodes[recovery.parent].to, text.utf16.count)
        XCTAssertNotNil(result.parsedSyntaxSnapshot(expectedRevision: 1))
    }

    func testProductionBundleNormalizesMarkdownHeadingLabels() async throws {
        try requireProductionWorker()
        let service = CodeMirrorParserService()
        let text = "# A\u{0007}#\nTitle\u{0085}X\n-----"
        let analysis = await service.analyze(text: text, language: "Markdown")
        let result = try XCTUnwrap(analysis)

        XCTAssertEqual(result.symbols.map(\.label), ["A", "Title X"])
        XCTAssertEqual(result.symbols.map(\.level), [0, 1])
    }

    func testMissingBundleReturnsNil() async {
        let service = CodeMirrorParserService(bundleURL: {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("missing-" + UUID().uuidString + ".js")
        })
        let result = await service.analyze(text: "value", language: "Swift")
        XCTAssertNil(result)
    }

    func testProductionRunnerReceivesResolvedRegularBundleAndWorkerPaths() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-parser-paths-" + UUID().uuidString, isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("parser.js")
        let worker = directory.appendingPathComponent("worker")
        try? Data("parser".utf8).write(to: bundle)
        try? Data("worker".utf8).write(to: worker)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], atPath: worker.path
        )
        let runner = ParserCommandCaptureRunner(
            response: Data(Self.validEnvelopeJSON(text: "ok", language: "Swift").utf8)
        )
        let service = CodeMirrorParserService(
            bundleURL: { bundle }, workerExecutableURL: { worker }, runner: runner
        )

        let analysis = await service.analyze(text: "ok", language: "Swift")
        XCTAssertNotNil(analysis)
        let command = await runner.lastCommand
        XCTAssertEqual(command?.executableURL, worker.resolvingSymlinksInPath())
        XCTAssertEqual(command?.arguments, [bundle.resolvingSymlinksInPath().path])
        XCTAssertEqual(command?.processGroupPolicy, .childOnly)
    }

    func testProductionRejectsNonExecutableWorkerBeforeRunner() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-parser-noexec-" + UUID().uuidString, isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("parser.js")
        let worker = directory.appendingPathComponent("worker")
        try? Data("parser".utf8).write(to: bundle)
        try? Data("worker".utf8).write(to: worker)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], atPath: worker.path
        )
        let runner = ParserCommandCaptureRunner(response: Data())
        let service = CodeMirrorParserService(
            bundleURL: { bundle }, workerExecutableURL: { worker }, runner: runner
        )

        let analysis = await service.analyze(text: "ok", language: "Swift")
        let command = await runner.lastCommand
        XCTAssertNil(analysis)
        XCTAssertNil(command)
    }

    func testJavaScriptExceptionReturnsNilAndNextRequestRecovers() async {
        let service = CodeMirrorParserService(scriptSource: .inline(Self.throwingScript))
        let failed = await service.analyze(text: "bad", language: "Swift")
        let recovered = await service.analyze(text: "good", language: "Swift")
        XCTAssertNil(failed)
        XCTAssertNotNil(recovered)
    }

    func testSourceBudgetReturnsNilBeforeEvaluation() async {
        let service = CodeMirrorParserService(
            scriptSource: .inline(Self.validScript),
            limits: .init(maximumSourceUTF16Length: 3)
        )
        let result = await service.analyze(text: "🙂🙂", language: "Swift")
        XCTAssertNil(result)
    }

    func testResultBudgetReturnsNilWhenJSONStringResponseIsTooLarge() async {
        let service = CodeMirrorParserService(
            scriptSource: .inline(Self.validScript),
            limits: .init(maximumResultUTF8Bytes: 64)
        )
        let result = await service.analyze(text: "ok", language: "Swift")
        XCTAssertNil(result)
    }

    func testExecutionTimeBudgetDropsSlowValidResult() async {
        let service = CodeMirrorParserService(
            scriptSource: .inline(Self.slowScript),
            limits: .init(executionTimeLimit: 0.001)
        )
        let result = await service.analyze(text: "ok", language: "Swift")
        XCTAssertNil(result)
    }

    func testConcurrentCallersShareSerialContextSafely() async {
        let service = CodeMirrorParserService(scriptSource: .inline(Self.validScript))
        let results = await withTaskGroup(
            of: CodeMirrorParserAnalysis?.self, returning: [CodeMirrorParserAnalysis].self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    await service.analyze(
                        text: "item-\(index)", language: "Plain Text"
                    )
                }
            }
            var values: [CodeMirrorParserAnalysis] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }
        XCTAssertEqual(results.count, 8)
    }

    func testProductionWorkerHardTimeoutAndSubsequentRequestRecovery() async throws {
        try requireProductionWorker()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-parser-worker-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("parser.js")
        let hangingScript = Self.script(
            prefix: "if (request.text === 'bad') { while (true) {} }"
        )
        try Data(hangingScript.utf8).write(to: scriptURL)
        let service = CodeMirrorParserService(
            limits: .init(executionTimeLimit: 0.5),
            bundleURL: { scriptURL }
        )

        let startedAt = Date()
        let timedOut = await service.analyze(text: "bad", language: "Swift")
        XCTAssertNil(timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)

        let recovered = await service.analyze(text: "good", language: "Swift")
        XCTAssertNotNil(recovered)
    }

    private static let validScript = script(prefix: "")
    private static let throwingScript = script(
        prefix: "if (request.text === 'bad') throw new Error('boom');"
    )
    private static let slowScript = script(
        prefix: "var start = Date.now(); while (Date.now() - start < 20) {}"
    )

    private static func script(prefix: String) -> String {
        """
        globalThis.LumenCodeMirrorParser = {
          analyze: function (requestJSON) {
            var request = JSON.parse(requestJSON);
            \(prefix)
            return JSON.stringify({ result: {
              schemaVersion: 2, supported: false, parserKind: "unsupported",
              requestedLanguage: request.language,
              resolvedLanguage: request.tabWidth + ":" + request.indentWidth + ":"
                + request.insertSpaces + ":" + request.text.length,
              sourceUTF16Length: request.text.length, highlights: [], syntaxNodes: [],
              bracketPairs: [], folds: [], symbols: [], indentation: [],
              truncated: { source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false, indentation: false }
            }});
          }
        };
        """
    }

    private static func validEnvelopeJSON(text: String, language: String) -> String {
        """
        {"result":{"schemaVersion":2,"supported":false,
        "parserKind":"unsupported","requestedLanguage":"\(language)",
        "resolvedLanguage":"\(language)","sourceUTF16Length":\(text.utf16.count),
        "highlights":[],"syntaxNodes":[],"bracketPairs":[],"folds":[],
        "symbols":[],"indentation":[],"truncated":{"source":false,
        "highlights":false,"syntaxNodes":false,"bracketPairs":false,
        "folds":false,"symbols":false,"indentation":false}}}
        """
    }

    private func requireProductionWorker(
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["LUMEN_REQUIRE_WORKERS"] == "1" {
            guard CodeMirrorParserService.defaultWorkerExecutableURL() != nil else {
                XCTFail(
                    "LumenParserWorker is required but unavailable; "
                        + "run native-macos/scripts/verify.sh",
                    file: file, line: line
                )
                throw CocoaError(.fileNoSuchFile)
            }
        } else {
            try XCTSkipIf(
                CodeMirrorParserService.defaultWorkerExecutableURL() == nil,
                "LumenParserWorker is unavailable; run native-macos/scripts/verify.sh",
                file: file, line: line
            )
        }
    }
}

private actor ParserCommandCaptureRunner: ToolCommandRunning {
    private(set) var lastCommand: ToolCommand?
    let response: Data

    init(response: Data) { self.response = response }

    func run(_ command: ToolCommand) async throws -> ToolProcessResult {
        lastCommand = command
        return ToolProcessResult(
            standardOutput: response, standardError: Data(), exitCode: 0
        )
    }

    func cancelAll() async {}
}

private actor ParserRunnerReclamationGate: ToolCommandRunning {
    private(set) var cancelCount = 0
    private(set) var completedCancelCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_ command: ToolCommand) async throws -> ToolProcessResult {
        ToolProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
    }

    func cancelAll() async {
        cancelCount += 1
        startWaiters.forEach { $0.resume() }
        startWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
        completedCancelCount += 1
    }

    func waitUntilCancellationStarted() async {
        guard cancelCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCancellation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
