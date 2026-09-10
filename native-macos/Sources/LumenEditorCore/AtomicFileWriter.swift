import Foundation
import Darwin

public enum FileWriteFailure: Error, Equatable, LocalizedError, Sendable {
    case conflict(actualRevision: String?)
    case hardLinked
    case invalidExpectedRevision

    public var errorDescription: String? {
        switch self {
        case .conflict:
            return "The file changed on disk after it was opened."
        case .hardLinked:
            return "The file has multiple hard links and was not replaced."
        case .invalidExpectedRevision:
            return "The expected file revision is invalid."
        }
    }
}

public struct FileWriteResult: Equatable, Sendable {
    public let revision: String
    public let wroteBytes: Bool
    /// False only when the target was verified at the requested revision, but
    /// synchronizing its parent directory could not be confirmed.
    public let durabilityConfirmed: Bool
    /// Whether cleanup performed by this invocation completed durably. This
    /// says nothing about artifacts left by earlier writer invocations. It
    /// remains false when unlink succeeded but its directory fsync failed.
    public let cleanupCompleted: Bool
    public let recoveryArtifact: URL?

    public var cleanupRecoveryArtifact: URL? {
        durabilityConfirmed && !cleanupCompleted ? recoveryArtifact : nil
    }

    public init(
        revision: String, wroteBytes: Bool,
        durabilityConfirmed: Bool = true, cleanupCompleted: Bool = true,
        recoveryArtifact: URL? = nil
    ) {
        self.revision = revision
        self.wroteBytes = wroteBytes
        self.durabilityConfirmed = durabilityConfirmed
        self.cleanupCompleted = cleanupCompleted
        self.recoveryArtifact = recoveryArtifact
    }
}

/// Failures whose filesystem side effects need more context than an ordinary
/// optimistic conflict. Any retained artifact is a complete file.
public enum FileWriteCommitFailure: Error, Equatable, LocalizedError, Sendable {
    case cleanupFailedBeforeCommit(recoveryArtifact: URL?)
    case stateIndeterminate(recoveryArtifact: URL?)

    public var errorDescription: String? {
        switch self {
        case .cleanupFailedBeforeCommit:
            return "The write was not committed, and its staging file could not be completely cleaned up."
        case .stateIndeterminate:
            return "The file changed during the atomic replacement. Recovery data was retained where possible."
        }
    }
}

enum AtomicFileWriterDirectorySyncPhase: Sendable {
    case noOp
    case commit
    case cleanup
    case precommitCleanup
    case rollback
}

/// Per-operation test seams. Keeping these on the call avoids mutable global
/// hooks and makes concurrent writer tests deterministic. Hook bodies execute
/// while the process-wide write lock is held and must not re-enter the writer.
struct AtomicFileWriterHooks: Sendable {
    var beforeAcquiringWriteLock: (@Sendable () throws -> Void)? = nil
    var afterAcquiringWriteLock: (@Sendable () throws -> Void)? = nil
    var afterInitialValidation: (@Sendable (_ target: URL) throws -> Void)? = nil
    var beforeCommit: (@Sendable (_ target: URL) throws -> Void)? = nil
    var afterFinalSnapshotBeforeCommit: (
        @Sendable (_ target: URL) throws -> Void
    )? = nil
    var beforeStagedIdentityRead: (
        @Sendable (_ stagingArtifact: URL) throws -> Void
    )? = nil
    var beforePrecommitCleanup: (
        @Sendable (_ stagingArtifact: URL) throws -> Void
    )? = nil
    var afterCommitBeforeValidation: (
        @Sendable (_ target: URL, _ recoveryArtifact: URL) throws -> Void
    )? = nil
    var beforeDirectorySync: (
        @Sendable (_ directory: URL, _ phase: AtomicFileWriterDirectorySyncPhase) throws -> Void
    )? = nil
    var beforeCleanup: (
        @Sendable (_ target: URL, _ recoveryArtifact: URL) throws -> Void
    )? = nil
}

/// Performs optimistic, same-directory atomic file replacement.
///
/// `expectedRevision == nil` means the destination must not exist. A concrete
/// SHA-256 revision means the current bytes must still match. Callers that
/// intentionally want an unchecked write should use `writeUnconditionally`.
public enum AtomicFileWriter {
    // App windows share this process-wide coordinator. Filesystem identity
    // validation still protects against external writers, while this lock
    // prevents two Lumen windows from racing the same optimistic revision.
    private static let writeLock = NSLock()

    private static let artifactPrefix = ".lumen-atomic-write-"

    public static func write(
        _ data: Data,
        to url: URL,
        expectedRevision: String?
    ) throws -> FileWriteResult {
        try write(
            data, to: url, expectedRevision: expectedRevision,
            hooks: AtomicFileWriterHooks()
        )
    }

    static func write(
        _ data: Data, to url: URL, expectedRevision: String?,
        hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        if let expectedRevision, !isRevision(expectedRevision) {
            throw FileWriteFailure.invalidExpectedRevision
        }
        return try withWriteLock(hooks: hooks) {
            try writeAssumingExclusiveTransaction(
                data, to: url, expectation: .revision(expectedRevision),
                hooks: hooks
            )
        }
    }

    /// Serializes a multi-step optimistic mutation with every ordinary atomic
    /// save in this process. The operation must not call `write` or
    /// `writeUnconditionally`, because `NSLock` is intentionally non-recursive.
    static func withExclusiveTransaction<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try operation()
    }

    public static func writeUnconditionally(
        _ data: Data, to url: URL
    ) throws -> FileWriteResult {
        try writeUnconditionally(
            data, to: url, hooks: AtomicFileWriterHooks()
        )
    }

    static func writeUnconditionally(
        _ data: Data, to url: URL, hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        try withWriteLock(hooks: hooks) {
            try writeAssumingExclusiveTransaction(
                data, to: url, expectation: .unconditional, hooks: hooks
            )
        }
    }

    private static func withWriteLock<T>(
        hooks: AtomicFileWriterHooks, _ operation: () throws -> T
    ) throws -> T {
        try hooks.beforeAcquiringWriteLock?()
        writeLock.lock()
        defer { writeLock.unlock() }
        try hooks.afterAcquiringWriteLock?()
        return try operation()
    }

    private enum WriteExpectation {
        case revision(String?)
        case unconditional
    }

    private enum WriteDecision {
        case proceed
        case noOp(EntrySnapshot)
    }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct EntrySnapshot {
        let identity: Identity
        let revision: String
        let permissions: mode_t
        let linkCount: UInt64
    }

    private final class StagedFile {
        private(set) var descriptor: Int32
        let name: String
        let identity: Identity

        init(descriptor: Int32, name: String, identity: Identity) {
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

    private struct CleanupFailure: Error {
        let artifactName: String?
    }

    private static func writeAssumingExclusiveTransaction(
        _ data: Data, to url: URL, expectation: WriteExpectation,
        hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        let manager = FileManager.default
        let logicalURL = url.standardizedFileURL
        let writeURL = logicalURL.resolvingSymlinksInPath().standardizedFileURL
        if (try? manager.destinationOfSymbolicLink(atPath: logicalURL.path)) != nil,
           !manager.fileExists(atPath: writeURL.path) {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }

        let directory = writeURL.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(directoryDescriptor) }

        let directoryIdentity = try descriptorIdentity(directoryDescriptor)
        try validateAttachment(
            logicalURL: logicalURL, writeURL: writeURL, directory: directory,
            directoryDescriptor: directoryDescriptor,
            expectedDirectoryIdentity: directoryIdentity
        )

        let targetName = writeURL.lastPathComponent
        let nextRevision = TextFileCodec.revision(of: data)
        let initial = try readEntryIfPresent(
            named: targetName, in: directoryDescriptor
        )
        if case let .noOp(snapshot) = try decision(
            initial, expectation: expectation, nextRevision: nextRevision
        ) {
            return try finishNoOp(
                targetName: targetName, targetURL: writeURL,
                directory: directory, directoryDescriptor: directoryDescriptor,
                directoryIdentity: directoryIdentity, logicalURL: logicalURL,
                snapshot: snapshot, nextRevision: nextRevision, hooks: hooks
            )
        }
        try hooks.afterInitialValidation?(writeURL)

        let stage = try createStagedFile(
            in: directoryDescriptor, directory: directory, hooks: hooks
        )
        do {
            try writeAll(data, to: stage.descriptor)
            try synchronize(stage.descriptor)
        } catch {
            let originalError = error
            stage.closeDescriptor()
            try cleanupBeforeCommit(
                stage, from: directoryDescriptor, directory: directory,
                hooks: hooks
            )
            throw originalError
        }

        let final: EntrySnapshot?
        do {
            try validateAttachment(
                logicalURL: logicalURL, writeURL: writeURL, directory: directory,
                directoryDescriptor: directoryDescriptor,
                expectedDirectoryIdentity: directoryIdentity
            )
            final = try readEntryIfPresent(
                named: targetName, in: directoryDescriptor
            )
            if case let .noOp(snapshot) = try decision(
                final, expectation: expectation, nextRevision: nextRevision
            ) {
                stage.closeDescriptor()
                try cleanupBeforeCommit(
                    stage, from: directoryDescriptor, directory: directory,
                    hooks: hooks
                )
                return try finishNoOp(
                    targetName: targetName, targetURL: writeURL,
                    directory: directory,
                    directoryDescriptor: directoryDescriptor,
                    directoryIdentity: directoryIdentity, logicalURL: logicalURL,
                    snapshot: snapshot, nextRevision: nextRevision, hooks: hooks
                )
            }
            if let final {
                guard Darwin.fchmod(stage.descriptor, final.permissions) == 0 else {
                    throw currentPOSIXError()
                }
                try synchronize(stage.descriptor)
            }
            try validateStagedFile(
                stage, in: directoryDescriptor, revision: nextRevision
            )
            try hooks.beforeCommit?(writeURL)
            try validateAttachment(
                logicalURL: logicalURL, writeURL: writeURL, directory: directory,
                directoryDescriptor: directoryDescriptor,
                expectedDirectoryIdentity: directoryIdentity
            )
            if let final {
                let immediatelyBeforeCommit = try readEntry(
                    named: targetName, in: directoryDescriptor,
                    expectedIdentity: final.identity
                )
                guard immediatelyBeforeCommit.revision == final.revision,
                      immediatelyBeforeCommit.linkCount == 1 else {
                    throw FileWriteFailure.conflict(
                        actualRevision: immediatelyBeforeCommit.revision
                    )
                }
            } else if try readEntryIfPresent(
                named: targetName, in: directoryDescriptor
            ) != nil {
                throw FileWriteFailure.conflict(
                    actualRevision: try readEntryIfPresent(
                        named: targetName, in: directoryDescriptor
                    )?.revision
                )
            }
            // This seam is deliberately after the last path snapshot. The
            // exchange cannot itself compare inode identities, so a change in
            // this final window is detected from the displaced entry and
            // safely exchanged back below.
            try hooks.afterFinalSnapshotBeforeCommit?(writeURL)
        } catch {
            let originalError = error
            stage.closeDescriptor()
            try cleanupBeforeCommit(
                stage, from: directoryDescriptor, directory: directory,
                hooks: hooks
            )
            throw originalError
        }

        if let final {
            return try commitExisting(
                targetName: targetName, targetURL: writeURL,
                directory: directory, directoryDescriptor: directoryDescriptor,
                directoryIdentity: directoryIdentity, logicalURL: logicalURL,
                previous: final, stage: stage, nextRevision: nextRevision,
                hooks: hooks
            )
        }

        return try commitCreation(
            targetName: targetName, targetURL: writeURL,
            directory: directory, directoryDescriptor: directoryDescriptor,
            directoryIdentity: directoryIdentity, logicalURL: logicalURL,
            expectation: expectation, stage: stage, nextRevision: nextRevision,
            hooks: hooks
        )
    }

    private static func decision(
        _ current: EntrySnapshot?, expectation: WriteExpectation,
        nextRevision: String
    ) throws -> WriteDecision {
        switch expectation {
        case let .revision(expected):
            guard current?.revision == expected else {
                if let current, current.revision == nextRevision {
                    return .noOp(current)
                }
                throw FileWriteFailure.conflict(actualRevision: current?.revision)
            }
        case .unconditional:
            if let current, current.revision == nextRevision {
                return .noOp(current)
            }
        }
        if let current, current.linkCount > 1 {
            throw FileWriteFailure.hardLinked
        }
        return .proceed
    }

    private static func finishNoOp(
        targetName: String, targetURL: URL, directory: URL,
        directoryDescriptor: Int32, directoryIdentity: Identity,
        logicalURL: URL, snapshot: EntrySnapshot, nextRevision: String,
        hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        var durabilityConfirmed = true
        do {
            try syncDirectory(
                directoryDescriptor, directory: directory, phase: .noOp,
                hooks: hooks
            )
        } catch {
            durabilityConfirmed = false
        }

        try validateAttachment(
            logicalURL: logicalURL, writeURL: targetURL, directory: directory,
            directoryDescriptor: directoryDescriptor,
            expectedDirectoryIdentity: directoryIdentity
        )
        let current = try readEntry(
            named: targetName, in: directoryDescriptor,
            expectedIdentity: snapshot.identity
        )
        guard current.revision == nextRevision else {
            throw FileWriteFailure.conflict(actualRevision: current.revision)
        }
        return FileWriteResult(
            revision: nextRevision, wroteBytes: false,
            durabilityConfirmed: durabilityConfirmed, cleanupCompleted: true
        )
    }

    private static func commitExisting(
        targetName: String, targetURL: URL, directory: URL,
        directoryDescriptor: Int32, directoryIdentity: Identity,
        logicalURL: URL, previous: EntrySnapshot, stage: StagedFile,
        nextRevision: String, hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        let swapFlags = UInt32(RENAME_SWAP | RENAME_SECLUDE)
        let swapResult = targetName.withCString { source in
            stage.name.withCString { destination in
                Darwin.renameatx_np(
                    directoryDescriptor, source, directoryDescriptor, destination,
                    swapFlags
                )
            }
        }
        guard swapResult == 0 else {
            let swapError = currentPOSIXError()
            stage.closeDescriptor()
            try cleanupBeforeCommit(
                stage, from: directoryDescriptor, directory: directory,
                hooks: hooks
            )
            throw swapError
        }

        // RENAME_SECLUDE applies to the source (the old target), not the
        // destination. Closing our descriptor also permits a safe rollback
        // using the newly-installed target as its secluded source.
        stage.closeDescriptor()
        let recoveryURL = directory.appendingPathComponent(
            stage.name, isDirectory: false
        )
        let displacedAtSwap: EntrySnapshot
        do {
            let installed = try readEntry(
                named: targetName, in: directoryDescriptor,
                expectedIdentity: stage.identity
            )
            guard installed.revision == nextRevision else {
                throw FileWriteFailure.conflict(
                    actualRevision: installed.revision
                )
            }
            displacedAtSwap = try readEntryPresent(
                named: stage.name, in: directoryDescriptor
            )
        } catch {
            throw FileWriteCommitFailure.stateIndeterminate(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor,
                    directory: directory
                )
            )
        }

        if displacedAtSwap.identity != previous.identity
            || displacedAtSwap.revision != previous.revision {
            try rollbackSwapIfStillOwned(
                targetName: targetName, displaced: displacedAtSwap, stage: stage,
                nextRevision: nextRevision, directory: directory,
                directoryDescriptor: directoryDescriptor, hooks: hooks
            )
            throw FileWriteFailure.conflict(
                actualRevision: displacedAtSwap.revision
            )
        }

        do {
            try hooks.afterCommitBeforeValidation?(targetURL, recoveryURL)
            try validateAttachment(
                logicalURL: logicalURL, writeURL: targetURL, directory: directory,
                directoryDescriptor: directoryDescriptor,
                expectedDirectoryIdentity: directoryIdentity
            )
            try validatePair(
                targetName: targetName, targetIdentity: stage.identity,
                targetRevision: nextRevision, artifactName: stage.name,
                artifactIdentity: previous.identity,
                artifactRevision: previous.revision,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            let validationError = error
            try rollbackSwapIfStillOwned(
                targetName: targetName, displaced: previous, stage: stage,
                nextRevision: nextRevision, directory: directory,
                directoryDescriptor: directoryDescriptor, hooks: hooks
            )
            throw validationError
        }

        do {
            try syncDirectory(
                directoryDescriptor, directory: directory, phase: .commit,
                hooks: hooks
            )
        } catch {
            do {
                try validateAttachment(
                    logicalURL: logicalURL, writeURL: targetURL,
                    directory: directory,
                    directoryDescriptor: directoryDescriptor,
                    expectedDirectoryIdentity: directoryIdentity
                )
                try validatePair(
                    targetName: targetName, targetIdentity: stage.identity,
                    targetRevision: nextRevision, artifactName: stage.name,
                    artifactIdentity: previous.identity,
                    artifactRevision: previous.revision,
                    directoryDescriptor: directoryDescriptor
                )
            } catch {
                throw FileWriteCommitFailure.stateIndeterminate(
                    recoveryArtifact: existingArtifactURL(
                        named: stage.name, in: directoryDescriptor,
                        directory: directory
                    )
                )
            }
            return FileWriteResult(
                revision: nextRevision, wroteBytes: true,
                durabilityConfirmed: false, cleanupCompleted: false,
                recoveryArtifact: recoveryURL
            )
        }

        // Detect interference during fsync before cleanup can remove the only
        // old version. At this point a successful sync did make our commit
        // durable, but the current path may already belong to another writer.
        do {
            try validateAttachment(
                logicalURL: logicalURL, writeURL: targetURL, directory: directory,
                directoryDescriptor: directoryDescriptor,
                expectedDirectoryIdentity: directoryIdentity
            )
            try validatePair(
                targetName: targetName, targetIdentity: stage.identity,
                targetRevision: nextRevision, artifactName: stage.name,
                artifactIdentity: previous.identity,
                artifactRevision: previous.revision,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            throw FileWriteCommitFailure.stateIndeterminate(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor, directory: directory
                )
            )
        }

        do {
            try hooks.beforeCleanup?(targetURL, recoveryURL)
            try securelyRemove(
                named: stage.name, expectedIdentity: previous.identity,
                from: directoryDescriptor, directory: directory,
                useSeclusion: true, hooks: hooks, syncPhase: .cleanup
            )
            return FileWriteResult(revision: nextRevision, wroteBytes: true)
        } catch let cleanup as CleanupFailure {
            return committedCleanupFailureResult(
                revision: nextRevision, cleanup: cleanup, directory: directory
            )
        } catch {
            return FileWriteResult(
                revision: nextRevision, wroteBytes: true,
                cleanupCompleted: false, recoveryArtifact: recoveryURL
            )
        }
    }

    private static func commitCreation(
        targetName: String, targetURL: URL, directory: URL,
        directoryDescriptor: Int32, directoryIdentity: Identity,
        logicalURL: URL, expectation: WriteExpectation, stage: StagedFile,
        nextRevision: String, hooks: AtomicFileWriterHooks
    ) throws -> FileWriteResult {
        let linkResult = stage.name.withCString { source in
            targetName.withCString { destination in
                Darwin.linkat(
                    directoryDescriptor, source, directoryDescriptor, destination, 0
                )
            }
        }
        guard linkResult == 0 else {
            let linkErrno = errno
            stage.closeDescriptor()
            try cleanupBeforeCommit(
                stage, from: directoryDescriptor, directory: directory,
                hooks: hooks
            )
            if linkErrno == EEXIST {
                let actual = (try? readEntryIfPresent(
                    named: targetName, in: directoryDescriptor
                ))?.revision
                switch expectation {
                case .revision:
                    throw FileWriteFailure.conflict(actualRevision: actual)
                case .unconditional:
                    // Never fall back to a path-based overwrite. A later
                    // unconditional retry will pin and exchange this target.
                    throw FileWriteFailure.conflict(actualRevision: actual)
                }
            }
            throw posixError(linkErrno)
        }

        stage.closeDescriptor()
        let recoveryURL = directory.appendingPathComponent(
            stage.name, isDirectory: false
        )
        do {
            try hooks.afterCommitBeforeValidation?(targetURL, recoveryURL)
            try validateAttachment(
                logicalURL: logicalURL, writeURL: targetURL, directory: directory,
                directoryDescriptor: directoryDescriptor,
                expectedDirectoryIdentity: directoryIdentity
            )
            try validateCreationPair(
                targetName: targetName, artifactName: stage.name,
                identity: stage.identity, revision: nextRevision,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            throw FileWriteCommitFailure.stateIndeterminate(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor, directory: directory
                )
            )
        }

        do {
            try syncDirectory(
                directoryDescriptor, directory: directory, phase: .commit,
                hooks: hooks
            )
        } catch {
            do {
                try validateAttachment(
                    logicalURL: logicalURL, writeURL: targetURL,
                    directory: directory,
                    directoryDescriptor: directoryDescriptor,
                    expectedDirectoryIdentity: directoryIdentity
                )
                try validateCreationPair(
                    targetName: targetName, artifactName: stage.name,
                    identity: stage.identity, revision: nextRevision,
                    directoryDescriptor: directoryDescriptor
                )
            } catch {
                throw FileWriteCommitFailure.stateIndeterminate(
                    recoveryArtifact: existingArtifactURL(
                        named: stage.name, in: directoryDescriptor,
                        directory: directory
                    )
                )
            }
            return FileWriteResult(
                revision: nextRevision, wroteBytes: true,
                durabilityConfirmed: false, cleanupCompleted: false,
                recoveryArtifact: recoveryURL
            )
        }

        do {
            try validateCreationPair(
                targetName: targetName, artifactName: stage.name,
                identity: stage.identity, revision: nextRevision,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            throw FileWriteCommitFailure.stateIndeterminate(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor, directory: directory
                )
            )
        }

        do {
            try hooks.beforeCleanup?(targetURL, recoveryURL)
            // The staging name and the newly-created target are hard links to
            // the same inode. RENAME_SECLUDE intentionally rejects a
            // multiply-linked source, so use an exclusive high-entropy rename
            // and validate the moved identity before unlinking the alias.
            try securelyRemove(
                named: stage.name, expectedIdentity: stage.identity,
                from: directoryDescriptor, directory: directory,
                useSeclusion: false, hooks: hooks, syncPhase: .cleanup
            )
            return FileWriteResult(revision: nextRevision, wroteBytes: true)
        } catch let cleanup as CleanupFailure {
            return committedCleanupFailureResult(
                revision: nextRevision, cleanup: cleanup, directory: directory
            )
        } catch {
            return FileWriteResult(
                revision: nextRevision, wroteBytes: true,
                cleanupCompleted: false, recoveryArtifact: recoveryURL
            )
        }
    }

    private static func validatePair(
        targetName: String, targetIdentity: Identity, targetRevision: String,
        artifactName: String, artifactIdentity: Identity,
        artifactRevision: String, directoryDescriptor: Int32
    ) throws {
        let installed = try readEntry(
            named: targetName, in: directoryDescriptor,
            expectedIdentity: targetIdentity
        )
        guard installed.revision == targetRevision else {
            throw FileWriteFailure.conflict(actualRevision: installed.revision)
        }
        let displaced = try readEntry(
            named: artifactName, in: directoryDescriptor,
            expectedIdentity: artifactIdentity
        )
        guard displaced.revision == artifactRevision else {
            throw FileWriteFailure.conflict(actualRevision: displaced.revision)
        }
    }

    private static func validateCreationPair(
        targetName: String, artifactName: String, identity: Identity,
        revision: String, directoryDescriptor: Int32
    ) throws {
        let installed = try readEntry(
            named: targetName, in: directoryDescriptor, expectedIdentity: identity
        )
        let alias = try readEntry(
            named: artifactName, in: directoryDescriptor, expectedIdentity: identity
        )
        guard installed.revision == revision, alias.revision == revision else {
            throw FileWriteFailure.conflict(actualRevision: installed.revision)
        }
    }

    private static func rollbackSwapIfStillOwned(
        targetName: String, displaced: EntrySnapshot, stage: StagedFile,
        nextRevision: String, directory: URL, directoryDescriptor: Int32,
        hooks: AtomicFileWriterHooks
    ) throws {
        do {
            try validatePair(
                targetName: targetName, targetIdentity: stage.identity,
                targetRevision: nextRevision, artifactName: stage.name,
                artifactIdentity: displaced.identity,
                artifactRevision: displaced.revision,
                directoryDescriptor: directoryDescriptor
            )
            let swapFlags = UInt32(RENAME_SWAP | RENAME_SECLUDE)
            let result = targetName.withCString { source in
                stage.name.withCString { destination in
                    Darwin.renameatx_np(
                        directoryDescriptor, source, directoryDescriptor,
                        destination, swapFlags
                    )
                }
            }
            guard result == 0 else { throw currentPOSIXError() }
            try validatePair(
                targetName: targetName, targetIdentity: displaced.identity,
                targetRevision: displaced.revision, artifactName: stage.name,
                artifactIdentity: stage.identity, artifactRevision: nextRevision,
                directoryDescriptor: directoryDescriptor
            )
            try syncDirectory(
                directoryDescriptor, directory: directory, phase: .rollback,
                hooks: hooks
            )
        } catch {
            throw FileWriteCommitFailure.stateIndeterminate(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor,
                    directory: directory
                )
            )
        }
        try cleanupBeforeCommit(
            stage, from: directoryDescriptor, directory: directory,
            hooks: hooks
        )
    }

    private static func cleanupBeforeCommit(
        _ stage: StagedFile, from directoryDescriptor: Int32,
        directory: URL, hooks: AtomicFileWriterHooks
    ) throws {
        let originalURL = directory.appendingPathComponent(
            stage.name, isDirectory: false
        )
        do {
            try hooks.beforePrecommitCleanup?(originalURL)
            try securelyRemove(
                named: stage.name, expectedIdentity: stage.identity,
                from: directoryDescriptor, directory: directory,
                useSeclusion: true, hooks: hooks,
                syncPhase: .precommitCleanup
            )
        } catch let cleanup as CleanupFailure {
            throw FileWriteCommitFailure.cleanupFailedBeforeCommit(
                recoveryArtifact: cleanup.artifactName.map {
                    directory.appendingPathComponent($0, isDirectory: false)
                }
            )
        } catch {
            throw FileWriteCommitFailure.cleanupFailedBeforeCommit(
                recoveryArtifact: existingArtifactURL(
                    named: stage.name, in: directoryDescriptor,
                    directory: directory
                )
            )
        }
    }

    private static func securelyRemove(
        named sourceName: String, expectedIdentity: Identity,
        from directoryDescriptor: Int32, directory: URL, useSeclusion: Bool,
        hooks: AtomicFileWriterHooks,
        syncPhase: AtomicFileWriterDirectorySyncPhase
    ) throws {
        guard entryIdentity(
            named: sourceName, in: directoryDescriptor
        ) == expectedIdentity else {
            throw CleanupFailure(artifactName: sourceName)
        }

        let cleanupName = freshArtifactName(kind: "cleanup")
        let flags = UInt32(RENAME_EXCL)
            | (useSeclusion ? UInt32(RENAME_SECLUDE) : 0)
        let renameResult = sourceName.withCString { source in
            cleanupName.withCString { destination in
                Darwin.renameatx_np(
                    directoryDescriptor, source, directoryDescriptor, destination,
                    flags
                )
            }
        }
        guard renameResult == 0 else {
            throw CleanupFailure(artifactName: sourceName)
        }
        guard entryIdentity(
            named: cleanupName, in: directoryDescriptor
        ) == expectedIdentity else {
            throw CleanupFailure(artifactName: cleanupName)
        }
        let unlinkResult = cleanupName.withCString { component in
            Darwin.unlinkat(directoryDescriptor, component, 0)
        }
        guard unlinkResult == 0 else {
            throw CleanupFailure(artifactName: cleanupName)
        }
        do {
            try syncDirectory(
                directoryDescriptor, directory: directory, phase: syncPhase,
                hooks: hooks
            )
        } catch {
            // unlink succeeded, so there is no longer a name that can honestly
            // be advertised as a recovery artifact. The committed outcome
            // still reports the cleanup durability failure explicitly.
            throw CleanupFailure(artifactName: nil)
        }
    }

    private static func committedCleanupFailureResult(
        revision: String, cleanup: CleanupFailure, directory: URL
    ) -> FileWriteResult {
        let artifactURL = cleanup.artifactName.map {
            directory.appendingPathComponent($0, isDirectory: false)
        }
        return FileWriteResult(
            revision: revision, wroteBytes: true,
            cleanupCompleted: false, recoveryArtifact: artifactURL
        )
    }

    private static func createStagedFile(
        in directoryDescriptor: Int32, directory: URL,
        hooks: AtomicFileWriterHooks
    ) throws -> StagedFile {
        for _ in 0..<8 {
            let name = freshArtifactName(kind: "staging")
            let descriptor = name.withCString { component in
                Darwin.openat(
                    directoryDescriptor, component,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o666)
                )
            }
            if descriptor >= 0 {
                let artifactURL = directory.appendingPathComponent(
                    name, isDirectory: false
                )
                do {
                    try hooks.beforeStagedIdentityRead?(artifactURL)
                    return StagedFile(
                        descriptor: descriptor, name: name,
                        identity: try descriptorIdentity(descriptor)
                    )
                } catch {
                    let originalError = error
                    let createdIdentity = try? descriptorIdentity(descriptor)
                    _ = Darwin.close(descriptor)
                    guard let createdIdentity else {
                        throw FileWriteCommitFailure.cleanupFailedBeforeCommit(
                            recoveryArtifact: artifactURL
                        )
                    }
                    let created = StagedFile(
                        descriptor: -1, name: name, identity: createdIdentity
                    )
                    try cleanupBeforeCommit(
                        created, from: directoryDescriptor, directory: directory,
                        hooks: hooks
                    )
                    throw originalError
                }
            }
            if errno != EEXIST { throw currentPOSIXError() }
        }
        throw POSIXError(.EEXIST)
    }

    private static func validateStagedFile(
        _ stage: StagedFile, in directoryDescriptor: Int32, revision: String
    ) throws {
        guard try descriptorIdentity(stage.descriptor) == stage.identity else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        let snapshot = try readEntry(
            named: stage.name, in: directoryDescriptor,
            expectedIdentity: stage.identity
        )
        guard snapshot.linkCount == 1, snapshot.revision == revision else {
            throw FileWriteFailure.conflict(actualRevision: snapshot.revision)
        }
    }

    private static func readEntryIfPresent(
        named name: String, in directoryDescriptor: Int32
    ) throws -> EntrySnapshot? {
        let descriptor = name.withCString { component in
            Darwin.openat(
                directoryDescriptor, component, O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw currentPOSIXError()
        }
        defer { _ = Darwin.close(descriptor) }
        return try readDescriptor(descriptor)
    }

    private static func readEntry(
        named name: String, in directoryDescriptor: Int32,
        expectedIdentity: Identity
    ) throws -> EntrySnapshot {
        guard let snapshot = try readEntryIfPresent(
            named: name, in: directoryDescriptor
        ), snapshot.identity == expectedIdentity else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        return snapshot
    }

    private static func readEntryPresent(
        named name: String, in directoryDescriptor: Int32
    ) throws -> EntrySnapshot {
        guard let snapshot = try readEntryIfPresent(
            named: name, in: directoryDescriptor
        ) else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        return snapshot
    }

    private static func readDescriptor(_ descriptor: Int32) throws -> EntrySnapshot {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw currentPOSIXError()
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }

        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw currentPOSIXError()
        }
        var data = Data()
        if before.st_size > 0, before.st_size <= off_t(Int.max) {
            data.reserveCapacity(Int(before.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            data.append(contentsOf: buffer[0..<count])
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw currentPOSIXError()
        }
        let beforeIdentity = identity(of: before)
        guard beforeIdentity == identity(of: after),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
        return EntrySnapshot(
            identity: beforeIdentity,
            revision: TextFileCodec.revision(of: data),
            permissions: before.st_mode & mode_t(0o7777),
            linkCount: UInt64(before.st_nlink)
        )
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
                    throw currentPOSIXError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private static func syncDirectory(
        _ descriptor: Int32, directory: URL,
        phase: AtomicFileWriterDirectorySyncPhase, hooks: AtomicFileWriterHooks
    ) throws {
        try hooks.beforeDirectorySync?(directory, phase)
        try synchronize(descriptor)
    }

    private static func validateAttachment(
        logicalURL: URL, writeURL: URL, directory: URL,
        directoryDescriptor: Int32, expectedDirectoryIdentity: Identity
    ) throws {
        guard logicalURL.resolvingSymlinksInPath().standardizedFileURL.path
                == writeURL.path,
              pathIdentity(directory) == expectedDirectoryIdentity,
              try descriptorIdentity(directoryDescriptor)
                == expectedDirectoryIdentity else {
            throw FileWriteFailure.conflict(actualRevision: nil)
        }
    }

    private static func descriptorIdentity(_ descriptor: Int32) throws -> Identity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw currentPOSIXError()
        }
        return identity(of: status)
    }

    private static func entryIdentity(
        named name: String, in directoryDescriptor: Int32
    ) -> Identity? {
        var status = stat()
        let result = name.withCString { component in
            Darwin.fstatat(
                directoryDescriptor, component, &status, AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return nil
        }
        return identity(of: status)
    }

    private static func pathIdentity(_ url: URL) -> Identity? {
        var status = stat()
        guard Darwin.stat(url.path, &status) == 0 else { return nil }
        return identity(of: status)
    }

    private static func identity(of status: stat) -> Identity {
        Identity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func existingArtifactURL(
        named name: String, in directoryDescriptor: Int32, directory: URL
    ) -> URL? {
        guard entryIdentity(named: name, in: directoryDescriptor) != nil else {
            return nil
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func freshArtifactName(kind: String) -> String {
        let entropy = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return artifactPrefix + kind + "-" + entropy
    }

    private static func isRevision(_ value: String) -> Bool {
        guard value.count == 71, value.hasPrefix("sha256:") else { return false }
        return value.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func currentPOSIXError() -> POSIXError {
        posixError(errno)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
