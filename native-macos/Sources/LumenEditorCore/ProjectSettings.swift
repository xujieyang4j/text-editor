import Foundation

/// A configurable formatter/diagnostics command. The optional execution
/// fields extend the legacy `command`/`args` JSON shape without changing it.
public struct LanguageToolConfig: Codable, Equatable, Sendable {
    public var command: String
    public var args: [String]
    public var shell: Bool?
    public var workingDirectory: String?
    public var env: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case command, args, shell, workingDirectory, env
    }

    public init(
        command: String,
        args: [String],
        shell: Bool? = nil,
        workingDirectory: String? = nil,
        env: [String: String]? = nil
    ) {
        self.command = command
        self.args = args
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.env = env
    }

    /// Vocabulary alias for execution APIs; the persisted JSON key remains `env`.
    public var environment: [String: String]? {
        get { env }
        set { env = newValue }
    }
}

public struct ProjectBuildVariant: Codable, Equatable, Sendable {
    public var name: String
    public var command: String?
    public var args: [String]?
    public var workingDirectory: String?
    public var fileRegex: String?
    public var env: [String: String]?
    public var shell: Bool?

    public init(
        name: String,
        command: String? = nil,
        args: [String]? = nil,
        workingDirectory: String? = nil,
        fileRegex: String? = nil,
        env: [String: String]? = nil,
        shell: Bool? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.fileRegex = fileRegex
        self.env = env
        self.shell = shell
    }
}

public struct ProjectBuildSystem: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    public var workingDirectory: String?
    public var fileRegex: String?
    public var saveBeforeBuild: Bool?
    public var shell: Bool?
    public var env: [String: String]
    public var variants: [ProjectBuildVariant]

    public init(
        name: String,
        command: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        fileRegex: String? = nil,
        saveBeforeBuild: Bool? = nil,
        shell: Bool? = nil,
        env: [String: String] = [:],
        variants: [ProjectBuildVariant] = []
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.fileRegex = fileRegex
        self.saveBeforeBuild = saveBeforeBuild
        self.shell = shell
        self.env = env
        self.variants = variants
    }
}

public struct ProjectKeyBindingRule: Codable, Equatable, Sendable {
    public var keys: [String]
    public var command: String
    public var when: KeyBindingContext?

    public init(keys: [String], command: String, when: KeyBindingContext? = nil) {
        self.keys = keys
        self.command = command
        self.when = when
    }
}

public struct ProjectSnippet: Codable, Equatable, Sendable {
    public var label: String
    public var text: String
    public var trigger: String?
    public var scope: String?

    public init(label: String, text: String, trigger: String? = nil, scope: String? = nil) {
        self.label = label
        self.text = text
        self.trigger = trigger
        self.scope = scope
    }
}

/// Typed, bounded counterpart of the Electron `ProjectSettings` IPC DTO.
/// Merely loading this value never authorises or executes a configured command;
/// execution layers must still apply ToolEnvironmentPolicy and approval identity.
/// Loading and saving canonicalize this schema, so unknown top-level fields are
/// intentionally discarded. Unknown fields inside a language-tool object do
/// not prevent its recognized fields from being loaded.
public struct ProjectSettings: Codable, Equatable, Sendable {
    public var exclude: [String]
    public var buildCommand: String
    public var keyBindings: [String: String]
    public var plugins: [String]
    public var pluginPermissions: [String: [PluginPermission]]
    public var languageTools: [String: LanguageToolConfig]
    public var languageServers: [String: LanguageServerConfig]
    public var buildSystems: [ProjectBuildSystem]
    public var keyBindingRules: [ProjectKeyBindingRule]
    public var marketplaceUrls: [String]
    public var snippets: [ProjectSnippet]

    public init(
        exclude: [String] = [],
        buildCommand: String = "",
        keyBindings: [String: String] = [:],
        plugins: [String] = [],
        pluginPermissions: [String: [PluginPermission]] = [:],
        languageTools: [String: LanguageToolConfig] = [:],
        languageServers: [String: LanguageServerConfig] = [:],
        buildSystems: [ProjectBuildSystem] = [],
        keyBindingRules: [ProjectKeyBindingRule] = [],
        marketplaceUrls: [String] = [],
        snippets: [ProjectSnippet] = []
    ) {
        self.exclude = exclude
        self.buildCommand = buildCommand
        self.keyBindings = keyBindings
        self.plugins = plugins
        self.pluginPermissions = pluginPermissions
        self.languageTools = languageTools
        self.languageServers = languageServers
        self.buildSystems = buildSystems
        self.keyBindingRules = keyBindingRules
        self.marketplaceUrls = marketplaceUrls
        self.snippets = snippets
    }

    public static let empty = ProjectSettings()

    public var marketplaceURLs: [String] {
        get { marketplaceUrls }
        set { marketplaceUrls = newValue }
    }

    public func sanitized() -> ProjectSettings {
        ProjectSettingsSanitizer.sanitize(self)
    }

    public func sessionProject() throws -> WindowSessionProject {
        try JSONDecoder().decode(
            WindowSessionProject.self,
            from: ProjectSettingsSanitizer.encodedData(self)
        )
    }
}

public enum ProjectSettingsParseError: Error, Equatable, LocalizedError, Sendable {
    case inputTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case expectedObject

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(actual, maximum):
            "Project settings use \(actual) bytes; the maximum is \(maximum) bytes."
        case .invalidJSON:
            "The project settings file is not valid JSON."
        case .expectedObject:
            "Project settings must contain a JSON object."
        }
    }
}

/// Electron-compatible field sanitisation plus explicit native limits for the
/// few Electron fields whose child strings or map sizes were previously unbounded.
public enum ProjectSettingsSanitizer {
    public static let maximumSerializedBytes = 1 * 1_024 * 1_024
    public static let maximumExclusions = 100
    public static let maximumExclusionUTF16CodeUnits = 200
    public static let maximumBuildCommandUTF16CodeUnits = 1_000
    public static let maximumLegacyKeyBindings = 100
    public static let maximumKeyBindingUTF16CodeUnits = 100
    public static let maximumPlugins = 50
    public static let maximumPluginPermissionEntries = 100
    public static let maximumLanguageConfigurations = 30
    public static let maximumLanguageNameUTF16CodeUnits = 100
    public static let maximumBuildSystems = 30
    public static let maximumBuildVariants = 20
    public static let maximumBuildNameUTF16CodeUnits = 100
    public static let maximumFileRegexUTF16CodeUnits = 1_000
    public static let maximumKeyBindingRules = 200
    public static let maximumKeySequenceItems = 4
    public static let maximumMarketplaceURLs = 20
    public static let maximumSnippets = 500

    public static func parse(_ data: Data) throws -> ProjectSettings {
        guard data.count <= maximumSerializedBytes else {
            throw ProjectSettingsParseError.inputTooLarge(
                actualBytes: data.count, maximumBytes: maximumSerializedBytes
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ProjectSettingsParseError.invalidJSON
        }
        let parsed: LosslessJSONValue
        do {
            parsed = try LosslessJSON.parse(
                source,
                limits: LosslessJSONLimits(
                    maximumDepth: 32,
                    maximumNodes: 50_000,
                    maximumBytes: maximumSerializedBytes
                )
            )
        } catch {
            throw ProjectSettingsParseError.invalidJSON
        }
        guard case let .object(root) = parsed else {
            throw ProjectSettingsParseError.expectedObject
        }
        return sanitize(orderedRoot: root)
    }

    public static func sanitize(_ project: WindowSessionProject) -> ProjectSettings {
        let raw = project.values
        return ProjectSettings(
            exclude: stringArray(raw["exclude"], itemLimit: maximumExclusionUTF16CodeUnits)
                .prefixArray(maximumExclusions),
            buildCommand: safeCommand(raw["buildCommand"]?.stringValue, fallback: ""),
            keyBindings: legacyKeyBindings(raw["keyBindings"]),
            plugins: pluginIDs(raw["plugins"]),
            pluginPermissions: permissions(raw["pluginPermissions"]),
            languageTools: languageTools(raw["languageTools"]),
            languageServers: languageServers(raw["languageServers"]),
            buildSystems: buildSystems(raw["buildSystems"]),
            keyBindingRules: keyBindingRules(raw["keyBindingRules"]),
            marketplaceUrls: marketplaceURLs(raw["marketplaceUrls"]),
            snippets: snippets(raw["snippets"])
        )
    }

    private static func sanitize(orderedRoot root: LosslessJSONObject) -> ProjectSettings {
        ProjectSettings(
            exclude: orderedStringArray(
                root["exclude"], itemLimit: maximumExclusionUTF16CodeUnits
            ).prefixArray(maximumExclusions),
            buildCommand: safeCommand(orderedString(root["buildCommand"]), fallback: ""),
            keyBindings: orderedLegacyKeyBindings(root["keyBindings"]),
            plugins: orderedStringArray(root["plugins"], itemLimit: Int.max)
                .filter(PluginManifestSecurity.isValidPluginID)
                .prefixArray(maximumPlugins),
            pluginPermissions: orderedPermissions(root["pluginPermissions"]),
            languageTools: orderedLanguageTools(root["languageTools"]),
            languageServers: orderedLanguageServers(root["languageServers"]),
            buildSystems: orderedBuildSystems(root["buildSystems"]),
            keyBindingRules: keyBindingRules(convert(root["keyBindingRules"])),
            marketplaceUrls: marketplaceURLs(convert(root["marketplaceUrls"])),
            snippets: snippets(convert(root["snippets"]))
        )
    }

    public static func sanitize(_ settings: ProjectSettings) -> ProjectSettings {
        do {
            let data = try encodedDataWithoutSanitizing(settings)
            guard let source = String(data: data, encoding: .utf8),
                  case let .object(root) = try LosslessJSON.parse(
                    source,
                    limits: LosslessJSONLimits(
                        maximumDepth: 32, maximumNodes: Int.max,
                        maximumBytes: max(data.count, maximumSerializedBytes)
                    )
                  ) else { return .empty }
            return sanitize(orderedRoot: root)
        } catch {
            return .empty
        }
    }

    public static func encodedData(_ settings: ProjectSettings) throws -> Data {
        let data = try encodedDataWithoutSanitizing(sanitize(settings))
        guard data.count <= maximumSerializedBytes else {
            throw ProjectSettingsParseError.inputTooLarge(
                actualBytes: data.count, maximumBytes: maximumSerializedBytes
            )
        }
        return data
    }

    private static func encodedDataWithoutSanitizing(_ settings: ProjectSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    private static func orderedLegacyKeyBindings(
        _ value: LosslessJSONValue?
    ) -> [String: String] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: String] = [:]
        for member in object.members where result.count < maximumLegacyKeyBindings {
            let key = member.key
            guard key.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  let command = orderedString(member.value),
                  command.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  !key.utf8.contains(0), !command.utf8.contains(0) else { continue }
            result[key] = command
        }
        return result
    }

    private static func orderedPermissions(
        _ value: LosslessJSONValue?
    ) -> [String: [PluginPermission]] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: [PluginPermission]] = [:]
        for member in object.members where result.count < maximumPluginPermissionEntries {
            let id = member.key
            guard id.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  PluginManifestSecurity.isValidPluginID(id),
                  case let .array(items) = member.value else { continue }
            var seen = Set<PluginPermission>()
            result[id] = items.compactMap { item in
                orderedString(item).flatMap(PluginPermission.init(rawValue:))
            }.filter { seen.insert($0).inserted }
        }
        return result
    }

    private static func orderedLanguageTools(
        _ value: LosslessJSONValue?
    ) -> [String: LanguageToolConfig] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: LanguageToolConfig] = [:]
        for member in object.members where result.count < maximumLanguageConfigurations {
            let language = member.key
            guard language.utf16.count <= maximumLanguageNameUTF16CodeUnits,
                  !language.utf8.contains(0),
                  case let .object(config) = member.value,
                  let command = orderedString(config["command"]),
                  !command.utf8.contains(0) else { continue }
            let env: [String: String]?
            if case .object? = config["env"] {
                env = orderedEnvironment(config["env"])
            } else {
                env = nil
            }
            result[language] = LanguageToolConfig(
                command: truncate(
                    command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                ),
                args: orderedStringArray(
                    config["args"],
                    itemLimit: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
                ).prefixArray(ToolExecutionLimits.maximumArguments),
                shell: orderedBool(config["shell"]),
                workingDirectory: orderedBoundedString(
                    config["workingDirectory"],
                    limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                ),
                env: env
            )
        }
        return result
    }

    private static func orderedLanguageServers(
        _ value: LosslessJSONValue?
    ) -> [String: LanguageServerConfig] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: LanguageServerConfig] = [:]
        for member in object.members where result.count < maximumLanguageConfigurations {
            let language = member.key
            guard language.utf16.count <= maximumLanguageNameUTF16CodeUnits,
                  !language.utf8.contains(0),
                  case let .object(config) = member.value,
                  let command = orderedString(config["command"]),
                  !command.utf8.contains(0) else { continue }
            result[language] = LanguageServerConfig(
                command: truncate(
                    command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                ),
                args: orderedStringArray(
                    config["args"],
                    itemLimit: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
                ).prefixArray(ToolExecutionLimits.maximumArguments)
            )
        }
        return result
    }

    private static func orderedBuildSystems(
        _ value: LosslessJSONValue?
    ) -> [ProjectBuildSystem] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap { value -> ProjectBuildSystem? in
            guard case let .object(raw) = value,
                  let name = orderedString(raw["name"]),
                  let command = orderedString(raw["command"]),
                  !name.utf8.contains(0), !command.utf8.contains(0) else { return nil }
            return ProjectBuildSystem(
                name: truncate(name, utf16: maximumBuildNameUTF16CodeUnits),
                command: truncate(
                    command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                ),
                args: orderedStringArray(
                    raw["args"], itemLimit: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
                ).prefixArray(ToolExecutionLimits.maximumArguments),
                workingDirectory: orderedBoundedString(
                    raw["workingDirectory"],
                    limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                ),
                fileRegex: orderedBoundedString(
                    raw["fileRegex"], limit: maximumFileRegexUTF16CodeUnits
                ),
                saveBeforeBuild: orderedBool(raw["saveBeforeBuild"]),
                shell: orderedBool(raw["shell"]),
                env: orderedEnvironment(raw["env"]),
                variants: orderedBuildVariants(raw["variants"])
            )
        }.prefixArray(maximumBuildSystems)
    }

    private static func orderedBuildVariants(
        _ value: LosslessJSONValue?
    ) -> [ProjectBuildVariant] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap { value -> ProjectBuildVariant? in
            guard case let .object(raw) = value,
                  let name = orderedString(raw["name"]),
                  !name.utf8.contains(0) else { return nil }
            let command = orderedString(raw["command"]).flatMap { value in
                value.utf8.contains(0) ? nil : truncate(
                    value, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                )
            }
            let args: [String]?
            if case .array? = raw["args"] {
                args = orderedStringArray(
                    raw["args"], itemLimit: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
                ).prefixArray(ToolExecutionLimits.maximumArguments)
            } else {
                args = nil
            }
            let env: [String: String]?
            if case .object? = raw["env"] {
                env = orderedEnvironment(raw["env"])
            } else {
                env = nil
            }
            return ProjectBuildVariant(
                name: truncate(name, utf16: maximumBuildNameUTF16CodeUnits),
                command: command,
                args: args,
                workingDirectory: orderedBoundedString(
                    raw["workingDirectory"],
                    limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                ),
                fileRegex: orderedBoundedString(
                    raw["fileRegex"], limit: maximumFileRegexUTF16CodeUnits
                ),
                env: env,
                shell: orderedBool(raw["shell"])
            )
        }.prefixArray(maximumBuildVariants)
    }

    private static func orderedEnvironment(
        _ value: LosslessJSONValue?
    ) -> [String: String] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: String] = [:]
        for member in object.members where result.count < ToolExecutionLimits.maximumEnvironmentVariables {
            guard isEnvironmentKey(member.key),
                  let value = orderedString(member.value),
                  value.utf16.count <= ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits,
                  !value.utf8.contains(0) else { continue }
            result[member.key] = value
        }
        return result
    }

    private static func orderedBoundedString(
        _ value: LosslessJSONValue?,
        limit: Int
    ) -> String? {
        orderedString(value).flatMap { raw in
            raw.utf8.contains(0) ? nil : truncate(raw, utf16: limit)
        }
    }

    private static func orderedBool(_ value: LosslessJSONValue?) -> Bool? {
        guard case let .bool(value)? = value else { return nil }
        return value
    }

    private static func orderedStringArray(
        _ value: LosslessJSONValue?,
        itemLimit: Int
    ) -> [String] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap(orderedString).filter { !$0.utf8.contains(0) }.map { value in
            itemLimit == Int.max ? value : truncate(value, utf16: itemLimit)
        }
    }

    private static func orderedString(_ value: LosslessJSONValue?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value.stringValue
    }

    private static func convert(_ value: LosslessJSONValue?) -> WindowSessionJSONValue? {
        guard let value else { return nil }
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .string(value):
            return .string(value.stringValue)
        case let .number(value):
            guard let number = Double(value.raw), number.isFinite else { return nil }
            return .number(number)
        case let .array(values):
            return .array(values.compactMap { convert($0) })
        case let .object(object):
            return .object(Dictionary(uniqueKeysWithValues: object.members.compactMap { member in
                convert(member.value).map { (member.key, $0) }
            }))
        }
    }

    private static func legacyKeyBindings(_ value: WindowSessionJSONValue?) -> [String: String] {
        guard let values = value?.objectValue else { return [:] }
        var result: [String: String] = [:]
        // Do not impose alphabetical sorting before truncation. This keeps the
        // decoded object's traversal order instead of deliberately diverging
        // from Electron's first-Object.entries behavior.
        for key in values.keys.sorted() where result.count < maximumLegacyKeyBindings {
            guard key.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  let command = values[key]?.stringValue,
                  command.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  !key.utf8.contains(0), !command.utf8.contains(0) else { continue }
            result[key] = command
        }
        return result
    }

    private static func pluginIDs(_ value: WindowSessionJSONValue?) -> [String] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap(\.stringValue)
            .filter(PluginManifestSecurity.isValidPluginID)
            .prefixArray(maximumPlugins)
    }

    private static func permissions(
        _ value: WindowSessionJSONValue?
    ) -> [String: [PluginPermission]] {
        guard let values = value?.objectValue else { return [:] }
        var result: [String: [PluginPermission]] = [:]
        for id in values.keys.sorted() where result.count < maximumPluginPermissionEntries {
            guard id.utf16.count <= maximumKeyBindingUTF16CodeUnits,
                  PluginManifestSecurity.isValidPluginID(id),
                  let items = values[id]?.arrayValue else { continue }
            var seen = Set<PluginPermission>()
            result[id] = items.compactMap { item in
                item.stringValue.flatMap(PluginPermission.init(rawValue:))
            }.filter { seen.insert($0).inserted }
        }
        return result
    }

    private static func languageTools(
        _ value: WindowSessionJSONValue?
    ) -> [String: LanguageToolConfig] {
        guard let values = value?.objectValue else { return [:] }
        var result: [String: LanguageToolConfig] = [:]
        for language in values.keys.sorted() where result.count < maximumLanguageConfigurations {
            guard language.utf16.count <= maximumLanguageNameUTF16CodeUnits,
                  !language.utf8.contains(0),
                  let config = values[language]?.objectValue,
                  let command = config["command"]?.stringValue,
                  !command.utf8.contains(0) else { continue }
            result[language] = LanguageToolConfig(
                command: truncate(
                    command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                ),
                args: arguments(config["args"]),
                shell: config["shell"]?.boolValue,
                workingDirectory: boundedString(
                    config["workingDirectory"],
                    limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                ),
                env: config["env"]?.objectValue == nil ? nil : environment(config["env"])
            )
        }
        return result
    }

    private static func languageServers(
        _ value: WindowSessionJSONValue?
    ) -> [String: LanguageServerConfig] {
        guard let values = value?.objectValue else { return [:] }
        var result: [String: LanguageServerConfig] = [:]
        for language in values.keys.sorted() where result.count < maximumLanguageConfigurations {
            guard language.utf16.count <= maximumLanguageNameUTF16CodeUnits,
                  !language.utf8.contains(0),
                  let config = values[language]?.objectValue,
                  let command = config["command"]?.stringValue,
                  !command.utf8.contains(0) else { continue }
            result[language] = LanguageServerConfig(
                command: truncate(command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits),
                args: arguments(config["args"])
            )
        }
        return result
    }

    private static func buildSystems(_ value: WindowSessionJSONValue?) -> [ProjectBuildSystem] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { item -> ProjectBuildSystem? in
            guard let raw = item.objectValue,
                  let name = raw["name"]?.stringValue,
                  let command = raw["command"]?.stringValue,
                  !name.utf8.contains(0), !command.utf8.contains(0) else { return nil }
            let variants = (raw["variants"]?.arrayValue ?? []).compactMap { value -> ProjectBuildVariant? in
                guard let variant = value.objectValue,
                      let name = variant["name"]?.stringValue,
                      !name.utf8.contains(0) else { return nil }
                let command = variant["command"]?.stringValue.flatMap { value in
                    value.utf8.contains(0) ? nil : truncate(
                        value, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                    )
                }
                return ProjectBuildVariant(
                    name: truncate(name, utf16: maximumBuildNameUTF16CodeUnits),
                    command: command,
                    args: variant["args"]?.arrayValue == nil ? nil : arguments(variant["args"]),
                    workingDirectory: boundedString(
                        variant["workingDirectory"],
                        limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                    ),
                    fileRegex: boundedString(variant["fileRegex"], limit: maximumFileRegexUTF16CodeUnits),
                    env: variant["env"]?.objectValue == nil ? nil : environment(variant["env"]),
                    shell: variant["shell"]?.boolValue
                )
            }.prefixArray(maximumBuildVariants)
            return ProjectBuildSystem(
                name: truncate(name, utf16: maximumBuildNameUTF16CodeUnits),
                command: truncate(command, utf16: ToolExecutionLimits.maximumExecutableUTF16CodeUnits),
                args: arguments(raw["args"]),
                workingDirectory: boundedString(
                    raw["workingDirectory"],
                    limit: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
                ),
                fileRegex: boundedString(raw["fileRegex"], limit: maximumFileRegexUTF16CodeUnits),
                saveBeforeBuild: raw["saveBeforeBuild"]?.boolValue,
                shell: raw["shell"]?.boolValue,
                env: environment(raw["env"]),
                variants: variants
            )
        }.prefixArray(maximumBuildSystems)
    }

    private static func keyBindingRules(
        _ value: WindowSessionJSONValue?
    ) -> [ProjectKeyBindingRule] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { item -> ProjectKeyBindingRule? in
            guard let raw = item.objectValue,
                  let command = raw["command"]?.stringValue,
                  !command.utf8.contains(0) else { return nil }
            let keys: [String]
            if let key = raw["keys"]?.stringValue {
                keys = [key]
            } else if let array = raw["keys"]?.arrayValue,
                      array.allSatisfy({ $0.stringValue != nil }) {
                keys = array.compactMap(\.stringValue)
            } else {
                return nil
            }
            let boundedKeys = keys.prefix(maximumKeySequenceItems).map {
                truncate($0, utf16: maximumKeyBindingUTF16CodeUnits)
            }.filter { !$0.isEmpty && !$0.utf8.contains(0) }
            guard !boundedKeys.isEmpty else { return nil }
            return ProjectKeyBindingRule(
                keys: boundedKeys,
                command: truncate(command, utf16: maximumKeyBindingUTF16CodeUnits),
                when: raw["when"]?.stringValue.flatMap(KeyBindingContext.init(rawValue:))
            )
        }.prefixArray(maximumKeyBindingRules)
    }

    private static func marketplaceURLs(_ value: WindowSessionJSONValue?) -> [String] {
        guard let values = value?.arrayValue else { return [] }
        return PluginManifestSecurity.sanitizeMarketplaceSourceURLs(
            values.compactMap(\.stringValue)
        ).prefix(maximumMarketplaceURLs).map(\.absoluteString)
    }

    private static func snippets(_ value: WindowSessionJSONValue?) -> [ProjectSnippet] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { item -> ProjectSnippet? in
            guard let raw = item.objectValue,
                  let label = raw["label"]?.stringValue,
                  let text = raw["text"]?.stringValue,
                  !label.utf8.contains(0), !text.utf8.contains(0) else { return nil }
            let trigger = raw["trigger"]?.stringValue.flatMap { value in
                isValidTrigger(value) ? value : nil
            }
            return ProjectSnippet(
                label: truncate(label, utf16: 200),
                text: truncate(text, utf16: 10_000),
                trigger: trigger,
                scope: boundedString(raw["scope"], limit: 100)
            )
        }.prefixArray(maximumSnippets)
    }

    private static func arguments(_ value: WindowSessionJSONValue?) -> [String] {
        stringArray(value, itemLimit: ToolExecutionLimits.maximumArgumentUTF16CodeUnits)
            .prefixArray(ToolExecutionLimits.maximumArguments)
    }

    private static func environment(_ value: WindowSessionJSONValue?) -> [String: String] {
        guard let values = value?.objectValue else { return [:] }
        var result: [String: String] = [:]
        for key in values.keys.sorted() where result.count < ToolExecutionLimits.maximumEnvironmentVariables {
            guard isEnvironmentKey(key),
                  let rawValue = values[key]?.stringValue,
                  rawValue.utf16.count <= ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits,
                  !rawValue.utf8.contains(0) else { continue }
            result[key] = rawValue
        }
        return result
    }

    private static func isEnvironmentKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty,
              bytes.count <= ToolExecutionLimits.maximumEnvironmentKeyASCIICharacters,
              isASCIIAlpha(bytes[0]) || bytes[0] == 0x5f else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlpha(byte) || (0x30...0x39).contains(byte) || byte == 0x5f
        }
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func stringArray(
        _ value: WindowSessionJSONValue?,
        itemLimit: Int
    ) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
            .filter { !$0.utf8.contains(0) }
            .map { truncate($0, utf16: itemLimit) }
    }

    private static func boundedString(
        _ value: WindowSessionJSONValue?,
        limit: Int
    ) -> String? {
        value?.stringValue.flatMap { raw in
            raw.utf8.contains(0) ? nil : truncate(raw, utf16: limit)
        }
    }

    private static func safeCommand(_ value: String?, fallback: String) -> String {
        guard let value, !value.utf8.contains(0) else { return fallback }
        return truncate(value, utf16: maximumBuildCommandUTF16CodeUnits)
    }

    private static func isValidTrigger(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 80 else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte) || byte == 0x5f || byte == 0x2d
        }
    }

    private static func truncate(_ value: String, utf16 limit: Int) -> String {
        guard value.utf16.count > limit else { return value }
        return String(decoding: Array(value.utf16.prefix(limit)), as: UTF16.self)
    }
}

private extension WindowSessionJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var arrayValue: [WindowSessionJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: WindowSessionJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

private extension Sequence {
    func prefixArray(_ maximum: Int) -> [Element] { Array(prefix(maximum)) }
}
