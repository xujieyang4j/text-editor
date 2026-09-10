import Foundation
import Darwin

private let workspaceMutationRecoveryNamePrefix = ".lumen-replace-recovery-"

/// One user-authorised folder in a multi-root workspace.
public struct WorkspaceRoot: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let rawValue: UUID

        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    public let url: URL
    public let displayName: String
    public let isPrimary: Bool

    public init(id: ID, url: URL, displayName: String, isPrimary: Bool) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.isPrimary = isPrimary
    }
}

/// A single, not-yet-expanded item in a workspace directory.
public struct WorkspaceEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case file
        case directory
        case symbolicLink
        case other
    }

    public var id: URL { url }
    public let name: String
    public let url: URL
    public let kind: Kind

    public init(name: String, url: URL, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }

    public var isDirectory: Bool { kind == .directory }
}

/// A bounded, immediate directory listing. Children are deliberately absent:
/// callers request them only when a directory is expanded.
public struct WorkspaceDirectoryListing: Equatable, Sendable {
    public let entries: [WorkspaceEntry]
    public let isTruncated: Bool

    public init(entries: [WorkspaceEntry], isTruncated: Bool) {
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

/// The result of a bounded recursive file enumeration.
public struct WorkspaceFileListing: Equatable, Sendable {
    public let files: [URL]
    public let isTruncated: Bool

    public init(files: [URL], isTruncated: Bool) {
        self.files = files
        self.isTruncated = isTruncated
    }
}

/// Filtering applied after the built-in noisy-name policy. Glob patterns use
/// the same compact subset as the Electron file tree: `*`, `**`, and `?`.
public struct WorkspaceExclusionPolicy: Equatable, Sendable {
    public static let `default` = WorkspaceExclusionPolicy()

    public var hiddenNames: Set<String>
    public var globPatterns: [String]
    public var caseInsensitive: Bool

    public init(
        hiddenNames: Set<String> = WorkspaceService.builtInIgnoredNames,
        globPatterns: [String] = [],
        caseInsensitive: Bool = true
    ) {
        self.hiddenNames = hiddenNames
        self.globPatterns = globPatterns
        self.caseInsensitive = caseInsensitive
    }

    fileprivate func excludes(name: String, relativePath: String, isDirectory: Bool) -> Bool {
        if name.hasPrefix(workspaceMutationRecoveryNamePrefix) { return true }
        if hiddenNames.contains(name) { return true }
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        return globPatterns.contains { pattern in
            Self.matches(path, pattern: pattern, isDirectory: isDirectory, caseInsensitive: caseInsensitive)
        }
    }

    private static func matches(
        _ path: String,
        pattern rawPattern: String,
        isDirectory: Bool,
        caseInsensitive: Bool
    ) -> Bool {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if pattern.hasPrefix("./") { pattern.removeFirst(2) }
        guard !pattern.isEmpty else { return false }

        let characters = Array(pattern)
        var index = 0
        var source = "^"
        let regexSpecial = Set<Character>(".+^${}()|[]\\")
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        source += "(?:.*/)?"
                        index += 3
                    } else {
                        source += ".*"
                        index += 2
                    }
                } else {
                    source += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                source += "[^/]"
                index += 1
            } else {
                if regexSpecial.contains(character) { source.append("\\") }
                source.append(character)
                index += 1
            }
        }
        source += "$"

        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: source, options: options) else {
            return false
        }
        func matchesExactly(_ candidate: String) -> Bool {
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            return expression.firstMatch(in: candidate, range: range) != nil
        }
        return matchesExactly(path) || (isDirectory && matchesExactly(path + "/"))
    }
}

public enum WorkspaceMoveRecoveryOutcome: Equatable, Sendable {
    case committedAtTarget
    case indeterminate
}

/// A root that remains registered after atomically replacing the workspace.
/// `retainingOpenFiles` preserves direct access for documents which are no
/// longer covered by the replacement root.
public struct WorkspaceRootReplacementRemoval: Equatable, Sendable {
    public let id: WorkspaceRoot.ID
    public let retainingOpenFiles: [URL]

    public init(
        id: WorkspaceRoot.ID, retainingOpenFiles: [URL] = []
    ) {
        self.id = id
        self.retainingOpenFiles = retainingOpenFiles
    }
}

public struct WorkspaceRootReplacementTransaction: Sendable {
    fileprivate let id: UUID
    public let replacement: WorkspaceRoot
}

enum WorkspaceMutationLeaseError: Error, Equatable, Sendable {
    case fileTooLarge(URL)
    case recoveryCapacityExceeded(URL)
    case recoveryFailed(URL)
}

/// A synchronous release handle for a service-owned mutation lease. The
/// release path deliberately does not hop back to the `WorkspaceService`
/// actor: cancellation and owner teardown can therefore close the lease in a
/// plain `defer`, before any root-revoking operation is allowed to continue.
final class WorkspaceMutationLease: @unchecked Sendable {
    /// A failed commit can retain the complete old or replacement contents.
    /// Bound every hidden artifact before a batch starts and again immediately
    /// before creating each fresh staging file.
    private static let maximumRecoveryArtifactsPerDirectory = 64

    fileprivate struct PinnedIdentity: Equatable, Hashable {
        let device: UInt64
        let inode: UInt64
    }

    fileprivate final class PinnedTarget {
        let directoryDescriptor: Int32
        let name: String
        let logicalURL: URL
        let resolvedURL: URL
        let parentResolvedURL: URL
        let parentIdentity: PinnedIdentity
        let rootLogicalURL: URL
        let rootResolvedURL: URL
        let rootIdentity: PinnedIdentity
        private var identity: PinnedIdentity
        private let lock = NSLock()

        init(
            directoryDescriptor: Int32, name: String, logicalURL: URL,
            resolvedURL: URL, parentResolvedURL: URL,
            parentIdentity: PinnedIdentity, rootLogicalURL: URL,
            rootResolvedURL: URL, rootIdentity: PinnedIdentity,
            identity: PinnedIdentity
        ) {
            self.directoryDescriptor = directoryDescriptor
            self.name = name
            self.logicalURL = logicalURL
            self.resolvedURL = resolvedURL
            self.parentResolvedURL = parentResolvedURL
            self.parentIdentity = parentIdentity
            self.rootLogicalURL = rootLogicalURL
            self.rootResolvedURL = rootResolvedURL
            self.rootIdentity = rootIdentity
            self.identity = identity
        }

        deinit { _ = Darwin.close(directoryDescriptor) }

        func currentIdentity() -> PinnedIdentity {
            lock.lock()
            defer { lock.unlock() }
            return identity
        }

        func replaceIdentity(with identity: PinnedIdentity) {
            lock.lock()
            self.identity = identity
            lock.unlock()
        }
    }

    private final class RecoverySlot {
        private(set) var descriptor: Int32
        let name: String
        let identity: PinnedIdentity

        init(descriptor: Int32, name: String, identity: PinnedIdentity) {
            self.descriptor = descriptor
            self.name = name
            self.identity = identity
        }

        func closeDescriptor() {
            guard descriptor >= 0 else { return }
            let openDescriptor = descriptor
            descriptor = -1
            _ = Darwin.close(openDescriptor)
        }

        deinit { closeDescriptor() }
    }

    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?
    private var targets: [PinnedTarget]
    private let afterSwapBeforeValidation: (
        @Sendable (_ target: URL, _ swappedOut: URL) throws -> Void
    )?
    private let beforeDirectorySync: (@Sendable (_ directory: URL) throws -> Void)?

    fileprivate init(
        targets: [PinnedTarget],
        afterSwapBeforeValidation: (
            @Sendable (_ target: URL, _ swappedOut: URL) throws -> Void
        )?,
        beforeDirectorySync: (@Sendable (_ directory: URL) throws -> Void)?,
        releaseAction: @escaping @Sendable () -> Void
    ) {
        self.targets = targets
        self.afterSwapBeforeValidation = afterSwapBeforeValidation
        self.beforeDirectorySync = beforeDirectorySync
        self.releaseAction = releaseAction
    }

    func preflightRecoveryCapacity(for targetIndices: [Int]) throws {
        var representatives: [PinnedIdentity: PinnedTarget] = [:]
        for index in targetIndices {
            let target = try retainedTarget(at: index)
            representatives[target.parentIdentity] = target
        }
        for target in representatives.values {
            let artifactCount = try Self.recoveryArtifactCount(in: target)
            // A forward failure can retain one full slot and the first failed
            // compensation can retain one more. Compensation stops there.
            guard artifactCount + 2
                    <= Self.maximumRecoveryArtifactsPerDirectory else {
                throw WorkspaceMutationLeaseError.recoveryCapacityExceeded(
                    target.logicalURL
                )
            }
        }
    }

    func readData(at index: Int, maximumByteCount: Int64) throws -> Data {
        let target = try retainedTarget(at: index)
        return try Self.readPinnedTarget(
            target, maximumByteCount: maximumByteCount
        ).data
    }

    @discardableResult
    func write(
        _ data: Data, at index: Int, expectedRevision: String,
        maximumByteCount: Int64
    ) throws -> FileWriteResult {
        let target = try retainedTarget(at: index)
        let nextRevision = TextFileCodec.revision(of: data)
        let first = try Self.readPinnedTarget(
            target, maximumByteCount: maximumByteCount
        )
        let currentRevision = TextFileCodec.revision(of: first.data)
        guard currentRevision == expectedRevision else {
            if currentRevision == nextRevision {
                return FileWriteResult(revision: nextRevision, wroteBytes: false)
            }
            throw FileWriteFailure.conflict(actualRevision: currentRevision)
        }
        if currentRevision == nextRevision {
            return FileWriteResult(revision: nextRevision, wroteBytes: false)
        }
        guard first.linkCount <= 1 else { throw FileWriteFailure.hardLinked }

        let slot = try Self.createRecoverySlot(in: target)
        do {
            try Self.prepareRecoverySlot(
                slot, with: data, permissions: first.permissions
            )

            // Re-open both names through the pinned parent immediately before
            // the atomic exchange. Post-swap validation handles a replacement
            // by another process in the remaining path/name race.
            let latest = try Self.readPinnedTarget(
                target, maximumByteCount: maximumByteCount
            )
            guard latest.linkCount <= 1 else { throw FileWriteFailure.hardLinked }
            let latestRevision = TextFileCodec.revision(of: latest.data)
            guard latestRevision == expectedRevision else {
                if latestRevision == nextRevision {
                    do { try removeUnswappedRecoverySlot(slot, in: target) } catch {
                        throw WorkspaceMutationLeaseError.recoveryFailed(
                            target.logicalURL
                        )
                    }
                    return FileWriteResult(revision: nextRevision, wroteBytes: false)
                }
                throw FileWriteFailure.conflict(actualRevision: latestRevision)
            }
            let staged = try Self.readEntry(
                named: slot.name, in: target.directoryDescriptor,
                logicalURL: target.logicalURL, expectedIdentity: slot.identity,
                maximumByteCount: maximumByteCount
            )
            guard staged.linkCount <= 1,
                  TextFileCodec.revision(of: staged.data) == nextRevision else {
                throw FileWriteFailure.conflict(
                    actualRevision: TextFileCodec.revision(of: staged.data)
                )
            }
        } catch {
            do { try removeUnswappedRecoverySlot(slot, in: target) } catch {
                throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
            }
            throw error
        }

        let swapFlags = UInt32(RENAME_SWAP | RENAME_SECLUDE)
        let swapResult = target.name.withCString { source in
            slot.name.withCString { destination in
                Darwin.renameatx_np(
                    target.directoryDescriptor, source,
                    target.directoryDescriptor, destination, swapFlags
                )
            }
        }
        guard swapResult == 0 else {
            let swapErrno = errno
            do { try removeUnswappedRecoverySlot(slot, in: target) } catch {
                throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
            }
            throw POSIXError(POSIXErrorCode(rawValue: swapErrno) ?? .EIO)
        }
        let swappedOutURL = target.parentResolvedURL.appendingPathComponent(
            slot.name, isDirectory: false
        )
        do {
            try afterSwapBeforeValidation?(target.logicalURL, swappedOutURL)
            try Self.validateAttachment(of: target)
            let installed = try Self.readEntry(
                named: target.name, in: target.directoryDescriptor,
                logicalURL: target.logicalURL, expectedIdentity: slot.identity,
                maximumByteCount: maximumByteCount
            )
            guard TextFileCodec.revision(of: installed.data) == nextRevision else {
                throw FileWriteFailure.conflict(
                    actualRevision: TextFileCodec.revision(of: installed.data)
                )
            }
            let swappedOut = try Self.readEntry(
                named: slot.name, in: target.directoryDescriptor,
                logicalURL: target.logicalURL, expectedIdentity: target.currentIdentity(),
                maximumByteCount: maximumByteCount
            )
            guard TextFileCodec.revision(of: swappedOut.data) == expectedRevision else {
                throw FileWriteFailure.conflict(
                    actualRevision: TextFileCodec.revision(of: swappedOut.data)
                )
            }
        } catch let validationError {
            // Swap back only while both names still designate the exact two
            // objects that this transaction exchanged. Otherwise an external
            // writer's new target could be moved aside and later unlinked.
            do {
                try Self.validateAttachment(of: target)
                let installed = try Self.readEntry(
                    named: target.name, in: target.directoryDescriptor,
                    logicalURL: target.logicalURL,
                    expectedIdentity: slot.identity,
                    maximumByteCount: maximumByteCount
                )
                guard TextFileCodec.revision(of: installed.data) == nextRevision else {
                    throw FileWriteFailure.conflict(
                        actualRevision: TextFileCodec.revision(of: installed.data)
                    )
                }
                let swappedOut = try Self.readEntry(
                    named: slot.name, in: target.directoryDescriptor,
                    logicalURL: target.logicalURL,
                    expectedIdentity: target.currentIdentity(),
                    maximumByteCount: maximumByteCount
                )
                guard TextFileCodec.revision(of: swappedOut.data) == expectedRevision else {
                    throw FileWriteFailure.conflict(
                        actualRevision: TextFileCodec.revision(of: swappedOut.data)
                    )
                }
            } catch {
                throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
            }

            let recoveryResult = slot.name.withCString { source in
                target.name.withCString { destination in
                    Darwin.renameatx_np(
                        target.directoryDescriptor, source,
                        target.directoryDescriptor, destination, swapFlags
                    )
                }
            }
            guard recoveryResult == 0 else {
                throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
            }
            do {
                try syncDirectory(for: target)
                try Self.validateAttachment(of: target)
                let restored = try Self.readEntry(
                    named: target.name, in: target.directoryDescriptor,
                    logicalURL: target.logicalURL,
                    expectedIdentity: target.currentIdentity(),
                    maximumByteCount: maximumByteCount
                )
                guard TextFileCodec.revision(of: restored.data) == expectedRevision else {
                    throw FileWriteFailure.conflict(
                        actualRevision: TextFileCodec.revision(of: restored.data)
                    )
                }
                let recoveredReplacement = try Self.readEntry(
                    named: slot.name, in: target.directoryDescriptor,
                    logicalURL: target.logicalURL,
                    expectedIdentity: slot.identity,
                    maximumByteCount: maximumByteCount
                )
                guard TextFileCodec.revision(of: recoveredReplacement.data) == nextRevision else {
                    throw FileWriteFailure.conflict(
                        actualRevision: TextFileCodec.revision(
                            of: recoveredReplacement.data
                        )
                    )
                }
                try removeSwappedOutEntry(
                    named: slot.name, expectedIdentity: slot.identity,
                    slot: slot, in: target
                )
            } catch {
                throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
            }
            throw validationError
        }

        do {
            // Persist the exchange while both complete versions are still
            // recoverable by name. Only then ask the kernel to seclude the old
            // inode into a fresh cleanup name and unlink that exact entry.
            try syncDirectory(for: target)
            try removeSwappedOutEntry(
                named: slot.name, expectedIdentity: target.currentIdentity(),
                slot: slot, in: target
            )
        } catch {
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }
        target.replaceIdentity(with: slot.identity)
        return FileWriteResult(revision: nextRevision, wroteBytes: true)
    }

    private func syncDirectory(for target: PinnedTarget) throws {
        try beforeDirectorySync?(target.parentResolvedURL)
        guard Darwin.fsync(target.directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func release() {
        let action: (@Sendable () -> Void)?
        let releasedTargets: [PinnedTarget]
        lock.lock()
        action = releaseAction
        releaseAction = nil
        releasedTargets = targets
        targets.removeAll()
        lock.unlock()
        _ = releasedTargets
        action?()
    }

    deinit { release() }

    private struct PinnedRead {
        let data: Data
        let permissions: mode_t
        let linkCount: UInt64
    }

    private func retainedTarget(at index: Int) throws -> PinnedTarget {
        lock.lock()
        defer { lock.unlock() }
        guard targets.indices.contains(index), releaseAction != nil else {
            throw WorkspaceServiceError.rootReplacementRollbackFailed
        }
        return targets[index]
    }

    private static func readPinnedTarget(
        _ target: PinnedTarget, maximumByteCount: Int64
    ) throws -> PinnedRead {
        try validateAttachment(of: target)
        guard target.logicalURL.standardizedFileURL.resolvingSymlinksInPath()
                .standardizedFileURL.path == target.resolvedURL.path else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                target.logicalURL
            )
        }
        return try readEntry(
            named: target.name, in: target.directoryDescriptor,
            logicalURL: target.logicalURL, expectedIdentity: target.currentIdentity(),
            maximumByteCount: maximumByteCount
        )
    }

    private static func validateAttachment(of target: PinnedTarget) throws {
        guard target.rootLogicalURL.standardizedFileURL.resolvingSymlinksInPath()
                .standardizedFileURL.path == target.rootResolvedURL.path,
              target.logicalURL.deletingLastPathComponent().standardizedFileURL
                .resolvingSymlinksInPath().standardizedFileURL.path
                == target.parentResolvedURL.path,
              pathIdentity(target.rootResolvedURL) == target.rootIdentity,
              pathIdentity(target.parentResolvedURL) == target.parentIdentity else {
            throw WorkspaceServiceError.rootChanged(target.rootLogicalURL)
        }
        var directoryStatus = stat()
        guard Darwin.fstat(target.directoryDescriptor, &directoryStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard PinnedIdentity(
            device: UInt64(directoryStatus.st_dev), inode: UInt64(directoryStatus.st_ino)
        ) == target.parentIdentity else {
            throw WorkspaceServiceError.rootChanged(target.rootLogicalURL)
        }
    }

    private static func readEntry(
        named name: String, in directoryDescriptor: Int32, logicalURL: URL,
        expectedIdentity: PinnedIdentity, maximumByteCount: Int64
    ) throws -> PinnedRead {
        let descriptor = try openEntry(
            named: name, in: directoryDescriptor, logicalURL: logicalURL,
            expectedIdentity: expectedIdentity
        )
        defer { _ = Darwin.close(descriptor) }
        return try readDescriptor(
            descriptor, logicalURL: logicalURL, expectedIdentity: expectedIdentity,
            maximumByteCount: maximumByteCount
        )
    }

    private static func openEntry(
        named name: String, in directoryDescriptor: Int32, logicalURL: URL,
        expectedIdentity: PinnedIdentity
    ) throws -> Int32 {
        var entryStatus = stat()
        let inspected = name.withCString { component in
            Darwin.fstatat(
                directoryDescriptor, component, &entryStatus, AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspected == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard entryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        guard PinnedIdentity(
            device: UInt64(entryStatus.st_dev), inode: UInt64(entryStatus.st_ino)
        ) == expectedIdentity else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        let descriptor = name.withCString { component in
            Darwin.openat(
                directoryDescriptor, component,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  PinnedIdentity(
                    device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
                  ) == expectedIdentity else {
                throw FileWriteFailure.conflict(actualRevision: nil)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openMutableEntry(
        named name: String, in directoryDescriptor: Int32, logicalURL: URL,
        expectedIdentity: PinnedIdentity
    ) throws -> Int32 {
        let readDescriptor = try openEntry(
            named: name, in: directoryDescriptor, logicalURL: logicalURL,
            expectedIdentity: expectedIdentity
        )
        defer { _ = Darwin.close(readDescriptor) }
        var status = stat()
        guard Darwin.fstat(readDescriptor, &status) == 0, status.st_nlink == 1 else {
            throw FileWriteFailure.hardLinked
        }
        guard Darwin.fchmod(readDescriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = name.withCString { component in
            Darwin.openat(
                directoryDescriptor, component, O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var mutableStatus = stat()
            guard Darwin.fstat(descriptor, &mutableStatus) == 0,
                  mutableStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  mutableStatus.st_nlink == 1,
                  PinnedIdentity(
                    device: UInt64(mutableStatus.st_dev),
                    inode: UInt64(mutableStatus.st_ino)
                  ) == expectedIdentity else {
                throw FileWriteFailure.conflict(actualRevision: nil)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func readDescriptor(
        _ descriptor: Int32, logicalURL: URL, expectedIdentity: PinnedIdentity,
        maximumByteCount: Int64
    ) throws -> PinnedRead {

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                logicalURL
            )
        }
        guard PinnedIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        ) == expectedIdentity else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        guard status.st_size >= 0, status.st_size <= maximumByteCount else {
            throw WorkspaceMutationLeaseError.fileTooLarge(logicalURL)
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Int64(data.count) + Int64(count) <= maximumByteCount else {
                throw WorkspaceMutationLeaseError.fileTooLarge(
                    logicalURL
                )
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return PinnedRead(
            data: data,
            permissions: status.st_mode & mode_t(0o7777),
            linkCount: UInt64(status.st_nlink)
        )
    }

    private static func prepareRecoverySlot(
        _ slot: RecoverySlot, with data: Data, permissions: mode_t
    ) throws {
        guard Darwin.fchmod(slot.descriptor, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try writeAll(data, to: slot.descriptor)
        guard Darwin.fsync(slot.descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeUnswappedRecoverySlot(
        _ slot: RecoverySlot, in target: PinnedTarget
    ) throws {
        try removeSwappedOutEntry(
            named: slot.name, expectedIdentity: slot.identity,
            slot: slot, in: target
        )
    }

    /// Move a verified artifact to a fresh private name with `RENAME_SECLUDE`
    /// before unlinking it. In particular, never truncate an inode which an
    /// external process could have opened after the exchange. The secluded
    /// rename atomically refuses an open, mapped, or multiply-linked source.
    private func removeSwappedOutEntry(
        named sourceName: String, expectedIdentity: PinnedIdentity,
        slot: RecoverySlot, in target: PinnedTarget
    ) throws {
        // On rollback the slot descriptor designates the source itself; on a
        // forward commit it designates the newly installed target. Close it in
        // either case before asking the kernel to prove the source is secluded.
        slot.closeDescriptor()

        guard Self.closedEntryIdentity(
            named: sourceName, in: target.directoryDescriptor
        ) == expectedIdentity else {
            try? syncDirectory(for: target)
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }

        // This rename is namespace-neutral, but recount at its allocation
        // boundary as well. It must never let our own cleanup operation grow an
        // already hostile or corrupt recovery namespace.
        let artifactCount = try Self.recoveryArtifactCount(in: target)
        guard artifactCount <= Self.maximumRecoveryArtifactsPerDirectory else {
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }
        let cleanupName = Self.freshRecoveryArtifactName(kind: "cleanup")
        let cleanupFlags = UInt32(RENAME_SECLUDE | RENAME_EXCL)
        let renameResult = sourceName.withCString { source in
            cleanupName.withCString { destination in
                Darwin.renameatx_np(
                    target.directoryDescriptor, source,
                    target.directoryDescriptor, destination, cleanupFlags
                )
            }
        }
        guard renameResult == 0 else {
            // The source name still contains the complete artifact. Make a
            // best effort to persist it when this was a pre-swap cleanup.
            try? syncDirectory(for: target)
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }

        // Detect a source-name replacement that raced the pre-rename identity
        // check. The cleanup name is intentionally unpredictable; the only
        // remaining name-to-unlink race is within the same-UID attack boundary.
        guard Self.closedEntryIdentity(
            named: cleanupName, in: target.directoryDescriptor
        ) == expectedIdentity else {
            try? syncDirectory(for: target)
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }
        let unlinkResult = cleanupName.withCString { component in
            Darwin.unlinkat(target.directoryDescriptor, component, 0)
        }
        guard unlinkResult == 0 else {
            try? syncDirectory(for: target)
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }
        do {
            try syncDirectory(for: target)
        } catch {
            throw WorkspaceMutationLeaseError.recoveryFailed(target.logicalURL)
        }
    }

    private static func closedEntryIdentity(
        named name: String, in directoryDescriptor: Int32
    ) -> PinnedIdentity? {
        var status = stat()
        let result = name.withCString { component in
            Darwin.fstatat(
                directoryDescriptor, component, &status, AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1 else {
            return nil
        }
        return PinnedIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        )
    }

    private static func freshRecoveryArtifactName(kind: String) -> String {
        let entropy = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return workspaceMutationRecoveryNamePrefix + kind + "-" + entropy
    }

    private static func createRecoverySlot(in target: PinnedTarget) throws -> RecoverySlot {
        // Recount at every actual creation boundary. Normal commits remove
        // their staging entry, while any retained full artifact consumes one
        // of the directory's bounded recovery slots.
        let artifactCount = try recoveryArtifactCount(in: target)
        guard artifactCount < maximumRecoveryArtifactsPerDirectory else {
            // No staging file exists and no target bytes have changed. Keep
            // this distinguishable from an indeterminate post-swap failure so
            // callers may safely leave their preview or receipt unconsumed.
            throw WorkspaceMutationLeaseError.recoveryCapacityExceeded(
                target.logicalURL
            )
        }
        let name = freshRecoveryArtifactName(kind: "staging")
        let descriptor = name.withCString { component in
            Darwin.openat(
                target.directoryDescriptor, component,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return RecoverySlot(
                descriptor: descriptor, name: name,
                identity: PinnedIdentity(
                    device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
                )
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode.EIO)
                }
                offset += count
            }
        }
    }

    private static func recoveryArtifactCount(
        in target: PinnedTarget
    ) throws -> Int {
        let enumerationDescriptor = Darwin.openat(
            target.directoryDescriptor, ".",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard enumerationDescriptor >= 0,
              let stream = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = Darwin.close(enumerationDescriptor) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.closedir(stream) }
        var artifactCount = 0
        errno = 0
        while let pointer = Darwin.readdir(stream) {
            var entry = pointer.pointee
            let capacity = MemoryLayout.size(ofValue: entry.d_name)
            let name = withUnsafePointer(to: &entry.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name.hasPrefix(workspaceMutationRecoveryNamePrefix) {
                artifactCount += 1
            }
            errno = 0
        }
        guard errno == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return artifactCount
    }

    private static func pathIdentity(_ url: URL) -> PinnedIdentity? {
        var status = stat()
        guard Darwin.stat(url.path, &status) == 0 else { return nil }
        return PinnedIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        )
    }
}

/// Actor entry protects root state, while this lock protects the one piece of
/// state that must also be synchronously mutable by a lease's `defer`. Token
/// matching prevents a late or duplicate release from clearing a newer lease.
private final class WorkspaceMutationLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeToken: UUID?

    func acquire(
        afterSwapBeforeValidation: (
            @Sendable (_ target: URL, _ swappedOut: URL) throws -> Void
        )?,
        beforeDirectorySync: (@Sendable (_ directory: URL) throws -> Void)?,
        buildTargets: () throws -> [WorkspaceMutationLease.PinnedTarget]
    ) throws -> WorkspaceMutationLease {
        let token = UUID()
        lock.lock()
        guard activeToken == nil else {
            lock.unlock()
            throw WorkspaceServiceError.rootReplacementInProgress
        }
        activeToken = token
        lock.unlock()
        let targets: [WorkspaceMutationLease.PinnedTarget]
        do {
            targets = try buildTargets()
        } catch {
            release(token)
            throw error
        }
        return WorkspaceMutationLease(
            targets: targets,
            afterSwapBeforeValidation: afterSwapBeforeValidation,
            beforeDirectorySync: beforeDirectorySync,
            releaseAction: { [weak self] in self?.release(token) }
        )
    }

    func requireNoActiveLease() throws {
        lock.lock()
        let hasActiveLease = activeToken != nil
        lock.unlock()
        if hasActiveLease {
            throw WorkspaceServiceError.rootReplacementInProgress
        }
    }

    private func release(_ token: UUID) {
        lock.lock()
        if activeToken == token { activeToken = nil }
        lock.unlock()
    }
}

public enum WorkspaceServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidFileURL(URL)
    case rootIsNotDirectory(URL)
    case rootAlreadyRegistered(URL)
    case rootNotRegistered(WorkspaceRoot.ID)
    case rootChanged(URL)
    case rootReplacementInProgress
    case rootReplacementRollbackFailed
    case tooManyRoots(maximum: Int)
    case tooManyRetainedFiles(maximum: Int)
    case tooManyDirectFileAuthorizations(maximum: Int)
    case unauthorized(URL)
    case symbolicLinkEscapesWorkspace(URL)
    case notADirectory(URL)
    case notAFile(URL)
    case itemNotFound(URL)
    case cannotEnumerateDirectory(URL)
    case invalidName(String)
    case itemAlreadyExists(URL)
    case cannotMutateWorkspaceRoot(URL)
    case moveIntoDescendant
    case crossVolumeMoveUnsupported
    case externalSpecialItemMoveUnsupported
    case directDirectoryTrashUnsupported
    case moveRollbackFailed(
        source: URL, target: URL, rollbackErrno: Int32,
        outcome: WorkspaceMoveRecoveryOutcome
    )

    public var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            "A workspace path must be an absolute file URL."
        case .rootIsNotDirectory:
            "A workspace root must be an existing directory."
        case .rootAlreadyRegistered:
            "This workspace root is already registered."
        case .rootNotRegistered:
            "This workspace root is no longer registered."
        case .rootChanged:
            "The authorised workspace root was replaced on disk."
        case .rootReplacementInProgress:
            "Another workspace-root replacement is still being finalized."
        case .rootReplacementRollbackFailed:
            "The workspace-root replacement could not be rolled back safely."
        case let .tooManyRoots(maximum):
            "A workspace supports at most \(maximum) roots."
        case let .tooManyRetainedFiles(maximum):
            "At most \(maximum) open files may retain access when a root is removed."
        case let .tooManyDirectFileAuthorizations(maximum):
            "At most \(maximum) files may have direct access."
        case .unauthorized:
            "This path has not been authorised for the workspace."
        case .symbolicLinkEscapesWorkspace:
            "A symbolic link resolves outside every authorised workspace root."
        case .notADirectory:
            "The requested path is not a directory."
        case .notAFile:
            "The requested path is not a regular file."
        case .itemNotFound:
            "The requested workspace item no longer exists."
        case .cannotEnumerateDirectory:
            "The directory could not be enumerated."
        case .invalidName:
            "Use a simple file or folder name without path separators."
        case .itemAlreadyExists:
            "An item with that name already exists."
        case .cannotMutateWorkspaceRoot:
            "A registered workspace root cannot be renamed, moved, or trashed."
        case .moveIntoDescendant:
            "A directory cannot be moved into one of its descendants."
        case .crossVolumeMoveUnsupported:
            "The item cannot be moved across storage volumes without copying it. The original was not changed."
        case .externalSpecialItemMoveUnsupported:
            "Only regular files and directories can be moved outside the workspace."
        case .directDirectoryTrashUnsupported:
            "Items moved outside the workspace cannot be moved to the Trash safely."
        case let .moveRollbackFailed(_, target, rollbackErrno, outcome):
            switch outcome {
            case .committedAtTarget:
                "The item was moved to \(target.path), but recovery after a verification failure also failed (errno \(rollbackErrno))."
            case .indeterminate:
                "The item move could not be recovered after verification failed; its disk location is uncertain (errno \(rollbackErrno))."
            }
        }
    }
}

/// Abstraction around the only destructive-looking workspace operation.
/// Production uses the recoverable system Trash; tests can inject a recorder.
public protocol WorkspaceTrashHandling: Sendable {
    func trashItem(at url: URL) throws
}

public struct SystemWorkspaceTrashHandler: WorkspaceTrashHandling, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func trashItem(at url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Opaque proof that a destination directory was selected by trusted UI. The
/// public constructor validates and captures the current directory target; UI
/// code should create it immediately after a trusted open panel returns.
public struct WorkspaceDirectoryAuthorization: Sendable {
    fileprivate let logicalURL: URL
    fileprivate let resolvedURL: URL
    fileprivate let device: UInt64
    fileprivate let inode: UInt64

    fileprivate init(
        logicalURL: URL, resolvedURL: URL, device: UInt64, inode: UInt64
    ) {
        self.logicalURL = logicalURL
        self.resolvedURL = resolvedURL
        self.device = device
        self.inode = inode
    }
}

/// Foundation-only core for a bounded, capability-scoped multi-root workspace.
///
/// Registering a root or direct file is the capability grant. UI code must do
/// that only after a trusted open panel, bookmark restore, or equivalent user
/// action. Every later operation rechecks both its lexical path and resolved
/// path. Directory symbolic links may be followed only when their target stays
/// inside an authorised root; recursive scans never follow symbolic links.
public actor WorkspaceService {
    private enum MoveItemResult: Sendable {
        case success
        case failure(Int32)
    }

    private struct DirectoryAuthorizationSnapshot: Sendable {
        let resolvedURL: URL
        let device: UInt64
        let inode: UInt64
    }

    private typealias MoveItemOperation = @Sendable (
        _ sourceDirectory: Int32, _ sourceName: String,
        _ destinationDirectory: Int32, _ destinationName: String
    ) -> MoveItemResult

    public struct Limits: Equatable, Sendable {
        public static let `default` = Limits()

        public var maximumRoots: Int
        public var maximumDirectoryEntries: Int
        public var maximumRecursiveFiles: Int
        public var maximumRecursiveEntries: Int
        public var maximumRecursionDepth: Int
        public var maximumEditableBytes: Int64
        public var maximumRetainedFiles: Int
        public var maximumDirectFileAuthorizations: Int
        public var maximumNameBytes: Int

        public init(
            maximumRoots: Int = 20,
            maximumDirectoryEntries: Int = 20_000,
            maximumRecursiveFiles: Int = 20_000,
            maximumRecursiveEntries: Int = 100_000,
            maximumRecursionDepth: Int = 20,
            maximumEditableBytes: Int64 = TextFileCodec.defaultMaximumByteCount,
            maximumRetainedFiles: Int = 100,
            maximumDirectFileAuthorizations: Int = 100,
            maximumNameBytes: Int = 255
        ) {
            precondition(maximumRoots >= 0)
            precondition(maximumDirectoryEntries >= 0)
            precondition(maximumRecursiveFiles >= 0)
            precondition(maximumRecursiveEntries >= 0)
            precondition(maximumRecursionDepth >= 0)
            precondition(maximumEditableBytes >= 0)
            precondition(maximumRetainedFiles >= 0)
            precondition(maximumDirectFileAuthorizations >= 0)
            precondition(maximumNameBytes >= 0)
            self.maximumRoots = maximumRoots
            self.maximumDirectoryEntries = maximumDirectoryEntries
            self.maximumRecursiveFiles = maximumRecursiveFiles
            self.maximumRecursiveEntries = maximumRecursiveEntries
            self.maximumRecursionDepth = maximumRecursionDepth
            self.maximumEditableBytes = maximumEditableBytes
            self.maximumRetainedFiles = maximumRetainedFiles
            self.maximumDirectFileAuthorizations = maximumDirectFileAuthorizations
            self.maximumNameBytes = maximumNameBytes
        }
    }

    /// Names hidden by the existing Electron workspace, without treating every
    /// dotfile as hidden.
    public static let builtInIgnoredNames: Set<String> = [
        ".git",
        "node_modules",
        ".DS_Store",
        ".cache",
        "dist",
        "out",
        "release",
        ".npm-cache",
        ".lumen-project.json"
    ]

    private struct RootRecord: Equatable {
        let id: WorkspaceRoot.ID
        let logicalURL: URL
        let resolvedURL: URL
        let identity: FileIdentity
    }

    private struct PendingRootReplacement {
        let id: UUID
        let baseRootRecords: [RootRecord]
        let basePrimaryRootID: WorkspaceRoot.ID?
        let baseDirectGrants: [String: DirectGrant]
        let stagedRootRecords: [RootRecord]
        let stagedPrimaryRootID: WorkspaceRoot.ID?
        let stagedDirectGrants: [String: DirectGrant]
    }

    private struct DirectFileGrant: Equatable {
        let logicalURL: URL
        let entryURL: URL
        let resolvedURL: URL
        let entryIdentity: FileIdentity
        let resolvedIdentity: FileIdentity
    }

    private struct DirectDirectoryGrant: Equatable {
        let logicalURL: URL
        let resolvedURL: URL
        let identity: FileIdentity
    }

    private enum DirectGrant: Equatable {
        case file(DirectFileGrant)
        case directory(DirectDirectoryGrant)

        var logicalURL: URL {
            switch self {
            case let .file(grant): grant.logicalURL
            case let .directory(grant): grant.logicalURL
            }
        }

        var identity: FileIdentity {
            switch self {
            case let .file(grant): grant.entryIdentity
            case let .directory(grant): grant.identity
            }
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Access {
        let logicalURL: URL
        let resolvedURL: URL
        let root: RootRecord?
        let entryIdentity: FileIdentity?
        let directoryGrant: DirectDirectoryGrant?

        init(
            logicalURL: URL, resolvedURL: URL, root: RootRecord?,
            entryIdentity: FileIdentity? = nil,
            directoryGrant: DirectDirectoryGrant? = nil
        ) {
            self.logicalURL = logicalURL
            self.resolvedURL = resolvedURL
            self.root = root
            self.entryIdentity = entryIdentity
            self.directoryGrant = directoryGrant
        }
    }

    private struct MovedItem {
        let url: URL
        let kind: WorkspaceEntry.Kind
        let identity: FileIdentity
    }

    private final class FileDescriptor {
        let rawValue: Int32

        init(_ rawValue: Int32) { self.rawValue = rawValue }

        deinit { _ = Darwin.close(rawValue) }
    }

    private struct BoundedChildren {
        let listing: WorkspaceDirectoryListing
        let inspectedCount: Int
    }

    private final class EnumerationErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        func store(_ error: Error) {
            lock.lock()
            storedError = error
            lock.unlock()
        }

        func load() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
    }

    private enum AccessKind: Equatable {
        /// Follow the final component for reads and directory traversal.
        case target
        /// Resolve only the parent so a symlink node itself can be moved or trashed.
        case entry
    }

    private enum EntryIdentityObservation: Equatable {
        case missing
        case identity(FileIdentity)
        case unknown(Int32)

        var failureCode: Int32? {
            guard case let .unknown(code) = self else { return nil }
            return code
        }
    }

    private let fileManager: FileManager
    private let trashHandler: any WorkspaceTrashHandling
    private let beforeOpeningFileDescriptor: (@Sendable (URL) throws -> Void)?
    private let beforeMutation: (@Sendable (URL) throws -> Void)?
    private let moveItemOperation: MoveItemOperation?
    private let rollbackMoveOperation: MoveItemOperation?
    private let afterMoveBeforeValidation: (@Sendable (URL) throws -> Void)?
    private let rollbackIdentityObservationFailure: (
        @Sendable (URL) -> Int32?
    )?
    private let beforeMoveDestinationAuthorization: (@Sendable (URL) throws -> Void)?
    private let beforeRootReplacementRemoval: (
        @Sendable (_ removalIndex: Int, _ rootID: WorkspaceRoot.ID) throws -> Void
    )?
    private let afterMutationLeaseSwapBeforeValidation: (
        @Sendable (_ target: URL, _ swappedOut: URL) throws -> Void
    )?
    private let beforeMutationLeaseDirectorySync: (
        @Sendable (_ directory: URL) throws -> Void
    )?
    public let limits: Limits

    private var rootRecords: [RootRecord] = []
    private var primaryRootID: WorkspaceRoot.ID?
    private var directGrants: [String: DirectGrant] = [:]
    private var pendingRootReplacement: PendingRootReplacement?
    private nonisolated let mutationLeaseRegistry = WorkspaceMutationLeaseRegistry()

    /// File mutations are ordered across service instances, just as saves and
    /// path changes share one queue in the Electron main process.
    private static let mutationLock = NSLock()

    public init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler()
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        beforeOpeningFileDescriptor: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        self.beforeOpeningFileDescriptor = beforeOpeningFileDescriptor
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        beforeMutation: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        self.beforeMutation = beforeMutation
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        moveItemFailure: @escaping @Sendable (
            _ sourceDirectory: Int32, _ sourceName: String,
            _ destinationDirectory: Int32, _ destinationName: String
        ) -> Int32
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = { sourceDirectory, sourceName, destinationDirectory, destinationName in
            .failure(moveItemFailure(
                sourceDirectory, sourceName, destinationDirectory, destinationName
            ))
        }
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        beforeMoveDestinationAuthorization: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        self.beforeMoveDestinationAuthorization = beforeMoveDestinationAuthorization
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        afterMoveBeforeValidation: @escaping @Sendable (URL) throws -> Void,
        rollbackMoveFailure: @escaping @Sendable (
            _ sourceDirectory: Int32, _ sourceName: String,
            _ destinationDirectory: Int32, _ destinationName: String
        ) -> Int32,
        rollbackIdentityObservationFailure: @escaping @Sendable (URL) -> Int32?
            = { _ in nil }
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = { sourceDirectory, sourceName,
                                  destinationDirectory, destinationName in
            let code = rollbackMoveFailure(
                sourceDirectory, sourceName, destinationDirectory, destinationName
            )
            return code == 0 ? .success : .failure(code)
        }
        self.afterMoveBeforeValidation = afterMoveBeforeValidation
        self.rollbackIdentityObservationFailure = rollbackIdentityObservationFailure
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    /// Test-only deterministic failure seam for the staged multi-root removal
    /// portion of `replaceRoots`. The actor commits none of the staged state if
    /// this hook or any later validation throws.
    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        beforeRootReplacementRemoval: @escaping @Sendable (
            _ removalIndex: Int, _ rootID: WorkspaceRoot.ID
        ) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        self.beforeRootReplacementRemoval = beforeRootReplacementRemoval
        afterMutationLeaseSwapBeforeValidation = nil
        beforeMutationLeaseDirectorySync = nil
    }

    /// Test-only seam after an atomic swap and before ownership validation.
    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        afterMutationLeaseSwapBeforeValidation: @escaping @Sendable (
            _ target: URL, _ swappedOut: URL
        ) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        self.afterMutationLeaseSwapBeforeValidation =
            afterMutationLeaseSwapBeforeValidation
        beforeMutationLeaseDirectorySync = nil
    }

    /// Test-only seam immediately before a post-swap directory durability sync.
    init(
        fileManager: FileManager = .default,
        limits: Limits = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler(),
        beforeMutationLeaseDirectorySync: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.trashHandler = trashHandler
        beforeOpeningFileDescriptor = nil
        beforeMutation = nil
        moveItemOperation = nil
        rollbackMoveOperation = nil
        afterMoveBeforeValidation = nil
        rollbackIdentityObservationFailure = nil
        beforeMoveDestinationAuthorization = nil
        beforeRootReplacementRemoval = nil
        afterMutationLeaseSwapBeforeValidation = nil
        self.beforeMutationLeaseDirectorySync = beforeMutationLeaseDirectorySync
    }

    // MARK: - Capability and root model

    @discardableResult
    public func addRoot(_ url: URL, makePrimary: Bool = false) throws -> WorkspaceRoot {
        try mutationLeaseRegistry.requireNoActiveLease()
        let logicalURL = try absoluteFileURL(url)
        let resolvedURL = canonicalURL(logicalURL)
        let values = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw WorkspaceServiceError.rootIsNotDirectory(logicalURL)
        }
        guard !rootRecords.contains(where: {
            $0.logicalURL.path == logicalURL.path || $0.resolvedURL.path == resolvedURL.path
        }) else {
            throw WorkspaceServiceError.rootAlreadyRegistered(logicalURL)
        }
        guard rootRecords.count < limits.maximumRoots else {
            throw WorkspaceServiceError.tooManyRoots(maximum: limits.maximumRoots)
        }

        let record = RootRecord(
            id: WorkspaceRoot.ID(),
            logicalURL: logicalURL,
            resolvedURL: resolvedURL,
            identity: try requiredFileIdentity(at: resolvedURL)
        )
        rootRecords.append(record)
        if primaryRootID == nil || makePrimary { primaryRootID = record.id }
        return snapshot(record)
    }

    public func setPrimaryRoot(_ id: WorkspaceRoot.ID) throws {
        try mutationLeaseRegistry.requireNoActiveLease()
        guard rootRecords.contains(where: { $0.id == id }) else {
            throw WorkspaceServiceError.rootNotRegistered(id)
        }
        primaryRootID = id
    }

    public func registeredRoots() -> [WorkspaceRoot] {
        rootRecords.map(snapshot)
    }

    /// Replaces all roots as one actor-isolated commit. Every filesystem and
    /// retained-file validation is performed against staged copies first, so
    /// an error after the replacement root is staged or between old-root
    /// removals leaves root IDs, primary selection, and direct grants exactly
    /// as they were before the call. Selecting an already registered root is
    /// therefore safe and only changes its primary marker at commit.
    @discardableResult
    public func replaceRoots(
        with url: URL,
        removing removals: [WorkspaceRootReplacementRemoval]
    ) throws -> WorkspaceRoot {
        let transaction = try beginRootReplacement(
            with: url, removing: removals
        )
        try finishRootReplacement(transaction, commit: true)
        return transaction.replacement
    }

    /// Validates and stages a replacement without publishing it. Reads and
    /// unrelated operations continue to observe the committed capability
    /// state until `finishRootReplacement` installs this staged value.
    public func beginRootReplacement(
        with url: URL,
        removing removals: [WorkspaceRootReplacementRemoval]
    ) throws -> WorkspaceRootReplacementTransaction {
        try Task.checkCancellation()
        try mutationLeaseRegistry.requireNoActiveLease()
        guard pendingRootReplacement == nil else {
            throw WorkspaceServiceError.rootReplacementInProgress
        }
        let logicalURL = try absoluteFileURL(url)
        let resolvedURL = canonicalURL(logicalURL)

        var stagedRootRecords = rootRecords
        var stagedPrimaryRootID = primaryRootID
        var stagedDirectGrants = directGrants

        let replacementRecord: RootRecord
        if let existing = stagedRootRecords.first(where: {
            $0.logicalURL.path == logicalURL.path
                || $0.resolvedURL.path == resolvedURL.path
        }) {
            replacementRecord = existing
        } else {
            let values = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw WorkspaceServiceError.rootIsNotDirectory(logicalURL)
            }
            replacementRecord = RootRecord(
                id: WorkspaceRoot.ID(),
                logicalURL: logicalURL,
                resolvedURL: resolvedURL,
                identity: try requiredFileIdentity(at: resolvedURL)
            )
            stagedRootRecords.append(replacementRecord)
        }
        stagedPrimaryRootID = replacementRecord.id

        var seenRemovalIDs: Set<WorkspaceRoot.ID> = []
        for (index, removal) in removals.enumerated() {
            guard seenRemovalIDs.insert(removal.id).inserted else { continue }
            guard removal.id != replacementRecord.id else { continue }
            try beforeRootReplacementRemoval?(index, removal.id)
            guard let rootIndex = stagedRootRecords.firstIndex(where: {
                $0.id == removal.id
            }) else {
                throw WorkspaceServiceError.rootNotRegistered(removal.id)
            }
            guard removal.retainingOpenFiles.count <= limits.maximumRetainedFiles else {
                throw WorkspaceServiceError.tooManyRetainedFiles(
                    maximum: limits.maximumRetainedFiles
                )
            }
            let record = stagedRootRecords[rootIndex]
            let retained = try removal.retainingOpenFiles.map { url -> DirectFileGrant in
                let logical = try absoluteFileURL(url)
                guard Self.contains(record.logicalURL, logical) else {
                    throw WorkspaceServiceError.unauthorized(logical)
                }
                let resolved = canonicalURL(logical)
                guard Self.contains(record.resolvedURL, resolved) else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logical)
                }
                let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw WorkspaceServiceError.notAFile(logical)
                }
                return try directGrant(for: logical)
            }
            stagedRootRecords.remove(at: rootIndex)
            stagedDirectGrants = stagedDirectGrants.filter { _, grant in
                !Self.contains(record.logicalURL, grant.logicalURL)
            }
            for grant in retained where stagedDirectGrants[grant.logicalURL.path] == nil {
                let coveredByDirectory = stagedDirectGrants.values.contains { existing in
                    guard case .directory = existing else { return false }
                    return Self.contains(existing.logicalURL, grant.logicalURL)
                }
                if !coveredByDirectory {
                    stagedDirectGrants[grant.logicalURL.path] = .file(grant)
                }
            }
            guard stagedDirectGrants.count <= limits.maximumDirectFileAuthorizations else {
                throw WorkspaceServiceError.tooManyDirectFileAuthorizations(
                    maximum: limits.maximumDirectFileAuthorizations
                )
            }
        }
        guard stagedRootRecords.count <= limits.maximumRoots else {
            throw WorkspaceServiceError.tooManyRoots(maximum: limits.maximumRoots)
        }

        let transactionID = UUID()
        pendingRootReplacement = PendingRootReplacement(
            id: transactionID,
            baseRootRecords: rootRecords,
            basePrimaryRootID: primaryRootID,
            baseDirectGrants: directGrants,
            stagedRootRecords: stagedRootRecords,
            stagedPrimaryRootID: stagedPrimaryRootID,
            stagedDirectGrants: stagedDirectGrants
        )
        return WorkspaceRootReplacementTransaction(
            id: transactionID,
            replacement: snapshot(
                replacementRecord, primaryRootID: stagedPrimaryRootID
            )
        )
    }

    /// Commits the complete staged capability state in one actor turn. A
    /// discard only clears the pending value because `begin` never modified
    /// live state. If another operation changed roots or direct grants between
    /// the phases, commit fails closed instead of overwriting that work.
    public func finishRootReplacement(
        _ transaction: WorkspaceRootReplacementTransaction, commit: Bool
    ) throws {
        guard let pending = pendingRootReplacement,
              pending.id == transaction.id else {
            throw WorkspaceServiceError.rootReplacementRollbackFailed
        }
        guard commit else {
            pendingRootReplacement = nil
            return
        }
        try mutationLeaseRegistry.requireNoActiveLease()
        try Task.checkCancellation()
        defer { pendingRootReplacement = nil }
        guard rootRecords == pending.baseRootRecords,
              primaryRootID == pending.basePrimaryRootID,
              directGrants == pending.baseDirectGrants else {
            throw WorkspaceServiceError.rootReplacementRollbackFailed
        }
        rootRecords = pending.stagedRootRecords
        primaryRootID = pending.stagedPrimaryRootID
        directGrants = pending.stagedDirectGrants
    }

    /// Returns the most-specific lexical root, which is what relative project
    /// excludes and multi-root tree labels need. I/O methods additionally run
    /// the resolved-path security check.
    public func root(containing url: URL) -> WorkspaceRoot? {
        guard let candidate = try? absoluteFileURL(url) else { return nil }
        return rootRecords
            .filter { Self.contains($0.logicalURL, candidate) }
            .max { $0.logicalURL.path.count < $1.logicalURL.path.count }
            .map(snapshot)
    }

    public func removeRoot(
        _ id: WorkspaceRoot.ID,
        retainingOpenFiles retainedFiles: [URL] = []
    ) throws {
        try mutationLeaseRegistry.requireNoActiveLease()
        guard let index = rootRecords.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceServiceError.rootNotRegistered(id)
        }
        guard retainedFiles.count <= limits.maximumRetainedFiles else {
            throw WorkspaceServiceError.tooManyRetainedFiles(maximum: limits.maximumRetainedFiles)
        }
        let record = rootRecords[index]
        let retained = try retainedFiles.map { url -> DirectFileGrant in
            let logical = try absoluteFileURL(url)
            guard Self.contains(record.logicalURL, logical) else {
                throw WorkspaceServiceError.unauthorized(logical)
            }
            let resolved = canonicalURL(logical)
            guard Self.contains(record.resolvedURL, resolved) else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logical)
            }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw WorkspaceServiceError.notAFile(logical)
            }
            return try directGrant(for: logical)
        }
        let grantsRemainingAfterRelease = directGrants.values.filter { grant in
            !Self.contains(record.logicalURL, grant.logicalURL)
        }
        let retainedPaths = Set(retained.map { $0.logicalURL.path })
        let existingPaths = Set(grantsRemainingAfterRelease.map { $0.logicalURL.path })
        let retainedGrantPaths = retainedPaths.filter { path in
            !grantsRemainingAfterRelease.contains { grant in
                guard case .directory = grant else { return false }
                return Self.contains(grant.logicalURL, URL(fileURLWithPath: path))
            }
        }
        let totalDirectGrants = existingPaths.union(retainedGrantPaths).count
        guard totalDirectGrants <= limits.maximumDirectFileAuthorizations else {
            throw WorkspaceServiceError.tooManyDirectFileAuthorizations(
                maximum: limits.maximumDirectFileAuthorizations
            )
        }

        rootRecords.remove(at: index)
        directGrants = directGrants.filter { _, grant in
            !Self.contains(record.logicalURL, grant.logicalURL)
        }
        for grant in retained where directGrants[grant.logicalURL.path] == nil {
            let coveredByDirectory = directGrants.values.contains { existing in
                guard case .directory = existing else { return false }
                return Self.contains(existing.logicalURL, grant.logicalURL)
            }
            if !coveredByDirectory {
                directGrants[grant.logicalURL.path] = .file(grant)
            }
        }
        if primaryRootID == id { primaryRootID = rootRecords.first?.id }
    }

    /// Atomically revalidates every exact root capability and installs an
    /// exclusive mutation lease in the same actor turn. A replacement may
    /// already be staged because it has not changed live capabilities; its
    /// eventual commit will fail closed while this lease remains active.
    func acquireMutationLease(
        for targets: [(rootID: WorkspaceRoot.ID, url: URL)]
    ) throws -> WorkspaceMutationLease {
        try Task.checkCancellation()
        return try mutationLeaseRegistry.acquire(
            afterSwapBeforeValidation: afterMutationLeaseSwapBeforeValidation,
            beforeDirectorySync: beforeMutationLeaseDirectorySync
        ) {
            var pinnedTargets: [WorkspaceMutationLease.PinnedTarget] = []
            pinnedTargets.reserveCapacity(targets.count)
            for target in targets {
                try Task.checkCancellation()
                pinnedTargets.append(try pinMutationTarget(
                    rootID: target.rootID, url: target.url
                ))
            }
            try Task.checkCancellation()
            return pinnedTargets
        }
    }

    /// Grants one exact user-selected file without recursively authorising its
    /// parent. Call only after a trusted file panel/bookmark operation.
    public func authorizeFile(_ url: URL) throws {
        try mutationLeaseRegistry.requireNoActiveLease()
        let logical = try absoluteFileURL(url)
        let resolved = canonicalURL(logical)
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceServiceError.notAFile(logical) }
        if directGrants[logical.path] == nil,
           directGrants.count >= limits.maximumDirectFileAuthorizations {
            throw WorkspaceServiceError.tooManyDirectFileAuthorizations(
                maximum: limits.maximumDirectFileAuthorizations
            )
        }
        directGrants[logical.path] = .file(try directGrant(for: logical))
    }

    public func revokeFileAuthorization(_ url: URL) {
        guard let logical = try? absoluteFileURL(url) else { return }
        if case .file? = directGrants[logical.path] {
            directGrants.removeValue(forKey: logical.path)
        }
    }

    /// Trusted UI calls this only for a directory returned by the native open
    /// panel. Keeping the token initializer internal prevents other modules
    /// from manufacturing a destination capability directly.
    public func authorizeMoveDestination(
        userSelectedDirectory url: URL
    ) throws -> WorkspaceDirectoryAuthorization {
        let logical = try absoluteFileURL(url)
        let first = try directoryAuthorizationSnapshot(for: logical)
        let second = try directoryAuthorizationSnapshot(for: logical)
        guard first.device == second.device, first.inode == second.inode,
              first.resolvedURL.path == second.resolvedURL.path else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logical)
        }
        try beforeMoveDestinationAuthorization?(logical)
        return WorkspaceDirectoryAuthorization(
            logicalURL: logical, resolvedURL: second.resolvedURL,
            device: second.device, inode: second.inode
        )
    }

    // MARK: - Lazy and recursive reads

    public func children(
        of directory: URL,
        exclusions: WorkspaceExclusionPolicy = .default
    ) throws -> WorkspaceDirectoryListing {
        try boundedChildren(
            of: directory,
            exclusions: exclusions,
            maximumInspectedEntries: limits.maximumDirectoryEntries
        ).listing
    }

    private func boundedChildren(
        of directory: URL,
        exclusions: WorkspaceExclusionPolicy,
        maximumInspectedEntries: Int
    ) throws -> BoundedChildren {
        let access = try authorisedAccess(to: directory, kind: .target)
        if access.directoryGrant != nil {
            let descriptor = try openMutationDirectory(access)
            defer { _ = Darwin.close(descriptor) }
            try beforeOpeningFileDescriptor?(access.logicalURL)
            return try boundedChildren(
                of: access.logicalURL, descriptor: descriptor,
                exclusions: exclusions, maximumInspectedEntries: maximumInspectedEntries
            )
        }
        let values = try access.resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw WorkspaceServiceError.notADirectory(access.logicalURL)
        }

        let errorBox = EnumerationErrorBox()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: access.resolvedURL,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, error in
                errorBox.store(error)
                return false
            }
        ) else {
            throw WorkspaceServiceError.cannotEnumerateDirectory(access.logicalURL)
        }

        var entries: [WorkspaceEntry] = []
        var inspected = 0
        var isTruncated = false
        while let rawItem = enumerator.nextObject() {
            if let error = errorBox.load() { throw error }
            guard let physicalURL = rawItem as? URL else { continue }
            if inspected >= maximumInspectedEntries {
                isTruncated = true
                break
            }
            inspected += 1

            let name = physicalURL.lastPathComponent
            let kind = try entryKind(at: physicalURL)
            let logicalURL = access.logicalURL.appendingPathComponent(
                name,
                isDirectory: kind == .directory
            ).standardizedFileURL
            let relativePath = relativePathForExclusions(
                logicalURL,
                root: access.root?.logicalURL ?? access.logicalURL
            )
            if exclusions.excludes(
                name: name,
                relativePath: relativePath,
                isDirectory: kind == .directory
            ) {
                continue
            }
            entries.append(WorkspaceEntry(name: name, url: logicalURL, kind: kind))
        }
        if let error = errorBox.load() { throw error }

        entries.sort(by: Self.entryComesBefore)
        return BoundedChildren(
            listing: WorkspaceDirectoryListing(entries: entries, isTruncated: isTruncated),
            inspectedCount: inspected
        )
    }

    private func boundedChildren(
        of logicalDirectory: URL, descriptor: Int32,
        exclusions: WorkspaceExclusionPolicy, maximumInspectedEntries: Int
    ) throws -> BoundedChildren {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw WorkspaceServiceError.cannotEnumerateDirectory(logicalDirectory)
        }
        defer { Darwin.closedir(stream) }
        var entries: [WorkspaceEntry] = []
        var inspected = 0
        var isTruncated = false
        errno = 0
        while let pointer = Darwin.readdir(stream) {
            var rawEntry = pointer.pointee
            let capacity = MemoryLayout.size(ofValue: rawEntry.d_name)
            let name = withUnsafePointer(to: &rawEntry.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            if inspected >= maximumInspectedEntries {
                isTruncated = true
                break
            }
            inspected += 1
            guard let status = try entryStatus(
                named: name, in: descriptor,
                logicalURL: logicalDirectory.appendingPathComponent(name)
            ) else { continue }
            let kind = entryKind(from: status)
            let logicalURL = logicalDirectory.appendingPathComponent(
                name, isDirectory: kind == .directory
            ).standardizedFileURL
            if exclusions.excludes(
                name: name, relativePath: name, isDirectory: kind == .directory
            ) {
                errno = 0
                continue
            }
            entries.append(WorkspaceEntry(name: name, url: logicalURL, kind: kind))
            errno = 0
        }
        guard errno == 0 else {
            throw WorkspaceServiceError.cannotEnumerateDirectory(logicalDirectory)
        }
        entries.sort(by: Self.entryComesBefore)
        return BoundedChildren(
            listing: WorkspaceDirectoryListing(entries: entries, isTruncated: isTruncated),
            inspectedCount: inspected
        )
    }

    public func recursiveFiles(
        in rootID: WorkspaceRoot.ID,
        exclusions: WorkspaceExclusionPolicy = .default
    ) throws -> WorkspaceFileListing {
        try recursiveFiles(in: [rootID], exclusions: exclusions)
    }

    public func recursiveFiles(
        in rootIDs: [WorkspaceRoot.ID],
        exclusions: WorkspaceExclusionPolicy = .default
    ) throws -> WorkspaceFileListing {
        var uniqueIDs: [WorkspaceRoot.ID] = []
        for id in rootIDs where !uniqueIDs.contains(id) { uniqueIDs.append(id) }
        let roots = try uniqueIDs.map { id -> RootRecord in
            guard let root = rootRecords.first(where: { $0.id == id }) else {
                throw WorkspaceServiceError.rootNotRegistered(id)
            }
            return root
        }

        var files: [URL] = []
        var inspectedEntries = 0
        var isTruncated = false

        for root in roots {
            var stack: [(url: URL, depth: Int)] = [(root.logicalURL, 0)]
            while let next = stack.popLast() {
                if next.depth > limits.maximumRecursionDepth {
                    isTruncated = true
                    continue
                }
                if inspectedEntries >= limits.maximumRecursiveEntries {
                    isTruncated = true
                    return WorkspaceFileListing(files: files, isTruncated: isTruncated)
                }
                let remainingEntries = limits.maximumRecursiveEntries - inspectedEntries
                let bounded = try boundedChildren(
                    of: next.url,
                    exclusions: exclusions,
                    maximumInspectedEntries: min(
                        limits.maximumDirectoryEntries,
                        remainingEntries
                    )
                )
                let listing = bounded.listing
                inspectedEntries += bounded.inspectedCount
                if listing.isTruncated { isTruncated = true }
                var directories: [URL] = []
                for entry in listing.entries {
                    switch entry.kind {
                    case .directory:
                        directories.append(entry.url)
                    case .file:
                        if files.count >= limits.maximumRecursiveFiles {
                            isTruncated = true
                            return WorkspaceFileListing(files: files, isTruncated: isTruncated)
                        }
                        files.append(entry.url)
                    case .symbolicLink, .other:
                        break
                    }
                }
                for child in directories.reversed() {
                    stack.append((child, next.depth + 1))
                }
            }
        }
        return WorkspaceFileListing(files: files, isTruncated: isTruncated)
    }

    public func openFile(
        _ url: URL,
        forcedEncoding: TextEncoding? = nil
    ) throws -> OpenedTextFile {
        let access = try authorisedAccess(to: url, kind: .target)
        let expectedIdentity: FileIdentity
        if access.root != nil {
            // The openat walk below is authoritative; this snapshot turns a
            // final-component swap between authorisation and open into a clean
            // identity mismatch instead of returning the replacement bytes.
            expectedIdentity = try requiredFileIdentity(at: access.resolvedURL)
        } else if access.directoryGrant != nil {
            guard let identity = access.entryIdentity else {
                throw WorkspaceServiceError.notAFile(access.logicalURL)
            }
            expectedIdentity = identity
        } else {
            guard case let .file(grant)? = directGrants[access.logicalURL.path] else {
                throw WorkspaceServiceError.unauthorized(access.logicalURL)
            }
            expectedIdentity = grant.resolvedIdentity
        }
        try beforeOpeningFileDescriptor?(access.resolvedURL)
        let descriptor: Int32
        do {
            descriptor = try openReadDescriptor(for: access)
        } catch let error as POSIXError where error.code == .ELOOP {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(access.logicalURL)
        }
        defer { _ = Darwin.close(descriptor) }
        let descriptorRead: TextFileCodec.DescriptorRead
        do {
            descriptorRead = try TextFileCodec.readDescriptor(
                descriptor,
                sourceURL: access.logicalURL,
                forcedEncoding: forcedEncoding,
                maximumByteCount: limits.maximumEditableBytes,
                expectedIdentity: TextFileCodec.DescriptorIdentity(
                    device: expectedIdentity.device,
                    inode: expectedIdentity.inode
                )
            )
        } catch let error as TextFileCodecError {
            if error == .fileChangedDuringOpen, access.root == nil {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(access.logicalURL)
            }
            throw error
        }
        return descriptorRead.file
    }

    /// Resolve `.editorconfig` only within one explicitly registered workspace
    /// capability. Passing the root ID prevents overlapping roots from silently
    /// widening the caller's intended authorization boundary.
    public func resolveEditorConfig(
        for targetURL: URL,
        in rootID: WorkspaceRoot.ID,
        allowMissingTarget: Bool = false,
        limits: EditorConfigLimits = .default
    ) throws -> ResolvedEditorConfig {
        guard let root = rootRecords.first(where: { $0.id == rootID }) else {
            throw WorkspaceServiceError.rootNotRegistered(rootID)
        }
        let target = try absoluteFileURL(targetURL)
        guard Self.contains(root.logicalURL, target) else {
            throw WorkspaceServiceError.unauthorized(target)
        }
        guard canonicalURL(root.logicalURL).path == root.resolvedURL.path,
              fileIdentityIfAvailable(at: root.resolvedURL) == root.identity else {
            throw WorkspaceServiceError.rootChanged(root.logicalURL)
        }

        do {
            return try EditorConfig.resolve(
                for: target,
                workspaceRoot: root.logicalURL,
                allowMissingTarget: allowMissingTarget,
                limits: limits
            )
        } catch let error as EditorConfigResolutionError {
            switch error {
            case .invalidFileURL, .targetOutsideWorkspace:
                throw WorkspaceServiceError.unauthorized(target)
            case .symbolicLinkEscapesWorkspace:
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(target)
            }
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func createFile(in directory: URL, named name: String) throws -> WorkspaceEntry {
        try mutationLeaseRegistry.requireNoActiveLease()
        try validateName(name)
        return try Self.withMutationLock {
            let parent = try authorisedAccess(to: directory, kind: .target)
            guard parent.root != nil || parent.directoryGrant != nil else {
                throw WorkspaceServiceError.unauthorized(parent.logicalURL)
            }
            let logical = parent.logicalURL.appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL
            try beforeMutation?(logical)
            let parentDescriptor = try openMutationDirectory(parent)
            defer { _ = Darwin.close(parentDescriptor) }
            let descriptor = name.withCString { component in
                Darwin.openat(
                    parentDescriptor, component,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o666)
                )
            }
            guard descriptor >= 0 else {
                try throwMutationError(errno, logicalURL: logical)
            }
            _ = Darwin.close(descriptor)
            return WorkspaceEntry(name: name, url: logical, kind: .file)
        }
    }

    @discardableResult
    public func createFile(at url: URL) throws -> WorkspaceEntry {
        let target = try absoluteFileURL(url)
        return try createFile(in: target.deletingLastPathComponent(), named: target.lastPathComponent)
    }

    @discardableResult
    public func createDirectory(in directory: URL, named name: String) throws -> WorkspaceEntry {
        try mutationLeaseRegistry.requireNoActiveLease()
        try validateName(name)
        return try Self.withMutationLock {
            let parent = try authorisedAccess(to: directory, kind: .target)
            guard parent.root != nil || parent.directoryGrant != nil else {
                throw WorkspaceServiceError.unauthorized(parent.logicalURL)
            }
            let logical = parent.logicalURL.appendingPathComponent(name, isDirectory: true)
                .standardizedFileURL
            try beforeMutation?(logical)
            let parentDescriptor = try openMutationDirectory(parent)
            defer { _ = Darwin.close(parentDescriptor) }
            let result = name.withCString { component in
                Darwin.mkdirat(parentDescriptor, component, mode_t(0o777))
            }
            guard result == 0 else {
                try throwMutationError(errno, logicalURL: logical)
            }
            return WorkspaceEntry(name: name, url: logical, kind: .directory)
        }
    }

    @discardableResult
    public func createDirectory(at url: URL) throws -> WorkspaceEntry {
        let target = try absoluteFileURL(url)
        return try createDirectory(
            in: target.deletingLastPathComponent(),
            named: target.lastPathComponent
        )
    }

    /// Rename is intentionally same-parent only. Cross-directory changes use
    /// `move`, where the destination directory receives its own capability check.
    @discardableResult
    public func rename(_ source: URL, toName name: String) throws -> URL {
        try mutationLeaseRegistry.requireNoActiveLease()
        try validateName(name)
        return try Self.withMutationLock {
            let sourceAccess = try authorisedAccess(to: source, kind: .entry)
            try rejectRegisteredRootMutation(sourceAccess.logicalURL)
            let logicalTarget = sourceAccess.logicalURL.deletingLastPathComponent()
                .appendingPathComponent(name)
                .standardizedFileURL
            if logicalTarget.path == sourceAccess.logicalURL.path { return logicalTarget }

            let parent = try authorisedAccess(
                to: sourceAccess.logicalURL.deletingLastPathComponent(),
                kind: .target
            )
            try beforeMutation?(logicalTarget)
            let parentDescriptor = try openMutationDirectory(parent)
            defer { _ = Darwin.close(parentDescriptor) }
            let sourceName = sourceAccess.logicalURL.lastPathComponent
            guard let sourceStatus = try entryStatus(
                named: sourceName, in: parentDescriptor, logicalURL: sourceAccess.logicalURL
            ) else {
                throw WorkspaceServiceError.itemNotFound(sourceAccess.logicalURL)
            }
            try validatePinnedSource(
                sourceStatus, against: sourceAccess, logicalURL: sourceAccess.logicalURL
            )
            try moveItemWithoutOverwriting(
                named: sourceName,
                from: parentDescriptor,
                named: name,
                to: parentDescriptor,
                logicalSource: sourceAccess.logicalURL,
                logicalDestination: logicalTarget
            )
            let expectedIdentity = FileIdentity(
                device: UInt64(sourceStatus.st_dev),
                inode: UInt64(sourceStatus.st_ino)
            )
            do {
                try afterMoveBeforeValidation?(logicalTarget)
                try validatePinnedDirectoryPath(
                    parentDescriptor, access: parent
                )
                _ = try verifiedMovedEntryIdentity(
                    named: name, in: parentDescriptor,
                    expected: expectedIdentity,
                    logicalURL: logicalTarget
                )
            } catch {
                let recovery = rollbackMove(
                    named: name, from: parentDescriptor, to: parentDescriptor,
                    destinationName: sourceName, expectedIdentity: expectedIdentity,
                    logicalSource: sourceAccess.logicalURL,
                    logicalTarget: logicalTarget
                )
                if recovery?.outcome == .committedAtTarget {
                    rewriteDirectGrants(
                        from: sourceAccess.logicalURL,
                        physicalSource: sourceAccess.resolvedURL,
                        to: logicalTarget,
                        physicalTarget: parent.resolvedURL.appendingPathComponent(name)
                            .standardizedFileURL
                    )
                }
                if let recovery { throw WorkspaceServiceError.moveRollbackFailed(
                    source: sourceAccess.logicalURL, target: logicalTarget,
                    rollbackErrno: recovery.errno, outcome: recovery.outcome
                ) }
                throw error
            }
            rewriteDirectGrants(
                from: sourceAccess.logicalURL,
                physicalSource: sourceAccess.resolvedURL,
                to: logicalTarget,
                physicalTarget: parent.resolvedURL.appendingPathComponent(name)
                    .standardizedFileURL
            )
            return logicalTarget
        }
    }

    @discardableResult
    public func move(_ source: URL, toDirectory destinationDirectory: URL) throws -> URL {
        try mutationLeaseRegistry.requireNoActiveLease()
        let destination = try authorisedAccess(to: destinationDirectory, kind: .target)
        return try move(source, to: destination)
    }

    /// Move to a directory selected outside the current workspace. The token
    /// does not add a recursive root grant; only the moved destination entry
    /// receives an exact direct grant after the operation succeeds.
    @discardableResult
    public func move(
        _ source: URL,
        using authorization: WorkspaceDirectoryAuthorization
    ) throws -> URL {
        try mutationLeaseRegistry.requireNoActiveLease()
        let sourceAccess = try authorisedAccess(to: source, kind: .entry)
        guard canonicalURL(authorization.logicalURL).path == authorization.resolvedURL.path else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(authorization.logicalURL)
        }
        let destinationIdentity = FileIdentity(
            device: authorization.device, inode: authorization.inode
        )
        guard fileIdentityIfAvailable(at: authorization.resolvedURL) == destinationIdentity else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(authorization.logicalURL)
        }
        let target = authorization.logicalURL
            .appendingPathComponent(sourceAccess.logicalURL.lastPathComponent)
            .standardizedFileURL
        let resolvedTarget = authorization.resolvedURL
            .appendingPathComponent(sourceAccess.logicalURL.lastPathComponent)
            .standardizedFileURL
        let coveredByRoot = rootRecords.contains { root in
            Self.contains(root.logicalURL, target)
                && Self.contains(root.resolvedURL, resolvedTarget)
        }
        let existingDestinationAccess = try? authorisedAccess(
            to: authorization.logicalURL, kind: .target
        )
        let coveredByDirectDirectory = existingDestinationAccess?.directoryGrant != nil
            && existingDestinationAccess?.resolvedURL.path == authorization.resolvedURL.path
        let shouldAddDirectGrant = !coveredByRoot && !coveredByDirectDirectory
        let sourceKind = try entryKind(at: sourceAccess.resolvedURL)
        if sourceKind != .file, sourceKind != .directory {
            throw WorkspaceServiceError.externalSpecialItemMoveUnsupported
        }
        var projectedGrants = rebasingDirectGrants(
            directGrants,
            from: sourceAccess.logicalURL,
            physicalSource: sourceAccess.resolvedURL,
            to: target,
            physicalTarget: resolvedTarget
        )
        if shouldAddDirectGrant {
            guard let sourceIdentity = sourceAccess.entryIdentity else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                    sourceAccess.logicalURL
                )
            }
            if sourceKind == .directory {
                projectedGrants[target.path] = .directory(DirectDirectoryGrant(
                    logicalURL: target, resolvedURL: resolvedTarget,
                    identity: sourceIdentity
                ))
            } else {
                projectedGrants[target.path] = .file(DirectFileGrant(
                    logicalURL: target, entryURL: resolvedTarget,
                    resolvedURL: resolvedTarget, entryIdentity: sourceIdentity,
                    resolvedIdentity: sourceIdentity
                ))
            }
        }
        projectedGrants = collapsingDirectFileGrantsCoveredByDirectories(
            projectedGrants
        )
        if projectedGrants.count > limits.maximumDirectFileAuthorizations {
            throw WorkspaceServiceError.tooManyDirectFileAuthorizations(
                maximum: limits.maximumDirectFileAuthorizations
            )
        }
        let destination = Access(
            logicalURL: authorization.logicalURL,
            resolvedURL: authorization.resolvedURL,
            root: nil,
            entryIdentity: destinationIdentity
        )
        let movedItem: MovedItem
        do {
            movedItem = try moveItem(
                source, to: destination, commitRecoveredGrants: false
            )
        } catch let error as WorkspaceServiceError {
            if case .moveRollbackFailed(_, _, _, .committedAtTarget) = error {
                directGrants = projectedGrants
            }
            throw error
        }
        let movedTarget = movedItem.url
        directGrants = projectedGrants
        return movedTarget
    }

    private func move(_ source: URL, to destination: Access) throws -> URL {
        try moveItem(source, to: destination).url
    }

    private func moveItem(
        _ source: URL, to destination: Access,
        commitRecoveredGrants: Bool = true
    ) throws -> MovedItem {
        try Self.withMutationLock {
            let sourceAccess = try authorisedAccess(to: source, kind: .entry)
            try rejectRegisteredRootMutation(sourceAccess.logicalURL)
            let logicalTarget = destination.logicalURL
                .appendingPathComponent(sourceAccess.logicalURL.lastPathComponent)
                .standardizedFileURL
            try beforeMutation?(logicalTarget)
            let sourceParentAccess = try authorisedAccess(
                to: sourceAccess.logicalURL.deletingLastPathComponent(), kind: .target
            )
            let sourceParent = try openMutationDirectory(sourceParentAccess)
            defer { _ = Darwin.close(sourceParent) }
            let destinationParent = try openMutationDirectory(destination)
            defer { _ = Darwin.close(destinationParent) }
            let sourceName = sourceAccess.logicalURL.lastPathComponent
            guard let sourceStatus = try entryStatus(
                named: sourceName, in: sourceParent, logicalURL: sourceAccess.logicalURL
            ) else {
                throw WorkspaceServiceError.itemNotFound(sourceAccess.logicalURL)
            }
            try validatePinnedSource(
                sourceStatus, against: sourceAccess, logicalURL: sourceAccess.logicalURL
            )
            let sourceKind = entryKind(from: sourceStatus)
            if destination.root == nil, sourceKind != .file, sourceKind != .directory {
                throw WorkspaceServiceError.externalSpecialItemMoveUnsupported
            }
            if sourceAccess.resolvedURL.deletingLastPathComponent().path
                == destination.resolvedURL.path {
                return MovedItem(
                    url: logicalTarget, kind: sourceKind,
                    identity: FileIdentity(
                        device: UInt64(sourceStatus.st_dev),
                        inode: UInt64(sourceStatus.st_ino)
                    )
                )
            }
            if sourceKind == .directory {
                let resolvedSource = canonicalURL(sourceAccess.resolvedURL)
                if Self.contains(resolvedSource, destination.resolvedURL) {
                    throw WorkspaceServiceError.moveIntoDescendant
                }
            }
            try moveItemWithoutOverwriting(
                named: sourceName,
                from: sourceParent,
                named: sourceName,
                to: destinationParent,
                logicalSource: sourceAccess.logicalURL,
                logicalDestination: logicalTarget
            )
            let expectedIdentity = FileIdentity(
                device: UInt64(sourceStatus.st_dev), inode: UInt64(sourceStatus.st_ino)
            )
            let movedIdentity: FileIdentity
            do {
                try afterMoveBeforeValidation?(logicalTarget)
                try validatePinnedDirectoryPath(
                    sourceParent, access: sourceParentAccess
                )
                try validatePinnedDirectoryPath(
                    destinationParent, access: destination
                )
                movedIdentity = try verifiedMovedEntryIdentity(
                    named: sourceName, in: destinationParent,
                    expected: expectedIdentity, logicalURL: logicalTarget
                )
            } catch {
                let recovery = rollbackMove(
                    named: sourceName, from: destinationParent,
                    to: sourceParent, expectedIdentity: expectedIdentity,
                    logicalSource: sourceAccess.logicalURL, logicalTarget: logicalTarget
                )
                if recovery?.outcome == .committedAtTarget, commitRecoveredGrants {
                    rewriteDirectGrants(
                        from: sourceAccess.logicalURL,
                        physicalSource: sourceAccess.resolvedURL,
                        to: logicalTarget,
                        physicalTarget: destination.resolvedURL.appendingPathComponent(
                            sourceName, isDirectory: sourceKind == .directory
                        ).standardizedFileURL
                    )
                }
                if let recovery { throw WorkspaceServiceError.moveRollbackFailed(
                    source: sourceAccess.logicalURL, target: logicalTarget,
                    rollbackErrno: recovery.errno, outcome: recovery.outcome
                ) }
                throw error
            }
            if commitRecoveredGrants {
                rewriteDirectGrants(
                    from: sourceAccess.logicalURL,
                    physicalSource: sourceAccess.resolvedURL,
                    to: logicalTarget,
                    physicalTarget: destination.resolvedURL.appendingPathComponent(
                        sourceName, isDirectory: sourceKind == .directory
                    ).standardizedFileURL
                )
            }
            return MovedItem(
                url: logicalTarget, kind: sourceKind,
                identity: movedIdentity
            )
        }
    }

    /// Moves a workspace-root entry to the recoverable system Trash. Direct
    /// directory capabilities fail closed because FileManager has no
    /// descriptor-relative Trash operation.
    public func moveToTrash(_ url: URL) throws {
        try mutationLeaseRegistry.requireNoActiveLease()
        try Self.withMutationLock {
            let access = try authorisedAccess(to: url, kind: .entry)
            try rejectRegisteredRootMutation(access.logicalURL)
            guard access.directoryGrant == nil else {
                throw WorkspaceServiceError.directDirectoryTrashUnsupported
            }
            try trashHandler.trashItem(at: access.resolvedURL)
            directGrants = directGrants.filter { _, grant in
                !Self.contains(access.logicalURL, grant.logicalURL)
            }
        }
    }

    // MARK: - Validation helpers

    private func snapshot(_ record: RootRecord) -> WorkspaceRoot {
        snapshot(record, primaryRootID: primaryRootID)
    }

    private func snapshot(
        _ record: RootRecord, primaryRootID: WorkspaceRoot.ID?
    ) -> WorkspaceRoot {
        let name = record.logicalURL.lastPathComponent.isEmpty
            ? record.logicalURL.path
            : record.logicalURL.lastPathComponent
        return WorkspaceRoot(
            id: record.id,
            url: record.logicalURL,
            displayName: name,
            isPrimary: primaryRootID == record.id
        )
    }

    private func absoluteFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw WorkspaceServiceError.invalidFileURL(url)
        }
        return url.standardizedFileURL
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func pinMutationTarget(
        rootID: WorkspaceRoot.ID, url: URL
    ) throws -> WorkspaceMutationLease.PinnedTarget {
        guard let root = rootRecords.first(where: { $0.id == rootID }) else {
            throw WorkspaceServiceError.rootNotRegistered(rootID)
        }
        let logicalURL = try absoluteFileURL(url)
        guard Self.contains(root.logicalURL, logicalURL) else {
            throw WorkspaceServiceError.unauthorized(logicalURL)
        }
        guard canonicalURL(root.logicalURL).path == root.resolvedURL.path,
              fileIdentityIfAvailable(at: root.resolvedURL) == root.identity else {
            throw WorkspaceServiceError.rootChanged(root.logicalURL)
        }
        let resolvedURL = canonicalURL(logicalURL)
        guard Self.contains(root.resolvedURL, resolvedURL) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        let components = try relativeComponents(of: logicalURL, under: root.logicalURL)
        guard let name = components.last, !name.isEmpty else {
            throw WorkspaceServiceError.notAFile(logicalURL)
        }
        let logicalParentURL = logicalURL.deletingLastPathComponent().standardizedFileURL
        let parentURL = canonicalURL(logicalParentURL)
        guard Self.contains(root.resolvedURL, parentURL) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        let parentAccess = Access(
            logicalURL: logicalParentURL,
            resolvedURL: parentURL, root: root
        )
        let parentDescriptor = try openMutationDirectory(parentAccess)
        do {
            var status = stat()
            let inspected = name.withCString { component in
                Darwin.fstatat(
                    parentDescriptor, component, &status, AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0 else {
                try throwMutationError(errno, logicalURL: logicalURL)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
            }
            let parentIdentity = try fileIdentity(of: parentDescriptor)
            return WorkspaceMutationLease.PinnedTarget(
                directoryDescriptor: parentDescriptor, name: name,
                logicalURL: logicalURL, resolvedURL: resolvedURL,
                parentResolvedURL: parentURL,
                parentIdentity: .init(
                    device: parentIdentity.device, inode: parentIdentity.inode
                ),
                rootLogicalURL: root.logicalURL, rootResolvedURL: root.resolvedURL,
                rootIdentity: .init(
                    device: root.identity.device, inode: root.identity.inode
                ),
                identity: .init(
                    device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
                )
            )
        } catch {
            _ = Darwin.close(parentDescriptor)
            throw error
        }
    }

    private func directoryAuthorizationSnapshot(
        for logicalURL: URL
    ) throws -> DirectoryAuthorizationSnapshot {
        let descriptor = Darwin.open(
            logicalURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolved = canonicalURL(logicalURL)
        var pathStatus = stat()
        guard Darwin.stat(resolved.path, &pathStatus) == 0,
              UInt64(pathStatus.st_dev) == UInt64(descriptorStatus.st_dev),
              UInt64(pathStatus.st_ino) == UInt64(descriptorStatus.st_ino) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        return DirectoryAuthorizationSnapshot(
            resolvedURL: resolved,
            device: UInt64(descriptorStatus.st_dev),
            inode: UInt64(descriptorStatus.st_ino)
        )
    }

    private func authorisedAccess(to rawURL: URL, kind: AccessKind) throws -> Access {
        let logicalURL = try absoluteFileURL(rawURL)
        let lexicalRoots = rootRecords
            .filter { Self.contains($0.logicalURL, logicalURL) }
            .sorted { $0.logicalURL.path.count > $1.logicalURL.path.count }
        var encounteredEscape = false

        for root in lexicalRoots {
            // A symlink used as the root must still point at the directory the
            // user authorised; retargeting it invalidates the capability.
            guard canonicalURL(root.logicalURL).path == root.resolvedURL.path else {
                encounteredEscape = true
                continue
            }
            guard fileIdentityIfAvailable(at: root.resolvedURL) == root.identity else {
                throw WorkspaceServiceError.rootChanged(root.logicalURL)
            }
            let resolved: URL
            switch kind {
            case .target:
                resolved = canonicalURL(logicalURL)
            case .entry:
                resolved = canonicalURL(logicalURL.deletingLastPathComponent())
                    .appendingPathComponent(logicalURL.lastPathComponent)
                    .standardizedFileURL
            }
            if Self.contains(root.resolvedURL, resolved) {
                guard canonicalURL(root.logicalURL).path == root.resolvedURL.path else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                if kind == .entry, !itemExists(at: resolved) {
                    throw WorkspaceServiceError.itemNotFound(logicalURL)
                }
                return Access(
                    logicalURL: logicalURL, resolvedURL: resolved, root: root,
                    entryIdentity: kind == .entry
                        ? try requiredEntryIdentity(at: resolved) : nil
                )
            }
            encounteredEscape = true
        }

        if case let .file(grant)? = directGrants[logicalURL.path] {
            switch kind {
            case .target:
                let current = canonicalURL(logicalURL)
                guard current.path == grant.resolvedURL.path else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                guard fileIdentityIfAvailable(at: current) == grant.resolvedIdentity else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                guard canonicalURL(logicalURL).path == current.path else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                return Access(logicalURL: logicalURL, resolvedURL: current, root: nil)
            case .entry:
                let currentEntry = canonicalURL(logicalURL.deletingLastPathComponent())
                    .appendingPathComponent(logicalURL.lastPathComponent)
                    .standardizedFileURL
                guard currentEntry.path == grant.entryURL.path else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                guard canonicalURL(logicalURL.deletingLastPathComponent())
                    .appendingPathComponent(logicalURL.lastPathComponent)
                    .standardizedFileURL.path == currentEntry.path else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                guard itemExists(at: currentEntry) else {
                    throw WorkspaceServiceError.itemNotFound(logicalURL)
                }
                let currentIdentity = try requiredEntryIdentity(at: currentEntry)
                guard currentIdentity == grant.entryIdentity else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
                }
                return Access(
                    logicalURL: logicalURL, resolvedURL: currentEntry, root: nil,
                    entryIdentity: currentIdentity
                )
            }
        }

        if let grant = directGrants.values.compactMap({ directGrant -> DirectDirectoryGrant? in
            guard case let .directory(grant) = directGrant,
                  Self.contains(grant.logicalURL, logicalURL) else { return nil }
            return grant
        }).max(by: { $0.logicalURL.path.count < $1.logicalURL.path.count }) {
            let rootAccess = Access(
                logicalURL: grant.logicalURL, resolvedURL: grant.resolvedURL,
                root: nil, entryIdentity: grant.identity
            )
            let rootDescriptor = try openMutationDirectory(rootAccess)
            defer { _ = Darwin.close(rootDescriptor) }
            let components = try relativeComponents(
                of: logicalURL, under: grant.logicalURL
            )
            if components.isEmpty {
                return Access(
                    logicalURL: logicalURL, resolvedURL: grant.resolvedURL,
                    root: nil, entryIdentity: grant.identity,
                    directoryGrant: grant
                )
            }
            var current = FileDescriptor(Darwin.dup(rootDescriptor))
            guard current.rawValue >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for component in components.dropLast() {
                let next = component.withCString { name in
                    Darwin.openat(
                        current.rawValue, name,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                    )
                }
                guard next >= 0 else {
                    try throwDirectoryOpenError(
                        errno, parentDescriptor: current.rawValue,
                        component: component, logicalURL: logicalURL
                    )
                }
                current = FileDescriptor(next)
            }
            let finalName = components[components.count - 1]
            guard let finalStatus = try entryStatus(
                named: finalName, in: current.rawValue, logicalURL: logicalURL
            ) else {
                throw WorkspaceServiceError.itemNotFound(logicalURL)
            }
            if kind == .target,
               finalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
            }
            let resolved = components.reduce(grant.resolvedURL) { partial, component in
                partial.appendingPathComponent(component)
            }.standardizedFileURL
            return Access(
                logicalURL: logicalURL, resolvedURL: resolved, root: nil,
                entryIdentity: FileIdentity(
                    device: UInt64(finalStatus.st_dev),
                    inode: UInt64(finalStatus.st_ino)
                ),
                directoryGrant: grant
            )
        }

        if encounteredEscape {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        throw WorkspaceServiceError.unauthorized(logicalURL)
    }

    private func directGrant(for logicalURL: URL) throws -> DirectFileGrant {
        let entryURL = canonicalURL(logicalURL.deletingLastPathComponent())
            .appendingPathComponent(logicalURL.lastPathComponent)
            .standardizedFileURL
        let resolvedURL = canonicalURL(logicalURL)
        return DirectFileGrant(
            logicalURL: logicalURL,
            entryURL: entryURL,
            resolvedURL: resolvedURL,
            entryIdentity: try requiredEntryIdentity(at: entryURL),
            resolvedIdentity: try requiredFileIdentity(at: resolvedURL)
        )
    }

    private func fileIdentityIfAvailable(at url: URL) -> FileIdentity? {
        var status = stat()
        guard Darwin.stat(url.path, &status) == 0 else { return nil }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private func requiredFileIdentity(at url: URL) throws -> FileIdentity {
        guard let identity = fileIdentityIfAvailable(at: url) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return identity
    }

    private func requiredEntryIdentity(at url: URL) throws -> FileIdentity {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw WorkspaceServiceError.itemNotFound(url) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private func openReadDescriptor(for access: Access) throws -> Int32 {
        if let grant = access.directoryGrant {
            var descriptor = Darwin.open(
                grant.resolvedURL.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            guard descriptor >= 0 else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                    access.logicalURL
                )
            }
            do {
                guard try fileIdentity(of: descriptor) == grant.identity else {
                    throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                        access.logicalURL
                    )
                }
                let components = try relativeComponents(
                    of: access.logicalURL, under: grant.logicalURL
                )
                guard !components.isEmpty else {
                    throw WorkspaceServiceError.notAFile(access.logicalURL)
                }
                for (index, component) in components.enumerated() {
                    let isLast = index == components.count - 1
                    let flags = isLast
                        ? (O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                        : (O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
                    let next = component.withCString { name in
                        Darwin.openat(descriptor, name, flags)
                    }
                    guard next >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    _ = Darwin.close(descriptor)
                    descriptor = next
                }
                return descriptor
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        guard let root = access.root else {
            let descriptor = Darwin.open(
                access.resolvedURL.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }

        var descriptor = Darwin.open(
            root.resolvedURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            guard try fileIdentity(of: descriptor) == root.identity else {
                throw WorkspaceServiceError.rootChanged(root.logicalURL)
            }
            let components = try relativeComponents(
                of: access.resolvedURL,
                under: root.resolvedURL
            )
            guard !components.isEmpty else {
                throw WorkspaceServiceError.notAFile(access.logicalURL)
            }
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                let flags = isLast
                    ? (O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    : (O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
                let next = component.withCString { name in
                    Darwin.openat(descriptor, name, flags)
                }
                guard next >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                _ = Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Opens a directory capability without following any component after the
    /// authorised anchor. The returned descriptor pins the actual directory
    /// used by the subsequent mutation even if its pathname is swapped.
    private func openMutationDirectory(_ access: Access) throws -> Int32 {
        if let grant = access.directoryGrant {
            var current = FileDescriptor(Darwin.open(
                grant.resolvedURL.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            ))
            guard current.rawValue >= 0,
                  try fileIdentity(of: current.rawValue) == grant.identity else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                    access.logicalURL
                )
            }
            let components = try relativeComponents(
                of: access.resolvedURL, under: grant.resolvedURL
            )
            for component in components {
                let next = component.withCString { name in
                    Darwin.openat(
                        current.rawValue, name,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                    )
                }
                guard next >= 0 else {
                    try throwDirectoryOpenError(
                        errno, parentDescriptor: current.rawValue,
                        component: component, logicalURL: access.logicalURL
                    )
                }
                current = FileDescriptor(next)
            }
            let result = Darwin.dup(current.rawValue)
            guard result >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return result
        }
        if let root = access.root {
            let rootDescriptor = Darwin.open(
                root.resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            guard rootDescriptor >= 0 else {
                throw WorkspaceServiceError.rootChanged(root.logicalURL)
            }
            var current = FileDescriptor(rootDescriptor)
            guard try fileIdentity(of: current.rawValue) == root.identity else {
                throw WorkspaceServiceError.rootChanged(root.logicalURL)
            }
            let components = try relativeComponents(
                of: access.resolvedURL, under: root.resolvedURL
            )
            for component in components {
                let next = component.withCString { name in
                    Darwin.openat(
                        current.rawValue, name,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                    )
                }
                guard next >= 0 else {
                    try throwDirectoryOpenError(
                        errno, parentDescriptor: current.rawValue,
                        component: component, logicalURL: access.logicalURL
                    )
                }
                current = FileDescriptor(next)
            }
            // Recheck the anchored root while every traversed directory is
            // still open. A renamed-away root is rejected before mutation.
            guard canonicalURL(root.logicalURL).path == root.resolvedURL.path else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                    access.logicalURL
                )
            }
            guard fileIdentityIfAvailable(at: root.resolvedURL) == root.identity else {
                throw WorkspaceServiceError.rootChanged(root.logicalURL)
            }
            guard canonicalURL(access.logicalURL).path == access.resolvedURL.path else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(
                    access.logicalURL
                )
            }
            let result = Darwin.dup(current.rawValue)
            guard result >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return result
        }

        let descriptor = Darwin.open(
            access.resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(access.logicalURL)
            }
            if errno == ENOENT {
                throw WorkspaceServiceError.itemNotFound(access.logicalURL)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            guard let expected = access.entryIdentity,
                  try fileIdentity(of: descriptor) == expected,
                  fileIdentityIfAvailable(at: access.resolvedURL) == expected,
                  canonicalURL(access.logicalURL).path == access.resolvedURL.path else {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(access.logicalURL)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func fileIdentity(of descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private func relativeComponents(of url: URL, under root: URL) throws -> [String] {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard Self.contains(root, url) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(url)
        }
        let suffix = rootPath == "/"
            ? String(path.dropFirst())
            : String(path.dropFirst(rootPath.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        guard !suffix.isEmpty else { return [] }
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(url)
        }
        return components
    }

    private func requireDirectory(_ access: Access) throws {
        let values = try access.resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw WorkspaceServiceError.notADirectory(access.logicalURL)
        }
    }

    private func entryKind(at url: URL) throws -> WorkspaceEntry.Kind {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return .symbolicLink
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true { return .directory }
        if values.isRegularFile == true { return .file }
        return .other
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0"),
              name.lengthOfBytes(using: .utf8) <= limits.maximumNameBytes else {
            throw WorkspaceServiceError.invalidName(name)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func throwMutationError(_ code: Int32, logicalURL: URL) throws -> Never {
        switch code {
        case EEXIST:
            throw WorkspaceServiceError.itemAlreadyExists(logicalURL)
        case ELOOP, ENOTDIR:
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        case ENOENT:
            throw WorkspaceServiceError.itemNotFound(logicalURL)
        default:
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func throwDirectoryOpenError(
        _ code: Int32, parentDescriptor: Int32, component: String, logicalURL: URL
    ) throws -> Never {
        if code == ELOOP {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        if code == ENOTDIR {
            var status = stat()
            let inspected = component.withCString { name in
                Darwin.fstatat(
                    parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW
                )
            }
            if inspected == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
            }
            throw WorkspaceServiceError.notADirectory(logicalURL)
        }
        if code == ENOENT {
            throw WorkspaceServiceError.itemNotFound(logicalURL)
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func entryStatus(
        named name: String, in directory: Int32, logicalURL: URL
    ) throws -> stat? {
        var status = stat()
        let result = name.withCString { component in
            Darwin.fstatat(directory, component, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return status }
        if errno == ENOENT { return nil }
        try throwMutationError(errno, logicalURL: logicalURL)
    }

    private func entryKind(from status: stat) -> WorkspaceEntry.Kind {
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFREG): .file
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
    }

    private func validatePinnedSource(
        _ status: stat, against access: Access, logicalURL: URL
    ) throws {
        guard let expected = access.entryIdentity,
              expected == FileIdentity(
                  device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
              ) else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
    }

    /// Both directory descriptors are pinned by no-follow component walks, and
    /// RENAME_EXCL closes the destination-existence race atomically.
    private func moveItemWithoutOverwriting(
        named sourceName: String, from sourceDirectory: Int32,
        named destinationName: String, to destinationDirectory: Int32,
        logicalSource: URL,
        logicalDestination: URL
    ) throws {
        let result: MoveItemResult
        if let moveItemOperation {
            result = moveItemOperation(
                sourceDirectory, sourceName, destinationDirectory, destinationName
            )
        } else {
            let returnCode = sourceName.withCString { source in
                destinationName.withCString { destination in
                    Darwin.renameatx_np(
                        sourceDirectory, source, destinationDirectory, destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            result = returnCode == 0 ? .success : .failure(errno)
        }
        guard case let .failure(failure) = result else { return }
        if failure == EEXIST {
            throw WorkspaceServiceError.itemAlreadyExists(logicalDestination)
        }
        if failure == ENOENT {
            throw WorkspaceServiceError.itemNotFound(logicalSource)
        }
        if failure == EXDEV {
            throw WorkspaceServiceError.crossVolumeMoveUnsupported
        }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    private func verifiedMovedEntryIdentity(
        named name: String, in directory: Int32, expected: FileIdentity,
        logicalURL: URL
    ) throws -> FileIdentity {
        guard let status = try entryStatus(
            named: name, in: directory, logicalURL: logicalURL
        ) else {
            throw WorkspaceServiceError.itemNotFound(logicalURL)
        }
        let identity = FileIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        )
        guard identity == expected else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(logicalURL)
        }
        return identity
    }

    private func validatePinnedDirectoryPath(
        _ descriptor: Int32, access: Access
    ) throws {
        let expected: FileIdentity
        if let root = access.root, access.resolvedURL.path == root.resolvedURL.path {
            expected = root.identity
        } else if let directoryGrant = access.directoryGrant,
                  access.resolvedURL.path == directoryGrant.resolvedURL.path {
            expected = directoryGrant.identity
        } else {
            expected = try fileIdentity(of: descriptor)
        }
        guard fileIdentityIfAvailable(at: access.resolvedURL) == expected else {
            throw WorkspaceServiceError.symbolicLinkEscapesWorkspace(access.logicalURL)
        }
    }

    private func rollbackMove(
        named name: String, from destinationDirectory: Int32, to sourceDirectory: Int32,
        destinationName: String? = nil, expectedIdentity: FileIdentity,
        logicalSource: URL, logicalTarget: URL
    ) -> (errno: Int32, outcome: WorkspaceMoveRecoveryOutcome)? {
        let destinationName = destinationName ?? name
        let result: MoveItemResult
        if let rollbackMoveOperation {
            result = rollbackMoveOperation(
                destinationDirectory, name, sourceDirectory, destinationName
            )
        } else {
            let returnCode = name.withCString { component in
                destinationName.withCString { destination in
                    Darwin.renameatx_np(
                        destinationDirectory, component, sourceDirectory, destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            result = returnCode == 0 ? .success : .failure(errno)
        }
        let failure: Int32?
        switch result {
        case .success:
            failure = nil
        case let .failure(code):
            failure = code
        }

        let sourceIdentity = observeEntryIdentity(
            named: destinationName, in: sourceDirectory
        )
        let targetIdentity = observeEntryIdentity(
            named: name, in: destinationDirectory
        )
        let logicalSourceIdentity = observeEntryIdentity(at: logicalSource)
        let logicalTargetIdentity = observeEntryIdentity(at: logicalTarget)
        if sourceIdentity == .identity(expectedIdentity),
           targetIdentity == .missing,
           logicalSourceIdentity == .identity(expectedIdentity),
           logicalTargetIdentity == .missing {
            return nil
        }
        let outcome: WorkspaceMoveRecoveryOutcome
        if sourceIdentity == .missing, targetIdentity == .identity(expectedIdentity),
           logicalSourceIdentity == .missing,
           logicalTargetIdentity == .identity(expectedIdentity) {
            outcome = .committedAtTarget
        } else {
            outcome = .indeterminate
        }
        let observationFailure = [
            sourceIdentity, targetIdentity,
            logicalSourceIdentity, logicalTargetIdentity
        ].lazy.compactMap(\.failureCode).first
        return (failure ?? observationFailure ?? EIO, outcome)
    }

    private func observeEntryIdentity(
        named name: String, in directory: Int32
    ) -> EntryIdentityObservation {
        var status = stat()
        let result = name.withCString { component in
            Darwin.fstatat(directory, component, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown(errno)
        }
        return .identity(FileIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        ))
    }

    private func observeEntryIdentity(at url: URL) -> EntryIdentityObservation {
        if let failure = rollbackIdentityObservationFailure?(url) {
            return .unknown(failure)
        }
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown(errno)
        }
        return .identity(FileIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        ))
    }

    private func rejectRegisteredRootMutation(_ source: URL) throws {
        let resolvedSource = canonicalURL(source)
        if rootRecords.contains(where: {
            Self.contains(source, $0.logicalURL)
                || Self.contains(resolvedSource, $0.resolvedURL)
        }) {
            throw WorkspaceServiceError.cannotMutateWorkspaceRoot(source)
        }
    }

    /// Rebase existing grants using the identities captured before the rename.
    /// No post-mutation pathname is resolved here; subsequent access re-opens
    /// the known destination and verifies the retained entry/resolved identity.
    private func rewriteDirectGrants(
        from source: URL, physicalSource: URL, to target: URL, physicalTarget: URL
    ) {
        directGrants = rebasingDirectGrants(
            directGrants, from: source, physicalSource: physicalSource,
            to: target, physicalTarget: physicalTarget
        )
        collapseDirectFileGrantsCoveredByDirectories()
    }

    private func rebasingDirectGrants(
        _ grants: [String: DirectGrant],
        from source: URL, physicalSource: URL,
        to target: URL, physicalTarget: URL
    ) -> [String: DirectGrant] {
        let affected = grants.values.filter {
            Self.isSameOrDescendant($0.logicalURL, of: source)
        }
        var result = grants
        for grant in affected { result.removeValue(forKey: grant.logicalURL.path) }
        for grant in affected {
            let suffix = String(grant.logicalURL.path.dropFirst(source.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let nextLogical = suffix.isEmpty
                ? target
                : target.appendingPathComponent(suffix)
            switch grant {
            case let .file(fileGrant):
                let nextEntry = rebasePhysicalURL(
                    fileGrant.entryURL, from: physicalSource, to: physicalTarget
                )
                let nextResolved = rebasePhysicalURL(
                    fileGrant.resolvedURL, from: physicalSource, to: physicalTarget
                )
                result[nextLogical.standardizedFileURL.path] = .file(
                    DirectFileGrant(
                        logicalURL: nextLogical.standardizedFileURL,
                        entryURL: nextEntry,
                        resolvedURL: nextResolved,
                        entryIdentity: fileGrant.entryIdentity,
                        resolvedIdentity: fileGrant.resolvedIdentity
                    )
                )
            case let .directory(directoryGrant):
                result[nextLogical.standardizedFileURL.path] = .directory(
                    DirectDirectoryGrant(
                        logicalURL: nextLogical.standardizedFileURL,
                        resolvedURL: rebasePhysicalURL(
                            directoryGrant.resolvedURL,
                            from: physicalSource, to: physicalTarget
                        ),
                        identity: directoryGrant.identity
                    )
                )
            }
        }
        return result
    }

    private func rebasePhysicalURL(
        _ url: URL, from source: URL, to target: URL
    ) -> URL {
        let source = source.standardizedFileURL
        let url = url.standardizedFileURL
        guard Self.isSameOrDescendant(url, of: source) else { return url }
        let suffix = String(url.path.dropFirst(source.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (suffix.isEmpty ? target : target.appendingPathComponent(suffix))
            .standardizedFileURL
    }

    private func collapseDirectFileGrantsCoveredByDirectories() {
        directGrants = collapsingDirectFileGrantsCoveredByDirectories(directGrants)
    }

    private func collapsingDirectFileGrantsCoveredByDirectories(
        _ grants: [String: DirectGrant]
    ) -> [String: DirectGrant] {
        let directories = grants.values.compactMap { grant -> DirectDirectoryGrant? in
            guard case let .directory(directory) = grant else { return nil }
            return directory
        }
        return grants.filter { _, grant in
            guard case let .file(fileGrant) = grant else { return true }
            return !directories.contains { directoryGrantCovers(
                fileGrant, directory: $0
            ) }
        }
    }

    /// Match the no-follow walk used by `authorisedAccess`. A lexical
    /// descendant is collapsible only when the directory capability reaches
    /// both its entry and target without crossing a symbolic link.
    private func directoryGrantCovers(
        _ fileGrant: DirectFileGrant, directory: DirectDirectoryGrant
    ) -> Bool {
        directoryGrantCovers(
            logicalURL: fileGrant.logicalURL, resolvedURL: fileGrant.entryURL,
            directory: directory
        ) && fileGrant.resolvedURL.standardizedFileURL.path
            == fileGrant.entryURL.standardizedFileURL.path
    }

    private func directoryGrantCovers(
        logicalURL: URL, resolvedURL: URL, directory: DirectDirectoryGrant
    ) -> Bool {
        guard Self.contains(directory.logicalURL, logicalURL) else { return false }
        let suffix = String(logicalURL.path.dropFirst(
            directory.logicalURL.path.count
        )).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !suffix.isEmpty else { return false }
        let reachable = directory.resolvedURL.appendingPathComponent(suffix)
            .standardizedFileURL
        return resolvedURL.standardizedFileURL.path == reachable.path
    }

    private func relativePathForExclusions(_ item: URL, root: URL) -> String {
        guard Self.contains(root, item), item.path != root.path else { return item.lastPathComponent }
        var relative = String(item.path.dropFirst(root.path.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == candidatePath { return true }
        if rootPath == "/" { return candidatePath.hasPrefix("/") }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSameOrDescendant(
        _ candidate: URL, of root: URL
    ) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath
            || (rootPath == "/" ? candidatePath.hasPrefix("/")
                : candidatePath.hasPrefix(rootPath + "/"))
    }

    private static func entryComesBefore(_ left: WorkspaceEntry, _ right: WorkspaceEntry) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        let comparison = left.name.localizedCompare(right.name)
        if comparison == .orderedSame { return left.url.path < right.url.path }
        return comparison == .orderedAscending
    }

    private static func withMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
    }
}
