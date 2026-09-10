import Foundation

public enum EditorLocale: String, Codable, CaseIterable, Sendable {
    case zhCN = "zh-CN"
    case enUS = "en-US"
}

public enum EditorTheme: String, Codable, CaseIterable, Sendable {
    case dark
    case light
}

public enum EditorColorScheme: String, Codable, CaseIterable, Sendable {
    case dark
    case light
    case solarizedDark = "solarized-dark"
    case dracula
}

public enum AutoSaveMode: String, Codable, CaseIterable, Sendable {
    case off
    case afterDelay = "after_delay"
    case onFocusChange = "on_focus_change"
}

/// The user-configurable editor preferences shared by the native application.
///
/// The JSON keys and values deliberately match Electron's `Settings` object.
/// `formatVersion` is the only native addition. A missing version is treated as
/// the current version so an existing Electron `settings.json` can be read.
public struct EditorSettings: Codable, Equatable, Sendable {
    public typealias Locale = EditorLocale
    public typealias Theme = EditorTheme
    public typealias ColorScheme = EditorColorScheme
    public typealias AutoSave = AutoSaveMode

    public static let currentFormatVersion = 2

    /// Native TextKit keeps a hard byte budget so a malformed or unexpectedly
    /// huge file cannot stall the UI, but the old 20 MB starting point was too
    /// restrictive for ordinary source, generated JSON, and log files. New
    /// native installations start at the existing user-selectable maximum.
    public static let defaultMaximumFileSizeMB = 200
    private static let legacyDefaultMaximumFileSizeMB = 20

    public var formatVersion: Int
    public var locale: EditorLocale
    public var fontSize: Int
    public var tabSize: Int
    public var insertSpaces: Bool
    public var theme: EditorTheme
    public var wordWrap: Bool
    public var showLineNumbers: Bool
    public var showMinimap: Bool
    public var showIndentGuides: Bool
    public var showWhitespace: Bool
    public var highlightTrailingWhitespace: Bool
    public var rulers: [Int]
    public var maxFileSizeMB: Int
    public var buildCommand: String
    public var colorScheme: EditorColorScheme
    public var spellCheck: Bool
    public var autoSave: AutoSaveMode
    public var autoSaveDelayMs: Int
    public var distractionFree: Bool
    public var showOutline: Bool
    public var searchHistory: [String]
    public var replaceHistory: [String]

    public init(
        formatVersion: Int = EditorSettings.currentFormatVersion,
        locale: EditorLocale = .zhCN,
        fontSize: Int = 14,
        tabSize: Int = 4,
        insertSpaces: Bool = true,
        theme: EditorTheme = .dark,
        wordWrap: Bool = false,
        showLineNumbers: Bool = true,
        showMinimap: Bool = true,
        showIndentGuides: Bool = true,
        showWhitespace: Bool = false,
        highlightTrailingWhitespace: Bool = true,
        rulers: [Int] = [],
        maxFileSizeMB: Int = EditorSettings.defaultMaximumFileSizeMB,
        buildCommand: String = "",
        colorScheme: EditorColorScheme = .dark,
        spellCheck: Bool = false,
        autoSave: AutoSaveMode = .off,
        autoSaveDelayMs: Int = 1_000,
        distractionFree: Bool = false,
        showOutline: Bool = false,
        searchHistory: [String] = [],
        replaceHistory: [String] = []
    ) {
        self.formatVersion = formatVersion
        self.locale = locale
        self.fontSize = Self.clamp(fontSize, minimum: 8, maximum: 40)
        self.tabSize = Self.clamp(tabSize, minimum: 1, maximum: 16)
        self.insertSpaces = insertSpaces
        self.theme = theme
        self.wordWrap = wordWrap
        self.showLineNumbers = showLineNumbers
        self.showMinimap = showMinimap
        self.showIndentGuides = showIndentGuides
        self.showWhitespace = showWhitespace
        self.highlightTrailingWhitespace = highlightTrailingWhitespace
        self.rulers = Array(rulers.lazy.filter { $0 > 0 && $0 <= 500 }.prefix(10))
        self.maxFileSizeMB = Self.clamp(maxFileSizeMB, minimum: 1, maximum: 200)
        self.buildCommand = Self.truncate(buildCommand, maximumUTF16CodeUnits: 1_000)
        self.colorScheme = colorScheme
        self.spellCheck = spellCheck
        self.autoSave = autoSave
        self.autoSaveDelayMs = Self.clamp(
            autoSaveDelayMs,
            minimum: 250,
            maximum: 60_000
        )
        self.distractionFree = distractionFree
        self.showOutline = showOutline
        self.searchHistory = Array(
            searchHistory.lazy
                .map { Self.truncate($0, maximumUTF16CodeUnits: 2_000) }
                .prefix(50)
        )
        self.replaceHistory = Array(
            replaceHistory.lazy
                .map { Self.truncate($0, maximumUTF16CodeUnits: 2_000) }
                .prefix(50)
        )
    }

    public static let `default` = EditorSettings()

    /// Applies the same bounds as Electron's `sanitizeSettings` to values that
    /// may have been changed directly after initialisation.
    public func sanitized() -> EditorSettings {
        EditorSettings(
            formatVersion: formatVersion,
            locale: locale,
            fontSize: fontSize,
            tabSize: tabSize,
            insertSpaces: insertSpaces,
            theme: theme,
            wordWrap: wordWrap,
            showLineNumbers: showLineNumbers,
            showMinimap: showMinimap,
            showIndentGuides: showIndentGuides,
            showWhitespace: showWhitespace,
            highlightTrailingWhitespace: highlightTrailingWhitespace,
            rulers: rulers,
            maxFileSizeMB: maxFileSizeMB,
            buildCommand: buildCommand,
            colorScheme: colorScheme,
            spellCheck: spellCheck,
            autoSave: autoSave,
            autoSaveDelayMs: autoSaveDelayMs,
            distractionFree: distractionFree,
            showOutline: showOutline,
            searchHistory: searchHistory,
            replaceHistory: replaceHistory
        )
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case locale
        case fontSize
        case tabSize
        case insertSpaces
        case theme
        case wordWrap
        case showLineNumbers
        case showMinimap
        case showIndentGuides
        case showWhitespace
        case highlightTrailingWhitespace
        case rulers
        case maxFileSizeMB
        case buildCommand
        case colorScheme
        case spellCheck
        case autoSave
        case autoSaveDelayMs
        case distractionFree
        case showOutline
        case searchHistory
        case replaceHistory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EditorSettings.default

        let storedFormatVersion = Self.formatVersion(in: container)
        // Migrate only the known v1 native preview. All other explicit values
        // remain observable so SettingsStore can keep rejecting an unsafe
        // overwrite of a future or otherwise unsupported schema.
        formatVersion = storedFormatVersion == nil || storedFormatVersion == 1
            ? Self.currentFormatVersion
            : storedFormatVersion!
        locale = Self.string(in: container, forKey: .locale)
            .flatMap(EditorLocale.init(rawValue:)) ?? defaults.locale
        fontSize = Self.boundedInteger(
            in: container,
            forKey: .fontSize,
            fallback: defaults.fontSize,
            minimum: 8,
            maximum: 40
        )
        tabSize = Self.boundedInteger(
            in: container,
            forKey: .tabSize,
            fallback: defaults.tabSize,
            minimum: 1,
            maximum: 16
        )
        insertSpaces = Self.bool(in: container, forKey: .insertSpaces)
            ?? defaults.insertSpaces
        theme = Self.string(in: container, forKey: .theme)
            .flatMap(EditorTheme.init(rawValue:)) ?? defaults.theme
        wordWrap = Self.bool(in: container, forKey: .wordWrap) ?? defaults.wordWrap
        showLineNumbers = Self.bool(in: container, forKey: .showLineNumbers)
            ?? defaults.showLineNumbers
        showMinimap = Self.bool(in: container, forKey: .showMinimap)
            ?? defaults.showMinimap
        showIndentGuides = Self.bool(in: container, forKey: .showIndentGuides)
            ?? defaults.showIndentGuides
        showWhitespace = Self.bool(in: container, forKey: .showWhitespace)
            ?? defaults.showWhitespace
        highlightTrailingWhitespace = Self.bool(
            in: container,
            forKey: .highlightTrailingWhitespace
        ) ?? defaults.highlightTrailingWhitespace
        rulers = Self.rulers(in: container, forKey: .rulers) ?? defaults.rulers
        let decodedMaximumFileSizeMB = Self.boundedInteger(
            in: container,
            forKey: .maxFileSizeMB,
            fallback: defaults.maxFileSizeMB,
            minimum: 1,
            maximum: 200
        )
        // Version 1 was written only by the native preview. Its default of
        // 20 MB caused Finder/Open-panel requests for common generated source
        // files to fail before the user had a chance to change Settings. Move
        // an untouched legacy default to the new 200 MB default, while
        // preserving every explicit value and all unversioned Electron input.
        maxFileSizeMB = (storedFormatVersion == nil || storedFormatVersion == 1)
            && decodedMaximumFileSizeMB == Self.legacyDefaultMaximumFileSizeMB
            ? Self.defaultMaximumFileSizeMB
            : decodedMaximumFileSizeMB
        buildCommand = Self.string(in: container, forKey: .buildCommand)
            .map { Self.truncate($0, maximumUTF16CodeUnits: 1_000) }
            ?? defaults.buildCommand
        colorScheme = Self.string(in: container, forKey: .colorScheme)
            .flatMap(EditorColorScheme.init(rawValue:)) ?? defaults.colorScheme
        spellCheck = Self.bool(in: container, forKey: .spellCheck)
            ?? defaults.spellCheck
        autoSave = Self.string(in: container, forKey: .autoSave)
            .flatMap(AutoSaveMode.init(rawValue:)) ?? defaults.autoSave
        autoSaveDelayMs = Self.boundedInteger(
            in: container,
            forKey: .autoSaveDelayMs,
            fallback: defaults.autoSaveDelayMs,
            minimum: 250,
            maximum: 60_000
        )
        distractionFree = Self.bool(in: container, forKey: .distractionFree)
            ?? defaults.distractionFree
        showOutline = Self.bool(in: container, forKey: .showOutline)
            ?? defaults.showOutline
        searchHistory = Self.history(in: container, forKey: .searchHistory)
            ?? defaults.searchHistory
        replaceHistory = Self.history(in: container, forKey: .replaceHistory)
            ?? defaults.replaceHistory
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(locale, forKey: .locale)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(tabSize, forKey: .tabSize)
        try container.encode(insertSpaces, forKey: .insertSpaces)
        try container.encode(theme, forKey: .theme)
        try container.encode(wordWrap, forKey: .wordWrap)
        try container.encode(showLineNumbers, forKey: .showLineNumbers)
        try container.encode(showMinimap, forKey: .showMinimap)
        try container.encode(showIndentGuides, forKey: .showIndentGuides)
        try container.encode(showWhitespace, forKey: .showWhitespace)
        try container.encode(
            highlightTrailingWhitespace,
            forKey: .highlightTrailingWhitespace
        )
        try container.encode(rulers, forKey: .rulers)
        try container.encode(maxFileSizeMB, forKey: .maxFileSizeMB)
        try container.encode(buildCommand, forKey: .buildCommand)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(spellCheck, forKey: .spellCheck)
        try container.encode(autoSave, forKey: .autoSave)
        try container.encode(autoSaveDelayMs, forKey: .autoSaveDelayMs)
        try container.encode(distractionFree, forKey: .distractionFree)
        try container.encode(showOutline, forKey: .showOutline)
        try container.encode(searchHistory, forKey: .searchHistory)
        try container.encode(replaceHistory, forKey: .replaceHistory)
    }

    private static func string(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        try? container.decode(String.self, forKey: key)
    }

    private static func bool(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        try? container.decode(Bool.self, forKey: key)
    }

    private static func boundedInteger(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fallback: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard let value = try? container.decode(Double.self, forKey: key),
              value.isFinite else {
            return fallback
        }
        // These settings all use positive, small bounds. Clamping the Double
        // first also prevents an overflowing conversion from hostile JSON.
        let clamped = min(Double(maximum), max(Double(minimum), value))
        return Int(clamped.rounded(.toNearestOrAwayFromZero))
    }

    private static func formatVersion(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Int? {
        guard let number = try? container.decode(
            Double.self,
            forKey: .formatVersion
        ),
              number.isFinite,
              number.rounded(.towardZero) == number,
              number > Double(Int.min),
              number < Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private static func rulers(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Int]? {
        guard let values = try? container.decode(
            LossyDoubleArray.self,
            forKey: key
        ).values else {
            return nil
        }
        var result: [Int] = []
        result.reserveCapacity(min(values.count, 10))
        for number in values {
            guard number.isFinite, number > 0, number <= 500 else {
                continue
            }
            result.append(Int(number.rounded(.toNearestOrAwayFromZero)))
            if result.count == 10 { break }
        }
        return result
    }

    private static func history(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String]? {
        guard let values = try? container.decode(
            LossyStringArray.self,
            forKey: key
        ).values else {
            return nil
        }
        var result: [String] = []
        result.reserveCapacity(min(values.count, 50))
        for item in values {
            result.append(truncate(item, maximumUTF16CodeUnits: 2_000))
            if result.count == 50 { break }
        }
        return result
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    /// JavaScript's `String.slice` limits strings in UTF-16 code units. Using
    /// the same unit keeps ASCII, CJK, and non-BMP limits aligned. If the limit
    /// splits a surrogate pair, Swift repairs the dangling unit to U+FFFD; this
    /// is the intentional safe-Unicode difference from JavaScript, which can
    /// retain an unpaired surrogate in a string.
    private static func truncate(_ value: String, maximumUTF16CodeUnits: Int) -> String {
        guard value.utf16.count > maximumUTF16CodeUnits else { return value }
        let units = Array(value.utf16.prefix(maximumUTF16CodeUnits))
        return String(decoding: units, as: UTF16.self)
    }
}

/// Decodes each element through its own decoder so a wrong element type does
/// not reject valid siblings. `superDecoder()` advances exactly one element
/// even when the requested scalar type cannot be decoded.
private struct LossyDoubleArray: Decodable {
    let values: [Double]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Double] = []
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            let element = try elementDecoder.singleValueContainer()
            if let value = try? element.decode(Double.self) {
                result.append(value)
            }
        }
        values = result
    }
}

private struct LossyStringArray: Decodable {
    let values: [String]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [String] = []
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            let element = try elementDecoder.singleValueContainer()
            if let value = try? element.decode(String.self) {
                result.append(value)
            }
        }
        values = result
    }
}
