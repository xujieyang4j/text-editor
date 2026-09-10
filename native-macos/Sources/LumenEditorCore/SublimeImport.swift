@preconcurrency import Foundation

public enum SublimeImportError: Error, Equatable, LocalizedError, Sendable {
    case inputTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case expectedObject
    case missingBuildCommand
    case expectedKeymapArray
    case invalidSourceURL
    case noProjectFolders
    case missingSnippetContent
    case snippetContentTooLarge

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(actual, maximum):
            return "The selected Sublime file uses \(actual) bytes; the maximum is \(maximum) bytes."
        case .invalidJSON:
            return "The selected Sublime file is not valid JSON."
        case .expectedObject:
            return "The selected Sublime file must contain a JSON object."
        case .missingBuildCommand:
            return "The selected .sublime-build file must declare a non-empty cmd or shell_cmd."
        case .expectedKeymapArray:
            return "The selected .sublime-keymap file must contain a JSON array."
        case .invalidSourceURL:
            return "A Sublime import source must be an absolute local file URL."
        case .noProjectFolders:
            return "No folders were declared in the selected .sublime-project."
        case .missingSnippetContent:
            return "The selected Sublime snippet does not contain non-empty content."
        case .snippetContentTooLarge:
            return "The Sublime snippet content exceeds 10,000 UTF-16 code units."
        }
    }
}

public struct SublimeImportLimits: Equatable, Sendable {
    public static let `default` = SublimeImportLimits()

    public var maximumJSONBytes: Int
    public var maximumSnippetBytes: Int
    public var maximumProjectRoots: Int
    public var maximumExclusions: Int
    public var maximumBuildSystems: Int
    public var maximumBuildVariants: Int
    public var maximumKeymapEntriesInspected: Int
    public var maximumKeyBindings: Int

    public init(
        maximumJSONBytes: Int = 1_024 * 1_024,
        maximumSnippetBytes: Int = 128 * 1_024,
        maximumProjectRoots: Int = 20,
        maximumExclusions: Int = 100,
        maximumBuildSystems: Int = 30,
        maximumBuildVariants: Int = 20,
        maximumKeymapEntriesInspected: Int = 500,
        maximumKeyBindings: Int = 200
    ) {
        precondition(maximumJSONBytes >= 0 && maximumSnippetBytes >= 0)
        precondition(maximumProjectRoots > 0 && maximumExclusions > 0)
        precondition(maximumBuildSystems > 0 && maximumBuildVariants > 0)
        precondition(maximumKeymapEntriesInspected > 0 && maximumKeyBindings > 0)
        self.maximumJSONBytes = maximumJSONBytes
        self.maximumSnippetBytes = maximumSnippetBytes
        self.maximumProjectRoots = maximumProjectRoots
        self.maximumExclusions = maximumExclusions
        self.maximumBuildSystems = maximumBuildSystems
        self.maximumBuildVariants = maximumBuildVariants
        self.maximumKeymapEntriesInspected = maximumKeymapEntriesInspected
        self.maximumKeyBindings = maximumKeyBindings
    }
}

public struct SublimeBuildVariantImport: Equatable, Sendable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let fileRegex: String?
    public let environment: [String: String]
    public let usesShell: Bool

    public init(
        name: String, command: String, arguments: [String] = [],
        workingDirectory: String? = nil, fileRegex: String? = nil,
        environment: [String: String] = [:], usesShell: Bool = false
    ) {
        self.name = name; self.command = command; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.fileRegex = fileRegex
        self.environment = environment; self.usesShell = usesShell
    }
}

public struct SublimeBuildSystemImport: Equatable, Sendable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let fileRegex: String?
    public let environment: [String: String]
    public let usesShell: Bool
    public let variants: [SublimeBuildVariantImport]

    public init(
        name: String, command: String, arguments: [String] = [],
        workingDirectory: String? = nil, fileRegex: String? = nil,
        environment: [String: String] = [:], usesShell: Bool = false,
        variants: [SublimeBuildVariantImport] = []
    ) {
        self.name = name; self.command = command; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.fileRegex = fileRegex
        self.environment = environment; self.usesShell = usesShell; self.variants = variants
    }
}

public struct SublimeProjectImport: Equatable, Sendable {
    public let sourceURL: URL
    /// Paths are lexical absolute URLs only. Parsing does not inspect, open, or
    /// authorise them; the confirmation callback must validate every root.
    public let roots: [URL]
    public let exclusions: [String]
    public let buildSystems: [SublimeBuildSystemImport]

    public init(
        sourceURL: URL, roots: [URL], exclusions: [String],
        buildSystems: [SublimeBuildSystemImport]
    ) {
        self.sourceURL = sourceURL; self.roots = roots
        self.exclusions = exclusions; self.buildSystems = buildSystems
    }

    public var projectSettings: WindowSessionProject {
        WindowSessionProject([
            "exclude": .array(exclusions.map(WindowSessionJSONValue.string)),
            "buildCommand": .string(""),
            "keyBindings": .object([:]),
            "plugins": .array([]),
            "pluginPermissions": .object([:]),
            "languageTools": .object([:]),
            "languageServers": .object([:]),
            "buildSystems": .array(buildSystems.map(\.jsonValue)),
            "keyBindingRules": .array([]),
            "marketplaceUrls": .array([]),
            "snippets": .array([])
        ])
    }
}

public enum SublimeSettingKey: String, CaseIterable, Sendable {
    case fontSize
    case tabSize
    case insertSpaces
    case wordWrap
    case showLineNumbers
    case showWhitespace
    case rulers
    case spellCheck
    case autoSave
    case autoSaveDelayMs
    case colorScheme
}

public struct SublimeSettingChange: Equatable, Sendable {
    public let key: SublimeSettingKey
    public let oldValue: String
    public let newValue: String

    public init(key: SublimeSettingKey, oldValue: String, newValue: String) {
        self.key = key; self.oldValue = oldValue; self.newValue = newValue
    }
}

public struct SublimeSettingsImport: Equatable, Sendable {
    public let sourceURL: URL
    public let settings: EditorSettings
    public let changes: [SublimeSettingChange]

    public init(sourceURL: URL, settings: EditorSettings, changes: [SublimeSettingChange]) {
        self.sourceURL = sourceURL; self.settings = settings; self.changes = changes
    }
}

public struct SublimeKeymapImport: Equatable, Sendable {
    public let sourceURL: URL
    public let overrides: [KeyBindingOverride]
    public let skipped: Int
    public let inspected: Int
    public let wasTruncated: Bool

    public init(
        sourceURL: URL, overrides: [KeyBindingOverride], skipped: Int,
        inspected: Int, wasTruncated: Bool
    ) {
        self.sourceURL = sourceURL; self.overrides = overrides
        self.skipped = skipped; self.inspected = inspected; self.wasTruncated = wasTruncated
    }

    /// Native override lookup is last-wins by command and context. Imported
    /// bindings therefore replace matching existing entries and are appended.
    public func merging(into existing: [KeyBindingOverride]) -> [KeyBindingOverride] {
        let incomingKeys = Set(overrides.map { OverrideKey($0) })
        return Array(
            (existing.filter { !incomingKeys.contains(OverrideKey($0)) } + overrides)
                .suffix(SublimeImportLimits.default.maximumKeyBindings)
        )
    }
}

public struct SublimeSnippetImport: Equatable, Sendable {
    public let sourceURL: URL
    public let label: String
    public let text: String
    public let trigger: String?
    public let scope: String?

    public init(
        sourceURL: URL, label: String, text: String,
        trigger: String? = nil, scope: String? = nil
    ) {
        self.sourceURL = sourceURL; self.label = label; self.text = text
        self.trigger = trigger; self.scope = scope
    }
}

public enum SublimeImportParser {
    public static func parseBuildSystem(
        _ data: Data,
        sourceURL: URL,
        limits: SublimeImportLimits = .default
    ) throws -> SublimeBuildSystemImport {
        try requireSourceURL(sourceURL)
        let value = try jsonObject(
            data, maximumBytes: limits.maximumJSONBytes, allowsComments: true
        )
        guard value is [String: Any] else { throw SublimeImportError.expectedObject }
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        guard let system = parseBuildSystem(
            value, fallbackName: fallbackName, limits: limits
        ) else {
            throw SublimeImportError.missingBuildCommand
        }
        return system
    }

    public static func parseProject(
        _ data: Data,
        sourceURL: URL,
        limits: SublimeImportLimits = .default
    ) throws -> SublimeProjectImport {
        try requireSourceURL(sourceURL)
        let object = try jsonObject(
            data, maximumBytes: limits.maximumJSONBytes, allowsComments: false
        )
        guard let raw = object as? [String: Any] else { throw SublimeImportError.expectedObject }
        let base = sourceURL.deletingLastPathComponent().standardizedFileURL
        let folders = raw["folders"] as? [Any] ?? []
        var rootCandidates: [URL] = []
        var exclusions: [String] = []

        for value in folders {
            guard let folder = value as? [String: Any] else { continue }
            if rootCandidates.count < limits.maximumProjectRoots,
               let path = folder["path"] as? String,
               let url = absoluteURL(path, relativeTo: base) {
                // Electron applies the 20-entry bound before de-duplicating.
                rootCandidates.append(url)
            }
            for key in ["file_exclude_patterns", "folder_exclude_patterns"] {
                guard exclusions.count < limits.maximumExclusions else { break }
                for case let pattern as String in (folder[key] as? [Any] ?? []) {
                    let imported = pattern.contains("*") ? pattern : "**/\(pattern)/**"
                    exclusions.append(truncate(imported, utf16: 200))
                    if exclusions.count == limits.maximumExclusions { break }
                }
                if exclusions.count == limits.maximumExclusions { break }
            }
        }
        var seenRoots = Set<String>()
        let roots = rootCandidates.filter { seenRoots.insert($0.path).inserted }
        guard !roots.isEmpty else { throw SublimeImportError.noProjectFolders }

        let systems = (raw["build_systems"] as? [Any] ?? []).compactMap {
            parseBuildSystem($0, fallbackName: nil, limits: limits)
        }
        return SublimeProjectImport(
            sourceURL: sourceURL.standardizedFileURL,
            roots: roots,
            exclusions: Array(exclusions.prefix(limits.maximumExclusions)),
            buildSystems: Array(systems.prefix(limits.maximumBuildSystems))
        )
    }

    public static func parseSettings(
        _ data: Data,
        sourceURL: URL,
        current: EditorSettings,
        limits: SublimeImportLimits = .default
    ) throws -> SublimeSettingsImport {
        try requireSourceURL(sourceURL)
        let value = try jsonObject(
            data, maximumBytes: limits.maximumJSONBytes, allowsComments: true
        )
        let raw = value as? [String: Any] ?? [:]
        var next = current
        if let value = finiteNumber(raw["font_size"]) { next.fontSize = boundedInt(value, 8, 40) }
        if let value = finiteNumber(raw["tab_size"]) { next.tabSize = boundedInt(value, 1, 16) }
        if let value = strictBool(raw["translate_tabs_to_spaces"]) { next.insertSpaces = value }
        if let value = strictBool(raw["word_wrap"]) { next.wordWrap = value }
        if let value = strictBool(raw["line_numbers"]) { next.showLineNumbers = value }
        if let value = raw["draw_white_space"] as? String {
            next.showWhitespace = value == "all" || value == "selection"
        }
        if let values = raw["rulers"] as? [Any] {
            next.rulers = Array(values.compactMap(finiteNumber)
                .filter { $0 > 0 && $0 <= 500 }
                .map { Int($0.rounded(.toNearestOrAwayFromZero)) }.prefix(10))
        }
        if let value = strictBool(raw["spell_check"]) { next.spellCheck = value }
        if let value = raw["auto_save"] as? String,
           let mode = AutoSaveMode(rawValue: value), mode != .off { next.autoSave = mode }
        if let value = finiteNumber(raw["auto_save_delay"]) {
            next.autoSaveDelayMs = boundedInt(value, 250, 60_000)
        }
        if let scheme = (raw["color_scheme"] as? String)?.lowercased() {
            if scheme.contains("solarized") { next.colorScheme = .solarizedDark }
            else if scheme.contains("dracula") { next.colorScheme = .dracula }
            else if scheme.contains("light") { next.colorScheme = .light }
        }
        next = next.sanitized()
        return SublimeSettingsImport(
            sourceURL: sourceURL.standardizedFileURL, settings: next,
            changes: settingChanges(from: current, to: next)
        )
    }

    public static func parseKeymap(
        _ data: Data,
        sourceURL: URL,
        limits: SublimeImportLimits = .default
    ) throws -> SublimeKeymapImport {
        try requireSourceURL(sourceURL)
        let value = try jsonObject(
            data, maximumBytes: limits.maximumJSONBytes, allowsComments: true
        )
        guard let entries = value as? [Any] else { throw SublimeImportError.expectedKeymapArray }
        let inspectedEntries = Array(entries.prefix(limits.maximumKeymapEntriesInspected))
        var overrides: [KeyBindingOverride] = []
        var skipped = 0
        var supported = 0
        for value in inspectedEntries {
            guard let raw = value as? [String: Any],
                  let sublimeCommand = raw["command"] as? String,
                  let commandID = commandMap[sublimeCommand],
                  CommandCatalog.command(id: commandID) != nil,
                  !hasParameters(raw["args"]),
                  !hasContext(raw["context"]),
                  let keys = raw["keys"] as? [Any], !keys.isEmpty, keys.count <= 4,
                  keys.allSatisfy({ $0 is String }) else {
                skipped += 1
                continue
            }
            let sequence = keys.compactMap { parseKey($0 as! String) }
            guard sequence.count == keys.count else { skipped += 1; continue }
            supported += 1
            if overrides.count < limits.maximumKeyBindings {
                overrides.append(KeyBindingOverride(
                    commandID: commandID, binding: CommandKeyBinding(sequence: sequence)
                ))
            }
        }
        let beyond = max(0, entries.count - limits.maximumKeymapEntriesInspected)
        let cappedSupported = max(0, supported - overrides.count)
        return SublimeKeymapImport(
            sourceURL: sourceURL.standardizedFileURL, overrides: overrides,
            skipped: skipped + cappedSupported + beyond,
            inspected: inspectedEntries.count, wasTruncated: beyond > 0 || cappedSupported > 0
        )
    }

    public static func parseSnippet(
        _ data: Data,
        sourceURL: URL,
        limits: SublimeImportLimits = .default
    ) throws -> SublimeSnippetImport {
        try requireSourceURL(sourceURL)
        try requireBound(data, maximum: limits.maximumSnippetBytes)
        guard let source = String(data: data, encoding: .utf8) else {
            throw SublimeImportError.missingSnippetContent
        }
        guard let content = xmlField("content", in: source), !content.isEmpty else {
            throw SublimeImportError.missingSnippetContent
        }
        guard content.utf16.count <= 10_000 else {
            throw SublimeImportError.snippetContentTooLarge
        }
        let rawTrigger = xmlField("tabTrigger", in: source)
        let trigger = rawTrigger.flatMap { isValidTrigger($0) ? $0 : nil }
        let scope = xmlField("scope", in: source).map { truncate($0, utf16: 100) }
        let label = truncate(sourceURL.deletingPathExtension().lastPathComponent, utf16: 200)
        return SublimeSnippetImport(
            sourceURL: sourceURL.standardizedFileURL, label: label, text: content,
            trigger: trigger, scope: scope
        )
    }

    private static let commandMap: [String: String] = [
        "save": "save", "save_as": "save-as", "close_file": "close-tab",
        "close_all": "close-all-tabs", "reopen_last_file": "reopen-tab",
        "next_view": "next-tab", "prev_view": "prev-tab",
        "goto_line": "go-to-line", "toggle_comment": "toggle-comment",
        "toggle_block_comment": "toggle-block-comment", "move_line_up": "move-line-up",
        "move_line_down": "move-line-down", "duplicate_line": "duplicate-selection",
        "delete_line": "delete-line", "sort_lines": "sort-lines",
        "upper_case": "to-upper-case", "lower_case": "to-lower-case",
        "join_lines": "join-lines", "indent": "indent-selection",
        "unindent": "outdent-selection", "toggle_setting": "toggle-word-wrap",
        "build": "build", "toggle_side_bar": "toggle-sidebar",
        "toggle_distraction_free": "toggle-distraction-free",
        "toggle_bookmark": "toggle-bookmark", "next_bookmark": "next-bookmark",
        "prev_bookmark": "prev-bookmark", "show_scope_name": "goto-symbol"
    ]

    private static func parseBuildSystem(
        _ value: Any, fallbackName: String?, limits: SublimeImportLimits
    ) -> SublimeBuildSystemImport? {
        guard let raw = value as? [String: Any] else { return nil }
        let cmd = exactStringArray(raw["cmd"])
        let shell = raw["shell_cmd"] as? String ?? ""
        guard let command = cmd.first ?? (shell.isEmpty ? nil : shell), !command.isEmpty else {
            return nil
        }
        let name = truncate((raw["name"] as? String) ?? fallbackName ?? command, utf16: 100)
        let variants = (raw["variants"] as? [Any] ?? []).compactMap { value -> SublimeBuildVariantImport? in
            guard let variant = value as? [String: Any], let name = variant["name"] as? String else {
                return nil
            }
            let commandParts = exactStringArray(variant["cmd"])
            let shellCommand = variant["shell_cmd"] as? String ?? ""
            guard let command = commandParts.first ?? (shellCommand.isEmpty ? nil : shellCommand),
                  !command.isEmpty else { return nil }
            return SublimeBuildVariantImport(
                name: truncate(name, utf16: 100), command: truncate(command, utf16: 1_000),
                arguments: Array(commandParts.dropFirst().prefix(50)).map { truncate($0, utf16: 4_000) },
                workingDirectory: string(raw: variant["working_dir"], limit: 500),
                fileRegex: string(raw: variant["file_regex"], limit: 1_000),
                environment: environment(variant["env"]), usesShell: !shellCommand.isEmpty
            )
        }
        return SublimeBuildSystemImport(
            name: name, command: truncate(command, utf16: 1_000),
            arguments: Array(cmd.dropFirst().prefix(50)).map { truncate($0, utf16: 4_000) },
            workingDirectory: string(raw: raw["working_dir"], limit: 500),
            fileRegex: string(raw: raw["file_regex"], limit: 1_000),
            environment: environment(raw["env"]), usesShell: !shell.isEmpty,
            variants: Array(variants.prefix(limits.maximumBuildVariants))
        )
    }

    private static func parseKey(_ raw: String) -> CommandKeyEquivalent? {
        let parts = raw.lowercased().split(separator: "+").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var modifiers: CommandKeyModifiers = []
        var keys: [String] = []
        for part in parts {
            switch part {
            case "ctrl", "super": modifiers.insert(.command)
            case "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "enter": keys.append("return")
            default: keys.append(part)
            }
        }
        guard keys.count == 1, isSupportedKey(keys[0]) else { return nil }
        return CommandKeyEquivalent(key: keys[0], modifiers: modifiers)
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if key.utf8.count == 1, let byte = key.utf8.first, byte >= 0x21, byte <= 0x7e {
            return true
        }
        if ["up", "down", "left", "right", "backspace", "delete", "return", "space"].contains(key) { return true }
        guard key.hasPrefix("f"), let number = Int(key.dropFirst()) else { return false }
        return (2...12).contains(number)
    }

    private static func jsonObject(
        _ data: Data, maximumBytes: Int, allowsComments: Bool
    ) throws -> Any {
        try requireBound(data, maximum: maximumBytes)
        let decoded: Data
        if allowsComments {
            guard let source = String(data: data, encoding: .utf8) else {
                throw SublimeImportError.invalidJSON
            }
            decoded = Data(removeTrailingCommas(stripComments(source)).utf8)
        } else {
            decoded = data
            guard let source = String(data: data, encoding: .utf8) else {
                throw SublimeImportError.invalidJSON
            }
            do {
                _ = try LosslessJSON.parse(
                    source,
                    limits: LosslessJSONLimits(
                        maximumDepth: LosslessJSONLimits.hardMaximumDepth,
                        maximumNodes: max(1, source.utf16.count),
                        maximumBytes: source.utf16.count
                    )
                )
            } catch {
                throw SublimeImportError.invalidJSON
            }
        }
        do {
            return try JSONSerialization.jsonObject(with: decoded, options: [.fragmentsAllowed])
        } catch {
            throw SublimeImportError.invalidJSON
        }
    }

    private static func requireBound(_ data: Data, maximum: Int) throws {
        guard data.count <= maximum else {
            throw SublimeImportError.inputTooLarge(actualBytes: data.count, maximumBytes: maximum)
        }
    }

    private static func requireSourceURL(_ url: URL) throws {
        guard url.isFileURL, (url.path as NSString).isAbsolutePath, !url.path.contains("\0") else {
            throw SublimeImportError.invalidSourceURL
        }
    }

    private static func stripComments(_ source: String) -> String {
        let units = Array(source.utf16)
        var output: [UInt16] = []
        var index = 0
        var quoted = false
        var escaped = false
        while index < units.count {
            let unit = units[index]
            if quoted {
                output.append(unit)
                if escaped { escaped = false }
                else if unit == 0x5c { escaped = true }
                else if unit == 0x22 { quoted = false }
                index += 1
            } else if unit == 0x22 {
                quoted = true; output.append(unit); index += 1
            } else if unit == 0x2f, index + 1 < units.count, units[index + 1] == 0x2f {
                index += 2
                while index < units.count, units[index] != 0x0a, units[index] != 0x0d { index += 1 }
            } else if unit == 0x2f, index + 1 < units.count, units[index + 1] == 0x2a {
                index += 2
                while index + 1 < units.count, !(units[index] == 0x2a && units[index + 1] == 0x2f) {
                    if units[index] == 0x0a || units[index] == 0x0d { output.append(units[index]) }
                    index += 1
                }
                index = min(units.count, index + 2)
            } else {
                output.append(unit); index += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func removeTrailingCommas(_ source: String) -> String {
        let units = Array(source.utf16)
        var output: [UInt16] = []
        var index = 0
        var quoted = false
        var escaped = false
        while index < units.count {
            let unit = units[index]
            if quoted {
                output.append(unit)
                if escaped { escaped = false }
                else if unit == 0x5c { escaped = true }
                else if unit == 0x22 { quoted = false }
                index += 1; continue
            }
            if unit == 0x22 { quoted = true; output.append(unit); index += 1; continue }
            if unit == 0x2c {
                var lookahead = index + 1
                while lookahead < units.count, [0x20, 0x09, 0x0a, 0x0d].contains(units[lookahead]) {
                    lookahead += 1
                }
                if lookahead < units.count, units[lookahead] == 0x7d || units[lookahead] == 0x5d {
                    index += 1; continue
                }
            }
            output.append(unit); index += 1
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func xmlField(_ name: String, in source: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: "<\(escaped)>([\\s\\S]*?)</\(escaped)>", options: [.caseInsensitive]
        ) else { return nil }
        let ns = source as NSString
        guard let match = expression.firstMatch(
            in: source, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        var value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") {
            value = String(value.dropFirst(9).dropLast(3))
        } else {
            value = decodeXML(value)
        }
        return value
    }

    private static func decodeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func isValidTrigger(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 80 && bytes.allSatisfy { byte in
            byte == 0x2d || byte == 0x5f || (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
        }
    }

    private static func exactStringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any], array.allSatisfy({ $0 is String }) else { return [] }
        return array as! [String]
    }

    private static func environment(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for key in raw.keys.sorted() {
            guard result.count < 50, isEnvironmentKey(key),
                  let value = raw[key] as? String, value.utf16.count <= 4_000 else { continue }
            result[key] = value
        }
        return result
    }

    private static func isEnvironmentKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= 100 else { return false }
        let head = bytes[0]
        guard head == 0x5f || (0x41...0x5a).contains(head) || (0x61...0x7a).contains(head) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            $0 == 0x5f || (0x30...0x39).contains($0) || (0x41...0x5a).contains($0)
                || (0x61...0x7a).contains($0)
        }
    }

    private static func hasParameters(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }

    private static func hasContext(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }

    private static func absoluteURL(_ path: String, relativeTo base: URL) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    private static func string(raw: Any?, limit: Int) -> String? {
        (raw as? String).map { truncate($0, utf16: limit) }
    }

    private static func truncate(_ value: String, utf16 limit: Int) -> String {
        guard value.utf16.count > limit else { return value }
        return String(decoding: value.utf16.prefix(limit), as: UTF16.self)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    private static func boundedInt(_ value: Double, _ minimum: Int, _ maximum: Int) -> Int {
        Int(min(Double(maximum), max(Double(minimum), value)).rounded(.toNearestOrAwayFromZero))
    }

    private static func settingChanges(
        from old: EditorSettings, to new: EditorSettings
    ) -> [SublimeSettingChange] {
        var result: [SublimeSettingChange] = []
        func add(_ key: SublimeSettingKey, _ oldValue: Any, _ newValue: Any) {
            let before = String(describing: oldValue), after = String(describing: newValue)
            if before != after { result.append(.init(key: key, oldValue: before, newValue: after)) }
        }
        add(.fontSize, old.fontSize, new.fontSize); add(.tabSize, old.tabSize, new.tabSize)
        add(.insertSpaces, old.insertSpaces, new.insertSpaces); add(.wordWrap, old.wordWrap, new.wordWrap)
        add(.showLineNumbers, old.showLineNumbers, new.showLineNumbers)
        add(.showWhitespace, old.showWhitespace, new.showWhitespace); add(.rulers, old.rulers, new.rulers)
        add(.spellCheck, old.spellCheck, new.spellCheck); add(.autoSave, old.autoSave.rawValue, new.autoSave.rawValue)
        add(.autoSaveDelayMs, old.autoSaveDelayMs, new.autoSaveDelayMs)
        add(.colorScheme, old.colorScheme.rawValue, new.colorScheme.rawValue)
        return result
    }
}

private struct OverrideKey: Hashable {
    let commandID: String
    let context: KeyBindingContext?

    init(_ override: KeyBindingOverride) {
        commandID = override.commandID
        context = override.when
    }
}

private extension SublimeBuildVariantImport {
    var jsonValue: WindowSessionJSONValue {
        var values: [String: WindowSessionJSONValue] = [
            "name": .string(name), "command": .string(command),
            "args": .array(arguments.map(WindowSessionJSONValue.string))
        ]
        if let workingDirectory { values["workingDirectory"] = .string(workingDirectory) }
        if let fileRegex { values["fileRegex"] = .string(fileRegex) }
        if usesShell { values["shell"] = .bool(true) }
        if !environment.isEmpty { values["env"] = .object(environment.mapValues(WindowSessionJSONValue.string)) }
        return .object(values)
    }
}

private extension SublimeBuildSystemImport {
    var jsonValue: WindowSessionJSONValue {
        var values: [String: WindowSessionJSONValue] = [
            "name": .string(name), "command": .string(command),
            "args": .array(arguments.map(WindowSessionJSONValue.string)),
            "variants": .array(variants.map(\.jsonValue))
        ]
        if let workingDirectory { values["workingDirectory"] = .string(workingDirectory) }
        if let fileRegex { values["fileRegex"] = .string(fileRegex) }
        if usesShell { values["shell"] = .bool(true) }
        if !environment.isEmpty { values["env"] = .object(environment.mapValues(WindowSessionJSONValue.string)) }
        return .object(values)
    }
}
