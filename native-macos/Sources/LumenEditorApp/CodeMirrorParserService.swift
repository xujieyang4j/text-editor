import Foundation
import JavaScriptCore
import LumenEditorCore

/// Bounded bridge for the CodeMirror parser bundle.
///
/// Production parsing always happens in a fresh, killable helper process. The
/// inline source is an intentionally in-process test seam; it must never be
/// used for production content because public JavaScriptCore has no hard
/// execution deadline API. All failures deliberately degrade to `nil`.
final class CodeMirrorParserService: @unchecked Sendable {
    static let maximumConcurrentProductionWorkers = 2
    static let maximumPendingProductionWorkers = 4

    struct Limits: Equatable, Sendable {
        static let `default` = Limits()

        var maximumBundleUTF8Bytes: Int
        var maximumSourceUTF16Length: Int
        var maximumRequestUTF8Bytes: Int
        var maximumResultUTF8Bytes: Int
        var executionTimeLimit: TimeInterval

        init(
            maximumBundleUTF8Bytes: Int = 8 * 1_024 * 1_024,
            maximumSourceUTF16Length: Int = 128 * 1_024,
            maximumRequestUTF8Bytes: Int = 1 * 1_024 * 1_024,
            maximumResultUTF8Bytes: Int = 2 * 1_024 * 1_024,
            executionTimeLimit: TimeInterval = 1.0
        ) {
            self.maximumBundleUTF8Bytes = maximumBundleUTF8Bytes
            self.maximumSourceUTF16Length = maximumSourceUTF16Length
            self.maximumRequestUTF8Bytes = maximumRequestUTF8Bytes
            self.maximumResultUTF8Bytes = maximumResultUTF8Bytes
            self.executionTimeLimit = executionTimeLimit
        }
    }

    struct AnalyzeRequest: Codable, Equatable, Sendable {
        static let maximumNewlineIndentationPositions = 8
        var text: String
        var language: String
        var tabWidth: Int
        var indentWidth: Int
        var insertSpaces: Bool
        var newlineIndentationPositions: [Int]

        init(
            text: String, language: String, tabWidth: Int = 4,
            indentWidth: Int? = nil, insertSpaces: Bool = true,
            newlineIndentationPositions: [Int] = []
        ) {
            self.text = text
            self.language = language
            self.tabWidth = min(16, max(1, tabWidth))
            self.indentWidth = min(16, max(1, indentWidth ?? tabWidth))
            self.insertSpaces = insertSpaces
            self.newlineIndentationPositions = Array(
                Set(newlineIndentationPositions.filter {
                    $0 >= 0 && $0 <= text.utf16.count
                })
            ).sorted().prefix(
                Self.maximumNewlineIndentationPositions
            ).map { $0 }
        }
    }

    enum ScriptSource: Equatable, Sendable {
        case productionBundle
        case inline(String)
    }

    private struct LoadedScript: Equatable, Sendable {
        let cacheKey: String
        let source: String
        let sourceURL: URL
    }

    private enum BridgeError: Error {
        case bundleUnavailable
        case bundleTooLarge
        case sourceTooLarge
        case resultTooLarge
        case javaScriptUnavailable
        case javaScriptException
        case parserUnavailable
        case invalidResult
        case executionTimedOut
        case workerUnavailable
        case workerFailed
    }

    private let scriptSource: ScriptSource
    private let limits: Limits
    private let fileManager: FileManager
    private let bundleURL: @Sendable () -> URL?
    private let workerExecutableURL: @Sendable () -> URL?
    private let runner: any ToolCommandRunning
    private let queue: DispatchQueue

    private var loadedScript: LoadedScript?
    private var context: JSContext?
    private var analyzeFunction: JSValue?

    init(
        scriptSource: ScriptSource = .productionBundle,
        limits: Limits = .default,
        fileManager: FileManager = .default,
        bundleURL: @escaping @Sendable () -> URL? = Self.defaultBundleURL,
        workerExecutableURL: @escaping @Sendable () -> URL? =
            Self.defaultWorkerExecutableURL,
        runner: (any ToolCommandRunning)? = nil
    ) {
        self.scriptSource = scriptSource
        self.limits = limits
        self.fileManager = fileManager
        self.bundleURL = bundleURL
        self.workerExecutableURL = workerExecutableURL
        if let runner {
            self.runner = runner
        } else {
            self.runner = ToolProcessRunner(
                maximumConcurrentProcesses:
                    Self.maximumConcurrentProductionWorkers,
                maximumPendingProcesses: Self.maximumPendingProductionWorkers
            )
        }
        queue = DispatchQueue(
            label: "LumenEditor.CodeMirrorParserService.\(UUID().uuidString)"
        )
    }

    func analyze(_ request: AnalyzeRequest) async -> CodeMirrorParserAnalysis? {
        guard request.text.utf16.count <= limits.maximumSourceUTF16Length else {
            return nil
        }
        switch scriptSource {
        case .productionBundle:
            do {
                return try await analyzeInWorker(request)
            } catch {
                return nil
            }
        case .inline:
            return await analyzeInline(request)
        }
    }

    func analyze(
        text: String, language: String, tabWidth: Int = 4,
        indentWidth: Int? = nil, insertSpaces: Bool = true,
        newlineIndentationPositions: [Int] = []
    ) async -> CodeMirrorParserAnalysis? {
        await analyze(AnalyzeRequest(
            text: text, language: language, tabWidth: tabWidth,
            indentWidth: indentWidth, insertSpaces: insertSpaces,
            newlineIndentationPositions: newlineIndentationPositions
        ))
    }

    /// Cancel queued/running production workers and wait for their teardown.
    /// Inline parsing is serialized in-process and has no killable worker.
    func cancelAll() async {
        guard scriptSource == .productionBundle else { return }
        await runner.cancelAll()
    }

    static func defaultBundleURL() -> URL? {
        Bundle.main.url(forResource: "CodeMirrorParserBundle", withExtension: "js")
            ?? Bundle.module.url(
                forResource: "CodeMirrorParserBundle", withExtension: "js"
            )
    }

    static func defaultWorkerExecutableURL() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[
            "LUMEN_PARSER_WORKER_EXECUTABLE"
        ], !override.isEmpty {
            guard (override as NSString).isAbsolutePath else { return nil }
            let url = URL(fileURLWithPath: override, isDirectory: false)
            return validatedExecutableURL(url, fileManager: fileManager)
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            let candidate = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/MacOS/LumenParserWorker", isDirectory: false
            )
            return validatedExecutableURL(candidate, fileManager: fileManager)
        }
        // SwiftPM places resource bundles and products beside one another.
        let candidates = [
            Bundle.module.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("LumenParserWorker", isDirectory: false),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("LumenParserWorker", isDirectory: false)
        ].compactMap { $0 }
        for candidate in candidates {
            if let resolved = validatedExecutableURL(
                candidate, fileManager: fileManager
            ) { return resolved }
        }
        return nil
    }

    private static func validatedExecutableURL(
        _ candidate: URL, fileManager: FileManager
    ) -> URL? {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL,
              let values = try? resolved.resourceValues(forKeys: [
                  .isRegularFileKey, .isSymbolicLinkKey
              ]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: resolved.path) else { return nil }
        return resolved
    }
}

private extension CodeMirrorParserService {
    static var maximumWorkerStandardErrorBytes: Int { 16 * 1_024 }

    func analyzeInWorker(
        _ request: AnalyzeRequest
    ) async throws -> CodeMirrorParserAnalysis {
        guard limits.maximumBundleUTF8Bytes > 0,
              limits.maximumRequestUTF8Bytes > 0,
              limits.maximumResultUTF8Bytes > 0,
              limits.executionTimeLimit > 0, limits.executionTimeLimit.isFinite else {
            throw BridgeError.invalidResult
        }
        guard let rawBundleURL = bundleURL() else {
            throw BridgeError.bundleUnavailable
        }
        let parserBundleURL = rawBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let bundleValues = try parserBundleURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard bundleValues.isRegularFile == true else {
            throw BridgeError.bundleUnavailable
        }
        let bundleBytes = bundleValues.fileSize ?? 0
        guard bundleBytes > 0, bundleBytes <= limits.maximumBundleUTF8Bytes else {
            throw BridgeError.bundleTooLarge
        }
        guard let rawWorkerURL = workerExecutableURL(),
              let workerURL = Self.validatedExecutableURL(
                  rawWorkerURL, fileManager: fileManager
              ),
              let workerValues = try? workerURL.resourceValues(forKeys: [
                  .isRegularFileKey, .isSymbolicLinkKey
              ]),
              workerValues.isRegularFile == true,
              workerValues.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: workerURL.path) else {
            throw BridgeError.workerUnavailable
        }
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= limits.maximumRequestUTF8Bytes else {
            throw BridgeError.sourceTooLarge
        }
        let command = ToolCommand(
            executableURL: workerURL,
            arguments: [parserBundleURL.path],
            workingDirectoryURL: workerURL.deletingLastPathComponent(),
            standardInput: requestData,
            timeout: limits.executionTimeLimit,
            maximumStandardInputBytes: limits.maximumRequestUTF8Bytes,
            maximumStandardOutputBytes: limits.maximumResultUTF8Bytes,
            maximumRetainedStandardOutputBytes: limits.maximumResultUTF8Bytes,
            maximumStandardErrorBytes: Self.maximumWorkerStandardErrorBytes,
            gracefulTerminationTimeout: 0.05,
            processGroupPolicy: .childOnly
        )
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            throw BridgeError.workerFailed
        }
        return try validatedAnalysis(from: result.standardOutput, request: request)
    }

    func analyzeInline(_ request: AnalyzeRequest) async -> CodeMirrorParserAnalysis? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try analyzeInlineOnQueue(request))
                } catch {
                    context = nil
                    analyzeFunction = nil
                    loadedScript = nil
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func analyzeInlineOnQueue(
        _ request: AnalyzeRequest
    ) throws -> CodeMirrorParserAnalysis {
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= limits.maximumRequestUTF8Bytes else {
            throw BridgeError.sourceTooLarge
        }
        let requestJSON = String(data: requestData, encoding: .utf8) ?? ""
        let function = try ensureAnalyzeFunction()
        let startedAt = CFAbsoluteTimeGetCurrent()
        let response = function.call(withArguments: [requestJSON])
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        guard elapsed <= limits.executionTimeLimit else {
            throw BridgeError.executionTimedOut
        }
        if let exception = context?.exception, !exception.isUndefined {
            context?.exception = nil
            throw BridgeError.javaScriptException
        }
        guard let response, !response.isUndefined, !response.isNull else {
            throw BridgeError.invalidResult
        }
        guard let json = response.toString() else {
            throw BridgeError.invalidResult
        }
        return try validatedAnalysis(from: Data(json.utf8), request: request)
    }

    func validatedAnalysis(
        from data: Data, request: AnalyzeRequest
    ) throws -> CodeMirrorParserAnalysis {
        guard data.count <= limits.maximumResultUTF8Bytes else {
            throw BridgeError.resultTooLarge
        }
        guard let envelope = try? JSONDecoder().decode(
            CodeMirrorParserEnvelope.self, from: data
        ),
              let analysis = envelope.result.validated(
                  text: request.text, language: request.language
              ) else {
            throw BridgeError.invalidResult
        }
        return analysis
    }

    func ensureAnalyzeFunction() throws -> JSValue {
        let script = try loadScript()
        if loadedScript != script {
            try install(script: script)
        }
        guard let analyzeFunction else {
            throw BridgeError.parserUnavailable
        }
        return analyzeFunction
    }

    func install(script: LoadedScript) throws {
        guard let context = JSContext() else {
            throw BridgeError.javaScriptUnavailable
        }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript(script.source, withSourceURL: script.sourceURL)
        if let exception = context.exception, !exception.isUndefined {
            context.exception = nil
            throw BridgeError.javaScriptException
        }
        guard let parser = context.objectForKeyedSubscript("LumenCodeMirrorParser")
        else {
            throw BridgeError.parserUnavailable
        }
        let analyze = parser.objectForKeyedSubscript("analyze")
        guard let analyze, !analyze.isUndefined, !analyze.isNull else {
            throw BridgeError.parserUnavailable
        }
        self.context = context
        loadedScript = script
        analyzeFunction = analyze
    }

    func loadScript() throws -> LoadedScript {
        switch scriptSource {
        case .inline(let source):
            return LoadedScript(
                cacheKey: "inline:\(source.hashValue)",
                source: source,
                sourceURL: URL(string: "lumen-parser://inline.js")!
            )
        case .productionBundle:
            throw BridgeError.bundleUnavailable
        }
    }
}
