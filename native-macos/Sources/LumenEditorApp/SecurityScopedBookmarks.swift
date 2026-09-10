@preconcurrency import Foundation
import LumenEditorCore

enum SecurityScopedBookmarkKind: String, Codable, CaseIterable, Sendable {
    case file
    case directory
}

struct SecurityScopedBookmarkRecord: Codable, Equatable, Sendable {
    let id: UUID
    var path: String
    var aliases: [String]
    var kind: SecurityScopedBookmarkKind
    var bookmarkData: Data
    var updatedAt: Double
}

struct SecurityScopedBookmarkMatch: Equatable, Sendable {
    let record: SecurityScopedBookmarkRecord
    /// The record path or historical alias that matched the requested URL.
    /// Directory matches use this path to preserve the relative descendant.
    let matchedPath: String
}

struct SecurityScopedFileAccessMove: Equatable, Sendable {
    let source: URL
    let destination: URL
}

enum SecurityScopedBookmarkStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL(String)
    case bookmarkTooLarge(actualBytes: Int, maximumBytes: Int)
    case persistenceCapacityExceeded
    case pathConflict(String)
    case transactionInProgress
    case serializedDataTooLarge(actualBytes: Int, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            "A security-scoped bookmark requires an absolute local path: \(value)"
        case let .bookmarkTooLarge(actual, maximum):
            "Bookmark data uses \(actual) bytes; the maximum is \(maximum) bytes."
        case .persistenceCapacityExceeded:
            "The bounded security-scoped bookmark store has no remaining capacity."
        case let .pathConflict(path):
            "A different security-scoped file grant already uses \(path)."
        case .transactionInProgress:
            "A security-scoped bookmark update is already in progress."
        case let .serializedDataTooLarge(actual, maximum):
            "Bookmark metadata uses \(actual) bytes; the maximum is \(maximum) bytes."
        }
    }
}

private final class SecurityScopedBookmarkPersistenceLock: @unchecked Sendable {
    static let shared = SecurityScopedBookmarkPersistenceLock()
    let value = NSLock()
    var pendingRebases: [String: PendingSecurityScopedBookmarkRebase] = [:]
}

private struct PendingSecurityScopedBookmarkRebase {
    let id: UUID
    let previousRecords: [SecurityScopedBookmarkRecord]
}

private struct PersistentSecurityScopedFileMove: Codable {
    let sourcePath: String
    let destinationPath: String
}

private struct PersistentSecurityScopedBookmarkRebase: Codable {
    let id: UUID
    let previousRecords: [SecurityScopedBookmarkRecord]
    let moves: [PersistentSecurityScopedFileMove]
}

final class PreparedSecurityScopedBookmarkRebase: @unchecked Sendable {
    private enum State: Equatable { case prepared, committed, aborted }

    private let lock = NSLock()
    private var state: State = .prepared
    private let commitAction: @Sendable () -> Void
    private let abortAction: @Sendable () throws -> Void

    init(
        commit: @escaping @Sendable () -> Void,
        abort: @escaping @Sendable () throws -> Void
    ) {
        commitAction = commit
        abortAction = abort
    }

    func commit() {
        lock.lock()
        guard state == .prepared else {
            lock.unlock()
            return
        }
        state = .committed
        lock.unlock()
        commitAction()
    }

    func abort() throws {
        lock.lock()
        guard state == .prepared else {
            lock.unlock()
            return
        }
        do {
            try abortAction()
            state = .aborted
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    deinit { try? abort() }
}

/// A process-wide, independently recoverable bookmark registry. Session and
/// recent-item files deliberately continue to persist plain paths so a damaged
/// bookmark cannot destroy hot-exit drafts or change their compatibility schema.
final class SecurityScopedBookmarkStore: @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        static let `default` = Limits(
            maximumRecords: 2_048,
            maximumBookmarkBytes: 64 * 1_024,
            maximumTotalBookmarkBytes: 16 * 1_024 * 1_024,
            maximumSerializedBytes: 24 * 1_024 * 1_024,
            maximumAliasesPerRecord: 4
        )

        var maximumRecords: Int
        var maximumBookmarkBytes: Int
        var maximumTotalBookmarkBytes: Int
        var maximumSerializedBytes: Int
        var maximumAliasesPerRecord: Int

        init(
            maximumRecords: Int,
            maximumBookmarkBytes: Int,
            maximumTotalBookmarkBytes: Int,
            maximumSerializedBytes: Int,
            maximumAliasesPerRecord: Int
        ) {
            precondition(maximumRecords >= 0)
            precondition(maximumBookmarkBytes >= 0)
            precondition(maximumTotalBookmarkBytes >= 0)
            precondition(maximumSerializedBytes >= 0)
            precondition(maximumAliasesPerRecord >= 0)
            self.maximumRecords = maximumRecords
            self.maximumBookmarkBytes = maximumBookmarkBytes
            self.maximumTotalBookmarkBytes = maximumTotalBookmarkBytes
            self.maximumSerializedBytes = maximumSerializedBytes
            self.maximumAliasesPerRecord = maximumAliasesPerRecord
        }
    }

    static let fileName = "security-scoped-bookmarks.json"
    private static let formatVersion = 1

    private struct Snapshot: Codable {
        var formatVersion: Int
        var records: [SecurityScopedBookmarkRecord]
        var pendingRebase: PersistentSecurityScopedBookmarkRebase?

        init(
            formatVersion: Int, records: [SecurityScopedBookmarkRecord],
            pendingRebase: PersistentSecurityScopedBookmarkRebase? = nil
        ) {
            self.formatVersion = formatVersion
            self.records = records
            self.pendingRebase = pendingRebase
        }

        private enum CodingKeys: String, CodingKey {
            case formatVersion, records, pendingRebase
        }

    init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
            records = try container.decode(
                [SecurityScopedBookmarkRecord].self, forKey: .records
            )
            pendingRebase = try container.decodeIfPresent(
                PersistentSecurityScopedBookmarkRebase.self, forKey: .pendingRebase
            )
        }
    }

    let fileURL: URL
    let limits: Limits
    private let fileManager: FileManager
    private static var persistenceLock: SecurityScopedBookmarkPersistenceLock { .shared }
    private var transactionKey: String { fileURL.path }

    convenience init(
        fileManager: FileManager = .default,
        limits: Limits = .default
    ) {
        self.init(
            directoryURL: RecentItemsStore.defaultDirectoryURL(fileManager: fileManager),
            fileManager: fileManager,
            limits: limits
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        limits: Limits = .default
    ) {
        precondition(directoryURL.isFileURL)
        self.fileURL = directoryURL.standardizedFileURL.appendingPathComponent(
            Self.fileName, isDirectory: false
        )
        self.fileManager = fileManager
        self.limits = limits
    }

    func records() -> [SecurityScopedBookmarkRecord] {
        Self.withPersistenceLock {
            (try? visibleRecordsUnlocked()) ?? []
        }
    }

    func simulateProcessRestartForTesting() {
        Self.withPersistenceLock {
            Self.persistenceLock.pendingRebases[transactionKey] = nil
        }
    }

    func match(
        for url: URL,
        kind: SecurityScopedBookmarkKind,
        allowingDirectoryAncestor: Bool
    ) -> SecurityScopedBookmarkMatch? {
        guard let requested = normalizedPath(url) else { return nil }
        return Self.withPersistenceLock {
            guard let records = try? visibleRecordsUnlocked() else { return nil }
            var exact: [(SecurityScopedBookmarkRecord, String)] = []
            var ancestors: [(SecurityScopedBookmarkRecord, String)] = []
            for record in records {
                let lookupPaths = [record.path] + record.aliases
                for path in lookupPaths where path == requested {
                    if record.kind == kind {
                        exact.append((record, path))
                    }
                }
                guard allowingDirectoryAncestor, kind == .file,
                      record.kind == .directory else { continue }
                for path in lookupPaths where Self.contains(path, requested) {
                    ancestors.append((record, path))
                }
            }
            let candidate = exact.max { $0.0.updatedAt < $1.0.updatedAt }
                ?? ancestors.max { left, right in
                    let leftCount = URL(fileURLWithPath: left.1).pathComponents.count
                    let rightCount = URL(fileURLWithPath: right.1).pathComponents.count
                    if leftCount != rightCount { return leftCount < rightCount }
                    return left.0.updatedAt < right.0.updatedAt
                }
            return candidate.map { SecurityScopedBookmarkMatch(
                record: $0.0, matchedPath: $0.1
            ) }
        }
    }

    @discardableResult
    func record(
        _ bookmarkData: Data,
        for url: URL,
        kind: SecurityScopedBookmarkKind,
        preservingDirectoryCoveredFile: Bool = false,
        at date: Date = Date()
    ) throws -> SecurityScopedBookmarkRecord {
        guard let path = normalizedPath(url) else {
            throw SecurityScopedBookmarkStoreError.invalidURL(url.absoluteString)
        }
        try validateBookmarkSize(bookmarkData)
        return try Self.withPersistenceLock {
            try requireNoPendingRebaseUnlocked()
            var records = try loadUnlocked()
            let existingIndex = records.firstIndex { record in
                if record.kind == kind {
                    return ([record.path] + record.aliases).contains(path)
                }
                if kind == .file, record.kind == .directory,
                   !preservingDirectoryCoveredFile {
                    return ([record.path] + record.aliases).contains {
                        Self.contains($0, path)
                    }
                }
                return false
            }
            let record: SecurityScopedBookmarkRecord
            if let existingIndex {
                var existing = records.remove(at: existingIndex)
                if existing.kind == kind {
                    if existing.path != path {
                        existing.aliases.insert(existing.path, at: 0)
                    }
                    existing.path = path
                    existing.aliases = canonicalAliases(
                        existing.aliases, excluding: path
                    )
                    existing.bookmarkData = bookmarkData
                }
                existing.updatedAt = milliseconds(date)
                record = existing
            } else {
                record = SecurityScopedBookmarkRecord(
                    id: UUID(), path: path, aliases: [], kind: kind,
                    bookmarkData: bookmarkData, updatedAt: milliseconds(date)
                )
            }
            records.insert(record, at: 0)
            try writeBounded(records, retaining: record.id)
            return record
        }
    }

    @discardableResult
    func refresh(
        _ match: SecurityScopedBookmarkMatch,
        bookmarkData: Data,
        resolvedURL: URL,
        at date: Date = Date()
    ) throws -> SecurityScopedBookmarkRecord {
        guard let path = normalizedPath(resolvedURL) else {
            throw SecurityScopedBookmarkStoreError.invalidURL(resolvedURL.absoluteString)
        }
        try validateBookmarkSize(bookmarkData)
        return try Self.withPersistenceLock {
            try requireNoPendingRebaseUnlocked()
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.id == match.record.id }) else {
                return try recordUnlocked(
                    bookmarkData, path: path, kind: match.record.kind, date: date,
                    records: &records
                )
            }
            var record = records.remove(at: index)
            if record.path != path { record.aliases.insert(record.path, at: 0) }
            if match.matchedPath != path { record.aliases.insert(match.matchedPath, at: 0) }
            record.path = path
            record.aliases = canonicalAliases(record.aliases, excluding: path)
            record.bookmarkData = bookmarkData
            record.updatedAt = milliseconds(date)
            records.insert(record, at: 0)
            try writeBounded(records, retaining: record.id)
            return record
        }
    }

    /// Atomically prepares all exact-file bookmark changes for one filesystem
    /// mutation. Until commit, lookups continue to see the original snapshot;
    /// abort restores that snapshot after any later filesystem failure.
    @discardableResult
    func prepareExactFileRebases(
        _ moves: [SecurityScopedFileAccessMove], at date: Date = Date()
    ) throws -> PreparedSecurityScopedBookmarkRebase? {
        let normalizedMoves = try moves.map { move -> (String, String) in
            guard let source = normalizedPath(move.source) else {
                throw SecurityScopedBookmarkStoreError.invalidURL(
                    move.source.absoluteString
                )
            }
            guard let destination = normalizedPath(move.destination) else {
                throw SecurityScopedBookmarkStoreError.invalidURL(
                    move.destination.absoluteString
                )
            }
            return (source, destination)
        }
        guard !normalizedMoves.isEmpty else { return nil }

        let transactionID = UUID()
        let didPrepare = try Self.withPersistenceLock { () -> Bool in
            try requireNoPendingRebaseUnlocked()
            let previous = try loadUnlocked()
            var destinationsBySource: [String: String] = [:]
            for (source, destination) in normalizedMoves {
                if let existing = destinationsBySource[source], existing != destination {
                    throw SecurityScopedBookmarkStoreError.pathConflict(source)
                }
                destinationsBySource[source] = destination
            }

            var changesByID: [UUID: (source: String, destination: String)] = [:]
            var destinationOwners: [String: UUID] = [:]
            for (source, destination) in destinationsBySource {
                let matches = previous.filter { record in
                    record.kind == .file
                        && ([record.path] + record.aliases).contains(source)
                }
                guard matches.count <= 1 else {
                    throw SecurityScopedBookmarkStoreError.pathConflict(source)
                }
                guard let record = matches.first else { continue }
                if let existing = changesByID[record.id],
                   existing.source != source || existing.destination != destination {
                    throw SecurityScopedBookmarkStoreError.pathConflict(source)
                }
                if let owner = destinationOwners[destination], owner != record.id {
                    throw SecurityScopedBookmarkStoreError.pathConflict(destination)
                }
                changesByID[record.id] = (source, destination)
                destinationOwners[destination] = record.id
            }
            guard !changesByID.isEmpty else { return false }

            for (destination, owner) in destinationOwners {
                for record in previous where record.kind == .file && record.id != owner {
                    if ([record.path] + record.aliases).contains(destination) {
                        throw SecurityScopedBookmarkStoreError.pathConflict(destination)
                    }
                }
            }

            let timestamp = milliseconds(date)
            let candidate = previous.map { record -> SecurityScopedBookmarkRecord in
                guard let change = changesByID[record.id] else { return record }
                var updated = record
                if updated.path != change.destination {
                    updated.aliases.insert(updated.path, at: 0)
                }
                if change.source != change.destination {
                    updated.aliases.insert(change.source, at: 0)
                }
                updated.path = change.destination
                updated.aliases = canonicalAliases(
                    updated.aliases, excluding: change.destination
                )
                updated.updatedAt = timestamp
                return updated
            }
            let requiredIDs = Set(changesByID.keys)
            let persistent = PersistentSecurityScopedBookmarkRebase(
                id: transactionID, previousRecords: previous,
                moves: normalizedMoves.map {
                    PersistentSecurityScopedFileMove(
                        sourcePath: $0.0, destinationPath: $0.1
                    )
                }
            )
            let bounded = try boundedRecords(
                candidate, retaining: requiredIDs, pendingRebase: persistent
            )
            try writeSnapshot(bounded, pendingRebase: persistent)
            Self.persistenceLock.pendingRebases[transactionKey] =
                PendingSecurityScopedBookmarkRebase(
                    id: transactionID, previousRecords: previous
                )
            return true
        }
        guard didPrepare else { return nil }
        return PreparedSecurityScopedBookmarkRebase(
            commit: { [self] in commitPreparedRebase(transactionID) },
            abort: { [self] in try abortPreparedRebase(transactionID) }
        )
    }

    @discardableResult
    func rebaseExactFile(
        from oldURL: URL, to newURL: URL, at date: Date = Date()
    ) throws -> SecurityScopedBookmarkRecord? {
        let prepared = try prepareExactFileRebases([
            SecurityScopedFileAccessMove(source: oldURL, destination: newURL)
        ], at: date)
        prepared?.commit()
        return match(
            for: newURL, kind: .file, allowingDirectoryAncestor: false
        )?.record
    }

    @discardableResult
    func remove(id: UUID) throws -> Bool {
        try Self.withPersistenceLock {
            try requireNoPendingRebaseUnlocked()
            var records = try loadUnlocked()
            let originalCount = records.count
            records.removeAll { $0.id == id }
            guard records.count != originalCount else { return false }
            try writeSnapshot(records)
            return true
        }
    }

    private func recordUnlocked(
        _ data: Data,
        path: String,
        kind: SecurityScopedBookmarkKind,
        date: Date,
        records: inout [SecurityScopedBookmarkRecord]
    ) throws -> SecurityScopedBookmarkRecord {
        let record = SecurityScopedBookmarkRecord(
            id: UUID(), path: path, aliases: [], kind: kind,
            bookmarkData: data, updatedAt: milliseconds(date)
        )
        records.insert(record, at: 0)
        try writeBounded(records, retaining: record.id)
        return record
    }

    private func visibleRecordsUnlocked() throws -> [SecurityScopedBookmarkRecord] {
        if let pending = Self.persistenceLock.pendingRebases[transactionKey] {
            return pending.previousRecords
        }
        return try loadUnlocked()
    }

    private func requireNoPendingRebaseUnlocked() throws {
        guard Self.persistenceLock.pendingRebases[transactionKey] == nil else {
            throw SecurityScopedBookmarkStoreError.transactionInProgress
        }
    }

    private func commitPreparedRebase(_ id: UUID) {
        Self.withPersistenceLock {
            guard Self.persistenceLock.pendingRebases[transactionKey]?.id == id else {
                return
            }
            Self.persistenceLock.pendingRebases[transactionKey] = nil
            if let snapshot = try? loadSnapshotUnlocked(),
               snapshot.pendingRebase?.id == id {
                try? writeSnapshot(snapshot.records)
            }
        }
    }

    private func abortPreparedRebase(_ id: UUID) throws {
        try Self.withPersistenceLock {
            guard let pending = Self.persistenceLock.pendingRebases[transactionKey],
                  pending.id == id else { return }
            try writeSnapshot(pending.previousRecords)
            Self.persistenceLock.pendingRebases[transactionKey] = nil
        }
    }

    private func loadUnlocked() throws -> [SecurityScopedBookmarkRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > limits.maximumSerializedBytes {
                try quarantineUnlocked()
                return []
            }
            guard let bounded = try readBoundedData() else {
                try quarantineUnlocked()
                return []
            }
            data = bounded
        } catch {
            throw error
        }

        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            try quarantineUnlocked()
            return []
        }
        guard snapshot.formatVersion == Self.formatVersion else {
            try quarantineUnlocked()
            return []
        }
        let candidate = canonicalRecords(snapshot.records)
        guard let pending = snapshot.pendingRebase else { return candidate }
        let shouldCommit = !pending.moves.isEmpty && pending.moves.allSatisfy { move in
            !itemExists(atPath: move.sourcePath)
                && itemExists(atPath: move.destinationPath)
        }
        let recovered = shouldCommit
            ? candidate : canonicalRecords(pending.previousRecords)
        try writeSnapshot(recovered)
        return recovered
    }

    private func canonicalRecords(
        _ input: [SecurityScopedBookmarkRecord]
    ) -> [SecurityScopedBookmarkRecord] {
        let valid = input.compactMap { source -> SecurityScopedBookmarkRecord? in
            guard let path = normalizedPath(URL(fileURLWithPath: source.path)),
                  !source.bookmarkData.isEmpty,
                  source.bookmarkData.count <= limits.maximumBookmarkBytes,
                  source.updatedAt.isFinite else { return nil }
            var record = source
            record.path = path
            record.aliases = canonicalAliases(source.aliases, excluding: path)
            return record
        }.enumerated().sorted { left, right in
            if left.element.updatedAt != right.element.updatedAt {
                return left.element.updatedAt > right.element.updatedAt
            }
            return left.offset < right.offset
        }.map(\.element)

        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()
        var total = 0
        var result: [SecurityScopedBookmarkRecord] = []
        for record in valid {
            let key = record.kind.rawValue + "\u{0}" + record.path
            guard seenIDs.insert(record.id).inserted, seenPaths.insert(key).inserted,
                  result.count < limits.maximumRecords,
                  total + record.bookmarkData.count <= limits.maximumTotalBookmarkBytes
            else { continue }
            result.append(record)
            total += record.bookmarkData.count
        }
        return result
    }

    private func writeBounded(
        _ input: [SecurityScopedBookmarkRecord],
        retaining requiredID: UUID
    ) throws {
        try writeBounded(input, retaining: [requiredID])
    }

    private func writeBounded(
        _ input: [SecurityScopedBookmarkRecord],
        retaining requiredIDs: Set<UUID>
    ) throws {
        try writeSnapshot(try boundedRecords(input, retaining: requiredIDs))
    }

    private func boundedRecords(
        _ input: [SecurityScopedBookmarkRecord],
        retaining requiredIDs: Set<UUID>,
        pendingRebase: PersistentSecurityScopedBookmarkRebase? = nil
    ) throws -> [SecurityScopedBookmarkRecord] {
        var records = canonicalRecords(input)
        guard requiredIDs.isSubset(of: Set(records.map(\.id))) else {
            throw SecurityScopedBookmarkStoreError.persistenceCapacityExceeded
        }
        while true {
            let data = try encodedSnapshot(records, pendingRebase: pendingRebase)
            if data.count <= limits.maximumSerializedBytes {
                return records
            }
            guard let removable = records.lastIndex(where: {
                !requiredIDs.contains($0.id)
            }) else {
                throw SecurityScopedBookmarkStoreError.serializedDataTooLarge(
                    actualBytes: data.count, maximumBytes: limits.maximumSerializedBytes
                )
            }
            records.remove(at: removable)
        }
    }

    private func writeSnapshot(
        _ input: [SecurityScopedBookmarkRecord],
        pendingRebase: PersistentSecurityScopedBookmarkRebase? = nil
    ) throws {
        let records = canonicalRecords(input)
        let data = try encodedSnapshot(records, pendingRebase: pendingRebase)
        guard data.count <= limits.maximumSerializedBytes else {
            throw SecurityScopedBookmarkStoreError.serializedDataTooLarge(
                actualBytes: data.count, maximumBytes: limits.maximumSerializedBytes
            )
        }
        try write(data)
    }

    private func encodedSnapshot(
        _ records: [SecurityScopedBookmarkRecord],
        pendingRebase: PersistentSecurityScopedBookmarkRebase? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Snapshot(
            formatVersion: Self.formatVersion, records: records,
            pendingRebase: pendingRebase
        ))
    }

    private func loadSnapshotUnlocked() throws -> Snapshot {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func itemExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func write(_ data: Data) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func readBoundedData() throws -> Data? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= limits.maximumSerializedBytes {
            let remaining = limits.maximumSerializedBytes - data.count
            let count = remaining == 0 ? 1 : min(64 * 1_024, remaining)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            if data.count > limits.maximumSerializedBytes { return nil }
        }
        return nil
    }

    private func quarantineUnlocked() throws {
        let suffix = "corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        try fileManager.moveItem(
            at: fileURL, to: fileURL.appendingPathExtension(suffix)
        )
    }

    private func validateBookmarkSize(_ data: Data) throws {
        guard !data.isEmpty, data.count <= limits.maximumBookmarkBytes else {
            throw SecurityScopedBookmarkStoreError.bookmarkTooLarge(
                actualBytes: data.count, maximumBytes: limits.maximumBookmarkBytes
            )
        }
    }

    private func canonicalAliases(_ aliases: [String], excluding path: String) -> [String] {
        var seen = Set([path])
        var result: [String] = []
        for alias in aliases {
            guard let normalized = normalizedPath(URL(fileURLWithPath: alias)),
                  seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == limits.maximumAliasesPerRecord { break }
        }
        return result
    }

    private func normalizedPath(_ url: URL) -> String? {
        guard url.isFileURL, url.host == nil || url.host?.isEmpty == true else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.contains("\0"),
              (path as NSString).isAbsolutePath else { return nil }
        return path
    }

    private func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
    }

    private static func contains(_ directory: String, _ candidate: String) -> Bool {
        let root = URL(fileURLWithPath: directory).pathComponents
        let child = URL(fileURLWithPath: candidate).pathComponents
        guard child.count > root.count else { return false }
        return zip(root, child).allSatisfy { $0.0 == $0.1 }
    }

    private static func withPersistenceLock<T>(_ body: () throws -> T) rethrows -> T {
        let lock = persistenceLock.value
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

struct ResolvedSecurityScopedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkProviding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

#if os(macOS)
struct SystemSecurityScopedBookmarkProvider: SecurityScopedBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedSecurityScopedBookmark(
            url: url.standardizedFileURL, isStale: stale
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
#else
struct SystemSecurityScopedBookmarkProvider: SecurityScopedBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        throw CocoaError(.featureUnsupported)
    }

    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}
#endif

enum SecurityScopedAccessError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL(String)
    case missingBookmark(String)
    case resolvedURLInvalid(String)
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            "The selected item is not an absolute local URL: \(value)"
        case let .missingBookmark(path):
            "Access to \(path) must be authorised again."
        case let .resolvedURLInvalid(path):
            "The saved access grant resolved outside its expected local path: \(path)"
        case let .accessDenied(path):
            "macOS did not grant security-scoped access to \(path)."
        }
    }
}

/// A balanced capability token. Keeping this object alive keeps the underlying
/// security scope active; explicit invalidation and deinitialisation both release it.
final class SecurityScopedResourceLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?

    init(url: URL, release: (() -> Void)? = nil) {
        self.url = url
        releaseAction = release
    }

    func invalidate() {
        let action: (() -> Void)?
        lock.lock()
        action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit { invalidate() }
}

/// Resolves persistent grants and balances `startAccessing`/`stopAccessing`
/// across all native windows. A directory grant can satisfy descendant file
/// access, which preserves the existing workspace capability semantics.
final class SecurityScopedAccessController: @unchecked Sendable {
    static let shared = SecurityScopedAccessController()

    private struct ActiveScope {
        var url: URL
        var referenceCount: Int
        var didStart: Bool
    }

    private let store: SecurityScopedBookmarkStore
    private let provider: any SecurityScopedBookmarkProviding
    private let requiresSecurityScope: @Sendable () -> Bool
    private let lock = NSLock()
    private var activeScopes: [String: ActiveScope] = [:]

    init(
        store: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        provider: any SecurityScopedBookmarkProviding = SystemSecurityScopedBookmarkProvider(),
        requiresSecurityScope: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        }
    ) {
        self.store = store
        self.provider = provider
        self.requiresSecurityScope = requiresSecurityScope
    }

    func accessUserSelectedURL(
        _ selectedURL: URL,
        kind: SecurityScopedBookmarkKind
    ) throws -> SecurityScopedResourceLease {
        let lease = try beginUserSelectedAccess(selectedURL)
        do {
            try persistUserSelectedURL(lease.url, kind: kind)
            return lease
        } catch {
            lease.invalidate()
            throw error
        }
    }

    /// Begins a Powerbox-provided scope without requiring the destination to
    /// exist yet. Save panels use this before the atomic write, then persist a
    /// bookmark only after the file has been created successfully.
    func beginUserSelectedAccess(
        _ selectedURL: URL
    ) throws -> SecurityScopedResourceLease {
        let url = try requireLocalURL(selectedURL)
        return try beginScope(scopeURL: url, effectiveURL: url)
    }

    func persistUserSelectedURL(
        _ url: URL, kind: SecurityScopedBookmarkKind
    ) throws {
        let localURL = try requireLocalURL(url)
        let data = try provider.makeBookmark(for: localURL)
        let preservesDistinctTarget = kind == .file
            && localURL.resolvingSymlinksInPath().standardizedFileURL.path
                != localURL.standardizedFileURL.path
        _ = try store.record(
            data, for: localURL, kind: kind,
            preservingDirectoryCoveredFile: preservesDistinctTarget
        )
    }

    func prepareExactFileAccessRebases(
        _ moves: [SecurityScopedFileAccessMove]
    ) throws -> PreparedSecurityScopedBookmarkRebase? {
        try store.prepareExactFileRebases(moves)
    }

    func accessPersistedURL(
        _ requestedURL: URL,
        kind: SecurityScopedBookmarkKind,
        allowingDirectoryAncestor: Bool = false
    ) throws -> SecurityScopedResourceLease {
        let requested = try requireLocalURL(requestedURL)
        guard let match = store.match(
            for: requested, kind: kind,
            allowingDirectoryAncestor: allowingDirectoryAncestor
        ) else {
            if requiresSecurityScope() {
                throw SecurityScopedAccessError.missingBookmark(requested.path)
            }
            return SecurityScopedResourceLease(url: requested)
        }

        let resolved = try provider.resolveBookmark(match.record.bookmarkData)
        let scopeURL = try requireLocalURL(resolved.url)
        if match.record.kind == .file, kind == .file {
            let requestedTarget = requested.resolvingSymlinksInPath().standardizedFileURL
            let scopeTarget = scopeURL.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: requestedTarget.path),
                  requestedTarget.path == scopeTarget.path else {
                throw SecurityScopedAccessError.resolvedURLInvalid(requested.path)
            }
        }
        let effectiveURL: URL
        if match.record.kind == .directory, kind == .file {
            effectiveURL = try descendantURL(
                requested: requested, matchedDirectoryPath: match.matchedPath,
                resolvedDirectory: scopeURL
            )
        } else {
            effectiveURL = scopeURL
        }

        let lease = try beginScope(scopeURL: scopeURL, effectiveURL: effectiveURL)
        do {
            if resolved.isStale {
                let refreshedData = try provider.makeBookmark(for: scopeURL)
                _ = try store.refresh(
                    match, bookmarkData: refreshedData, resolvedURL: scopeURL
                )
            } else if scopeURL.path != match.record.path {
                _ = try store.refresh(
                    match, bookmarkData: match.record.bookmarkData,
                    resolvedURL: scopeURL
                )
            }
            return lease
        } catch {
            lease.invalidate()
            throw error
        }
    }

    private func beginScope(
        scopeURL: URL, effectiveURL: URL
    ) throws -> SecurityScopedResourceLease {
        let key = scopeURL.standardizedFileURL.path
        lock.lock()
        if var active = activeScopes[key] {
            active.referenceCount += 1
            activeScopes[key] = active
            lock.unlock()
            return lease(effectiveURL: effectiveURL, scopeKey: key)
        }
        let didStart = provider.startAccessing(scopeURL)
        if !didStart, requiresSecurityScope() {
            lock.unlock()
            throw SecurityScopedAccessError.accessDenied(scopeURL.path)
        }
        activeScopes[key] = ActiveScope(
            url: scopeURL, referenceCount: 1, didStart: didStart
        )
        lock.unlock()
        return lease(effectiveURL: effectiveURL, scopeKey: key)
    }

    private func lease(
        effectiveURL: URL, scopeKey: String
    ) -> SecurityScopedResourceLease {
        SecurityScopedResourceLease(url: effectiveURL) { [weak self] in
            self?.releaseScope(scopeKey)
        }
    }

    private func releaseScope(_ key: String) {
        var stopURL: URL?
        lock.lock()
        if var active = activeScopes[key] {
            active.referenceCount -= 1
            if active.referenceCount == 0 {
                activeScopes[key] = nil
                if active.didStart { stopURL = active.url }
            } else {
                activeScopes[key] = active
            }
        }
        lock.unlock()
        if let stopURL { provider.stopAccessing(stopURL) }
    }

    private func requireLocalURL(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
              standardized.host == nil || standardized.host?.isEmpty == true,
              standardized.path.hasPrefix("/"),
              !standardized.path.contains("\0") else {
            throw SecurityScopedAccessError.invalidURL(url.absoluteString)
        }
        return standardized
    }

    private func descendantURL(
        requested: URL,
        matchedDirectoryPath: String,
        resolvedDirectory: URL
    ) throws -> URL {
        let rootComponents = URL(fileURLWithPath: matchedDirectoryPath).pathComponents
        let requestedComponents = requested.pathComponents
        guard requestedComponents.count > rootComponents.count,
              zip(rootComponents, requestedComponents).allSatisfy({ $0.0 == $0.1 }) else {
            throw SecurityScopedAccessError.resolvedURLInvalid(requested.path)
        }
        return requestedComponents.dropFirst(rootComponents.count).reduce(
            resolvedDirectory
        ) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
    }
}
