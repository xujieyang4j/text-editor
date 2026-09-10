import Foundation

public enum SettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormatVersion(Int)
    case snapshotTooLarge

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(version):
            return "Settings format version \(version) is not supported."
        case .snapshotTooLarge:
            return "The settings file exceeds the supported size limit."
        }
    }
}

/// Loads and atomically persists native editor settings.
///
/// Missing or unreadable files return defaults. Unlike Electron's silent JSON
/// parse fallback, malformed native JSON is moved aside so a bad file cannot
/// poison every application launch. Valid objects are decoded field-by-field
/// by `EditorSettings`, which preserves recognised values while defaulting only
/// bad or missing fields. Unversioned Electron files and future integer versions
/// remain readable; saving a future version is rejected to avoid overwriting
/// fields this build does not understand.
public final class SettingsStore {
    public static let applicationSupportDirectoryName = "LumenEditorNativePreview"
    public static let settingsFileName = "settings.json"
    public static let maximumSerializedBytes = 1_024 * 1_024

    public let settingsURL: URL

    private static let persistenceLock = NSLock()
    private let fileManager: FileManager

    /// Creates a store in the user's Application Support directory.
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            settingsURL: Self.defaultSettingsURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// Creates a store at an injected location, useful for tests and previews.
    public init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    public static func defaultSettingsURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(settingsFileName, isDirectory: false)
    }

    public func load() -> EditorSettings {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .default
        }

        let data: Data
        do {
            let values = try settingsURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= Self.maximumSerializedBytes else {
                quarantineCorruptFile()
                return .default
            }
            let handle = try FileHandle(forReadingFrom: settingsURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumSerializedBytes + 1) ?? Data()
            guard data.count <= Self.maximumSerializedBytes else {
                quarantineCorruptFile()
                return .default
            }
        } catch {
            // A transient permission or I/O failure should not destroy a file
            // that may still be valid and recoverable on the next launch.
            return .default
        }

        do {
            // Electron treats any valid non-object JSON as an empty settings
            // object. Preserve that migration behaviour instead of quarantining
            // syntactically valid JSON solely because its root has another type.
            let root = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
            guard root is [String: Any] else { return .default }

            return try JSONDecoder().decode(EditorSettings.self, from: data)
        } catch {
            quarantineCorruptFile()
            return .default
        }
    }

    /// Sanitises and atomically replaces the on-disk settings object.
    public func save(_ settings: EditorSettings) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }

        guard settings.formatVersion == EditorSettings.currentFormatVersion else {
            throw SettingsStoreError.unsupportedFormatVersion(settings.formatVersion)
        }

        let sanitized = settings.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sanitized)
        guard data.count <= Self.maximumSerializedBytes else {
            throw SettingsStoreError.snapshotTooLarge
        }

        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Best-effort isolation: inability to rename a broken file must never
    /// prevent the editor from launching with safe defaults.
    private func quarantineCorruptFile() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.lowercased()
        let quarantineURL = settingsURL.appendingPathExtension(
            "corrupt-\(timestamp)-\(suffix)"
        )
        try? fileManager.moveItem(at: settingsURL, to: quarantineURL)
    }
}
