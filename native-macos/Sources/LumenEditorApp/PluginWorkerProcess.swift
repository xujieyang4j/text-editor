import Foundation
import LumenEditorCore

protocol PluginWorkerProcessSessioning: Sendable {
    func write(_ data: Data) async throws
    func closeStandardInput() async throws
    func cancel()
    func waitForExit() async throws -> ToolProcessResult
}

extension ToolProcessSession: PluginWorkerProcessSessioning {}

protocol PluginWorkerProcessRunning: Sendable {
    func start(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any PluginWorkerProcessSessioning
    func cancelAll() async
}

struct PluginWorkerProcessRunnerAdapter: PluginWorkerProcessRunning {
    private let runner: ToolProcessRunner

    init(runner: ToolProcessRunner = ToolProcessRunner(
        maximumQueuedStandardInputBytes: PluginWorkerProtocol.maximumMessageBytes,
        maximumPendingOutputDeliveryBytes: PluginWorkerProtocol.maximumResponseBytes,
        maximumPendingOutputDeliveryChunks:
            PluginWorkerProtocol.maximumWireMessagesPerRequest * 2
    )) {
        self.runner = runner
    }

    func start(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any PluginWorkerProcessSessioning {
        try await runner.start(command, onOutput: onOutput)
    }

    func cancelAll() async { await runner.cancelAll() }
}

/// One persistent helper connection. Output parsing is synchronized because
/// ToolProcessRunner deliberately delivers callbacks off the main actor.
final class PluginWorkerConnection: @unchecked Sendable {
    let id = UUID()
    private let session: any PluginWorkerProcessSessioning
    private let channel: PluginWorkerResponseChannel
    private let requestGate = PluginWorkerRequestGate()
    private var exitMonitor: Task<Void, Never>?
    private let lifecycleLock = NSLock()

    private init(
        session: any PluginWorkerProcessSessioning,
        channel: PluginWorkerResponseChannel
    ) {
        self.session = session
        self.channel = channel
    }

    private func observeExit(
        _ onExit: @escaping @Sendable (UUID, any Error) -> Void
    ) {
        let connectionID = id
        let monitor = Task.detached { [session, channel] in
            do {
                let result = try await session.waitForExit()
                let failure = PluginWorkerRuntimeError.workerExited(
                    result.exitCode, String(decoding: result.standardError, as: UTF8.self)
                )
                channel.finish(with: failure)
                onExit(connectionID, failure)
            } catch {
                channel.finish(with: error)
                onExit(connectionID, error)
            }
        }
        lifecycleLock.lock()
        exitMonitor = monitor
        lifecycleLock.unlock()
    }

    static func start(
        runner: any PluginWorkerProcessRunning,
        command: ToolCommand,
        onExit: @escaping @Sendable (UUID, any Error) -> Void = { _, _ in }
    ) async throws -> PluginWorkerConnection {
        let channel = PluginWorkerResponseChannel()
        let session = try await runner.start(command) { stream, data in
            guard stream == .standardOutput else { return }
            channel.receive(data)
        }
        let connection = PluginWorkerConnection(session: session, channel: channel)
        connection.observeExit(onExit)
        return connection
    }

    func request(
        _ request: PluginWorkerRequest,
        timeout: TimeInterval
    ) async throws -> [PluginWorkerResponse] {
        try await requestGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await performRequest(request, timeout: timeout)
            await requestGate.release()
            return result
        } catch {
            await requestGate.cancelAll()
            await requestGate.release()
            session.cancel()
            throw error
        }
    }

    /// A complete JSON line owns the connection until its terminal response.
    /// This prevents concurrent callers from interleaving bounded stdin chunks
    /// and also preserves the worker's single-threaded event ordering.
    private func performRequest(
        _ request: PluginWorkerRequest,
        timeout: TimeInterval
    ) async throws -> [PluginWorkerResponse] {
        precondition(timeout > 0 && timeout.isFinite)
        try channel.begin(requestID: request.requestID)
        do {
            let encoded = try PluginWorkerWireCodec.encode(request)
            var start = encoded.startIndex
            while start < encoded.endIndex {
                let end = encoded.index(
                    start,
                    offsetBy: min(
                        ToolExecutionLimits.maximumStdinWriteBytes,
                        encoded.distance(from: start, to: encoded.endIndex)
                    )
                )
                try await session.write(Data(encoded[start..<end]))
                start = end
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    channel.installWaiter(
                        requestID: request.requestID,
                        timeout: timeout,
                        continuation: continuation
                    )
                }
            } onCancel: {
                channel.cancel(requestID: request.requestID)
                session.cancel()
            }
        } catch {
            channel.cancel(requestID: request.requestID)
            session.cancel()
            throw error
        }
    }

    func close(gracefulExitTimeout: TimeInterval) async {
        precondition(gracefulExitTimeout > 0 && gracefulExitTimeout.isFinite)
        await requestGate.cancelAll()
        try? await session.closeStandardInput()
        lifecycleLock.lock()
        let monitor = exitMonitor
        lifecycleLock.unlock()
        if let monitor {
            let gate = PluginWorkerDeadlineGate()
            Task {
                _ = await monitor.value
                gate.resolve(true)
            }
            Task {
                try? await Task.sleep(
                    nanoseconds: Self.nanoseconds(gracefulExitTimeout)
                )
                gate.resolve(false)
            }
            if await !gate.wait() {
                session.cancel()
                _ = await monitor.value
            }
        }
        lifecycleLock.lock()
        exitMonitor?.cancel()
        exitMonitor = nil
        lifecycleLock.unlock()
    }

    func cancel() async {
        await requestGate.cancelAll()
        session.cancel()
        lifecycleLock.lock()
        exitMonitor?.cancel()
        exitMonitor = nil
        lifecycleLock.unlock()
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let maximum = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(maximum, max(0, seconds)) * 1_000_000_000)
    }
}

private actor PluginWorkerRequestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isOwned = false
    private var waiters: [Waiter] = []
    private var isCancelled = false

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !isOwned {
                    isOwned = true
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isOwned = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    func cancelAll() {
        isCancelled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private final class PluginWorkerDeadlineGate: @unchecked Sendable {
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

private final class PluginWorkerResponseChannel: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<[PluginWorkerResponse], any Error>
    private typealias Resumption = (
        Continuation, Result<[PluginWorkerResponse], any Error>
    )

    private struct Waiter {
        let continuation: Continuation
        let timeout: DispatchWorkItem
    }

    private let lock = NSLock()
    private var decoder = PluginWorkerLineDecoder()
    private var activeRequestIDs: Set<String> = []
    private var responses: [String: [PluginWorkerResponse]] = [:]
    private var responseBytes: [String: Int] = [:]
    private var completed: [String: Result<[PluginWorkerResponse], any Error>] = [:]
    private var waiters: [String: Waiter] = [:]
    private var terminalError: (any Error)?

    func begin(requestID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let terminalError { throw terminalError }
        guard !activeRequestIDs.contains(requestID), waiters[requestID] == nil,
              completed[requestID] == nil else {
            throw PluginWorkerRuntimeError.requestMismatch
        }
        activeRequestIDs.insert(requestID)
        responses[requestID] = []
        responseBytes[requestID] = 0
    }

    func receive(_ data: Data) {
        var resumptions: [Resumption] = []
        lock.lock()
        do {
            let lines = try decoder.append(data)
            for line in lines {
                try consume(line, resumptions: &resumptions)
            }
        } catch {
            resumptions.append(contentsOf: failLocked(with: error))
        }
        lock.unlock()
        resume(resumptions)
    }

    private func consume(_ line: Data, resumptions: inout [Resumption]) throws {
        let response = try PluginWorkerWireCodec.decodeResponse(line)
        guard let requestID = response.requestID,
              activeRequestIDs.contains(requestID) else {
            throw PluginWorkerRuntimeError.requestMismatch
        }
        let totalBytes = (responseBytes[requestID] ?? 0) + line.count + 1
        guard totalBytes <= PluginWorkerProtocol.maximumResponseBytes else {
            throw PluginWorkerProtocolError.responseTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumResponseBytes
            )
        }
        responseBytes[requestID] = totalBytes
        var values = responses[requestID] ?? []
        switch response.type {
        case .completed:
            values.append(response)
            activeRequestIDs.remove(requestID)
            responses[requestID] = nil
            responseBytes[requestID] = nil
            let result: Result<[PluginWorkerResponse], any Error> = .success(values)
            if let waiter = waiters.removeValue(forKey: requestID) {
                waiter.timeout.cancel()
                resumptions.append((waiter.continuation, result))
            } else {
                completed[requestID] = result
            }
        case .failed:
            activeRequestIDs.remove(requestID)
            responses[requestID] = nil
            responseBytes[requestID] = nil
            let result: Result<[PluginWorkerResponse], any Error> = .failure(
                PluginWorkerProtocolError.workerFailure(
                    response.text ?? "Plugin worker failed."
                )
            )
            if let waiter = waiters.removeValue(forKey: requestID) {
                waiter.timeout.cancel()
                resumptions.append((waiter.continuation, result))
            } else {
                completed[requestID] = result
            }
        case .registerCommand, .replaceDocument, .notify:
            guard values.count < PluginWorkerProtocol.maximumMessagesPerRequest else {
                throw PluginWorkerProtocolError.tooManyMessages(
                    maximum: PluginWorkerProtocol.maximumMessagesPerRequest
                )
            }
            values.append(response)
            responses[requestID] = values
        }
    }

    func installWaiter(
        requestID: String,
        timeout: TimeInterval,
        continuation: CheckedContinuation<[PluginWorkerResponse], any Error>
    ) {
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.timeOut(requestID: requestID, seconds: timeout)
        }
        lock.lock()
        if let result = completed.removeValue(forKey: requestID) {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if let terminalError {
            lock.unlock()
            continuation.resume(throwing: terminalError)
            return
        }
        guard activeRequestIDs.contains(requestID) else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters[requestID] = Waiter(continuation: continuation, timeout: timeoutWork)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: timeoutWork
        )
    }

    func cancel(requestID: String) {
        lock.lock()
        activeRequestIDs.remove(requestID)
        responses[requestID] = nil
        responseBytes[requestID] = nil
        completed[requestID] = nil
        let waiter = waiters.removeValue(forKey: requestID)
        waiter?.timeout.cancel()
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }

    func finish(with error: any Error) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let resumptions = failLocked(with: error)
        lock.unlock()
        resume(resumptions)
    }

    private func timeOut(requestID: String, seconds: TimeInterval) {
        lock.lock()
        activeRequestIDs.remove(requestID)
        responses[requestID] = nil
        responseBytes[requestID] = nil
        completed[requestID] = nil
        let waiter = waiters.removeValue(forKey: requestID)
        lock.unlock()
        waiter?.continuation.resume(
            throwing: ToolExecutionError.timedOut(seconds: seconds)
        )
    }

    private func failLocked(
        with error: any Error
    ) -> [Resumption] {
        terminalError = terminalError ?? error
        activeRequestIDs.removeAll()
        responses.removeAll()
        responseBytes.removeAll()
        completed.removeAll()
        let values = waiters.values.map { waiter in
            waiter.timeout.cancel()
            return (waiter.continuation, .failure(error))
        }
        waiters.removeAll()
        return values
    }

    private func resume(
        _ values: [Resumption]
    ) {
        for (continuation, result) in values { continuation.resume(with: result) }
    }
}
