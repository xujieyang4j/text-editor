@preconcurrency import Foundation

// MARK: - Renderer-compatible Git DTOs

public struct GitStatusEntry: Codable, Equatable, Sendable {
    public let path: String
    public let indexStatus: String
    public let worktreeStatus: String

    public init(path: String, indexStatus: String, worktreeStatus: String) {
        self.path = path
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }
}

public struct GitRemote: Codable, Equatable, Sendable {
    public let name: String
    public var fetchUrl: String?
    public var pushUrl: String?

    /// Swift-spelling conveniences. Coding continues to use the Electron DTO
    /// keys `fetchUrl` and `pushUrl`.
    public var fetchURL: String? { fetchUrl }
    public var pushURL: String? { pushUrl }

    public init(name: String, fetchUrl: String? = nil, pushUrl: String? = nil) {
        self.name = name
        self.fetchUrl = fetchUrl
        self.pushUrl = pushUrl
    }
}

public struct GitTrackingStatus: Codable, Equatable, Sendable {
    public let upstream: String?
    public let remote: String?
    public let remoteBranch: String?
    public let ahead: Int?
    public let behind: Int?

    public init(
        upstream: String? = nil,
        remote: String? = nil,
        remoteBranch: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil
    ) {
        self.upstream = upstream
        self.remote = remote
        self.remoteBranch = remoteBranch
        self.ahead = ahead
        self.behind = behind
    }
}

public struct GitStatus: Codable, Equatable, Sendable {
    public let available: Bool
    public let branch: String?
    public let entries: [GitStatusEntry]
    public let tracking: GitTrackingStatus?
    public let remotes: [GitRemote]?

    public init(
        available: Bool,
        branch: String? = nil,
        entries: [GitStatusEntry],
        tracking: GitTrackingStatus? = nil,
        remotes: [GitRemote]? = nil
    ) {
        self.available = available
        self.branch = branch
        self.entries = entries
        self.tracking = tracking
        self.remotes = remotes
    }
}

public struct GitDiff: Codable, Equatable, Sendable {
    public let path: String
    public let diff: String

    public init(path: String, diff: String) {
        self.path = path
        self.diff = diff
    }
}

public struct GitHunk: Codable, Equatable, Sendable {
    public let path: String
    public let header: String
    public let patch: String

    public init(path: String, header: String, patch: String) {
        self.path = path
        self.header = header
        self.patch = patch
    }
}

public struct GitHistoryEntry: Codable, Equatable, Sendable {
    public let id: String
    public let shortId: String
    public let author: String
    public let date: String
    public let subject: String

    public init(id: String, shortId: String, author: String, date: String, subject: String) {
        self.id = id
        self.shortId = shortId
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// The Electron IPC returns blame as a bare string. This path-bearing wrapper
/// is useful to native callers that may have more than one request in flight.
public struct GitBlame: Codable, Equatable, Sendable {
    public let path: String
    public let blame: String

    public init(path: String, blame: String) {
        self.path = path
        self.blame = blame
    }
}

public struct GitConflict: Codable, Equatable, Sendable {
    public let path: String
    public let ours: String?
    public let theirs: String?

    public init(path: String, ours: String? = nil, theirs: String? = nil) {
        self.path = path
        self.ours = ours
        self.theirs = theirs
    }
}

public enum GitConflictSide: String, Codable, CaseIterable, Equatable, Sendable {
    case ours
    case theirs

    fileprivate var stageNumber: String {
        switch self {
        case .ours: return "2"
        case .theirs: return "3"
        }
    }
}

public enum GitAction: String, Codable, CaseIterable, Equatable, Sendable {
    case stage
    case unstage
    case discard
    case stageHunk = "stage-hunk"
    case discardHunk = "discard-hunk"
    case commit
    case checkoutBranch = "checkout-branch"
    case createBranch = "create-branch"
}

public struct GitActionRequest: Codable, Equatable, Sendable {
    public let root: String
    public let action: GitAction
    public let paths: [String]?
    public let message: String?
    public let branch: String?
    public let patch: String?

    public init(
        root: String,
        action: GitAction,
        paths: [String]? = nil,
        message: String? = nil,
        branch: String? = nil,
        patch: String? = nil
    ) {
        self.root = root
        self.action = action
        self.paths = paths
        self.message = message
        self.branch = branch
        self.patch = patch
    }

    public init(
        root: URL,
        action: GitAction,
        paths: [String]? = nil,
        message: String? = nil,
        branch: String? = nil,
        patch: String? = nil
    ) {
        self.init(
            root: root.path,
            action: action,
            paths: paths,
            message: message,
            branch: branch,
            patch: patch
        )
    }
}

/// The status read that follows a successfully committed Git mutation.
public enum GitMutationStatusRefresh: Equatable, Sendable {
    case refreshed(GitStatus)
    case failed(GitServiceError)
}

/// The result after an action command has been handed to the process runner.
/// `indeterminate` means cancellation or failure arrived after launch became
/// possible, so destructive callers must reconcile worktree-backed buffers.
/// Errors thrown before this value is returned are guaranteed to precede the
/// action-command handoff and therefore mean the mutation did not start.
public enum GitMutationResult: Equatable, Sendable {
    case committed(statusRefresh: GitMutationStatusRefresh)
    case indeterminate(GitServiceError)
}

// MARK: - Commands, limits, and errors

public struct GitServiceLimits: Equatable, Sendable {
    public static let `default` = GitServiceLimits()

    public var commandTimeout: TimeInterval
    public var maximumStatusBytes: Int
    public var maximumMetadataBytes: Int
    public var maximumContentBytes: Int
    public var maximumErrorBytes: Int
    public var maximumPatchBytes: Int
    public var maximumPathBytes: Int
    public var maximumPathsPerAction: Int
    public var maximumHunks: Int
    public var maximumHistoryEntries: Int
    public var maximumRemotes: Int
    public var maximumRemoteURLUTF16Units: Int
    public var maximumConflictLabelUTF16Units: Int

    public init(
        commandTimeout: TimeInterval = 10,
        maximumStatusBytes: Int = 8 * 1_024 * 1_024,
        maximumMetadataBytes: Int = 512 * 1_024,
        maximumContentBytes: Int = 2 * 1_024 * 1_024,
        maximumErrorBytes: Int = 512 * 1_024,
        maximumPatchBytes: Int = 2 * 1_024 * 1_024,
        maximumPathBytes: Int = 16 * 1_024,
        maximumPathsPerAction: Int = 500,
        maximumHunks: Int = 200,
        maximumHistoryEntries: Int = 100,
        maximumRemotes: Int = 100,
        maximumRemoteURLUTF16Units: Int = 4_096,
        maximumConflictLabelUTF16Units: Int = 256
    ) {
        self.commandTimeout = commandTimeout
        self.maximumStatusBytes = maximumStatusBytes
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumContentBytes = maximumContentBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.maximumPatchBytes = maximumPatchBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumPathsPerAction = maximumPathsPerAction
        self.maximumHunks = maximumHunks
        self.maximumHistoryEntries = maximumHistoryEntries
        self.maximumRemotes = maximumRemotes
        self.maximumRemoteURLUTF16Units = maximumRemoteURLUTF16Units
        self.maximumConflictLabelUTF16Units = maximumConflictLabelUTF16Units
    }

    fileprivate var isValid: Bool {
        commandTimeout > 0 && commandTimeout.isFinite
            && maximumStatusBytes > 0
            && maximumMetadataBytes > 0
            && maximumContentBytes > 0
            && maximumErrorBytes > 0
            && maximumPatchBytes > 0
            && maximumPathBytes > 0
            && maximumPathsPerAction > 0
            && maximumHunks > 0
            && maximumHistoryEntries > 0
            && maximumRemotes > 0
            && maximumRemoteURLUTF16Units > 0
            && maximumConflictLabelUTF16Units > 0
    }
}

public struct GitCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let standardInput: Data?
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let maximumErrorBytes: Int

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        maximumErrorBytes: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumErrorBytes = maximumErrorBytes
    }
}

public struct GitProcessResult: Equatable, Sendable {
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

public enum GitOutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

public enum GitServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot(String)
    case invalidLimits
    case invalidRelativePath(String)
    case tooManyPaths(maximum: Int)
    case pathsRequired(action: GitAction)
    case invalidBranch(String)
    case commitMessageRequired
    case invalidHunk
    case staleHunk
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    case outputLimitExceeded(stream: GitOutputStream, maximumBytes: Int)
    case processFailed(exitCode: Int32, stderr: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "A Git workspace root must be an absolute file URL."
        case .invalidLimits:
            return "Git service limits must all be finite and greater than zero."
        case .invalidRelativePath:
            return "A Git path must be a non-empty relative path inside the workspace root."
        case let .tooManyPaths(maximum):
            return "A Git action accepts at most \(maximum) paths."
        case let .pathsRequired(action):
            return "The Git action \(action.rawValue) requires at least one path."
        case .invalidBranch:
            return "The Git branch name is invalid."
        case .commitMessageRequired:
            return "A commit message is required."
        case .invalidHunk:
            return "Choose one valid Git hunk."
        case .staleHunk:
            return "The selected hunk is stale or does not belong to this file."
        case let .launchFailed(detail):
            return "Git could not be launched: \(detail)"
        case let .timedOut(seconds):
            return "Git did not finish within \(seconds) seconds."
        case let .outputLimitExceeded(stream, maximumBytes):
            return "Git \(stream.rawValue) exceeded \(maximumBytes) bytes."
        case let .processFailed(exitCode, stderr):
            return stderr.isEmpty
                ? "Git exited with status \(exitCode)."
                : stderr
        case .cancelled:
            return "The Git operation was cancelled."
        }
    }
}

/// Builds commands without invoking a shell. The fixed, absolute executable
/// and argument arrays keep paths and messages out of command-line parsing.
public struct GitCommandBuilder: Sendable {
    public static var systemGitURL: URL {
        URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)
    }

    public let rootURL: URL
    public let gitExecutableURL: URL
    public let limits: GitServiceLimits

    private let environment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GCM_INTERACTIVE": "Never",
        "GIT_LITERAL_PATHSPECS": "1",
        "LC_ALL": "C"
    ]

    /// Applied before the subcommand. Besides making every pathspec literal,
    /// this prevents passive status/diff reads from launching a repository-
    /// configured fsmonitor helper.
    private let safeGlobalArguments = [
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false"
    ]

    public init(
        rootURL: URL,
        gitExecutableURL: URL = GitCommandBuilder.systemGitURL,
        limits: GitServiceLimits = .default
    ) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              !rootURL.path.isEmpty,
              !rootURL.path.utf8.contains(0),
              rootURL.host == nil || rootURL.host == "" || rootURL.host == "localhost" else {
            throw GitServiceError.invalidRoot(rootURL.absoluteString)
        }
        guard gitExecutableURL.isFileURL,
              gitExecutableURL.path.hasPrefix("/"),
              !gitExecutableURL.path.utf8.contains(0) else {
            throw GitServiceError.invalidRoot(gitExecutableURL.absoluteString)
        }
        guard limits.isValid else { throw GitServiceError.invalidLimits }
        self.rootURL = rootURL.standardizedFileURL
        self.gitExecutableURL = gitExecutableURL.standardizedFileURL
        self.limits = limits
    }

    public init(
        root: String,
        gitExecutableURL: URL = GitCommandBuilder.systemGitURL,
        limits: GitServiceLimits = .default
    ) throws {
        guard NSString(string: root).isAbsolutePath else {
            throw GitServiceError.invalidRoot(root)
        }
        try self.init(
            rootURL: URL(fileURLWithPath: root, isDirectory: true),
            gitExecutableURL: gitExecutableURL,
            limits: limits
        )
    }

    public func branchCommand() -> GitCommand {
        command(["branch", "--show-current"], maximumOutputBytes: 64 * 1_024)
    }

    public func porcelainStatusCommand() -> GitCommand {
        command(
            ["status", "--porcelain=v1", "-z"],
            maximumOutputBytes: limits.maximumStatusBytes
        )
    }

    /// Alias used by callers that do not need to name the porcelain version.
    public func statusCommand() -> GitCommand { porcelainStatusCommand() }

    public func remoteConfigurationCommand() -> GitCommand {
        command(
            ["config", "--get-regexp", "^remote[.].*[.](url|pushurl)$"],
            maximumOutputBytes: limits.maximumMetadataBytes
        )
    }

    public func trackingMergeRefCommand(branch: String) -> GitCommand {
        command(
            ["config", "--get", "branch.\(branch).merge"],
            maximumOutputBytes: 64 * 1_024
        )
    }

    public func trackingRemoteCommand(branch: String) -> GitCommand {
        command(
            ["config", "--get", "branch.\(branch).remote"],
            maximumOutputBytes: 64 * 1_024
        )
    }

    public func upstreamCommand() -> GitCommand {
        command(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            maximumOutputBytes: 64 * 1_024
        )
    }

    public func aheadBehindCommand() -> GitCommand {
        command(
            ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            maximumOutputBytes: 64 * 1_024
        )
    }

    public func diffCommand(relativePath: String) throws -> GitCommand {
        let path = try validatedRelativePath(relativePath)
        return command(
            ["diff", "--no-ext-diff", "--no-textconv", "--", path],
            maximumOutputBytes: limits.maximumContentBytes
        )
    }

    public func historyCommand(relativePath: String) throws -> GitCommand {
        let path = try validatedRelativePath(relativePath)
        return command(
            [
                "log", "-n", "\(limits.maximumHistoryEntries)",
                "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00",
                "--", path
            ],
            maximumOutputBytes: limits.maximumContentBytes
        )
    }

    public func blameCommand(relativePath: String) throws -> GitCommand {
        let path = try validatedRelativePath(relativePath)
        return command(
            ["blame", "--date=short", "--", path],
            maximumOutputBytes: limits.maximumContentBytes
        )
    }

    public func conflictsCommand() -> GitCommand {
        command(
            ["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--diff-filter=U"],
            maximumOutputBytes: limits.maximumContentBytes
        )
    }

    public func conflictBlobCommand(
        relativePath: String,
        side: GitConflictSide
    ) throws -> GitCommand {
        let path = try validatedRelativePath(relativePath)
        return command(
            ["show", ":\(side.stageNumber):\(path)"],
            maximumOutputBytes: limits.maximumContentBytes
        )
    }

    public func actionCommand(for request: GitActionRequest) throws -> GitCommand {
        try validateRequestRoot(request.root)
        switch request.action {
        case .stage:
            let paths = try requiredPaths(request.paths, action: request.action)
            return command(
                ["add", "--"] + paths,
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .unstage:
            let paths = try requiredPaths(request.paths, action: request.action)
            return command(
                ["restore", "--staged", "--"] + paths,
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .discard:
            let paths = try requiredPaths(request.paths, action: request.action)
            return command(
                ["restore", "--worktree", "--"] + paths,
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .stageHunk, .discardHunk:
            let paths = try validatedPaths(request.paths ?? [])
            guard paths.count == 1,
                  let patch = request.patch,
                  !patch.isEmpty,
                  patch.lengthOfBytes(using: .utf8) <= limits.maximumPatchBytes else {
                throw GitServiceError.invalidHunk
            }
            let option = request.action == .stageHunk ? "--cached" : "--reverse"
            return command(
                ["apply", option, "-"],
                standardInput: Data(patch.utf8),
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .commit:
            let message = request.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty, !message.utf8.contains(0) else {
                throw GitServiceError.commitMessageRequired
            }
            return command(
                ["commit", "-m", message],
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .checkoutBranch:
            let branch = try validatedBranch(request.branch)
            return command(
                ["switch", branch],
                maximumOutputBytes: limits.maximumContentBytes
            )
        case .createBranch:
            let branch = try validatedBranch(request.branch)
            return command(
                ["switch", "-c", branch],
                maximumOutputBytes: limits.maximumContentBytes
            )
        }
    }

    public func validatedRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              !relativePath.contains(".."),
              !NSString(string: relativePath).isAbsolutePath,
              relativePath.lengthOfBytes(using: .utf8) <= limits.maximumPathBytes else {
            throw GitServiceError.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitServiceError.invalidRelativePath(relativePath)
        }

        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL.path
        let rootPath = rootURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard candidate.hasPrefix(prefix) else {
            throw GitServiceError.invalidRelativePath(relativePath)
        }
        return relativePath
    }

    public func validatedPaths(_ paths: [String]) throws -> [String] {
        guard paths.count <= limits.maximumPathsPerAction else {
            throw GitServiceError.tooManyPaths(maximum: limits.maximumPathsPerAction)
        }
        return try paths.map(validatedRelativePath)
    }

    public func validateRequestRoot(_ root: String) throws {
        guard NSString(string: root).isAbsolutePath else {
            throw GitServiceError.invalidRoot(root)
        }
        let requested = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        guard requested.path == rootURL.path else { throw GitServiceError.invalidRoot(root) }
    }

    private func requiredPaths(_ rawPaths: [String]?, action: GitAction) throws -> [String] {
        let paths = try validatedPaths(rawPaths ?? [])
        guard !paths.isEmpty else { throw GitServiceError.pathsRequired(action: action) }
        return paths
    }

    private func validatedBranch(_ value: String?) throws -> String {
        guard let value,
              !value.isEmpty,
              !value.hasPrefix("-"),
              !value.contains("..") else {
            throw GitServiceError.invalidBranch(value ?? "")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GitServiceError.invalidBranch(value)
        }
        return value
    }

    private func command(
        _ gitArguments: [String],
        standardInput: Data? = nil,
        maximumOutputBytes: Int
    ) -> GitCommand {
        GitCommand(
            executableURL: gitExecutableURL,
            arguments: ["-C", rootURL.path] + safeGlobalArguments + gitArguments,
            environment: environment,
            standardInput: standardInput,
            timeout: limits.commandTimeout,
            maximumOutputBytes: maximumOutputBytes,
            maximumErrorBytes: limits.maximumErrorBytes
        )
    }
}

// MARK: - Pure parsers

public enum GitParsers {
    /// Parses `git status --porcelain=v1 -z`. Rename/copy records have a
    /// second NUL field containing the source path; it is consumed rather than
    /// being mistaken for another status entry. The first path is the new path
    /// in porcelain `-z` output.
    public static func parsePorcelainV1Z(_ data: Data) -> [GitStatusEntry] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }
            let start = record.startIndex
            let indexByte = record[start]
            let worktreeByte = record[record.index(after: start)]
            let separator = record[record.index(start, offsetBy: 2)]
            guard separator == 0x20 else {
                index += 1
                continue
            }
            let pathStart = record.index(start, offsetBy: 3)
            let path = String(decoding: record[pathStart...], as: UTF8.self)
            guard !path.isEmpty else {
                index += 1
                continue
            }
            let indexStatus = String(decoding: [indexByte], as: UTF8.self)
            let worktreeStatus = String(decoding: [worktreeByte], as: UTF8.self)
            entries.append(GitStatusEntry(
                path: path,
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus
            ))
            let hasSourcePath = indexByte == 0x52 || indexByte == 0x43
                || worktreeByte == 0x52 || worktreeByte == 0x43 // R or C
            index += hasSourcePath ? 2 : 1
        }
        return entries
    }

    public static func parsePorcelainV1Z(_ text: String) -> [GitStatusEntry] {
        parsePorcelainV1Z(Data(text.utf8))
    }

    public static func sanitizeRemoteURL(_ value: String) -> String {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "" }

        if let helper = captures("^([A-Za-z0-9][A-Za-z0-9+.-]*)::(.+)$", in: url) {
            let name = helper[0]
            if name.lowercased() == "ext" { return "\(name)::[redacted]" }
            let address = helper[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikeURL = firstMatch("^[A-Za-z][A-Za-z0-9+.-]*://", in: address)
                || firstMatch("^[^/@:\\s]+(?::[^@\\s]+)?@[^:\\s]+:.+$", in: address)
                || firstMatch("^(?:\\.{0,2}/|/)", in: address)
            return "\(name)::\(looksLikeURL ? sanitizeRemoteURL(address) : "[redacted]")"
        }

        if let credentialSCP = captures(
            "^[^/@:\\s]+:[^@\\s]+@([^:\\s]+):(.+)$",
            in: url
        ) {
            return "\(credentialSCP[0]):\(credentialSCP[1])"
        }
        if let scp = captures("^[^/@:\\s]+@([^:\\s]+):(.+)$", in: url) {
            return "\(scp[0]):\(scp[1])"
        }

        if var components = URLComponents(string: url), components.scheme != nil {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            if let sanitized = components.string {
                return decodeURIForDisplay(sanitized)
            }
        }

        if let credentialSCP = captures("^([^@/:]+):[^@]*@([^:]+):(.*)$", in: url) {
            return "\(credentialSCP[1]):\(credentialSCP[2])"
        }
        return url
    }

    public static func parseRemoteLines(
        _ text: String,
        maximumRemotes: Int = GitServiceLimits.default.maximumRemotes,
        maximumURLUTF16Units: Int = GitServiceLimits.default.maximumRemoteURLUTF16Units
    ) -> [GitRemote] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var byName: [String: GitRemote] = [:]
        var order = 0
        while order < lines.count {
            let line = lines[order]
            var values: [String]?
            if let inline = captures("^remote\\.(.+)\\.(url|pushurl)[\\t ]+(.+)$", in: line) {
                values = inline
            } else if let key = captures("^remote\\.(.+)\\.(url|pushurl)$", in: line),
                      order + 1 < lines.count {
                order += 1
                values = [key[0], key[1], lines[order]]
            }
            order += 1
            guard let values else { continue }

            let name = values[0]
            let kind = values[1]
            let sanitized = truncateUTF16(
                sanitizeRemoteURL(values[2]),
                maximumUnits: maximumURLUTF16Units
            )
            guard !sanitized.isEmpty else { continue }
            var remote = byName[name] ?? GitRemote(name: name)
            if kind == "url", remote.fetchUrl == nil { remote.fetchUrl = sanitized }
            if kind == "pushurl", remote.pushUrl == nil { remote.pushUrl = sanitized }
            byName[name] = remote
        }
        return byName.values
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .prefix(max(0, maximumRemotes))
            .map { $0 }
    }

    public static func parseTracking(
        upstreamText: String,
        aheadBehindText: String,
        remoteText: String = "",
        remoteRefText: String = ""
    ) -> GitTrackingStatus {
        let upstream = nonEmptyTrimmed(upstreamText)
        let remote = nonEmptyTrimmed(remoteText)
        let rawRemoteRef = nonEmptyTrimmed(remoteRefText)
        let remoteBranch = rawRemoteRef.map { value in
            value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
        }
        let values = aheadBehindText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let maximumSafeInteger = 9_007_199_254_740_991
        let counts = values.count == 2 ? values.compactMap { value -> Int? in
            guard let parsed = Int(value), parsed >= 0, parsed <= maximumSafeInteger else { return nil }
            return parsed
        } : []
        return GitTrackingStatus(
            upstream: upstream,
            remote: remote,
            remoteBranch: remoteBranch,
            ahead: counts.count == 2 ? counts[0] : nil,
            behind: counts.count == 2 ? counts[1] : nil
        )
    }

    public static func parseHunks(
        relativePath: String,
        diff: String,
        maximumCount: Int = GitServiceLimits.default.maximumHunks
    ) -> [GitHunk] {
        let lines = diff.components(separatedBy: "\n")
        var prefix: [String] = []
        var hunks: [GitHunk] = []
        var current: [String]?
        var header = ""

        func appendCurrent() {
            guard let current, hunks.count < maximumCount else { return }
            let patch = (prefix + current).joined(separator: "\n")
            guard patch.contains("@@ ") else { return }
            hunks.append(GitHunk(path: relativePath, header: header, patch: patch))
        }

        for line in lines {
            if line.hasPrefix("@@ ") {
                appendCurrent()
                guard hunks.count < maximumCount else { break }
                header = line
                current = [line]
            } else if current != nil {
                current?.append(line)
            } else {
                prefix.append(line)
            }
        }
        appendCurrent()
        return hunks
    }

    public static func parseHistory(
        _ text: String,
        maximumCount: Int = GitServiceLimits.default.maximumHistoryEntries
    ) -> [GitHistoryEntry] {
        let values = text.components(separatedBy: "\0")
        var entries: [GitHistoryEntry] = []
        var index = 0
        while index + 4 < values.count, entries.count < maximumCount {
            // `git log --format` places a record newline after the terminating
            // NUL. It belongs to framing, not to the next object ID.
            let id = values[index].drop(while: { $0 == "\r" || $0 == "\n" })
            let shortId = values[index + 1]
            if !id.isEmpty, !shortId.isEmpty {
                entries.append(GitHistoryEntry(
                    id: String(id),
                    shortId: shortId,
                    author: values[index + 2],
                    date: values[index + 3],
                    subject: values[index + 4]
                ))
            }
            index += 5
        }
        return entries
    }

    public static func parseConflicts(_ data: Data) -> [GitConflict] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { GitConflict(path: String(decoding: $0, as: UTF8.self)) }
    }

    /// Convenience for fixtures and legacy callers. Production uses the NUL-
    /// delimited Data overload so newlines in file names remain unambiguous.
    public static func parseConflicts(_ text: String) -> [GitConflict] {
        if text.contains("\0") { return parseConflicts(Data(text.utf8)) }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { GitConflict(path: $0) }
    }

    public static func truncateDisplayText(
        _ value: String,
        maximumUTF16Units: Int
    ) -> String {
        truncateUTF16(value, maximumUnits: maximumUTF16Units)
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstMatch(_ pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ) else { return nil }
        var result: [String] = []
        for captureIndex in 1..<match.numberOfRanges {
            let range = match.range(at: captureIndex)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                return nil
            }
            result.append(String(value[swiftRange]))
        }
        return result
    }

    private static func truncateUTF16(_ value: String, maximumUnits: Int) -> String {
        guard maximumUnits > 0, value.utf16.count > maximumUnits else {
            return maximumUnits > 0 ? value : ""
        }
        return String(decoding: Array(value.utf16.prefix(maximumUnits)), as: UTF16.self)
    }

    /// A small `decodeURI` equivalent: percent-encoded Unicode and safe ASCII
    /// are displayed, while URI delimiters remain escaped.
    private static func decodeURIForDisplay(_ value: String) -> String {
        let reserved = Set<UInt8>(";/?:@&=+$,#".utf8)
        let characters = Array(value.utf8)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == 0x25,
                  index + 2 < characters.count,
                  hexByte(characters[index + 1], characters[index + 2]) != nil else {
                result += String(decoding: CollectionOfOne(characters[index]), as: UTF8.self)
                index += 1
                continue
            }

            var encodedBytes: [UInt8] = []
            while index + 2 < characters.count, characters[index] == 0x25,
                  let next = hexByte(characters[index + 1], characters[index + 2]) {
                encodedBytes.append(next)
                index += 3
            }
            var byteIndex = 0
            while byteIndex < encodedBytes.count {
                let current = encodedBytes[byteIndex]
                if current < 0x80 {
                    if reserved.contains(current) {
                        result += String(format: "%%%02X", current)
                    } else {
                        result.append(Character(UnicodeScalar(current)))
                    }
                    byteIndex += 1
                    continue
                }
                var end = byteIndex + 1
                while end < encodedBytes.count, encodedBytes[end] >= 0x80 { end += 1 }
                let bytes = Array(encodedBytes[byteIndex..<end])
                if let decoded = String(bytes: bytes, encoding: .utf8) {
                    result += decoded
                } else {
                    for invalid in bytes { result += String(format: "%%%02X", invalid) }
                }
                byteIndex = end
            }
        }
        return result
    }

    private static func hexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        guard let first = nibble(high), let second = nibble(low) else { return nil }
        return first * 16 + second
    }
}

// MARK: - Bounded Process runner

public protocol GitCommandRunning: Sendable {
    func run(_ command: GitCommand) async throws -> GitProcessResult
    func cancelAll() async
}

public extension GitCommandRunning {
    func cancelAll() async {}
}

/// Git-specific adapter over the shared process broker. Commands remain exact
/// executable-plus-argv values, so this layer never inserts a shell. The
/// broker supplies
/// bounded I/O, task cancellation, isolated process groups, TERM/KILL
/// escalation, and joinable teardown without inserting a shell.
public actor GitProcessRunner: GitCommandRunning {
    private let runner: ToolProcessRunner

    public init() {
        runner = ToolProcessRunner()
    }

    public func run(_ command: GitCommand) async throws -> GitProcessResult {
        guard command.executableURL.isFileURL,
              command.executableURL.path.hasPrefix("/"),
              !command.executableURL.path.utf8.contains(0),
              command.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              command.environment.allSatisfy({
                  !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
              }),
              command.timeout > 0, command.timeout.isFinite,
              command.maximumOutputBytes > 0,
              command.maximumErrorBytes > 0 else {
            throw GitServiceError.launchFailed("Invalid Git process command.")
        }
        var environment = Self.gitSafeInheritedEnvironment(
            ProcessInfo.processInfo.environment
        )
        command.environment.forEach { environment[$0.key] = $0.value }
        let toolCommand = ToolCommand(
            executableURL: command.executableURL,
            arguments: command.arguments,
            workingDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            environment: environment,
            standardInput: command.standardInput,
            timeout: command.timeout,
            maximumStandardInputBytes: max(
                1,
                command.standardInput?.count ?? 0
            ),
            maximumStandardOutputBytes: command.maximumOutputBytes,
            maximumStandardErrorBytes: command.maximumErrorBytes,
            gracefulTerminationTimeout: ToolExecutionLimits.gracefulTerminationTimeout,
            processGroupPolicy: .isolated
        )

        do {
            let result = try await runner.run(toolCommand)
            return GitProcessResult(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                exitCode: result.exitCode
            )
        } catch {
            throw Self.gitError(from: error)
        }
    }

    /// Cancels the current generation and joins every isolated process group
    /// before returning. A later call to run starts a fresh generation.
    public func cancelAll() async {
        await runner.cancelAll()
    }

    private nonisolated static func gitError(from error: any Error) -> GitServiceError {
        if error is CancellationError { return .cancelled }
        if let error = error as? ToolExecutionError {
            switch error {
            case let .timedOut(seconds):
                return .timedOut(seconds: seconds)
            case let .outputLimitExceeded(stream, maximumBytes):
                return .outputLimitExceeded(
                    stream: stream == .standardOutput ? .standardOutput : .standardError,
                    maximumBytes: maximumBytes
                )
            case .cancelled:
                return .cancelled
            default:
                return .launchFailed(error.localizedDescription)
            }
        }
        if let error = error as? ToolProcessRunnerError {
            switch error {
            case let .launchFailed(detail):
                return .launchFailed(detail)
            case .standardInputWriteFailed:
                return .launchFailed("Could not write Git standard input.")
            default:
                return .launchFailed(error.localizedDescription)
            }
        }
        return .launchFailed(error.localizedDescription)
    }

    private nonisolated static func gitSafeInheritedEnvironment(
        _ inherited: [String: String]
    ) -> [String: String] {
        inherited.filter { entry in
            // Git's execution-affecting environment is extensive and grows
            // over time. Drop the whole namespace; fixed safe values are added
            // from GitCommand.environment afterward.
            !entry.key.uppercased().hasPrefix("GIT_")
                && entry.key != "GCM_INTERACTIVE"
        }
    }
}

// MARK: - Root-scoped service

public actor GitService {
    public let rootURL: URL
    public let commands: GitCommandBuilder

    private let runner: any GitCommandRunning
    private var mutationInProgress = false
    private var isShutdown = false
    private var shutdownTask: Task<Void, Never>?
    private struct MutationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var mutationWaiters: [MutationWaiter] = []

    public init(
        rootURL: URL,
        runner: any GitCommandRunning = GitProcessRunner(),
        limits: GitServiceLimits = .default,
        gitExecutableURL: URL = GitCommandBuilder.systemGitURL
    ) throws {
        let commands = try GitCommandBuilder(
            rootURL: rootURL,
            gitExecutableURL: gitExecutableURL,
            limits: limits
        )
        self.rootURL = commands.rootURL
        self.commands = commands
        self.runner = runner
    }

    public func status() async throws -> GitStatus {
        do {
            let branchResult = try await checked(commands.branchCommand())
            let statusResult = try await checked(commands.porcelainStatusCommand())
            let remoteText = try await bestEffort(commands.remoteConfigurationCommand())
            let branchName = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            var tracking = GitTrackingStatus()
            if !branchName.isEmpty {
                let mergeRef = try await bestEffort(commands.trackingMergeRefCommand(branch: branchName))
                let remote = try await bestEffort(commands.trackingRemoteCommand(branch: branchName))
                let upstream = try await bestEffort(commands.upstreamCommand())
                let upstreamName = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
                let counts = upstreamName.isEmpty
                    ? ""
                    : try await bestEffort(commands.aheadBehindCommand())
                tracking = GitParsers.parseTracking(
                    upstreamText: upstreamName,
                    aheadBehindText: counts,
                    remoteText: remote,
                    remoteRefText: mergeRef
                )
            }

            return GitStatus(
                available: true,
                branch: branchName.isEmpty ? "(detached)" : branchName,
                entries: GitParsers.parsePorcelainV1Z(statusResult.standardOutput),
                tracking: tracking,
                remotes: GitParsers.parseRemoteLines(
                    remoteText,
                    maximumRemotes: commands.limits.maximumRemotes,
                    maximumURLUTF16Units: commands.limits.maximumRemoteURLUTF16Units
                )
            )
        } catch let error as GitServiceError where isNotRepository(error) {
            return GitStatus(available: false, entries: [])
        }
    }

    public func diff(relativePath: String) async throws -> GitDiff {
        let command = try commands.diffCommand(relativePath: relativePath)
        let result = try await checked(command)
        return GitDiff(path: relativePath, diff: result.stdout)
    }

    public func hunks(relativePath: String) async throws -> [GitHunk] {
        let current = try await diff(relativePath: relativePath)
        return GitParsers.parseHunks(
            relativePath: relativePath,
            diff: current.diff,
            maximumCount: commands.limits.maximumHunks
        )
    }

    public func history(relativePath: String) async throws -> [GitHistoryEntry] {
        let command = try commands.historyCommand(relativePath: relativePath)
        let result = try await checked(command)
        return GitParsers.parseHistory(
            result.stdout,
            maximumCount: commands.limits.maximumHistoryEntries
        )
    }

    /// Electron-compatible blame payload. Use `blameDetails` when retaining
    /// the requested path beside the result is useful.
    public func blame(relativePath: String) async throws -> String {
        let command = try commands.blameCommand(relativePath: relativePath)
        return try await checked(command).stdout
    }

    public func blameDetails(relativePath: String) async throws -> GitBlame {
        GitBlame(path: relativePath, blame: try await blame(relativePath: relativePath))
    }

    public func conflicts() async throws -> [GitConflict] {
        do {
            let result = try await checked(commands.conflictsCommand())
            let paths = GitParsers.parseConflicts(result.standardOutput).map(\.path)
            var conflicts: [GitConflict] = []
            conflicts.reserveCapacity(paths.count)
            for path in paths {
                try Task.checkCancellation()
                conflicts.append(GitConflict(
                    path: path,
                    ours: try await conflictLabel(relativePath: path, side: .ours),
                    theirs: try await conflictLabel(relativePath: path, side: .theirs)
                ))
            }
            return conflicts
        } catch let error as GitServiceError {
            if error == .cancelled { throw error }
            return []
        } catch is CancellationError {
            throw GitServiceError.cancelled
        } catch {
            return []
        }
    }

    /// Executes one validated mutation and then attempts to refresh status.
    /// Hunk mutations compare the supplied patch with a fresh diff before
    /// writing it to stdin. Once the action command exits successfully this
    /// method returns a committed result even if cancellation, shutdown, or a
    /// read error prevents the follow-up status refresh.
    public func perform(_ request: GitActionRequest) async throws -> GitMutationResult {
        try await acquireMutationPermit()
        defer { releaseMutationPermit() }
        do {
            try Task.checkCancellation()
        } catch {
            throw GitServiceError.cancelled
        }
        try commands.validateRequestRoot(request.root)
        if request.action == .stageHunk || request.action == .discardHunk {
            let paths = try commands.validatedPaths(request.paths ?? [])
            guard paths.count == 1,
                  let patch = request.patch,
                  !patch.isEmpty,
                  patch.lengthOfBytes(using: .utf8) <= commands.limits.maximumPatchBytes else {
                throw GitServiceError.invalidHunk
            }
            let current = try await diff(relativePath: paths[0])
            let currentHunks = GitParsers.parseHunks(
                relativePath: paths[0],
                diff: current.diff,
                maximumCount: commands.limits.maximumHunks
            )
            guard currentHunks.contains(where: { $0.patch == patch }) else {
                throw GitServiceError.staleHunk
            }
        }
        let command = try commands.actionCommand(for: request)
        // Cancellation and shutdown observed before the runner handoff prove
        // that the action command did not start, so preserve them as thrown
        // `notStarted` failures for the controller.
        guard !isShutdown else { throw GitServiceError.cancelled }
        do { try Task.checkCancellation() }
        catch { throw GitServiceError.cancelled }

        // From this handoff onward, any thrown runner result is fail-safe
        // indeterminate: the child may have changed the index/worktree before
        // cancellation, timeout, output failure, or a nonzero exit was observed.
        do {
            _ = try await checkedMutationCommand(command)
        } catch let error as GitServiceError {
            return .indeterminate(error)
        } catch is CancellationError {
            return .indeterminate(.cancelled)
        } catch {
            let mapped = GitServiceError.launchFailed(error.localizedDescription)
            return .indeterminate(mapped)
        }
        do {
            return .committed(statusRefresh: .refreshed(try await status()))
        } catch let error as GitServiceError {
            return .committed(statusRefresh: .failed(error))
        } catch is CancellationError {
            return .committed(statusRefresh: .failed(.cancelled))
        } catch {
            return .committed(statusRefresh: .failed(.launchFailed(error.localizedDescription)))
        }
    }

    public func action(_ request: GitActionRequest) async throws -> GitMutationResult {
        try await perform(request)
    }

    public func conflictSnapshot(
        relativePath: String,
        side: GitConflictSide
    ) async throws -> OpenedTextFile {
        let path = try commands.validatedRelativePath(relativePath)
        let blob = try await checked(commands.conflictBlobCommand(
            relativePath: path,
            side: side
        )).standardOutput
        return try TextFileCodec.decode(
            blob,
            sourceURL: rootURL.appendingPathComponent(
                ".git/lumen-conflicts/\(side.rawValue)/\(path)"
            ),
            maximumByteCount: Int64(commands.limits.maximumContentBytes)
        )
    }

    public func cancelAll() async {
        await runner.cancelAll()
    }

    /// Permanently closes this root-scoped service. Pending mutation permits
    /// are revoked before launched commands are joined, so queued work cannot
    /// start again after a root/window teardown has begun.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutdown = true
        let waiters = mutationWaiters
        mutationWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.continuation.resume(returning: false) }
        let runner = runner
        let task = Task { await runner.cancelAll() }
        shutdownTask = task
        await task.value
    }

    public nonisolated static func parseStatusPorcelain(_ data: Data) -> [GitStatusEntry] {
        GitParsers.parsePorcelainV1Z(data)
    }

    public nonisolated static func sanitizeRemoteURL(_ value: String) -> String {
        GitParsers.sanitizeRemoteURL(value)
    }

    private func conflictLabel(
        relativePath: String,
        side: GitConflictSide
    ) async throws -> String? {
        do {
            _ = try await conflictSnapshot(relativePath: relativePath, side: side)
            let fallback = side == .ours ? "Ours" : "Theirs"
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return GitParsers.truncateDisplayText(
                trimmed,
                maximumUTF16Units: commands.limits.maximumConflictLabelUTF16Units
            )
        } catch let error as GitServiceError {
            if error == .cancelled { throw error }
            return nil
        } catch is CancellationError {
            throw GitServiceError.cancelled
        } catch {
            return nil
        }
    }

    private func checked(_ command: GitCommand) async throws -> GitProcessResult {
        guard !isShutdown else { throw GitServiceError.cancelled }
        let result: GitProcessResult
        do {
            result = try await runner.run(command)
        } catch is CancellationError {
            throw GitServiceError.cancelled
        }
        guard !isShutdown else { throw GitServiceError.cancelled }
        guard result.exitCode == 0 else {
            throw GitServiceError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    /// Unlike a read, a mutation cannot be retroactively treated as cancelled
    /// after its process has reported a zero exit status. Teardown may make the
    /// subsequent status read fail, but the caller must still learn that disk
    /// state was committed and perform its document reconciliation.
    private func checkedMutationCommand(
        _ command: GitCommand
    ) async throws -> GitProcessResult {
        let result: GitProcessResult
        do {
            result = try await runner.run(command)
        } catch is CancellationError {
            throw GitServiceError.cancelled
        }
        guard result.exitCode == 0 else {
            throw GitServiceError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func bestEffort(_ command: GitCommand) async throws -> String {
        do {
            guard !isShutdown else { throw GitServiceError.cancelled }
            try Task.checkCancellation()
            let result = try await runner.run(command)
            guard !isShutdown else { throw GitServiceError.cancelled }
            try Task.checkCancellation()
            return result.exitCode == 0 ? result.stdout : ""
        } catch is CancellationError {
            throw GitServiceError.cancelled
        } catch let error as GitServiceError where error == .cancelled {
            throw error
        } catch {
            return ""
        }
    }

    private func isNotRepository(_ error: GitServiceError) -> Bool {
        guard case let .processFailed(exitCode, stderr) = error, exitCode == 128 else {
            return false
        }
        return stderr.range(of: "not a git repository", options: .caseInsensitive) != nil
            || stderr.contains("不是一个 git 仓库")
            || stderr.contains("非 git 仓库")
    }

    /// Actor isolation alone is reentrant at every `await`. This explicit FIFO
    /// permit keeps the fresh-hunk check, mutation and status refresh ordered
    /// with respect to other mutations issued through this service instance.
    private func acquireMutationPermit() async throws {
        guard !isShutdown else { throw GitServiceError.cancelled }
        do { try Task.checkCancellation() }
        catch { throw GitServiceError.cancelled }
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    mutationWaiters.append(MutationWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelMutationWaiter(id: id) }
        }
        guard acquired else { throw GitServiceError.cancelled }
        if Task.isCancelled || isShutdown {
            // This waiter already owns the transferred permit; pass it onward
            // before reporting cancellation.
            releaseMutationPermit()
            throw GitServiceError.cancelled
        }
    }

    private func releaseMutationPermit() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelMutationWaiter(id: UUID) {
        guard let index = mutationWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = mutationWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
