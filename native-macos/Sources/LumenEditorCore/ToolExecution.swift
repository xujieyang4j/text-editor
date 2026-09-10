import CryptoKit
import Foundation

/// The user-visible purpose of an external process. Purpose is part of the
/// approval identity: approving a formatter never approves the same command as
/// a build, terminal, or language server.
public enum ToolKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case build
    case buildCommand = "build-command"
    case buildSystem = "build-system"
    case git
    case terminal
    case languageTool = "language-tool"
    case languageServer = "language-server"
    case pluginWorker = "plugin-worker"
}

/// Limits shared by a future process broker and its UI. This module does not
/// start processes; keeping the limits beside the validated contract makes it
/// possible for every eventual transport to enforce the same boundaries.
public enum ToolExecutionLimits {
    // Project-setting limits mirror the Electron configuration boundary.
    public static let maximumExecutableUTF16CodeUnits = 1_000
    public static let maximumArguments = 50
    public static let maximumArgumentUTF16CodeUnits = 4_000
    public static let maximumWorkingDirectoryUTF16CodeUnits = 500
    public static let maximumEnvironmentVariables = 50
    public static let maximumInheritedEnvironmentVariables = 256
    public static let maximumEnvironmentKeyASCIICharacters = 100
    public static let maximumEnvironmentValueUTF16CodeUnits = 4_000

    // Output and input limits mirror the existing build/terminal boundaries.
    public static let maximumRetainedOutputCharacters = 1_000_000
    public static let maximumOutputChunkBytes = 256 * 1_024
    public static let maximumStdinWriteBytes = 64 * 1_024
    public static let maximumOneShotStdinBytes = 20 * 1_024 * 1_024
    public static let maximumStandardOutputBytes = 8 * 1_024 * 1_024
    public static let maximumStandardErrorBytes = 1 * 1_024 * 1_024

    // One-shot language tools and LSP initialization currently use 15 seconds.
    public static let oneShotTimeout: TimeInterval = 15
    public static let languageToolTimeout: TimeInterval = oneShotTimeout
    public static let languageServerInitializeTimeout: TimeInterval = 15
    public static let gracefulTerminationTimeout: TimeInterval = 0.5

    // LSP framing and back-pressure boundaries.
    public static let maximumLSPHeaderBytes = 16 * 1_024
    public static let maximumLSPPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumLSPStdinQueueBytes = 16 * 1_024 * 1_024

    // Short aliases for process-broker call sites.
    public static let maximumOutputCharacters = maximumRetainedOutputCharacters
    public static let maximumStdinBytes = maximumOneShotStdinBytes
    public static let executionTimeout = oneShotTimeout
    public static let maximumLSPQueueBytes = maximumLSPStdinQueueBytes
}

/// Resolves configured executable names without consulting the mutable child
/// environment's `PATH`. The application builds this allowlist from trusted
/// system locations or an explicit user selection; project settings cannot add
/// entries to it by themselves.
public struct ToolExecutableResolver: Equatable, Sendable {
    private let aliases: [String: URL]
    private let allowedURLs: Set<URL>
    public let shellExecutableURL: URL?

    /// A deliberately small system allowlist. Project-specific tools (for
    /// example a workspace's `node_modules/.bin` server) require an explicit
    /// resolver assembled after trusted UI has selected/approved the binary.
    public static let macOSSystem: ToolExecutableResolver = ToolExecutableResolver(
        validatedAliases: [
            "bash": URL(fileURLWithPath: "/bin/bash", isDirectory: false),
            "git": URL(fileURLWithPath: "/usr/bin/git", isDirectory: false),
            "sh": URL(fileURLWithPath: "/bin/sh", isDirectory: false),
            "xcrun": URL(fileURLWithPath: "/usr/bin/xcrun", isDirectory: false),
            "zsh": URL(fileURLWithPath: "/bin/zsh", isDirectory: false)
        ],
        shellExecutableURL: URL(fileURLWithPath: "/bin/sh", isDirectory: false)
    )

    public static let system = macOSSystem

    public init(
        allowedExecutables: [String: URL],
        shellExecutableURL: URL? = nil
    ) throws {
        var normalizedAliases: [String: URL] = [:]
        for (alias, url) in allowedExecutables {
            guard Self.validAlias(alias) else {
                throw ToolExecutionError.invalidExecutableAlias(alias)
            }
            normalizedAliases[alias] = try Self.normalizedExecutableURL(url)
        }
        let normalizedShell: URL?
        if let shellExecutableURL {
            normalizedShell = try Self.normalizedExecutableURL(shellExecutableURL)
        } else {
            normalizedShell = nil
        }
        let allowed = Set(normalizedAliases.values)
        if let normalizedShell, !allowed.contains(normalizedShell) {
            throw ToolExecutionError.shellExecutableNotAllowed(normalizedShell)
        }
        aliases = normalizedAliases
        allowedURLs = allowed
        self.shellExecutableURL = normalizedShell
    }

    private init(validatedAliases: [String: URL], shellExecutableURL: URL?) {
        let normalizedAliases = validatedAliases.mapValues {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        aliases = normalizedAliases
        allowedURLs = Set(normalizedAliases.values)
        self.shellExecutableURL = shellExecutableURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    public var allowedExecutableURLs: Set<URL> { allowedURLs }

    public func resolve(_ configuredExecutable: String) throws -> URL {
        try resolve(configuredExecutable, relativeTo: nil)
    }

    /// Resolve an explicit relative path against a validated working directory.
    /// The resulting canonical path must still be present in the fixed allowlist.
    public func resolve(
        _ configuredExecutable: String,
        relativeTo workingDirectory: URL
    ) throws -> URL {
        try resolve(configuredExecutable, relativeTo: Optional(workingDirectory))
    }

    private func resolve(
        _ configuredExecutable: String,
        relativeTo workingDirectory: URL?
    ) throws -> URL {
        let source = configuredExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ToolExecutionError.emptyExecutable }
        guard !source.utf8.contains(0) else {
            throw ToolExecutionError.executableContainsNull
        }
        guard source.utf16.count <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits else {
            throw ToolExecutionError.executableTooLong(
                maximumUTF16CodeUnits: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
            )
        }

        if (source as NSString).isAbsolutePath {
            let resolved = try Self.normalizedExecutableURL(
                URL(fileURLWithPath: source, isDirectory: false)
            )
            guard allowedURLs.contains(resolved) else {
                throw ToolExecutionError.executableNotAllowed(source)
            }
            return resolved
        }
        if source.contains("/") {
            guard let workingDirectory else {
                throw ToolExecutionError.relativeExecutablePathNotAllowed(source)
            }
            let resolved = try Self.normalizedExecutableURL(
                workingDirectory.appendingPathComponent(source, isDirectory: false)
            )
            guard allowedURLs.contains(resolved) else {
                throw ToolExecutionError.executableNotAllowed(source)
            }
            return resolved
        }
        guard let resolved = aliases[source] else {
            throw ToolExecutionError.executableNotAllowed(source)
        }
        return resolved
    }

    public func resolveShell() throws -> URL {
        guard let shellExecutableURL else {
            throw ToolExecutionError.shellExecutableUnavailable
        }
        return shellExecutableURL
    }

    private static func validAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty,
              alias.utf16.count <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits,
              !alias.contains("/"),
              !alias.contains("\0") else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-"
        )
        return alias.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func normalizedExecutableURL(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.host == nil || url.host?.isEmpty == true,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            throw ToolExecutionError.invalidExecutableURL(url)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return URL(fileURLWithPath: resolved.path, isDirectory: false)
    }
}

/// Builds an exact child environment instead of passing the app's complete
/// environment through implicitly. Explicit project values are validated and
/// included in the approval identity; inherited values use a conservative
/// allowlist and are bounded deterministically.
public enum ToolEnvironmentPolicy {
    public static func sanitizedEnvironment(
        inheriting inherited: [String: String] = [:],
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        let checkedOverrides = try validateOverrides(overrides)
        var result = checkedOverrides
        let remaining = max(
            0,
            ToolExecutionLimits.maximumInheritedEnvironmentVariables - result.count
        )
        let inheritedPairs = inherited
            .filter { key, value in
                safeInheritedKey(key)
                    && validKey(key)
                    && !isUnsafeKey(key)
                    && !value.utf8.contains(0)
                    && value.utf16.count <= ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
                    && checkedOverrides[key] == nil
            }
            .sorted { left, right in left.key < right.key }
            .prefix(remaining)
        for (key, value) in inheritedPairs { result[key] = value }
        return result
    }

    fileprivate static func validateOverrides(
        _ environment: [String: String]
    ) throws -> [String: String] {
        guard environment.count <= ToolExecutionLimits.maximumEnvironmentVariables else {
            throw ToolExecutionError.tooManyEnvironmentVariables(
                maximum: ToolExecutionLimits.maximumEnvironmentVariables
            )
        }
        for (key, value) in environment {
            guard validKey(key) else {
                throw ToolExecutionError.invalidEnvironmentKey(key)
            }
            guard !isUnsafeKey(key) else {
                throw ToolExecutionError.unsafeEnvironmentKey(key)
            }
            guard !value.utf8.contains(0) else {
                throw ToolExecutionError.environmentValueContainsNull(key: key)
            }
            guard value.utf16.count <= ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits else {
                throw ToolExecutionError.environmentValueTooLong(
                    key: key,
                    maximumUTF16CodeUnits: ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
                )
            }
        }
        return environment
    }

    private static func validKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty,
              bytes.count <= ToolExecutionLimits.maximumEnvironmentKeyASCIICharacters,
              isASCIIAlpha(bytes[0]) || bytes[0] == 0x5f else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlpha(byte) || (0x30...0x39).contains(byte) || byte == 0x5f
        }
    }

    private static func safeInheritedKey(_ key: String) -> Bool {
        switch key {
        case "COLORTERM", "DEVELOPER_DIR", "HOME", "LANG", "LOGNAME",
             "PATH", "SDKROOT", "SHELL", "SSH_AUTH_SOCK", "TERM",
             "TMPDIR", "USER":
            return true
        default:
            return key.hasPrefix("LC_")
        }
    }

    private static func isUnsafeKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return unsafeKeys.contains(normalized)
            || normalized.hasPrefix("DYLD_")
            || normalized.hasPrefix("__XPC_DYLD_")
            || normalized.hasPrefix("LD_")
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    /// Variables that cause a runtime, shell, or interpreter to load project-
    /// selected code before the approved executable's normal entry point.
    private static let unsafeKeys: Set<String> = [
        "BASH_ENV",
        "ENV",
        "GCONV_PATH",
        "JDK_JAVA_OPTIONS",
        "JAVA_TOOL_OPTIONS",
        "NODE_OPTIONS",
        "PERL5OPT",
        "PYTHONINSPECT",
        "PYTHONSTARTUP",
        "RUBYOPT",
        "_JAVA_OPTIONS"
    ]
}

public enum ToolExecutionError: Error, Equatable, LocalizedError, Sendable {
    case invalidExecutableAlias(String)
    case invalidExecutableURL(URL)
    case executableNotAllowed(String)
    case relativeExecutablePathNotAllowed(String)
    case shellExecutableNotAllowed(URL)
    case shellExecutableUnavailable
    case shellNotAllowed(kind: ToolKind)
    case shellArgumentsNotAllowed
    case invalidAuthorizedRoot(URL)
    case invalidWorkingDirectory(URL)
    case workingDirectoryOutsideAuthorizedRoot(root: URL, workingDirectory: URL)
    case workingDirectoryPathTooLong(maximumUTF16CodeUnits: Int)
    case emptyExecutable
    case executableContainsNull
    case executableTooLong(maximumUTF16CodeUnits: Int)
    case tooManyArguments(maximum: Int)
    case argumentContainsNull(index: Int)
    case argumentTooLong(index: Int, maximumUTF16CodeUnits: Int)
    case tooManyEnvironmentVariables(maximum: Int)
    case invalidEnvironmentKey(String)
    case unsafeEnvironmentKey(String)
    case environmentValueContainsNull(key: String)
    case environmentValueTooLong(key: String, maximumUTF16CodeUnits: Int)
    case invalidProcessLimits
    case standardInputTooLarge(actualBytes: Int, maximumBytes: Int)
    case timedOut(seconds: TimeInterval)
    case outputLimitExceeded(stream: ToolOutputStream, maximumBytes: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidExecutableAlias:
            return "An executable allowlist alias must be a simple command name."
        case .invalidExecutableURL:
            return "An allowlisted executable must be an absolute local file URL."
        case .executableNotAllowed:
            return "The configured executable is not in the trusted executable allowlist."
        case .relativeExecutablePathNotAllowed:
            return "Executable paths containing a slash must be absolute and explicitly allowlisted."
        case .shellExecutableNotAllowed:
            return "The fixed shell executable must also be in the executable allowlist."
        case .shellExecutableUnavailable:
            return "No fixed shell executable was configured for this execution policy."
        case let .shellNotAllowed(kind):
            return "The tool purpose ‘\(kind.rawValue)’ cannot execute through a shell."
        case .shellArgumentsNotAllowed:
            return "A shell command cannot receive project arguments; put trusted syntax in the approved command or execute argv directly."
        case .invalidAuthorizedRoot:
            return "An authorised tool root must be an absolute local file URL."
        case .invalidWorkingDirectory:
            return "A tool working directory must be an absolute local file URL."
        case .workingDirectoryOutsideAuthorizedRoot:
            return "A tool working directory must stay inside its authorised workspace root."
        case let .workingDirectoryPathTooLong(maximum):
            return "A tool working-directory setting may use at most \(maximum) UTF-16 code units."
        case .emptyExecutable:
            return "Configure a non-empty tool executable."
        case .executableContainsNull:
            return "A tool executable cannot contain a null byte."
        case let .executableTooLong(maximum):
            return "A tool executable may use at most \(maximum) UTF-16 code units."
        case let .tooManyArguments(maximum):
            return "A tool may have at most \(maximum) arguments."
        case let .argumentContainsNull(index):
            return "Tool argument \(index) cannot contain a null byte."
        case let .argumentTooLong(index, maximum):
            return "Tool argument \(index) may use at most \(maximum) UTF-16 code units."
        case let .tooManyEnvironmentVariables(maximum):
            return "A tool may add at most \(maximum) environment variables."
        case let .invalidEnvironmentKey(key):
            return "The tool environment key ‘\(key)’ is invalid."
        case let .unsafeEnvironmentKey(key):
            return "The tool environment key ‘\(key)’ can inject code into a child process and is not allowed."
        case let .environmentValueContainsNull(key):
            return "The value of tool environment key ‘\(key)’ cannot contain a null byte."
        case let .environmentValueTooLong(key, maximum):
            return "The value of tool environment key ‘\(key)’ may use at most \(maximum) UTF-16 code units."
        case .invalidProcessLimits:
            return "Tool process limits must be finite and greater than zero."
        case let .standardInputTooLarge(actualBytes, maximumBytes):
            return "Tool standard input uses \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        case let .timedOut(seconds):
            return "The tool did not finish within \(seconds) seconds."
        case let .outputLimitExceeded(stream, maximumBytes):
            return "Tool \(stream.rawValue) exceeded \(maximumBytes) bytes."
        case .cancelled:
            return "The tool operation was cancelled."
        }
    }
}

/// A SHA-256 identifier for every execution-affecting field. Approvals still
/// retain and compare the complete configuration so a hash collision cannot
/// turn a different configuration into an approved one.
public struct ToolExecutionIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    fileprivate init(digest: SHA256.Digest) {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        rawValue = "sha256:" + String(decoding: encoded, as: UTF8.self)
    }

    public var description: String { rawValue }
}

/// Immutable, normalized input to a future external-process service. Creating
/// this value validates configuration only and never starts a process.
public struct ToolExecutionConfiguration: Equatable, Sendable {
    public let kind: ToolKind
    public let executable: String
    public let args: [String]
    public let cwd: URL
    public let shell: Bool
    public let env: [String: String]
    public let root: URL
    public let executableURL: URL
    public let identity: ToolExecutionIdentity

    /// Validate an already-resolved cwd. A missing cwd means the authorised
    /// root, matching build, terminal, language-tool, and LSP behavior.
    public init(
        kind: ToolKind,
        executable: String,
        args: [String] = [],
        cwd: URL? = nil,
        shell: Bool = false,
        env: [String: String] = [:],
        inheritedEnvironment: [String: String] = [:],
        authorizedRoot: URL,
        resolver: ToolExecutableResolver = .system
    ) throws {
        let normalizedRoot = try Self.normalizeLocalFileURL(
            authorizedRoot,
            error: .invalidAuthorizedRoot(authorizedRoot)
        )
        let requestedCWD = cwd ?? normalizedRoot
        let normalizedCWD = try Self.normalizeLocalFileURL(
            requestedCWD,
            error: .invalidWorkingDirectory(requestedCWD)
        )
        guard Self.contains(normalizedRoot, normalizedCWD) else {
            throw ToolExecutionError.workingDirectoryOutsideAuthorizedRoot(
                root: normalizedRoot,
                workingDirectory: normalizedCWD
            )
        }

        let normalizedExecutable = try Self.normalizeExecutable(executable)
        let normalizedArguments = try Self.validate(arguments: args)
        if shell {
            let permitsShell: Bool = switch kind {
            case .build, .buildCommand, .buildSystem, .languageTool:
                true
            case .git, .terminal, .languageServer, .pluginWorker:
                false
            }
            guard permitsShell else {
                throw ToolExecutionError.shellNotAllowed(kind: kind)
            }
            guard normalizedArguments.isEmpty else {
                throw ToolExecutionError.shellArgumentsNotAllowed
            }
        }
        let normalizedEnvironment = try ToolEnvironmentPolicy.sanitizedEnvironment(
            inheriting: inheritedEnvironment,
            overrides: env
        )
        let resolvedExecutableURL = shell
            ? try resolver.resolveShell()
            : try resolver.resolve(normalizedExecutable, relativeTo: normalizedCWD)

        self.kind = kind
        self.executable = normalizedExecutable
        self.args = normalizedArguments
        self.cwd = normalizedCWD
        self.shell = shell
        self.env = normalizedEnvironment
        root = normalizedRoot
        executableURL = resolvedExecutableURL
        identity = Self.makeIdentity(
            kind: kind,
            executable: normalizedExecutable,
            executableURL: resolvedExecutableURL,
            args: normalizedArguments,
            cwd: normalizedCWD,
            shell: shell,
            env: normalizedEnvironment,
            root: normalizedRoot
        )
    }

    /// Resolve a project setting just as `path.resolve(root, workingDirectory)`
    /// does: relative values are rooted in the workspace and an empty value
    /// selects the root. Traversal and symlink escapes are rejected afterward.
    public init(
        kind: ToolKind,
        executable: String,
        args: [String] = [],
        workingDirectory: String?,
        shell: Bool = false,
        env: [String: String] = [:],
        inheritedEnvironment: [String: String] = [:],
        authorizedRoot: URL,
        resolver: ToolExecutableResolver = .system
    ) throws {
        let resolvedCWD: URL?
        if let workingDirectory, !workingDirectory.isEmpty {
            guard !workingDirectory.utf8.contains(0) else {
                throw ToolExecutionError.invalidWorkingDirectory(
                    URL(fileURLWithPath: workingDirectory, isDirectory: true)
                )
            }
            guard workingDirectory.utf16.count <= ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits else {
                throw ToolExecutionError.workingDirectoryPathTooLong(
                    maximumUTF16CodeUnits: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                )
            }
            if (workingDirectory as NSString).isAbsolutePath {
                resolvedCWD = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            } else {
                resolvedCWD = authorizedRoot.appendingPathComponent(
                    workingDirectory,
                    isDirectory: true
                )
            }
        } else {
            resolvedCWD = nil
        }
        try self.init(
            kind: kind,
            executable: executable,
            args: args,
            cwd: resolvedCWD,
            shell: shell,
            env: env,
            inheritedEnvironment: inheritedEnvironment,
            authorizedRoot: authorizedRoot,
            resolver: resolver
        )
    }

    /// Labels matching the build/project-settings vocabulary.
    public init(
        kind: ToolKind,
        root: URL,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        shell: Bool = false,
        environment: [String: String] = [:],
        inheritedEnvironment: [String: String] = [:],
        resolver: ToolExecutableResolver = .system
    ) throws {
        try self.init(
            kind: kind,
            executable: command,
            args: arguments,
            workingDirectory: workingDirectory,
            shell: shell,
            env: environment,
            inheritedEnvironment: inheritedEnvironment,
            authorizedRoot: root,
            resolver: resolver
        )
    }

    public var authorizedRoot: URL { root }
    public var arguments: [String] { args }
    public var workingDirectory: URL { cwd }
    public var usesShell: Bool { shell }
    public var environment: [String: String] { env }
    public var identityHash: String { identity.rawValue }

    /// Convert the approved configuration into a runner request. Direct tools
    /// receive argv unchanged. Shell mode uses one fixed shell and one `-c`
    /// source argument; it is permitted only for legacy shell-command kinds
    /// whose existing behavior is explicitly shell-based.
    public func makeCommand(
        standardInput: Data? = nil,
        limits: ToolProcessLimits = .default
    ) throws -> ToolCommand {
        guard limits.isValid else { throw ToolExecutionError.invalidProcessLimits }
        if let standardInput, standardInput.count > limits.maximumStandardInputBytes {
            throw ToolExecutionError.standardInputTooLarge(
                actualBytes: standardInput.count,
                maximumBytes: limits.maximumStandardInputBytes
            )
        }

        let commandArguments: [String]
        if shell {
            commandArguments = ["-c", executable]
        } else {
            commandArguments = args
        }

        return ToolCommand(
            executableURL: executableURL,
            arguments: commandArguments,
            workingDirectoryURL: cwd,
            environment: env,
            standardInput: standardInput,
            timeout: limits.timeout,
            maximumStandardInputBytes: limits.maximumStandardInputBytes,
            maximumStandardOutputBytes: limits.maximumStandardOutputBytes,
            maximumRetainedStandardOutputBytes: limits.maximumRetainedStandardOutputBytes,
            maximumStandardErrorBytes: limits.maximumStandardErrorBytes,
            gracefulTerminationTimeout: limits.gracefulTerminationTimeout,
            processGroupPolicy: limits.processGroupPolicy
        )
    }

    fileprivate static func normalizedRootForRelease(_ root: URL) throws -> URL {
        try normalizeLocalFileURL(root, error: .invalidAuthorizedRoot(root))
    }

    private static func normalizeExecutable(_ source: String) throws -> String {
        guard !source.utf8.contains(0) else {
            throw ToolExecutionError.executableContainsNull
        }
        guard source.utf16.count <= ToolExecutionLimits.maximumExecutableUTF16CodeUnits else {
            throw ToolExecutionError.executableTooLong(
                maximumUTF16CodeUnits: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
            )
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolExecutionError.emptyExecutable }
        return trimmed
    }

    private static func validate(arguments: [String]) throws -> [String] {
        guard arguments.count <= ToolExecutionLimits.maximumArguments else {
            throw ToolExecutionError.tooManyArguments(
                maximum: ToolExecutionLimits.maximumArguments
            )
        }
        for (index, argument) in arguments.enumerated() {
            guard !argument.utf8.contains(0) else {
                throw ToolExecutionError.argumentContainsNull(index: index)
            }
            guard argument.utf16.count <= ToolExecutionLimits.maximumArgumentUTF16CodeUnits else {
                throw ToolExecutionError.argumentTooLong(
                    index: index,
                    maximumUTF16CodeUnits: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
                )
            }
        }
        return arguments
    }

    private static func normalizeLocalFileURL(
        _ url: URL,
        error: ToolExecutionError
    ) throws -> URL {
        guard url.isFileURL,
              url.host == nil || url.host?.isEmpty == true,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            throw error
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix("/"), !resolved.path.utf8.contains(0) else {
            throw error
        }
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private static func makeIdentity(
        kind: ToolKind,
        executable: String,
        executableURL: URL,
        args: [String],
        cwd: URL,
        shell: Bool,
        env: [String: String],
        root: URL
    ) -> ToolExecutionIdentity {
        var canonical = CanonicalToolIdentityData()
        canonical.append("lumen-tool-execution-v1")
        canonical.append(kind.rawValue)
        canonical.append(root.path)
        canonical.append(executable)
        canonical.append(executableURL.path)
        canonical.append(UInt64(args.count))
        for argument in args { canonical.append(argument) }
        canonical.append(cwd.path)
        canonical.append(shell)
        let sortedEnvironment = env.sorted { left, right in left.key < right.key }
        canonical.append(UInt64(sortedEnvironment.count))
        for (key, value) in sortedEnvironment {
            canonical.append(key)
            canonical.append(value)
        }
        return ToolExecutionIdentity(digest: SHA256.hash(data: canonical.data))
    }
}

/// Per-command budgets and lifecycle policy. The shape deliberately overlaps
/// `GitCommand`: a future shared runner adapter can map executableURL, argv,
/// environment, stdin, timeout, and separate stdout/stderr caps mechanically.
public struct ToolProcessLimits: Equatable, Sendable {
    public static let `default` = ToolProcessLimits()

    public var timeout: TimeInterval
    public var maximumStandardInputBytes: Int
    public var maximumStandardOutputBytes: Int
    /// Bytes retained for the eventual process result. Streaming callbacks
    /// still receive every bounded chunk up to `maximumStandardOutputBytes`.
    public var maximumRetainedStandardOutputBytes: Int
    public var maximumStandardErrorBytes: Int
    public var gracefulTerminationTimeout: TimeInterval
    public var processGroupPolicy: ToolProcessGroupPolicy

    public init(
        timeout: TimeInterval = ToolExecutionLimits.oneShotTimeout,
        maximumStandardInputBytes: Int = ToolExecutionLimits.maximumOneShotStdinBytes,
        maximumStandardOutputBytes: Int = ToolExecutionLimits.maximumStandardOutputBytes,
        maximumRetainedStandardOutputBytes: Int? = nil,
        maximumStandardErrorBytes: Int = ToolExecutionLimits.maximumStandardErrorBytes,
        gracefulTerminationTimeout: TimeInterval = ToolExecutionLimits.gracefulTerminationTimeout,
        processGroupPolicy: ToolProcessGroupPolicy = .isolated
    ) {
        let retainedOutputLimit = maximumRetainedStandardOutputBytes
            ?? maximumStandardOutputBytes
        precondition(retainedOutputLimit >= 0)
        precondition(retainedOutputLimit <= maximumStandardOutputBytes)
        self.timeout = timeout
        self.maximumStandardInputBytes = maximumStandardInputBytes
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumRetainedStandardOutputBytes = retainedOutputLimit
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.gracefulTerminationTimeout = gracefulTerminationTimeout
        self.processGroupPolicy = processGroupPolicy
    }

    fileprivate var isValid: Bool {
        timeout > 0 && timeout.isFinite
            && gracefulTerminationTimeout >= 0 && gracefulTerminationTimeout.isFinite
            && maximumStandardInputBytes >= 0
            && maximumStandardOutputBytes > 0
            && maximumRetainedStandardOutputBytes >= 0
            && maximumRetainedStandardOutputBytes <= maximumStandardOutputBytes
            && maximumStandardErrorBytes > 0
    }
}

/// `.isolated` requires the eventual broker to create a process group and send
/// cancel/timeout termination to that group, followed by a forced kill after
/// `gracefulTerminationTimeout`. `.childOnly` is reserved for a trusted helper
/// that guarantees it cannot leave descendants behind.
public enum ToolProcessGroupPolicy: String, Codable, Equatable, Hashable, Sendable {
    case isolated
    case childOnly
}

public struct ToolCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let environment: [String: String]
    public let standardInput: Data?
    public let timeout: TimeInterval
    public let maximumStandardInputBytes: Int
    public let maximumStandardOutputBytes: Int
    public let maximumRetainedStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let gracefulTerminationTimeout: TimeInterval
    public let processGroupPolicy: ToolProcessGroupPolicy

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval,
        maximumStandardInputBytes: Int,
        maximumStandardOutputBytes: Int,
        maximumRetainedStandardOutputBytes: Int? = nil,
        maximumStandardErrorBytes: Int,
        gracefulTerminationTimeout: TimeInterval = ToolExecutionLimits.gracefulTerminationTimeout,
        processGroupPolicy: ToolProcessGroupPolicy = .isolated
    ) {
        let retainedOutputLimit = maximumRetainedStandardOutputBytes
            ?? maximumStandardOutputBytes
        precondition(retainedOutputLimit >= 0)
        precondition(retainedOutputLimit <= maximumStandardOutputBytes)
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.maximumStandardInputBytes = maximumStandardInputBytes
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumRetainedStandardOutputBytes = retainedOutputLimit
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.gracefulTerminationTimeout = gracefulTerminationTimeout
        self.processGroupPolicy = processGroupPolicy
    }

    public var maximumOutputBytes: Int { maximumStandardOutputBytes }
    public var maximumErrorBytes: Int { maximumStandardErrorBytes }
}

public struct ToolProcessResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitCode: Int32

    public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var stdout: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderr: String { String(decoding: standardError, as: UTF8.self) }
}

public enum ToolOutputStream: String, Codable, Equatable, Hashable, Sendable {
    case standardOutput
    case standardError
}

/// Injectable boundary for a future Foundation `Process` broker. Tests and
/// services can already consume commands without granting this Core module the
/// authority to launch anything. Cancellation is both task-local (`run`) and
/// explicit (`cancelAll`), matching `GitCommandRunning`.
public protocol ToolCommandRunning: Sendable {
    func run(_ command: ToolCommand) async throws -> ToolProcessResult
    func cancelAll() async
}

public extension ToolCommandRunning {
    func cancelAll() async {}
}

/// One ephemeral approval namespace. IDs are generated by trusted application
/// code and deliberately remain opaque; neither is read from project settings.
public struct ToolApprovalScope: Hashable, Sendable {
    public let windowID: String
    public let sessionID: String

    public init(windowID: String, sessionID: String) {
        self.windowID = windowID
        self.sessionID = sessionID
    }

    public init(windowID: UUID, sessionID: UUID) {
        self.init(
            windowID: windowID.uuidString.lowercased(),
            sessionID: sessionID.uuidString.lowercased()
        )
    }
}

public typealias ToolExecutionScope = ToolApprovalScope

public enum ToolApprovalState: Equatable, Sendable {
    case required
    case approved
}

/// In-memory, window/session-scoped trust. It is intentionally not Codable:
/// approval ends with a session and must never be restored from project data.
public actor ToolApprovalStore {
    private var approvals: [
        ToolApprovalScope: [ToolExecutionIdentity: ToolExecutionConfiguration]
    ] = [:]

    public init() {}

    public func state(
        for configuration: ToolExecutionConfiguration,
        in scope: ToolApprovalScope
    ) -> ToolApprovalState {
        isApproved(configuration, in: scope) ? .approved : .required
    }

    public func isApproved(
        _ configuration: ToolExecutionConfiguration,
        in scope: ToolApprovalScope
    ) -> Bool {
        approvals[scope]?[configuration.identity] == configuration
    }

    /// Record consent returned by trusted UI. Returns true only when this call
    /// adds or replaces a grant; repeated approval of the same value is idempotent.
    @discardableResult
    public func approve(
        _ configuration: ToolExecutionConfiguration,
        in scope: ToolApprovalScope
    ) -> Bool {
        if approvals[scope]?[configuration.identity] == configuration { return false }
        var scoped = approvals[scope] ?? [:]
        scoped[configuration.identity] = configuration
        approvals[scope] = scoped
        return true
    }

    @discardableResult
    public func revoke(
        _ configuration: ToolExecutionConfiguration,
        in scope: ToolApprovalScope
    ) -> Bool {
        guard approvals[scope]?[configuration.identity] == configuration else { return false }
        approvals[scope]?.removeValue(forKey: configuration.identity)
        removeScopeIfEmpty(scope)
        return true
    }

    /// Releasing a workspace capability also revokes every tool approval that
    /// depended on it in that exact window/session.
    @discardableResult
    public func releaseRoot(_ root: URL, in scope: ToolApprovalScope) throws -> Int {
        let normalized = try ToolExecutionConfiguration.normalizedRootForRelease(root)
        guard var scoped = approvals[scope] else { return 0 }
        let revoked = scoped.compactMap { identity, configuration in
            configuration.root == normalized ? identity : nil
        }
        for identity in revoked { scoped.removeValue(forKey: identity) }
        if scoped.isEmpty { approvals.removeValue(forKey: scope) }
        else { approvals[scope] = scoped }
        return revoked.count
    }

    /// Revoke a root from every session belonging to one window.
    @discardableResult
    public func releaseRoot(_ root: URL, fromWindow windowID: String) throws -> Int {
        let normalized = try ToolExecutionConfiguration.normalizedRootForRelease(root)
        var count = 0
        for scope in Array(approvals.keys) where scope.windowID == windowID {
            guard var scoped = approvals[scope] else { continue }
            let revoked = scoped.compactMap { identity, configuration in
                configuration.root == normalized ? identity : nil
            }
            for identity in revoked { scoped.removeValue(forKey: identity) }
            if scoped.isEmpty { approvals.removeValue(forKey: scope) }
            else { approvals[scope] = scoped }
            count += revoked.count
        }
        return count
    }

    /// Global form for application shutdown or a capability service that owns
    /// the root across windows.
    @discardableResult
    public func releaseRoot(_ root: URL) throws -> Int {
        let normalized = try ToolExecutionConfiguration.normalizedRootForRelease(root)
        var count = 0
        for scope in Array(approvals.keys) {
            guard var scoped = approvals[scope] else { continue }
            let revoked = scoped.compactMap { identity, configuration in
                configuration.root == normalized ? identity : nil
            }
            for identity in revoked { scoped.removeValue(forKey: identity) }
            if scoped.isEmpty { approvals.removeValue(forKey: scope) }
            else { approvals[scope] = scoped }
            count += revoked.count
        }
        return count
    }

    @discardableResult
    public func endSession(_ scope: ToolApprovalScope) -> Int {
        approvals.removeValue(forKey: scope)?.count ?? 0
    }

    @discardableResult
    public func closeWindow(_ windowID: String) -> Int {
        var count = 0
        for scope in Array(approvals.keys) where scope.windowID == windowID {
            count += approvals.removeValue(forKey: scope)?.count ?? 0
        }
        return count
    }

    @discardableResult
    public func revokeAll() -> Int {
        let count = approvals.values.reduce(0) { $0 + $1.count }
        approvals.removeAll(keepingCapacity: false)
        return count
    }

    public func approvalCount(in scope: ToolApprovalScope) -> Int {
        approvals[scope]?.count ?? 0
    }

    private func removeScopeIfEmpty(_ scope: ToolApprovalScope) {
        if approvals[scope]?.isEmpty == true { approvals.removeValue(forKey: scope) }
    }
}

/// Alternate name emphasizing that the store is the session trust model.
public typealias ToolSessionTrust = ToolApprovalStore

private struct CanonicalToolIdentityData {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func append(_ value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func append(_ value: Bool) {
        data.append(UInt8(value ? 1 : 0))
    }
}
