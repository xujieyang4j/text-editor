import Foundation
import Darwin
import XCTest
@testable import LumenEditorCore

final class AtomicFileWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesOnlyWhenDestinationIsMissing() throws {
        let url = directory.appendingPathComponent("new.txt")
        let result = try AtomicFileWriter.write(Data("first".utf8), to: url, expectedRevision: nil)

        XCTAssertTrue(result.wroteBytes)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first")
        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("second".utf8), to: url, expectedRevision: nil)
        ) { error in
            guard case FileWriteFailure.conflict = error else {
                return XCTFail("Expected a conflict, got \(error)")
            }
        }
    }

    func testMissingParentDirectoryIsNotCreated() throws {
        let missingParent = directory.appendingPathComponent(
            "missing/child", isDirectory: true
        )
        let url = missingParent.appendingPathComponent("new.txt")

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("new".utf8), to: url, expectedRevision: nil
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingParent.path)
        )
    }

    func testExclusiveCreateLeavesExistingDestinationUntouched() throws {
        let url = directory.appendingPathComponent("raced.txt")
        try Data("other writer".utf8).write(to: url)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("local".utf8), to: url, expectedRevision: nil)
        ) { error in
            guard case FileWriteFailure.conflict = error else {
                return XCTFail("Expected a conflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "other writer")
    }

    func testRejectsStaleRevisionWithoutChangingFile() throws {
        let url = directory.appendingPathComponent("existing.txt")
        try Data("base".utf8).write(to: url)
        let baseRevision = TextFileCodec.revision(of: Data("base".utf8))
        try Data("external".utf8).write(to: url)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("local".utf8), to: url, expectedRevision: baseRevision)
        ) { error in
            guard case FileWriteFailure.conflict = error else {
                return XCTFail("Expected a conflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    func testAcceptsMatchingRevision() throws {
        let url = directory.appendingPathComponent("existing.txt")
        let original = Data("base".utf8)
        try original.write(to: url)

        let result = try AtomicFileWriter.write(
            Data("next".utf8),
            to: url,
            expectedRevision: TextFileCodec.revision(of: original)
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "next")
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testMatchingExpectedAndReplacementRevisionIsANoOp() throws {
        let url = directory.appendingPathComponent("unchanged.txt")
        let original = Data("same".utf8)
        try original.write(to: url)
        let inodeBefore = try inode(of: url)

        let result = try AtomicFileWriter.write(
            original, to: url,
            expectedRevision: TextFileCodec.revision(of: original)
        )

        XCTAssertFalse(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try inode(of: url), inodeBefore)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testStaleExpectedRevisionIsANoOpWhenReplacementAlreadyMatches() throws {
        let url = directory.appendingPathComponent("already-written.txt")
        let original = Data("base".utf8)
        let replacement = Data("desired".utf8)
        try original.write(to: url)
        let expectedRevision = TextFileCodec.revision(of: original)
        try replacement.write(to: url)
        let inodeBefore = try inode(of: url)

        let result = try AtomicFileWriter.write(
            replacement, to: url, expectedRevision: expectedRevision
        )

        XCTAssertFalse(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.cleanupRecoveryArtifact)
        XCTAssertEqual(result.revision, TextFileCodec.revision(of: replacement))
        XCTAssertEqual(try inode(of: url), inodeBefore)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testNoOpCleanupStateDoesNotDescribeHistoricalArtifacts() throws {
        let url = directory.appendingPathComponent("historical-artifact.txt")
        let historical = directory.appendingPathComponent(
            ".lumen-atomic-write-historical"
        )
        let data = Data("same".utf8)
        try data.write(to: url)
        try Data("old recovery".utf8).write(to: historical)

        let result = try AtomicFileWriter.writeUnconditionally(data, to: url)

        XCTAssertFalse(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try Data(contentsOf: historical), Data("old recovery".utf8))
    }

    func testNoOpDirectorySyncFailureReturnsExplicitDurabilityState() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("no-op-sync.txt")
        let data = Data("same".utf8)
        try data.write(to: url)
        let inodeBefore = try inode(of: url)

        let result = try AtomicFileWriter.write(
            data, to: url, expectedRevision: TextFileCodec.revision(of: data),
            hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                if case .noOp = phase { throw InjectedSyncFailure() }
            })
        )

        XCTAssertFalse(result.wroteBytes)
        XCTAssertFalse(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try inode(of: url), inodeBefore)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testNoOpSyncFailureRevalidatesTargetIdentity() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("no-op-sync-race.txt")
        let displaced = directory.appendingPathComponent("displaced-no-op.txt")
        let external = directory.appendingPathComponent("external-no-op.txt")
        let original = Data("same".utf8)
        let winner = Data("external winner".utf8)
        try original.write(to: url)
        try winner.write(to: external)

        XCTAssertThrowsError(
            try AtomicFileWriter.writeUnconditionally(
                original, to: url,
                hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                    guard case .noOp = phase else { return }
                    try FileManager.default.moveItem(at: url, to: displaced)
                    try FileManager.default.moveItem(at: external, to: url)
                    throw InjectedSyncFailure()
                })
            )
        ) { error in
            guard case FileWriteFailure.conflict = error else {
                return XCTFail("Expected a conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testFinalRevisionNoOpSynchronizesAfterCleaningItsStagingFile() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("final-no-op-sync.txt")
        let external = directory.appendingPathComponent("desired.txt")
        let original = Data("base".utf8)
        let replacement = Data("desired".utf8)
        try original.write(to: url)
        try replacement.write(to: external)

        let result = try AtomicFileWriter.write(
            replacement, to: url,
            expectedRevision: TextFileCodec.revision(of: original),
            hooks: AtomicFileWriterHooks(
                afterInitialValidation: { target in
                    try FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: external, to: target)
                },
                beforeDirectorySync: { _, phase in
                    if case .noOp = phase { throw InjectedSyncFailure() }
                }
            )
        )

        XCTAssertFalse(result.wroteBytes)
        XCTAssertFalse(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testSavingThroughSymbolicLinkPreservesTheLink() throws {
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("alias.txt")
        let original = Data("base".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try AtomicFileWriter.write(
            Data("next".utf8),
            to: link,
            expectedRevision: TextFileCodec.revision(of: original)
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "next")
    }

    func testRejectsHardLinkedTargetWithoutChangingEitherName() throws {
        let originalURL = directory.appendingPathComponent("original.txt")
        let linkedURL = directory.appendingPathComponent("linked.txt")
        let original = Data("base".utf8)
        try original.write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("next".utf8),
                to: linkedURL,
                expectedRevision: TextFileCodec.revision(of: original)
            )
        ) { error in
            XCTAssertEqual(error as? FileWriteFailure, .hardLinked)
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertEqual(try Data(contentsOf: linkedURL), original)
    }

    func testPreopenedTargetMakesSecludedSwapFailWithoutChangingFile() throws {
        let url = directory.appendingPathComponent("preopened.txt")
        let original = Data("base".utf8)
        try original.write(to: url)
        let inodeBefore = try inode(of: url)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("next".utf8), to: url,
                expectedRevision: TextFileCodec.revision(of: original)
            )
        )

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try inode(of: url), inodeBefore)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testPreservesPOSIXPermissions() throws {
        let url = directory.appendingPathComponent("script.sh")
        let original = Data("#!/bin/sh\nexit 0\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o751],
            ofItemAtPath: url.path
        )

        _ = try AtomicFileWriter.write(
            Data("#!/bin/sh\nexit 1\n".utf8),
            to: url,
            expectedRevision: TextFileCodec.revision(of: original)
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
    }

    func testBrokenSymbolicLinkIsNotReplacedByARegularFile() throws {
        let missingTarget = directory.appendingPathComponent("missing.txt")
        let link = directory.appendingPathComponent("broken.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("new".utf8), to: link, expectedRevision: nil)
        ) { error in
            guard case FileWriteFailure.conflict = error else {
                return XCTFail("Expected a conflict, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            missingTarget.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testDirectorySyncFailureRetainsBothCompleteVersions() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("sync-failure.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        try original.write(to: url)
        let result = try AtomicFileWriter.write(
            replacement, to: url,
            expectedRevision: TextFileCodec.revision(of: original),
            hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                if case .commit = phase { throw InjectedSyncFailure() }
            })
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertFalse(result.durabilityConfirmed)
        XCTAssertFalse(result.cleanupCompleted)
        XCTAssertEqual(result.revision, TextFileCodec.revision(of: replacement))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        let artifact = try XCTUnwrap(result.recoveryArtifact)
        XCTAssertEqual(try Data(contentsOf: artifact), original)
    }

    func testExistingCommitSyncFailureRevalidatesInterferingTarget() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("existing-sync-race.txt")
        let installed = directory.appendingPathComponent("writer-version.txt")
        let external = directory.appendingPathComponent("external-source.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        let winner = Data("external winner".utf8)
        try original.write(to: url)
        try winner.write(to: external)
        var recoveryArtifact: URL?

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                replacement, to: url,
                expectedRevision: TextFileCodec.revision(of: original),
                hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                    guard case .commit = phase else { return }
                    try FileManager.default.moveItem(at: url, to: installed)
                    try FileManager.default.moveItem(at: external, to: url)
                    throw InjectedSyncFailure()
                })
            )
        ) { error in
            guard case let FileWriteCommitFailure.stateIndeterminate(artifact) = error else {
                return XCTFail("Expected indeterminate state, got \(error)")
            }
            recoveryArtifact = artifact
        }

        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertEqual(try Data(contentsOf: installed), replacement)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recoveryArtifact)), original)
    }

    func testCreationCommitSyncFailureRevalidatesInterferingTarget() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("creation-sync-race.txt")
        let installed = directory.appendingPathComponent("created-version.txt")
        let external = directory.appendingPathComponent("external-create.txt")
        let replacement = Data("next".utf8)
        let winner = Data("external winner".utf8)
        try winner.write(to: external)
        var recoveryArtifact: URL?

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                replacement, to: url, expectedRevision: nil,
                hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                    guard case .commit = phase else { return }
                    try FileManager.default.moveItem(at: url, to: installed)
                    try FileManager.default.moveItem(at: external, to: url)
                    throw InjectedSyncFailure()
                })
            )
        ) { error in
            guard case let FileWriteCommitFailure.stateIndeterminate(artifact) = error else {
                return XCTFail("Expected indeterminate state, got \(error)")
            }
            recoveryArtifact = artifact
        }

        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertEqual(try Data(contentsOf: installed), replacement)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recoveryArtifact)), replacement)
    }

    func testCleanupFailureReturnsCommittedResultAndPreservesOldVersion() throws {
        let url = directory.appendingPathComponent("cleanup-failure.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        try original.write(to: url)
        let heldArtifact = AtomicWriterHeldDescriptor()
        defer { heldArtifact.close() }

        let result = try AtomicFileWriter.write(
            replacement, to: url,
            expectedRevision: TextFileCodec.revision(of: original),
            hooks: AtomicFileWriterHooks(beforeCleanup: { _, artifact in
                try heldArtifact.open(artifact)
            })
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertFalse(result.cleanupCompleted)
        XCTAssertEqual(result.revision, TextFileCodec.revision(of: replacement))
        let artifact = try XCTUnwrap(result.cleanupRecoveryArtifact)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try Data(contentsOf: artifact), original)
    }

    func testCleanupDirectorySyncFailureIsReportedInCommittedResult() throws {
        struct InjectedSyncFailure: Error {}

        let url = directory.appendingPathComponent("cleanup-sync.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        try original.write(to: url)

        let result = try AtomicFileWriter.write(
            replacement, to: url,
            expectedRevision: TextFileCodec.revision(of: original),
            hooks: AtomicFileWriterHooks(beforeDirectorySync: { _, phase in
                if case .cleanup = phase { throw InjectedSyncFailure() }
            })
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertFalse(result.cleanupCompleted)
        XCTAssertNil(result.recoveryArtifact)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testPrecommitCleanupFailureIsTypedAndRetainsStagingArtifact() throws {
        struct InjectedWriteFailure: Error {}

        let url = directory.appendingPathComponent("precommit-cleanup.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        try original.write(to: url)
        let heldArtifact = AtomicWriterHeldDescriptor()
        defer { heldArtifact.close() }
        var recoveryArtifact: URL?

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                replacement, to: url,
                expectedRevision: TextFileCodec.revision(of: original),
                hooks: AtomicFileWriterHooks(
                    beforeCommit: { _ in throw InjectedWriteFailure() },
                    beforePrecommitCleanup: { artifact in
                        try heldArtifact.open(artifact)
                    }
                )
            )
        ) { error in
            guard case let FileWriteCommitFailure.cleanupFailedBeforeCommit(
                artifact
            ) = error else {
                return XCTFail("Expected typed cleanup failure, got \(error)")
            }
            recoveryArtifact = artifact
        }

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(recoveryArtifact)), replacement
        )
    }

    func testStagingIdentityFailureCleansCreatedArtifact() throws {
        struct InjectedIdentityFailure: Error {}

        let url = directory.appendingPathComponent("identity-failure.txt")

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("next".utf8), to: url, expectedRevision: nil,
                hooks: AtomicFileWriterHooks(
                    beforeStagedIdentityRead: { _ in
                        throw InjectedIdentityFailure()
                    }
                )
            )
        ) { error in
            XCTAssertTrue(error is InjectedIdentityFailure)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testReplacementAfterFinalSnapshotIsRestoredAsConflict() throws {
        let url = directory.appendingPathComponent("pre-swap-race.txt")
        let displacedOriginal = directory.appendingPathComponent("displaced-base.txt")
        let external = directory.appendingPathComponent("external-winner.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        let winner = Data("external winner".utf8)
        try original.write(to: url)
        try winner.write(to: external)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                replacement, to: url,
                expectedRevision: TextFileCodec.revision(of: original),
                hooks: AtomicFileWriterHooks(
                    afterFinalSnapshotBeforeCommit: { target in
                        try FileManager.default.moveItem(
                            at: target, to: displacedOriginal
                        )
                        try FileManager.default.moveItem(at: external, to: target)
                    }
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? FileWriteFailure,
                .conflict(actualRevision: TextFileCodec.revision(of: winner))
            )
        }

        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertEqual(try Data(contentsOf: displacedOriginal), original)
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testPostSwapTargetReplacementPreservesEveryCompleteVersion() throws {
        let url = directory.appendingPathComponent("post-swap.txt")
        let external = directory.appendingPathComponent("external.txt")
        let installed = directory.appendingPathComponent("installed-by-writer.txt")
        let original = Data("base".utf8)
        let replacement = Data("next".utf8)
        let externalData = Data("external winner".utf8)
        try original.write(to: url)
        try externalData.write(to: external)
        var recoveryArtifact: URL?

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                replacement, to: url,
                expectedRevision: TextFileCodec.revision(of: original),
                hooks: AtomicFileWriterHooks(
                    afterCommitBeforeValidation: { target, _ in
                        try FileManager.default.moveItem(at: target, to: installed)
                        try FileManager.default.moveItem(at: external, to: target)
                    }
                )
            )
        ) { error in
            guard case let FileWriteCommitFailure.stateIndeterminate(artifact) = error else {
                return XCTFail("Expected an indeterminate commit, got \(error)")
            }
            recoveryArtifact = artifact
        }

        XCTAssertEqual(try Data(contentsOf: url), externalData)
        XCTAssertEqual(try Data(contentsOf: installed), replacement)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recoveryArtifact)), original)
    }

    func testUnconditionalExistingWriteUsesProtectedReplacement() throws {
        let url = directory.appendingPathComponent("unconditional.txt")
        try Data("base".utf8).write(to: url)

        let result = try AtomicFileWriter.writeUnconditionally(
            Data("next".utf8), to: url
        )

        XCTAssertTrue(result.wroteBytes)
        XCTAssertTrue(result.durabilityConfirmed)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertNil(result.cleanupRecoveryArtifact)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "next")
        XCTAssertTrue(try writerArtifacts().isEmpty)
    }

    func testExclusiveTransactionSerializesOrdinaryWrites() async throws {
        let url = directory.appendingPathComponent("serialized.txt")
        let original = Data("base".utf8)
        try original.write(to: url)
        let entered = expectation(description: "exclusive transaction entered")
        let mayFinish = DispatchSemaphore(value: 0)
        let transaction = Task.detached {
            AtomicFileWriter.withExclusiveTransaction {
                entered.fulfill()
                mayFinish.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 1)

        let writeAttempted = DispatchSemaphore(value: 0)
        let lockProbe = AtomicWriterLockProbe()
        let ordinaryWrite = Task.detached {
            return try AtomicFileWriter.write(
                Data("next".utf8), to: url,
                expectedRevision: TextFileCodec.revision(of: original),
                hooks: AtomicFileWriterHooks(
                    beforeAcquiringWriteLock: { writeAttempted.signal() },
                    afterAcquiringWriteLock: { lockProbe.markAcquired() }
                )
            )
        }
        XCTAssertEqual(writeAttempted.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(lockProbe.didAcquire)
        XCTAssertEqual(try Data(contentsOf: url), original)

        mayFinish.signal()
        await transaction.value
        let writeResult = try await ordinaryWrite.value
        XCTAssertTrue(writeResult.wroteBytes)
        XCTAssertTrue(lockProbe.didAcquire)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "next")
    }

    private func writerArtifacts() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".lumen-atomic-write-") }
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

private final class AtomicWriterHeldDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    func open(_ url: URL) throws {
        let opened = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard opened >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lock.lock()
        descriptor = opened
        lock.unlock()
    }

    func close() {
        lock.lock()
        let opened = descriptor
        descriptor = -1
        lock.unlock()
        if opened >= 0 { _ = Darwin.close(opened) }
    }

    deinit { close() }
}

private final class AtomicWriterLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false

    var didAcquire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return acquired
    }

    func markAcquired() {
        lock.lock()
        acquired = true
        lock.unlock()
    }
}
