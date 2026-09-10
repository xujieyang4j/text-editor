import Foundation

/// A selection expressed as UTF-16 offsets, matching the coordinate system
/// used by AppKit text views. A backwards selection has `anchor > head`.
public struct SessionSelection: Codable, Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }
}

/// The serialisable state needed to reconstruct one editor tab.
public struct SessionTab: Codable, Equatable {
    /// The absolute file-system path, or `nil` for an untitled buffer.
    public var path: String?
    public var name: String
    /// The current editor text, including any unsaved draft.
    public var content: String
    /// The last content known to have been saved to disk.
    public var savedContent: String
    public var encoding: TextEncoding
    /// The encoding at the last successful save. Optional for snapshots
    /// written by the first native preview build.
    public var savedEncoding: TextEncoding?
    public var eol: LineEnding
    /// The line ending at the last successful save. Optional for backwards
    /// compatibility with early native snapshots.
    public var savedEOL: LineEnding?
    /// An opaque disk revision supplied by the document layer.
    public var revision: String?
    /// Whether the disk baseline must be decoded with `savedEncoding` rather
    /// than automatic detection.
    public var encodingLocked: Bool?
    /// A decoding warning attached to the draft. Retaining it prevents a
    /// recovered buffer containing replacement characters from appearing
    /// lossless after relaunch.
    public var encodingIssue: EncodingIssue?
    /// Carries dirty state that cannot be derived from text or formatting,
    /// such as a draft recovered after its original file disappeared.
    public var requiresSave: Bool?
    public var selection: SessionSelection

    public init(
        path: String?,
        name: String,
        content: String,
        savedContent: String,
        encoding: TextEncoding,
        savedEncoding: TextEncoding? = nil,
        eol: LineEnding,
        savedEOL: LineEnding? = nil,
        revision: String?,
        encodingLocked: Bool? = nil,
        encodingIssue: EncodingIssue? = nil,
        requiresSave: Bool? = nil,
        selection: SessionSelection
    ) {
        self.path = path
        self.name = name
        self.content = content
        self.savedContent = savedContent
        self.encoding = encoding
        self.savedEncoding = savedEncoding
        self.eol = eol
        self.savedEOL = savedEOL
        self.revision = revision
        self.encodingLocked = encodingLocked
        self.encodingIssue = encodingIssue
        self.requiresSave = requiresSave
        self.selection = selection
    }
}

/// A complete, versioned editor-session snapshot.
public struct EditorSession: Codable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var tabs: [SessionTab]
    /// The selected tab, or `nil` when the session has no tabs.
    public var activeTabIndex: Int?

    public init(
        formatVersion: Int = EditorSession.currentFormatVersion,
        tabs: [SessionTab] = [],
        activeTabIndex: Int? = nil
    ) {
        self.formatVersion = formatVersion
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
    }

    public static var empty: EditorSession { EditorSession() }
}

public enum SessionStoreError: Error, Equatable, Sendable {
    case tooManyTabs(actual: Int, maximum: Int)
    case draftDataTooLarge(actualBytes: Int, maximumBytes: Int)
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidSnapshot
    case unsupportedFormatVersion(Int)
}

extension SessionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .tooManyTabs(actual, maximum):
            return "A session contains \(actual) tabs; the maximum is \(maximum)."
        case let .draftDataTooLarge(actualBytes, maximumBytes):
            return "Session drafts use \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        case let .snapshotTooLarge(actualBytes, maximumBytes):
            return "The session snapshot uses \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        case .invalidSnapshot:
            return "The session snapshot contains invalid document state."
        case let .unsupportedFormatVersion(version):
            return "Session format version \(version) is not supported."
        }
    }
}

/// Persists an editor session as JSON. Reads never prevent application launch:
/// an unreadable file produces an empty session, while a malformed or invalid
/// file is moved aside before returning the same safe fallback.
public final class SessionStore {
    private struct SnapshotVersion: Decodable {
        let formatVersion: Int
    }

    public struct Limits: Equatable, Sendable {
        public static let `default` = Limits(
            maximumTabs: 100,
            maximumDraftBytes: 200 * 1_024 * 1_024,
            maximumSnapshotBytes: 208 * 1_024 * 1_024
        )

        public var maximumTabs: Int
        public var maximumDraftBytes: Int
        public var maximumSnapshotBytes: Int

        public init(
            maximumTabs: Int,
            maximumDraftBytes: Int,
            maximumSnapshotBytes: Int? = nil
        ) {
            precondition(maximumTabs >= 0, "maximumTabs must not be negative")
            precondition(maximumDraftBytes >= 0, "maximumDraftBytes must not be negative")
            let defaultSnapshotBytes = maximumDraftBytes.addingReportingOverflow(
                8 * 1_024 * 1_024
            )
            let snapshotBytes = maximumSnapshotBytes
                ?? (defaultSnapshotBytes.overflow ? Int.max : defaultSnapshotBytes.partialValue)
            precondition(snapshotBytes >= 0, "maximumSnapshotBytes must not be negative")
            self.maximumTabs = maximumTabs
            self.maximumDraftBytes = maximumDraftBytes
            self.maximumSnapshotBytes = snapshotBytes
        }
    }

    public static let applicationSupportDirectoryName = "LumenEditorNativePreview"
    public static let sessionFileName = "session.json"

    public let sessionURL: URL
    public let limits: Limits

    private let fileManager: FileManager
    private let lock = NSLock()

    /// Creates a store in the user's Application Support directory.
    public convenience init(
        fileManager: FileManager = .default,
        limits: Limits = .default
    ) {
        self.init(
            sessionURL: Self.defaultSessionURL(fileManager: fileManager),
            fileManager: fileManager,
            limits: limits
        )
    }

    /// Creates a store at an injected location, useful for tests and previews.
    public init(
        sessionURL: URL,
        fileManager: FileManager = .default,
        limits: Limits = .default
    ) {
        self.sessionURL = sessionURL
        self.fileManager = fileManager
        self.limits = limits
    }

    public static func defaultSessionURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionFileName, isDirectory: false)
    }

    /// Returns an empty session if no snapshot exists or the snapshot cannot be
    /// read. Invalid JSON, unsupported versions, and limit violations are also
    /// quarantined so they will not be retried on every launch.
    public func load() -> EditorSession {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: sessionURL.path) else {
            return .empty
        }

        let data: Data
        do {
            let values = try sessionURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > limits.maximumSnapshotBytes {
                quarantineCorruptFile()
                return .empty
            }
            guard let boundedData = try readSnapshotData() else {
                quarantineCorruptFile()
                return .empty
            }
            data = boundedData
        } catch {
            return .empty
        }

        do {
            // A V2 snapshot belongs to the WindowSession API. In particular,
            // do not quarantine it merely because the legacy App model cannot
            // decode its schema as an EditorSession.
            if try snapshotFormatVersion(in: data) == WindowSession.currentFormatVersion {
                _ = try WindowSession.decodeOrMigrate(
                    from: data,
                    limits: windowSessionLimits
                )
                return .empty
            }
            let session = try JSONDecoder().decode(EditorSession.self, from: data)
            try validate(session)
            return session
        } catch {
            quarantineCorruptFile()
            return .empty
        }
    }

    /// Loads either a native V2 window snapshot or a migrated V1 editor
    /// snapshot. Invalid data and resource-limit violations are quarantined;
    /// missing and temporarily unreadable files use the safe empty fallback.
    public func loadWindowSession() -> WindowSession {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: sessionURL.path) else {
            return .empty
        }

        let data: Data
        do {
            let values = try sessionURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > limits.maximumSnapshotBytes {
                quarantineCorruptFile()
                return .empty
            }
            guard let boundedData = try readSnapshotData() else {
                quarantineCorruptFile()
                return .empty
            }
            data = boundedData
        } catch {
            return .empty
        }

        do {
            return try WindowSession.decodeOrMigrate(
                from: data,
                limits: windowSessionLimits
            )
        } catch {
            quarantineCorruptFile()
            return .empty
        }
    }

    /// Validates and atomically replaces the on-disk session snapshot.
    public func save(_ session: EditorSession) throws {
        lock.lock()
        defer { lock.unlock() }

        try validate(session)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        guard data.count <= limits.maximumSnapshotBytes else {
            throw SessionStoreError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: limits.maximumSnapshotBytes
            )
        }
        let directory = sessionURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: sessionURL, options: .atomic)
    }

    /// Validates and atomically replaces the snapshot with a V2 window
    /// session encoded as deterministic, human-readable JSON.
    @_disfavoredOverload
    public func save(_ session: WindowSession) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try session.encodedData(
            using: encoder,
            limits: windowSessionLimits
        )
        let directory = sessionURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: sessionURL, options: .atomic)
    }

    private var windowSessionLimits: WindowSession.Limits {
        WindowSession.Limits(
            maximumTabs: limits.maximumTabs,
            maximumRecoveryBytes: limits.maximumDraftBytes,
            maximumSnapshotBytes: limits.maximumSnapshotBytes
        )
    }

    private func snapshotFormatVersion(in data: Data) throws -> Int {
        try JSONDecoder().decode(SnapshotVersion.self, from: data).formatVersion
    }

    private func validate(_ session: EditorSession) throws {
        guard session.formatVersion == EditorSession.currentFormatVersion else {
            throw SessionStoreError.unsupportedFormatVersion(session.formatVersion)
        }
        guard session.tabs.count <= limits.maximumTabs else {
            throw SessionStoreError.tooManyTabs(
                actual: session.tabs.count,
                maximum: limits.maximumTabs
            )
        }
        if let activeTabIndex = session.activeTabIndex {
            guard activeTabIndex >= 0, activeTabIndex < session.tabs.count else {
                throw SessionStoreError.invalidSnapshot
            }
        }

        var totalDraftBytes = 0
        for tab in session.tabs {
            if let path = tab.path {
                guard (path as NSString).isAbsolutePath else {
                    throw SessionStoreError.invalidSnapshot
                }
            }
            guard tab.selection.anchor >= 0, tab.selection.head >= 0 else {
                throw SessionStoreError.invalidSnapshot
            }
            let currentBytes = tab.content.lengthOfBytes(using: .utf8)
            let savedBytes = tab.savedContent.lengthOfBytes(using: .utf8)
            let combined = currentBytes.addingReportingOverflow(savedBytes)
            let bytes = combined.overflow ? Int.max : combined.partialValue
            guard totalDraftBytes <= limits.maximumDraftBytes,
                  bytes <= limits.maximumDraftBytes - totalDraftBytes else {
                let actual = totalDraftBytes.addingReportingOverflow(bytes)
                throw SessionStoreError.draftDataTooLarge(
                    actualBytes: actual.overflow ? Int.max : actual.partialValue,
                    maximumBytes: limits.maximumDraftBytes
                )
            }
            totalDraftBytes += bytes
        }
    }

    /// Reads at most one byte beyond the configured limit so a malformed
    /// snapshot cannot force an unbounded allocation between stat and read.
    private func readSnapshotData() throws -> Data? {
        let handle = try FileHandle(forReadingFrom: sessionURL)
        defer { try? handle.close() }

        var data = Data()
        while true {
            let remaining = limits.maximumSnapshotBytes - data.count
            let readSize = remaining == 0 ? 1 : min(1_024 * 1_024, remaining)
            guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            guard data.count <= limits.maximumSnapshotBytes else {
                return nil
            }
        }
    }

    /// Best-effort isolation. Failure to rename must not turn session recovery
    /// into an application-launch failure.
    private func quarantineCorruptFile() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.lowercased()
        let quarantineURL = sessionURL.appendingPathExtension(
            "corrupt-\(timestamp)-\(suffix)"
        )
        try? fileManager.moveItem(at: sessionURL, to: quarantineURL)
    }
}
