@preconcurrency import Foundation
import Darwin
import LumenPTYSupport

public struct PseudoTerminalSize: Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: Int, rows: Int) throws {
        guard (2 ... 1_000).contains(columns), (2 ... 1_000).contains(rows) else {
            throw ToolProcessRunnerError.invalidCommand
        }
        self.columns = UInt16(columns)
        self.rows = UInt16(rows)
    }

    public static let `default` = try! PseudoTerminalSize(columns: 120, rows: 36)
}

public final class PseudoTerminalProcessSession: @unchecked Sendable {
    private let execution: PseudoTerminalProcessExecution

    fileprivate init(execution: PseudoTerminalProcessExecution) {
        self.execution = execution
    }

    public func write(_ data: Data) async throws { try await execution.write(data) }

    /// In canonical terminal mode an EOT character expresses end-of-input
    /// without closing the shared PTY master, which must remain open for output.
    public func closeStandardInput() async throws {
        try await execution.closeStandardInput()
    }

    /// Write the terminal's VINTR character. The kernel line discipline sends
    /// SIGINT to the PTY foreground process group (which may differ from the
    /// login shell's process group after job control starts a command).
    public func interrupt() async throws { try await execution.interrupt() }

    public func resize(to size: PseudoTerminalSize) async throws {
        try await execution.resize(to: size)
    }

    public func cancel() { execution.cancel() }

    public func waitForExit() async throws -> ToolProcessResult {
        try await execution.waitForExit()
    }
}

/// Dedicated PTY broker for Terminal. Build, Git, LSP, parser, and plugin
/// workers deliberately remain on `ToolProcessRunner`, where separate stdout
/// and stderr pipes and non-terminal stdin semantics are required.
public struct PseudoTerminalProcessRunner: Sendable {
    private let maximumQueuedInputBytes: Int
    private let maximumPendingDeliveryBytes: Int
    private let maximumPendingDeliveryChunks: Int

    public init(
        maximumQueuedInputBytes: Int = ToolExecutionLimits.maximumLSPStdinQueueBytes,
        maximumPendingDeliveryBytes: Int = ToolExecutionLimits.maximumOutputChunkBytes * 4,
        maximumPendingDeliveryChunks: Int = 64
    ) {
        precondition(maximumQueuedInputBytes > 0)
        precondition(maximumPendingDeliveryBytes > 0)
        precondition(maximumPendingDeliveryChunks > 0)
        self.maximumQueuedInputBytes = maximumQueuedInputBytes
        self.maximumPendingDeliveryBytes = maximumPendingDeliveryBytes
        self.maximumPendingDeliveryChunks = maximumPendingDeliveryChunks
    }

    public func start(
        _ command: ToolCommand,
        size: PseudoTerminalSize = .default,
        onOutput: ToolProcessOutputHandler? = nil
    ) async throws -> PseudoTerminalProcessSession {
        try ToolProcessCommandValidator.validate(command)
        guard command.standardInput == nil, command.processGroupPolicy == .isolated else {
            throw ToolProcessRunnerError.invalidCommand
        }
        try Task.checkCancellation()
        let execution = PseudoTerminalProcessExecution(
            command: command, size: size,
            maximumQueuedInputBytes: maximumQueuedInputBytes,
            maximumPendingDeliveryBytes: maximumPendingDeliveryBytes,
            maximumPendingDeliveryChunks: maximumPendingDeliveryChunks,
            onOutput: onOutput
        )
        do {
            try await withTaskCancellationHandler {
                try await execution.start()
            } onCancel: {
                execution.cancel()
            }
            if Task.isCancelled {
                execution.cancel()
                _ = try? await execution.waitForTeardown()
                throw ToolExecutionError.cancelled
            }
            return PseudoTerminalProcessSession(execution: execution)
        } catch {
            _ = try? await execution.waitForTeardown()
            throw error
        }
    }
}

fileprivate final class PseudoTerminalProcessExecution: @unchecked Sendable {
    private typealias ResultValue = Result<ToolProcessResult, Error>

    private struct PendingWrite {
        var data: Data
        var offset: Int
        let closesInput: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private let command: ToolCommand
    private let initialSize: PseudoTerminalSize
    private let maximumQueuedInputBytes: Int
    private let maximumPendingDeliveryBytes: Int
    private let maximumPendingDeliveryChunks: Int
    private let onOutput: ToolProcessOutputHandler?

    private let stateQueue = DispatchQueue(
        label: "LumenEditor.PseudoTerminal.State." + UUID().uuidString
    )
    private let deliveryQueue = DispatchQueue(
        label: "LumenEditor.PseudoTerminal.Delivery." + UUID().uuidString
    )

    private var launchContinuation: CheckedContinuation<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<ToolProcessResult, Error>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var teardownWaiters: [CheckedContinuation<ToolProcessResult, Error>] = []
    private var finalResult: ResultValue?

    private var processIdentifier: pid_t = 0
    private var trackedProcessGroups: Set<pid_t> = []
    private var masterDescriptor: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var writeRetryWorkItem: DispatchWorkItem?
    private var processExitSource: (any DispatchSourceProcess)?
    private var processStarted = false
    private var processTerminationObserved = false
    private var sessionGone = false
    private var terminationExitCode: Int32?
    private var stopError: Error?
    private var terminationStarted = false
    private var finalizationScheduled = false
    private var readFinished = false
    private var descriptorClosePending = false

    private var standardOutput = Data()
    private var observedOutputBytes = 0
    private var pendingDeliveryBytes = 0
    private var pendingDeliveryChunks = 0

    private var inputAccepting = true
    private var inputClosed = false
    private var pendingWrites: [PendingWrite] = []
    private var queuedInputBytes = 0

    private var timeoutWorkItem: DispatchWorkItem?
    private var forceKillWorkItem: DispatchWorkItem?
    private var sessionPollWorkItem: DispatchWorkItem?

    init(
        command: ToolCommand,
        size: PseudoTerminalSize,
        maximumQueuedInputBytes: Int,
        maximumPendingDeliveryBytes: Int,
        maximumPendingDeliveryChunks: Int,
        onOutput: ToolProcessOutputHandler?
    ) {
        self.command = command
        initialSize = size
        self.maximumQueuedInputBytes = maximumQueuedInputBytes
        self.maximumPendingDeliveryBytes = maximumPendingDeliveryBytes
        self.maximumPendingDeliveryChunks = maximumPendingDeliveryChunks
        self.onOutput = onOutput
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in startOnStateQueue(continuation) }
        }
    }

    func write(_ data: Data) async throws {
        try await enqueueWrite(data, closesInput: false)
    }

    func closeStandardInput() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard inputAccepting, !inputClosed, finalResult == nil else {
                    if inputClosed { continuation.resume() }
                    else { continuation.resume(throwing: ToolProcessSessionError.closed) }
                    return
                }
                inputAccepting = false
                appendWrite(Data([0x04]), closesInput: true, continuation: continuation)
            }
        }
    }

    func interrupt() async throws {
        try await enqueueWrite(Data([0x03]), closesInput: false)
    }

    func resize(to size: PseudoTerminalSize) async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard masterDescriptor >= 0, finalResult == nil, stopError == nil else {
                    continuation.resume(throwing: ToolProcessSessionError.closed)
                    return
                }
                if lumen_pty_resize(masterDescriptor, size.columns, size.rows) == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ToolProcessSessionError.resizeFailed)
                }
            }
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            self?.requestStop(with: ToolExecutionError.cancelled)
        }
    }

    func waitForExit() async throws -> ToolProcessResult {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateQueue.async { [self] in registerWaiter(id, continuation) }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    func waitForTeardown() async throws -> ToolProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                if let finalResult { continuation.resume(with: finalResult) }
                else { teardownWaiters.append(continuation) }
            }
        }
    }

    private func enqueueWrite(_ data: Data, closesInput: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard inputAccepting, !inputClosed, finalResult == nil, stopError == nil else {
                    continuation.resume(throwing: ToolProcessSessionError.closed)
                    return
                }
                guard data.count <= ToolExecutionLimits.maximumStdinWriteBytes else {
                    continuation.resume(throwing: ToolProcessSessionError.writeTooLarge(
                        actualBytes: data.count,
                        maximumBytes: ToolExecutionLimits.maximumStdinWriteBytes
                    ))
                    return
                }
                guard queuedInputBytes <= maximumQueuedInputBytes - data.count else {
                    continuation.resume(throwing: ToolProcessSessionError.queueOverflow(
                        maximumBytes: maximumQueuedInputBytes
                    ))
                    return
                }
                guard !data.isEmpty else { continuation.resume(); return }
                appendWrite(data, closesInput: closesInput, continuation: continuation)
            }
        }
    }

    private func appendWrite(
        _ data: Data,
        closesInput: Bool,
        continuation: CheckedContinuation<Void, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        queuedInputBytes += data.count
        pendingWrites.append(PendingWrite(
            data: data, offset: 0, closesInput: closesInput, continuation: continuation
        ))
        drainWrites()
    }

    private func startOnStateQueue(_ continuation: CheckedContinuation<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard launchContinuation == nil, finalResult == nil else {
            continuation.resume(throwing: ToolProcessRunnerError.invalidCommand)
            return
        }
        launchContinuation = continuation
        if let stopError { finishBeforeLaunch(stopError); return }
        do {
            let launched = try spawnProcess()
            processIdentifier = launched.pid
            masterDescriptor = launched.master
            let foregroundProcessGroup = max(
                processIdentifier, lumen_pty_foreground_process_group(launched.master)
            )
            trackedProcessGroups.insert(processIdentifier)
            trackedProcessGroups.insert(foregroundProcessGroup)
            processStarted = true
        } catch {
            finishBeforeLaunch(error)
            return
        }
        startDescriptorSources()
        startProcessExitSource()
        scheduleTimeout()
        let launched = launchContinuation
        launchContinuation = nil
        launched?.resume()
    }

    private func spawnProcess() throws -> (pid: pid_t, master: Int32) {
        let arguments = try SpawnCStringVector(
            [command.executableURL.path] + command.arguments
        )
        let environment = try SpawnCStringVector(
            command.environment.keys.sorted().map { key in
                key + "=" + (command.environment[key] ?? "")
            }
        )
        var child: pid_t = 0
        var master: Int32 = -1
        var failureStage: Int32 = 0
        var errorCode: Int32 = 0
        let result = command.executableURL.path.withCString { executable in
            command.workingDirectoryURL.path.withCString { directory in
                arguments.withUnsafeMutablePointer { argv in
                    environment.withUnsafeMutablePointer { envp in
                        lumen_pty_spawn(
                            executable, argv, envp, directory,
                            initialSize.columns, initialSize.rows,
                            &child, &master, &failureStage, &errorCode
                        )
                    }
                }
            }
        }
        guard result == 0 else {
            let stage: String = switch failureStage {
            case 1: "configure PTY"
            case 2: "fork PTY child"
            case 3: "set working directory"
            case 4: "exec terminal shell"
            default: "read PTY launch status"
            }
            throw ToolProcessRunnerError.launchFailed(
                stage + ": " + String(cString: strerror(errorCode))
                    + " (errno \(errorCode))"
            )
        }
        return (child, master)
    }

    private func startDescriptorSources() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let reader = DispatchSource.makeReadSource(
            fileDescriptor: masterDescriptor, queue: stateQueue
        )
        reader.setEventHandler { [weak self] in self?.readAvailableOutput() }
        readSource = reader
        reader.activate()
    }

    private func readAvailableOutput() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard masterDescriptor >= 0, !readFinished else { return }
        captureForegroundProcessGroup()
        var storage = [UInt8](
            repeating: 0, count: ToolExecutionLimits.maximumOutputChunkBytes
        )
        while true {
            let count = storage.withUnsafeMutableBytes { raw in
                Darwin.read(masterDescriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                consumeOutput(Data(storage.prefix(Int(count))))
                continue
            }
            if count == 0 || (count < 0 && errno == EIO) {
                finishReading()
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK
                        && errno != EINTR {
                requestStop(with: ToolProcessRunnerError.launchFailed(
                    "read PTY: " + String(cString: strerror(errno))
                        + " (errno \(errno))"
                ))
            } else if count < 0 && errno == EINTR {
                continue
            }
            return
        }
    }

    private func consumeOutput(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !data.isEmpty, finalResult == nil else { return }
        guard stopError == nil else { return }
        let maximum = command.maximumStandardOutputBytes
        let acceptedCount = min(data.count, max(0, maximum - observedOutputBytes))
        observedOutputBytes += acceptedCount
        if acceptedCount > 0 {
            let accepted = Data(data.prefix(acceptedCount))
            let retained = command.maximumRetainedStandardOutputBytes
            if standardOutput.count < retained {
                standardOutput.append(accepted.prefix(retained - standardOutput.count))
            }
            if let onOutput {
                guard accepted.count <= maximumPendingDeliveryBytes,
                      pendingDeliveryBytes <= maximumPendingDeliveryBytes - accepted.count,
                      pendingDeliveryChunks < maximumPendingDeliveryChunks else {
                    requestStop(with: ToolProcessRunnerError.outputDeliveryQueueOverflow(
                        maximumBytes: maximumPendingDeliveryBytes,
                        maximumChunks: maximumPendingDeliveryChunks
                    ))
                    return
                }
                pendingDeliveryBytes += accepted.count
                pendingDeliveryChunks += 1
                deliveryQueue.async { [self] in
                    onOutput(.standardOutput, accepted)
                    stateQueue.async { [self] in
                        pendingDeliveryBytes -= accepted.count
                        pendingDeliveryChunks -= 1
                        tryFinalize()
                    }
                }
            }
        }
        if data.count > acceptedCount {
            requestStop(with: ToolExecutionError.outputLimitExceeded(
                stream: .standardOutput, maximumBytes: maximum
            ))
        }
    }

    private func drainWrites() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard masterDescriptor >= 0, finalResult == nil else { return }
        while !pendingWrites.isEmpty {
            let offset = pendingWrites[0].offset
            let remaining = pendingWrites[0].data.count - offset
            let count = pendingWrites[0].data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(
                    masterDescriptor, base.advanced(by: offset), remaining
                )
            }
            if count > 0 {
                pendingWrites[0].offset += count
                queuedInputBytes -= count
                if pendingWrites[0].offset == pendingWrites[0].data.count {
                    let completed = pendingWrites.removeFirst()
                    if completed.closesInput { inputClosed = true }
                    completed.continuation.resume()
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                scheduleWriteRetry()
                return
            }
            failPendingWrites(with: ToolProcessSessionError.closed)
            return
        }
        writeRetryWorkItem?.cancel()
        writeRetryWorkItem = nil
    }

    private func scheduleWriteRetry() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard writeRetryWorkItem == nil, masterDescriptor >= 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            writeRetryWorkItem = nil
            drainWrites()
        }
        writeRetryWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + 0.005, execute: item)
    }

    private func failPendingWrites(with error: Error) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        inputAccepting = false
        inputClosed = true
        queuedInputBytes = 0
        let writes = pendingWrites
        pendingWrites.removeAll(keepingCapacity: false)
        writes.forEach { $0.continuation.resume(throwing: error) }
    }

    private func finishReading() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !readFinished else { return }
        readFinished = true
        closeMasterDescriptor()
        tryFinalize()
    }

    private func closeMasterDescriptor() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        writeRetryWorkItem?.cancel()
        writeRetryWorkItem = nil
        let descriptor = masterDescriptor
        masterDescriptor = -1
        if let reader = readSource, descriptor >= 0 {
            descriptorClosePending = true
            reader.setCancelHandler { [weak self] in
                _ = Darwin.close(descriptor)
                guard let self else { return }
                descriptorClosePending = false
                tryFinalize()
            }
            reader.cancel()
        } else if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
        readSource = nil
        failPendingWrites(with: ToolProcessSessionError.closed)
    }

    private func startProcessExitSource() {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier, eventMask: .exit, queue: stateQueue
        )
        processExitSource = source
        source.setEventHandler { [weak self] in self?.reapExitedProcessIfAvailable() }
        source.activate()
        reapExitedProcessIfAvailable()
    }

    private func reapExitedProcessIfAvailable() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !processTerminationObserved else { return }
        var status: Int32 = 0
        while true {
            let waited = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if waited == processIdentifier {
                processExitSource?.cancel()
                processExitSource = nil
                processTerminationObserved = true
                terminationExitCode = Self.exitCode(fromWaitStatus: status)
                captureForegroundProcessGroup()
                refreshSessionLiveness()
                if !sessionGone { beginTerminationIfNeeded() }
                scheduleSessionPollIfNeeded()
                finishPTYAfterSessionGoneIfNeeded()
                tryFinalize()
                return
            }
            if waited == 0 { return }
            if waited < 0 && errno == EINTR { continue }
            processExitSource?.cancel()
            processExitSource = nil
            processTerminationObserved = true
            terminationExitCode = -1
            if stopError == nil {
                stopError = ToolProcessRunnerError.launchFailed(
                    "waitpid PTY: " + String(cString: strerror(errno))
                )
            }
            captureForegroundProcessGroup()
            refreshSessionLiveness()
            if !sessionGone { beginTerminationIfNeeded() }
            scheduleSessionPollIfNeeded()
            finishPTYAfterSessionGoneIfNeeded()
            tryFinalize()
            return
        }
    }

    private func scheduleTimeout() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, finalResult == nil, !processTerminationObserved else { return }
            reapExitedProcessIfAvailable()
            guard !processTerminationObserved else { return }
            requestStop(with: ToolExecutionError.timedOut(seconds: command.timeout))
        }
        timeoutWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + command.timeout, execute: item)
    }

    private func requestStop(with error: Error) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil else { return }
        if processStarted, !processTerminationObserved { reapExitedProcessIfAvailable() }
        if stopError == nil, processTerminationObserved,
           (error as? ToolExecutionError) == .cancelled { return }
        if stopError == nil { stopError = error }
        inputAccepting = false
        failPendingWrites(with: ToolProcessSessionError.closed)
        guard processStarted else {
            if launchContinuation != nil { finishBeforeLaunch(stopError ?? error) }
            return
        }
        beginTerminationIfNeeded()
    }

    private func beginTerminationIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !terminationStarted, !sessionGone else { return }
        terminationStarted = true
        captureForegroundProcessGroup()
        signalTrackedProcessGroups(SIGTERM)
        scheduleSessionPollIfNeeded()
        let item = DispatchWorkItem { [weak self] in
            guard let self, finalResult == nil else { return }
            captureForegroundProcessGroup()
            refreshSessionLiveness()
            guard !sessionGone else {
                finishPTYAfterSessionGoneIfNeeded()
                tryFinalize()
                return
            }
            signalTrackedProcessGroups(SIGKILL)
            scheduleSessionPollIfNeeded()
        }
        forceKillWorkItem = item
        stateQueue.asyncAfter(
            deadline: .now() + command.gracefulTerminationTimeout, execute: item
        )
    }

    private func captureForegroundProcessGroup() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard masterDescriptor >= 0 else { return }
        let group = lumen_pty_foreground_process_group(masterDescriptor)
        if group > 1 {
            trackedProcessGroups.insert(group)
        }
    }

    private func signalTrackedProcessGroups(_ signal: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        for group in trackedProcessGroups {
            _ = lumen_pty_signal_process_group(group, signal)
        }
        refreshSessionLiveness()
    }

    private func refreshSessionLiveness() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        trackedProcessGroups = trackedProcessGroups.filter { group in
            lumen_pty_process_group_exists(group) != 0
        }
        sessionGone = trackedProcessGroups.isEmpty
        if sessionGone {
            sessionGone = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }
    }

    private func scheduleSessionPollIfNeeded() {
        guard (!processTerminationObserved || !sessionGone),
              sessionPollWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            sessionPollWorkItem = nil
            guard finalResult == nil else { return }
            if !processTerminationObserved { reapExitedProcessIfAvailable() }
            refreshSessionLiveness()
            if processTerminationObserved, sessionGone {
                finishPTYAfterSessionGoneIfNeeded()
                tryFinalize()
            } else {
                scheduleSessionPollIfNeeded()
            }
        }
        sessionPollWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    private func finishPTYAfterSessionGoneIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processTerminationObserved, sessionGone, !readFinished else { return }
        // Drain every byte already readable before closing the master. Closing
        // it is also the final controlling-terminal hangup for an untracked
        // background job that inherited the slave after the shell exited.
        readAvailableOutput()
        if !readFinished { finishReading() }
    }

    private func tryFinalize() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil, !finalizationScheduled,
              processTerminationObserved, sessionGone, readFinished,
              !descriptorClosePending, pendingWrites.isEmpty,
              pendingDeliveryChunks == 0 else { return }
        let result: ResultValue = if let stopError {
            .failure(stopError)
        } else {
            .success(ToolProcessResult(
                standardOutput: standardOutput, standardError: Data(),
                exitCode: terminationExitCode ?? -1
            ))
        }
        finalizationScheduled = true
        finishFinalization(result)
    }

    private func finishBeforeLaunch(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        stopError = error
        processTerminationObserved = true
        sessionGone = true
        readFinished = true
        inputAccepting = false
        inputClosed = true
        terminationExitCode = -1
        tryFinalize()
    }

    private func finishFinalization(_ result: ResultValue) {
        timeoutWorkItem?.cancel()
        forceKillWorkItem?.cancel()
        sessionPollWorkItem?.cancel()
        processExitSource?.cancel()
        timeoutWorkItem = nil
        forceKillWorkItem = nil
        sessionPollWorkItem = nil
        processExitSource = nil
        closeMasterDescriptor()
        finalResult = result
        let launch = launchContinuation
        launchContinuation = nil
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        cancelledWaiterIDs.removeAll(keepingCapacity: false)
        let teardown = teardownWaiters
        teardownWaiters.removeAll(keepingCapacity: false)
        launch?.resume(with: result.map { _ in () })
        waiters.values.forEach { $0.resume(with: result) }
        teardown.forEach { $0.resume(with: result) }
    }

    private func registerWaiter(
        _ id: UUID, _ continuation: CheckedContinuation<ToolProcessResult, Error>
    ) {
        if cancelledWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
        } else if let finalResult {
            continuation.resume(with: finalResult)
        } else {
            waiters[id] = continuation
        }
    }

    private func cancelWaiter(_ id: UUID) {
        stateQueue.async { [self] in
            guard finalResult == nil else { return }
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume(throwing: CancellationError())
            } else {
                cancelledWaiterIDs.insert(id)
            }
        }
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowBits = status & 0x7f
        if lowBits == 0 { return (status >> 8) & 0xff }
        if lowBits != 0x7f { return lowBits }
        return -1
    }
}
