@preconcurrency import Foundation

// MARK: - Process adapter

/// The deliberately small interactive-process boundary used by the LSP runtime.
/// Keeping it separate from `ToolCommandRunning` lets long-lived language
/// servers use stdin without changing one-shot tool runners and their fakes.
public protocol LanguageServerProcessSessioning: Sendable {
    func write(_ data: Data) async throws
    func closeStandardInput() async throws
    func cancel()
    func waitForExit() async throws -> ToolProcessResult
}

extension ToolProcessSession: LanguageServerProcessSessioning {}

public protocol LanguageServerProcessRunning: Sendable {
    func start(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any LanguageServerProcessSessioning
}

/// The only production coupling between the language-server runtime and the
/// current `ToolProcessRunner` interactive API.
public struct ToolProcessLanguageServerRunner: LanguageServerProcessRunning {
    private let runner: ToolProcessRunner

    public init(runner: ToolProcessRunner = ToolProcessRunner()) {
        self.runner = runner
    }

    public func start(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any LanguageServerProcessSessioning {
        try await runner.start(command, onOutput: onOutput)
    }
}

// MARK: - Public runtime model

public struct LanguageServerInstanceKey: Hashable, Sendable, CustomStringConvertible {
    public let rootPath: String
    public let command: String
    public let arguments: [String]

    public init(root: URL, config: LanguageServerConfig) {
        rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        command = config.command
        arguments = config.args
    }

    public var description: String {
        ([rootPath, command] + arguments).joined(separator: "\u{1f}")
    }
}

public enum LanguageServerClientState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case restarting
    case failed
}

public struct LanguageServerStatus: Equatable, Sendable {
    public let key: LanguageServerInstanceKey
    public let root: URL
    public let config: LanguageServerConfig
    public let state: LanguageServerClientState
    public let generation: UInt64
    /// Monotonic within one process generation; lets consumers reject late
    /// same-generation callbacks without guessing a state-machine rank.
    public let sequence: UInt64
    public let capabilities: [String]
    public let message: String?

    public init(
        key: LanguageServerInstanceKey,
        root: URL,
        config: LanguageServerConfig,
        state: LanguageServerClientState,
        generation: UInt64,
        sequence: UInt64 = 0,
        capabilities: [String] = [],
        message: String? = nil
    ) {
        self.key = key
        self.root = root
        self.config = config
        self.state = state
        self.generation = generation
        self.sequence = sequence
        self.capabilities = capabilities
        self.message = message
    }
}

public enum LanguageServerLogStream: String, Codable, Equatable, Sendable {
    case standardError
    case server
}

public enum LanguageServerLogLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct LanguageServerLogEntry: Equatable, Sendable {
    public let key: LanguageServerInstanceKey
    public let root: URL
    public let stream: LanguageServerLogStream
    public let level: LanguageServerLogLevel
    public let text: String
    public let timestamp: Date
    public let generation: UInt64
    public let sequence: UInt64

    public init(
        key: LanguageServerInstanceKey,
        root: URL,
        stream: LanguageServerLogStream,
        level: LanguageServerLogLevel,
        text: String,
        timestamp: Date = Date(),
        generation: UInt64,
        sequence: UInt64 = 0
    ) {
        self.key = key
        self.root = root
        self.stream = stream
        self.level = level
        self.text = text
        self.timestamp = timestamp
        self.generation = generation
        self.sequence = sequence
    }
}

public struct LanguageServerDiagnosticsUpdate: Equatable, Sendable {
    public let key: LanguageServerInstanceKey
    public let event: LanguageServerDiagnosticEvent
    public let documentVersion: Int?
    public let generation: UInt64
    public let sequence: UInt64

    public init(
        key: LanguageServerInstanceKey,
        event: LanguageServerDiagnosticEvent,
        documentVersion: Int?,
        generation: UInt64,
        sequence: UInt64 = 0
    ) {
        self.key = key
        self.event = event
        self.documentVersion = documentVersion
        self.generation = generation
        self.sequence = sequence
    }
}

public struct LanguageServerRenamePreview: Equatable, Sendable {
    public let key: LanguageServerInstanceKey
    public let fileURL: URL
    public let position: LSPPosition
    public let newName: String
    public let edits: [LanguageRenameEdit]

    public init(
        key: LanguageServerInstanceKey,
        fileURL: URL,
        position: LSPPosition,
        newName: String,
        edits: [LanguageRenameEdit]
    ) {
        self.key = key
        self.fileURL = fileURL
        self.position = position
        self.newName = newName
        self.edits = edits
    }
}

public enum LanguageServerEvent: Equatable, Sendable {
    case status(LanguageServerStatus)
    case diagnostics(LanguageServerDiagnosticsUpdate)
    case log(LanguageServerLogEntry)
}

public enum LanguageServerClientError: Error, Equatable, LocalizedError, Sendable {
    case approvalRequired(ToolExecutionConfiguration)
    case invalidRoot
    case fileOutsideRoot(String)
    case notRunning
    case operationInProgress
    case stopped
    case staleDocumentVersion(current: Int, received: Int)
    case documentVersionExhausted
    case requestTimedOut(String)
    case requestCancelled(String)
    case responseError(code: Int, message: String)
    case invalidResponse(String)
    case processTerminated(String)
    case inputQueueOverflow(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .approvalRequired:
            "This language-server command requires approval for the current session."
        case .invalidRoot:
            "The language-server workspace root is invalid."
        case let .fileOutsideRoot(path):
            "The language-server document is outside its workspace: \(path)"
        case .notRunning:
            "The language server is not running."
        case .operationInProgress:
            "A language-server lifecycle operation is already in progress."
        case .stopped:
            "The language server stopped."
        case let .staleDocumentVersion(current, received):
            "Document version \(received) is not newer than version \(current)."
        case .documentVersionExhausted:
            "The language-server document version is exhausted."
        case let .requestTimedOut(method):
            "Language-server request ‘\(method)’ timed out."
        case let .requestCancelled(method):
            "Language-server request ‘\(method)’ was cancelled."
        case let .responseError(code, message):
            "Language server error \(code): \(message)"
        case let .invalidResponse(method):
            "The language server returned an invalid \(method) response."
        case let .processTerminated(detail):
            "The language-server process terminated: \(detail)"
        case let .inputQueueOverflow(maximumBytes):
            "Language-server input exceeded the \(maximumBytes)-byte queue limit."
        }
    }
}

public typealias LanguageServerEventHandler = @Sendable (LanguageServerEvent) -> Void

// MARK: - Bounded transport helpers

private struct LanguageServerOutputPacket: Sendable {
    let stream: ToolOutputStream
    let data: Data
}

/// `ToolProcessRunner` serializes callbacks, and this relay preserves that
/// order while keeping the callback nonblocking. Both chunk count and byte
/// count are bounded; overflow terminates the affected process generation.
private final class LanguageServerOutputRelay: @unchecked Sendable {
    let stream: AsyncStream<LanguageServerOutputPacket>

    private let lock = NSLock()
    private let continuation: AsyncStream<LanguageServerOutputPacket>.Continuation
    private let onOverflow: @Sendable () -> Void
    private var didOverflow = false
    private var bufferedBytes = 0

    init(onOverflow: @escaping @Sendable () -> Void) {
        var saved: AsyncStream<LanguageServerOutputPacket>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { saved = $0 }
        continuation = saved!
        self.onOverflow = onOverflow
    }

    func receive(stream: ToolOutputStream, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let exceedsBudget = data.count > LSPProtocolLimits.maximumInputQueueBytes - bufferedBytes
        if !exceedsBudget { bufferedBytes += data.count }
        let notify = exceedsBudget && !didOverflow
        if exceedsBudget { didOverflow = true }
        lock.unlock()
        if !exceedsBudget {
            let result = continuation.yield(LanguageServerOutputPacket(stream: stream, data: data))
            guard case .dropped(let packet) = result else { return }
            lock.lock()
            bufferedBytes = max(0, bufferedBytes - packet.data.count)
            let droppedNotify = !didOverflow
            didOverflow = true
            lock.unlock()
            if droppedNotify {
                continuation.finish()
                onOverflow()
            }
            return
        }
        if notify {
            continuation.finish()
            onOverflow()
        }
    }

    func didConsume(_ count: Int) {
        lock.lock()
        bufferedBytes = max(0, bufferedBytes - count)
        lock.unlock()
    }

    func finish() { continuation.finish() }
}

/// A one-shot gate for a deadline race. This deliberately avoids a structured
/// task group because a process waiter is allowed to ignore task cancellation.
private final class LanguageServerDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private actor LanguageServerFrameWriter {
    private enum CloseState {
        case open
        case draining
        case closing
        case closed(Result<Void, Error>)
    }

    private struct QueuedFrame {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let session: any LanguageServerProcessSessioning
    private var queue: [QueuedFrame] = []
    private var queuedBytes = 0
    private var isPumping = false
    private var closeState = CloseState.open
    private var terminalError: Error?
    private var drainWaiters: [CheckedContinuation<Void, Error>] = []
    private var closeWaiters: [CheckedContinuation<Void, Error>] = []

    init(session: any LanguageServerProcessSessioning) {
        self.session = session
    }

    func write(_ frame: Data) async throws {
        guard terminalError == nil, case .open = closeState else {
            throw terminalError ?? LanguageServerClientError.stopped
        }
        guard frame.count <= LSPProtocolLimits.maximumInputQueueBytes - queuedBytes else {
            throw LanguageServerClientError.inputQueueOverflow(
                maximumBytes: LSPProtocolLimits.maximumInputQueueBytes
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            queue.append(QueuedFrame(data: frame, continuation: continuation))
            queuedBytes += frame.count
            if !isPumping {
                isPumping = true
                Task { await self.pump() }
            }
        }
    }

    func close() async throws {
        switch closeState {
        case let .closed(result):
            return try result.get()
        case .draining, .closing:
            return try await withCheckedThrowingContinuation { closeWaiters.append($0) }
        case .open:
            closeState = .draining
        }
        if isPumping || !queue.isEmpty {
            try await withCheckedThrowingContinuation { drainWaiters.append($0) }
        }
        if let terminalError {
            completeClose(.failure(terminalError))
            throw terminalError
        }
        closeState = .closing
        do {
            try await session.closeStandardInput()
            completeClose(.success(()))
        } catch {
            completeClose(.failure(error))
            throw error
        }
    }

    private func pump() async {
        while !queue.isEmpty {
            let frame = queue.removeFirst()
            do {
                var offset = 0
                while offset < frame.data.count {
                    let count = min(
                        ToolExecutionLimits.maximumStdinWriteBytes,
                        frame.data.count - offset
                    )
                    let upper = offset + count
                    try await session.write(frame.data.subdata(in: offset..<upper))
                    offset = upper
                }
                queuedBytes -= frame.data.count
                frame.continuation.resume()
            } catch {
                queuedBytes -= frame.data.count
                frame.continuation.resume(throwing: error)
                failQueued(with: error)
                return
            }
        }
        isPumping = false
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func failQueued(with error: Error) {
        terminalError = error
        closeState = .closed(.failure(error))
        isPumping = false
        let frames = queue
        queue.removeAll(keepingCapacity: false)
        queuedBytes = 0
        frames.forEach { $0.continuation.resume(throwing: error) }
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(throwing: error) }
        let closeWaiters = closeWaiters
        self.closeWaiters.removeAll(keepingCapacity: false)
        closeWaiters.forEach { $0.resume(throwing: error) }
    }

    private func completeClose(_ result: Result<Void, Error>) {
        closeState = .closed(result)
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(with: result) }
    }
}

private enum LanguageServerLogSafety {
    static func sanitize(_ source: String) -> String {
        var clean = String()
        clean.reserveCapacity(min(source.count, LSPProtocolLimits.maximumLogCharacters))
        for scalar in source.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t" ||
                (value >= 0x20 && value != 0x7f && !(0x80...0x9f).contains(value)) {
                clean.unicodeScalars.append(scalar)
            }
        }
        return LSPLogSanitizer.boundedLog(clean)
    }

    static func detail(_ error: Error, fallback: String) -> String {
        let source = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        let clean = sanitize(source.isEmpty ? fallback : source)
        return LSPLogSanitizer.prefixUTF16(
            clean, maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
        )
    }
}

// MARK: - One root + config client

public actor LanguageServerClient {
    public static let defaultInitializeTimeout: TimeInterval =
        TimeInterval(LSPProtocolLimits.initializeTimeoutMilliseconds) / 1_000
    public static let defaultRequestTimeout: TimeInterval = 15
    public static let defaultGracefulStopTimeout: TimeInterval = 0.5

    private struct DocumentSnapshot: Equatable, Sendable {
        var languageID: String
        var text: String
        var version: Int
    }

    private struct PendingRequest {
        let method: String
        let generation: UInt64
        let continuation: CheckedContinuation<LSPJSONValue, Error>
        var timeoutTask: Task<Void, Never>?
        var writeStarted: Bool
        var wasSent: Bool
    }

    public nonisolated let key: LanguageServerInstanceKey
    public nonisolated let root: URL
    public nonisolated let config: LanguageServerConfig

    private let command: ToolCommand
    private let runner: any LanguageServerProcessRunning
    private let eventHandler: LanguageServerEventHandler
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let gracefulStopTimeout: TimeInterval

    private var state: LanguageServerClientState = .stopped
    private var generation: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var capabilities: [String] = []
    private var documents: [String: DocumentSnapshot] = [:]
    private var requestIDs = LSPRequestIDGenerator()
    private var pending: [LSPRequestID: PendingRequest] = [:]
    private var cancelledWrites: [LSPRequestID: UInt64] = [:]
    private var activeDocumentOperations: Set<String> = []
    private var documentOperationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private var session: (any LanguageServerProcessSessioning)?
    private var writer: LanguageServerFrameWriter?
    private var reader = LSPMessageReader()
    private var relay: LanguageServerOutputRelay?
    private var outputTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private struct StartOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct StopOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var startOperation: StartOperation?
    private var stopOperation: StopOperation?

    public init(
        root: URL,
        config: LanguageServerConfig,
        command: ToolCommand,
        runner: any LanguageServerProcessRunning = ToolProcessLanguageServerRunner(),
        initializeTimeout: TimeInterval = LanguageServerClient.defaultInitializeTimeout,
        requestTimeout: TimeInterval = LanguageServerClient.defaultRequestTimeout,
        gracefulStopTimeout: TimeInterval = LanguageServerClient.defaultGracefulStopTimeout,
        eventHandler: @escaping LanguageServerEventHandler = { _ in }
    ) {
        precondition(initializeTimeout > 0 && initializeTimeout.isFinite)
        precondition(requestTimeout > 0 && requestTimeout.isFinite)
        precondition(gracefulStopTimeout > 0 && gracefulStopTimeout.isFinite)
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = normalizedRoot
        key = LanguageServerInstanceKey(root: normalizedRoot, config: config)
        self.config = config
        self.command = command
        self.runner = runner
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.gracefulStopTimeout = gracefulStopTimeout
        self.eventHandler = eventHandler
    }

    public func currentStatus() -> LanguageServerStatus { makeStatus(advanceSequence: false) }

    public func start() async throws {
        while true {
            if state == .running { return }
            if let operation = stopOperation {
                await operation.task.value
                clearStopOperation(operation.id)
                continue
            }
            if let operation = startOperation {
                do {
                    try await operation.task.value
                } catch {
                    clearStartOperation(operation.id)
                    if state == .stopped { continue }
                    throw error
                }
                clearStartOperation(operation.id)
                guard state == .running else {
                    continue
                }
                return
            }
            break
        }
        generation = nextGeneration(generation)
        let requestedGeneration = generation
        transition(to: .starting)
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { throw LanguageServerClientError.stopped }
            try await self.startGeneration(requestedGeneration)
        }
        startOperation = StartOperation(id: operationID, task: task)
        do {
            try await task.value
            clearStartOperation(operationID)
            guard state == .running else { throw LanguageServerClientError.stopped }
        } catch {
            clearStartOperation(operationID)
            if generation == requestedGeneration, state == .starting {
                await failGeneration(requestedGeneration, error: error)
            }
            throw error
        }
    }

    public func stop() async {
        if let operation = stopOperation {
            await operation.task.value
            return
        }
        if state == .stopped, session == nil, startOperation == nil { return }
        let stoppingGeneration = generation
        transition(to: .stopping)
        startOperation?.task.cancel()
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performGracefulStop(stoppingGeneration)
        }
        stopOperation = StopOperation(id: operationID, task: task)
        await task.value
        clearStopOperation(operationID)
    }

    public func restart() async throws {
        if stopOperation != nil { await stop() }
        if state == .running { transition(to: .restarting) }
        await stop()
        try await start()
    }

    /// Immediately cancel this process generation and every pending request.
    /// Document snapshots are retained so an explicit `restart()` can reopen
    /// them with their last synchronized versions.
    public func cancel() async {
        if let operation = stopOperation {
            await operation.task.value
            return
        }
        if state == .stopped, session == nil, startOperation == nil { return }
        let cancelledGeneration = generation
        transition(to: .stopping)
        startOperation?.task.cancel()
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performImmediateStop(generation: cancelledGeneration)
        }
        stopOperation = StopOperation(id: operationID, task: task)
        await task.value
        clearStopOperation(operationID)
    }

    private func performImmediateStop(generation cancelledGeneration: UInt64) async {
        guard generation == cancelledGeneration else { return }
        generation = nextGeneration(generation)
        let teardownGeneration = generation
        failAllPending(with: LanguageServerClientError.stopped)
        let oldSession = session
        relay?.finish()
        outputTask?.cancel()
        terminationTask?.cancel()
        session = nil
        writer = nil
        relay = nil
        outputTask = nil
        terminationTask = nil
        reader = LSPMessageReader()
        oldSession?.cancel()
        if let oldSession {
            _ = await waitForExit(oldSession, timeout: gracefulStopTimeout)
        }
        if generation == teardownGeneration, session == nil { transition(to: .stopped) }
    }

    public func synchronizeDocument(
        fileURL: URL,
        languageID: String,
        text: String,
        version: Int
    ) async throws {
        let uri = try documentURI(for: fileURL)
        await acquireDocumentOperation(uri)
        defer { releaseDocumentOperation(uri) }
        try await synchronizeDocumentLocked(
            uri: uri, languageID: languageID, text: text, version: version
        )
    }

    private func synchronizeDocumentLocked(
        uri: String, languageID: String, text: String, version: Int
    ) async throws {
        guard state == .running else { throw LanguageServerClientError.notRunning }
        if let previous = documents[uri] {
            if previous.version == version, previous.text == text, previous.languageID == languageID {
                return
            }
            guard version > previous.version else {
                throw LanguageServerClientError.staleDocumentVersion(
                    current: previous.version, received: version
                )
            }
            let replacement = DocumentSnapshot(
                languageID: languageID, text: text, version: version
            )
            documents[uri] = replacement
            do {
                if previous.languageID == languageID {
                    try await sendNotification(
                        method: "textDocument/didChange",
                        params: DidChangeParams(
                            textDocument: VersionedTextDocumentIdentifier(
                                uri: uri, version: version
                            ),
                            contentChanges: [FullContentChange(text: text)]
                        ),
                        generation: generation
                    )
                } else {
                    try await sendNotifications([
                        try notificationValue(
                            method: "textDocument/didClose",
                            params: DidCloseParams(
                                textDocument: LSPTextDocumentIdentifier(uri: uri)
                            )
                        ),
                        try notificationValue(
                            method: "textDocument/didOpen",
                            params: DidOpenParams(textDocument: TextDocumentItem(
                                uri: uri, languageId: languageID, version: version, text: text
                            ))
                        )
                    ], generation: generation)
                }
            } catch {
                if documents[uri] == replacement { documents[uri] = previous }
                throw error
            }
        } else {
            let opened = DocumentSnapshot(
                languageID: languageID, text: text, version: version
            )
            documents[uri] = opened
            do {
                try await sendNotification(
                    method: "textDocument/didOpen",
                    params: DidOpenParams(textDocument: TextDocumentItem(
                        uri: uri, languageId: languageID, version: version, text: text
                    )),
                    generation: generation
                )
            } catch {
                if documents[uri] == opened { documents[uri] = nil }
                throw error
            }
        }
    }

    @discardableResult
    public func synchronizeDocument(
        fileURL: URL,
        languageID: String,
        text: String
    ) async throws -> Int {
        let uri = try documentURI(for: fileURL)
        await acquireDocumentOperation(uri)
        defer { releaseDocumentOperation(uri) }
        let nextVersion = try nextDocumentVersion(after: documents[uri]?.version)
        try await synchronizeDocumentLocked(
            uri: uri, languageID: languageID, text: text, version: nextVersion
        )
        return nextVersion
    }

    public func closeDocument(fileURL: URL) async throws {
        let uri = try documentURI(for: fileURL)
        await acquireDocumentOperation(uri)
        defer { releaseDocumentOperation(uri) }
        guard let previous = documents[uri] else { return }
        documents[uri] = nil
        if state == .running {
            do {
                try await sendNotification(
                    method: "textDocument/didClose",
                    params: DidCloseParams(textDocument: LSPTextDocumentIdentifier(uri: uri)),
                    generation: generation
                )
            } catch {
                if documents[uri] == nil { documents[uri] = previous }
                throw error
            }
        }
    }

    public func perform(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerInteractiveResult {
        try validate(request: request)
        _ = try await synchronizeDocument(
            fileURL: URL(fileURLWithPath: request.filePath),
            languageID: request.languageId,
            text: request.content
        )
        let uri = try documentURI(for: URL(fileURLWithPath: request.filePath))
        let position = LSPPosition(
            line: max(0, request.line), character: max(0, request.character)
        )
        switch request.method {
        case .completion:
            let result = try await requestValue(
                method: request.method.protocolMethod,
                params: LSPTextDocumentPositionParams(uri: uri, position: position)
            )
            guard result != .null else {
                return LanguageServerInteractiveResult(completions: [])
            }
            let response: LSPCompletionResponse = try decode(
                result, method: request.method.protocolMethod
            )
            return LanguageServerInteractiveResult(
                completions: response.items.map { boundedCompletion($0.languageCompletionItem) }
            )

        case .hover:
            let result = try await requestValue(
                method: request.method.protocolMethod,
                params: LSPTextDocumentPositionParams(uri: uri, position: position)
            )
            guard result != .null else { return LanguageServerInteractiveResult() }
            let hover: LSPHover = try decode(result, method: request.method.protocolMethod)
            return LanguageServerInteractiveResult(hover: LanguageHover(text:
                LSPLogSanitizer.prefixUTF16(
                    hover.languageHover.text,
                    maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
                )
            ))

        case .definition, .references:
            let params: LSPJSONValue
            if request.method == .references {
                params = try jsonValue(LSPReferenceParams(uri: uri, position: position))
            } else {
                params = try jsonValue(LSPTextDocumentPositionParams(uri: uri, position: position))
            }
            let result = try await requestValue(
                method: request.method.protocolMethod, paramsValue: params
            )
            return LanguageServerInteractiveResult(
                locations: try decodeLocations(result, method: request.method.protocolMethod)
            )

        case .rename:
            let newName = request.newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !newName.isEmpty else {
                throw LanguageServerClientError.invalidResponse("rename name")
            }
            let result = try await requestValue(
                method: request.method.protocolMethod,
                params: LSPRenameParams(uri: uri, position: position, newName: newName)
            )
            guard result != .null else {
                return LanguageServerInteractiveResult(renameEdits: [])
            }
            return LanguageServerInteractiveResult(
                renameEdits: try decodeRenameEdits(
                    result, method: request.method.protocolMethod
                )
            )
        }
    }

    /// Synchronizes the current buffer before asking the server for whole-
    /// document formatting edits. A null result is the protocol's "no edits"
    /// response; malformed or over-budget edits fail as one atomic response.
    public func format(_ request: LanguageServerRequest) async throws -> LanguageServerResult {
        try validate(request: request)
        let fileURL = URL(fileURLWithPath: request.filePath)
        let uri = try documentURI(for: fileURL)
        // Keep synchronization and formatting in the same document operation
        // so the server cannot format a newer concurrently supplied snapshot.
        await acquireDocumentOperation(uri)
        defer { releaseDocumentOperation(uri) }
        let version = try nextDocumentVersion(after: documents[uri]?.version)
        try await synchronizeDocumentLocked(
            uri: uri,
            languageID: request.languageId,
            text: request.content,
            version: version
        )
        let method = "textDocument/formatting"
        let result = try await requestValue(
            method: method,
            params: LSPDocumentFormattingParams(uri: uri)
        )
        guard result != .null else {
            return LanguageServerResult(edits: [], diagnostics: [])
        }
        return LanguageServerResult(
            edits: try decodeFormattingEdits(result, method: method),
            diagnostics: []
        )
    }

    public func renamePreview(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerRenamePreview {
        guard request.method == .rename else {
            throw LanguageServerClientError.invalidResponse("rename request")
        }
        let result = try await perform(request)
        let name = request.newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanguageServerRenamePreview(
            key: key,
            fileURL: URL(fileURLWithPath: request.filePath),
            position: LSPPosition(line: max(0, request.line), character: max(0, request.character)),
            newName: name,
            edits: result.renameEdits ?? []
        )
    }

    // MARK: Lifecycle implementation

    private func startGeneration(_ requestedGeneration: UInt64) async throws {
        guard generation == requestedGeneration, state == .starting else {
            throw LanguageServerClientError.stopped
        }
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw LanguageServerClientError.invalidRoot
        }

        let relay = LanguageServerOutputRelay { [weak self] in
            guard let client = self else { return }
            Task { await client.outputOverflowed(generation: requestedGeneration) }
        }
        let launched = try await runner.start(command) { stream, data in
            relay.receive(stream: stream, data: data)
        }
        guard generation == requestedGeneration, state == .starting else {
            launched.cancel()
            _ = await waitForExit(launched, timeout: gracefulStopTimeout)
            throw LanguageServerClientError.stopped
        }

        session = launched
        writer = LanguageServerFrameWriter(session: launched)
        reader = LSPMessageReader()
        self.relay = relay
        let outputTask = Task { [weak self] in
            for await packet in relay.stream {
                guard !Task.isCancelled else { break }
                await self?.receive(packet, generation: requestedGeneration)
                relay.didConsume(packet.data.count)
            }
        }
        self.outputTask = outputTask
        terminationTask = Task { [weak self] in
            let result: Result<ToolProcessResult, Error>
            do { result = .success(try await launched.waitForExit()) }
            catch { result = .failure(error) }
            relay.finish()
            await outputTask.value
            await self?.processTerminated(result, generation: requestedGeneration)
        }

        let initialize = try await requestValue(
            method: "initialize",
            params: LSPInitializeParams(
                processID: Int(ProcessInfo.processInfo.processIdentifier),
                rootURI: root.absoluteString,
                capabilities: LSPClientCapabilities()
            ),
            timeout: initializeTimeout,
            requiredGeneration: requestedGeneration
        )
        let result: LSPInitializeResult = try decode(initialize, method: "initialize")
        guard generation == requestedGeneration, state == .starting else {
            throw LanguageServerClientError.stopped
        }
        capabilities = result.capabilities.summarizedNames()
        try await sendNotification(
            method: "initialized", params: LSPEmptyObject(), generation: requestedGeneration
        )
        try await reopenDocuments(generation: requestedGeneration)
        transition(to: .running)
    }

    private func performGracefulStop(_ stoppingGeneration: UInt64) async {
        guard generation == stoppingGeneration else { return }
        if session != nil, writer != nil {
            _ = try? await requestValue(
                method: "shutdown",
                paramsValue: .null,
                timeout: gracefulStopTimeout,
                requiredGeneration: stoppingGeneration
            )
            failAllPending(with: LanguageServerClientError.stopped)
            try? await sendNotificationValue(
                method: "exit", params: .null, generation: stoppingGeneration
            )
            try? await writer?.close()
        } else {
            failAllPending(with: LanguageServerClientError.stopped)
        }
        if let session {
            let exited = await waitForExit(session, timeout: gracefulStopTimeout)
            if !exited {
                session.cancel()
                _ = await waitForExit(session, timeout: gracefulStopTimeout)
            }
        }
        finishGeneration(stoppingGeneration, state: .stopped, message: nil)
    }

    private func failGeneration(_ failedGeneration: UInt64, error: Error) async {
        guard generation == failedGeneration else { return }
        let detail = LanguageServerLogSafety.detail(
            error, fallback: "Language server failed."
        )
        emitLog(stream: .server, level: .error, text: detail, generation: failedGeneration)
        let failedSession = session
        failAllPending(with: error)
        generation = nextGeneration(generation)
        let teardownGeneration = generation
        relay?.finish()
        outputTask?.cancel()
        terminationTask?.cancel()
        relay = nil
        outputTask = nil
        terminationTask = nil
        writer = nil
        session = nil
        reader = LSPMessageReader()
        capabilities = []
        state = .failed
        emit(.status(makeStatus(message: detail)))
        failedSession?.cancel()
        if let failedSession {
            _ = await waitForExit(failedSession, timeout: gracefulStopTimeout)
        }
        guard generation == teardownGeneration else { return }
    }

    private func finishGeneration(
        _ finishedGeneration: UInt64,
        state finalState: LanguageServerClientState,
        message: String?
    ) {
        guard generation == finishedGeneration else { return }
        failAllPending(with: LanguageServerClientError.stopped)
        generation = nextGeneration(generation)
        relay?.finish()
        outputTask?.cancel()
        terminationTask?.cancel()
        relay = nil
        outputTask = nil
        terminationTask = nil
        writer = nil
        session = nil
        reader = LSPMessageReader()
        capabilities = []
        self.state = finalState
        emit(.status(makeStatus(message: message)))
    }

    private func processTerminated(
        _ result: Result<ToolProcessResult, Error>,
        generation terminatedGeneration: UInt64
    ) async {
        guard generation == terminatedGeneration else { return }
        if state == .stopping {
            failAllPending(with: LanguageServerClientError.stopped)
            return
        }
        let detail: String
        switch result {
        case let .success(result):
            detail = "exit code \(result.exitCode)"
        case let .failure(error):
            detail = LanguageServerLogSafety.detail(error, fallback: "unknown process error")
        }
        await failGeneration(
            terminatedGeneration, error: LanguageServerClientError.processTerminated(detail)
        )
    }

    private func outputOverflowed(generation overflowGeneration: UInt64) async {
        guard generation == overflowGeneration else { return }
        await failGeneration(
            overflowGeneration,
            error: LanguageServerClientError.processTerminated(
                "the bounded output-delivery queue overflowed"
            )
        )
    }

    // MARK: JSON-RPC transport

    private func requestValue<Parameters: Encodable & Sendable>(
        method: String,
        params: Parameters,
        timeout: TimeInterval? = nil,
        requiredGeneration: UInt64? = nil
    ) async throws -> LSPJSONValue {
        try await requestValue(
            method: method,
            paramsValue: try jsonValue(params),
            timeout: timeout,
            requiredGeneration: requiredGeneration
        )
    }

    private func requestValue(
        method: String,
        paramsValue: LSPJSONValue,
        timeout: TimeInterval? = nil,
        requiredGeneration: UInt64? = nil
    ) async throws -> LSPJSONValue {
        let requestGeneration = requiredGeneration ?? generation
        guard generation == requestGeneration, writer != nil else {
            throw LanguageServerClientError.notRunning
        }
        let id = try requestIDs.next()
        let frame = try LSPMessageFraming.encode([
            "jsonrpc": .string("2.0"),
            "id": jsonValue(id),
            "method": .string(method),
            "params": paramsValue
        ])
        let duration = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(
                    method: method, generation: requestGeneration,
                    continuation: continuation, timeoutTask: nil,
                    writeStarted: false, wasSent: false
                )
                if Task.isCancelled {
                    settlePending(
                        id: id,
                        result: .failure(LanguageServerClientError.requestCancelled(method))
                    )
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(duration)) }
                    catch { return }
                    await self?.timeoutPending(id: id, generation: requestGeneration)
                }
                pending[id]?.timeoutTask = timer
                Task { [weak self] in
                    await self?.writePending(
                        frame, id: id, method: method, generation: requestGeneration
                    )
                }
            }
        } onCancel: { [weak self] in
            guard let client = self else { return }
            Task {
                await client.cancelPending(
                    id: id, method: method, generation: requestGeneration
                )
            }
        }
    }

    private func writePending(
        _ frame: Data,
        id: LSPRequestID,
        method: String,
        generation writeGeneration: UInt64
    ) async {
        guard generation == writeGeneration,
              pending[id]?.generation == writeGeneration,
              let writer else {
            settlePending(
                id: id, result: .failure(LanguageServerClientError.stopped)
            )
            return
        }
        pending[id]?.writeStarted = true
        do {
            try await writer.write(frame)
            if pending[id]?.generation == writeGeneration {
                pending[id]?.wasSent = true
            } else if cancelledWrites.removeValue(forKey: id) == writeGeneration {
                sendCancellationNotification(id: id, generation: writeGeneration)
            }
        } catch {
            settlePending(id: id, result: .failure(error))
            await failGeneration(writeGeneration, error: error)
        }
    }

    private func timeoutPending(id: LSPRequestID, generation timeoutGeneration: UInt64) {
        guard generation == timeoutGeneration, let request = pending[id] else { return }
        let cancelImmediately = request.wasSent
        if request.writeStarted && !request.wasSent { cancelledWrites[id] = timeoutGeneration }
        settlePending(
            id: id, result: .failure(LanguageServerClientError.requestTimedOut(request.method))
        )
        if cancelImmediately {
            sendCancellationNotification(id: id, generation: timeoutGeneration)
        }
    }

    private func cancelPending(
        id: LSPRequestID, method: String, generation cancelGeneration: UInt64
    ) {
        guard generation == cancelGeneration, let request = pending[id] else { return }
        let cancelImmediately = request.wasSent
        if request.writeStarted && !request.wasSent { cancelledWrites[id] = cancelGeneration }
        settlePending(
            id: id, result: .failure(LanguageServerClientError.requestCancelled(method))
        )
        if cancelImmediately {
            sendCancellationNotification(id: id, generation: cancelGeneration)
        }
    }

    private func sendCancellationNotification(id: LSPRequestID, generation: UInt64) {
        Task { [weak self] in
            try? await self?.sendNotificationValue(
                method: "$/cancelRequest",
                params: .object(["id": Self.jsonValue(id)]),
                generation: generation
            )
        }
    }

    private func settlePending(
        id: LSPRequestID, result: Result<LSPJSONValue, Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let requests = pending
        pending.removeAll(keepingCapacity: true)
        cancelledWrites.removeAll(keepingCapacity: true)
        for request in requests.values {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func sendNotification<Parameters: Encodable & Sendable>(
        method: String, params: Parameters, generation: UInt64
    ) async throws {
        try await sendNotificationValue(
            method: method, params: try jsonValue(params), generation: generation
        )
    }

    private func sendNotificationValue(
        method: String, params: LSPJSONValue, generation notificationGeneration: UInt64
    ) async throws {
        guard generation == notificationGeneration, let writer else {
            throw LanguageServerClientError.notRunning
        }
        let frame = try LSPMessageFraming.encode([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        try await writer.write(frame)
        guard generation == notificationGeneration else {
            throw LanguageServerClientError.stopped
        }
    }

    private func notificationValue<Parameters: Encodable>(
        method: String, params: Parameters
    ) throws -> LSPMessage {
        [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": try jsonValue(params)
        ]
    }

    private func sendNotifications(
        _ messages: [LSPMessage], generation notificationGeneration: UInt64
    ) async throws {
        guard generation == notificationGeneration, let writer else {
            throw LanguageServerClientError.notRunning
        }
        var batch = Data()
        for message in messages { batch.append(try LSPMessageFraming.encode(message)) }
        try await writer.write(batch)
        guard generation == notificationGeneration else {
            throw LanguageServerClientError.stopped
        }
    }

    private func receive(_ packet: LanguageServerOutputPacket, generation packetGeneration: UInt64) {
        guard generation == packetGeneration else { return }
        if packet.stream == .standardError {
            let text = String(decoding: packet.data, as: UTF8.self)
            emitLog(stream: .standardError, level: .error, text: text, generation: packetGeneration)
            return
        }
        let output = reader.append(packet.data)
        for error in output.errors {
            emitLog(
                stream: .server, level: error.fatal ? .error : .warning,
                text: "LSP protocol error: \(error.message)",
                generation: packetGeneration
            )
            if error.fatal {
                Task { [weak self] in
                    await self?.failGeneration(packetGeneration, error: error)
                }
            }
        }
        for message in output.messages { handle(message, generation: packetGeneration) }
    }

    private func handle(_ message: LSPMessage, generation messageGeneration: UInt64) {
        guard generation == messageGeneration else { return }
        if message["method"] == nil, message["id"] != nil {
            do {
                let response = try message.decode(LSPResponse.self)
                guard let request = pending[response.id], request.generation == messageGeneration else {
                    return
                }
                if let error = response.error {
                    let detail = LSPLogSanitizer.prefixUTF16(
                        LanguageServerLogSafety.sanitize(error.message),
                        maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
                    )
                    settlePending(
                        id: response.id,
                        result: .failure(LanguageServerClientError.responseError(
                            code: error.code, message: detail
                        ))
                    )
                } else {
                    settlePending(id: response.id, result: .success(response.result ?? .null))
                }
            } catch {
                emitLog(
                    stream: .server, level: .warning,
                    text: "Ignored an invalid JSON-RPC response.",
                    generation: messageGeneration
                )
            }
            return
        }

        guard case let .string(method)? = message["method"] else { return }
        if method == "textDocument/publishDiagnostics" {
            publishDiagnostics(message, generation: messageGeneration)
        } else if method == "window/logMessage" || method == "window/showMessage" {
            publishWindowLog(message, generation: messageGeneration)
        } else if let idValue = message["id"], let id = requestID(from: idValue) {
            respondMethodNotFound(id: id, generation: messageGeneration)
        }
    }

    private func publishDiagnostics(_ message: LSPMessage, generation: UInt64) {
        guard message["jsonrpc"] == .string("2.0"),
              let notification = try? message.decode(LSPPublishDiagnosticsNotification.self),
              notification.method == "textDocument/publishDiagnostics",
              let url = URL(string: notification.params.uri),
              let normalized = try? normalizedDocumentURL(url),
              contains(root: root, candidate: normalized) else { return }
        let uri = normalized.absoluteString
        if let version = notification.params.version,
           let document = documents[uri], version != document.version { return }

        var diagnostics: [LanguageServerDiagnostic] = []
        diagnostics.reserveCapacity(min(
            notification.params.diagnostics.count, LSPProtocolLimits.maximumDiagnostics
        ))
        var remainingBytes = LSPProtocolLimits.maximumDiagnosticMessageBytes
        for item in notification.params.diagnostics.prefix(LSPProtocolLimits.maximumDiagnostics) {
            guard remainingBytes > 0 else { break }
            let converted = item.languageServerDiagnostic
            let message = LSPLogSanitizer.prefixUTF8(
                LanguageServerLogSafety.sanitize(converted.message),
                maximumBytes: remainingBytes
            )
            guard !message.isEmpty else { break }
            remainingBytes -= message.utf8.count
            diagnostics.append(LanguageServerDiagnostic(
                line: converted.line, column: converted.column,
                endLine: converted.endLine, endColumn: converted.endColumn,
                severity: converted.severity, message: message
            ))
        }
        emit(.diagnostics(LanguageServerDiagnosticsUpdate(
            key: key,
            event: LanguageServerDiagnosticEvent(
                filePath: normalized.path, diagnostics: diagnostics
            ),
            documentVersion: notification.params.version,
            generation: generation, sequence: nextEventSequence()
        )))
    }

    private func publishWindowLog(_ message: LSPMessage, generation: UInt64) {
        guard case let .object(params)? = message["params"],
              case let .string(text)? = params["message"] else { return }
        let level: LanguageServerLogLevel
        if case .integer(1)? = params["type"] { level = .error }
        else if case .integer(2)? = params["type"] { level = .warning }
        else { level = .info }
        emitLog(stream: .server, level: level, text: text, generation: generation)
    }

    private func respondMethodNotFound(id: LSPRequestID, generation: UInt64) {
        Task { [weak self] in
            let message: LSPMessage = [
                "jsonrpc": .string("2.0"),
                "id": Self.jsonValue(id),
                "error": .object([
                    "code": .integer(-32_601),
                    "message": .string("Method not supported by this client.")
                ])
            ]
            await self?.sendRawMessageIfCurrent(message, generation: generation)
        }
    }

    private func sendRawMessageIfCurrent(
        _ message: LSPMessage, generation messageGeneration: UInt64
    ) async {
        guard generation == messageGeneration, let writer,
              let frame = try? LSPMessageFraming.encode(message) else { return }
        try? await writer.write(frame)
    }

    // MARK: Documents and decoding

    private func reopenDocuments(generation reopenGeneration: UInt64) async throws {
        for uri in documents.keys.sorted() {
            guard let document = documents[uri] else { continue }
            try await sendNotification(
                method: "textDocument/didOpen",
                params: DidOpenParams(textDocument: TextDocumentItem(
                    uri: uri, languageId: document.languageID,
                    version: document.version, text: document.text
                )),
                generation: reopenGeneration
            )
        }
    }

    private func validate(request: LanguageServerInteractiveRequest) throws {
        let requestKey = LanguageServerInstanceKey(
            root: URL(fileURLWithPath: request.root), config: request.config
        )
        guard requestKey == key else { throw LanguageServerClientError.invalidRoot }
    }

    private func validate(request: LanguageServerRequest) throws {
        let requestKey = LanguageServerInstanceKey(
            root: URL(fileURLWithPath: request.root), config: request.config
        )
        guard requestKey == key else { throw LanguageServerClientError.invalidRoot }
    }

    private func clearStartOperation(_ id: UUID) {
        if startOperation?.id == id { startOperation = nil }
    }

    private func clearStopOperation(_ id: UUID) {
        if stopOperation?.id == id { stopOperation = nil }
    }

    private func acquireDocumentOperation(_ uri: String) async {
        if activeDocumentOperations.insert(uri).inserted { return }
        await withCheckedContinuation { continuation in
            documentOperationWaiters[uri, default: []].append(continuation)
        }
    }

    private func releaseDocumentOperation(_ uri: String) {
        if var waiters = documentOperationWaiters[uri], !waiters.isEmpty {
            let next = waiters.removeFirst()
            documentOperationWaiters[uri] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            activeDocumentOperations.remove(uri)
        }
    }

    private func documentURI(for fileURL: URL) throws -> String {
        let normalized = try normalizedDocumentURL(fileURL)
        guard contains(root: root, candidate: normalized) else {
            throw LanguageServerClientError.fileOutsideRoot(normalized.path)
        }
        return normalized.absoluteString
    }

    private func normalizedDocumentURL(_ value: URL) throws -> URL {
        guard value.isFileURL,
              value.host == nil || value.host?.isEmpty == true,
              value.path.hasPrefix("/"),
              !value.path.utf8.contains(0) else {
            throw LanguageServerClientError.fileOutsideRoot(value.path)
        }
        return URL(
            fileURLWithPath: value.standardizedFileURL.resolvingSymlinksInPath().path,
            isDirectory: false
        )
    }

    private func decodeLocations(
        _ value: LSPJSONValue, method: String
    ) throws -> [LanguageLocation] {
        if value == .null { return [] }
        if let locations = try? decodeValue([LSPLocation].self, value) {
            return Array(locations.compactMap(\.languageLocation).filter(isContained).prefix(
                LSPProtocolLimits.maximumDiagnostics
            ))
        }
        if let links = try? decodeValue([LSPLocationLink].self, value) {
            return Array(links.compactMap(\.languageLocation).filter(isContained).prefix(
                LSPProtocolLimits.maximumDiagnostics
            ))
        }
        if let location = try? decodeValue(LSPLocation.self, value),
           let converted = location.languageLocation { return isContained(converted) ? [converted] : [] }
        if let link = try? decodeValue(LSPLocationLink.self, value),
           let converted = link.languageLocation { return isContained(converted) ? [converted] : [] }
        throw LanguageServerClientError.invalidResponse(method)
    }

    /// Decode both WorkspaceEdit representations used by modern servers.
    /// Resource operations are rejected explicitly because the caller receives
    /// only text-edit preview data and must never mistake a partial preview for
    /// the complete rename operation.
    private func decodeRenameEdits(
        _ value: LSPJSONValue, method: String
    ) throws -> [LanguageRenameEdit] {
        guard case let .object(workspaceEdit) = value else {
            throw LanguageServerClientError.invalidResponse(method)
        }
        var result: [LanguageRenameEdit] = []
        if let changesValue = workspaceEdit["changes"] {
            guard case let .object(changes) = changesValue else {
                throw LanguageServerClientError.invalidResponse(method)
            }
            for uri in changes.keys.sorted() {
                guard let editsValue = changes[uri], case let .array(edits) = editsValue else {
                    throw LanguageServerClientError.invalidResponse(method)
                }
                try appendRenameEdits(edits, uri: uri, to: &result, method: method)
            }
        }
        if let documentChangesValue = workspaceEdit["documentChanges"] {
            guard case let .array(documentChanges) = documentChangesValue else {
                throw LanguageServerClientError.invalidResponse(method)
            }
            for change in documentChanges {
                guard case let .object(object) = change, object["kind"] == nil,
                      case let .object(document)? = object["textDocument"],
                      case let .string(uri)? = document["uri"],
                      case let .array(edits)? = object["edits"] else {
                    throw LanguageServerClientError.invalidResponse(method)
                }
                try appendRenameEdits(edits, uri: uri, to: &result, method: method)
            }
        }
        return Array(result.prefix(LSPProtocolLimits.maximumDiagnostics))
    }

    private func decodeFormattingEdits(
        _ value: LSPJSONValue, method: String
    ) throws -> [LanguageServerTextEdit] {
        guard case let .array(values) = value,
              values.count <= LSPProtocolLimits.maximumFormattingEdits else {
            throw LanguageServerClientError.invalidResponse(method)
        }
        var result: [LanguageServerTextEdit] = []
        result.reserveCapacity(values.count)
        var totalTextUnits = 0
        for value in values {
            let edit: LSPTextEdit
            do { edit = try decodeValue(LSPTextEdit.self, value) }
            catch { throw LanguageServerClientError.invalidResponse(method) }
            let textUnits = edit.newText.utf16.count
            guard textUnits <= LSPProtocolLimits.maximumFormattingEditTextUTF16CodeUnits,
                  totalTextUnits <= LSPProtocolLimits.maximumFormattingTotalTextUTF16CodeUnits
                    - textUnits else {
                throw LanguageServerClientError.invalidResponse(method)
            }
            totalTextUnits += textUnits
            let start = edit.range.start
            let end = edit.range.end
            result.append(LanguageServerTextEdit(
                startLine: max(0, start.line),
                startCharacter: max(0, start.character),
                endLine: max(0, end.line),
                endCharacter: max(0, end.character),
                newText: edit.newText
            ))
        }
        return result
    }

    private func appendRenameEdits(
        _ values: [LSPJSONValue],
        uri: String,
        to result: inout [LanguageRenameEdit],
        method: String
    ) throws {
        guard let sourceURL = URL(string: uri),
              let fileURL = try? normalizedDocumentURL(sourceURL),
              contains(root: root, candidate: fileURL) else { return }
        for value in values {
            let edit: LSPTextEdit
            do { edit = try decodeValue(LSPTextEdit.self, value) }
            catch { throw LanguageServerClientError.invalidResponse(method) }
            let start = edit.range.start
            let end = edit.range.end
            result.append(LanguageRenameEdit(
                filePath: fileURL.path,
                startLine: max(0, start.line),
                startCharacter: max(0, start.character),
                endLine: max(0, end.line),
                endCharacter: max(0, end.character),
                newText: edit.newText
            ))
            if result.count >= LSPProtocolLimits.maximumDiagnostics { return }
        }
    }

    private func boundedCompletion(_ item: LanguageCompletionItem) -> LanguageCompletionItem {
        let limit = LSPProtocolLimits.maximumExternalDetailCharacters
        return LanguageCompletionItem(
            label: LSPLogSanitizer.prefixUTF16(item.label, maximumUnits: limit),
            detail: item.detail.map { LSPLogSanitizer.prefixUTF16($0, maximumUnits: limit) },
            documentation: item.documentation.map {
                LSPLogSanitizer.prefixUTF16($0, maximumUnits: limit)
            },
            insertText: item.insertText.map { LSPLogSanitizer.prefixUTF16($0, maximumUnits: limit) }
        )
    }

    private func isContained(_ location: LanguageLocation) -> Bool {
        contains(
            root: root,
            candidate: URL(fileURLWithPath: location.filePath).standardizedFileURL
                .resolvingSymlinksInPath()
        )
    }

    private func decode<Value: Decodable>(
        _ value: LSPJSONValue, method: String
    ) throws -> Value {
        do { return try decodeValue(Value.self, value) }
        catch { throw LanguageServerClientError.invalidResponse(method) }
    }

    private func decodeValue<Value: Decodable>(
        _ type: Value.Type, _ value: LSPJSONValue
    ) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func jsonValue<Value: Encodable>(_ value: Value) throws -> LSPJSONValue {
        try JSONDecoder().decode(
            LSPJSONValue.self, from: JSONEncoder().encode(value)
        )
    }

    private static func jsonValue(_ id: LSPRequestID) -> LSPJSONValue {
        switch id {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        }
    }

    private func jsonValue(_ id: LSPRequestID) -> LSPJSONValue { Self.jsonValue(id) }

    private func requestID(from value: LSPJSONValue) -> LSPRequestID? {
        switch value {
        case let .integer(id) where (-LSPRequestID.maximumSafeInteger...LSPRequestID.maximumSafeInteger).contains(id):
            .integer(id)
        case let .string(id): .string(id)
        default: nil
        }
    }

    private func emitLog(
        stream: LanguageServerLogStream,
        level: LanguageServerLogLevel,
        text: String,
        generation logGeneration: UInt64
    ) {
        guard generation == logGeneration else { return }
        let clean = LanguageServerLogSafety.sanitize(text)
        guard !clean.isEmpty else { return }
        emit(.log(LanguageServerLogEntry(
            key: key, root: root, stream: stream, level: level,
            text: clean, generation: logGeneration, sequence: nextEventSequence()
        )))
    }

    private func transition(to newState: LanguageServerClientState, message: String? = nil) {
        state = newState
        emit(.status(makeStatus(message: message)))
    }

    private func emit(_ event: LanguageServerEvent) {
        eventHandler(event)
    }

    private func makeStatus(
        message: String? = nil, advanceSequence: Bool = true
    ) -> LanguageServerStatus {
        let sequence = advanceSequence ? nextEventSequence() : eventSequence
        return LanguageServerStatus(
            key: key, root: root, config: config, state: state, generation: generation,
            sequence: sequence,
            capabilities: capabilities,
            message: message.map { LSPLogSanitizer.prefixUTF16(
                LanguageServerLogSafety.sanitize($0),
                maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
            ) }
        )
    }

    private func waitForExit(
        _ session: any LanguageServerProcessSessioning, timeout: TimeInterval
    ) async -> Bool {
        let gate = LanguageServerDeadlineGate()
        Task {
            _ = try? await session.waitForExit()
            gate.resolve(true)
        }
        Task {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
            gate.resolve(false)
        }
        return await gate.wait()
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let maximum = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(maximum, max(0, seconds)) * 1_000_000_000)
    }

    private func nextGeneration(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private func nextEventSequence() -> UInt64 {
        eventSequence = eventSequence == UInt64.max ? 1 : eventSequence + 1
        return eventSequence
    }

    private func nextDocumentVersion(after value: Int?) throws -> Int {
        guard let value else { return 1 }
        guard value < Int.max else {
            throw LanguageServerClientError.documentVersionExhausted
        }
        return value + 1
    }

    private func contains(root: URL, candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private struct TextDocumentItem: Codable, Sendable {
        let uri: String
        let languageId: String
        let version: Int
        let text: String
    }

    private struct DidOpenParams: Codable, Sendable { let textDocument: TextDocumentItem }

    private struct VersionedTextDocumentIdentifier: Codable, Sendable {
        let uri: String
        let version: Int
    }

    private struct FullContentChange: Codable, Sendable { let text: String }

    private struct DidChangeParams: Codable, Sendable {
        let textDocument: VersionedTextDocumentIdentifier
        let contentChanges: [FullContentChange]
    }

    private struct DidCloseParams: Codable, Sendable {
        let textDocument: LSPTextDocumentIdentifier
    }
}

// MARK: - Multi-instance manager

public typealias LanguageServerConfigurationBuilder = @Sendable (
    _ root: URL, _ config: LanguageServerConfig
) throws -> ToolExecutionConfiguration

public enum LanguageServerExecutableAuthorizationError:
    Error, Equatable, LocalizedError, Sendable
{
    case unavailable
    case invalidSelection(URL)
    case tooManySelections(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This language-server manager uses a custom execution policy and cannot add executable selections."
        case .invalidSelection:
            return "Choose an existing executable file for the language server."
        case let .tooManySelections(maximum):
            return "At most \(maximum) language-server executables may be authorised in one session."
        }
    }
}

/// Owns exactly one client for each normalized `(root, command, args)` tuple.
/// Stopped clients remain registered so their document snapshots can be
/// reopened on restart; they never share a process or pending-request map.
public actor LanguageServerManager {
    public static let defaultSessionLifetime: TimeInterval = 24 * 60 * 60
    public static let maximumRetainedProcessOutputBytes = 64 * 1_024 * 1_024
    public static let maximumExplicitExecutableSelections = 128

    private struct ManagedClient {
        let token: UUID
        let client: LanguageServerClient
        let configuration: ToolExecutionConfiguration
        let eventContinuation: AsyncStream<LanguageServerEvent>.Continuation
        let eventTask: Task<Void, Never>
    }

    private let runner: any LanguageServerProcessRunning
    private let customConfigurationBuilder: LanguageServerConfigurationBuilder?
    private let resolver: ToolExecutableResolver?
    private let inheritedEnvironment: [String: String]
    private let approvals: ToolApprovalStore
    private let approvalScope: ToolApprovalScope
    private let sessionLifetime: TimeInterval
    private var clients: [LanguageServerInstanceKey: ManagedClient] = [:]
    private var observers: [UUID: AsyncStream<LanguageServerEvent>.Continuation] = [:]
    private var statuses: [LanguageServerInstanceKey: LanguageServerStatus] = [:]
    private var latestEventOrder: [LanguageServerInstanceKey: (generation: UInt64, sequence: UInt64)] = [:]
    private var explicitlyAuthorizedExecutableURLs: Set<URL> = []

    public init(
        runner: any LanguageServerProcessRunning,
        approvals: ToolApprovalStore = ToolApprovalStore(),
        approvalScope: ToolApprovalScope = ToolApprovalScope(
            windowID: UUID(), sessionID: UUID()
        ),
        sessionLifetime: TimeInterval = LanguageServerManager.defaultSessionLifetime,
        configurationBuilder: @escaping LanguageServerConfigurationBuilder
    ) {
        precondition(sessionLifetime > LanguageServerClient.defaultInitializeTimeout)
        precondition(sessionLifetime.isFinite)
        self.runner = runner
        self.approvals = approvals
        self.approvalScope = approvalScope
        self.sessionLifetime = sessionLifetime
        customConfigurationBuilder = configurationBuilder
        resolver = nil
        inheritedEnvironment = [:]
    }

    public init(
        runner: any LanguageServerProcessRunning = ToolProcessLanguageServerRunner(),
        approvals: ToolApprovalStore = ToolApprovalStore(),
        approvalScope: ToolApprovalScope = ToolApprovalScope(
            windowID: UUID(), sessionID: UUID()
        ),
        resolver: ToolExecutableResolver = .system,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        sessionLifetime: TimeInterval = LanguageServerManager.defaultSessionLifetime
    ) {
        precondition(sessionLifetime > LanguageServerClient.defaultInitializeTimeout)
        precondition(sessionLifetime.isFinite)
        self.runner = runner
        self.approvals = approvals
        self.approvalScope = approvalScope
        self.sessionLifetime = sessionLifetime
        customConfigurationBuilder = nil
        self.resolver = resolver
        self.inheritedEnvironment = inheritedEnvironment
    }

    public func events() -> AsyncStream<LanguageServerEvent> {
        let id = UUID()
        let pair = AsyncStream<LanguageServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        observers[id] = pair.continuation
        for status in statuses.values.sorted(by: { $0.key.description < $1.key.description }) {
            pair.continuation.yield(.status(status))
        }
        pair.continuation.onTermination = { [weak self] _ in
            guard let manager = self else { return }
            Task { await manager.removeObserver(id) }
        }
        return pair.stream
    }

    /// Returns the exact normalized launch configuration whose identity is
    /// shown by the application approval UI and checked again before launch.
    public func approvalConfiguration(
        root: URL, config: LanguageServerConfig
    ) throws -> ToolExecutionConfiguration {
        try makeConfiguration(
            root: root.standardizedFileURL.resolvingSymlinksInPath(), config: config
        )
    }

    /// Adds an executable selected by trusted application UI to this in-memory
    /// manager. Project settings cannot call this capability, and a separate
    /// exact-configuration approval is still required before process launch.
    public func authorizeExecutable(_ url: URL) throws -> URL {
        guard customConfigurationBuilder == nil else {
            throw LanguageServerExecutableAuthorizationError.unavailable
        }
        guard url.isFileURL, (url.host == nil || url.host?.isEmpty == true),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw LanguageServerExecutableAuthorizationError.invalidSelection(url)
        }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalized.path, isDirectory: &isDirectory
        ), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: normalized.path) else {
            throw LanguageServerExecutableAuthorizationError.invalidSelection(url)
        }
        guard explicitlyAuthorizedExecutableURLs.contains(normalized)
                || explicitlyAuthorizedExecutableURLs.count
                    < Self.maximumExplicitExecutableSelections else {
            throw LanguageServerExecutableAuthorizationError.tooManySelections(
                maximum: Self.maximumExplicitExecutableSelections
            )
        }
        explicitlyAuthorizedExecutableURLs.insert(normalized)
        return normalized
    }

    @discardableResult
    public func revokeExecutable(_ url: URL) -> Bool {
        explicitlyAuthorizedExecutableURLs.remove(
            url.standardizedFileURL.resolvingSymlinksInPath()
        ) != nil
    }

    public func revokeAllExecutables() {
        explicitlyAuthorizedExecutableURLs.removeAll(keepingCapacity: false)
    }

    public func approve(_ configuration: ToolExecutionConfiguration) async {
        _ = await approvals.approve(configuration, in: approvalScope)
    }

    @discardableResult
    public func start(root: URL, config: LanguageServerConfig) async throws
        -> LanguageServerInstanceKey {
        let managed = try await approvedManagedClient(root: root, config: config)
        try await managed.client.start()
        return managed.client.key
    }

    @discardableResult
    public func synchronize(_ request: LanguageServerSyncRequest) async throws
        -> LanguageServerInstanceKey {
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        let managed = try await approvedManagedClient(root: root, config: request.config)
        try await managed.client.start()
        try await managed.client.synchronizeDocument(
            fileURL: URL(fileURLWithPath: request.filePath),
            languageID: request.languageId, text: request.content, version: request.version
        )
        return managed.client.key
    }

    public func closeDocument(
        root: URL, config: LanguageServerConfig, fileURL: URL
    ) async throws {
        let key = LanguageServerInstanceKey(root: root, config: config)
        guard let managed = clients[key] else { return }
        try await managed.client.closeDocument(fileURL: fileURL)
    }

    public func perform(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerInteractiveResult {
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        let managed = try await approvedManagedClient(root: root, config: request.config)
        try await managed.client.start()
        return try await managed.client.perform(request)
    }

    public func format(_ request: LanguageServerRequest) async throws -> LanguageServerResult {
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        let managed = try await approvedManagedClient(root: root, config: request.config)
        try await managed.client.start()
        return try await managed.client.format(request)
    }

    public func renamePreview(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerRenamePreview {
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        let managed = try await approvedManagedClient(root: root, config: request.config)
        try await managed.client.start()
        return try await managed.client.renamePreview(request)
    }

    public func stop(_ key: LanguageServerInstanceKey) async {
        await clients[key]?.client.stop()
    }

    public func restart(_ key: LanguageServerInstanceKey) async throws {
        guard let managed = clients[key] else { throw LanguageServerClientError.stopped }
        guard await approvals.isApproved(managed.configuration, in: approvalScope) else {
            throw LanguageServerClientError.approvalRequired(managed.configuration)
        }
        try await managed.client.restart()
    }

    public func cancel(_ key: LanguageServerInstanceKey) async {
        await clients[key]?.client.cancel()
    }

    public func stopAll(root: URL? = nil) async {
        let normalized = root?.standardizedFileURL.resolvingSymlinksInPath().path
        let selected = Array(
            clients.filter { normalized == nil || $0.key.rootPath == normalized }.values
        )
        for managed in selected { await managed.client.stop() }
    }

    public func currentStatuses() -> [LanguageServerStatus] {
        statuses.values.sorted { $0.key.description < $1.key.description }
    }

    private func managedClient(
        root: URL, config: LanguageServerConfig, configuration: ToolExecutionConfiguration
    ) throws -> ManagedClient {
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
        let key = LanguageServerInstanceKey(root: normalized, config: config)
        if let existing = clients[key] { return existing }
        let command = try configuration.makeCommand(limits: ToolProcessLimits(
            timeout: sessionLifetime,
            maximumStandardInputBytes: LSPProtocolLimits.maximumInputQueueBytes,
            maximumStandardOutputBytes: Self.maximumRetainedProcessOutputBytes,
            maximumStandardErrorBytes: LSPProtocolLimits.maximumLogBatchBytes * 16,
            gracefulTerminationTimeout: LanguageServerClient.defaultGracefulStopTimeout,
            processGroupPolicy: .isolated
        ))
        let token = UUID()
        let events = AsyncStream<LanguageServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        let client = LanguageServerClient(
            root: normalized, config: config, command: command, runner: runner
        ) { event in
            events.continuation.yield(event)
        }
        let eventTask = Task { [weak self] in
            for await event in events.stream {
                guard !Task.isCancelled, let self else { break }
                await self.receive(event, key: key, token: token)
            }
        }
        let managed = ManagedClient(
            token: token, client: client, configuration: configuration,
            eventContinuation: events.continuation,
            eventTask: eventTask
        )
        clients[key] = managed
        return managed
    }

    private func approvedManagedClient(
        root: URL, config: LanguageServerConfig
    ) async throws -> ManagedClient {
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
        let key = LanguageServerInstanceKey(root: normalized, config: config)
        if let existing = clients[key] {
            guard await approvals.isApproved(existing.configuration, in: approvalScope) else {
                throw LanguageServerClientError.approvalRequired(existing.configuration)
            }
            return existing
        }
        let configuration = try approvalConfiguration(root: normalized, config: config)
        guard await approvals.isApproved(configuration, in: approvalScope) else {
            throw LanguageServerClientError.approvalRequired(configuration)
        }
        // Approval lookup crosses actors. Another caller may have installed
        // this exact client while we were suspended, so recheck before create.
        if let existing = clients[key] { return existing }
        return try managedClient(root: normalized, config: config, configuration: configuration)
    }

    private func makeConfiguration(
        root: URL, config: LanguageServerConfig
    ) throws -> ToolExecutionConfiguration {
        if let customConfigurationBuilder {
            return try customConfigurationBuilder(root, config)
        }
        guard let resolver else {
            throw LanguageServerExecutableAuthorizationError.unavailable
        }
        return try ToolExecutionConfiguration(
            kind: .languageServer, root: root, command: config.command,
            arguments: config.args, inheritedEnvironment: inheritedEnvironment,
            resolver: try resolverForConfiguration(config, root: root, base: resolver)
        )
    }

    private func resolverForConfiguration(
        _ config: LanguageServerConfig, root: URL, base: ToolExecutableResolver
    ) throws -> ToolExecutableResolver {
        let source = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.contains("/") else { return base }
        let selectedURL = (source as NSString).isAbsolutePath
            ? URL(fileURLWithPath: source, isDirectory: false)
            : root.appendingPathComponent(source, isDirectory: false)
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard explicitlyAuthorizedExecutableURLs.contains(selected) else { return base }

        var allowed: [String: URL] = [:]
        for (index, url) in base.allowedExecutableURLs.sorted(
            by: { $0.path < $1.path }
        ).enumerated() {
            allowed["base-\(index)"] = url
        }
        for (index, url) in explicitlyAuthorizedExecutableURLs.sorted(
            by: { $0.path < $1.path }
        ).enumerated() {
            allowed["selected-\(index)"] = url
        }
        return try ToolExecutableResolver(
            allowedExecutables: allowed, shellExecutableURL: base.shellExecutableURL
        )
    }

    private func receive(
        _ event: LanguageServerEvent, key: LanguageServerInstanceKey, token: UUID
    ) {
        guard clients[key]?.token == token else { return }
        let order: (generation: UInt64, sequence: UInt64)
        switch event {
        case let .status(status): order = (status.generation, status.sequence)
        case let .diagnostics(update): order = (update.generation, update.sequence)
        case let .log(entry): order = (entry.generation, entry.sequence)
        }
        if let latest = latestEventOrder[key],
           order.generation < latest.generation ||
            (order.generation == latest.generation && order.sequence <= latest.sequence) {
            return
        }
        latestEventOrder[key] = order
        if case let .status(status) = event {
            statuses[key] = status
        }
        for continuation in observers.values { continuation.yield(event) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
