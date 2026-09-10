import Foundation

/// A wire-compatible entry in `recent-files.json` or `recent-projects.json`.
/// Timestamps use Unix milliseconds, matching JavaScript's `Date.now()`.
public struct RecentItem: Codable, Equatable, Sendable {
    public let path: String
    public let lastOpened: Double

    public init(path: String, lastOpened: Double) {
        self.path = path
        self.lastOpened = lastOpened
    }
}

/// The Electron bridge gives files and projects identical persisted shapes.
public typealias RecentFile = RecentItem
public typealias RecentProject = RecentItem

/// Platform-neutral geometry associated with a window-session registry entry.
public struct WindowSessionBounds: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Geometry is kept platform-neutral so Core does not depend on AppKit.
    /// The window layer remains responsible for clamping a valid rectangle to
    /// the screens that are connected when it is restored.
    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}

public enum WindowSessionState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case normal
    case minimized
    case maximized
    case fullScreen = "fullscreen"

    /// Source compatibility for call sites that mirror Electron's spelling.
    public static var fullscreen: WindowSessionState { .fullScreen }
}

public struct WindowSessionPresentation: Codable, Equatable, Hashable, Sendable {
    public var bounds: WindowSessionBounds?
    public var state: WindowSessionState

    public init(
        bounds: WindowSessionBounds? = nil,
        state: WindowSessionState = .normal
    ) {
        self.bounds = bounds
        self.state = state
    }
}

/// A wire-compatible entry in `window-sessions.json`. Bounds and state are
/// optional additions: registries written before native window restoration
/// continue to decode, and Electron can ignore the extra JSON properties.
public struct WindowSessionMetadata: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let updatedAt: Double
    public let bounds: WindowSessionBounds?
    public let state: WindowSessionState?

    public init(
        id: String,
        updatedAt: Double,
        bounds: WindowSessionBounds? = nil,
        state: WindowSessionState? = nil
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.bounds = bounds
        self.state = state
    }

    public init(
        id: String,
        updatedAt: Double,
        presentation: WindowSessionPresentation
    ) {
        self.init(
            id: id,
            updatedAt: updatedAt,
            bounds: presentation.bounds,
            state: presentation.state
        )
    }

    public var presentation: WindowSessionPresentation? {
        guard bounds != nil || state != nil else { return nil }
        return WindowSessionPresentation(
            bounds: bounds,
            state: state ?? .normal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case updatedAt
        case bounds
        case state
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
        let decodedBounds = try? values.decodeIfPresent(
            WindowSessionBounds.self,
            forKey: .bounds
        )
        bounds = decodedBounds.flatMap { $0.isValid ? $0 : nil }
        state = (try? values.decodeIfPresent(WindowSessionState.self, forKey: .state)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(bounds, forKey: .bounds)
        try values.encodeIfPresent(state, forKey: .state)
    }
}

public typealias WindowSessionMeta = WindowSessionMetadata

public enum RecentItemsStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidAbsolutePath(String)
    case invalidWindowSessionID(String)
    case invalidWindowBounds
    case serializedDataTooLarge(actualBytes: Int, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidAbsolutePath(path):
            return "Recent-item paths must be absolute file-system paths: \(path)"
        case let .invalidWindowSessionID(id):
            return "Window session IDs may contain only ASCII letters, digits, and hyphens: \(id)"
        case .invalidWindowBounds:
            return "Window bounds must contain finite coordinates and positive dimensions."
        case let .serializedDataTooLarge(actualBytes, maximumBytes):
            return "Recent-item data uses \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        }
    }
}

/// Persists the process-wide recent-file, recent-project, and window-session
/// registries. Every read-modify-write transaction is serialized across store
/// instances so two native windows cannot lose one another's updates.
/// The coordinator is process-local; a caller that deliberately points two
/// application processes at one directory must provide external coordination.
///
/// Reads are deliberately forgiving. Individual malformed entries are
/// discarded, syntactically valid non-array roots safely behave as empty
/// registries, and malformed or oversized JSON is moved aside. Paths are
/// standardized lexically but symlinks are not resolved, preserving the path
/// the user selected.
public final class RecentItemsStore: @unchecked Sendable {
    public static let applicationSupportDirectoryName = "LumenEditorNativePreview"
    public static let recentFilesFileName = "recent-files.json"
    public static let recentProjectsFileName = "recent-projects.json"
    public static let windowSessionsFileName = "window-sessions.json"

    public static let maximumRecentFiles = 50
    public static let maximumRecentProjects = 30
    public static let maximumWindowSessions = 12
    public static let maximumSerializedBytes = 1_024 * 1_024

    public let directoryURL: URL
    public let recentFilesURL: URL
    public let recentProjectsURL: URL
    public let windowSessionsURL: URL
    public let serializedByteLimit: Int

    private static let persistenceLock = NSLock()
    private let fileManager: FileManager

    /// Creates a store in the native app's Application Support directory.
    public convenience init(
        fileManager: FileManager = .default,
        serializedByteLimit: Int = RecentItemsStore.maximumSerializedBytes
    ) {
        self.init(
            directoryURL: Self.defaultDirectoryURL(fileManager: fileManager),
            fileManager: fileManager,
            serializedByteLimit: serializedByteLimit
        )
    }

    /// Creates a store at an injected directory, useful for tests and previews.
    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        serializedByteLimit: Int = RecentItemsStore.maximumSerializedBytes
    ) {
        precondition(directoryURL.isFileURL, "directoryURL must be a file URL")
        precondition(serializedByteLimit >= 0, "serializedByteLimit must not be negative")

        let directory = directoryURL.standardizedFileURL
        self.directoryURL = directory
        self.recentFilesURL = directory.appendingPathComponent(
            Self.recentFilesFileName,
            isDirectory: false
        )
        self.recentProjectsURL = directory.appendingPathComponent(
            Self.recentProjectsFileName,
            isDirectory: false
        )
        self.windowSessionsURL = directory.appendingPathComponent(
            Self.windowSessionsFileName,
            isDirectory: false
        )
        self.fileManager = fileManager
        self.serializedByteLimit = serializedByteLimit
    }

    public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    // MARK: - Recent files

    public func recentFiles() -> [RecentFile] {
        withPersistenceLock {
            do {
                return try loadRecentItemsUnlocked(
                    from: recentFilesURL,
                    limit: Self.maximumRecentFiles
                )
            } catch {
                return []
            }
        }
    }

    /// Naming companion for call sites that model persistence explicitly.
    public func loadRecentFiles() -> [RecentFile] {
        recentFiles()
    }

    public func recordRecentFile(_ url: URL, at date: Date = Date()) throws {
        guard url.isFileURL else {
            throw RecentItemsStoreError.invalidAbsolutePath(url.absoluteString)
        }
        try recordRecentFile(url.path, at: date)
    }

    public func recordRecentFile(_ path: String, at date: Date = Date()) throws {
        let path = try requireAbsolutePath(path)
        try mutateRecentItems(
            at: recentFilesURL,
            limit: Self.maximumRecentFiles,
            inserting: RecentItem(path: path, lastOpened: milliseconds(since1970: date))
        )
    }

    public func addRecentFile(_ url: URL, at date: Date = Date()) throws {
        try recordRecentFile(url, at: date)
    }

    public func addRecentFile(_ path: String, at date: Date = Date()) throws {
        try recordRecentFile(path, at: date)
    }

    @discardableResult
    public func removeRecentFile(_ url: URL) throws -> Bool {
        guard url.isFileURL else {
            throw RecentItemsStoreError.invalidAbsolutePath(url.absoluteString)
        }
        return try removeRecentItem(url.path, from: recentFilesURL, limit: Self.maximumRecentFiles)
    }

    @discardableResult
    public func removeRecentFile(_ path: String) throws -> Bool {
        try removeRecentItem(path, from: recentFilesURL, limit: Self.maximumRecentFiles)
    }

    // MARK: - Recent projects

    public func recentProjects() -> [RecentProject] {
        withPersistenceLock {
            do {
                return try loadRecentItemsUnlocked(
                    from: recentProjectsURL,
                    limit: Self.maximumRecentProjects
                )
            } catch {
                return []
            }
        }
    }

    public func loadRecentProjects() -> [RecentProject] {
        recentProjects()
    }

    public func recordRecentProject(_ url: URL, at date: Date = Date()) throws {
        guard url.isFileURL else {
            throw RecentItemsStoreError.invalidAbsolutePath(url.absoluteString)
        }
        try recordRecentProject(url.path, at: date)
    }

    public func recordRecentProject(_ path: String, at date: Date = Date()) throws {
        let path = try requireAbsolutePath(path)
        try mutateRecentItems(
            at: recentProjectsURL,
            limit: Self.maximumRecentProjects,
            inserting: RecentItem(path: path, lastOpened: milliseconds(since1970: date))
        )
    }

    public func addRecentProject(_ url: URL, at date: Date = Date()) throws {
        try recordRecentProject(url, at: date)
    }

    public func addRecentProject(_ path: String, at date: Date = Date()) throws {
        try recordRecentProject(path, at: date)
    }

    @discardableResult
    public func removeRecentProject(_ url: URL) throws -> Bool {
        guard url.isFileURL else {
            throw RecentItemsStoreError.invalidAbsolutePath(url.absoluteString)
        }
        return try removeRecentItem(
            url.path,
            from: recentProjectsURL,
            limit: Self.maximumRecentProjects
        )
    }

    @discardableResult
    public func removeRecentProject(_ path: String) throws -> Bool {
        try removeRecentItem(
            path,
            from: recentProjectsURL,
            limit: Self.maximumRecentProjects
        )
    }

    // MARK: - Window sessions

    public func windowSessions() -> [WindowSessionMetadata] {
        withPersistenceLock {
            do {
                return try loadWindowSessionsUnlocked()
            } catch {
                return []
            }
        }
    }

    public func loadWindowSessions() -> [WindowSessionMetadata] {
        windowSessions()
    }

    public func windowSessionIDs() -> [String] {
        windowSessions().map(\.id)
    }

    public func registerWindowSession(_ id: String, at date: Date = Date()) throws {
        try registerWindowSession(id, presentation: nil, at: date)
    }

    public func registerWindowSession(id: String, at date: Date = Date()) throws {
        try registerWindowSession(id, at: date)
    }

    /// Registers a successfully persisted window and records its most recent
    /// presentation. Passing no presentation through the compatibility API
    /// above preserves any geometry already stored for that ID.
    public func registerWindowSession(
        _ id: String,
        presentation: WindowSessionPresentation,
        at date: Date = Date()
    ) throws {
        try registerWindowSession(id, presentation: Optional(presentation), at: date)
    }

    /// Updates geometry only for an existing registry entry. Returning false
    /// is intentional: observing a window frame must never make a session
    /// restorable before its first snapshot has been written successfully.
    @discardableResult
    public func updateWindowSessionPresentation(
        _ id: String,
        presentation: WindowSessionPresentation,
        at date: Date = Date()
    ) throws -> Bool {
        try requireValidWindowSessionID(id)
        try requireValidWindowPresentation(presentation)

        return try withPersistenceLock {
            let existing = try loadWindowSessionsUnlocked()
            guard existing.contains(where: { $0.id == id }) else { return false }
            let entry = WindowSessionMetadata(
                id: id,
                updatedAt: milliseconds(since1970: date),
                presentation: presentation
            )
            let next = canonicalWindowSessions(
                [entry] + existing.filter { $0.id != id },
                limit: Self.maximumWindowSessions
            )
            try writeJSON(next, to: windowSessionsURL)
            return true
        }
    }

    @discardableResult
    public func removeWindowSession(_ id: String) throws -> Bool {
        guard Self.isValidWindowSessionID(id) else {
            throw RecentItemsStoreError.invalidWindowSessionID(id)
        }

        return try withPersistenceLock {
            let existing = try loadWindowSessionsUnlocked()
            let next = existing.filter { $0.id != id }
            guard next.count != existing.count else { return false }
            try writeJSON(next, to: windowSessionsURL)
            return true
        }
    }

    /// Returns the snapshot path associated with a registry ID. Strict ID
    /// validation makes this safe to use for filename construction.
    public func windowSessionURL(for id: String) throws -> URL {
        guard Self.isValidWindowSessionID(id) else {
            throw RecentItemsStoreError.invalidWindowSessionID(id)
        }
        let name = id == "legacy" ? "session.json" : "session-\(id).json"
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    public func sessionURL(for id: String) throws -> URL {
        try windowSessionURL(for: id)
    }

    /// Mirrors `/^[a-z0-9-]+$/i` without Unicode letter expansion.
    public static func isValidWindowSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            byte == 45
                || (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
        }
    }

    private func registerWindowSession(
        _ id: String,
        presentation: WindowSessionPresentation?,
        at date: Date
    ) throws {
        try requireValidWindowSessionID(id)
        if let presentation {
            try requireValidWindowPresentation(presentation)
        }

        try withPersistenceLock {
            let existing = try loadWindowSessionsUnlocked()
            let previous = existing.first { $0.id == id }
            let entry: WindowSessionMetadata
            if let presentation {
                entry = WindowSessionMetadata(
                    id: id,
                    updatedAt: milliseconds(since1970: date),
                    presentation: presentation
                )
            } else {
                entry = WindowSessionMetadata(
                    id: id,
                    updatedAt: milliseconds(since1970: date),
                    bounds: previous?.bounds,
                    state: previous?.state
                )
            }
            let next = canonicalWindowSessions(
                [entry] + existing.filter { $0.id != id },
                limit: Self.maximumWindowSessions
            )
            try writeJSON(next, to: windowSessionsURL)
        }
    }

    private func requireValidWindowSessionID(_ id: String) throws {
        guard Self.isValidWindowSessionID(id) else {
            throw RecentItemsStoreError.invalidWindowSessionID(id)
        }
    }

    private func requireValidWindowPresentation(
        _ presentation: WindowSessionPresentation
    ) throws {
        guard presentation.bounds?.isValid != false else {
            throw RecentItemsStoreError.invalidWindowBounds
        }
    }

    // MARK: - Transactions

    private func mutateRecentItems(
        at url: URL,
        limit: Int,
        inserting entry: RecentItem
    ) throws {
        try withPersistenceLock {
            let existing = try loadRecentItemsUnlocked(from: url, limit: limit)
            let next = canonicalRecentItems(
                [entry] + existing.filter { $0.path != entry.path },
                limit: limit
            )
            try writeJSON(next, to: url)
        }
    }

    private func removeRecentItem(_ path: String, from url: URL, limit: Int) throws -> Bool {
        let path = try requireAbsolutePath(path)
        return try withPersistenceLock {
            let existing = try loadRecentItemsUnlocked(from: url, limit: limit)
            let next = existing.filter { $0.path != path }
            guard next.count != existing.count else { return false }
            try writeJSON(next, to: url)
            return true
        }
    }

    private func withPersistenceLock<T>(_ operation: () throws -> T) rethrows -> T {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        return try operation()
    }

    // MARK: - Tolerant decoding and sanitisation

    private func loadRecentItemsUnlocked(from url: URL, limit: Int) throws -> [RecentItem] {
        guard let raw = try readJSONRoot(from: url) as? [Any] else { return [] }

        let entries: [RecentItem] = raw.compactMap { value in
            guard let object = value as? [String: Any],
                  let rawPath = object["path"] as? String,
                  let path = normalizedAbsolutePath(rawPath) else {
                return nil
            }
            return RecentItem(
                path: path,
                lastOpened: finiteNumber(object["lastOpened"]) ?? 0
            )
        }
        return canonicalRecentItems(entries, limit: limit)
    }

    private func loadWindowSessionsUnlocked() throws -> [WindowSessionMetadata] {
        guard let raw = try readJSONRoot(from: windowSessionsURL) as? [Any] else { return [] }

        let entries: [WindowSessionMetadata] = raw.compactMap { value in
            guard let object = value as? [String: Any],
                  let id = object["id"] as? String,
                  Self.isValidWindowSessionID(id),
                  let updatedAt = finiteNumber(object["updatedAt"]) else {
                return nil
            }
            return WindowSessionMetadata(
                id: id,
                updatedAt: updatedAt,
                bounds: windowSessionBounds(object["bounds"]),
                state: (object["state"] as? String).flatMap(WindowSessionState.init(rawValue:))
            )
        }
        return canonicalWindowSessions(entries, limit: Self.maximumWindowSessions)
    }

    private func windowSessionBounds(_ value: Any?) -> WindowSessionBounds? {
        guard let object = value as? [String: Any],
              let x = finiteNumber(object["x"]),
              let y = finiteNumber(object["y"]),
              let width = finiteNumber(object["width"]),
              let height = finiteNumber(object["height"]) else {
            return nil
        }
        let bounds = WindowSessionBounds(x: x, y: y, width: width, height: height)
        return bounds.isValid ? bounds : nil
    }

    private func canonicalRecentItems(_ entries: [RecentItem], limit: Int) -> [RecentItem] {
        let sorted = entries.enumerated().sorted { left, right in
            if left.element.lastOpened != right.element.lastOpened {
                return left.element.lastOpened > right.element.lastOpened
            }
            // Preserve disk order for equal millisecond timestamps. A newly
            // recorded entry is prepended, so it wins an exact-time tie.
            return left.offset < right.offset
        }

        var seen = Set<String>()
        var result: [RecentItem] = []
        result.reserveCapacity(min(limit, sorted.count))
        for candidate in sorted where seen.insert(candidate.element.path).inserted {
            result.append(candidate.element)
            if result.count == limit { break }
        }
        return result
    }

    private func canonicalWindowSessions(
        _ entries: [WindowSessionMetadata],
        limit: Int
    ) -> [WindowSessionMetadata] {
        let sorted = entries.enumerated().sorted { left, right in
            if left.element.updatedAt != right.element.updatedAt {
                return left.element.updatedAt > right.element.updatedAt
            }
            return left.offset < right.offset
        }

        var seen = Set<String>()
        var result: [WindowSessionMetadata] = []
        result.reserveCapacity(min(limit, sorted.count))
        for candidate in sorted where seen.insert(candidate.element.id).inserted {
            result.append(candidate.element)
            if result.count == limit { break }
        }
        return result
    }

    private func requireAbsolutePath(_ path: String) throws -> String {
        guard let normalized = normalizedAbsolutePath(path) else {
            throw RecentItemsStoreError.invalidAbsolutePath(path)
        }
        return normalized
    }

    private func normalizedAbsolutePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.contains("\0"),
              path.hasPrefix("/"), // POSIX `/`; unlike NSString, do not accept `~`.
              (path as NSString).isAbsolutePath else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // JSON booleans bridge through NSNumber too, but JavaScript's
        // `typeof true` is not `number`.
        let type = String(cString: number.objCType)
        guard type != "c", type != "B" else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private func milliseconds(since1970 date: Date) -> Double {
        // Date.now() is integral even though JavaScript stores it as a Number.
        (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
    }

    // MARK: - Bounded atomic JSON persistence

    private func readJSONRoot(from url: URL) throws -> Any? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > serializedByteLimit {
                try quarantineCorruptFile(at: url)
                return nil
            }
            guard let bounded = try readBoundedData(from: url) else {
                try quarantineCorruptFile(at: url)
                return nil
            }
            data = bounded
        } catch {
            // Permission and transient I/O failures must not destroy data that
            // may be readable on a later launch. Public reads catch this and
            // return an empty view; mutations propagate it and do not write.
            throw error
        }

        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            try quarantineCorruptFile(at: url)
            return nil
        }
    }

    /// Reads at most one byte past the limit, including when file-size metadata
    /// is absent or races with an external writer.
    private func readBoundedData(from url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while data.count <= serializedByteLimit {
            let remaining = serializedByteLimit - data.count
            let readSize = remaining == 0 ? 1 : min(64 * 1_024, remaining)
            guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            if data.count > serializedByteLimit { return nil }
        }
        return nil
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= serializedByteLimit else {
            throw RecentItemsStoreError.serializedDataTooLarge(
                actualBytes: data.count,
                maximumBytes: serializedByteLimit
            )
        }

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: url, options: .atomic)
    }

    /// Isolation errors propagate to mutations so a bad but recoverable file
    /// is never overwritten. Public reads catch them and safely return empty.
    private func quarantineCorruptFile(at url: URL) throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.lowercased()
        let quarantineURL = url.appendingPathExtension(
            "corrupt-\(timestamp)-\(suffix)"
        )
        try fileManager.moveItem(at: url, to: quarantineURL)
    }
}
