import CoreFoundation
@preconcurrency import Foundation

/// Limits applied after the process broker has enforced its byte budgets.
/// Keeping the diagnostic limit separate prevents a small JSON response from
/// expanding into an unbounded number of application objects.
public enum LanguageToolLimits {
    public static let maximumDiagnostics = 1_000
    public static let maximumDiagnosticMessageUTF16CodeUnits = 2_000
    public static let maximumErrorDetailUTF16CodeUnits = 2_000
}

public enum LanguageToolDiagnosticSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case error
    case warning
    case info
}

/// Electron-compatible, one-based diagnostic coordinates.
public struct LanguageToolDiagnostic: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let endLine: Int?
    public let endColumn: Int?
    public let severity: LanguageToolDiagnosticSeverity
    public let message: String

    public init(
        line: Int,
        column: Int,
        endLine: Int? = nil,
        endColumn: Int? = nil,
        severity: LanguageToolDiagnosticSeverity,
        message: String
    ) {
        self.line = max(1, line)
        self.column = max(1, column)
        self.endLine = endLine.map { max(1, $0) }
        self.endColumn = endColumn.map { max(1, $0) }
        self.severity = severity
        self.message = LanguageToolTextSanitizer.displayText(
            message,
            maximumUTF16Units: LanguageToolLimits.maximumDiagnosticMessageUTF16CodeUnits
        )
    }
}

/// A structured tool may return diagnostics with optional replacement content.
/// Every other successful stdout value is treated as replacement content.
public struct LanguageToolResult: Codable, Equatable, Sendable {
    public let content: String?
    public let diagnostics: [LanguageToolDiagnostic]

    public init(content: String? = nil, diagnostics: [LanguageToolDiagnostic] = []) {
        self.content = content
        self.diagnostics = Array(diagnostics.prefix(LanguageToolLimits.maximumDiagnostics))
    }
}

public struct LanguageToolRequest: Equatable, Sendable {
    public let root: URL
    public let configuration: LanguageToolConfig
    public let content: String
    public let fileURL: URL?

    public init(
        root: URL,
        configuration: LanguageToolConfig,
        content: String,
        fileURL: URL? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.content = content
        self.fileURL = fileURL
    }
}

public enum LanguageToolStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

public enum LanguageToolError: Error, Equatable, LocalizedError, Sendable {
    case approvalRequired(ToolExecutionConfiguration)
    case fileOutsideWorkspace(file: URL, root: URL)
    case invalidUTF8(LanguageToolStream)
    case nonzeroExit(code: Int32, detail: String)
    case executableSelectionUnavailable
    case invalidExecutableSelection(URL)
    case tooManyExecutableSelections(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "Running this language tool requires approval for its exact configuration."
        case .fileOutsideWorkspace:
            return "The document is outside the language tool's authorised workspace."
        case let .invalidUTF8(stream):
            return "The language tool returned invalid UTF-8 on \(stream.rawValue)."
        case let .nonzeroExit(code, detail):
            return detail.isEmpty
                ? "The language tool exited with code \(code)."
                : "The language tool exited with code \(code): \(detail)"
        case .executableSelectionUnavailable:
            return "This language tool service uses a custom execution policy and cannot add executable selections."
        case .invalidExecutableSelection:
            return "Choose an absolute, local, executable file for the language tool."
        case let .tooManyExecutableSelections(maximum):
            return "At most \(maximum) language-tool executables may be authorised in one session."
        }
    }
}

/// Converts bounded process output into the generic formatter/diagnostic wire
/// contract used by the Electron application. Malformed diagnostic children
/// are ignored; malformed or non-object JSON remains ordinary formatter text.
public enum LanguageToolOutputParser {
    public static func parse(_ data: Data) throws -> LanguageToolResult {
        guard let stdout = String(data: data, encoding: .utf8) else {
            throw LanguageToolError.invalidUTF8(.standardOutput)
        }
        guard let value = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ), let object = value as? [String: Any],
              let rawDiagnostics = object["diagnostics"] as? [Any] else {
            return LanguageToolResult(content: stdout)
        }

        var diagnostics: [LanguageToolDiagnostic] = []
        diagnostics.reserveCapacity(min(rawDiagnostics.count, LanguageToolLimits.maximumDiagnostics))
        for raw in rawDiagnostics {
            guard diagnostics.count < LanguageToolLimits.maximumDiagnostics else { break }
            guard let item = raw as? [String: Any],
                  let line = coordinate(item["line"]),
                  let column = coordinate(item["column"]),
                  let message = item["message"] as? String else { continue }
            let severity: LanguageToolDiagnosticSeverity
            switch item["severity"] as? String {
            case "warning": severity = .warning
            case "info": severity = .info
            default: severity = .error
            }
            diagnostics.append(LanguageToolDiagnostic(
                line: line,
                column: column,
                endLine: coordinate(item["endLine"]),
                endColumn: coordinate(item["endColumn"]),
                severity: severity,
                message: message
            ))
        }
        return LanguageToolResult(
            content: object["content"] as? String,
            diagnostics: diagnostics
        )
    }

    private static func coordinate(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        if value <= 1 { return 1 }
        if value >= Double(Int.max) { return Int.max }
        return max(1, Int(floor(value)))
    }
}

public typealias LanguageToolConfigurationBuilder = @Sendable (
    _ root: URL, _ configuration: LanguageToolConfig
) throws -> ToolExecutionConfiguration

/// Production one-shot stdin/stdout language-tool broker. The project file can
/// describe a command but cannot execute it: a complete, normalized execution
/// configuration must already be approved in this window/session scope.
public actor LanguageToolService {
    public static let maximumExplicitExecutableSelections = 128
    public static let processLimits = ToolProcessLimits(
        timeout: ToolExecutionLimits.languageToolTimeout,
        maximumStandardInputBytes: ToolExecutionLimits.maximumOneShotStdinBytes,
        maximumStandardOutputBytes: ToolExecutionLimits.maximumStandardOutputBytes,
        maximumStandardErrorBytes: ToolExecutionLimits.maximumStandardErrorBytes,
        gracefulTerminationTimeout: ToolExecutionLimits.gracefulTerminationTimeout,
        processGroupPolicy: .isolated
    )

    private let runner: any ToolCommandRunning
    private let approvals: ToolApprovalStore
    private let approvalScope: ToolApprovalScope
    private let customConfigurationBuilder: LanguageToolConfigurationBuilder?
    private let resolver: ToolExecutableResolver?
    private let inheritedEnvironment: [String: String]
    private var explicitlyAuthorizedExecutableURLs: Set<URL> = []

    public init(
        runner: any ToolCommandRunning = ToolProcessRunner(),
        approvals: ToolApprovalStore = ToolApprovalStore(),
        approvalScope: ToolApprovalScope = ToolApprovalScope(
            windowID: UUID(), sessionID: UUID()
        ),
        resolver: ToolExecutableResolver = .system,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.approvals = approvals
        self.approvalScope = approvalScope
        customConfigurationBuilder = nil
        self.resolver = resolver
        self.inheritedEnvironment = inheritedEnvironment
    }

    public init(
        runner: any ToolCommandRunning,
        approvals: ToolApprovalStore = ToolApprovalStore(),
        approvalScope: ToolApprovalScope = ToolApprovalScope(
            windowID: UUID(), sessionID: UUID()
        ),
        configurationBuilder: @escaping LanguageToolConfigurationBuilder
    ) {
        self.runner = runner
        self.approvals = approvals
        self.approvalScope = approvalScope
        customConfigurationBuilder = configurationBuilder
        resolver = nil
        inheritedEnvironment = [:]
    }

    /// Adds an executable selected by trusted UI to this in-memory service. A
    /// project file alone cannot call this API, and process execution still
    /// requires a separate exact-configuration approval.
    public func authorizeExecutable(_ url: URL) throws -> URL {
        guard customConfigurationBuilder == nil else {
            throw LanguageToolError.executableSelectionUnavailable
        }
        guard url.isFileURL, (url.host == nil || url.host?.isEmpty == true),
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw LanguageToolError.invalidExecutableSelection(url)
        }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalized.path, isDirectory: &isDirectory
        ), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: normalized.path) else {
            throw LanguageToolError.invalidExecutableSelection(url)
        }
        guard explicitlyAuthorizedExecutableURLs.contains(normalized)
                || explicitlyAuthorizedExecutableURLs.count
                    < Self.maximumExplicitExecutableSelections else {
            throw LanguageToolError.tooManyExecutableSelections(
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

    public func approvalConfiguration(
        root: URL, configuration: LanguageToolConfig
    ) throws -> ToolExecutionConfiguration {
        try makeConfiguration(root: normalized(root), configuration: configuration)
    }

    public func approve(_ configuration: ToolExecutionConfiguration) async {
        _ = await approvals.approve(configuration, in: approvalScope)
    }

    public func run(_ request: LanguageToolRequest) async throws -> LanguageToolResult {
        try Task.checkCancellation()
        guard request.root.isFileURL,
              request.root.host == nil || request.root.host?.isEmpty == true,
              request.root.user == nil, request.root.password == nil,
              request.root.port == nil, request.root.query == nil,
              request.root.fragment == nil,
              request.root.path.hasPrefix("/"),
              !request.root.path.utf8.contains(0) else {
            throw ToolExecutionError.invalidAuthorizedRoot(request.root)
        }
        let root = normalized(request.root)
        if let fileURL = request.fileURL {
            guard fileURL.isFileURL,
                  fileURL.host == nil || fileURL.host?.isEmpty == true,
                  fileURL.user == nil, fileURL.password == nil,
                  fileURL.port == nil, fileURL.query == nil,
                  fileURL.fragment == nil,
                  fileURL.path.hasPrefix("/"), !fileURL.path.utf8.contains(0) else {
                throw LanguageToolError.fileOutsideWorkspace(
                    file: fileURL, root: root
                )
            }
            let file = normalized(fileURL)
            guard contains(root: root, candidate: file) else {
                throw LanguageToolError.fileOutsideWorkspace(file: file, root: root)
            }
        }
        let configuration = try makeConfiguration(
            root: root, configuration: request.configuration
        )
        guard await approvals.isApproved(configuration, in: approvalScope) else {
            throw LanguageToolError.approvalRequired(configuration)
        }
        try Task.checkCancellation()
        let command = try configuration.makeCommand(
            standardInput: Data(request.content.utf8),
            limits: Self.processLimits
        )
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            guard let stderr = String(data: result.standardError, encoding: .utf8) else {
                throw LanguageToolError.invalidUTF8(.standardError)
            }
            let detail = LanguageToolTextSanitizer.displayText(
                stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumUTF16Units: LanguageToolLimits.maximumErrorDetailUTF16CodeUnits
            )
            throw LanguageToolError.nonzeroExit(code: result.exitCode, detail: detail)
        }
        return try LanguageToolOutputParser.parse(result.standardOutput)
    }

    public func cancelAll() async { await runner.cancelAll() }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func makeConfiguration(
        root: URL, configuration: LanguageToolConfig
    ) throws -> ToolExecutionConfiguration {
        if let customConfigurationBuilder {
            return try customConfigurationBuilder(root, configuration)
        }
        let selectedResolver = try resolverForConfiguration(
            configuration, root: root
        )
        return try ToolExecutionConfiguration(
            kind: .languageTool,
            root: root,
            command: configuration.command,
            arguments: configuration.args,
            workingDirectory: configuration.workingDirectory,
            shell: configuration.shell ?? false,
            environment: configuration.env ?? [:],
            inheritedEnvironment: inheritedEnvironment,
            resolver: selectedResolver
        )
    }

    private func resolverForConfiguration(
        _ configuration: LanguageToolConfig,
        root: URL
    ) throws -> ToolExecutableResolver {
        guard let resolver else {
            throw LanguageToolError.executableSelectionUnavailable
        }
        let source = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.shell != true, source.contains("/") else {
            return resolver
        }
        let selectedURL: URL
        if (source as NSString).isAbsolutePath {
            selectedURL = URL(fileURLWithPath: source, isDirectory: false)
        } else {
            // Relative executable paths use the same cwd resolution as the
            // execution configuration itself.
            let cwd: URL
            if let configured = configuration.workingDirectory,
               !configured.isEmpty {
                cwd = (configured as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: configured, isDirectory: true)
                    : root.appendingPathComponent(configured, isDirectory: true)
            } else {
                cwd = root
            }
            selectedURL = cwd.appendingPathComponent(source, isDirectory: false)
        }
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard explicitlyAuthorizedExecutableURLs.contains(selected) else { return resolver }
        var allowed: [String: URL] = [:]
        for (index, url) in resolver.allowedExecutableURLs.sorted(
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
            allowedExecutables: allowed,
            shellExecutableURL: resolver.shellExecutableURL
        )
    }

    private func contains(root: URL, candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { $0.0 == $0.1 }
    }
}

private enum LanguageToolTextSanitizer {
    static func displayText(_ source: String, maximumUTF16Units: Int) -> String {
        var clean = String()
        clean.reserveCapacity(min(source.count, maximumUTF16Units))
        for scalar in source.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t"
                || (value >= 0x20 && value != 0x7f && !(0x80...0x9f).contains(value)) {
                clean.unicodeScalars.append(scalar)
            }
        }
        return LSPLogSanitizer.prefixUTF16(clean, maximumUnits: maximumUTF16Units)
    }
}

/// Dependency-free fallback used only when the active language has no external
/// formatter. It mirrors Electron: remove spaces/tabs at line ends, then keep
/// at most one blank line (two consecutive newline characters).
public enum BuiltInDocumentFormatter {
    public static func format(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var trimmed = String()
        trimmed.reserveCapacity(source.utf8.count)
        for (index, line) in lines.enumerated() {
            var end = line.endIndex
            while end > line.startIndex {
                let previous = line.index(before: end)
                guard line[previous] == " " || line[previous] == "\t" else { break }
                end = previous
            }
            trimmed.append(contentsOf: line[..<end])
            if index + 1 < lines.count { trimmed.append("\n") }
        }

        var result = String()
        result.reserveCapacity(trimmed.utf8.count)
        var consecutiveNewlines = 0
        for character in trimmed {
            if character == "\n" {
                consecutiveNewlines += 1
                if consecutiveNewlines <= 2 { result.append(character) }
            } else {
                consecutiveNewlines = 0
                result.append(character)
            }
        }
        return result
    }
}
