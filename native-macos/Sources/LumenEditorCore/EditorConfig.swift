import Foundation
import Darwin

public enum EditorConfigPathStyle: Equatable, Sendable {
    case posix
    case win32
}

public enum EditorConfigIndentStyle: String, Codable, Equatable, Sendable {
    case space
    case tab
}

/// `indent_size` is either a concrete width or the special EditorConfig
/// `tab` value. Concrete widths are validated by the parser to be in 1...16.
public enum EditorConfigIndentSize: Equatable, Sendable {
    case columns(Int)
    case tab

    public var columnCount: Int? {
        guard case let .columns(value) = self else { return nil }
        return value
    }
}

public struct EditorConfigProperties: Equatable, Sendable {
    public var indentStyle: EditorConfigIndentStyle?
    public var indentSize: EditorConfigIndentSize?
    public var tabWidth: Int?
    public var endOfLine: LineEnding?

    public init(
        indentStyle: EditorConfigIndentStyle? = nil,
        indentSize: EditorConfigIndentSize? = nil,
        tabWidth: Int? = nil,
        endOfLine: LineEnding? = nil
    ) {
        self.indentStyle = indentStyle
        self.indentSize = indentSize
        self.tabWidth = tabWidth
        self.endOfLine = endOfLine
    }
}

public enum EditorConfigProperty: String, CaseIterable, Hashable, Sendable {
    case indentStyle = "indent_style"
    case indentSize = "indent_size"
    case tabWidth = "tab_width"
    case endOfLine = "end_of_line"
}

public enum EditorConfigAssignment: Equatable, Sendable {
    case indentStyle(EditorConfigIndentStyle)
    case indentSize(EditorConfigIndentSize)
    case tabWidth(Int)
    case endOfLine(LineEnding)
    case unset
}

public struct EditorConfigSection: Equatable, Sendable {
    public let pattern: String
    public let isValid: Bool
    public let assignments: [EditorConfigProperty: EditorConfigAssignment]

    public init(
        pattern: String,
        isValid: Bool,
        assignments: [EditorConfigProperty: EditorConfigAssignment]
    ) {
        self.pattern = pattern
        self.isValid = isValid
        self.assignments = assignments
    }

    /// Compatibility with the TypeScript model's `valid` spelling.
    public var valid: Bool { isValid }
}

public struct ParsedEditorConfig: Equatable, Sendable {
    public let isValid: Bool
    public let root: Bool
    public let sections: [EditorConfigSection]

    public init(isValid: Bool, root: Bool, sections: [EditorConfigSection]) {
        self.isValid = isValid
        self.root = root
        self.sections = sections
    }

    /// Compatibility with the TypeScript model's `valid` spelling.
    public var valid: Bool { isValid }
}

/// One in-memory config in an outermost-to-innermost cascade.
public struct EditorConfigSource: Equatable, Sendable {
    public let path: String
    public let source: String

    public init(path: String, source: String) {
        self.path = path
        self.source = source
    }

    public init(url: URL, source: String) {
        self.init(path: url.path, source: source)
    }
}

public struct IndentationPreferences: Equatable, Sendable {
    public let indentSize: Int
    public let tabWidth: Int
    public let insertSpaces: Bool

    public init(indentSize: Int, tabWidth: Int? = nil, insertSpaces: Bool) {
        self.indentSize = indentSize
        self.tabWidth = tabWidth ?? indentSize
        self.insertSpaces = insertSpaces
    }
}

/// A compiled section glob. Its matcher preserves JavaScript's UTF-16
/// code-unit semantics even though Foundation regular expressions normally
/// operate on Unicode scalars.
public struct EditorConfigGlob: @unchecked Sendable {
    fileprivate let expression: NSRegularExpression

    fileprivate init(expression: NSRegularExpression) {
        self.expression = expression
    }

    /// Match the complete candidate string, just like the anchored RegExp
    /// returned by the Electron implementation's compiler.
    public func matches(_ candidate: String) -> Bool {
        let encoded = EditorConfig.encodedUTF16ForMatching(candidate)
        let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
        return expression.firstMatch(in: encoded, range: range) != nil
    }
}

/// Bounds for project-owned `.editorconfig` discovery and reading.
public struct EditorConfigLimits: Equatable, Sendable {
    public static let `default` = EditorConfigLimits()

    public let maximumLevels: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int

    public init(
        maximumLevels: Int = 32,
        maximumFileBytes: Int = 64 * 1_024,
        maximumTotalBytes: Int = 512 * 1_024
    ) {
        precondition(maximumLevels >= 0)
        precondition(maximumFileBytes >= 0 && maximumFileBytes < Int.max)
        precondition(maximumTotalBytes >= 0 && maximumTotalBytes < Int.max)
        self.maximumLevels = maximumLevels
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }
}

public struct ResolvedEditorConfig: Equatable, Sendable {
    public let properties: EditorConfigProperties
    /// Config paths in outermost-to-innermost application order.
    public let sources: [URL]
    public let isTruncated: Bool

    public init(
        properties: EditorConfigProperties = EditorConfigProperties(),
        sources: [URL] = [],
        isTruncated: Bool = false
    ) {
        self.properties = properties
        self.sources = sources
        self.isTruncated = isTruncated
    }

    public var indentStyle: EditorConfigIndentStyle? { properties.indentStyle }
    public var indentSize: EditorConfigIndentSize? { properties.indentSize }
    public var tabWidth: Int? { properties.tabWidth }
    public var endOfLine: LineEnding? { properties.endOfLine }
    public var truncated: Bool { isTruncated }
}

/// Boundary violations are surfaced to the caller. Ordinary missing, invalid,
/// or racing config files safely degrade to an empty result.
public enum EditorConfigResolutionError: Error, Equatable, LocalizedError, Sendable {
    case invalidFileURL(URL)
    case targetOutsideWorkspace(URL)
    case symbolicLinkEscapesWorkspace(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            "EditorConfig paths must be absolute file URLs."
        case .targetOutsideWorkspace:
            "The EditorConfig target is outside the requested workspace root."
        case .symbolicLinkEscapesWorkspace:
            "The EditorConfig target resolves outside the requested workspace root."
        }
    }
}

/// Dependency-free EditorConfig parsing, matching, cascading, and safe reads.
public enum EditorConfig {
    public static let maximumLines = 4_096
    public static let maximumSections = 256
    public static let maximumGlobUTF16CodeUnits = 512

    // MARK: - Pure parsing and application

    public static func parse(_ source: String) -> ParsedEditorConfig {
        var text = source
        if text.unicodeScalars.first?.value == 0xfeff {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.contains("\r") else { return invalidParsedConfig }

        let lines = text.components(separatedBy: "\n")
        guard lines.count <= maximumLines else { return invalidParsedConfig }

        var root = false
        var sections: [MutableSection] = []
        var currentSectionIndex: Int?
        var inPreamble = true

        for originalLine in lines {
            let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") {
                inPreamble = false
                if line.hasSuffix("]") {
                    guard sections.count < maximumSections else { return invalidParsedConfig }
                    let pattern = String(line.dropFirst().dropLast())
                    sections.append(MutableSection(
                        pattern: pattern,
                        isValid: compileGlob(pattern) != nil,
                        assignments: [:]
                    ))
                    currentSectionIndex = sections.count - 1
                } else {
                    // Do not let pairs after a malformed header leak into the
                    // preceding valid section. A later valid header recovers.
                    currentSectionIndex = nil
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let valueStart = line.index(after: equals)
            let value = String(line[valueStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if inPreamble {
                guard key == "root" else { continue }
                switch value.lowercased() {
                case "true": root = true
                case "false": root = false
                default: break
                }
                continue
            }

            guard let index = currentSectionIndex, sections[index].isValid,
                  let property = EditorConfigProperty(rawValue: key),
                  let parsedAssignment = assignment(for: property, rawValue: value) else {
                continue
            }
            sections[index].assignments[property] = parsedAssignment
        }

        return ParsedEditorConfig(
            isValid: true,
            root: root,
            sections: sections.map { section in
                EditorConfigSection(
                    pattern: section.pattern,
                    isValid: section.isValid,
                    assignments: section.assignments
                )
            }
        )
    }

    /// Compile a supported section glob. `nil` means that the section is
    /// invalid and can never match. Matching is deliberately case-sensitive.
    public static func compileGlob(_ pattern: String) -> EditorConfigGlob? {
        let codeUnits = Array(pattern.utf16)
        guard !codeUnits.isEmpty,
              codeUnits.count <= maximumGlobUTF16CodeUnits,
              codeUnits.last != slash else {
            return nil
        }
        let normalized = codeUnits.contains(slash) && codeUnits.first == slash
            ? Array(codeUnits.dropFirst())
            : codeUnits
        guard let fragment = compileFragment(normalized, allowBrace: true) else {
            return nil
        }
        guard let expression = try? NSRegularExpression(pattern: "^\(fragment)$") else {
            return nil
        }
        return EditorConfigGlob(expression: expression)
    }

    public static func globMatches(_ pattern: String, relativePath: String) -> Bool {
        guard let expression = compileGlob(pattern) else { return false }
        let rawCandidate: String
        if pattern.utf16.contains(slash) {
            rawCandidate = relativePath
        } else {
            let candidateCodeUnits = Array(relativePath.utf16)
            if let separator = candidateCodeUnits.lastIndex(of: slash) {
                rawCandidate = String(
                    decoding: candidateCodeUnits.suffix(from: separator + 1),
                    as: UTF16.self
                )
            } else {
                rawCandidate = relativePath
            }
        }
        return expression.matches(rawCandidate)
    }

    /// Return a forward-slash path strictly below `directory`, or `nil` when
    /// the paths are unrelated or malformed for the selected path style.
    public static func relativePath(
        from directory: String,
        to targetPath: String,
        style: EditorConfigPathStyle = .posix
    ) -> String? {
        guard let base = normalizePath(directory, style: style),
              let target = normalizePath(targetPath, style: style),
              base.root == target.root,
              target.parts.count > base.parts.count else {
            return nil
        }
        for index in base.parts.indices {
            let left = style == .win32 ? base.parts[index].lowercased() : base.parts[index]
            let right = style == .win32 ? target.parts[index].lowercased() : target.parts[index]
            guard left == right else { return nil }
        }
        return target.parts.dropFirst(base.parts.count).joined(separator: "/")
    }

    public static func apply(
        _ config: ParsedEditorConfig,
        to relativePath: String,
        over base: EditorConfigProperties = EditorConfigProperties()
    ) -> EditorConfigProperties {
        var result = base
        guard config.isValid else { return result }

        for section in config.sections
        where section.isValid && globMatches(section.pattern, relativePath: relativePath) {
            for (property, value) in section.assignments {
                switch (property, value) {
                case (.indentStyle, .unset): result.indentStyle = nil
                case (.indentSize, .unset): result.indentSize = nil
                case (.tabWidth, .unset): result.tabWidth = nil
                case (.endOfLine, .unset): result.endOfLine = nil
                case let (.indentStyle, .indentStyle(style)): result.indentStyle = style
                case let (.indentSize, .indentSize(size)): result.indentSize = size
                case let (.tabWidth, .tabWidth(width)): result.tabWidth = width
                case let (.endOfLine, .endOfLine(ending)): result.endOfLine = ending
                default:
                    // Parsed assignments always pair with their own property.
                    // Ignore inconsistent manually-created values defensively.
                    break
                }
            }
        }
        return result
    }

    /// Apply all applicable sources from distant ancestors to the nearest
    /// config. Sorting by depth makes the result independent of traversal order.
    public static func apply(
        _ sources: [EditorConfigSource],
        to targetPath: String,
        style: EditorConfigPathStyle = .posix
    ) -> EditorConfigProperties {
        var applicable: [ApplicableConfig] = []
        for (sourceIndex, source) in sources.enumerated() {
            let config = parse(source.source)
            guard config.isValid else { continue }
            let directory = configDirectory(for: source.path, style: style)
            guard let relative = relativePath(
                from: directory,
                to: targetPath,
                style: style
            ) else { continue }
            applicable.append(ApplicableConfig(
                config: config,
                relativePath: relative,
                depth: relative.split(separator: "/").count,
                sourceIndex: sourceIndex
            ))
        }
        applicable.sort { left, right in
            if left.depth != right.depth { return left.depth > right.depth }
            return left.sourceIndex < right.sourceIndex
        }

        var result = EditorConfigProperties()
        for item in applicable {
            if item.config.root { result = EditorConfigProperties() }
            result = apply(item.config, to: item.relativePath, over: result)
        }
        return result
    }

    public static func resolveIndentation(
        config: EditorConfigProperties?,
        detected: IndentationPreferences,
        defaultTabWidth: Int
    ) -> IndentationPreferences {
        let fallbackTabWidth = min(16, max(1, defaultTabWidth))
        let requestedIndentSize: Int
        if let configuredIndentSize = config?.indentSize {
            switch configuredIndentSize {
            case let .columns(value): requestedIndentSize = value
            case .tab: requestedIndentSize = config?.tabWidth ?? fallbackTabWidth
            }
        } else {
            requestedIndentSize = detected.indentSize
        }

        let tabWidth: Int
        if let configured = config?.tabWidth {
            tabWidth = configured
        } else if case let .columns(value)? = config?.indentSize {
            tabWidth = value
        } else if config?.indentSize == .tab {
            tabWidth = fallbackTabWidth
        } else {
            tabWidth = detected.indentSize
        }

        let insertSpaces = config?.indentStyle.map { $0 == .space }
            ?? detected.insertSpaces
        return IndentationPreferences(
            indentSize: insertSpaces ? requestedIndentSize : tabWidth,
            tabWidth: tabWidth,
            insertSpaces: insertSpaces
        )
    }

    // MARK: - Capability-bounded file resolution

    /// Resolve project-owned EditorConfig files without reading outside the
    /// caller-provided workspace capability boundary. The caller must pass the
    /// exact root it has authorised; this function never searches above it.
    public static func resolve(
        for targetURL: URL,
        workspaceRoot rootURL: URL,
        allowMissingTarget: Bool = false,
        limits: EditorConfigLimits = .default
    ) throws -> ResolvedEditorConfig {
        let root = try absoluteFileURL(rootURL)
        let target = try absoluteFileURL(targetURL)
        guard contains(root, target) else {
            throw EditorConfigResolutionError.targetOutsideWorkspace(target)
        }

        let realRoot: URL
        let rootIdentity: FileIdentity
        do {
            realRoot = try resolvedExistingURL(root)
            let status = try fileStatus(at: realRoot, followingSymbolicLink: true)
            guard isDirectory(status) else { return ResolvedEditorConfig() }
            rootIdentity = FileIdentity(status)
        } catch {
            return ResolvedEditorConfig()
        }
        let realTarget: URL
        do {
            realTarget = try resolvedExistingURL(target)
        } catch {
            guard allowMissingTarget, isNoEntry(error) else {
                return ResolvedEditorConfig()
            }
            do {
                let parent = try resolvedExistingURL(target.deletingLastPathComponent())
                realTarget = parent.appendingPathComponent(
                    target.lastPathComponent,
                    isDirectory: false
                ).standardizedFileURL
            } catch {
                return ResolvedEditorConfig()
            }
        }
        guard contains(realRoot, realTarget) else {
            throw EditorConfigResolutionError.symbolicLinkEscapesWorkspace(target)
        }

        var configsNearToFar: [(url: URL, source: String)] = []
        var directory = target.deletingLastPathComponent().standardizedFileURL
        var totalBytes = 0
        var isTruncated = false

        if limits.maximumLevels == 0, contains(root, directory) {
            return ResolvedEditorConfig(isTruncated: true)
        }

        for level in 0..<limits.maximumLevels {
            guard contains(root, directory) else { break }
            guard rootIsUnchanged(root, realRoot: realRoot, identity: rootIdentity) else {
                return ResolvedEditorConfig()
            }

            let candidate = directory.appendingPathComponent(
                ".editorconfig",
                isDirectory: false
            ).standardizedFileURL
            var reachedRootDeclaration = false
            switch inspectCandidate(
                candidate,
                realRoot: realRoot,
                totalBytes: totalBytes,
                limits: limits
            ) {
            case .missing:
                break
            case .rejected:
                return ResolvedEditorConfig()
            case .truncated:
                return ResolvedEditorConfig(isTruncated: true)
            case let .source(source, byteCount):
                totalBytes += byteCount
                let parsed = parse(source)
                guard parsed.isValid else { return ResolvedEditorConfig() }
                configsNearToFar.append((candidate, source))
                reachedRootDeclaration = parsed.root
            }

            if reachedRootDeclaration { break }
            if directory == root { break }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory { break }
            directory = parent
            if level == limits.maximumLevels - 1, contains(root, directory) {
                isTruncated = true
            }
        }

        guard rootIsUnchanged(root, realRoot: realRoot, identity: rootIdentity) else {
            return ResolvedEditorConfig()
        }
        if isTruncated { return ResolvedEditorConfig(isTruncated: true) }

        let configs = Array(configsNearToFar.reversed())
        let sources = configs.map { EditorConfigSource(url: $0.url, source: $0.source) }
        return ResolvedEditorConfig(
            properties: apply(sources, to: target.path, style: .posix),
            sources: configs.map { $0.url },
            isTruncated: false
        )
    }

    // MARK: - Parser helpers

    private struct MutableSection {
        let pattern: String
        let isValid: Bool
        var assignments: [EditorConfigProperty: EditorConfigAssignment]
    }

    private struct NormalPath {
        let root: String
        let parts: [String]
    }

    private struct ApplicableConfig {
        let config: ParsedEditorConfig
        let relativePath: String
        let depth: Int
        let sourceIndex: Int
    }

    private static let invalidParsedConfig = ParsedEditorConfig(
        isValid: false,
        root: false,
        sections: []
    )

    private static func assignment(
        for property: EditorConfigProperty,
        rawValue: String
    ) -> EditorConfigAssignment? {
        let value = rawValue.lowercased()
        if value == "unset" { return .unset }
        switch property {
        case .indentStyle:
            guard let style = EditorConfigIndentStyle(rawValue: value) else { return nil }
            return .indentStyle(style)
        case .endOfLine:
            guard let ending = LineEnding(rawValue: value.uppercased()) else { return nil }
            return .endOfLine(ending)
        case .indentSize:
            if value == "tab" { return .indentSize(.tab) }
            guard let width = editorConfigWidth(value) else { return nil }
            return .indentSize(.columns(width))
        case .tabWidth:
            guard let width = editorConfigWidth(value) else { return nil }
            return .tabWidth(width)
        }
    }

    private static func editorConfigWidth(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              value.first != "0",
              let number = Int(value),
              (1...16).contains(number) else {
            return nil
        }
        return number
    }

    private static let slash: UInt16 = 0x2f
    private static let backslash: UInt16 = 0x5c
    private static let asterisk: UInt16 = 0x2a
    private static let questionMark: UInt16 = 0x3f
    private static let leftBracket: UInt16 = 0x5b
    private static let rightBracket: UInt16 = 0x5d
    private static let leftBrace: UInt16 = 0x7b
    private static let rightBrace: UInt16 = 0x7d
    private static let comma: UInt16 = 0x2c
    private static let exclamationMark: UInt16 = 0x21
    private static let hyphen: UInt16 = 0x2d
    private static let caret: UInt16 = 0x5e

    /// ICU regexes operate on Unicode scalars while JavaScript regexes without
    /// `u` operate on UTF-16 code units. Map every code unit to one private-use
    /// scalar so `?`, character classes, and astral characters retain the
    /// exact TypeScript behavior without constructing ill-formed Swift text.
    private static func encodedCodeUnit(_ codeUnit: UInt16) -> String {
        String(UnicodeScalar(0x10_000 + UInt32(codeUnit))!)
    }

    fileprivate static func encodedUTF16ForMatching(_ value: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(value.utf16.count)
        for codeUnit in value.utf16 {
            scalars.append(UnicodeScalar(0x10_000 + UInt32(codeUnit))!)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func escapeRegex(_ codeUnit: UInt16) -> String {
        encodedCodeUnit(codeUnit)
    }

    private static func compileCharacterClass(
        _ pattern: [UInt16],
        start: Int
    ) -> (source: String, end: Int)? {
        var cursor = start + 1
        var negate = false
        if cursor < pattern.count, pattern[cursor] == exclamationMark {
            negate = true
            cursor += 1
        }
        var members: [(value: UInt16, escaped: Bool)] = []
        var closed = false
        while cursor < pattern.count {
            let member = pattern[cursor]
            if member == rightBracket, !members.isEmpty {
                closed = true
                break
            }
            if member == backslash {
                cursor += 1
                guard cursor < pattern.count else { return nil }
                members.append((pattern[cursor], true))
            } else {
                guard member != slash else { return nil }
                members.append((member, false))
            }
            cursor += 1
        }
        guard closed, !members.isEmpty else { return nil }

        var body = ""
        for (index, member) in members.enumerated() {
            if member.escaped {
                body += encodedCodeUnit(member.value)
            } else if member.value == hyphen {
                if index > 0 && index < members.count - 1 {
                    body.append("-")
                } else {
                    body += encodedCodeUnit(hyphen)
                }
            } else {
                body += encodedCodeUnit(member.value)
            }
        }
        return ("[\(negate ? "^" : "")\(body)]", cursor)
    }

    private static func compileFragment(
        _ pattern: [UInt16],
        allowBrace: Bool
    ) -> String? {
        var result = ""
        var index = 0
        while index < pattern.count {
            let character = pattern[index]
            if character == backslash {
                index += 1
                guard index < pattern.count else { return nil }
                result += escapeRegex(pattern[index])
            } else if character == asterisk {
                if index + 1 < pattern.count, pattern[index + 1] == asterisk {
                    index += 1
                    while index + 1 < pattern.count, pattern[index + 1] == asterisk {
                        index += 1
                    }
                    if index + 1 < pattern.count, pattern[index + 1] == slash {
                        index += 1
                        result += "(?:.*\(encodedCodeUnit(slash)))?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^\(encodedCodeUnit(slash))]*"
                }
            } else if character == questionMark {
                result += "[^\(encodedCodeUnit(slash))]"
            } else if character == leftBracket {
                guard let characterClass = compileCharacterClass(pattern, start: index) else {
                    return nil
                }
                result += characterClass.source
                index = characterClass.end
            } else if character == leftBrace {
                guard allowBrace else { return nil }
                var cursor = index + 1
                var part: [UInt16] = []
                var parts: [[UInt16]] = []
                var closed = false
                while cursor < pattern.count {
                    let member = pattern[cursor]
                    if member == leftBrace {
                        return nil
                    } else if member == backslash {
                        guard cursor + 1 < pattern.count else { return nil }
                        part.append(member)
                        cursor += 1
                        part.append(pattern[cursor])
                    } else if member == comma {
                        parts.append(part)
                        part = []
                    } else if member == rightBrace {
                        parts.append(part)
                        closed = true
                        break
                    } else {
                        part.append(member)
                    }
                    cursor += 1
                }
                guard closed, parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else {
                    return nil
                }
                var compiled: [String] = []
                for part in parts {
                    guard let fragment = compileFragment(part, allowBrace: false) else {
                        return nil
                    }
                    compiled.append(fragment)
                }
                result += "(?:\(compiled.joined(separator: "|")))"
                index = cursor
            } else if character == rightBracket || character == rightBrace {
                return nil
            } else {
                result += escapeRegex(character)
            }
            index += 1
        }
        return result
    }

    private static func normalizePath(
        _ input: String,
        style: EditorConfigPathStyle
    ) -> NormalPath? {
        var value = style == .win32
            ? input.replacingOccurrences(of: "\\", with: "/")
            : input
        let root: String

        if style == .win32 {
            let characters = Array(value)
            if characters.count >= 2,
               characters[0].isASCII, characters[0].isLetter,
               characters[1] == ":",
               (characters.count == 2 || characters[2] == "/") {
                root = String(characters[0...1]).lowercased()
                value = characters.count == 2 ? "" : String(characters.dropFirst(3))
            } else if value.hasPrefix("//") {
                let remainder = String(value.dropFirst(2))
                guard let serverEnd = remainder.firstIndex(of: "/") else { return nil }
                let server = String(remainder[..<serverEnd])
                let afterServer = remainder[remainder.index(after: serverEnd)...]
                guard !server.isEmpty, !afterServer.isEmpty else { return nil }
                if let shareEnd = afterServer.firstIndex(of: "/") {
                    let share = String(afterServer[..<shareEnd])
                    guard !share.isEmpty else { return nil }
                    root = "//\(server.lowercased())/\(share.lowercased())"
                    value = String(afterServer[afterServer.index(after: shareEnd)...])
                } else {
                    root = "//\(server.lowercased())/\(afterServer.lowercased())"
                    value = ""
                }
            } else {
                return nil
            }
        } else {
            guard value.hasPrefix("/") else { return nil }
            root = "/"
            value.removeFirst()
        }

        var parts: [String] = []
        for part in value.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return NormalPath(root: root, parts: parts)
    }

    private static func configDirectory(
        for sourcePath: String,
        style: EditorConfigPathStyle
    ) -> String {
        let characters = Array(sourcePath)
        guard let slash = characters.indices.last(where: {
            characters[$0] == "/" || characters[$0] == "\\"
        }) else {
            return sourcePath
        }
        if slash == 0 { return "/" }
        if style == .win32, slash == 2, characters.count >= 2, characters[1] == ":" {
            return String(characters[0...2])
        }
        return String(characters[..<slash])
    }

    // MARK: - Secure file helpers

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private enum CandidateResult {
        case missing
        case rejected
        case truncated
        case source(String, Int)
    }

    private static func inspectCandidate(
        _ candidate: URL,
        realRoot: URL,
        totalBytes: Int,
        limits: EditorConfigLimits
    ) -> CandidateResult {
        let initialStatus: stat
        do {
            initialStatus = try fileStatus(at: candidate, followingSymbolicLink: false)
        } catch {
            return isNoEntry(error) ? .missing : .rejected
        }
        guard isRegularFile(initialStatus) else { return .rejected }

        let initialSize = Int64(initialStatus.st_size)
        guard initialSize >= 0 else { return .rejected }
        let remainingTotal = max(0, limits.maximumTotalBytes - totalBytes)
        if initialSize > Int64(limits.maximumFileBytes)
            || initialSize > Int64(remainingTotal) {
            return .truncated
        }

        do {
            let realCandidate = try resolvedExistingURL(candidate)
            guard contains(realRoot, realCandidate) else { return .rejected }
        } catch {
            return .rejected
        }

        let remaining = min(
            limits.maximumFileBytes,
            remainingTotal
        )
        return readBounded(
            candidate,
            byteLimit: remaining,
            expectedIdentity: FileIdentity(initialStatus)
        )
    }

    private static func readBounded(
        _ url: URL,
        byteLimit: Int,
        expectedIdentity: FileIdentity
    ) -> CandidateResult {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return .rejected }
        defer { _ = Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              isRegularFile(openedStatus),
              FileIdentity(openedStatus) == expectedIdentity,
              openedStatus.st_size >= 0,
              Int64(openedStatus.st_size) <= Int64(byteLimit) else {
            return .truncated
        }

        var data = Data()
        let boundedReadCount = byteLimit + 1
        data.reserveCapacity(min(boundedReadCount, 8 * 1_024))
        var buffer = [UInt8](repeating: 0, count: min(max(boundedReadCount, 1), 8 * 1_024))
        while data.count <= byteLimit {
            let requested = min(buffer.count, boundedReadCount - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .truncated
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= byteLimit, let source = String(data: data, encoding: .utf8) else {
            return .truncated
        }
        return .source(source, data.count)
    }

    private static func absoluteFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw EditorConfigResolutionError.invalidFileURL(url)
        }
        // `URL.standardizedFileURL` resolves symlinks on Darwin and
        // swift-corelibs Foundation. Standardise components lexically so the
        // subsequent explicit realpath containment check can distinguish a
        // logical in-root path from its escaped target.
        return URL(fileURLWithPath: (url.path as NSString).standardizingPath)
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" { return candidatePath.hasPrefix("/") }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func resolvedExistingURL(_ url: URL) throws -> URL {
        try url.path.withCString { path in
            guard let resolved = Darwin.realpath(path, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
        }
    }

    private static func fileStatus(
        at url: URL,
        followingSymbolicLink: Bool
    ) throws -> stat {
        var status = stat()
        let result = url.path.withCString { path in
            followingSymbolicLink ? Darwin.stat(path, &status) : Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }

    private static func isDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isNoEntry(_ error: any Error) -> Bool {
        (error as? POSIXError)?.code == .ENOENT
    }

    private static func rootIsUnchanged(
        _ logicalRoot: URL,
        realRoot: URL,
        identity: FileIdentity
    ) -> Bool {
        guard let currentRoot = try? resolvedExistingURL(logicalRoot),
              currentRoot == realRoot,
              let status = try? fileStatus(at: currentRoot, followingSymbolicLink: true),
              isDirectory(status),
              FileIdentity(status) == identity else {
            return false
        }
        return true
    }
}

// MARK: - TypeScript-parity free functions

public func parseEditorConfig(_ source: String) -> ParsedEditorConfig {
    EditorConfig.parse(source)
}

public func compileEditorConfigGlob(_ pattern: String) -> EditorConfigGlob? {
    EditorConfig.compileGlob(pattern)
}

public func editorConfigGlobMatches(_ pattern: String, _ relativePath: String) -> Bool {
    EditorConfig.globMatches(pattern, relativePath: relativePath)
}

public func editorConfigRelativePath(
    _ directory: String,
    _ targetPath: String,
    _ style: EditorConfigPathStyle = .posix
) -> String? {
    EditorConfig.relativePath(from: directory, to: targetPath, style: style)
}

public func applyEditorConfig(
    _ base: EditorConfigProperties,
    _ config: ParsedEditorConfig,
    _ relativePath: String
) -> EditorConfigProperties {
    EditorConfig.apply(config, to: relativePath, over: base)
}

public func applyEditorConfigChain(
    _ sources: [EditorConfigSource],
    _ targetPath: String,
    _ style: EditorConfigPathStyle = .posix
) -> EditorConfigProperties {
    EditorConfig.apply(sources, to: targetPath, style: style)
}

public func resolveEditorConfigIndentation(
    _ config: EditorConfigProperties?,
    _ detected: IndentationPreferences,
    _ defaultTabWidth: Int
) -> IndentationPreferences {
    EditorConfig.resolveIndentation(
        config: config,
        detected: detected,
        defaultTabWidth: defaultTabWidth
    )
}

public func resolveEditorConfig(
    for targetURL: URL,
    workspaceRoot rootURL: URL,
    allowMissingTarget: Bool = false,
    limits: EditorConfigLimits = .default
) throws -> ResolvedEditorConfig {
    try EditorConfig.resolve(
        for: targetURL,
        workspaceRoot: rootURL,
        allowMissingTarget: allowMissingTarget,
        limits: limits
    )
}
