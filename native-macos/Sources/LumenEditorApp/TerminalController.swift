import Combine
import Foundation
import LumenEditorCore
#if canImport(Darwin)
import Darwin
#endif

/// A validated description of the shell supplied by the application shell.
///
/// The default follows the user's validated login-shell preference, then falls
/// back to the account database and known system shells. Alternate explicit
/// shells must be paired with a resolver which allowlists that executable.
/// The process owns a real controlling PTY. The current panel deliberately
/// advertises `TERM=dumb` because it presents an accessible plain-text log
/// rather than claiming ANSI cursor/color emulation it does not implement.
struct TerminalShellConfiguration: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var inheritedEnvironment: [String: String]
    private let trustedDefaultExecutableURL: URL?

    static let systemFallbackExecutables = ["/bin/sh", "/bin/bash", "/bin/zsh"]

    init(
        executable: String? = nil,
        arguments: [String] = ["-i"],
        environment: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        accountShell: String? = TerminalShellConfiguration.currentAccountLoginShell(),
        fallbackExecutables: [String] = TerminalShellConfiguration.systemFallbackExecutables,
        fileManager: FileManager = .default
    ) {
        let usesDefaultExecutable = executable == nil
        let resolvedExecutable: String
        if let executable {
            resolvedExecutable = executable
        } else {
            resolvedExecutable = Self.resolveDefaultExecutable(
                inheritedEnvironment: inheritedEnvironment,
                accountShell: accountShell,
                fallbackExecutables: fallbackExecutables,
                fileManager: fileManager
            )
        }
        self.executable = resolvedExecutable
        self.arguments = arguments
        var environment = environment
        environment["TERM"] = "dumb"
        if usesDefaultExecutable { environment["SHELL"] = resolvedExecutable }
        self.environment = environment
        self.inheritedEnvironment = inheritedEnvironment
        trustedDefaultExecutableURL = usesDefaultExecutable
            ? URL(fileURLWithPath: resolvedExecutable, isDirectory: false)
            : nil
    }

    func executionConfiguration(
        workspaceRoot: URL,
        resolver: ToolExecutableResolver? = nil
    ) throws -> ToolExecutionConfiguration {
        let effectiveResolver: ToolExecutableResolver
        if let resolver {
            effectiveResolver = resolver
        } else if let trustedDefaultExecutableURL {
            // The process environment and account database are application/user
            // inputs, not workspace configuration. After validating the selected
            // executable, authorize only its canonical path for this terminal.
            effectiveResolver = try ToolExecutableResolver(allowedExecutables: [
                "terminal-login-shell": trustedDefaultExecutableURL
            ])
        } else {
            effectiveResolver = .system
        }
        return try ToolExecutionConfiguration(
            kind: .terminal,
            executable: executable,
            args: arguments,
            cwd: workspaceRoot,
            env: environment,
            inheritedEnvironment: inheritedEnvironment,
            authorizedRoot: workspaceRoot,
            resolver: effectiveResolver
        )
    }

    static func resolveDefaultExecutable(
        inheritedEnvironment: [String: String],
        accountShell: String?,
        fallbackExecutables: [String] = systemFallbackExecutables,
        fileManager: FileManager = .default
    ) -> String {
        let preferred = [inheritedEnvironment["SHELL"], accountShell]
        for candidate in preferred {
            if let resolved = validatedShellExecutable(candidate, fileManager: fileManager) {
                return resolved
            }
        }
        for candidate in fallbackExecutables {
            if let resolved = validatedShellExecutable(candidate, fileManager: fileManager) {
                return resolved
            }
        }

        // `/bin/sh` is guaranteed by the supported macOS platform. Keeping one
        // constant last resort makes configuration failure deterministic even
        // if filesystem inspection is temporarily unavailable.
        return URL(fileURLWithPath: "/bin/sh", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func currentAccountLoginShell() -> String? {
#if os(macOS)
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
#else
        return nil
#endif
    }

    private static func validatedShellExecutable(
        _ candidate: String?,
        fileManager: FileManager
    ) -> String? {
        guard let candidate,
              !candidate.isEmpty,
              !candidate.utf8.contains(0),
              candidate.utf16.count <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits,
              candidate.rangeOfCharacter(from: .controlCharacters) == nil,
              (candidate as NSString).isAbsolutePath else {
            return nil
        }

        let resolved = URL(fileURLWithPath: candidate, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolved.path.utf16.count <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits,
              let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved.path
    }
}

/// Narrow interactive-session boundary used by the App target and its tests.
/// Production adapts `PseudoTerminalProcessSession`; embedders can inject a broker with
/// the same lifecycle guarantees without giving the SwiftUI view process APIs.
protocol TerminalProcessSessioning: Sendable {
    func write(_ data: Data) async throws
    func closeStandardInput() async throws
    func interrupt() async throws
    func resize(to size: PseudoTerminalSize) async throws
    func cancel()
    func waitForExit() async throws -> ToolProcessResult
}

extension PseudoTerminalProcessSession: TerminalProcessSessioning {}

protocol TerminalProcessRunning: Sendable {
    func start(
        _ command: ToolCommand,
        size: PseudoTerminalSize,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any TerminalProcessSessioning
}

struct TerminalProcessRunnerAdapter: TerminalProcessRunning {
    private let runner: PseudoTerminalProcessRunner

    init(runner: PseudoTerminalProcessRunner = PseudoTerminalProcessRunner()) {
        self.runner = runner
    }

    func start(
        _ command: ToolCommand,
        size: PseudoTerminalSize,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> any TerminalProcessSessioning {
        try await runner.start(command, size: size, onOutput: onOutput)
    }
}

enum TerminalControllerState: Equatable, Sendable {
    case idle
    case awaitingApproval
    case starting(sessionID: String)
    case running(sessionID: String)
    case stopping
}

struct TerminalApprovalRequest: Identifiable, Equatable, Sendable {
    var id: ToolExecutionIdentity { configuration.identity }
    let configuration: ToolExecutionConfiguration

    var commandDescription: String {
        ([configuration.executable] + configuration.args).joined(separator: " ")
    }

    /// Human-readable expansion of every execution-affecting identity field.
    /// The digest is included for audit/debugging, but approval is still stored
    /// against and compared with the complete normalized configuration.
    var identityDescription: String {
        let environment = configuration.env
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return [
            "Purpose: \(configuration.kind.rawValue)",
            "Workspace: \(configuration.root.path)",
            "Command: \(commandDescription)",
            "Working directory: \(configuration.cwd.path)",
            "Uses shell command parsing: \(configuration.shell ? "yes" : "no")",
            environment.isEmpty ? "Environment: none" : "Environment:\n\(environment)",
            "Identity: \(configuration.identity.rawValue)"
        ].joined(separator: "\n")
    }
}

struct TerminalLogEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case standardOutput
        case standardError
        case status
    }

    /// Keeps application-authored status separate from process output. Shell
    /// output must always remain verbatim, while status can be rendered again
    /// when the runtime locale changes.
    enum Content: Equatable, Sendable {
        case verbatim(String)
        case exitStatus(code: Int32)
    }

    let id: UUID
    let sessionID: String
    let kind: Kind
    let content: Content

    /// Stable English rendering retained for diagnostics and existing
    /// controller-only consumers. User-visible presentation must call
    /// `text(locale:)` with the current runtime locale.
    var text: String { text(locale: .enUS) }

    init(id: UUID = UUID(), sessionID: String, kind: Kind, text: String) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.content = .verbatim(text)
    }

    init(id: UUID = UUID(), sessionID: String, exitCode: Int32) {
        self.id = id
        self.sessionID = sessionID
        self.kind = .status
        self.content = .exitStatus(code: exitCode)
    }

    func text(locale: EditorLocale) -> String {
        switch content {
        case let .verbatim(text):
            return text
        case let .exitStatus(code):
            return locale.localizedApp(.terminalExited(code: code)) + "\n"
        }
    }

    /// Count the longest supported rendering so the retained-output bound
    /// remains true after a locale switch.
    var retainedUTF16Count: Int {
        switch content {
        case let .verbatim(text):
            return text.utf16.count
        case .exitStatus:
            return max(text(locale: .enUS).utf16.count, text(locale: .zhCN).utf16.count)
        }
    }
}

struct TerminalPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case noWorkspaceOpen
        case notRunning
        case invalidInput
        case inputFailed
        case interruptFailed
        case couldNotStart
        case sessionEnded
        case invalidConfiguration
        case verbatim(String)
    }

    enum Message: Equatable, Sendable {
        case openWorkspaceBeforeStarting
        case startBeforeSendingInput
        case inputByteLimit(maximum: Int)
        case inputDeliveryFailed
        case interruptDeliveryFailed
        case approvedShellCouldNotStart
        case processEndedUnexpectedly
        case invalidOrUntrustedConfiguration
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English compatibility for command routing and controller tests.
    /// SwiftUI renders the typed payload again with its current locale.
    var title: String {
        EditorLocale.enUS.localizedTerminalIssueTitle(titleContent)
    }

    var message: String {
        EditorLocale.enUS.localizedTerminalIssue(content)
    }

    init(id: UUID = UUID(), title: Title, message: Message) {
        self.id = id
        titleContent = title
        content = message
    }
}

/// Main-actor state and lifecycle owner for the PTY-backed project shell.
/// No process is started until the exact normalized execution configuration is
/// present in the injected, ephemeral `ToolApprovalStore`.
@MainActor
final class TerminalController: ObservableObject {
    typealias MakeSessionID = @MainActor () -> String

    static let maximumLogCharacters = ToolExecutionLimits.maximumRetainedOutputCharacters

    @Published var input = ""
    @Published private(set) var workspaceRoot: URL?
    @Published private(set) var state: TerminalControllerState = .idle
    @Published private(set) var logEntries: [TerminalLogEntry] = []
    @Published private(set) var pendingApproval: TerminalApprovalRequest?
    @Published private(set) var issue: TerminalPresentationIssue?
    @Published private(set) var wasOutputTruncated = false
    @Published private(set) var lastExitCode: Int32?

    private let runner: any TerminalProcessRunning
    private let approvals: ToolApprovalStore
    private let scope: ToolApprovalScope
    private let shell: TerminalShellConfiguration
    private let resolver: ToolExecutableResolver?
    private let makeSessionID: MakeSessionID
    private let sessionTimeout: TimeInterval

    private var pendingConfiguration: ToolExecutionConfiguration?
    private var session: (any TerminalProcessSessioning)?
    private var launchTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// Orders asynchronous workspace changes independently of process output.
    /// SwiftUI may cancel an older `.task(id:)` while `stop()` is suspended;
    /// only the newest request may publish its root after teardown completes.
    private var workspaceUpdateGeneration: UInt64 = 0
    private var outputSessionID: String?
    private var retainedCharacterCount = 0
    private var currentOutputDecoder: TerminalUTF8OutputDecoder?
    private var terminalSize = PseudoTerminalSize.default

    init(
        workspaceRoot: URL? = nil,
        runner: any TerminalProcessRunning = TerminalProcessRunnerAdapter(),
        approvals: ToolApprovalStore = ToolApprovalStore(),
        scope: ToolApprovalScope = ToolApprovalScope(windowID: UUID(), sessionID: UUID()),
        shell: TerminalShellConfiguration = TerminalShellConfiguration(),
        resolver: ToolExecutableResolver? = nil,
        sessionTimeout: TimeInterval = 30 * 24 * 60 * 60,
        makeSessionID: @escaping MakeSessionID = {
            "terminal-" + UUID().uuidString.lowercased()
        }
    ) {
        precondition(sessionTimeout > 0 && sessionTimeout.isFinite)
        self.workspaceRoot = workspaceRoot
        self.runner = runner
        self.approvals = approvals
        self.scope = scope
        self.shell = shell
        self.resolver = resolver
        self.sessionTimeout = sessionTimeout
        self.makeSessionID = makeSessionID
    }

    var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isStopping: Bool { state == .stopping }

    var canStart: Bool { workspaceRoot != nil && state == .idle }

    var canStop: Bool {
        switch state {
        case .starting, .running: true
        case .idle, .awaitingApproval, .stopping: false
        }
    }

    var activeSessionID: String? {
        switch state {
        case let .starting(sessionID), let .running(sessionID): sessionID
        case .idle, .awaitingApproval, .stopping: nil
        }
    }

    var outputText: String { outputText(locale: .enUS) }

    func outputText(locale: EditorLocale) -> String {
        logEntries.map { $0.text(locale: locale) }.joined()
    }

    /// The composition shell should call this with the primary capability root.
    /// Switching or removing the root fully tears down the previous process.
    func updateWorkspaceRoot(_ root: URL?) async {
        workspaceUpdateGeneration &+= 1
        let requestGeneration = workspaceUpdateGeneration
        guard root != workspaceRoot || stopTask != nil else { return }
        await stop()
        guard requestGeneration == workspaceUpdateGeneration, !Task.isCancelled else {
            return
        }
        workspaceRoot = root
        pendingConfiguration = nil
        pendingApproval = nil
        outputSessionID = nil
        state = .idle
    }

    func requestStart() async {
        guard state == .idle else { return }
        guard let root = workspaceRoot else {
            issue = TerminalPresentationIssue(
                title: .noWorkspaceOpen,
                message: .openWorkspaceBeforeStarting
            )
            return
        }

        do {
            let configuration = try shell.executionConfiguration(
                workspaceRoot: root, resolver: resolver
            )
            issue = nil
            pendingConfiguration = configuration
            pendingApproval = TerminalApprovalRequest(configuration: configuration)
            state = .awaitingApproval
            if await approvals.isApproved(configuration, in: scope) {
                guard pendingConfiguration == configuration,
                      pendingApproval?.configuration == configuration,
                      state == .awaitingApproval else { return }
                pendingConfiguration = nil
                pendingApproval = nil
                state = .idle
                await start(configuration)
            }
        } catch {
            presentConfigurationError(error)
        }
    }

    func confirmPendingStart() async {
        guard state == .awaitingApproval,
              let configuration = pendingConfiguration,
              pendingApproval?.configuration == configuration else { return }
        _ = await approvals.approve(configuration, in: scope)
        // The workspace or dialog may change while the actor call suspends.
        // Approval may remain recorded for its exact identity, but it must not
        // cause an obsolete shell request to launch.
        guard state == .awaitingApproval,
              pendingConfiguration == configuration,
              pendingApproval?.configuration == configuration,
              workspaceRoot == configuration.root else { return }
        pendingConfiguration = nil
        pendingApproval = nil
        outputSessionID = nil
        state = .idle
        await start(configuration)
    }

    func declinePendingStart() {
        guard state == .awaitingApproval else { return }
        pendingConfiguration = nil
        pendingApproval = nil
        state = .idle
    }

    /// Submit one line through the PTY. An empty line is a real Return; Ctrl-C
    /// is exposed separately and follows the terminal's foreground job.
    func submitInput() async {
        let value = input
        input = ""
        await sendLine(value)
    }

    func sendLine(_ line: String) async {
        await write(Data((line + "\n").utf8))
    }

    func resize(columns: Int, rows: Int) async {
        guard let size = try? PseudoTerminalSize(columns: columns, rows: rows) else { return }
        terminalSize = size
        guard case let .running(sessionID) = state, let session else { return }
        let currentGeneration = generation
        do {
            try await session.resize(to: size)
        } catch {
            guard isCurrent(currentGeneration, sessionID: sessionID) else { return }
            // Resize failure does not invalidate a live shell. The next input
            // and output operation remains usable at the previous size.
        }
    }

    func sendInterrupt() async {
        guard case let .running(sessionID) = state, let session else {
            issue = TerminalPresentationIssue(
                title: .notRunning,
                message: .startBeforeSendingInput
            )
            return
        }
        let currentGeneration = generation
        do {
            try await session.interrupt()
        } catch {
            guard isCurrent(currentGeneration, sessionID: sessionID) else { return }
            issue = TerminalPresentationIssue(
                title: .interruptFailed,
                message: .interruptDeliveryFailed
            )
            await stop()
        }
    }

    /// Clear local identity before awaiting teardown so every late callback is
    /// rejected. `waitForExit` then guarantees process-group cleanup is done.
    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let hadActiveWork = state != .idle && state != .awaitingApproval
        generation &+= 1
        pendingConfiguration = nil
        pendingApproval = nil
        outputSessionID = nil
        currentOutputDecoder = nil

        let launching = launchTask
        launchTask = nil
        launching?.cancel()

        let runningSession = session
        session = nil
        let waiter = waitTask
        waitTask = nil
        waiter?.cancel()

        state = hadActiveWork ? .stopping : .idle
        let cleanup = Task {
            runningSession?.cancel()
            if let runningSession {
                _ = try? await runningSession.waitForExit()
            }
            await launching?.value
            await waiter?.value
        }
        stopTask = cleanup
        await cleanup.value
        stopTask = nil
        state = .idle
    }

    /// Panel/window owners should await this before discarding the controller.
    func close() async {
        await stop()
    }

    func clearOutput() {
        logEntries = []
        retainedCharacterCount = 0
        wasOutputTruncated = false
        lastExitCode = nil
    }

    func dismissIssue() { issue = nil }

    private func start(_ configuration: ToolExecutionConfiguration) async {
        guard state == .idle else { return }
        generation &+= 1
        let currentGeneration = generation
        let sessionID = makeSessionID()
        let outputDecoder = TerminalUTF8OutputDecoder()
        currentOutputDecoder = outputDecoder
        clearOutput()
        outputSessionID = sessionID
        state = .starting(sessionID: sessionID)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let command = try configuration.makeCommand(limits: ToolProcessLimits(
                    timeout: sessionTimeout,
                    maximumStandardOutputBytes: ToolExecutionLimits.maximumStandardOutputBytes,
                    maximumStandardErrorBytes: ToolExecutionLimits.maximumStandardErrorBytes
                ))
                let started = try await runner.start(
                    command, size: terminalSize
                ) { [weak self] stream, data in
                    guard let event = outputDecoder.decode(data, stream: stream) else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.isCurrent(
                                currentGeneration, sessionID: sessionID
                              ) else { return }
                        self.append(
                            event.text, stream: event.stream, sessionID: sessionID,
                            generation: currentGeneration
                        )
                        outputDecoder.acknowledge(event.id)
                    }
                }
                guard isCurrent(currentGeneration, sessionID: sessionID) else {
                    started.cancel()
                    _ = try? await started.waitForExit()
                    return
                }
                // A panel resize may have occurred while forkpty/exec was in
                // flight. Publish the newest viewport before accepting input.
                try? await started.resize(to: terminalSize)
                session = started
                state = .running(sessionID: sessionID)
                observeExit(of: started, sessionID: sessionID, generation: currentGeneration)
            } catch is CancellationError {
                finishFailedStart(generation: currentGeneration, sessionID: sessionID, error: nil)
            } catch ToolExecutionError.cancelled {
                finishFailedStart(generation: currentGeneration, sessionID: sessionID, error: nil)
            } catch {
                finishFailedStart(generation: currentGeneration, sessionID: sessionID, error: error)
            }
        }
        launchTask = task
        await task.value
        if isCurrent(currentGeneration, sessionID: sessionID) { launchTask = nil }
    }

    private func observeExit(
        of session: any TerminalProcessSessioning,
        sessionID: String,
        generation: UInt64
    ) {
        waitTask = Task { @MainActor [weak self] in
            do {
                let result = try await session.waitForExit()
                self?.finishSession(
                    sessionID: sessionID, generation: generation, result: result
                )
            } catch is CancellationError {
                return
            } catch ToolExecutionError.cancelled {
                return
            } catch {
                self?.finishSession(
                    sessionID: sessionID, generation: generation, error: error
                )
            }
        }
    }

    private func write(_ data: Data) async {
        guard case let .running(sessionID) = state, let session else {
            issue = TerminalPresentationIssue(
                title: .notRunning,
                message: .startBeforeSendingInput
            )
            return
        }
        guard !data.isEmpty, data.count <= ToolExecutionLimits.maximumStdinWriteBytes else {
            issue = TerminalPresentationIssue(
                title: .invalidInput,
                message: .inputByteLimit(
                    maximum: ToolExecutionLimits.maximumStdinWriteBytes
                )
            )
            return
        }
        let currentGeneration = generation
        do {
            try await session.write(data)
        } catch {
            guard isCurrent(currentGeneration, sessionID: sessionID) else { return }
            issue = TerminalPresentationIssue(
                title: .inputFailed,
                message: .inputDeliveryFailed
            )
            await stop()
        }
    }

    private func append(
        _ text: String,
        stream: ToolOutputStream,
        sessionID: String,
        generation: UInt64
    ) {
        guard isCurrent(generation, sessionID: sessionID) else { return }
        let kind: TerminalLogEntry.Kind = stream == .standardError
            ? .standardError
            : .standardOutput
        appendEntry(TerminalLogEntry(sessionID: sessionID, kind: kind, text: text))
    }

    private func appendEntry(_ entry: TerminalLogEntry) {
        logEntries.append(entry)
        retainedCharacterCount += entry.retainedUTF16Count
        trimLogIfNeeded()
    }

    private func trimLogIfNeeded() {
        var excess = retainedCharacterCount - Self.maximumLogCharacters
        guard excess > 0 else { return }
        wasOutputTruncated = true
        while excess > 0, let first = logEntries.first {
            let count = first.retainedUTF16Count
            if count <= excess || first.kind == .status {
                logEntries.removeFirst()
                retainedCharacterCount -= count
                excess = max(0, retainedCharacterCount - Self.maximumLogCharacters)
            } else {
                guard case let .verbatim(text) = first.content else {
                    // Future structured entries are kept atomic for the same
                    // reason as exit status: never retain a translated fragment.
                    logEntries.removeFirst()
                    retainedCharacterCount -= count
                    excess = max(0, retainedCharacterCount - Self.maximumLogCharacters)
                    continue
                }
                let retained = Self.droppingLeadingUTF16CodeUnits(
                    from: text, count: excess
                )
                logEntries[0] = TerminalLogEntry(
                    id: first.id, sessionID: first.sessionID, kind: first.kind, text: retained
                )
                retainedCharacterCount -= excess
                excess = 0
            }
        }
    }

    private static func droppingLeadingUTF16CodeUnits(
        from text: String, count: Int
    ) -> String {
        guard count > 0 else { return text }
        let utf16 = text.utf16
        guard count < utf16.count else { return "" }
        var start = utf16.index(utf16.startIndex, offsetBy: count)
        if start > utf16.startIndex, start < utf16.endIndex {
            let previous = utf16[utf16.index(before: start)]
            let current = utf16[start]
            if (0xD800...0xDBFF).contains(previous),
               (0xDC00...0xDFFF).contains(current) {
                start = utf16.index(after: start)
            }
        }
        return String(decoding: utf16[start...], as: UTF16.self)
    }

    private func finishFailedStart(
        generation: UInt64,
        sessionID: String,
        error: (any Error)?
    ) {
        guard isCurrent(generation, sessionID: sessionID) else { return }
        session = nil
        currentOutputDecoder = nil
        state = .idle
        outputSessionID = nil
        if error != nil {
            issue = TerminalPresentationIssue(
                title: .couldNotStart,
                message: .approvedShellCouldNotStart
            )
        }
    }

    private func finishSession(
        sessionID: String,
        generation: UInt64,
        result: ToolProcessResult
    ) {
        guard isCurrent(generation, sessionID: sessionID) else { return }
        appendDecoderRemainder(
            sessionID: sessionID, generation: generation
        )
        lastExitCode = result.exitCode
        appendEntry(TerminalLogEntry(sessionID: sessionID, exitCode: result.exitCode))
        session = nil
        waitTask = nil
        outputSessionID = nil
        state = .idle
    }

    private func finishSession(
        sessionID: String,
        generation: UInt64,
        error: any Error
    ) {
        guard isCurrent(generation, sessionID: sessionID) else { return }
        appendDecoderRemainder(
            sessionID: sessionID, generation: generation
        )
        session = nil
        waitTask = nil
        outputSessionID = nil
        state = .idle
        issue = TerminalPresentationIssue(
            title: .sessionEnded,
            message: .processEndedUnexpectedly
        )
    }

    private func appendDecoderRemainder(sessionID: String, generation: UInt64) {
        let pending = currentOutputDecoder?.finish() ?? []
        currentOutputDecoder = nil
        for event in pending {
            append(
                event.text, stream: event.stream, sessionID: sessionID,
                generation: generation
            )
        }
    }

    private func isCurrent(_ candidate: UInt64, sessionID: String) -> Bool {
        candidate == generation && outputSessionID == sessionID
    }

    private func presentConfigurationError(_ error: any Error) {
        issue = TerminalPresentationIssue(
            title: .invalidConfiguration,
            message: .invalidOrUntrustedConfiguration
        )
        pendingConfiguration = nil
        pendingApproval = nil
        state = .idle
    }
}

/// Streaming UTF-8 decoder for the single merged PTY output stream. It keeps
/// only a potentially valid incomplete scalar (at most three bytes); invalid
/// bytes retain `String(decoding:)` replacement behavior.
private final class TerminalUTF8OutputDecoder: @unchecked Sendable {
    struct Event: Sendable {
        let id: UInt64
        let stream: ToolOutputStream
        let text: String
    }

    private let lock = NSLock()
    private var trailingBytes: [UInt8] = []
    private var trailingStream: ToolOutputStream = .standardOutput
    private var nextID: UInt64 = 0
    private var pendingEvents: [Event] = []

    func decode(_ data: Data, stream: ToolOutputStream) -> Event? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if trailingBytes.isEmpty { trailingStream = stream }
        var bytes = trailingBytes
        bytes.append(contentsOf: data)
        let trailingCount = Self.incompleteSuffixCount(in: bytes)
        let decodedEnd = bytes.count - trailingCount
        let text = String(decoding: bytes[..<decodedEnd], as: UTF8.self)
        trailingBytes = trailingCount == 0 ? [] : Array(bytes[decodedEnd...])
        guard !text.isEmpty else { return nil }
        let event = Event(id: nextID, stream: stream, text: text)
        nextID &+= 1
        pendingEvents.append(event)
        return event
    }

    func acknowledge(_ id: UInt64) {
        lock.lock()
        pendingEvents.removeAll { $0.id == id }
        lock.unlock()
    }

    func finish() -> [Event] {
        lock.lock()
        defer {
            trailingBytes.removeAll(keepingCapacity: false)
            pendingEvents.removeAll(keepingCapacity: false)
            lock.unlock()
        }
        if !trailingBytes.isEmpty {
            pendingEvents.append(Event(
                id: nextID, stream: trailingStream,
                text: String(decoding: trailingBytes, as: UTF8.self)
            ))
            nextID &+= 1
        }
        return pendingEvents
    }

    private static func incompleteSuffixCount(in bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        for start in max(0, bytes.count - 3) ..< bytes.count {
            guard let expected = sequenceLength(for: bytes[start]) else { continue }
            let available = bytes.count - start
            guard available < expected else { continue }
            let continuationBytes = bytes[(start + 1)...]
            if continuationBytes.allSatisfy({ ($0 & 0xC0) == 0x80 }) {
                return available
            }
        }
        return 0
    }

    private static func sequenceLength(for byte: UInt8) -> Int? {
        switch byte {
        case 0xC2 ... 0xDF: 2
        case 0xE0 ... 0xEF: 3
        case 0xF0 ... 0xF4: 4
        default: nil
        }
    }
}
