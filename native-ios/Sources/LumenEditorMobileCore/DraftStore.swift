import Foundation

public struct MobileDraftSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public var displayName: String
    public var content: String
    public var encoding: MobileTextEncoding
    public var lineEnding: MobileLineEnding
    public var bookmarkData: Data?
    public var sourceRevision: String?
    public var isDirty: Bool
    public var requiresEncodingConfirmation: Bool
    public var selectionLocation: Int
    public var selectionLength: Int
    public var checkpointGeneration: UInt64?
    public var encodingRecoveryData: Data?
    public var checkpointedAt: Date

    public init(
        id: UUID,
        displayName: String,
        content: String,
        encoding: MobileTextEncoding,
        lineEnding: MobileLineEnding,
        bookmarkData: Data?,
        sourceRevision: String?,
        isDirty: Bool,
        requiresEncodingConfirmation: Bool = false,
        selectionLocation: Int = 0,
        selectionLength: Int = 0,
        checkpointGeneration: UInt64? = nil,
        encodingRecoveryData: Data? = nil,
        checkpointedAt: Date = Date()
    ) {
        schemaVersion = 1
        self.id = id
        self.displayName = displayName
        self.content = content
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.bookmarkData = bookmarkData
        self.sourceRevision = sourceRevision
        self.isDirty = isDirty
        self.requiresEncodingConfirmation = requiresEncodingConfirmation
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.checkpointGeneration = checkpointGeneration
        self.encodingRecoveryData = encodingRecoveryData
        self.checkpointedAt = checkpointedAt
    }
}

public enum MobileDraftStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidSchema(Int)
    case invalidSelection
    case invalidEncodingRecoveryData

    public var errorDescription: String? {
        switch self {
        case let .invalidSchema(version):
            String(
                format: NSLocalizedString("error_unsupported_draft_schema", comment: ""),
                version
            )
        case .invalidSelection:
            NSLocalizedString("error_invalid_draft_selection", comment: "")
        case .invalidEncodingRecoveryData:
            NSLocalizedString("error_invalid_encoding_recovery_data", comment: "")
        }
    }
}

public struct MobileDraftRestoreReport: Equatable, Sendable {
    public let snapshots: [MobileDraftSnapshot]
    public let unreadableFileCount: Int
    public let deferredFileCount: Int

    public init(
        snapshots: [MobileDraftSnapshot],
        unreadableFileCount: Int,
        deferredFileCount: Int = 0
    ) {
        self.snapshots = snapshots
        self.unreadableFileCount = unreadableFileCount
        self.deferredFileCount = deferredFileCount
    }
}

/// Durable app-private recovery. This never substitutes for writing the provider file.
public actor MobileDraftStore {
    public static let maximumDraftByteCount = 128 * 1_024 * 1_024
    public static let maximumEncodingRecoveryByteCount = 20 * 1_024 * 1_024
    public static let maximumRestoredCount = MobileWorkspaceCapacity.maximumDocumentCount
    public static let maximumRestoredMemoryByteCount =
        MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
    private let directory: URL
    private let fileManager: FileManager
    private let restoredCountLimit: Int
    private let restoredMemoryByteLimit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var removedIDs: Set<UUID> = []

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        maximumRestoredCount: Int = MobileDraftStore.maximumRestoredCount,
        maximumRestoredMemoryByteCount: Int = MobileDraftStore.maximumRestoredMemoryByteCount
    ) {
        self.directory = directory
        self.fileManager = fileManager
        restoredCountLimit = max(0, maximumRestoredCount)
        restoredMemoryByteLimit = max(0, maximumRestoredMemoryByteCount)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public static func applicationStore(fileManager: FileManager = .default) -> MobileDraftStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MobileDraftStore(
            directory: root.appendingPathComponent("RecoveryDrafts", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func checkpoint(_ snapshot: MobileDraftSnapshot) throws {
        guard !removedIDs.contains(snapshot.id) else { return }
        try validate(snapshot)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumDraftByteCount else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let destination = fileURL(for: snapshot.id)
        if let currentData = try? readBoundedData(
               at: destination, maximumByteCount: Self.maximumDraftByteCount
           ),
           let current = try? decoder.decode(MobileDraftSnapshot.self, from: currentData),
           isNewer(current, than: snapshot) {
            return
        }
        try data.write(to: destination, options: protectedAtomicWriteOptions)
    }

    public func restoreAll() throws -> [MobileDraftSnapshot] {
        try restoreReport().snapshots
    }

    /// Invalid recovery files are deliberately retained for support/manual
    /// recovery. Callers receive a count so corruption is never silent.
    public func restoreReport() throws -> MobileDraftRestoreReport {
        guard fileManager.fileExists(atPath: directory.path) else {
            return MobileDraftRestoreReport(snapshots: [], unreadableFileCount: 0)
        }
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var unreadableFileCount = 0
        let candidates = urls.compactMap { url -> RecoveryCandidate? in
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let byteCount = values.fileSize, byteCount >= 0 else {
                    unreadableFileCount += 1
                    return nil
                }
                return RecoveryCandidate(
                    url: url, serializedByteCount: byteCount,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            } catch {
                unreadableFileCount += 1
                return nil
            }
        }.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        var snapshots: [MobileDraftSnapshot] = []
        var deferredFileCount = 0
        var estimatedMemoryByteCount = 0
        for candidate in candidates {
            guard snapshots.count < restoredCountLimit else {
                deferredFileCount += 1
                continue
            }
            let remainingMemoryByteCount = max(
                0, restoredMemoryByteLimit - estimatedMemoryByteCount
            )
            let serializedReadLimit = maximumRestoreCandidateSerializedByteCount(
                remainingEstimatedByteCount: remainingMemoryByteCount
            )
            guard candidate.serializedByteCount <= serializedReadLimit else {
                deferredFileCount += 1
                continue
            }
            let snapshot: MobileDraftSnapshot
            let serializedByteCount: Int
            do {
                let data = try readBoundedData(
                    at: candidate.url, maximumByteCount: serializedReadLimit
                )
                serializedByteCount = data.count
                snapshot = try decoder.decode(MobileDraftSnapshot.self, from: data)
                try validate(snapshot)
                guard candidate.url.deletingPathExtension().lastPathComponent
                        == snapshot.id.uuidString.lowercased() else {
                    throw MobileDraftStoreError.invalidSchema(snapshot.schemaVersion)
                }
            } catch let error as CocoaError where error.code == .fileReadTooLarge {
                deferredFileCount += 1
                continue
            } catch {
                unreadableFileCount += 1
                continue
            }
            let candidateMemoryByteCount = estimatedMemoryBytes(for: snapshot)
            let transientCandidateByteCount = addingWithoutOverflow(
                serializedByteCount, candidateMemoryByteCount
            )
            guard transientCandidateByteCount <= remainingMemoryByteCount else {
                deferredFileCount += 1
                continue
            }
            snapshots.append(snapshot)
            estimatedMemoryByteCount = addingWithoutOverflow(
                estimatedMemoryByteCount, candidateMemoryByteCount
            )
        }
        snapshots.sort { lhs, rhs in
            if lhs.checkpointedAt != rhs.checkpointedAt {
                return lhs.checkpointedAt > rhs.checkpointedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return MobileDraftRestoreReport(
            snapshots: snapshots,
            unreadableFileCount: unreadableFileCount,
            deferredFileCount: deferredFileCount
        )
    }

    public func remove(id: UUID) throws {
        removedIDs.insert(id)
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // The document remains open when deletion fails, so future edits
            // must still be checkpointable if the user retries later.
            removedIDs.remove(id)
            throw error
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func readBoundedData(at url: URL, maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 1_048_576))
        while true {
            let remaining = maximumByteCount - data.count
            let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
            if chunk.isEmpty { return data }
            guard chunk.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
    }

    private func validate(_ snapshot: MobileDraftSnapshot) throws {
        guard snapshot.schemaVersion == 1 else {
            throw MobileDraftStoreError.invalidSchema(snapshot.schemaVersion)
        }
        let length = snapshot.content.utf16.count
        guard snapshot.selectionLocation >= 0, snapshot.selectionLength >= 0,
              snapshot.selectionLocation <= length,
              snapshot.selectionLength <= length - snapshot.selectionLocation else {
            throw MobileDraftStoreError.invalidSelection
        }
        guard (snapshot.encodingRecoveryData?.count ?? 0)
                <= Self.maximumEncodingRecoveryByteCount else {
            throw CocoaError(.fileReadTooLarge)
        }
        guard snapshot.requiresEncodingConfirmation
                || snapshot.encodingRecoveryData == nil else {
            throw MobileDraftStoreError.invalidEncodingRecoveryData
        }
    }

    private func isNewer(
        _ current: MobileDraftSnapshot,
        than candidate: MobileDraftSnapshot
    ) -> Bool {
        let currentGeneration = current.checkpointGeneration ?? 0
        let candidateGeneration = candidate.checkpointGeneration ?? 0
        if currentGeneration != candidateGeneration {
            return currentGeneration > candidateGeneration
        }
        return current.checkpointedAt >= candidate.checkpointedAt
    }

    /// Cap a serialized candidate before decoding. The exact post-decode guard
    /// below then accounts for both serialized bytes and estimated retained
    /// UTF-16/Data payload. JSONDecoder has additional framework overhead, so
    /// real-device memory-pressure testing remains a release gate.
    private func maximumRestoreCandidateSerializedByteCount(
        remainingEstimatedByteCount: Int
    ) -> Int {
        let serializedBudget = max(0, remainingEstimatedByteCount / 3)
        return min(Self.maximumDraftByteCount, serializedBudget)
    }

    private func estimatedMemoryBytes(for snapshot: MobileDraftSnapshot) -> Int {
        MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: snapshot.content.utf16.count,
            encodingRecoveryByteCount: snapshot.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: snapshot.bookmarkData?.count ?? 0
        )
    }

    private func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    private var protectedAtomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private struct RecoveryCandidate {
        let url: URL
        let serializedByteCount: Int
        let modifiedAt: Date
    }
}
