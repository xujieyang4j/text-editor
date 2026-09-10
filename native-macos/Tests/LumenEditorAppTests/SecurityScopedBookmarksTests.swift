import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class SecurityScopedBookmarksTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testStoreMatchesExactFilesAndDirectoryDescendants() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let project = URL(fileURLWithPath: "/tmp/lumen-project", isDirectory: true)
        let standalone = URL(fileURLWithPath: "/tmp/standalone.txt")
        _ = try store.record(Data("directory".utf8), for: project, kind: .directory)
        _ = try store.record(Data("file".utf8), for: standalone, kind: .file)

        let child = project.appendingPathComponent("Sources/main.swift")
        XCTAssertEqual(
            store.match(
                for: child, kind: .file, allowingDirectoryAncestor: true
            )?.record.kind,
            .directory
        )
        XCTAssertNil(store.match(
            for: child, kind: .file, allowingDirectoryAncestor: false
        ))
        XCTAssertEqual(store.match(
            for: standalone, kind: .file, allowingDirectoryAncestor: true
        )?.record.bookmarkData, Data("file".utf8))
    }

    func testStoreEvictsOldestRecordsWithinBounds() throws {
        let directory = temporaryDirectory()
        let limits = SecurityScopedBookmarkStore.Limits(
            maximumRecords: 2, maximumBookmarkBytes: 32,
            maximumTotalBookmarkBytes: 64, maximumSerializedBytes: 4_096,
            maximumAliasesPerRecord: 2
        )
        let store = SecurityScopedBookmarkStore(
            directoryURL: directory, limits: limits
        )
        for index in 0..<3 {
            _ = try store.record(
                Data("bookmark-\(index)".utf8),
                for: URL(fileURLWithPath: "/tmp/file-\(index)"),
                kind: .file,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(store.records().map(\.path), ["/tmp/file-2", "/tmp/file-1"])
        XCTAssertLessThanOrEqual(
            (try FileManager.default.attributesOfItem(
                atPath: store.fileURL.path
            )[.size] as? NSNumber)?.intValue ?? Int.max,
            limits.maximumSerializedBytes
        )
    }

    func testConcurrentStoreInstancesDoNotLoseRecords() {
        let directory = temporaryDirectory()
        let queue = DispatchQueue(
            label: "SecurityScopedBookmarksTests.concurrent",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        for index in 0..<32 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let store = SecurityScopedBookmarkStore(directoryURL: directory)
                _ = try? store.record(
                    Data("bookmark-\(index)".utf8),
                    for: URL(fileURLWithPath: "/tmp/concurrent-\(index)"),
                    kind: .file,
                    at: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
        }
        group.wait()

        XCTAssertEqual(
            SecurityScopedBookmarkStore(directoryURL: directory).records().count,
            32
        )
    }

    func testRefreshRetainsOldPathAsBoundedAlias() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/old-project", isDirectory: true)
        let newURL = URL(fileURLWithPath: "/tmp/new-project", isDirectory: true)
        _ = try store.record(Data("old".utf8), for: oldURL, kind: .directory)
        let match = try XCTUnwrap(store.match(
            for: oldURL, kind: .directory, allowingDirectoryAncestor: false
        ))

        let refreshed = try store.refresh(
            match, bookmarkData: Data("new".utf8), resolvedURL: newURL
        )

        XCTAssertEqual(refreshed.path, newURL.path)
        XCTAssertEqual(refreshed.aliases, [oldURL.path])
        XCTAssertEqual(store.match(
            for: oldURL.appendingPathComponent("README.md"),
            kind: .file, allowingDirectoryAncestor: true
        )?.matchedPath, oldURL.path)
    }

    func testRebaseExactFileKeepsTokenAndOldPathAlias() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/project/Folder/link.txt")
        let newURL = URL(fileURLWithPath: "/tmp/moved/Folder/link.txt")
        let token = Data("exact-target-token".utf8)
        _ = try store.record(token, for: oldURL, kind: .file)

        let rebased = try XCTUnwrap(store.rebaseExactFile(from: oldURL, to: newURL))

        XCTAssertEqual(rebased.path, newURL.path)
        XCTAssertEqual(rebased.aliases, [oldURL.path])
        XCTAssertEqual(rebased.bookmarkData, token)
        XCTAssertEqual(
            store.match(for: newURL, kind: .file, allowingDirectoryAncestor: true)?
                .record.bookmarkData,
            token
        )
    }

    func testExactFileMatchWinsOverAncestorAfterRebase() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/project/Folder/link.txt")
        let movedRoot = URL(fileURLWithPath: "/tmp/moved/Folder", isDirectory: true)
        let newURL = movedRoot.appendingPathComponent("link.txt")
        _ = try store.record(Data("directory".utf8), for: movedRoot, kind: .directory)
        _ = try store.record(
            Data("exact".utf8), for: oldURL, kind: .file,
            preservingDirectoryCoveredFile: true
        )
        _ = try store.rebaseExactFile(from: oldURL, to: newURL)

        let match = store.match(
            for: newURL, kind: .file, allowingDirectoryAncestor: true
        )

        XCTAssertEqual(match?.record.kind, .file)
        XCTAssertEqual(match?.record.bookmarkData, Data("exact".utf8))
    }

    func testRebaseConflictPreservesBothExactFileRecords() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/old.txt")
        let occupiedURL = URL(fileURLWithPath: "/tmp/occupied.txt")
        _ = try store.record(Data("old".utf8), for: oldURL, kind: .file)
        _ = try store.record(Data("occupied".utf8), for: occupiedURL, kind: .file)

        XCTAssertThrowsError(try store.rebaseExactFile(
            from: oldURL, to: occupiedURL
        )) { error in
            XCTAssertEqual(
                error as? SecurityScopedBookmarkStoreError,
                .pathConflict(occupiedURL.path)
            )
        }

        XCTAssertEqual(store.match(
            for: oldURL, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data("old".utf8))
        XCTAssertEqual(store.match(
            for: occupiedURL, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data("occupied".utf8))
    }

    func testPreparedRebaseIsInvisibleUntilCommitAndAbortRestoresSnapshot() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/transaction-old.txt")
        let newURL = URL(fileURLWithPath: "/tmp/transaction-new.txt")
        let token = Data("token".utf8)
        _ = try store.record(token, for: oldURL, kind: .file)
        let before = store.records()

        let prepared = try XCTUnwrap(store.prepareExactFileRebases([
            .init(source: oldURL, destination: newURL)
        ]))
        XCTAssertEqual(store.records(), before)
        XCTAssertNil(store.match(
            for: newURL, kind: .file, allowingDirectoryAncestor: false
        ))
        XCTAssertThrowsError(try store.record(
            Data("blocked".utf8), for: URL(fileURLWithPath: "/tmp/blocked.txt"),
            kind: .file
        )) { error in
            XCTAssertEqual(
                error as? SecurityScopedBookmarkStoreError, .transactionInProgress
            )
        }

        try prepared.abort()

        XCTAssertEqual(store.records(), before)
        XCTAssertNil(store.match(
            for: newURL, kind: .file, allowingDirectoryAncestor: false
        ))
        XCTAssertEqual(store.match(
            for: oldURL, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, token)
    }

    func testPreparedRebaseCommitPublishesAllNewPathsTogether() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let first = URL(fileURLWithPath: "/tmp/batch-first.txt")
        let second = URL(fileURLWithPath: "/tmp/batch-second.txt")
        let movedFirst = URL(fileURLWithPath: "/tmp/moved/batch-first.txt")
        let movedSecond = URL(fileURLWithPath: "/tmp/moved/batch-second.txt")
        _ = try store.record(Data("first".utf8), for: first, kind: .file)
        _ = try store.record(Data("second".utf8), for: second, kind: .file)
        let prepared = try XCTUnwrap(store.prepareExactFileRebases([
            .init(source: first, destination: movedFirst),
            .init(source: second, destination: movedSecond)
        ]))

        XCTAssertNil(store.match(
            for: movedFirst, kind: .file, allowingDirectoryAncestor: false
        ))
        XCTAssertNil(store.match(
            for: movedSecond, kind: .file, allowingDirectoryAncestor: false
        ))

        prepared.commit()

        XCTAssertEqual(store.match(
            for: movedFirst, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data("first".utf8))
        XCTAssertEqual(store.match(
            for: movedSecond, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data("second".utf8))
    }

    func testPreparedRebaseRecoversOldSnapshotAfterInterruptedFailedMove() throws {
        let directory = temporaryDirectory()
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: oldURL)
        var prepared: PreparedSecurityScopedBookmarkRebase?
        do {
            let store = SecurityScopedBookmarkStore(directoryURL: directory)
            _ = try store.record(Data(oldURL.path.utf8), for: oldURL, kind: .file)
            prepared = try store.prepareExactFileRebases([
                .init(source: oldURL, destination: newURL)
            ])
        }

        // Simulate the next process reading a pending transaction after the
        // filesystem move did not happen. The persisted before-image wins.
        prepared = nil
        let interrupted = SecurityScopedBookmarkStore(directoryURL: directory)
        let interruptedPrepared = try XCTUnwrap(interrupted.prepareExactFileRebases([
            .init(source: oldURL, destination: newURL)
        ]))
        interrupted.simulateProcessRestartForTesting()
        let restored = SecurityScopedBookmarkStore(directoryURL: directory)
        XCTAssertEqual(restored.match(
            for: oldURL, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data(oldURL.path.utf8))
        XCTAssertNil(restored.match(
            for: newURL, kind: .file, allowingDirectoryAncestor: false
        ))
        _ = interruptedPrepared
    }

    func testStalePreparedAliasCannotOpenAnUnrelatedDestination() throws {
        let directory = temporaryDirectory()
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: oldURL)
        try Data("unrelated".utf8).write(to: newURL)
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let provider = FakeBookmarkProvider()
        let controller = SecurityScopedAccessController(
            store: store, provider: provider, requiresSecurityScope: { true }
        )
        let originalLease = try controller.accessUserSelectedURL(oldURL, kind: .file)
        originalLease.invalidate()
        let prepared = try XCTUnwrap(store.prepareExactFileRebases([
            .init(source: oldURL, destination: newURL)
        ]))
        prepared.commit()

        XCTAssertThrowsError(try controller.accessPersistedURL(
            newURL, kind: .file, allowingDirectoryAncestor: false
        )) { error in
            XCTAssertEqual(
                error as? SecurityScopedAccessError,
                .resolvedURLInvalid(newURL.path)
            )
        }
    }

    func testPreparedBatchRebaseIsAllOrNoneWhenLaterMoveConflicts() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")
        let firstTarget = URL(fileURLWithPath: "/tmp/moved-first.txt")
        let occupied = URL(fileURLWithPath: "/tmp/occupied.txt")
        _ = try store.record(Data("first".utf8), for: first, kind: .file)
        _ = try store.record(Data("second".utf8), for: second, kind: .file)
        _ = try store.record(Data("occupied".utf8), for: occupied, kind: .file)
        let before = store.records()

        XCTAssertThrowsError(try store.prepareExactFileRebases([
            .init(source: first, destination: firstTarget),
            .init(source: second, destination: occupied)
        ]))

        XCTAssertEqual(store.records(), before)
        XCTAssertNil(store.match(
            for: firstTarget, kind: .file, allowingDirectoryAncestor: false
        ))
    }

    func testCorruptOrOversizedStoreIsQuarantined() throws {
        let directory = temporaryDirectory()
        let limits = SecurityScopedBookmarkStore.Limits(
            maximumRecords: 4, maximumBookmarkBytes: 32,
            maximumTotalBookmarkBytes: 128, maximumSerializedBytes: 32,
            maximumAliasesPerRecord: 1
        )
        let store = SecurityScopedBookmarkStore(
            directoryURL: directory, limits: limits
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 33).write(to: store.fileURL)

        XCTAssertEqual(store.records(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains {
            $0.hasPrefix(SecurityScopedBookmarkStore.fileName + ".corrupt-")
        })
    }

    func testControllerBalancesSharedScopeAndResolvesDescendant() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let root = URL(fileURLWithPath: "/tmp/bookmark-root", isDirectory: true)
        let provider = FakeBookmarkProvider(resolutions: [
            Data("bookmark:/tmp/bookmark-root".utf8): .init(url: root, isStale: false)
        ])
        let controller = SecurityScopedAccessController(
            store: store, provider: provider, requiresSecurityScope: { true }
        )

        let selected = try controller.accessUserSelectedURL(root, kind: .directory)
        let child = root.appendingPathComponent("Sources/main.swift")
        let restored = try controller.accessPersistedURL(
            child, kind: .file, allowingDirectoryAncestor: true
        )
        XCTAssertEqual(restored.url, child)
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(provider.stopCount, 0)

        selected.invalidate()
        XCTAssertEqual(provider.stopCount, 0)
        restored.invalidate()
        XCTAssertEqual(provider.stopCount, 1)
    }

    func testRecordingWorkspaceChildDoesNotReplaceDirectoryGrant() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let root = URL(fileURLWithPath: "/tmp/project-root", isDirectory: true)
        let child = root.appendingPathComponent("main.swift")
        _ = try store.record(Data("root".utf8), for: root, kind: .directory)

        _ = try store.record(Data("child".utf8), for: child, kind: .file)

        XCTAssertEqual(store.records().count, 1)
        XCTAssertEqual(store.records()[0].kind, .directory)
        XCTAssertEqual(store.records()[0].path, root.path)
        XCTAssertEqual(store.records()[0].bookmarkData, Data("root".utf8))
    }

    func testStaleResolutionRefreshesPersistedBookmark() throws {
        let directory = temporaryDirectory()
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let oldURL = URL(fileURLWithPath: "/tmp/old", isDirectory: true)
        let movedURL = URL(fileURLWithPath: "/tmp/moved", isDirectory: true)
        let oldData = Data("old-data".utf8)
        _ = try store.record(oldData, for: oldURL, kind: .directory)
        let provider = FakeBookmarkProvider(resolutions: [
            oldData: .init(url: movedURL, isStale: true)
        ])
        let controller = SecurityScopedAccessController(
            store: store, provider: provider, requiresSecurityScope: { true }
        )

        let lease = try controller.accessPersistedURL(
            oldURL, kind: .directory
        )
        XCTAssertEqual(lease.url, movedURL)
        XCTAssertEqual(store.records().first?.path, movedURL.path)
        XCTAssertEqual(store.records().first?.aliases, [oldURL.path])
        lease.invalidate()
    }

    func testSavePanelAccessCanBePersistedAfterDestinationIsCreated() throws {
        let directory = temporaryDirectory()
        let destination = directory.appendingPathComponent("new.txt")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let store = SecurityScopedBookmarkStore(directoryURL: directory)
        let provider = FakeBookmarkProvider()
        let controller = SecurityScopedAccessController(
            store: store, provider: provider, requiresSecurityScope: { true }
        )

        let lease = try controller.beginUserSelectedAccess(destination)
        XCTAssertEqual(store.records(), [])
        try Data("created".utf8).write(to: destination)
        try controller.persistUserSelectedURL(destination, kind: .file)

        XCTAssertEqual(store.records().map(\.path), [destination.path])
        lease.invalidate()
        XCTAssertEqual(provider.stopCount, 1)
    }

    func testSandboxedRestoreRequiresPersistedGrant() {
        let controller = SecurityScopedAccessController(
            store: SecurityScopedBookmarkStore(directoryURL: temporaryDirectory()),
            provider: FakeBookmarkProvider(),
            requiresSecurityScope: { true }
        )
        XCTAssertThrowsError(try controller.accessPersistedURL(
            URL(fileURLWithPath: "/tmp/no-grant.txt"), kind: .file
        )) { error in
            XCTAssertEqual(
                error as? SecurityScopedAccessError,
                .missingBookmark("/tmp/no-grant.txt")
            )
        }
    }

    @MainActor
    func testAppModelRetainsRestoredFileLeaseUntilDocumentCloses() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("restored.txt")
        try Data("saved".utf8).write(to: file)
        let sessionURL = directory.appendingPathComponent("session.json")
        let sessionStore = SessionStore(sessionURL: sessionURL)
        try sessionStore.save(WindowSession(
            documents: [WindowSessionDocument(
                documentID: "restored", path: file.path, name: "restored.txt",
                baseRevision: try TextFileCodec.revision(ofFileAt: file),
                diskEncoding: .utf8, eol: .lf
            )],
            activeDocumentID: "restored",
            layout: WindowSessionLayout(
                kind: .single, activeGroup: 0,
                groups: [WindowSessionGroup(
                    documentIDs: ["restored"], activeDocumentID: "restored"
                )]
            )
        ))
        let releaseCounter = LockedInt()
        let model = AppModel(sessionStore: sessionStore, createInitialDocument: false)
        model.restoreSecurityScopedFileAccess = { url in
            SecurityScopedResourceLease(url: url) { releaseCounter.increment() }
        }

        await model.restoreSession()
        let document = try XCTUnwrap(model.document(forSessionID: "restored"))
        XCTAssertEqual(releaseCounter.value, 0)
        model.requestClose(document)
        XCTAssertEqual(releaseCounter.value, 1)
    }

    @MainActor
    func testDirtySessionAccessFailureKeepsRecoverableDraftUntitled() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let missing = directory.appendingPathComponent("missing.txt")
        let store = SessionStore(
            sessionURL: directory.appendingPathComponent("session.json")
        )
        try store.save(WindowSession(
            documents: [WindowSessionDocument(
                documentID: "dirty", path: missing.path, name: "missing.txt",
                draft: "unsaved work", baseRevision: nil,
                encoding: .utf8, diskEncoding: .utf8, eol: .lf
            )],
            activeDocumentID: "dirty"
        ))
        let model = AppModel(sessionStore: store, createInitialDocument: false)
        model.restoreSecurityScopedFileAccess = { url in
            throw SecurityScopedAccessError.missingBookmark(url.path)
        }

        await model.restoreSession()

        let document = try XCTUnwrap(model.document(forSessionID: "dirty"))
        XCTAssertNil(document.fileURL)
        XCTAssertEqual(document.text, "unsaved work")
        XCTAssertTrue(document.requiresSave)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SecurityScopedBookmarksTests-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryDirectories.append(url)
        return url
    }
}

private final class FakeBookmarkProvider: SecurityScopedBookmarkProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var resolutions: [Data: ResolvedSecurityScopedBookmark]
    private var starts = 0
    private var stops = 0

    init(resolutions: [Data: ResolvedSecurityScopedBookmark] = [:]) {
        self.resolutions = resolutions
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func makeBookmark(for url: URL) throws -> Data {
        let data = Data("bookmark:\(url.path)".utf8)
        lock.withLock {
            if resolutions[data] == nil {
                resolutions[data] = ResolvedSecurityScopedBookmark(
                    url: url.standardizedFileURL, isStale: false
                )
            }
        }
        return data
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        if let value = lock.withLock({ resolutions[data] }) { return value }
        throw CocoaError(.fileReadCorruptFile)
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
