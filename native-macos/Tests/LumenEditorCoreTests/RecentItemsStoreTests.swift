import Foundation
import XCTest
@testable import LumenEditorCore

final class RecentItemsStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testRecordsWireCompatibleEntriesAndStandardizesAbsolutePaths() throws {
        let store = makeStore()

        try store.recordRecentFile(
            "/tmp/a/../note.txt",
            at: Date(timeIntervalSince1970: 12)
        )
        try store.recordRecentProject(
            "/tmp/work/./project",
            at: Date(timeIntervalSince1970: 34)
        )
        try store.registerWindowSession(
            "window-1",
            at: Date(timeIntervalSince1970: 56)
        )

        XCTAssertEqual(
            store.recentFiles(),
            [RecentItem(path: "/tmp/note.txt", lastOpened: 12_000)]
        )
        XCTAssertEqual(
            store.recentProjects(),
            [RecentItem(path: "/tmp/work/project", lastOpened: 34_000)]
        )
        XCTAssertEqual(
            store.windowSessions(),
            [WindowSessionMetadata(id: "window-1", updatedAt: 56_000)]
        )

        let recentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.recentFilesURL))
                as? [[String: Any]]
        )
        XCTAssertEqual(Set(recentObject[0].keys), ["path", "lastOpened"])
        XCTAssertEqual(recentObject[0]["path"] as? String, "/tmp/note.txt")
        XCTAssertEqual((recentObject[0]["lastOpened"] as? NSNumber)?.doubleValue, 12_000)
        let projectObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.recentProjectsURL))
                as? [[String: Any]]
        )
        XCTAssertEqual(Set(projectObject[0].keys), ["path", "lastOpened"])
        XCTAssertEqual(projectObject[0]["path"] as? String, "/tmp/work/project")
        XCTAssertEqual(
            (projectObject[0]["lastOpened"] as? NSNumber)?.doubleValue,
            34_000
        )

        let sessionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.windowSessionsURL))
                as? [[String: Any]]
        )
        XCTAssertEqual(Set(sessionObject[0].keys), ["id", "updatedAt"])
        XCTAssertEqual(sessionObject[0]["id"] as? String, "window-1")
        XCTAssertEqual(
            (sessionObject[0]["updatedAt"] as? NSNumber)?.doubleValue,
            56_000
        )
    }

    func testRecentFilesAreSanitizedDeduplicatedSortedAndCappedAtFifty() throws {
        let store = makeStore()
        var entries: [[String: Any]] = (0..<55).map { index in
            ["path": "/tmp/file-\(index)", "lastOpened": index]
        }
        entries.append(["path": "relative/file", "lastOpened": 10_000])
        entries.append(["path": "/tmp/dir/../file-54", "lastOpened": 100])
        entries.append(["path": "/tmp/no-time", "lastOpened": "bad"])
        entries.append(["path": 42, "lastOpened": 20_000])
        try writeJSONObject(entries, to: store.recentFilesURL)

        let recent = store.recentFiles()

        XCTAssertEqual(recent.count, RecentItemsStore.maximumRecentFiles)
        XCTAssertEqual(recent.first, RecentItem(path: "/tmp/file-54", lastOpened: 100))
        XCTAssertEqual(recent[1], RecentItem(path: "/tmp/file-53", lastOpened: 53))
        XCTAssertEqual(recent.last, RecentItem(path: "/tmp/file-5", lastOpened: 5))
        XCTAssertEqual(recent.filter { $0.path == "/tmp/file-54" }.count, 1)
        XCTAssertFalse(recent.contains { $0.path == "relative/file" })
    }

    func testBadEntriesAreDroppedIndividuallyAndMissingTimeFallsBackToZero() throws {
        let store = makeStore()
        try writeJSONObject(
            [
                NSNull(),
                "not-an-object",
                ["path": 42, "lastOpened": 99],
                ["path": "relative", "lastOpened": 98],
                ["path": "/tmp/bool-time", "lastOpened": true],
                ["path": "/tmp/string-time", "lastOpened": "97"],
                ["path": "/tmp/missing-time"],
                ["path": "/tmp/good", "lastOpened": 2]
            ],
            to: store.recentFilesURL
        )

        XCTAssertEqual(store.recentFiles(), [
            RecentItem(path: "/tmp/good", lastOpened: 2),
            RecentItem(path: "/tmp/bool-time", lastOpened: 0),
            RecentItem(path: "/tmp/string-time", lastOpened: 0),
            RecentItem(path: "/tmp/missing-time", lastOpened: 0)
        ])
    }

    func testRecentProjectsAreSortedDeduplicatedAndCappedAtThirty() throws {
        let store = makeStore()
        var entries: [[String: Any]] = (0..<35).map { index in
            ["path": "/tmp/project-\(index)", "lastOpened": index]
        }
        entries.append(["path": "/tmp/project-34/../project-34", "lastOpened": 90])
        try writeJSONObject(entries, to: store.recentProjectsURL)

        let recent = store.recentProjects()

        XCTAssertEqual(recent.count, RecentItemsStore.maximumRecentProjects)
        XCTAssertEqual(recent.first, RecentItem(path: "/tmp/project-34", lastOpened: 90))
        XCTAssertEqual(recent[1], RecentItem(path: "/tmp/project-33", lastOpened: 33))
        XCTAssertEqual(recent.last, RecentItem(path: "/tmp/project-5", lastOpened: 5))
    }

    func testRecordingMovesAnExistingPathToTheFrontAndRemovalUsesCanonicalPath() throws {
        let store = makeStore()
        try store.recordRecentFile(
            "/tmp/one",
            at: Date(timeIntervalSince1970: 1)
        )
        try store.recordRecentFile(
            "/tmp/two",
            at: Date(timeIntervalSince1970: 2)
        )
        try store.recordRecentFile(
            "/tmp/folder/../one",
            at: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(store.recentFiles().map(\.path), ["/tmp/one", "/tmp/two"])
        XCTAssertTrue(try store.removeRecentFile("/tmp/other/../two"))
        XCTAssertFalse(try store.removeRecentFile("/tmp/two"))
        XCTAssertEqual(store.recentFiles().map(\.path), ["/tmp/one"])
    }

    func testRecordingReplacesAnExistingTimestampEvenWhenTheClockMovesBackwards() throws {
        let store = makeStore()
        try store.recordRecentFile(
            "/tmp/one",
            at: Date(timeIntervalSince1970: 10)
        )
        try store.recordRecentFile(
            "/tmp/two",
            at: Date(timeIntervalSince1970: 8)
        )
        try store.recordRecentFile(
            "/tmp/one",
            at: Date(timeIntervalSince1970: 7)
        )

        XCTAssertEqual(store.recentFiles(), [
            RecentItem(path: "/tmp/two", lastOpened: 8_000),
            RecentItem(path: "/tmp/one", lastOpened: 7_000)
        ])
    }

    func testWindowSessionsRejectTraversalThenCleanSortDeduplicateAndCap() throws {
        let store = makeStore()
        var entries: [[String: Any]] = (0..<14).map { index in
            ["id": "window-\(index)", "updatedAt": index]
        }
        entries.append(["id": "window-13", "updatedAt": 100])
        entries.append(["id": "../escape", "updatedAt": 1_000])
        entries.append(["id": "contains/slash", "updatedAt": 1_001])
        entries.append(["id": "under_score", "updatedAt": 1_002])
        entries.append(["id": "窗口", "updatedAt": 1_003])
        entries.append(["id": "missing-time"])
        try writeJSONObject(entries, to: store.windowSessionsURL)

        let sessions = store.windowSessions()

        XCTAssertEqual(sessions.count, RecentItemsStore.maximumWindowSessions)
        XCTAssertEqual(sessions.first, WindowSessionMetadata(id: "window-13", updatedAt: 100))
        XCTAssertEqual(sessions[1].id, "window-12")
        XCTAssertEqual(sessions.last?.id, "window-2")
        XCTAssertEqual(sessions.filter { $0.id == "window-13" }.count, 1)

        for invalidID in ["", "../escape", "a/b", "a_b", "窗口", "a.b"] {
            XCTAssertThrowsError(try store.registerWindowSession(invalidID)) { error in
                XCTAssertEqual(
                    error as? RecentItemsStoreError,
                    .invalidWindowSessionID(invalidID)
                )
            }
            XCTAssertThrowsError(try store.windowSessionURL(for: invalidID))
        }
    }

    func testSessionURLMappingCannotEscapeTheStoreDirectory() throws {
        let store = makeStore()

        XCTAssertEqual(try store.windowSessionURL(for: "legacy").lastPathComponent, "session.json")
        XCTAssertEqual(
            try store.windowSessionURL(for: "AbC-123").lastPathComponent,
            "session-AbC-123.json"
        )
        XCTAssertEqual(
            try store.windowSessionURL(for: "AbC-123").deletingLastPathComponent(),
            store.directoryURL
        )
    }

    func testWindowSessionPresentationRoundTripsAndLegacyMetadataStillDecodes() throws {
        let store = makeStore()
        let presentation = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: -120, y: 80, width: 1_200, height: 760),
            state: .fullScreen
        )
        try store.registerWindowSession(
            "presented",
            presentation: presentation,
            at: Date(timeIntervalSince1970: 5)
        )
        try store.registerWindowSession(
            "legacy-shape",
            at: Date(timeIntervalSince1970: 6)
        )

        let sessions = store.windowSessions()
        XCTAssertEqual(sessions.map(\.id), ["legacy-shape", "presented"])
        XCTAssertNil(sessions[0].presentation)
        XCTAssertEqual(sessions[1].presentation, presentation)

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.windowSessionsURL))
                as? [[String: Any]]
        )
        XCTAssertNil(raw[0]["bounds"])
        XCTAssertNil(raw[0]["state"])
        XCTAssertEqual(raw[1]["state"] as? String, "fullscreen")
    }

    func testPresentationUpdateDoesNotRegisterUnknownWindowAndRejectsInvalidBounds() throws {
        let store = makeStore()
        let valid = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertFalse(try store.updateWindowSessionPresentation(
            "not-saved-yet",
            presentation: valid
        ))
        XCTAssertEqual(store.windowSessions(), [])

        let invalid = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: 0, y: 0, width: 0, height: 600)
        )
        XCTAssertThrowsError(try store.registerWindowSession(
            "invalid-bounds",
            presentation: invalid
        )) { error in
            XCTAssertEqual(error as? RecentItemsStoreError, .invalidWindowBounds)
        }
    }

    func testTimestampOnlyRegistrationPreservesExistingPresentation() throws {
        let store = makeStore()
        let presentation = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: 1, y: 2, width: 900, height: 700),
            state: .maximized
        )
        try store.registerWindowSession(
            "window-a",
            presentation: presentation,
            at: Date(timeIntervalSince1970: 1)
        )
        try store.registerWindowSession(
            "window-a",
            at: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(store.windowSessions(), [WindowSessionMetadata(
            id: "window-a",
            updatedAt: 2_000,
            presentation: presentation
        )])
    }

    func testMalformedOptionalPresentationFieldsDoNotDiscardLegacyRegistryEntry() throws {
        let store = makeStore()
        try writeJSONObject([
            [
                "id": "window-safe",
                "updatedAt": 12,
                "bounds": ["x": 0, "y": 0, "width": 0, "height": 700],
                "state": "future-state"
            ]
        ], to: store.windowSessionsURL)

        XCTAssertEqual(store.windowSessions(), [WindowSessionMetadata(
            id: "window-safe", updatedAt: 12
        )])
    }

    func testRelativePathsAndNonFileURLsAreRejected() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.recordRecentFile("relative.txt")) { error in
            XCTAssertEqual(
                error as? RecentItemsStoreError,
                .invalidAbsolutePath("relative.txt")
            )
        }
        XCTAssertThrowsError(try store.recordRecentProject("../project"))
        XCTAssertThrowsError(try store.recordRecentProject("~/project"))
        XCTAssertThrowsError(try store.recordRecentFile(URL(string: "https://example.com/a")!))
    }

    func testMalformedJSONIsQuarantinedWhileValidWrongShapeSafelyFallsBack() throws {
        let store = makeStore()
        try write(Data("{ not-json".utf8), to: store.recentFilesURL)
        try writeJSONObject(["path": "/tmp/project"], to: store.recentProjectsURL)

        XCTAssertEqual(store.recentFiles(), [])
        XCTAssertEqual(store.recentProjects(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recentFilesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recentProjectsURL.path))

        let names = try FileManager.default.contentsOfDirectory(
            atPath: store.directoryURL.path
        )
        XCTAssertTrue(names.contains {
            $0.hasPrefix("\(RecentItemsStore.recentFilesFileName).corrupt-")
        })
    }

    func testOversizedRegistryIsReadBoundedlyAndQuarantined() throws {
        let store = makeStore(serializedByteLimit: 64)
        try write(Data(repeating: 0x20, count: 65), to: store.windowSessionsURL)

        XCTAssertEqual(store.windowSessions(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.windowSessionsURL.path))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: store.directoryURL.path
        )
        XCTAssertTrue(names.contains {
            $0.hasPrefix("\(RecentItemsStore.windowSessionsFileName).corrupt-")
        })
    }

    func testReadFailureReturnsEmptyAndMutationDoesNotReplaceTheUnreadableEntry() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let targetDirectory = store.directoryURL.appendingPathComponent(
            "unreadable-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.recentFilesURL,
            withDestinationURL: targetDirectory
        )

        XCTAssertEqual(store.recentFiles(), [])
        XCTAssertThrowsError(try store.recordRecentFile("/tmp/must-not-replace"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: store.recentFilesURL.path),
            targetDirectory.path
        )
    }

    func testWritesAreAtomicJSONAndCreateOnlyTheThreeRegistryFiles() throws {
        let store = makeStore()
        for index in 0..<10 {
            try store.recordRecentFile(
                "/tmp/file-\(index)",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
            try store.recordRecentProject(
                "/tmp/project-\(index)",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
            try store.registerWindowSession(
                "window-\(index)",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        for url in [store.recentFilesURL, store.recentProjectsURL, store.windowSessionsURL] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)),
            [
                RecentItemsStore.recentFilesFileName,
                RecentItemsStore.recentProjectsFileName,
                RecentItemsStore.windowSessionsFileName
            ]
        )
    }

    func testConcurrentTransactionsAcrossStoreInstancesDoNotLoseUpdates() throws {
        let first = makeStore()
        let second = RecentItemsStore(directoryURL: first.directoryURL)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8
        let errors = LockedErrors()

        for index in 0..<RecentItemsStore.maximumRecentFiles {
            queue.addOperation {
                do {
                    let store = index.isMultiple(of: 2) ? first : second
                    try store.recordRecentFile(
                        "/tmp/concurrent-\(index)",
                        at: Date(timeIntervalSince1970: TimeInterval(index + 1))
                    )
                } catch {
                    errors.append(error)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        XCTAssertEqual(errors.values.count, 0)
        let recent = first.recentFiles()
        XCTAssertEqual(recent.count, RecentItemsStore.maximumRecentFiles)
        XCTAssertEqual(Set(recent.map(\.path)).count, RecentItemsStore.maximumRecentFiles)
        XCTAssertEqual(recent.first?.path, "/tmp/concurrent-49")
        XCTAssertEqual(recent.last?.path, "/tmp/concurrent-0")
    }

    func testMutationRejectsOutputAboveConfiguredBoundWithoutPartialFile() throws {
        let store = makeStore(serializedByteLimit: 32)

        XCTAssertThrowsError(try store.recordRecentFile("/tmp/a-very-long-file-name")) { error in
            guard case RecentItemsStoreError.serializedDataTooLarge = error else {
                return XCTFail("Expected serializedDataTooLarge, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recentFilesURL.path))
    }

    func testOversizedMutationDoesNotReplaceAnExistingGoodRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RecentItemsStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryDirectories.append(directory)
        let roomyStore = RecentItemsStore(directoryURL: directory)
        try roomyStore.recordRecentFile(
            "/a",
            at: Date(timeIntervalSince1970: 1)
        )
        let original = try Data(contentsOf: roomyStore.recentFilesURL)
        let constrainedStore = RecentItemsStore(
            directoryURL: directory,
            serializedByteLimit: original.count + 1
        )

        XCTAssertThrowsError(try constrainedStore.recordRecentFile(
            "/this-path-is-long-enough-to-exceed-the-configured-output-bound"
        ))
        XCTAssertEqual(try Data(contentsOf: roomyStore.recentFilesURL), original)
    }

    func testDefaultDirectoryUsesApplicationSupportSubdirectory() {
        let directory = RecentItemsStore.defaultDirectoryURL()

        XCTAssertEqual(
            directory.lastPathComponent,
            RecentItemsStore.applicationSupportDirectoryName
        )
    }

    private func makeStore(
        serializedByteLimit: Int = RecentItemsStore.maximumSerializedBytes
    ) -> RecentItemsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RecentItemsStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryDirectories.append(directory)
        return RecentItemsStore(
            directoryURL: directory,
            serializedByteLimit: serializedByteLimit
        )
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try write(data, to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
