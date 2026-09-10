@preconcurrency import Foundation
import Darwin

/// Errors which are specific to admitting, launching, or delivering events
/// from a tool process. Limits already represented by `ToolExecutionError`
/// continue to use that error type.
public enum ToolProcessRunnerError: Error, Equatable, LocalizedError, Sendable {
    case invalidCommand
    case launchFailed(String)
    case processQueueOverflow(maximumPending: Int)
    case outputDeliveryQueueOverflow(maximumBytes: Int, maximumChunks: Int)
    case standardInputWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "The tool process command or its limits are invalid."
        case let .launchFailed(detail):
            return "The tool process could not be launched: \(detail)"
        case let .processQueueOverflow(maximumPending):
            return "The tool process queue already contains \(maximumPending) pending commands."
        case let .outputDeliveryQueueOverflow(maximumBytes, maximumChunks):
            return "Tool output delivery exceeded \(maximumBytes) pending bytes or \(maximumChunks) pending chunks."
        case .standardInputWriteFailed:
            return "Could not write the complete one-shot tool standard input."
        }
    }
}

/// Errors returned by interactive session operations. A write is accepted
/// only when the complete value fits in the bounded pending-write queue.
public enum ToolProcessSessionError: Error, Equatable, LocalizedError, Sendable {
    case writeTooLarge(actualBytes: Int, maximumBytes: Int)
    case queueOverflow(maximumBytes: Int)
    case interruptFailed
    case resizeFailed
    case closed

    public var errorDescription: String? {
        switch self {
        case let .writeTooLarge(actualBytes, maximumBytes):
            return "A tool stdin write uses \(actualBytes) bytes; each write may use at most \(maximumBytes) bytes."
        case let .queueOverflow(maximumBytes):
            return "The tool stdin queue exceeds its \(maximumBytes)-byte limit."
        case .interruptFailed:
            return "Could not deliver SIGINT to the tool process session."
        case .resizeFailed:
            return "Could not resize the pseudo-terminal session."
        case .closed:
            return "The tool process standard input is closed."
        }
    }
}

/// Output callbacks are serialized in the order in which the broker observes
/// the two pipes. Every delivered `Data` value is nonempty and no larger than
/// `ToolExecutionLimits.maximumOutputChunkBytes`.
public typealias ToolProcessOutputHandler = @Sendable (
    _ stream: ToolOutputStream,
    _ data: Data
) -> Void

/// The termination callback follows every accepted output callback. It runs
/// off the process state queue and completes before `waitForExit()` settles.
public typealias ToolProcessTerminationHandler = @Sendable (
    _ result: Result<ToolProcessResult, Error>
) -> Void

/// A running process with serialized, bounded stdin and repeatable waiting.
/// Cancelling one `waitForExit()` task removes only that waiter; use `cancel()`
/// to stop the process itself.
public final class ToolProcessSession: @unchecked Sendable {
    fileprivate let execution: ToolProcessExecution

    fileprivate init(execution: ToolProcessExecution) {
        self.execution = execution
    }

    /// Queue one stdin value. Concurrent calls are written in acceptance
    /// order. The call returns after the bytes have been written or rejected.
    public func write(_ data: Data) async throws {
        try await execution.write(data)
    }

    public func writeStandardInput(_ data: Data) async throws {
        try await write(data)
    }

    /// Stop accepting stdin and close it after all previously accepted writes.
    public func closeStandardInput() async throws {
        try await execution.closeStandardInput()
    }

    /// Deliver SIGINT without closing stdin or beginning cancellation. For an
    /// isolated command this targets the complete process group, allowing a
    /// non-PTY client to interrupt a shell's foreground child.
    public func interrupt() async throws {
        try await execution.interrupt()
    }

    /// Request bounded SIGTERM/SIGKILL teardown. Completion is observed with
    /// `waitForExit()`; this method itself is deliberately nonblocking.
    public func cancel() {
        execution.cancel()
    }

    /// Waiters may be added before or after exit and all receive the same
    /// process result. Cancelling a waiter does not cancel the shared process.
    public func waitForExit() async throws -> ToolProcessResult {
        try await execution.waitForExit()
    }
}

/// A bounded broker for direct `posix_spawn` execution on macOS. It
/// never inserts a shell: validated shell commands are already represented by
/// a fixed shell executable and `-c` argv in `ToolCommand`.
public actor ToolProcessRunner: ToolCommandRunning {
    private struct PendingPermit {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentProcesses: Int
    private let maximumPendingProcesses: Int
    private let maximumQueuedStandardInputBytes: Int
    private let maximumPendingOutputDeliveryBytes: Int
    private let maximumPendingOutputDeliveryChunks: Int
    private let processExitNotificationDelayForTesting: TimeInterval
    private let processExitNotificationObservedForTesting: (@Sendable () -> Void)?

    private var executions: [UUID: ToolProcessExecution] = [:]
    private var reservedPermits: Set<UUID> = []
    private var pendingPermits: [PendingPermit] = []
    private var cancelledAdmissionIDs: Set<UUID> = []

    public init(
        maximumConcurrentProcesses: Int = 8,
        maximumPendingProcesses: Int = 64,
        maximumQueuedStandardInputBytes: Int = ToolExecutionLimits.maximumLSPStdinQueueBytes,
        maximumPendingOutputDeliveryBytes: Int = ToolExecutionLimits.maximumOutputChunkBytes * 4,
        maximumPendingOutputDeliveryChunks: Int = 64
    ) {
        precondition(maximumConcurrentProcesses > 0)
        precondition(maximumPendingProcesses >= 0)
        precondition(maximumQueuedStandardInputBytes > 0)
        precondition(maximumPendingOutputDeliveryBytes > 0)
        precondition(maximumPendingOutputDeliveryChunks > 0)
        self.maximumConcurrentProcesses = maximumConcurrentProcesses
        self.maximumPendingProcesses = maximumPendingProcesses
        self.maximumQueuedStandardInputBytes = maximumQueuedStandardInputBytes
        self.maximumPendingOutputDeliveryBytes = maximumPendingOutputDeliveryBytes
        self.maximumPendingOutputDeliveryChunks = maximumPendingOutputDeliveryChunks
        self.processExitNotificationDelayForTesting = 0
        self.processExitNotificationObservedForTesting = nil
    }

    /// Test seam for deterministically holding the dispatch exit notification
    /// after the kernel has reported it but before this runner calls `waitpid`.
    /// Production always uses the public initializer's zero-delay path.
    init(
        processExitNotificationDelayForTesting: TimeInterval,
        processExitNotificationObservedForTesting: @escaping @Sendable () -> Void
    ) {
        precondition(processExitNotificationDelayForTesting >= 0)
        self.maximumConcurrentProcesses = 8
        self.maximumPendingProcesses = 64
        self.maximumQueuedStandardInputBytes = ToolExecutionLimits.maximumLSPStdinQueueBytes
        self.maximumPendingOutputDeliveryBytes = ToolExecutionLimits.maximumOutputChunkBytes * 4
        self.maximumPendingOutputDeliveryChunks = 64
        self.processExitNotificationDelayForTesting = processExitNotificationDelayForTesting
        self.processExitNotificationObservedForTesting = processExitNotificationObservedForTesting
    }

    public func run(_ command: ToolCommand) async throws -> ToolProcessResult {
        try await run(command, onOutput: nil)
    }

    /// Run a one-shot command while optionally receiving bounded chunks. The
    /// returned result remains separately bounded by the command's two caps.
    public func run(
        _ command: ToolCommand,
        onOutput: ToolProcessOutputHandler?
    ) async throws -> ToolProcessResult {
        let session = try await startExecution(
            command,
            closeEmptyStandardInput: true,
            cancellationShouldStopProcess: true,
            onOutput: onOutput,
            onTermination: nil
        )
        return try await session.execution.waitForRunnerCompletion()
    }

    /// Launch an interactive process. A command carrying one-shot stdin writes
    /// that value and closes stdin automatically; nil stdin remains open.
    public func start(
        _ command: ToolCommand,
        onOutput: ToolProcessOutputHandler? = nil,
        onTermination: ToolProcessTerminationHandler? = nil
    ) async throws -> ToolProcessSession {
        return try await startExecution(
            command,
            closeEmptyStandardInput: false,
            cancellationShouldStopProcess: false,
            onOutput: onOutput,
            onTermination: onTermination
        )
    }

    private func startExecution(
        _ command: ToolCommand,
        closeEmptyStandardInput: Bool,
        cancellationShouldStopProcess: Bool,
        onOutput: ToolProcessOutputHandler?,
        onTermination: ToolProcessTerminationHandler?
    ) async throws -> ToolProcessSession {
        try ToolProcessCommandValidator.validate(command)
        try Task.checkCancellation()

        let id = UUID()
        try await acquirePermit(id: id)

        guard !Task.isCancelled, cancelledAdmissionIDs.remove(id) == nil else {
            releaseReservedPermit(id: id)
            throw ToolExecutionError.cancelled
        }
        let execution = ToolProcessExecution(
            command: command,
            closeEmptyStandardInput: closeEmptyStandardInput,
            cancellationShouldStopProcess: cancellationShouldStopProcess,
            maximumQueuedStandardInputBytes: maximumQueuedStandardInputBytes,
            maximumPendingOutputDeliveryBytes: maximumPendingOutputDeliveryBytes,
            maximumPendingOutputDeliveryChunks: maximumPendingOutputDeliveryChunks,
            processExitNotificationDelayForTesting: processExitNotificationDelayForTesting,
            processExitNotificationObservedForTesting:
                processExitNotificationObservedForTesting,
            onOutput: onOutput,
            onTermination: onTermination,
            onFinalized: { [weak self] in
                guard let runner = self else { return }
                Task { await runner.executionDidFinalize(id: id) }
            }
        )
        reservedPermits.remove(id)
        executions[id] = execution

        do {
            try await withTaskCancellationHandler {
                try await execution.start()
            } onCancel: {
                execution.cancel()
            }
            if Task.isCancelled {
                execution.cancel()
                // If cancellation raced with a child that had already exited,
                // requestStop's synchronous reap preserves that physical result.
                // A still-running child instead completes this wait by throwing
                // the cancellation recorded during bounded teardown.
                _ = try await execution.waitForRunnerCompletion()
            }
            return ToolProcessSession(execution: execution)
        } catch {
            // Launch failures and launch-time cancellation finish teardown
            // before `start` throws; the finalizer releases the permit.
            _ = try? await execution.waitForRunnerCompletion()
            throw error
        }
    }

    /// Cancel the currently admitted generation and wait for every launched
    /// member of that generation to finish teardown. Later starts are allowed.
    public func cancelAll() async {
        let pending = pendingPermits
        pendingPermits.removeAll(keepingCapacity: true)
        cancelledAdmissionIDs.formUnion(reservedPermits)
        pending.forEach { $0.continuation.resume(throwing: ToolExecutionError.cancelled) }

        let active = executions.map { ($0.key, $0.value) }
        active.forEach { $0.1.cancel() }
        for (_, execution) in active {
            _ = try? await execution.waitForRunnerCompletion()
        }
        // The finalizer callback removes executions asynchronously through the
        // actor. Remove exactly the generation we just joined now, so a caller
        // can immediately start a fresh generation without oversubscribing.
        for (id, _) in active { executions[id] = nil }
        promotePendingPermits()
    }

    private func acquirePermit(id: UUID) async throws {
        if executions.count + reservedPermits.count < maximumConcurrentProcesses {
            reservedPermits.insert(id)
            return
        }
        guard pendingPermits.count < maximumPendingProcesses else {
            throw ToolProcessRunnerError.processQueueOverflow(
                maximumPending: maximumPendingProcesses
            )
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: ToolExecutionError.cancelled)
                } else {
                    pendingPermits.append(PendingPermit(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelPendingPermit(id: id) }
        }
    }

    private func cancelPendingPermit(id: UUID) {
        guard let index = pendingPermits.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingPermits.remove(at: index)
        pending.continuation.resume(throwing: ToolExecutionError.cancelled)
    }

    private func releaseReservedPermit(id: UUID) {
        reservedPermits.remove(id)
        cancelledAdmissionIDs.remove(id)
        promotePendingPermits()
    }

    private func executionDidFinalize(id: UUID) {
        executions[id] = nil
        promotePendingPermits()
    }

    private func promotePendingPermits() {
        while executions.count + reservedPermits.count < maximumConcurrentProcesses,
              !pendingPermits.isEmpty {
            let pending = pendingPermits.removeFirst()
            reservedPermits.insert(pending.id)
            pending.continuation.resume()
        }
    }

}

/// Shared validation for the pipe and pseudo-terminal process brokers. Keeping
/// one admission contract prevents Terminal from accepting argv, environment,
/// path, or resource limits that Build/LSP would reject.
enum ToolProcessCommandValidator {
    static func validate(_ command: ToolCommand) throws {
        let executable = command.executableURL
        let workingDirectory = command.workingDirectoryURL
        guard executable.isFileURL,
              executable.host == nil || executable.host?.isEmpty == true,
              executable.path.hasPrefix("/"),
              !executable.path.utf8.contains(0),
              executable.path.utf16.count
                <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits,
              workingDirectory.isFileURL,
              workingDirectory.host == nil || workingDirectory.host?.isEmpty == true,
              workingDirectory.path.hasPrefix("/"),
              !workingDirectory.path.utf8.contains(0),
              workingDirectory.path.utf16.count
                <= ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits,
              command.arguments.allSatisfy({
                  !$0.utf8.contains(0)
                    && $0.utf16.count
                        <= ToolExecutionLimits.maximumArgumentUTF16CodeUnits
              }),
              command.arguments.count <= ToolExecutionLimits.maximumArguments,
              command.environment.count
                <= ToolExecutionLimits.maximumInheritedEnvironmentVariables,
              command.environment.allSatisfy({
                  !$0.key.isEmpty
                    && !$0.key.utf8.contains(0)
                    && !$0.key.contains("=")
                    && $0.key.utf8.count
                        <= ToolExecutionLimits.maximumEnvironmentKeyASCIICharacters
                    && !$0.value.utf8.contains(0)
                    && $0.value.utf16.count
                        <= ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
              }),
              command.timeout > 0, command.timeout.isFinite,
              command.gracefulTerminationTimeout >= 0,
              command.gracefulTerminationTimeout.isFinite,
              command.maximumStandardInputBytes >= 0,
              command.maximumStandardOutputBytes > 0,
              command.maximumRetainedStandardOutputBytes >= 0,
              command.maximumRetainedStandardOutputBytes
                <= command.maximumStandardOutputBytes,
              command.maximumStandardErrorBytes > 0 else {
            throw ToolProcessRunnerError.invalidCommand
        }
        if let input = command.standardInput,
           input.count > command.maximumStandardInputBytes {
            throw ToolExecutionError.standardInputTooLarge(
                actualBytes: input.count,
                maximumBytes: command.maximumStandardInputBytes
            )
        }
    }
}

// MARK: - One execution

fileprivate final class ToolProcessExecution: @unchecked Sendable {
    private typealias ResultValue = Result<ToolProcessResult, Error>

    private let command: ToolCommand
    private let closeEmptyStandardInput: Bool
    private let cancellationShouldStopProcess: Bool
    private let maximumQueuedStandardInputBytes: Int
    private let maximumPendingOutputDeliveryBytes: Int
    private let maximumPendingOutputDeliveryChunks: Int
    private let processExitNotificationDelayForTesting: TimeInterval
    private let processExitNotificationObservedForTesting: (@Sendable () -> Void)?
    private let onOutput: ToolProcessOutputHandler?
    private let onTermination: ToolProcessTerminationHandler?
    private let onFinalized: @Sendable () -> Void

    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputPipe = Pipe()

    /// Process identifiers and all lifecycle state live only on this queue.
    private let stateQueue = DispatchQueue(
        label: "LumenEditor.ToolProcess.State.\(UUID().uuidString)"
    )
    /// Each FileHandle has one owning serial queue after launch.
    private let outputReaderQueue = DispatchQueue(
        label: "LumenEditor.ToolProcess.Stdout.\(UUID().uuidString)"
    )
    private let errorReaderQueue = DispatchQueue(
        label: "LumenEditor.ToolProcess.Stderr.\(UUID().uuidString)"
    )
    private let inputWriterQueue = DispatchQueue(
        label: "LumenEditor.ToolProcess.Stdin.\(UUID().uuidString)"
    )
    private let deliveryQueue = DispatchQueue(
        label: "LumenEditor.ToolProcess.Delivery.\(UUID().uuidString)"
    )

    private var launchContinuation: CheckedContinuation<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<ToolProcessResult, Error>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var finalResult: ResultValue?

    private var processStarted = false
    private var processIdentifier: pid_t = 0
    private var processExitSource: (any DispatchSourceProcess)?
    private var processExitNotificationWasObserved = false
    private var processTerminationObserved = false
    private var terminationExitCode: Int32?
    private var processGroupGone = false
    private var usesIsolatedProcessGroup = false
    private var stopError: Error?
    private var terminationStarted = false
    private var finalizationScheduled = false

    private var standardOutput = Data()
    private var standardError = Data()
    private var observedStandardOutputBytes = 0
    private var observedStandardErrorBytes = 0
    private var outputReadFinished = false
    private var errorReadFinished = false
    private var observedOutputSequence: UInt64 = 0
    private var nextDeliverySequence: UInt64 = 0
    private var pendingOutputBySequence: [
        UInt64: (stream: ToolOutputStream, data: Data)
    ] = [:]
    private var pendingDeliveryBytes = 0
    private var pendingDeliveryChunks = 0

    private var inputAccepting = true
    private var inputCloseScheduled = false
    private var inputClosed = false
    private var queuedInputBytes = 0
    private var outstandingInputOperations = 0
    private var inputWriteError: Error?
    private var inputCloseWaiters: [CheckedContinuation<Void, Error>] = []

    private var timeoutWorkItem: DispatchWorkItem?
    private var forceKillWorkItem: DispatchWorkItem?
    private var groupPollWorkItem: DispatchWorkItem?

    init(
        command: ToolCommand,
        closeEmptyStandardInput: Bool,
        cancellationShouldStopProcess: Bool,
        maximumQueuedStandardInputBytes: Int,
        maximumPendingOutputDeliveryBytes: Int,
        maximumPendingOutputDeliveryChunks: Int,
        processExitNotificationDelayForTesting: TimeInterval,
        processExitNotificationObservedForTesting: (@Sendable () -> Void)?,
        onOutput: ToolProcessOutputHandler?,
        onTermination: ToolProcessTerminationHandler?,
        onFinalized: @escaping @Sendable () -> Void
    ) {
        self.command = command
        self.closeEmptyStandardInput = closeEmptyStandardInput
        self.cancellationShouldStopProcess = cancellationShouldStopProcess
        self.maximumQueuedStandardInputBytes = maximumQueuedStandardInputBytes
        self.maximumPendingOutputDeliveryBytes = maximumPendingOutputDeliveryBytes
        self.maximumPendingOutputDeliveryChunks = maximumPendingOutputDeliveryChunks
        self.processExitNotificationDelayForTesting = processExitNotificationDelayForTesting
        self.processExitNotificationObservedForTesting =
            processExitNotificationObservedForTesting
        self.onOutput = onOutput
        self.onTermination = onTermination
        self.onFinalized = onFinalized
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                startOnStateQueue(continuation: continuation)
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync { [self] in
                acceptInput(data, continuation: continuation)
            }
        }
    }

    func closeStandardInput() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.sync { [self] in
                if inputClosed {
                    if let inputWriteError { continuation.resume(throwing: inputWriteError) }
                    else { continuation.resume() }
                    return
                }
                inputAccepting = false
                inputCloseWaiters.append(continuation)
                scheduleInputClose()
            }
        }
    }

    func interrupt() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                interruptOnStateQueue(continuation: continuation)
            }
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            self?.requestStop(with: ToolExecutionError.cancelled)
        }
    }

    /// Public-session waiting: cancelling this Task removes just its waiter.
    func waitForExit() async throws -> ToolProcessResult {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateQueue.async { [self] in
                    registerWaiter(id: id, continuation: continuation)
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    /// Runner waiting deliberately ignores waiter cancellation. The runner's
    /// cancellation handler first stops the process, then this waits for its
    /// confirmed exit and resource teardown.
    func waitForRunnerCompletion() async throws -> ToolProcessResult {
        try await waitForExit()
    }

    private func startOnStateQueue(
        continuation: CheckedContinuation<Void, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil, launchContinuation == nil else {
            continuation.resume(throwing: ToolProcessRunnerError.invalidCommand)
            return
        }
        launchContinuation = continuation
        if let stopError {
            finishBeforeLaunch(with: stopError)
            return
        }

        do {
            processIdentifier = try spawnProcess()
            processStarted = true
        } catch {
            finishBeforeLaunch(with: error)
            return
        }

        // POSIX_SPAWN_SETPGROUP with pgroup zero creates a group whose ID is
        // the child's PID before its executable begins. A successful spawn is
        // therefore sufficient proof of isolation; there is no post-exec
        // getpgid/setpgid window to race.
        usesIsolatedProcessGroup = command.processGroupPolicy == .isolated

        // The child duplicated its ends during spawn. No worker queue ever
        // touches these parent-owned endpoint objects.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()

        startReaders()
        startProcessExitSource()

        scheduleTimeout()
        if let initialInput = command.standardInput {
            inputAccepting = false
            scheduleInitialInput(initialInput)
            scheduleInputClose()
        } else if closeEmptyStandardInput {
            scheduleInputClose()
        }

        let launched = launchContinuation
        launchContinuation = nil
        launched?.resume()
    }

    private func finishBeforeLaunch(with error: Error) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        stopError = error
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
        try? inputPipe.fileHandleForWriting.close()
        outputReadFinished = true
        errorReadFinished = true
        inputAccepting = false
        inputClosed = true
        processTerminationObserved = true
        processGroupGone = true
        terminationExitCode = -1
        tryFinalize()
    }

    private func spawnProcess() throws -> pid_t {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let inputWriteDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        guard Darwin.fcntl(inputWriteDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            let errorCode = errno
            throw ToolProcessRunnerError.launchFailed(
                "configure stdin pipe: "
                    + "\(String(cString: strerror(errorCode))) "
                    + "(errno \(errorCode))"
            )
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        try checkSpawnResult(
            posix_spawn_file_actions_init(&fileActions),
            operation: "posix_spawn_file_actions_init"
        )
        defer { _ = posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t? = nil
        try checkSpawnResult(
            posix_spawnattr_init(&attributes),
            operation: "posix_spawnattr_init"
        )
        defer { _ = posix_spawnattr_destroy(&attributes) }

        // A parent process is allowed to have one of 0, 1, or 2 closed. In
        // that case Pipe may reuse a standard descriptor, and a sequence of
        // dup2 actions could overwrite a later action's source. Give every
        // source a private descriptor above the standard range first.
        var spawnDescriptors: [Int32] = []
        defer { spawnDescriptors.forEach { _ = Darwin.close($0) } }
        func duplicateForSpawn(_ descriptor: Int32) throws -> Int32 {
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
            guard duplicate >= 0 else {
                let errorCode = errno
                throw ToolProcessRunnerError.launchFailed(
                    "duplicate pipe descriptor: "
                        + "\(String(cString: strerror(errorCode))) "
                        + "(errno \(errorCode))"
                )
            }
            spawnDescriptors.append(duplicate)
            return duplicate
        }

        let inputDescriptor = try duplicateForSpawn(
            inputPipe.fileHandleForReading.fileDescriptor
        )
        let outputDescriptor = try duplicateForSpawn(
            outputPipe.fileHandleForWriting.fileDescriptor
        )
        let errorDescriptor = try duplicateForSpawn(
            errorPipe.fileHandleForWriting.fileDescriptor
        )
        try addSpawnFileAction(
            posix_spawn_file_actions_adddup2(
                &fileActions, inputDescriptor, STDIN_FILENO
            ),
            operation: "redirect stdin"
        )
        try addSpawnFileAction(
            posix_spawn_file_actions_adddup2(
                &fileActions, outputDescriptor, STDOUT_FILENO
            ),
            operation: "redirect stdout"
        )
        try addSpawnFileAction(
            posix_spawn_file_actions_adddup2(
                &fileActions, errorDescriptor, STDERR_FILENO
            ),
            operation: "redirect stderr"
        )

        // Explicitly close the private sources after dup2. CLOEXEC_DEFAULT
        // closes every original Pipe endpoint and unrelated parent descriptor.
        for descriptor in spawnDescriptors {
            try addSpawnFileAction(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close redirected descriptor"
            )
        }

        let chdirResult = command.workingDirectoryURL.path.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        try addSpawnFileAction(chdirResult, operation: "set working directory")

        var emptySignalMask = sigset_t()
        guard Darwin.sigemptyset(&emptySignalMask) == 0 else {
            let errorCode = errno
            throw ToolProcessRunnerError.launchFailed(
                "configure child signal mask: "
                    + "\(String(cString: strerror(errorCode))) "
                    + "(errno \(errorCode))"
            )
        }
        try checkSpawnResult(
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask),
            operation: "configure child signal mask"
        )
        var defaultSignals = sigset_t()
        guard Darwin.sigfillset(&defaultSignals) == 0,
              Darwin.sigdelset(&defaultSignals, SIGKILL) == 0,
              Darwin.sigdelset(&defaultSignals, SIGSTOP) == 0 else {
            let errorCode = errno
            throw ToolProcessRunnerError.launchFailed(
                "configure child signal defaults: "
                    + "\(String(cString: strerror(errorCode))) "
                    + "(errno \(errorCode))"
            )
        }
        try checkSpawnResult(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            operation: "configure child signal defaults"
        )

        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int16(POSIX_SPAWN_SETSIGMASK)
            | Int16(POSIX_SPAWN_SETSIGDEF)
        if command.processGroupPolicy == .isolated {
            try checkSpawnResult(
                posix_spawnattr_setpgroup(&attributes, 0),
                operation: "configure isolated process group"
            )
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
        }
        try checkSpawnResult(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "posix_spawnattr_setflags"
        )

        let arguments = try SpawnCStringVector(
            [command.executableURL.path] + command.arguments
        )
        let environment = try SpawnCStringVector(
            command.environment.keys.sorted().map { key in
                "\(key)=\(command.environment[key] ?? "")"
            }
        )
        var childPID: pid_t = 0
        let result = command.executableURL.path.withCString { executablePath in
            arguments.withUnsafeMutablePointer { argv in
                environment.withUnsafeMutablePointer { envp in
                    posix_spawn(
                        &childPID, executablePath, &fileActions, &attributes,
                        argv, envp
                    )
                }
            }
        }
        try checkSpawnResult(result, operation: "posix_spawn")
        return childPID
    }

    private func addSpawnFileAction(_ result: Int32, operation: String) throws {
        try checkSpawnResult(result, operation: "posix_spawn file action: \(operation)")
    }

    private func checkSpawnResult(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ToolProcessRunnerError.launchFailed(
                "\(operation): \(String(cString: strerror(result))) (errno \(result))"
            )
        }
    }

    private func startProcessExitSource() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: stateQueue
        )
        processExitSource = source
        source.setEventHandler { [weak self] in
            self?.processExitNotificationDidArrive()
        }
        source.activate()

        // The child may have exited before the kqueue source was installed.
        // A zombie retains its PID until this exact state queue reaps it, so
        // this probe both closes that registration race and prevents any PID
        // reuse between waitpid and lifecycle state publication.
        reapExitedProcessIfAvailable()
    }

    private func processExitNotificationDidArrive() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !processTerminationObserved else { return }
        if !processExitNotificationWasObserved {
            processExitNotificationWasObserved = true
            processExitNotificationObservedForTesting?()
        }
        guard processExitNotificationDelayForTesting > 0 else {
            reapExitedProcessIfAvailable()
            return
        }
        stateQueue.asyncAfter(
            deadline: .now() + processExitNotificationDelayForTesting
        ) { [weak self] in
            self?.reapExitedProcessIfAvailable()
        }
    }

    private func reapExitedProcessIfAvailable() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !processTerminationObserved else { return }
        var status: Int32 = 0
        while true {
            let waitedPID = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if waitedPID == processIdentifier {
                processExitSource?.cancel()
                processExitSource = nil
                processDidTerminate(waitStatus: status)
                return
            }
            if waitedPID == 0 { return }
            if waitedPID == -1, errno == EINTR { continue }
            let waitError = errno
            processExitSource?.cancel()
            processExitSource = nil
            processWaitDidFail(errorCode: waitError)
            return
        }
    }

    private func startReaders() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let maximumChunk = ToolExecutionLimits.maximumOutputChunkBytes
        outputReaderQueue.async { [self] in
            readToEnd(
                from: outputPipe.fileHandleForReading,
                stream: .standardOutput,
                maximumChunkBytes: maximumChunk
            )
        }
        errorReaderQueue.async { [self] in
            readToEnd(
                from: errorPipe.fileHandleForReading,
                stream: .standardError,
                maximumChunkBytes: maximumChunk
            )
        }
    }

    private func readToEnd(
        from handle: FileHandle,
        stream: ToolOutputStream,
        maximumChunkBytes: Int
    ) {
        while true {
            // `read(upToCount:)` is permitted to wait for its requested byte
            // count. `availableData` returns as soon as pipe data is readable,
            // which is required for output limits and live callbacks to react
            // before a long-running child exits.
            let available = handle.availableData
            guard !available.isEmpty else { break }
            var start = available.startIndex
            while start < available.endIndex {
                let end = available.index(
                    start,
                    offsetBy: min(
                        maximumChunkBytes,
                        available.distance(from: start, to: available.endIndex)
                    )
                )
                let chunk = Data(available[start..<end])
                stateQueue.sync { [self] in
                    consume(chunk, stream: stream)
                }
                start = end
            }
        }
        try? handle.close()
        stateQueue.async { [self] in
            readerDidFinish(stream: stream)
        }
    }

    private func consume(_ data: Data, stream: ToolOutputStream) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil, !data.isEmpty else { return }
        let sequence = observedOutputSequence
        observedOutputSequence &+= 1
        // Once stopping has begun, readers continue to EOF to prevent pipe
        // deadlock, but no more user-controlled bytes are retained.
        guard stopError == nil else {
            markOutputSequenceSkipped(sequence)
            return
        }

        let maximum = stream == .standardOutput
            ? command.maximumStandardOutputBytes
            : command.maximumStandardErrorBytes
        let observed = stream == .standardOutput
            ? observedStandardOutputBytes
            : observedStandardErrorBytes
        let acceptedCount = min(data.count, max(0, maximum - observed))
        if stream == .standardOutput { observedStandardOutputBytes += acceptedCount }
        else { observedStandardErrorBytes += acceptedCount }
        if acceptedCount > 0 {
            let accepted = Data(data.prefix(acceptedCount))
            guard canEnqueueOutputDelivery(accepted) else {
                markOutputSequenceSkipped(sequence)
                requestStop(with: ToolProcessRunnerError.outputDeliveryQueueOverflow(
                    maximumBytes: maximumPendingOutputDeliveryBytes,
                    maximumChunks: maximumPendingOutputDeliveryChunks
                ))
                return
            }
            if stream == .standardOutput {
                appendRetainedOutput(accepted)
            } else {
                standardError.append(accepted)
            }
            enqueueOutputDelivery(accepted, stream: stream, sequence: sequence)
        } else {
            markOutputSequenceSkipped(sequence)
        }
        if data.count > acceptedCount {
            requestStop(with: ToolExecutionError.outputLimitExceeded(
                stream: stream,
                maximumBytes: maximum
            ))
        }
    }

    private func appendRetainedOutput(_ data: Data) {
        let maximum = command.maximumRetainedStandardOutputBytes
        guard maximum > 0, standardOutput.count < maximum else { return }
        standardOutput.append(data.prefix(maximum - standardOutput.count))
    }

    private func enqueueOutputDelivery(
        _ data: Data,
        stream: ToolOutputStream,
        sequence: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard let onOutput, stopError == nil else { return }
        pendingDeliveryBytes += data.count
        pendingDeliveryChunks += 1
        pendingOutputBySequence[sequence] = (stream, data)
        drainObservedOutput(onOutput: onOutput)
    }

    private func markOutputSequenceSkipped(_ sequence: UInt64) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        pendingOutputBySequence[sequence] = nil
        if sequence == nextDeliverySequence {
            nextDeliverySequence &+= 1
            while nextDeliverySequence < observedOutputSequence,
                  pendingOutputBySequence[nextDeliverySequence] == nil {
                nextDeliverySequence &+= 1
            }
        }
    }

    private func drainObservedOutput(onOutput: @escaping ToolProcessOutputHandler) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        while let pending = pendingOutputBySequence.removeValue(
            forKey: nextDeliverySequence
        ) {
            nextDeliverySequence &+= 1
            deliveryQueue.async { [self] in
                onOutput(pending.stream, pending.data)
                stateQueue.async { [self] in
                    pendingDeliveryBytes -= pending.data.count
                    pendingDeliveryChunks -= 1
                    tryFinalize()
                }
            }
        }
    }

    private func canEnqueueOutputDelivery(_ data: Data) -> Bool {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard onOutput != nil else { return true }
        return data.count <= maximumPendingOutputDeliveryBytes
            && pendingDeliveryBytes <= maximumPendingOutputDeliveryBytes - data.count
            && pendingDeliveryChunks < maximumPendingOutputDeliveryChunks
    }

    private func readerDidFinish(stream: ToolOutputStream) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if stream == .standardOutput { outputReadFinished = true }
        else { errorReadFinished = true }
        tryFinalize()
    }

    private func acceptInput(
        _ data: Data,
        continuation: CheckedContinuation<Void, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard inputAccepting, !inputClosed, finalResult == nil else {
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
        guard queuedInputBytes <= maximumQueuedStandardInputBytes - data.count else {
            continuation.resume(throwing: ToolProcessSessionError.queueOverflow(
                maximumBytes: maximumQueuedStandardInputBytes
            ))
            return
        }
        guard !data.isEmpty else {
            continuation.resume()
            return
        }
        queuedInputBytes += data.count
        outstandingInputOperations += 1
        scheduleInputWrite(data, continuation: continuation)
    }

    private func scheduleInitialInput(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !data.isEmpty else { return }
        queuedInputBytes += data.count
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(
                start,
                offsetBy: min(
                    ToolExecutionLimits.maximumStdinWriteBytes,
                    data.distance(from: start, to: data.endIndex)
                )
            )
            scheduleInputWrite(
                Data(data[start..<end]),
                continuation: nil,
                isOneShot: true
            )
            outstandingInputOperations += 1
            start = end
        }
    }

    private func scheduleInputWrite(
        _ data: Data,
        continuation: CheckedContinuation<Void, Error>?,
        isOneShot: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        inputWriterQueue.async { [self] in
            let failed: Bool
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
                failed = false
            } catch {
                failed = true
            }
            stateQueue.async { [self] in
                queuedInputBytes -= data.count
                outstandingInputOperations -= 1
                if failed {
                    inputAccepting = false
                    inputWriteError = inputWriteError ?? ToolProcessSessionError.closed
                    continuation?.resume(throwing: inputWriteError ?? ToolProcessSessionError.closed)
                    scheduleInputClose()
                    if isOneShot {
                        requestStop(with: ToolProcessRunnerError.standardInputWriteFailed)
                    }
                } else {
                    continuation?.resume()
                }
                tryFinalize()
            }
        }
    }

    private func scheduleInputClose() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !inputClosed, !inputCloseScheduled else { return }
        inputCloseScheduled = true
        inputAccepting = false
        inputWriterQueue.async { [self] in
            try? inputPipe.fileHandleForWriting.close()
            stateQueue.async { [self] in
                inputClosed = true
                let closeWaiters = inputCloseWaiters
                inputCloseWaiters.removeAll(keepingCapacity: false)
                if let inputWriteError {
                    closeWaiters.forEach { $0.resume(throwing: inputWriteError) }
                } else {
                    closeWaiters.forEach { $0.resume() }
                }
                tryFinalize()
            }
        }
    }

    private func scheduleTimeout() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard finalResult == nil, !processTerminationObserved else { return }
            // Resolve an exit already visible to waitpid before deciding that
            // this command exceeded its deadline. This runs on the same queue
            // as the process source and every signal decision.
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

        // Dispatch may not have delivered the process-source callback yet even
        // though the child is already waitable. Reap on this same serial queue
        // before publishing cancellation, which establishes one owner for
        // waitpid and prevents PID reuse or a double reap. A physical exit wins
        // over only a late cancellation. Output-limit and other I/O failures are
        // properties of the execution contract and retain their existing error
        // precedence even when discovered while draining an exited child.
        if processStarted, !processTerminationObserved {
            reapExitedProcessIfAvailable()
        }
        if stopError == nil, processTerminationObserved, isCancellationStop(error) {
            return
        }
        if stopError == nil { stopError = error }
        inputAccepting = false

        guard processStarted else {
            // `cancel()` may run before the queued launch block. Preserve the
            // stop reason; startOnStateQueue observes it and never launches.
            if launchContinuation != nil {
                finishBeforeLaunch(with: stopError ?? error)
            }
            return
        }
        scheduleInputClose()
        beginTerminationIfNeeded()
    }

    private func isCancellationStop(_ error: Error) -> Bool {
        (error as? ToolExecutionError) == .cancelled
    }

    private func beginTerminationIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !terminationStarted, !processGroupGone else { return }
        terminationStarted = true
        signalTarget(SIGTERM)
        scheduleGroupPollIfNeeded()

        let item = DispatchWorkItem { [weak self] in
            guard let self, finalResult == nil else { return }
            refreshTargetLiveness()
            guard !processGroupGone else {
                tryFinalize()
                return
            }
            signalTarget(SIGKILL)
            scheduleGroupPollIfNeeded()
        }
        forceKillWorkItem = item
        stateQueue.asyncAfter(
            deadline: .now() + command.gracefulTerminationTimeout,
            execute: item
        )
    }

    private func interruptOnStateQueue(
        continuation: CheckedContinuation<Void, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        reapExitedProcessIfAvailable()
        guard finalResult == nil,
              stopError == nil,
              processStarted,
              !processTerminationObserved,
              !terminationStarted,
              processIdentifier > 1 else {
            continuation.resume(throwing: ToolProcessSessionError.closed)
            return
        }
        let target = usesIsolatedProcessGroup
            ? -processIdentifier
            : processIdentifier
        if Darwin.kill(target, SIGINT) == 0 {
            continuation.resume()
        } else if errno == ESRCH {
            refreshTargetLiveness()
            continuation.resume(throwing: ToolProcessSessionError.closed)
        } else {
            continuation.resume(throwing: ToolProcessSessionError.interruptFailed)
        }
    }

    private func signalTarget(_ signal: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processIdentifier > 1 else { return }
        let target = usesIsolatedProcessGroup
            ? -processIdentifier
            : processIdentifier
        if Darwin.kill(target, signal) == -1, errno == ESRCH {
            if usesIsolatedProcessGroup {
                processGroupGone = true
            } else if processTerminationObserved {
                processGroupGone = true
            }
        }
    }

    private func processDidTerminate(waitStatus: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !processTerminationObserved else { return }
        processTerminationObserved = true
        terminationExitCode = Self.exitCode(fromWaitStatus: waitStatus)
        scheduleInputClose()
        refreshTargetLiveness()
        if usesIsolatedProcessGroup, !processGroupGone {
            // A successful group leader is not permission to orphan detached
            // descendants. Reap the rest of its original group as well.
            beginTerminationIfNeeded()
            scheduleGroupPollIfNeeded()
        }
        if processGroupGone {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }
        tryFinalize()
    }

    private func processWaitDidFail(errorCode: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard processStarted, !processTerminationObserved else { return }
        if stopError == nil {
            stopError = ToolProcessRunnerError.launchFailed(
                "waitpid: \(String(cString: strerror(errorCode))) "
                    + "(errno \(errorCode))"
            )
        }
        // ECHILD is the only expected terminal error for a valid blocking
        // wait. Treat the direct child as gone, but still tear down and prove
        // disappearance of an isolated descendant group.
        processTerminationObserved = true
        terminationExitCode = -1
        scheduleInputClose()
        refreshTargetLiveness()
        if usesIsolatedProcessGroup, !processGroupGone {
            beginTerminationIfNeeded()
            scheduleGroupPollIfNeeded()
        }
        tryFinalize()
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        // Darwin's WIFEXITED/WEXITSTATUS family are C macros and are not
        // consistently imported into Swift. waitpid without WUNTRACED yields
        // either a normal exit (low seven bits zero) or a terminating signal.
        let lowBits = status & 0x7f
        if lowBits == 0 { return (status >> 8) & 0xff }
        if lowBits != 0x7f { return lowBits }
        return -1
    }

    private func refreshTargetLiveness() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if !usesIsolatedProcessGroup {
            processGroupGone = processTerminationObserved
            return
        }
        guard processIdentifier > 1 else { return }
        if Darwin.kill(-processIdentifier, 0) == -1, errno == ESRCH {
            processGroupGone = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }
    }

    private func scheduleGroupPollIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard (!processTerminationObserved
                || (usesIsolatedProcessGroup && !processGroupGone)),
              groupPollWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            groupPollWorkItem = nil
            guard finalResult == nil else { return }
            refreshTargetLiveness()
            if processTerminationObserved, processGroupGone {
                tryFinalize()
            } else {
                scheduleGroupPollIfNeeded()
            }
        }
        groupPollWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    private func tryFinalize() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil,
              !finalizationScheduled,
              processTerminationObserved,
              processGroupGone,
              outputReadFinished,
              errorReadFinished,
              inputClosed,
              outstandingInputOperations == 0,
              pendingDeliveryChunks == 0 else { return }

        let result: ResultValue
        if let stopError {
            result = .failure(stopError)
        } else {
            result = .success(ToolProcessResult(
                standardOutput: standardOutput,
                standardError: standardError,
                exitCode: terminationExitCode ?? -1
            ))
        }
        finalizationScheduled = true
        if let onTermination {
            deliveryQueue.async { [self] in
                onTermination(result)
                stateQueue.async { [self] in finishFinalization(with: result) }
            }
        } else {
            finishFinalization(with: result)
        }
    }

    private func finishFinalization(with result: ResultValue) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard finalResult == nil else { return }
        timeoutWorkItem?.cancel()
        forceKillWorkItem?.cancel()
        groupPollWorkItem?.cancel()
        processExitSource?.cancel()
        timeoutWorkItem = nil
        forceKillWorkItem = nil
        groupPollWorkItem = nil
        processExitSource = nil
        finalResult = result

        let launch = launchContinuation
        launchContinuation = nil
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        cancelledWaiterIDs.removeAll(keepingCapacity: false)
        let closeWaiters = inputCloseWaiters
        inputCloseWaiters.removeAll(keepingCapacity: false)

        switch result {
        case let .success(value):
            launch?.resume()
            currentWaiters.values.forEach { $0.resume(returning: value) }
        case let .failure(error):
            launch?.resume(throwing: error)
            currentWaiters.values.forEach { $0.resume(throwing: error) }
        }
        if let inputWriteError {
            closeWaiters.forEach { $0.resume(throwing: inputWriteError) }
        } else {
            closeWaiters.forEach { $0.resume() }
        }
        onFinalized()
    }

    private func registerWaiter(
        id: UUID,
        continuation: CheckedContinuation<ToolProcessResult, Error>
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if cancelledWaiterIDs.remove(id) != nil {
            if cancellationShouldStopProcess {
                waiters[id] = continuation
                requestStop(with: ToolExecutionError.cancelled)
            } else {
                continuation.resume(throwing: CancellationError())
            }
            return
        }
        if let finalResult {
            switch finalResult {
            case let .success(value): continuation.resume(returning: value)
            case let .failure(error): continuation.resume(throwing: error)
            }
            return
        }
        waiters[id] = continuation
    }

    private func cancelWaiter(id: UUID) {
        stateQueue.async { [self] in
            guard finalResult == nil else { return }
            if cancellationShouldStopProcess {
                // One-shot run must not resume until process/group teardown,
                // so retain this waiter and complete it with `.cancelled`.
                if waiters[id] == nil { cancelledWaiterIDs.insert(id) }
                requestStop(with: ToolExecutionError.cancelled)
            } else if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume(throwing: CancellationError())
            } else {
                cancelledWaiterIDs.insert(id)
            }
        }
    }
}

/// Owns a null-terminated `char **` for the synchronous duration of spawn.
/// `strdup` avoids pointers into movable Swift string storage, and every
/// successfully allocated element is released even when a later one fails.
final class SpawnCStringVector {
    private var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) throws {
        var allocated: [UnsafeMutablePointer<CChar>?] = []
        allocated.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = Darwin.strdup(string) else {
                allocated.forEach { pointer in
                    if let pointer { Darwin.free(pointer) }
                }
                throw ToolProcessRunnerError.launchFailed(
                    "allocate spawn arguments: "
                        + "\(String(cString: strerror(ENOMEM))) "
                        + "(errno \(ENOMEM))"
                )
            }
            allocated.append(pointer)
        }
        allocated.append(nil)
        pointers = allocated
    }

    deinit {
        pointers.forEach { pointer in
            if let pointer { Darwin.free(pointer) }
        }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
