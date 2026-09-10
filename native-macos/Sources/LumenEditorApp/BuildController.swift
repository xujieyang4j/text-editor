import Combine
import Dispatch
@preconcurrency import Foundation
import LumenEditorCore

enum BuildConfigurationError: Error, Equatable, LocalizedError {
    case emptyName
    case tooManyVariants(maximum: Int)
    case invalidFileRegex
    case unsafeFileRegex
    case unknownVariant(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "A build system and each variant must have a name."
        case let .tooManyVariants(maximum):
            return "A build system may contain at most \(maximum) variants."
        case .invalidFileRegex: return "The build problem regular expression is invalid."
        case .unsafeFileRegex:
            return "The build problem regular expression uses constructs that are unsafe for streaming output."
        case let .unknownVariant(name): return "The build variant ‘\(name)’ does not exist."
        }
    }
}

/// Foundation's regular-expression engine has no match deadline or cancellation
/// hook. Reject the common exponential-backtracking shapes before a configured
/// expression can reach the bounded background matcher below. This is
/// intentionally conservative: build problem matchers are expected to describe
/// one output line and do not need backreferences or look-around assertions.
private enum BuildFileRegexSafety {
    private struct Group {
        var containsRepetition = false
        var containsAlternation = false
        var hasAlternationBranchContent = false
        var hasEmptyAlternationBranch = false
        var lastAtom: Atom = .none
    }

    private enum Atom {
        case none
        case ordinary
        case group(containsRepetition: Bool, containsAlternation: Bool)
        case quantified
    }

    private static let maximumQuantifiers = 32

    static func isObviouslyUnsafe(_ pattern: String) -> Bool {
        guard pattern.utf16.count <= ProjectSettingsSanitizer.maximumFileRegexUTF16CodeUnits,
              !pattern.utf8.contains(0) else { return true }

        let bytes = Array(pattern.utf8)
        var groups = [Group()]
        var quantifierCount = 0
        var index = 0

        func isASCIIDigit(_ byte: UInt8) -> Bool {
            (48 ... 57).contains(byte)
        }

        func bracedQuantifierEnd(start: Int) -> Int? {
            var cursor = start + 1
            guard cursor < bytes.count, isASCIIDigit(bytes[cursor]) else { return nil }
            while cursor < bytes.count, isASCIIDigit(bytes[cursor]) { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 44 { // comma
                cursor += 1
                while cursor < bytes.count, isASCIIDigit(bytes[cursor]) { cursor += 1 }
            }
            guard cursor < bytes.count, bytes[cursor] == 125 else { return nil } // }
            return cursor
        }

        func isLookAround(start: Int) -> Bool {
            guard start + 2 < bytes.count, bytes[start + 1] == 63 else { return false }
            if bytes[start + 2] == 61 || bytes[start + 2] == 33 { return true } // (?=, (?!
            return start + 3 < bytes.count
                && bytes[start + 2] == 60
                && (bytes[start + 3] == 61 || bytes[start + 3] == 33) // (?<=, (?<!
        }

        func applyingQuantifier() -> Bool {
            let candidate = groups[groups.count - 1].lastAtom
            if case .quantified = candidate {
                // Lazy and possessive suffixes do not introduce another repeated atom.
                return false
            }
            if case .none = candidate { return true }
            quantifierCount += 1
            if quantifierCount > maximumQuantifiers { return true }
            if case let .group(containsRepetition, containsAlternation) = candidate,
               containsRepetition || containsAlternation {
                return true
            }
            groups[groups.count - 1].containsRepetition = true
            groups[groups.count - 1].lastAtom = .quantified
            return false
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 92: // backslash
                guard index + 1 < bytes.count else {
                    index += 1
                    continue
                }
                let escaped = bytes[index + 1]
                // Numeric and named backreferences can turn otherwise simple
                // repetitions into super-linear matches.
                if (49 ... 57).contains(escaped) || escaped == 107 || escaped == 103 {
                    return true
                }
                groups[groups.count - 1].lastAtom = .ordinary
                groups[groups.count - 1].hasAlternationBranchContent = true
                index += 2

            case 91: // character class
                index += 1
                var escaped = false
                while index < bytes.count {
                    if escaped {
                        escaped = false
                    } else if bytes[index] == 92 {
                        escaped = true
                    } else if bytes[index] == 93 {
                        index += 1
                        break
                    }
                    index += 1
                }
                groups[groups.count - 1].lastAtom = .ordinary
                groups[groups.count - 1].hasAlternationBranchContent = true

            case 40: // (
                if isLookAround(start: index) { return true }
                groups.append(Group())
                index += 1
                if index < bytes.count, bytes[index] == 63 {
                    // Skip the syntax prefix of noncapturing, atomic, named, and
                    // option groups so its punctuation cannot look like a
                    // quantifier or alternation inside the group body.
                    if index + 1 < bytes.count, bytes[index + 1] == 58 {
                        index += 2 // (?:
                    } else if index + 1 < bytes.count, bytes[index + 1] == 62 {
                        index += 2 // (?>
                    } else if index + 1 < bytes.count, bytes[index + 1] == 60 {
                        index += 2 // (?<name>
                        while index < bytes.count, bytes[index] != 62 { index += 1 }
                        if index < bytes.count { index += 1 }
                    } else {
                        index += 1 // (?im-sx: or (?im-sx)
                        while index < bytes.count,
                              bytes[index] != 58, bytes[index] != 41 { index += 1 }
                        if index < bytes.count, bytes[index] == 58 { index += 1 }
                    }
                }

            case 41: // )
                guard groups.count > 1 else {
                    groups[groups.count - 1].lastAtom = .ordinary
                    index += 1
                    continue
                }
                let closed = groups.removeLast()
                let closedContainsAlternation = closed.containsAlternation
                    || closed.hasEmptyAlternationBranch
                    || (closed.containsAlternation && !closed.hasAlternationBranchContent)
                groups[groups.count - 1].containsRepetition =
                    groups[groups.count - 1].containsRepetition || closed.containsRepetition
                groups[groups.count - 1].containsAlternation =
                    groups[groups.count - 1].containsAlternation || closedContainsAlternation
                groups[groups.count - 1].hasAlternationBranchContent = true
                groups[groups.count - 1].lastAtom = .group(
                    containsRepetition: closed.containsRepetition,
                    containsAlternation: closedContainsAlternation
                )
                index += 1

            case 124: // |
                groups[groups.count - 1].containsAlternation = true
                if !groups[groups.count - 1].hasAlternationBranchContent {
                    groups[groups.count - 1].hasEmptyAlternationBranch = true
                }
                groups[groups.count - 1].hasAlternationBranchContent = false
                groups[groups.count - 1].lastAtom = .none
                index += 1

            case 42, 43, 63: // *, +, ?
                if applyingQuantifier() { return true }
                groups[groups.count - 1].hasAlternationBranchContent = true
                index += 1

            case 123: // {m,n}
                guard let end = bracedQuantifierEnd(start: index) else {
                    groups[groups.count - 1].lastAtom = .ordinary
                    groups[groups.count - 1].hasAlternationBranchContent = true
                    index += 1
                    continue
                }
                if applyingQuantifier() { return true }
                groups[groups.count - 1].hasAlternationBranchContent = true
                index = end + 1

            default:
                groups[groups.count - 1].lastAtom = .ordinary
                groups[groups.count - 1].hasAlternationBranchContent = true
                index += 1
            }
        }
        return false
    }
}

struct BuildVariant: Identifiable, Equatable, Sendable {
    let name: String
    var command: String?
    var arguments: [String]?
    var workingDirectory: String?
    var fileRegex: String?
    var environment: [String: String]?
    var shell: Bool?

    var id: String { name }

    init(
        name: String,
        command: String? = nil,
        arguments: [String]? = nil,
        workingDirectory: String? = nil,
        fileRegex: String? = nil,
        environment: [String: String]? = nil,
        shell: Bool? = nil
    ) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BuildConfigurationError.emptyName }
        if let fileRegex {
            _ = try Self.validate(fileRegex: fileRegex)
        }
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.fileRegex = fileRegex
        self.environment = environment
        self.shell = shell
    }

    fileprivate static func validate(fileRegex: String) throws -> String {
        guard !BuildFileRegexSafety.isObviouslyUnsafe(fileRegex) else {
            throw BuildConfigurationError.unsafeFileRegex
        }
        do {
            _ = try NSRegularExpression(pattern: fileRegex)
            return fileRegex
        } catch {
            throw BuildConfigurationError.invalidFileRegex
        }
    }
}

struct BuildSystem: Identifiable, Equatable, Sendable {
    static let maximumVariants = 20

    let name: String
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var fileRegex: String?
    var saveBeforeBuild: Bool
    var shell: Bool
    var environment: [String: String]
    var variants: [BuildVariant]

    var id: String { name }

    init(
        name: String,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        fileRegex: String? = nil,
        saveBeforeBuild: Bool = false,
        shell: Bool = false,
        environment: [String: String] = [:],
        variants: [BuildVariant] = []
    ) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BuildConfigurationError.emptyName }
        guard variants.count <= Self.maximumVariants else {
            throw BuildConfigurationError.tooManyVariants(maximum: Self.maximumVariants)
        }
        if let fileRegex { _ = try BuildVariant.validate(fileRegex: fileRegex) }
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.fileRegex = fileRegex
        self.saveBeforeBuild = saveBeforeBuild
        self.shell = shell
        self.environment = environment
        self.variants = variants
    }

    func configuration(
        for variantName: String? = nil,
        root: URL,
        resolver: ToolExecutableResolver = .system
    ) throws -> (ToolExecutionConfiguration, String?) {
        let variant: BuildVariant?
        if let variantName {
            guard let match = variants.first(where: { $0.name == variantName }) else {
                throw BuildConfigurationError.unknownVariant(variantName)
            }
            variant = match
        } else {
            variant = nil
        }
        let configuration = try ToolExecutionConfiguration(
            kind: .buildSystem,
            root: root,
            command: variant?.command ?? command,
            arguments: variant?.arguments ?? arguments,
            workingDirectory: variant?.workingDirectory ?? workingDirectory,
            shell: variant?.shell ?? shell,
            environment: variant?.environment ?? environment,
            resolver: resolver
        )
        let effectiveFileRegex = variant?.fileRegex ?? fileRegex
        // Build systems are mutable value types. Revalidate here as well as in
        // their initializers so a subsequently mutated pattern cannot bypass
        // the streaming parser's safety contract.
        if let effectiveFileRegex {
            _ = try BuildVariant.validate(fileRegex: effectiveFileRegex)
        }
        return (configuration, effectiveFileRegex)
    }
}

struct BuildSystemSelection: Identifiable, Equatable, Sendable {
    let system: BuildSystem
    let variantName: String?
    let systemIndex: Int
    let variantIndex: Int?

    var id: String {
        "system.\(systemIndex).variant.\(variantIndex.map(String.init) ?? "base")"
    }
    var label: String {
        variantName.map { "\(system.name): \($0)" } ?? system.name
    }
    var detail: String {
        guard let variantName,
              let variant = system.variants.first(where: { $0.name == variantName })
        else { return system.command }
        return variant.command ?? system.command
    }

}

struct BuildSystemPaletteItem: Identifiable, Equatable, Sendable {
    let selection: BuildSystemSelection
    let match: FuzzyResult

    var id: String { selection.id }
    var label: String { selection.label }
    var detail: String { selection.detail }
    var matchedUTF16Offsets: [Int] { match.matches }
}

protocol BuildProcessRunning: Sendable {
    func run(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult
    func cancelAll() async
}

struct BuildProcessRunnerAdapter: BuildProcessRunning {
    private let runner: ToolProcessRunner

    init(runner: ToolProcessRunner = ToolProcessRunner()) {
        self.runner = runner
    }

    func run(
        _ command: ToolCommand,
        onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult {
        try await runner.run(command, onOutput: onOutput)
    }

    func cancelAll() async { await runner.cancelAll() }
}

struct BuildLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let stream: ToolOutputStream
    let text: String

    init(id: UUID = UUID(), stream: ToolOutputStream, text: String) {
        self.id = id
        self.stream = stream
        self.text = text
    }
}

/// Decodes process output without treating a UTF-8 scalar split across two
/// callbacks as malformed. Each stream retains only a potentially valid,
/// incomplete scalar prefix, which is at most three bytes. Invalid bytes are
/// decoded immediately with the same repair behavior as `String(decoding:)`;
/// genuinely truncated prefixes receive that repair only when the stream ends.
private final class BuildUTF8OutputDecoder: @unchecked Sendable {
    private struct StreamDecoder {
        private static let maximumTrailingByteCount = 3
        private var trailingBytes: [UInt8] = []

        mutating func decode(_ data: Data) -> String {
            guard !data.isEmpty else { return "" }
            var bytes = trailingBytes
            bytes.reserveCapacity(trailingBytes.count + data.count)
            bytes.append(contentsOf: data)

            let trailingCount = Self.incompleteSuffixCount(in: bytes)
            let decodedEnd = bytes.count - trailingCount
            let text = String(decoding: bytes[..<decodedEnd], as: UTF8.self)
            trailingBytes = trailingCount == 0 ? [] : Array(bytes[decodedEnd...])
            assert(trailingBytes.count <= Self.maximumTrailingByteCount)
            return text
        }

        mutating func finish() -> String {
            defer { trailingBytes.removeAll(keepingCapacity: false) }
            return String(decoding: trailingBytes, as: UTF8.self)
        }

        private static func incompleteSuffixCount(in bytes: [UInt8]) -> Int {
            guard !bytes.isEmpty else { return 0 }
            let firstCandidate = max(0, bytes.count - maximumTrailingByteCount)
            for start in firstCandidate ..< bytes.count {
                guard let expectedCount = sequenceLength(for: bytes[start]) else { continue }
                let availableCount = bytes.count - start
                guard availableCount < expectedCount,
                      isValidPrefix(bytes, start: start) else { continue }
                return availableCount
            }
            return 0
        }

        private static func sequenceLength(for leadingByte: UInt8) -> Int? {
            switch leadingByte {
            case 0xC2 ... 0xDF: return 2
            case 0xE0 ... 0xEF: return 3
            case 0xF0 ... 0xF4: return 4
            default: return nil
            }
        }

        private static func isValidPrefix(_ bytes: [UInt8], start: Int) -> Bool {
            let leadingByte = bytes[start]
            guard start + 1 < bytes.count else { return true }
            for index in (start + 1) ..< bytes.count {
                let byte = bytes[index]
                if index == start + 1 {
                    switch leadingByte {
                    case 0xE0 where !(0xA0 ... 0xBF).contains(byte),
                         0xED where !(0x80 ... 0x9F).contains(byte),
                         0xF0 where !(0x90 ... 0xBF).contains(byte),
                         0xF4 where !(0x80 ... 0x8F).contains(byte):
                        return false
                    default:
                        break
                    }
                }
                guard (0x80 ... 0xBF).contains(byte) else { return false }
            }
            return true
        }
    }

    private let lock = NSLock()
    private var standardOutput = StreamDecoder()
    private var standardError = StreamDecoder()
    private var isFinished = false

    func decode(_ data: Data, from stream: ToolOutputStream) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return "" }
        switch stream {
        case .standardOutput:
            return standardOutput.decode(data)
        case .standardError:
            return standardError.decode(data)
        }
    }

    func finish() -> [(ToolOutputStream, String)] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }
        isFinished = true
        return [
            (.standardOutput, standardOutput.finish()),
            (.standardError, standardError.finish())
        ].filter { !$0.1.isEmpty }
    }
}

struct BuildProblem: Identifiable, Equatable, Sendable {
    enum Severity: String, Equatable, Sendable { case error, warning, info }

    let id: UUID
    let url: URL
    let line: Int
    let column: Int
    let message: String
    let severity: Severity

    init(
        id: UUID = UUID(),
        url: URL,
        line: Int,
        column: Int,
        message: String,
        severity: Severity
    ) {
        self.id = id
        self.url = url
        self.line = line
        self.column = column
        self.message = message
        self.severity = severity
    }
}

private enum BuildProblemParserEvent: Sendable {
    case available
}

private struct BuildProblemParserBatch: Sendable {
    let text: String
    let inputLimitReached: Bool
}

/// A synchronous, thread-safe ingress for process callbacks. Parsing accepts at
/// most two megabytes per build and coalesces process chunks into batches of at
/// least 64 KiB when possible. The stream contains only one pending wake-up
/// signal, so tiny process chunks cannot allocate an unbounded event queue.
private final class BuildProblemParserInput: @unchecked Sendable {
    static let maximumUTF16Count = 2_000_000
    private static let maximumBufferedUTF16Count = 64 * 1_024

    let events: AsyncStream<BuildProblemParserEvent>

    private let continuation: AsyncStream<BuildProblemParserEvent>.Continuation
    private let lock = BuildProblemParserLock()
    private var remainingUTF16Count = maximumUTF16Count
    private var bufferedText = ""
    private var didReachInputLimit = false
    private var isFinished = false

    init() {
        let pair = AsyncStream<BuildProblemParserEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func yield(_ text: String) {
        guard !text.isEmpty else { return }
        let action: (notify: Bool, finish: Bool)? = lock.withLock {
            guard !isFinished else { return nil }

            let count = text.utf16.count
            let acceptedCount = min(remainingUTF16Count, count)
            let accepted = Self.prefix(text, maximumUTF16Count: acceptedCount)
            remainingUTF16Count -= accepted.utf16.count
            bufferedText += accepted
            let shouldNotify = bufferedText.utf16.count >= Self.maximumBufferedUTF16Count

            let reachedLimit = count > accepted.utf16.count || remainingUTF16Count == 0
            if reachedLimit {
                didReachInputLimit = true
                isFinished = true
            }
            return (shouldNotify || reachedLimit, reachedLimit)
        }
        guard let action else { return }
        if action.notify { continuation.yield(.available) }
        if action.finish { continuation.finish() }
    }

    func finish() {
        let shouldFinish = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        guard shouldFinish else { return }
        continuation.yield(.available)
        continuation.finish()
    }

    func takeBatch() -> BuildProblemParserBatch {
        lock.withLock {
            let batch = BuildProblemParserBatch(
                text: bufferedText, inputLimitReached: didReachInputLimit
            )
            bufferedText = ""
            didReachInputLimit = false
            return batch
        }
    }

    private static func prefix(_ text: String, maximumUTF16Count: Int) -> String {
        guard maximumUTF16Count > 0 else { return "" }
        let utf16 = text.utf16
        guard utf16.count > maximumUTF16Count else { return text }
        var end = utf16.index(utf16.startIndex, offsetBy: maximumUTF16Count)
        if end > utf16.startIndex, end < utf16.endIndex {
            let previous = utf16[utf16.index(before: end)]
            let current = utf16[end]
            if (0xD800 ... 0xDBFF).contains(previous),
               (0xDC00 ... 0xDFFF).contains(current) {
                end = utf16.index(before: end)
            }
        }
        return String(decoding: utf16[..<end], as: UTF16.self)
    }
}

private final class BuildProblemParserLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// Incremental line parser owned exclusively by a detached utility task. Regex
/// calls never run on the main actor. The limits are deliberately independent:
/// input bounds memory, line length plus structural validation bound one
/// uninterruptible ICU call, and attempts plus measured regex time bound
/// cumulative work. Parsed results remain capped at 500 and are handed to the
/// main actor once, so tiny process chunks cannot flood the main-actor queue.
private struct BuildProblemStreamParser {
    private static let defaultPattern = #"(?:^|\n)([^:\n]+):(\d+):(\d+):\s*(.*)"#
    private static let maximumLineUTF16Count = 4_096
    private static let maximumMatchAttempts = 10_000
    private static let maximumProblems = 500
    private static let maximumRegexNanoseconds: UInt64 = 500_000_000

    private let root: URL
    private let regex: NSRegularExpression
    private var pendingLine = ""
    private var pendingLineUTF16Count = 0
    private var isDiscardingOversizedLine = false
    private var matchAttempts = 0
    private var regexNanoseconds: UInt64 = 0
    private var problemCount = 0
    private(set) var isExhausted = false

    init?(root: URL, fileRegex: String?) {
        self.root = root
        guard let regex = try? NSRegularExpression(
            pattern: fileRegex ?? Self.defaultPattern,
            options: [.anchorsMatchLines]
        ) else { return nil }
        self.regex = regex
    }

    mutating func consume(_ text: String) -> [BuildProblem] {
        guard !isExhausted, !Task.isCancelled else { return [] }
        var result: [BuildProblem] = []
        var start = text.startIndex
        while start < text.endIndex,
              let newline = text[start...].firstIndex(of: "\n") {
            accept(text[start..<newline], completesLine: true, into: &result)
            guard !isExhausted, !Task.isCancelled else { return result }
            start = text.index(after: newline)
        }
        if start < text.endIndex {
            accept(text[start...], completesLine: false, into: &result)
        }
        return result
    }

    mutating func inputLimitReached() {
        // Never interpret a prefix cut at the global budget as a complete
        // compiler line. Complete lines preceding it were already processed.
        pendingLine = ""
        pendingLineUTF16Count = 0
        isDiscardingOversizedLine = false
        isExhausted = true
    }

    mutating func finish() -> [BuildProblem] {
        guard !isExhausted, !isDiscardingOversizedLine, !pendingLine.isEmpty,
              !Task.isCancelled else { return [] }
        var result: [BuildProblem] = []
        parsePendingLine(into: &result)
        return result
    }

    private mutating func accept(
        _ segment: Substring, completesLine: Bool, into result: inout [BuildProblem]
    ) {
        if isDiscardingOversizedLine {
            if completesLine {
                isDiscardingOversizedLine = false
                pendingLine = ""
                pendingLineUTF16Count = 0
            }
            return
        }

        let segmentCount = segment.utf16.count
        let combinedCount = pendingLineUTF16Count + segmentCount
        guard combinedCount <= Self.maximumLineUTF16Count else {
            pendingLine = ""
            pendingLineUTF16Count = 0
            isDiscardingOversizedLine = !completesLine
            return
        }
        pendingLine.append(contentsOf: segment)
        pendingLineUTF16Count = combinedCount
        if completesLine { parsePendingLine(into: &result) }
    }

    private mutating func parsePendingLine(into result: inout [BuildProblem]) {
        var line = pendingLine
        pendingLine = ""
        pendingLineUTF16Count = 0
        if line.last == "\r" { line.removeLast() }
        guard matchAttempts < Self.maximumMatchAttempts,
              problemCount < Self.maximumProblems,
              regexNanoseconds < Self.maximumRegexNanoseconds,
              !Task.isCancelled else {
            isExhausted = true
            return
        }
        matchAttempts += 1

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let started = DispatchTime.now().uptimeNanoseconds
        let match = regex.firstMatch(in: line, range: range)
        let ended = DispatchTime.now().uptimeNanoseconds
        if ended >= started { regexNanoseconds += ended - started }

        if let match,
           let problem = Self.problem(from: match, line: line, root: root) {
            result.append(problem)
            problemCount += 1
        }
        if matchAttempts >= Self.maximumMatchAttempts
            || problemCount >= Self.maximumProblems
            || regexNanoseconds >= Self.maximumRegexNanoseconds {
            isExhausted = true
        }
    }

    private static func problem(
        from match: NSTextCheckingResult, line: String, root: URL
    ) -> BuildProblem? {
        guard match.numberOfRanges >= 5,
              let pathRange = Range(match.range(at: 1), in: line),
              let lineRange = Range(match.range(at: 2), in: line),
              let columnRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line),
              let lineNumber = Int(line[lineRange]),
              let column = Int(line[columnRange]),
              let completeRange = Range(match.range, in: line) else { return nil }
        let path = String(line[pathRange])
        let url = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        let message = String(line[messageRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let complete = line[completeRange]
        let severity: BuildProblem.Severity = complete.range(
            of: "warning", options: .caseInsensitive
        ) != nil ? .warning : (
            complete.range(of: "info", options: .caseInsensitive) != nil ? .info : .error
        )
        return BuildProblem(
            url: url.standardizedFileURL,
            line: max(1, lineNumber), column: max(1, column),
            message: message, severity: severity
        )
    }
}

struct BuildPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case invalidCommand
        case invalidBuildSystem
        case buildFailed
        case noWorkspace
        case saveBuildCommand
    }

    enum Message: Equatable, Sendable {
        case noWorkspace
        case timedOut
        case outputLimitExceeded
        case processQueueOverflow
        case operationFailed
        case persistence(BuildCommandPersistenceError)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    var title: String { localizedTitle(locale: .enUS) }
    var message: String { localizedMessage(locale: .enUS) }

    init(id: UUID = UUID(), title: Title, message: Message) {
        self.id = id
        self.titleContent = title
        self.content = message
    }

    init(id: UUID = UUID(), persistenceError: BuildCommandPersistenceError) {
        self.id = id
        titleContent = .saveBuildCommand
        content = .persistence(persistenceError)
    }

    func localizedTitle(locale: EditorLocale) -> String {
        switch titleContent {
        case .invalidCommand:
            return locale.text("Invalid Build Command", zh: "构建命令无效")
        case .invalidBuildSystem:
            return locale.text("Invalid Build System", zh: "构建系统无效")
        case .buildFailed:
            return locale.text("Build Failed", zh: "构建失败")
        case .noWorkspace:
            return locale.text("No Workspace Open", zh: "未打开工作区")
        case .saveBuildCommand:
            return locale.text("Could Not Save Build Command", zh: "无法保存构建命令")
        }
    }

    func localizedMessage(locale: EditorLocale) -> String {
        switch content {
        case .noWorkspace:
            return locale.text(
                "Open a workspace folder before running a build.",
                zh: "请先打开工作区文件夹，再运行构建。"
            )
        case .timedOut:
            return locale.text("The build timed out.", zh: "构建超时。")
        case .outputLimitExceeded:
            return locale.text(
                "The build exceeded its process output limit.",
                zh: "构建超出了进程输出限制。"
            )
        case .processQueueOverflow:
            return locale.text(
                "Too many external tools are waiting to run.",
                zh: "等待运行的外部工具过多。"
            )
        case .operationFailed:
            return locale.text(
                "The build operation could not be completed.",
                zh: "无法完成构建操作。"
            )
        case let .persistence(error):
            return error.localizedDescription(locale: locale)
        }
    }
}

enum BuildCommandPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case projectWriteFailed(String)
    case globalWriteFailed(String)
    case partialPersistence(globalFailure: String, projectRollbackFailure: String)
    case unexpected(String)

    var errorDescription: String? { localizedDescription(locale: .enUS) }

    func localizedDescription(locale: EditorLocale) -> String {
        switch self {
        case let .projectWriteFailed(message):
            return locale.text(
                "The approved build command was not run because project settings could not be saved: \(message)",
                zh: "已批准的构建命令未运行，因为无法保存项目设置：\(message)"
            )
        case let .globalWriteFailed(message):
            return locale.text(
                "The approved build command was not run because global settings could not be saved: \(message) The project build command was restored.",
                zh: "已批准的构建命令未运行，因为无法保存全局设置：\(message) 项目构建命令已恢复。"
            )
        case let .partialPersistence(globalFailure, rollbackFailure):
            return locale.text(
                "The approved build command was not run because global settings could not be saved: \(globalFailure) Rolling back project settings also failed: \(rollbackFailure) Global and project build commands may differ.",
                zh: "已批准的构建命令未运行，因为无法保存全局设置：\(globalFailure) 回滚项目设置也失败：\(rollbackFailure) 全局与项目构建命令可能不一致。"
            )
        case let .unexpected(message):
            return locale.text(
                "The approved build command was not run because its settings could not be saved: \(message)",
                zh: "已批准的构建命令未运行，因为无法保存其设置：\(message)"
            )
        }
    }
}

enum BuildRequestOutcome: Equatable, Sendable {
    case started
    case awaitingApproval
    case unavailable
    case failed(String)
}

extension BuildRequestOutcome {
    var wasAccepted: Bool {
        switch self {
        case .started, .awaitingApproval: true
        case .unavailable, .failed: false
        }
    }
}

struct BuildApprovalRequest: Identifiable, Equatable {
    enum Subject: Equatable, Sendable {
        case freeForm
        case buildSystem(name: String, variant: String?)
    }

    var id: ToolExecutionIdentity { configuration.identity }
    let subject: Subject
    let configuration: ToolExecutionConfiguration

    func title(locale: EditorLocale) -> String {
        switch subject {
        case .freeForm:
            return locale.text(
                "Confirm free-form build command",
                zh: "确认自由构建命令"
            )
        case let .buildSystem(name, variant):
            let suffix = variant.map { " — \($0)" } ?? ""
            return locale.text(
                "Confirm build system ‘\(name)\(suffix)’",
                zh: "确认构建系统“\(name)\(suffix)”"
            )
        }
    }

    var commandDescription: String {
        configuration.shell
            ? configuration.executable
            : ([configuration.executable] + configuration.args).joined(separator: " ")
    }

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
            "Uses shell: \(configuration.shell ? "yes" : "no")",
            environment.isEmpty ? "Environment: none" : "Environment:\n\(environment)",
            "Identity: \(configuration.identity.rawValue)"
        ].joined(separator: "\n")
    }
}

@MainActor
final class BuildController: ObservableObject {
    typealias SaveBeforeBuild = @MainActor () async -> Bool
    typealias PersistApprovedFreeFormCommand =
        @MainActor (ToolExecutionConfiguration) throws -> Void

    static let maximumLogCharacters = ToolExecutionLimits.maximumRetainedOutputCharacters
    static let maximumProblems = 500
    static let maximumBuildSystemPaletteItems =
        ProjectSettingsSanitizer.maximumBuildSystems * (BuildSystem.maximumVariants + 1)
    static let maximumBuildSystemQueryUTF16Count = 256

    @Published var freeFormCommand = "" {
        didSet {
            let bounded = Self.boundedPrefix(
                freeFormCommand,
                maximumUTF16Count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
            )
            if bounded != freeFormCommand {
                synchronizeFreeFormCommand(bounded)
                return
            }
        }
    }
    @Published private(set) var workspaceRoot: URL?
    @Published private(set) var logEntries: [BuildLogEntry] = []
    @Published private(set) var problems: [BuildProblem] = []
    @Published private(set) var pendingApproval: BuildApprovalRequest?
    @Published private(set) var issue: BuildPresentationIssue?
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var wasOutputTruncated = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var selectedBuildSystem: BuildSystem?
    @Published private(set) var selectedBuildVariantName: String?
    @Published private(set) var buildSystemPaletteItems: [BuildSystemPaletteItem] = []
    @Published private(set) var selectedBuildSystemPaletteIndex: Int?
    @Published private(set) var isBuildSystemPalettePresented = false
    @Published var buildSystemQuery: String = "" {
        didSet {
            let bounded = Self.boundedPrefix(
                buildSystemQuery, maximumUTF16Count: Self.maximumBuildSystemQueryUTF16Count
            )
            if bounded != buildSystemQuery {
                buildSystemQuery = bounded
                return
            }
            guard buildSystemQuery != oldValue else { return }
            rebuildBuildSystemPalette(
                preservingSelectionIndex: selectedBuildSystemPaletteIndex
            )
        }
    }

    private struct PendingBuild: Sendable {
        let configuration: ToolExecutionConfiguration
        let approvalSubject: BuildApprovalRequest.Subject
        let fileRegex: String?
        let saveBeforeBuild: Bool
    }

    private let runner: any BuildProcessRunning
    private let approvals: ToolApprovalStore
    private let scope: ToolApprovalScope
    private let resolver: ToolExecutableResolver
    private let saveBeforeBuild: SaveBeforeBuild
    private let buildTimeout: TimeInterval
    private var persistApprovedFreeFormCommand: PersistApprovedFreeFormCommand = { _ in }
    private var workspaceUpdateGeneration: UInt64 = 0
    private var globalBuildCommand = ""
    private var projectBuildCommandOverride: String?
    private var pendingBuild: PendingBuild?
    private var operationTask: Task<Void, Never>?
    private var problemParserTask: Task<[BuildProblem], Never>?
    private var problemParserInput: BuildProblemParserInput?
    private var problemParserID: UUID?
    private var generation: UInt64 = 0
    private var retainedCharacterCount = 0
    private var paletteBuildSystems: [BuildSystem] = []

    init(
        workspaceRoot: URL? = nil,
        runner: any BuildProcessRunning = BuildProcessRunnerAdapter(),
        approvals: ToolApprovalStore = ToolApprovalStore(),
        scope: ToolApprovalScope = ToolApprovalScope(windowID: UUID(), sessionID: UUID()),
        resolver: ToolExecutableResolver = .system,
        buildTimeout: TimeInterval = 60 * 60,
        saveBeforeBuild: @escaping SaveBeforeBuild = { true }
    ) {
        precondition(buildTimeout > 0 && buildTimeout.isFinite)
        self.workspaceRoot = workspaceRoot
        self.runner = runner
        self.approvals = approvals
        self.scope = scope
        self.resolver = resolver
        self.buildTimeout = buildTimeout
        self.saveBeforeBuild = saveBeforeBuild
    }

    var outputText: String { logEntries.map(\.text).joined() }
    var canRun: Bool { workspaceRoot != nil && !isRunning && !isCancelling }

    func bindFreeFormCommand(
        initialValue: String,
        persistApprovedCommand: @escaping PersistApprovedFreeFormCommand
    ) {
        globalBuildCommand = Self.boundedPrefix(
            initialValue,
            maximumUTF16Count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
        )
        synchronizeFreeFormCommand(projectBuildCommandOverride ?? globalBuildCommand)
        persistApprovedFreeFormCommand = persistApprovedCommand
    }

    func synchronizePersistedFreeFormCommand(_ command: String) {
        globalBuildCommand = Self.boundedPrefix(
            command,
            maximumUTF16Count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
        )
        guard projectBuildCommandOverride == nil else { return }
        synchronizeFreeFormCommand(globalBuildCommand)
    }

    func synchronizeProjectBuildCommand(_ command: String) {
        let bounded = Self.boundedPrefix(
            command,
            maximumUTF16Count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
        )
        projectBuildCommandOverride = bounded
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
        synchronizeFreeFormCommand(projectBuildCommandOverride ?? globalBuildCommand)
    }

    func clearProjectBuildCommandOverride() {
        projectBuildCommandOverride = nil
        synchronizeFreeFormCommand(globalBuildCommand)
    }

    func synchronizeFreeFormCommand(_ command: String) {
        let bounded = Self.boundedPrefix(
            command, maximumUTF16Count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
        )
        guard freeFormCommand != bounded else { return }
        freeFormCommand = bounded
    }

    private func persistFreeFormCommandBeforeStarting(
        _ configuration: ToolExecutionConfiguration
    ) -> Bool {
        do {
            try persistApprovedFreeFormCommand(configuration)
        } catch {
            synchronizeFreeFormCommand(configuration.executable)
            issue = BuildPresentationIssue(
                persistenceError: error as? BuildCommandPersistenceError
                    ?? .unexpected(error.localizedDescription)
            )
            return false
        }
        globalBuildCommand = configuration.executable
        projectBuildCommandOverride = configuration.executable
        synchronizeFreeFormCommand(configuration.executable)
        issue = nil
        return true
    }
    var canRunPrimaryAction: Bool { canRun }

    func updateWorkspaceRoot(_ root: URL?) async {
        workspaceUpdateGeneration &+= 1
        let updateGeneration = workspaceUpdateGeneration
        guard root != workspaceRoot else { return }
        await cancel()
        guard !Task.isCancelled,
              updateGeneration == workspaceUpdateGeneration else { return }
        workspaceRoot = root
        pendingApproval = nil
        pendingBuild = nil
        dismissBuildSystemPalette()
    }

    @discardableResult
    func requestFreeFormBuild(_ command: String? = nil) async -> BuildRequestOutcome {
        guard let root = requireWorkspaceRoot() else {
            return .failed(issue?.message ?? "Open a workspace before running a build.")
        }
        do {
            let source = command ?? freeFormCommand
            let configuration = try ToolExecutionConfiguration(
                kind: .buildCommand,
                root: root,
                command: source,
                shell: true,
                resolver: resolver
            )
            synchronizeFreeFormCommand(configuration.executable)
            return await request(PendingBuild(
                configuration: configuration,
                approvalSubject: .freeForm,
                fileRegex: nil,
                saveBeforeBuild: false
            ))
        } catch {
            present(error, title: .invalidCommand)
            return .failed(issue?.message ?? error.localizedDescription)
        }
    }

    @discardableResult
    func requestBuildSystem(
        _ system: BuildSystem, variantName: String? = nil
    ) async -> BuildRequestOutcome {
        guard let root = requireWorkspaceRoot() else {
            return .failed(issue?.message ?? "Open a workspace before running a build.")
        }
        do {
            let (configuration, fileRegex) = try system.configuration(
                for: variantName, root: root, resolver: resolver
            )
            return await request(PendingBuild(
                configuration: configuration,
                approvalSubject: .buildSystem(
                    name: system.name, variant: variantName
                ),
                fileRegex: fileRegex,
                saveBeforeBuild: system.saveBeforeBuild
            ))
        } catch {
            present(error, title: .invalidBuildSystem)
            return .failed(issue?.message ?? error.localizedDescription)
        }
    }

    @discardableResult
    func runPrimaryAction() async -> BuildRequestOutcome {
        if selectedBuildSystem != nil {
            return await runSelectedBuildSystem()
        } else {
            return await requestFreeFormBuild()
        }
    }

    func selectBuildSystem(_ system: BuildSystem, variantName: String? = nil) {
        selectedBuildSystem = system
        selectedBuildVariantName = variantName
        let variant = variantName.flatMap { name in
            system.variants.first { $0.name == name }
        }
        synchronizeFreeFormCommand(variant?.command ?? system.command)
    }

    @discardableResult
    func presentBuildSystemPalette(
        buildSystems: [BuildSystem], query: String = ""
    ) -> Bool {
        guard workspaceRoot != nil, !isRunning, !isCancelling else { return false }
        let boundedSystems = Array(
            buildSystems.prefix(ProjectSettingsSanitizer.maximumBuildSystems)
        )
        guard !boundedSystems.isEmpty else { return false }
        paletteBuildSystems = boundedSystems
        isBuildSystemPalettePresented = true
        buildSystemQuery = Self.boundedPrefix(
            query, maximumUTF16Count: Self.maximumBuildSystemQueryUTF16Count
        )
        rebuildBuildSystemPalette()
        return true
    }

    func dismissBuildSystemPalette() {
        isBuildSystemPalettePresented = false
        paletteBuildSystems = []
        buildSystemPaletteItems = []
        selectedBuildSystemPaletteIndex = nil
    }

    var selectedBuildSystemPaletteItem: BuildSystemPaletteItem? {
        guard let selectedBuildSystemPaletteIndex,
              buildSystemPaletteItems.indices.contains(selectedBuildSystemPaletteIndex)
        else { return nil }
        return buildSystemPaletteItems[selectedBuildSystemPaletteIndex]
    }

    func selectBuildSystemPaletteItem(at index: Int) {
        guard buildSystemPaletteItems.indices.contains(index) else { return }
        selectedBuildSystemPaletteIndex = index
    }

    func moveBuildSystemPaletteSelection(by delta: Int) {
        guard !buildSystemPaletteItems.isEmpty else {
            selectedBuildSystemPaletteIndex = nil
            return
        }
        let current = selectedBuildSystemPaletteIndex.flatMap {
            buildSystemPaletteItems.indices.contains($0) ? $0 : nil
        } ?? 0
        selectedBuildSystemPaletteIndex = (
            (current + delta) % buildSystemPaletteItems.count
                + buildSystemPaletteItems.count
        ) % buildSystemPaletteItems.count
    }

    /// Mirrors Electron's palette acceptance: remember the effective system
    /// first, then immediately enter the normal approval/execution pipeline.
    @discardableResult
    func acceptBuildSystemPaletteSelection() async -> Bool {
        guard let item = selectedBuildSystemPaletteItem else { return false }
        let selection = item.selection
        selectBuildSystem(selection.system, variantName: selection.variantName)
        dismissBuildSystemPalette()
        let outcome = await runSelectedBuildSystem()
        switch outcome {
        case .started, .awaitingApproval:
            return true
        case .unavailable, .failed:
            return false
        }
    }

    @discardableResult
    func acceptBuildSystemPaletteItem(at index: Int) async -> Bool {
        guard buildSystemPaletteItems.indices.contains(index) else { return false }
        selectedBuildSystemPaletteIndex = index
        return await acceptBuildSystemPaletteSelection()
    }

    @discardableResult
    func runSelectedBuildSystem() async -> BuildRequestOutcome {
        guard let selectedBuildSystem else { return .unavailable }
        return await requestBuildSystem(
            selectedBuildSystem, variantName: selectedBuildVariantName
        )
    }

    private func rebuildBuildSystemPalette(
        preservingSelectionIndex preferredIndex: Int? = nil
    ) {
        guard isBuildSystemPalettePresented else {
            buildSystemPaletteItems = []
            selectedBuildSystemPaletteIndex = nil
            return
        }
        let selections = paletteBuildSystems.enumerated().flatMap { systemIndex, system in
            [BuildSystemSelection(
                system: system, variantName: nil,
                systemIndex: systemIndex, variantIndex: nil
            )] + system.variants.enumerated().map { variantIndex, variant in
                BuildSystemSelection(
                    system: system, variantName: variant.name,
                    systemIndex: systemIndex, variantIndex: variantIndex
                )
            }
        }
        let query = buildSystemQuery
        let ranked: [(item: BuildSystemSelection, result: FuzzyResult)]
        if query.isEmpty {
            ranked = selections.map { ($0, FuzzyResult(score: 1, matches: [])) }
        } else {
            // Electron's generic palette fuzzy-matches the displayed label,
            // not the command detail. Stable equal-score ordering is retained.
            ranked = CommandFuzzyMatcher.filter(
                query: query, items: selections, key: \.label
            )
        }
        buildSystemPaletteItems = ranked.prefix(Self.maximumBuildSystemPaletteItems).map {
            BuildSystemPaletteItem(selection: $0.item, match: $0.result)
        }
        guard !buildSystemPaletteItems.isEmpty else {
            selectedBuildSystemPaletteIndex = nil
            return
        }
        selectedBuildSystemPaletteIndex = min(
            max(0, preferredIndex ?? 0), buildSystemPaletteItems.count - 1
        )
    }

    func confirmPendingBuild() async {
        guard let requestedBuild = pendingBuild,
              pendingApproval?.configuration == requestedBuild.configuration else { return }
        _ = await approvals.approve(requestedBuild.configuration, in: scope)
        // Root changes and a competing dismissal can run while the actor call
        // suspends. Never launch the stale request merely because it was approved.
        guard pendingBuild?.configuration == requestedBuild.configuration,
              pendingApproval?.configuration == requestedBuild.configuration,
              workspaceRoot == requestedBuild.configuration.root else { return }
        guard start(requestedBuild) else {
            pendingApproval = nil
            pendingBuild = nil
            return
        }
        pendingApproval = nil
        pendingBuild = nil
    }

    func declinePendingBuild() {
        pendingApproval = nil
        pendingBuild = nil
    }

    func cancel() async {
        guard operationTask != nil || isRunning else { return }
        generation &+= 1
        let task = operationTask
        let parserTask = problemParserTask
        let parserInput = problemParserInput
        operationTask = nil
        problemParserTask = nil
        problemParserInput = nil
        problemParserID = nil
        isRunning = false
        isCancelling = true
        parserTask?.cancel()
        parserInput?.finish()
        task?.cancel()
        await runner.cancelAll()
        await task?.value
        await parserTask?.value
        isCancelling = false
    }

    func clearOutput() {
        logEntries = []
        problems = []
        wasOutputTruncated = false
        retainedCharacterCount = 0
        exitCode = nil
    }

    func dismissIssue() { issue = nil }

    func waitForCurrentBuild() async {
        let task = operationTask
        await task?.value
    }

    private func request(_ build: PendingBuild) async -> BuildRequestOutcome {
        guard !isRunning && !isCancelling else { return .unavailable }
        issue = nil
        pendingBuild = build
        pendingApproval = BuildApprovalRequest(
            subject: build.approvalSubject,
            configuration: build.configuration
        )
        if await approvals.isApproved(build.configuration, in: scope) {
            guard pendingBuild?.configuration == build.configuration else { return .unavailable }
            guard start(build) else {
                pendingBuild = nil
                pendingApproval = nil
                return .failed(issue?.message ?? "The build command could not be saved.")
            }
            pendingBuild = nil
            pendingApproval = nil
            return .started
        }
        return .awaitingApproval
    }

    @discardableResult
    private func start(_ build: PendingBuild) -> Bool {
        // Match Electron's commit boundary: editing remains an in-memory draft,
        // while the exact normalized command that passed approval is persisted
        // immediately before execution starts.
        if case .freeForm = build.approvalSubject,
           !persistFreeFormCommandBeforeStarting(build.configuration) {
            return false
        }
        generation &+= 1
        let currentGeneration = generation
        clearOutput()
        isRunning = true

        let parserID = UUID()
        let parserInput = BuildProblemParserInput()
        let outputDecoder = BuildUTF8OutputDecoder()
        let root = build.configuration.root
        let parserTask = Task.detached(priority: .utility) {
            await Self.parseProblems(
                from: parserInput, root: root, fileRegex: build.fileRegex
            )
        }
        problemParserID = parserID
        problemParserInput = parserInput
        problemParserTask = parserTask

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if build.saveBeforeBuild {
                let didSave = await saveBeforeBuild()
                guard didSave else {
                    parserInput.finish()
                    await parserTask.value
                    finish(generation: currentGeneration, exitCode: nil)
                    return
                }
            }
            guard isCurrent(currentGeneration) else { return }
            do {
                let command = try build.configuration.makeCommand(limits: ToolProcessLimits(
                    timeout: buildTimeout,
                    maximumStandardOutputBytes: ToolExecutionLimits.maximumStandardOutputBytes,
                    maximumStandardErrorBytes: ToolExecutionLimits.maximumStandardErrorBytes
                ))
                let result = try await runner.run(command) { [weak self] stream, data in
                    let text = outputDecoder.decode(data, from: stream)
                    guard !text.isEmpty else { return }
                    parserInput.yield(text)
                    Task { @MainActor [weak self] in
                        self?.append(text, stream: stream, generation: currentGeneration)
                    }
                }
                for (stream, text) in outputDecoder.finish() {
                    parserInput.yield(text)
                    Task { @MainActor [weak self] in
                        self?.append(text, stream: stream, generation: currentGeneration)
                    }
                }
                parserInput.finish()
                let parsed = await parserTask.value
                append(parsed, generation: currentGeneration, parserID: parserID)
                finish(generation: currentGeneration, exitCode: result.exitCode)
            } catch is CancellationError {
                parserInput.finish()
                parserTask.cancel()
                await parserTask.value
                finish(generation: currentGeneration, exitCode: nil)
            } catch ToolExecutionError.cancelled {
                parserInput.finish()
                parserTask.cancel()
                await parserTask.value
                finish(generation: currentGeneration, exitCode: nil)
            } catch {
                parserInput.finish()
                parserTask.cancel()
                await parserTask.value
                guard isCurrent(currentGeneration) else { return }
                present(error, title: .buildFailed)
                finish(generation: currentGeneration, exitCode: nil)
            }
        }
        return true
    }

    private func append(_ text: String, stream: ToolOutputStream, generation: UInt64) {
        guard isCurrent(generation) else { return }
        logEntries.append(BuildLogEntry(stream: stream, text: text))
        retainedCharacterCount += text.utf16.count
        trimLogIfNeeded()
    }

    private func append(
        _ parsed: [BuildProblem], generation: UInt64, parserID: UUID
    ) {
        guard isCurrent(generation), self.problemParserID == parserID else { return }
        problems = Array(parsed.prefix(Self.maximumProblems))
    }

    private func trimLogIfNeeded() {
        var excess = retainedCharacterCount - Self.maximumLogCharacters
        guard excess > 0 else { return }
        wasOutputTruncated = true
        while excess > 0, let first = logEntries.first {
            let count = first.text.utf16.count
            if count <= excess {
                logEntries.removeFirst()
                retainedCharacterCount -= count
                excess -= count
            } else {
                let retained = Self.droppingLeadingUTF16CodeUnits(
                    from: first.text, count: excess
                )
                logEntries[0] = BuildLogEntry(id: first.id, stream: first.stream, text: retained)
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

    private static func boundedPrefix(
        _ value: String, maximumUTF16Count: Int
    ) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var result = ""
        result.reserveCapacity(maximumUTF16Count)
        var count = 0
        for character in value {
            let width = String(character).utf16.count
            guard count + width <= maximumUTF16Count else { break }
            result.append(character)
            count += width
        }
        return result
    }

    private func finish(generation: UInt64, exitCode: Int32?) {
        guard isCurrent(generation) else { return }
        self.exitCode = exitCode
        isRunning = false
        operationTask = nil
        problemParserTask = nil
        problemParserInput = nil
        problemParserID = nil
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        generation == candidate && !Task.isCancelled
    }

    private func requireWorkspaceRoot() -> URL? {
        guard let workspaceRoot else {
            issue = BuildPresentationIssue(
                title: .noWorkspace,
                message: .noWorkspace
            )
            return nil
        }
        return workspaceRoot
    }

    private func present(
        _ error: any Error, title: BuildPresentationIssue.Title
    ) {
        let fallback: BuildPresentationIssue.Message
        switch error {
        case ToolExecutionError.timedOut:
            fallback = .timedOut
        case ToolExecutionError.outputLimitExceeded:
            fallback = .outputLimitExceeded
        case ToolProcessRunnerError.processQueueOverflow:
            fallback = .processQueueOverflow
        default:
            fallback = .operationFailed
        }
        issue = BuildPresentationIssue(
            title: title,
            message: fallback
        )
    }

    private nonisolated static func parseProblems(
        from input: BuildProblemParserInput,
        root: URL,
        fileRegex: String?
    ) async -> [BuildProblem] {
        guard var parser = BuildProblemStreamParser(
            root: root, fileRegex: fileRegex
        ) else { return [] }
        var result: [BuildProblem] = []
        for await _ in input.events {
            guard !Task.isCancelled else { return [] }
            let batch = input.takeBatch()
            result.append(contentsOf: parser.consume(batch.text))
            if batch.inputLimitReached { parser.inputLimitReached() }
            if parser.isExhausted { return result }
            await Task.yield()
        }
        let finalBatch = input.takeBatch()
        result.append(contentsOf: parser.consume(finalBatch.text))
        if finalBatch.inputLimitReached { parser.inputLimitReached() }
        result.append(contentsOf: parser.finish())
        return Task.isCancelled ? [] : result
    }
}
